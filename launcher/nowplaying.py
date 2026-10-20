"""Now playing for the desktop launcher: "Share what I'm listening to" (Settings > Privacy, off by default).

While the switch is on, a background thread looks every 10 seconds at what is playing and writes

    launcher/nowplaying.json    {"title", "artist", "link", "at", "source"}   (nothing else)

and hands "Title - Artist" (80 characters at most) to the in-game Persona addon, which shows it to
other players as "Listening: ..." and shares it over its channel like its other profile fields.

Where the title comes from:
  * Windows: the system media session (the same one the volume flyout shows: Spotify, browsers,
    foobar2000, VLC with the plugin, ...). Needs the optional package `winsdk` (or the newer
    `winrt-Windows.Media.Control`); without it this source is skipped. Only title and artist are
    read; the app's name and the album art are not.
  * Spotify Web API, if the player linked their own Spotify account in the launcher (PKCE: no
    secret; scope user-read-currently-playing; the refresh token stays in the launcher's settings
    on this PC). Works on any OS. The client id is the launcher's Spotify app (`spotify_client_id`
    in defaults.json / settings.json); its redirect URI must be http://127.0.0.1:43129/callback.
    A Spotify app in development mode only serves the (max 25) accounts added in its dashboard.

How it reaches the game, honestly: the 1.12 client cannot be told anything while it runs, so the
desktop route is a SavedVariables shim. The launcher rewrites Persona's per-character file
(`Persona_NowPlaying = {text=, at=}`) in every character folder that already exists:
    <launcher>/benilla-config/saved/<Realm>-<Character>/Persona.lua          (the Open Vanilla client)
    <WoW 1.12 folder>/WTF/Account/<ACC>/<Realm>/<Character>/SavedVariables/Persona.lua
The client reads it when the character enters the world; Persona shows it for 10 minutes after it
was written (it cannot be refreshed during the session; /reload re-reads the copy the client saved
itself). The web client gets live updates instead through realm/www/nowplaying.js.

Turning the switch off writes an empty shim and an empty nowplaying.json.
"""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

MAX = 80
INTERVAL = 10
SPOTIFY_REDIRECT_PORT = 43129
SPOTIFY_REDIRECT = f"http://127.0.0.1:{SPOTIFY_REDIRECT_PORT}/callback"
SPOTIFY_SCOPE = "user-read-currently-playing"


def clean(s):
    s = re.sub(r"[\x00-\x1f\x7f|]", " ", str(s or ""))
    return re.sub(r"\s+", " ", s).strip()


def format_text(title, artist):
    """'Title - Artist', no control characters or pipes (colour codes), 80 characters at most."""
    t, a = clean(title), clean(artist)
    s = f"{t} - {a}" if t and a else (t or a)
    if len(s) > MAX:
        s = s[:MAX - 3].rstrip() + "..."
    return s


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r") + '"'


def shim_body(text, at):
    if not text:
        return "Persona_NowPlaying = {\n}\n"
    return (f"Persona_NowPlaying = {{\n\t[\"text\"] = {lua_string(text)},\n\t[\"at\"] = {int(at)},\n}}\n")


def shim_paths(engine_config_dirs=(), wow_folders=()):
    """Persona's per-character files in the character folders that already exist."""
    out = []
    if isinstance(engine_config_dirs, str):
        engine_config_dirs = [engine_config_dirs]
    for eng in engine_config_dirs or ():
        saved = os.path.join(eng, "saved") if eng else ""
        if not saved or not os.path.isdir(saved):
            continue
        for d in sorted(os.listdir(saved)):
            p = os.path.join(saved, d)
            if os.path.isdir(p) and "-" in d:          # <Realm>-<Character> (file_token keeps no other '-')
                out.append(os.path.join(p, "Persona.lua"))
    for wow in wow_folders or ():
        acc_root = os.path.join(wow, "WTF", "Account")
        if not os.path.isdir(acc_root):
            continue
        for acc in sorted(os.listdir(acc_root)):
            a = os.path.join(acc_root, acc)
            if not os.path.isdir(a):
                continue
            for realm in sorted(os.listdir(a)):
                r = os.path.join(a, realm)
                if not os.path.isdir(r) or realm == "SavedVariables":
                    continue
                for ch in sorted(os.listdir(r)):
                    sv = os.path.join(r, ch, "SavedVariables")
                    if os.path.isdir(sv):
                        out.append(os.path.join(sv, "Persona.lua"))
    return out


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------------------- sources

def read_windows_media():
    """{'title', 'artist'} of the system's current media session while it plays; None when the
    optional winsdk/winrt package is missing, nothing plays, or this is not Windows."""
    if os.name != "nt":
        return None
    try:
        import asyncio
        try:
            from winsdk.windows.media.control import \
                GlobalSystemMediaTransportControlsSessionManager as Manager  # type: ignore
        except ImportError:
            from winrt.windows.media.control import \
                GlobalSystemMediaTransportControlsSessionManager as Manager  # type: ignore
    except ImportError:
        return None

    async def query():
        mgr = await Manager.request_async()
        s = mgr.get_current_session()
        if s is None:
            return None
        status = s.get_playback_info().playback_status
        if int(getattr(status, "value", status)) != 4:          # 4 = Playing
            return None
        props = await s.try_get_media_properties_async()
        return {"title": props.title or "", "artist": props.artist or props.album_artist or ""}
    try:
        return asyncio.run(query())
    except Exception:  # noqa: BLE001 - a COM hiccup must never reach the launcher
        return None


class Http:
    def call(self, method, url, headers=None, data=None, timeout=10):
        body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
        req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
        with urllib.request.urlopen(req, timeout=timeout) as r:  # nosec B310 - fixed Spotify hosts
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)


def pkce_pair():
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def spotify_authorize_url(client_id, challenge, state):
    return "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode({
        "client_id": client_id, "response_type": "code", "redirect_uri": SPOTIFY_REDIRECT,
        "scope": SPOTIFY_SCOPE, "code_challenge_method": "S256", "code_challenge": challenge, "state": state})


def _token_store(sp, tok, now):
    sp.update(access=tok["access_token"], expires=now + int(tok.get("expires_in", 3600)) - 60)
    if tok.get("refresh_token"):
        sp["refresh"] = tok["refresh_token"]
    return sp


def link_spotify(client_id, open_url, http=None, timeout=300):
    """Browser sign-in with PKCE through a one-shot loopback server -> the dict to keep in
    settings['spotify'] ({client, access, refresh, expires}). Raises RuntimeError on failure."""
    http = http or Http()
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(16)
    got = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            msg = "Spotify linked. You can close this tab." if q.get("code") else "Spotify was not linked."
            self.wfile.write(f"<!doctype html><title>Open Vanilla</title><p style='font:16px sans-serif'>{msg}</p>".encode())

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", SPOTIFY_REDIRECT_PORT), Handler)
    srv.timeout = 1
    try:
        open_url(spotify_authorize_url(client_id, challenge, state))
        end = time.time() + timeout
        while not got and time.time() < end:
            srv.handle_request()
    finally:
        srv.server_close()
    if got.get("state") != state or not got.get("code"):
        raise RuntimeError("Spotify sign-in was cancelled" + (f" ({got.get('error')})" if got.get("error") else ""))
    status, tok = http.call("POST", "https://accounts.spotify.com/api/token", data={
        "client_id": client_id, "grant_type": "authorization_code", "code": got["code"],
        "redirect_uri": SPOTIFY_REDIRECT, "code_verifier": verifier})
    if status != 200 or not tok or "access_token" not in tok:
        raise RuntimeError("Spotify did not accept the sign-in")
    return _token_store({"client": client_id}, tok, time.time())


def read_spotify(sp, http=None, now=None):
    """-> ({'title','artist','link'} or None, the possibly refreshed sp dict or None if unlinked)."""
    if not sp or not sp.get("access"):
        return None, sp
    http, now = http or Http(), now or time.time()
    if now >= sp.get("expires", 0):
        if not sp.get("refresh"):
            return None, None
        try:
            status, tok = http.call("POST", "https://accounts.spotify.com/api/token", data={
                "client_id": sp["client"], "grant_type": "refresh_token", "refresh_token": sp["refresh"]})
        except urllib.error.HTTPError as e:
            return None, (None if e.code in (400, 401) else sp)       # revoked -> unlinked
        except (urllib.error.URLError, OSError, ValueError):
            return None, sp
        if status != 200 or not tok:
            return None, sp
        sp = _token_store(dict(sp), tok, now)
    try:
        status, j = http.call("GET", "https://api.spotify.com/v1/me/player/currently-playing",
                              headers={"Authorization": "Bearer " + sp["access"]})
    except urllib.error.HTTPError as e:
        if e.code == 401:
            sp = dict(sp, expires=0)
        return None, sp
    except (urllib.error.URLError, OSError, ValueError):
        return None, sp
    if status == 204 or not j or not j.get("is_playing") or not j.get("item"):
        return {"title": "", "artist": "", "link": ""}, sp
    it = j["item"]
    artist = ", ".join(a.get("name", "") for a in it.get("artists") or []) or (it.get("show") or {}).get("name", "")
    return {"title": it.get("name", ""), "artist": artist,
            "link": (it.get("external_urls") or {}).get("spotify", "")}, sp


# ---------------------------------------------------------------------------------------- worker

class NowPlaying:
    """One tick every INTERVAL seconds while enabled; thread-safe start/stop."""

    def __init__(self, json_path, shim_roots, get_settings, save_settings=None, http=None,
                 windows_reader=read_windows_media, clock=time.time):
        self.json_path = json_path
        self.shim_roots = shim_roots          # callable -> ([engine config dirs], [wow folders])
        self.get_settings = get_settings
        self.save_settings = save_settings or (lambda: None)
        self.http = http
        self.windows_reader = windows_reader
        self.clock = clock
        self.last = None                      # last text written
        self._stop = threading.Event()
        self._thread = None

    def tick(self):
        s = self.get_settings()
        now = self.clock()
        if not s.get("share_listening", False):
            if self.last is None:
                # first look: clear only what an earlier session shared; never touch the
                # game folders of a player who did not turn this on
                try:
                    with open(self.json_path, encoding="utf-8") as f:
                        d = json.load(f)
                    shared = d.get("title") or d.get("artist")
                except (OSError, ValueError, AttributeError):
                    shared = False
                if not shared:
                    self.last = ""
                    return ""
            if self.last != "":
                self.publish({"title": "", "artist": "", "link": ""}, now, "off")
            return ""
        np, source = None, ""
        if self.windows_reader:
            np = self.windows_reader()
            source = "windows" if np else ""
        if not np and s.get("spotify"):
            np, sp = read_spotify(s.get("spotify"), self.http, now)
            if sp != s.get("spotify"):
                if sp:
                    s["spotify"] = sp
                else:
                    s.pop("spotify", None)
                self.save_settings()
            source = "spotify" if np else ""
        np = np or {"title": "", "artist": "", "link": ""}
        return self.publish(np, now, source)

    def publish(self, np, now, source):
        text = format_text(np.get("title"), np.get("artist"))
        doc = {"title": clean(np.get("title"))[:MAX], "artist": clean(np.get("artist"))[:MAX],
               "link": np.get("link", "") if str(np.get("link", "")).startswith("https://") else "",
               "at": int(now), "source": source}
        try:
            write_atomic(self.json_path, json.dumps(doc, ensure_ascii=False))
        except OSError:
            pass
        # The shim is rewritten when the text changes, and every minute otherwise so its time
        # stamp stays inside Persona's 10-minute window for a character that logs in later.
        if text != self.last or int(now) % 60 < INTERVAL:
            engines, wows = self.shim_roots()
            body = shim_body(text, now)
            for p in shim_paths(engines, wows):
                try:
                    write_atomic(p, body)
                except OSError:
                    pass
        self.last = text
        return text

    def _run(self):
        delay = 0
        while not self._stop.wait(delay):
            delay = INTERVAL
            try:
                self.tick()
            except Exception:  # noqa: BLE001 - never take the launcher down
                pass

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="nowplaying", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
