#!/usr/bin/env python3
"""Open Vanilla streams & creators: who is live, recent videos and the monthly creator leaderboard.

    python3 tools/streams_fetch.py                         one pass (cron / systemd timer every 5 min)
    python3 tools/streams_fetch.py --mock                  offline: canned API answers, no keys, no network
    python3 tools/streams_fetch.py --out X --creators Y --state Z

Writes `www/community/streams.json` (or --out), the file the website and Herald read:

    {"updated": "<iso>", "live": [stream], "scheduled": [stream], "videos": [video],
     "creators": [{"name", "platforms": {...}, "links": {...}, "badge", "character"?}],
     "leaderboard": {"month": "YYYY-MM", "rows": [{"creator", "hours", "peak", "avg", "videos"}]},
     "ingame": [{"character", "platform"}]}
    stream = {platform, channel, creator, title, viewers, thumbnail, url, embed, started}
    video  = {platform, id, creator, title, thumbnail, url, embed, published, kind, topics, classes}

Sources (each skipped when its keys are missing; nothing is ever re-uploaded, thumbnails are the
platforms' own URLs and players use the platforms' official embeds):
  Twitch   Helix with an app token (client credentials): TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET.
           Live streams of the curated channels, plus live channels whose title mentions "Open Vanilla" (or the old name)
           (search/channels, live only) and World of Warcraft streams titled "Open Vanilla".
  YouTube  Data API v3: YOUTUBE_API_KEY. Each channel costs 1 unit a pass (its uploads playlist),
           plus 1 per 50 videos (videos.list: live, upcoming, videos, shorts). The keyword search
           ("Open Vanilla" or the old name, two calls of 100 units) runs at most every YT_SEARCH_MINUTES (default 60):
           4,800 units a day, so a 5-minute timer fits ~15 channels in the default 10,000 a day.
           More channels: raise YT_SEARCH_MINUTES, slow the timer, or ask Google for more quota.
  TikTok   There is no public search or live API. Creators who connect TikTok through the official
           Display API (Login Kit, scopes user.info.basic + video.list) get their recent videos
           listed: TIKTOK_TOKENS_FILE is a JSON file {"<handle>": "<user access token>"} kept off the
           website. Everyone else's TikTok shows as a profile link on their creator card.

Creators: `www/community/creators.yml` (--creators). Everything above the marker line is hand-curated
and kept as written; everything below it is rewritten from the realm service's
`GET /api/creator/links` (REALM_URL + CREATOR_EXPORT_TOKEN, staff only) — the channels players linked
on their account (creators.html#link). A linked creator's in-game character is published only
when they ticked "Show me as LIVE"; the game also needs the in-game Social setting.

Proof of ownership: every linked account has a code (OW-XXXXXX, shown on the link page). A linked
channel is used only after its code was seen on the channel itself: the Twitch "About" text (Helix
users) or a live title, the YouTube channel description (channels.list, 1 unit). TikTok counts as
proven when the creator connected TikTok (TIKTOK_TOKENS_FILE: they signed in to TikTok to do it);
Kick has no API, so staff add Kick channels to the curated list by hand. Proofs are remembered in
the state file per (platform, channel, code); unlinking and relinking with another account needs a
new proof. Curated entries are trusted as written.

Monthly stats live in a small private state file (--state, default STREAMS_STATE or
~/.local/state/openvanilla/streams_state.json), never in the website folder: live seconds and
viewer-seconds per creator per month, the peak, and the videos published.

Keys are read from the environment only and never written anywhere.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_OUT = os.path.join(ROOT, "www", "community", "streams.json")
DEFAULT_CREATORS = os.path.join(ROOT, "www", "community", "creators.yml")
MARKER = "# --- linked: written by tools/streams_fetch.py from /api/creator/links; do not edit below ---"
KEYWORDS = ("openvanilla", "openwow")   # spaces ignored: "Open Vanilla", "OpenVanilla", and the old name
WOW_GAME_ID = "18122"            # Twitch: World of Warcraft
MAX_LIVE = 60
MAX_VIDEOS = 120
MONTHS_KEPT = 13
UA = "OpenVanilla-streams/1.0 (+https://openvanilla.app)"
CLASSES = ["warrior", "paladin", "hunter", "rogue", "priest", "shaman", "mage", "warlock", "druid"]
TOPICS = {
    "dungeon": ["dungeon", "deadmines", "stockade", "wailing caverns", "scarlet", "uldaman", "maraudon", "zul'farrak", "brd", "lbrs", "ubrs", "stratholme", "scholomance", "dire maul"],
    "raid": ["raid", "molten core", "onyxia", "blackwing", "zul'gurub", "aq20", "aq40", "naxx"],
    "pvp": ["pvp", "battleground", "warsong", "arathi", "alterac", "duel", "world pvp"],
    "guide": ["guide", "how to", "tutorial", "tips", "explained"],
    "leveling": ["leveling", "levelling", "level 1", "to 60", "questing", "1-60"],
    "addons": ["addon", "addons", " ui ", "interface", "workshop"],
    "roleplay": ["roleplay", " rp ", "persona", "story"],
    "news": ["patch", "update", "news", "announcement", "season"],
}
PLATFORMS = ("twitch", "youtube", "tiktok", "kick")
HANDLE_RE = {
    "twitch": re.compile(r"^[A-Za-z0-9_]{3,25}$"),
    "youtube": re.compile(r"^(UC[A-Za-z0-9_-]{22}|@[A-Za-z0-9._-]{3,30})$"),
    "tiktok": re.compile(r"^@?[A-Za-z0-9._]{2,24}$"),
    "kick": re.compile(r"^[A-Za-z0-9_]{3,25}$"),
}
CHAR_RE = re.compile(r"^[A-Za-zÀ-ÿ]{2,12}$")
CODE_RE = re.compile(r"^OW-[A-Z0-9]{6}$")
PROOF_RETRY = 15 * 60            # a pending link's channel is looked at again at most every 15 min


# ---------------------------------------------------------------------------------------------- HTTP

class Http:
    """urllib with a timeout; tests swap it for a fake with the same call()."""

    def call(self, method, url, headers=None, data=None, timeout=15):
        body = None
        if data is not None:
            body = data if isinstance(data, bytes) else urllib.parse.urlencode(data).encode()
        req = urllib.request.Request(url, data=body, method=method, headers={"User-Agent": UA, **(headers or {})})
        with urllib.request.urlopen(req, timeout=timeout) as r:  # nosec B310 - fixed https API hosts
            return json.loads(r.read().decode("utf-8") or "null")


def log(*a):
    print("[streams]", *a, file=sys.stderr)


# ---------------------------------------------------------------------------------------------- creators.yml

def _scalar(v):
    v = v.strip()
    if not v:
        return ""
    if v[0] in "\"'" and v[-1] == v[0] and len(v) >= 2:
        return v[1:-1]
    if v.startswith("[") and v.endswith("]"):
        return [_scalar(x) for x in v[1:-1].split(",") if x.strip()]
    low = v.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


def _strip_comment(line):
    out, q = [], None
    for i, c in enumerate(line):
        if q:
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(c)
    return "".join(out).rstrip()


def parse_yaml(text):
    """The small YAML subset creators.yml uses (maps, lists of maps, inline lists, scalars).
    PyYAML is used instead when it is installed."""
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text) or {}
    except ImportError:
        pass
    lines = []
    for raw in text.splitlines():
        s = _strip_comment(raw)
        if s.strip():
            lines.append((len(s) - len(s.lstrip(" ")), s.strip()))
    pos = 0

    def block(indent):
        nonlocal pos
        if pos >= len(lines):
            return None
        if lines[pos][1].startswith("- ") or lines[pos][1] == "-":
            out = []
            while pos < len(lines) and lines[pos][0] == indent and (lines[pos][1].startswith("- ") or lines[pos][1] == "-"):
                item = lines[pos][1][1:].strip()
                if not item:
                    pos += 1
                    out.append(block(lines[pos][0]) if pos < len(lines) and lines[pos][0] > indent else None)
                elif ":" in item and not item.startswith(("'", '"')):
                    # "- key: value" starts a map whose other keys sit at indent + 2
                    lines[pos] = (indent + 2, item)
                    out.append(mapping(indent + 2))
                else:
                    pos += 1
                    out.append(_scalar(item))
            return out
        return mapping(indent)

    def mapping(indent):
        nonlocal pos
        out = {}
        while pos < len(lines) and lines[pos][0] == indent and not lines[pos][1].startswith("- "):
            k, _, v = lines[pos][1].partition(":")
            pos += 1
            if v.strip():
                out[k.strip()] = _scalar(v)
            elif pos < len(lines) and (lines[pos][0] > indent or (lines[pos][0] == indent and lines[pos][1].startswith("- "))):
                out[k.strip()] = block(lines[pos][0])
            else:
                out[k.strip()] = None
        return out

    return block(lines[0][0]) if lines else {}


def _q(v):
    s = str(v)
    if s == "" or re.search(r"[:#\[\]{},&*!|>'\"%@`]", s) or s.strip() != s or s.lower() in ("true", "false", "yes", "no"):
        return json.dumps(s, ensure_ascii=False)
    return s


def dump_linked(creators):
    """The linked section, in the same subset parse_yaml reads."""
    out = ["linked:"]
    if not creators:
        return "linked: []\n"
    for c in creators:
        out.append(f"  - name: {_q(c['name'])}")
        if c.get("character"):
            out.append(f"    character: {_q(c['character'])}")
        out.append(f"    show_live: {'true' if c.get('show_live') else 'false'}")
        if c.get("code") and CODE_RE.match(str(c["code"])):
            out.append(f"    code: {c['code']}")
        out.append("    platforms:")
        for p, h in sorted(c["platforms"].items()):
            out.append(f"      {p}: {_q(h)}")
    return "\n".join(out) + "\n"


def load_creators(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return [], [], ""
    head, sep, _tail = text.partition(MARKER)
    data = parse_yaml(text) or {}
    curated = [c for c in (data.get("curated") or []) if isinstance(c, dict) and c.get("name")]
    linked = [c for c in (data.get("linked") or []) if isinstance(c, dict) and c.get("name")]
    return curated, linked, head if sep else text.rstrip("\n") + "\n\n"


def write_creators(path, head, linked):
    write_atomic(path, head.rstrip("\n") + "\n\n" + MARKER + "\n" + dump_linked(linked))


def refresh_curated(path, fresh):
    """The repo's curated list replaces ours; the linked part (rewritten every pass) stays."""
    with open(fresh, encoding="utf-8") as f:
        text = f.read()
    head = text.partition(MARKER)[0]
    if "curated" not in (parse_yaml(head) or {}):
        log("curated list:", fresh, "has no 'curated:' key; keeping ours")
        return
    _c, linked, _h = load_creators(path)
    write_creators(path, head, linked)


def valid_handle(platform, handle):
    r = HANDLE_RE.get(platform)
    return bool(r and isinstance(handle, str) and r.match(handle))


def fetch_linked(http, realm_url, token):
    """GET /api/creator/links (staff token) -> creators grouped by account."""
    rows = http.call("GET", realm_url.rstrip("/") + "/api/creator/links",
                     headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    by_user = {}
    for r in rows or []:
        p, h = str(r.get("platform", "")).lower(), str(r.get("handle", ""))
        if p not in PLATFORMS or not valid_handle(p, h):
            continue
        u = by_user.setdefault(r.get("user"), {"name": str(r.get("display_name") or h)[:40], "platforms": {},
                                                 "character": "", "show_live": False, "code": ""})
        code = str(r.get("code") or "").upper()
        if CODE_RE.match(code):
            u["code"] = code
        u["platforms"][p] = h.lstrip("@") if p in ("twitch", "kick", "tiktok") else h
        ch = str(r.get("character") or "")
        if ch and CHAR_RE.match(ch):
            u["character"] = ch[:1].upper() + ch[1:].lower()
        u["show_live"] = u["show_live"] or bool(r.get("show_live"))
    return sorted(by_user.values(), key=lambda c: c["name"].lower())


def profile_links(platforms):
    links = {}
    for p, h in platforms.items():
        h = str(h)
        if p == "twitch":
            links[p] = f"https://www.twitch.tv/{h}"
        elif p == "youtube":
            links[p] = f"https://www.youtube.com/{h}" if h.startswith("@") else f"https://www.youtube.com/channel/{h}"
        elif p == "tiktok":
            links[p] = f"https://www.tiktok.com/@{h.lstrip('@')}"
        elif p == "kick":
            links[p] = f"https://kick.com/{h}"
    return links


def merge_creators(curated, linked):
    """One list; a linked account that names the same channel as a curated entry joins it."""
    out, owner = [], {}
    for src, rows in (("curated", curated), ("linked", linked)):
        for c in rows:
            plats = {p: str(h).lstrip("@") if p in ("twitch", "kick", "tiktok") else str(h)
                     for p, h in (c.get("platforms") or {}).items() if p in PLATFORMS and h and valid_handle(p, str(h))}
            hit = next((owner[(p, h.lower())] for p, h in plats.items() if (p, h.lower()) in owner), None)
            if hit is None:
                hit = {"name": str(c["name"])[:40], "platforms": {}, "badge": str(c.get("badge") or ("linked" if src == "linked" else "")),
                       "character": "", "show_live": False, "all_videos": bool(c.get("all_videos")),
                       "topics": [str(t) for t in (c.get("topics") or [])][:6]}
                out.append(hit)
            for p, h in plats.items():
                hit["platforms"].setdefault(p, h)
                owner[(p, h.lower())] = hit
            ch = str(c.get("character") or "")
            if ch and CHAR_RE.match(ch) and not hit["character"]:
                hit["character"] = ch[:1].upper() + ch[1:].lower()
            hit["show_live"] = hit["show_live"] or bool(c.get("show_live"))
    for c in out:
        c["links"] = profile_links(c["platforms"])
    return out


def proof_key(platform, handle):
    return f"{platform}:{str(handle).lstrip('@').lower() if platform != 'youtube' else str(handle).lower()}"


def verify_linked(http, state, linked, now, twitch=None, yt_key="", tiktok_handles=()):
    """Keep only the linked channels whose account code was seen on the channel (see the top)."""
    proofs = state.setdefault("proofs", {})
    tried = state.setdefault("proof_tried", {})
    pending = {}                                  # platform -> {handle: code}
    for c in linked:
        code = str(c.get("code") or "").upper()
        if not CODE_RE.match(code):
            continue
        for p, h in (c.get("platforms") or {}).items():
            k = proof_key(p, h)
            if proofs.get(k) != code and now - tried.get(k, 0) >= PROOF_RETRY:
                pending.setdefault(p, {})[str(h)] = code

    def seen(p, h, text):
        k, code = proof_key(p, h), pending[p][h]
        tried[k] = now
        if code in str(text or "").upper():
            proofs[k] = code
            tried.pop(k, None)
            log(f"proof: {p} {h} belongs to the account with {code}")

    if pending.get("twitch") and twitch:
        cid, token = twitch
        hdr = {"Client-Id": cid, "Authorization": "Bearer " + token}
        logins = list(pending["twitch"])
        texts = {h.lower(): "" for h in logins}
        try:
            for i in range(0, len(logins), 100):
                q = "&".join("login=" + urllib.parse.quote(h.lstrip("@")) for h in logins[i:i + 100])
                for u in (http.call("GET", "https://api.twitch.tv/helix/users?" + q, headers=hdr) or {}).get("data") or []:
                    texts[str(u.get("login", "")).lower()] = texts.get(str(u.get("login", "")).lower(), "") + " " + str(u.get("description") or "")
                q = "&".join("user_login=" + urllib.parse.quote(h.lstrip("@")) for h in logins[i:i + 100])
                for s in (http.call("GET", "https://api.twitch.tv/helix/streams?first=100&" + q, headers=hdr) or {}).get("data") or []:
                    texts[str(s.get("user_login", "")).lower()] = texts.get(str(s.get("user_login", "")).lower(), "") + " " + str(s.get("title") or "")
            for h in logins:
                seen("twitch", h, texts.get(h.lstrip("@").lower(), ""))
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            log("twitch proofs:", e)
    if pending.get("youtube") and yt_key:
        for h in list(pending["youtube"]):
            try:
                r = yt(http, "channels", yt_key, part="snippet", **({"forHandle": h} if h.startswith("@") else {"id": h}))
                items = r.get("items") or []
                seen("youtube", h, items[0].get("snippet", {}).get("description", "") if items else "")
            except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
                log("youtube proof", h, e)
    for h in list(pending.get("tiktok") or {}):
        # Connecting TikTok (Display API) means they signed in to that TikTok account.
        if h.lstrip("@").lower() in {t.lstrip("@").lower() for t in tiktok_handles}:
            seen("tiktok", h, pending["tiktok"][h])
    out = []
    for c in linked:
        code = str(c.get("code") or "").upper()
        plats = {p: h for p, h in (c.get("platforms") or {}).items() if code and proofs.get(proof_key(p, h)) == code}
        if plats:
            out.append(dict(c, platforms=plats))
    return out


# ---------------------------------------------------------------------------------------------- classify

def classify(*texts):
    hay = " " + " ".join(t or "" for t in texts).lower() + " "
    topics = [k for k, words in TOPICS.items() if any(w in hay for w in words)]
    classes = [c for c in CLASSES if re.search(r"\b" + c + r"s?\b", hay)]
    return topics, classes


def mentions(*texts):
    return any(k in (t or "").lower().replace(" ", "") for t in texts for k in KEYWORDS)


def iso_duration_seconds(s):
    m = re.fullmatch(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", s or "")
    if not m:
        return 0
    d, h, mi, se = (int(x or 0) for x in m.groups())
    return ((d * 24 + h) * 60 + mi) * 60 + se


def ts(iso):
    try:
        return dt.datetime.fromisoformat(str(iso).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return 0.0


def iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------------------------- Twitch

def twitch_token(http, cid, secret, state, now):
    tok = state.get("twitch_token") or {}
    if tok.get("token") and tok.get("expires", 0) > now + 300 and tok.get("cid") == cid:
        return tok["token"]
    r = http.call("POST", "https://id.twitch.tv/oauth2/token",
                  data={"client_id": cid, "client_secret": secret, "grant_type": "client_credentials"})
    # The app token is a credential too: kept in the private state file, never in the output.
    state["twitch_token"] = {"token": r["access_token"], "expires": now + int(r.get("expires_in", 3600)), "cid": cid}
    return r["access_token"]


def twitch_streams(http, cid, token, logins):
    h = {"Client-Id": cid, "Authorization": "Bearer " + token}
    seen, out = set(), []

    def take(rows, need_keyword):
        for s in rows or []:
            if s.get("type", "live") != "live" or s.get("id") in seen:
                continue
            if need_keyword and not mentions(s.get("title"), " ".join(s.get("tags") or [])):
                continue
            seen.add(s.get("id"))
            out.append(s)

    logins = sorted({l.lower() for l in logins})
    for i in range(0, len(logins), 100):
        q = urllib.parse.urlencode([("user_login", l) for l in logins[i:i + 100]] + [("first", "100")])
        take(http.call("GET", "https://api.twitch.tv/helix/streams?" + q, headers=h).get("data"), False)
    # live channels whose title mentions Open Vanilla
    found = http.call("GET", "https://api.twitch.tv/helix/search/channels?" + urllib.parse.urlencode(
        {"query": "Open Vanilla", "live_only": "true", "first": "50"}), headers=h).get("data") or []
    extra = [c.get("broadcaster_login") for c in found
             if c.get("is_live") and mentions(c.get("title"), " ".join(c.get("tags") or []))
             and c.get("broadcaster_login") and c["broadcaster_login"].lower() not in logins]
    for i in range(0, len(extra), 100):
        q = urllib.parse.urlencode([("user_login", l) for l in extra[i:i + 100]])
        take(http.call("GET", "https://api.twitch.tv/helix/streams?" + q, headers=h).get("data"), True)
    # World of Warcraft streams titled Open Vanilla (first two pages are the biggest; enough for a strip)
    cursor = None
    for _ in range(2):
        params = {"game_id": WOW_GAME_ID, "first": "100"}
        if cursor:
            params["after"] = cursor
        r = http.call("GET", "https://api.twitch.tv/helix/streams?" + urllib.parse.urlencode(params), headers=h)
        take(r.get("data"), True)
        cursor = (r.get("pagination") or {}).get("cursor")
        if not cursor:
            break
    return out


def twitch_card(s):
    login = s.get("user_login") or s.get("user_name", "").lower()
    thumb = (s.get("thumbnail_url") or "").replace("{width}", "440").replace("{height}", "248")
    return {"platform": "twitch", "id": "tw:" + str(s.get("id")), "channel": s.get("user_name") or login,
            "handle": login, "title": (s.get("title") or "")[:140], "viewers": int(s.get("viewer_count") or 0),
            "thumbnail": thumb, "url": f"https://www.twitch.tv/{login}",
            "embed": {"type": "twitch", "channel": login}, "started": s.get("started_at") or ""}


# ---------------------------------------------------------------------------------------------- YouTube

def yt(http, path, key, **params):
    params["key"] = key
    return http.call("GET", "https://www.googleapis.com/youtube/v3/" + path + "?" + urllib.parse.urlencode(params))


def youtube_collect(http, key, channels, state, now, search_every):
    """-> (live, scheduled, videos) as raw videos.list items tagged with their channel id."""
    cache = state.setdefault("yt_uploads", {})
    ids = []
    handles = [c for c in channels if c.startswith("@") and c not in cache]
    for hnd in handles:
        r = yt(http, "channels", key, part="contentDetails", forHandle=hnd)
        for it in r.get("items") or []:
            cache[hnd] = it["contentDetails"]["relatedPlaylists"]["uploads"]
            state.setdefault("yt_ids", {})[hnd] = it["id"]
    plain = [c for c in channels if c.startswith("UC") and c not in cache]
    for i in range(0, len(plain), 50):
        r = yt(http, "channels", key, part="contentDetails", id=",".join(plain[i:i + 50]))
        for it in r.get("items") or []:
            cache[it["id"]] = it["contentDetails"]["relatedPlaylists"]["uploads"]
    for c in channels:
        pl = cache.get(c)
        if not pl:
            continue
        try:
            r = yt(http, "playlistItems", key, part="contentDetails", playlistId=pl, maxResults="10")
        except urllib.error.HTTPError as e:
            log("youtube uploads", c, e)
            continue
        ids += [it["contentDetails"]["videoId"] for it in r.get("items") or []]
    srch = state.setdefault("yt_search", {"at": 0, "ids": []})
    if now - srch.get("at", 0) >= search_every * 60:
        got = []
        for event in ("live", None):
            params = {"part": "id", "q": "\"Open Vanilla\"|Open Vanilla", "type": "video", "maxResults": "25", "order": "date"}
            if event:
                params["eventType"] = event
            r = yt(http, "search", key, **params)
            got += [it["id"]["videoId"] for it in r.get("items") or [] if it.get("id", {}).get("videoId")]
        srch.update(at=now, ids=list(dict.fromkeys(got))[:50])
    ids += srch.get("ids") or []
    ids = list(dict.fromkeys(ids))
    items = []
    for i in range(0, len(ids), 50):
        r = yt(http, "videos", key, part="snippet,liveStreamingDetails,contentDetails", id=",".join(ids[i:i + 50]))
        items += r.get("items") or []
    return items


def youtube_card(v):
    sn, live = v.get("snippet") or {}, v.get("liveStreamingDetails") or {}
    th = sn.get("thumbnails") or {}
    thumb = (th.get("high") or th.get("medium") or th.get("default") or {}).get("url", "")
    secs = iso_duration_seconds((v.get("contentDetails") or {}).get("duration"))
    vid = v.get("id")
    base = {"platform": "youtube", "id": "yt:" + str(vid), "channel": sn.get("channelTitle", ""),
            "handle": sn.get("channelId", ""), "title": (sn.get("title") or "")[:140], "thumbnail": thumb,
            "url": f"https://www.youtube.com/watch?v={vid}", "embed": {"type": "youtube", "id": vid}}
    state = sn.get("liveBroadcastContent", "none")
    if state == "live":
        base.update(viewers=int(live.get("concurrentViewers") or 0), started=live.get("actualStartTime", ""))
    elif state == "upcoming":
        base.update(viewers=0, scheduled=live.get("scheduledStartTime", ""))
    else:
        topics, classes = classify(sn.get("title"), sn.get("description"), " ".join(sn.get("tags") or []))
        base.update(published=sn.get("publishedAt", ""), kind="short" if 0 < secs <= 180 else "video",
                    duration=secs, topics=topics, classes=classes)
    return state, base


# ---------------------------------------------------------------------------------------------- TikTok

def tiktok_videos(http, tokens):
    out = []
    for handle, token in tokens.items():
        try:
            r = http.call("POST", "https://open.tiktokapis.com/v2/video/list/?fields="
                          "id,title,video_description,cover_image_url,share_url,create_time,duration",
                          headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
                          data=json.dumps({"max_count": 20}).encode())
        except urllib.error.HTTPError as e:
            log("tiktok", handle, e)
            continue
        for v in ((r or {}).get("data") or {}).get("videos") or []:
            title = (v.get("title") or v.get("video_description") or "")[:140]
            topics, classes = classify(title, v.get("video_description"))
            out.append({"platform": "tiktok", "id": "tt:" + str(v.get("id")), "channel": "@" + handle.lstrip("@"),
                        "handle": handle.lstrip("@"), "title": title, "thumbnail": v.get("cover_image_url", ""),
                        "url": v.get("share_url") or f"https://www.tiktok.com/@{handle.lstrip('@')}/video/{v.get('id')}",
                        "embed": {"type": "tiktok", "id": str(v.get("id")), "url": v.get("share_url", "")},
                        "published": iso(int(v.get("create_time") or 0)), "kind": "short",
                        "duration": int(v.get("duration") or 0), "topics": topics, "classes": classes,
                        "_text": (v.get("video_description") or "") + " " + title})
    return out


TIKTOK_TOKEN_URL = "https://open.tiktokapis.com/v2/oauth/token/"
TIKTOK_SCOPES = "user.info.basic,video.list"


def tiktok_access_tokens(http, path, env, now):
    """{handle: access token} from TIKTOK_TOKENS_FILE. An entry is either a bare access token or
    {"access", "refresh", "expires"} (what --tiktok-connect stores); TikTok access tokens live 24 h,
    so stored entries are refreshed here (TIKTOK_CLIENT_KEY / TIKTOK_CLIENT_SECRET) and the file is
    rewritten (mode 600). An entry that cannot be refreshed is skipped until staff reconnect it."""
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    if not isinstance(raw, dict):
        raise ValueError("the TikTok tokens file must be a JSON object")
    ck, cs = env.get("TIKTOK_CLIENT_KEY", "").strip(), env.get("TIKTOK_CLIENT_SECRET", "").strip()
    out, changed = {}, False
    for h, t in raw.items():
        if not valid_handle("tiktok", h):
            continue
        if isinstance(t, str):
            out[h] = t
            continue
        if not isinstance(t, dict):
            continue
        if t.get("expires", 0) < now + 300 and t.get("refresh") and ck and cs:
            try:
                r = http.call("POST", TIKTOK_TOKEN_URL, headers={"Content-Type": "application/x-www-form-urlencoded"},
                              data={"client_key": ck, "client_secret": cs, "grant_type": "refresh_token",
                                    "refresh_token": t["refresh"]})
                t = {"access": r["access_token"], "refresh": r.get("refresh_token") or t["refresh"],
                     "expires": int(now + int(r.get("expires_in", 86400)))}
                raw[h], changed = t, True
            except (urllib.error.URLError, OSError, ValueError, KeyError, TypeError) as e:
                log("tiktok refresh", h, e)
        if t.get("access") and t.get("expires", 0) > now:
            out[h] = t["access"]
    if changed:
        write_private(path, raw)
    return out


def tiktok_connect(http, env, path, handle, code="", now=None):
    """Staff helper (--tiktok-connect): without a code, the TikTok sign-in URL to send the creator;
    with the code TikTok's redirect showed them, store their tokens in TIKTOK_TOKENS_FILE."""
    ck, cs, redirect = (env.get(k, "").strip() for k in ("TIKTOK_CLIENT_KEY", "TIKTOK_CLIENT_SECRET", "TIKTOK_REDIRECT_URI"))
    if not (ck and redirect):
        raise SystemExit("set TIKTOK_CLIENT_KEY, TIKTOK_CLIENT_SECRET and TIKTOK_REDIRECT_URI first")
    handle = handle.lstrip("@").lower()
    if not valid_handle("tiktok", handle):
        raise SystemExit("not a TikTok handle: " + handle)
    if not code:
        return "https://www.tiktok.com/v2/auth/authorize/?" + urllib.parse.urlencode({
            "client_key": ck, "scope": TIKTOK_SCOPES, "response_type": "code", "redirect_uri": redirect,
            "state": "openvanilla-" + handle})
    r = http.call("POST", TIKTOK_TOKEN_URL, headers={"Content-Type": "application/x-www-form-urlencoded"},
                  data={"client_key": ck, "client_secret": cs, "code": code, "grant_type": "authorization_code",
                        "redirect_uri": redirect})
    if not r.get("access_token"):
        raise SystemExit("TikTok did not accept the code: " + str(r.get("error_description") or r.get("error") or r))
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except (FileNotFoundError, ValueError):
        raw = {}
    now = now or time.time()
    raw[handle] = {"access": r["access_token"], "refresh": r.get("refresh_token", ""),
                   "expires": int(now + int(r.get("expires_in", 86400)))}
    write_private(path, raw)
    return f"connected @{handle}; its public videos appear on the next pass"


# ---------------------------------------------------------------------------------------------- leaderboard

def month_of(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m")


def month_start(t):
    d = dt.datetime.fromtimestamp(t, dt.timezone.utc)
    return dt.datetime(d.year, d.month, 1, tzinfo=dt.timezone.utc).timestamp()


def accumulate(state, live, videos, now):
    """Fold one pass into the monthly stats.

    A broadcast is one stream id; it has been live from max(its start, the month's start, the end of
    what we already counted) until now, and that span is credited with this pass's viewer count
    (viewer-seconds, so the average is weighted by time). The peak is the highest count seen.
    Videos count once, in the month they were published.
    """
    m = month_of(now)
    months = state.setdefault("months", {})
    cur = months.setdefault(m, {})
    counted = state.setdefault("counted", {})
    m0 = month_start(now)
    for s in live:
        who = s.get("creator") or s.get("channel")
        row = cur.setdefault(who, {"seconds": 0.0, "viewer_seconds": 0.0, "peak": 0, "videos": []})
        start = max(ts(s.get("started")) or now, m0, counted.get(s["id"], 0))
        span = max(0.0, now - start)
        row["seconds"] += span
        row["viewer_seconds"] += span * int(s.get("viewers") or 0)
        row["peak"] = max(row["peak"], int(s.get("viewers") or 0))
        counted[s["id"]] = now
    for v in videos:
        pm = month_of(ts(v.get("published")) or now)
        if pm not in months and pm < m:
            continue                                 # older than the stats we keep
        who = v.get("creator") or v.get("channel")
        row = months.setdefault(pm, {}).setdefault(who, {"seconds": 0.0, "viewer_seconds": 0.0, "peak": 0, "videos": []})
        if v["id"] not in row["videos"]:
            row["videos"].append(v["id"])
    # forget broadcasts not seen for a day, and months past the window
    for k in [k for k, t in counted.items() if now - t > 86400]:
        del counted[k]
    for k in sorted(months)[:-MONTHS_KEPT]:
        del months[k]
    return leaderboard(state, m)


def leaderboard(state, m):
    rows = []
    for who, r in (state.get("months", {}).get(m) or {}).items():
        sec = r.get("seconds", 0.0)
        rows.append({"creator": who, "hours": round(sec / 3600.0, 1), "peak": int(r.get("peak", 0)),
                     "avg": int(round(r.get("viewer_seconds", 0.0) / sec)) if sec > 0 else 0,
                     "videos": len(r.get("videos") or [])})
    rows.sort(key=lambda r: (-r["hours"], -r["peak"], -r["videos"], r["creator"].lower()))
    rows = [r for r in rows if r["hours"] > 0 or r["videos"] > 0]
    for i, r in enumerate(rows):
        r["rank"] = i + 1
    return {"month": m, "rows": rows[:50]}


# ---------------------------------------------------------------------------------------------- the pass

def write_atomic(path, text):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(os.path.abspath(path)))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def write_private(path, obj):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(os.path.abspath(path)))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def save_state(path, state):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(os.path.abspath(path)))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.chmod(tmp, 0o600)                             # holds the Twitch app token
    os.replace(tmp, path)


def run(env, http, out_path, creators_path, state_path, now=None):
    now = now or time.time()
    state = load_state(state_path)
    curated, linked, head = load_creators(creators_path)
    realm, export_token = env.get("REALM_URL", "").strip(), env.get("CREATOR_EXPORT_TOKEN", "").strip()
    if realm and export_token:
        try:
            linked = fetch_linked(http, realm, export_token)
            write_creators(creators_path, head, linked)
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            log("creator links:", e, "(keeping the last export)")
    cid, secret = env.get("TWITCH_CLIENT_ID", "").strip(), env.get("TWITCH_CLIENT_SECRET", "").strip()
    key = env.get("YOUTUBE_API_KEY", "").strip()
    tok = None
    if cid and secret:
        try:
            tok = twitch_token(http, cid, secret, state, now)
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            log("twitch:", e)
            state.pop("twitch_token", None)
    tok_file = env.get("TIKTOK_TOKENS_FILE", "").strip()
    tokens = {}
    if tok_file and os.path.isfile(tok_file):
        try:
            tokens = tiktok_access_tokens(http, tok_file, env, now)
        except (OSError, ValueError, AttributeError) as e:
            log("tiktok tokens:", e)
    linked = verify_linked(http, state, linked, now, twitch=(cid, tok) if tok else None, yt_key=key,
                           tiktok_handles=list(tokens))
    creators = merge_creators(curated, linked)
    by_handle = {(p, h.lower()): c for c in creators for p, h in c["platforms"].items()}

    def owner(card):
        return by_handle.get((card["platform"], str(card.get("handle", "")).lower()))

    live, scheduled, videos = [], [], []
    if tok:
        try:
            logins = [c["platforms"]["twitch"] for c in creators if "twitch" in c["platforms"]]
            live += [twitch_card(s) for s in twitch_streams(http, cid, tok, logins)]
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            log("twitch:", e)
            state.pop("twitch_token", None)
    if key:
        try:
            chans = [c["platforms"]["youtube"] for c in creators if "youtube" in c["platforms"]]
            every = int(env.get("YT_SEARCH_MINUTES", "60") or 60)
            items = youtube_collect(http, key, chans, state, now, every)
            for hnd, chan_id in (state.get("yt_ids") or {}).items():   # @handle -> its channel id
                if ("youtube", hnd.lower()) in by_handle:
                    by_handle[("youtube", chan_id.lower())] = by_handle[("youtube", hnd.lower())]
            for item in items:
                kind, card = youtube_card(item)
                sn = item.get("snippet") or {}
                text = " ".join([sn.get("title", ""), sn.get("description", ""), " ".join(sn.get("tags") or [])])
                c = owner(card)
                if not mentions(text) and not (c and c.get("all_videos")):
                    continue
                (live if kind == "live" else scheduled if kind == "upcoming" else videos).append(card)
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            log("youtube:", e)
    if tokens:
        try:
            for v in tiktok_videos(http, tokens):
                text = v.pop("_text", "")
                c = owner(v)
                if mentions(text) or (c and c.get("all_videos")):
                    videos.append(v)
        except (urllib.error.URLError, OSError, ValueError) as e:
            log("tiktok:", e)

    for card in live + scheduled + videos:
        c = owner(card)
        card["creator"] = c["name"] if c else card["channel"]
    live.sort(key=lambda s: -s.get("viewers", 0))
    live = live[:MAX_LIVE]
    scheduled.sort(key=lambda s: ts(s.get("scheduled")))
    videos = list({v["id"]: v for v in videos}.values())
    videos.sort(key=lambda v: -ts(v.get("published")))
    videos = videos[:MAX_VIDEOS]
    board = accumulate(state, live, videos, now)

    # the in-game ● LIVE list: only creators who ticked "Show me as LIVE" and named a character
    ingame, seen = [], set()
    for s in live:
        c = owner(s)
        if c and c.get("show_live") and c.get("character") and c["character"] not in seen:
            seen.add(c["character"])
            ingame.append({"character": c["character"], "platform": s["platform"]})
    live_names = {s["creator"] for s in live}
    for card in live + scheduled + videos:
        card.pop("handle", None)
    doc = {
        "updated": iso(now),
        "live": live,
        "scheduled": scheduled[:30],
        "videos": videos,
        "creators": [{"name": c["name"], "platforms": sorted(c["platforms"]), "links": c["links"], "badge": c["badge"],
                      "topics": c.get("topics", []), "live": c["name"] in live_names}
                     for c in creators],
        "leaderboard": board,
        "ingame": ingame,
    }
    write_atomic(out_path, json.dumps(doc, ensure_ascii=False, indent=1))
    save_state(state_path, state)
    return doc


# ---------------------------------------------------------------------------------------------- mock mode

MOCK_CREATORS = """curated:
  - name: Orlen Maps
    badge: partner
    topics: [guide, dungeon]
    platforms:
      youtube: UCaaaaaaaaaaaaaaaaaaaaaa
      tiktok: "@orlenmaps"
  - name: RandomRaider
    platforms:
      twitch: randomraider

""" + MARKER + """
linked:
  - name: Berra Plays
    character: Berra
    show_live: true
    code: OW-BERRA2
    platforms:
      twitch: berraplays
      tiktok: berraplays
"""


class MockHttp:
    """Canned answers for --mock and the tests: two Twitch streams, a YouTube live, an upcoming
    stream, a video and a short, and one linked creator."""

    def __init__(self, viewers=120):
        self.calls = []
        self.viewers = viewers

    def call(self, method, url, headers=None, data=None, timeout=15):
        self.calls.append((method, url, headers or {}, data))
        if "id.twitch.tv/oauth2/token" in url:
            return {"access_token": "mock-app-token", "expires_in": 3600}
        if "/api/creator/links" in url:
            return [{"user": 7, "display_name": "Berra Plays", "platform": "twitch", "handle": "berraplays",
                     "character": "Berra", "show_live": True, "code": "OW-BERRA2"},
                    {"user": 7, "display_name": "Berra Plays", "platform": "tiktok", "handle": "@berraplays",
                     "character": "Berra", "show_live": True, "code": "OW-BERRA2"}]
        if "helix/users" in url:
            about = {"berraplays": "Classic+ every night. Open Vanilla proof: OW-BERRA2"}
            return {"data": [{"login": l, "description": about.get(l, "")}
                             for l in re.findall(r"login=([^&]+)", url)]}
        if "helix/search/channels" in url:
            return {"data": [{"broadcaster_login": "randomraider", "is_live": True, "title": "Open Vanilla MC night"}]}
        if "helix/streams" in url:
            if "game_id" in url:
                return {"data": [{"id": "9", "user_login": "someone", "user_name": "Someone", "type": "live",
                                  "title": "classic wow chill", "viewer_count": 900}], "pagination": {}}
            rows = []
            if "randomraider" in url:
                rows.append({"id": "2", "user_login": "randomraider", "user_name": "RandomRaider", "type": "live",
                             "title": "Open Vanilla MC night", "viewer_count": 40,
                             "thumbnail_url": "https://static-cdn.jtvnw.net/x-{width}x{height}.jpg",
                             "started_at": "2026-10-15T10:00:00Z"})
            if "berraplays" in url:
                rows.append({"id": "1", "user_login": "berraplays", "user_name": "BerraPlays", "type": "live",
                             "title": "Deadmines on Open Vanilla (priest)", "viewer_count": self.viewers,
                             "thumbnail_url": "https://static-cdn.jtvnw.net/b-{width}x{height}.jpg",
                             "started_at": "2026-10-15T11:00:00Z"})
            return {"data": rows}
        if "youtube/v3/channels" in url:
            return {"items": [{"id": "UCaaaaaaaaaaaaaaaaaaaaaa", "contentDetails": {"relatedPlaylists": {"uploads": "UUaaaa"}}}]}
        if "youtube/v3/playlistItems" in url:
            return {"items": [{"contentDetails": {"videoId": v}} for v in ("v1", "v2", "v3", "v4")]}
        if "youtube/v3/search" in url:
            return {"items": [{"id": {"videoId": "v5"}}]}
        if "youtube/v3/videos" in url:
            def item(i, title, state="none", dur="PT12M", extra=None):
                d = {"id": i, "snippet": {"title": title, "description": "", "channelId": "UCaaaaaaaaaaaaaaaaaaaaaa",
                                          "channelTitle": "Orlen Maps", "publishedAt": "2026-10-14T09:00:00Z",
                                          "liveBroadcastContent": state,
                                          "thumbnails": {"high": {"url": f"https://i.ytimg.com/vi/{i}/hqdefault.jpg"}}},
                     "contentDetails": {"duration": dur}}
                d.update(extra or {})
                return d
            return {"items": [
                item("v1", "Open Vanilla live: mage leveling", "live", extra={"liveStreamingDetails": {"concurrentViewers": "55", "actualStartTime": "2026-10-15T11:30:00Z"}}),
                item("v2", "Open Vanilla raid night", "upcoming", extra={"liveStreamingDetails": {"scheduledStartTime": "2026-10-16T19:00:00Z"}}),
                item("v3", "Open Vanilla warlock guide: dungeon tips", dur="PT14M"),
                item("v4", "My cat", dur="PT40S"),
                item("v5", "Open Vanilla in 60 seconds #shorts", dur="PT45S"),
            ]}
        raise urllib.error.URLError("mock: no answer for " + url)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.environ.get("STREAMS_OUT", DEFAULT_OUT))
    ap.add_argument("--creators", default=os.environ.get("CREATORS_YML", DEFAULT_CREATORS))
    ap.add_argument("--state", default=os.environ.get("STREAMS_STATE",
                                                      os.path.expanduser("~/.local/state/openvanilla/streams_state.json")))
    ap.add_argument("--curated-from", default="", help="take the curated part from this creators.yml "
                    "(a fresh copy from the repo) and keep --creators' linked part")
    ap.add_argument("--mock", action="store_true", help="canned answers; no keys, no network")
    ap.add_argument("--tiktok-connect", metavar="HANDLE", default="",
                    help="staff: print the TikTok sign-in link for a creator, then run again with --code")
    ap.add_argument("--code", default="", help="with --tiktok-connect: the code TikTok's redirect showed the creator")
    a = ap.parse_args(argv)
    env = dict(os.environ)
    http = Http()
    if a.tiktok_connect:
        path = env.get("TIKTOK_TOKENS_FILE", "").strip()
        if not path:
            raise SystemExit("set TIKTOK_TOKENS_FILE (a private path the fetcher can rewrite, e.g. /var/lib/openvanilla-streams/tiktok.json)")
        print(tiktok_connect(http, env, path, a.tiktok_connect, a.code))
        return 0
    if a.mock or env.get("STREAMS_MOCK") == "1":
        http = MockHttp()
        env.update(TWITCH_CLIENT_ID="mock", TWITCH_CLIENT_SECRET="mock", YOUTUBE_API_KEY="mock")
        env.pop("REALM_URL", None)                   # never rewrite creators.yml from canned data
        # canned data never lands in the real files: the pages read streams.mock.json with ?mock=1
        if a.out == DEFAULT_OUT:
            a.out = os.path.join(ROOT, "www", "community", "streams.mock.json")
        if "STREAMS_STATE" not in env and a.state.endswith(os.path.join("openvanilla", "streams_state.json")):
            a.state = os.path.join(tempfile.gettempdir(), "openvanilla_streams_mock_state.json")
        if a.creators == DEFAULT_CREATORS:
            a.creators = os.path.join(tempfile.gettempdir(), "openvanilla_streams_mock_creators.yml")
            write_atomic(a.creators, MOCK_CREATORS)
    if a.curated_from and os.path.isfile(a.curated_from):
        refresh_curated(a.creators, a.curated_from)
    doc = run(env, http, a.out, a.creators, a.state)
    log(f"{len(doc['live'])} live, {len(doc['scheduled'])} scheduled, {len(doc['videos'])} videos, "
        f"{len(doc['creators'])} creators -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
