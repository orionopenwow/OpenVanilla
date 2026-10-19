"""Open Vanilla's own downloads over BitTorrent, with a clean plain-HTTP fallback.

    t = Torrents(state_dir, settings)       # settings: {"seeding": False, "upload_kbps": 256}
    t.seeding_enabled                       # False until the player turns it on (after the explainer)
    t.enable_seeding(upload_kbps=256); t.disable_seeding()
    path = t.download(manifest_url, dest_dir, progress_cb)   # progress_cb(done, total, text)
    t.status()

What is shared: only files listed in an Open Vanilla manifest signed with the release key (the Solo pack,
the launcher/client zips, patch-Z.MPQ). Blizzard game files are never downloaded or seeded here.

Manifests: the existing solo.json / version.json shape, each downloadable entry ({"url", "size",
"sha256"}) optionally with
    "torrent": {"url": ".torrent URL", "info_hash": "<sha1 hex>", "name": "<file name>",
                "files": [{"path": "<file name>", "size": n, "sha256": "<hex>"}],
                "web_seeds": ["https://…/<file name>"], "trackers": ["https://play.openvanilla.app/announce"]}
and a detached signature at <manifest URL>.sig (hex Ed25519 over the exact bytes), as
packaging/release_manifest.py and tools/make_release_torrents.py write them.

libtorrent (optional): `import libtorrent` (Windows: bundle the `libtorrent` wheel from PyPI for the
launcher's Python, e.g. libtorrent==2.0.11 cp3xx win_amd64, which carries its OpenSSL DLLs; PyInstaller
needs --collect-binaries libtorrent). Settings: LSD (BEP 14) on, DHT/UPnP/NAT-PMP off, our tracker,
web seeds (BEP 19). Without seeding, unchoke slots are 0, so nothing is uploaded at all. Every file
is checked against the manifest's sha256 before it is used; on any problem the HTTP path runs.
"""
import hashlib
import json
import math
import os
import re
import threading
import time
import urllib.parse

import ed25519

from . import MANIFEST_PUBKEY, USER_AGENT, P2PError, http, read_json, write_json

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ +-]{0,127}$")
LISTEN = "0.0.0.0:6881,[::]:6881"


# ---------------------------------------------------------------- bencode

def bencode(x):
    if isinstance(x, bool):
        raise TypeError("bool")
    if isinstance(x, int):
        return b"i%de" % x
    if isinstance(x, str):
        x = x.encode("utf-8")
    if isinstance(x, (bytes, bytearray)):
        return b"%d:" % len(x) + bytes(x)
    if isinstance(x, (list, tuple)):
        return b"l" + b"".join(bencode(i) for i in x) + b"e"
    if isinstance(x, dict):
        items = sorted((k.encode("utf-8") if isinstance(k, str) else k, v) for k, v in x.items())
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError(type(x))


def bdecode(data):
    def dec(i):
        c = data[i:i + 1]
        if c == b"i":
            j = data.index(b"e", i)
            return int(data[i + 1:j]), j + 1
        if c == b"l":
            out, i = [], i + 1
            while data[i:i + 1] != b"e":
                v, i = dec(i)
                out.append(v)
            return out, i + 1
        if c == b"d":
            out, i = {}, i + 1
            while data[i:i + 1] != b"e":
                k, i = dec(i)
                v, i = dec(i)
                out[k] = v
            return out, i + 1
        if c.isdigit():
            j = data.index(b":", i)
            n = int(data[i:j])
            if j + 1 + n > len(data):
                raise ValueError("truncated")
            return data[j + 1:j + 1 + n], j + 1 + n
        raise ValueError("bad bencode")
    v, end = dec(0)
    if end != len(data):
        raise ValueError("trailing data")
    return v


def raw_info(torrent_bytes):
    """The exact bencoded info dict (hashing a re-encode would hide non-canonical input)."""
    d = bdecode(torrent_bytes)
    if not isinstance(d, dict) or b"info" not in d:
        raise ValueError("no info dict")
    enc = bencode(d[b"info"])
    if enc not in torrent_bytes:
        raise ValueError("non-canonical info dict")
    return d, enc


def info_hash(torrent_bytes):
    return hashlib.sha1(raw_info(torrent_bytes)[1]).hexdigest()  # nosec B324 - BitTorrent v1 info-hash


def piece_length_for(size):
    target = max(size / 1500, 1)
    return int(min(max(2 ** math.ceil(math.log2(target)), 256 * 1024), 16 << 20))


def make_torrent(path, trackers=(), web_seeds=(), piece_length=None, comment="Open Vanilla", created=None):
    """A single-file v1 .torrent. -> (bytes, info_hash hex)."""
    size = os.path.getsize(path)
    plen = piece_length or piece_length_for(size)
    pieces = bytearray()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(plen), b""):
            pieces += hashlib.sha1(block).digest()  # nosec B324 - mandated by BitTorrent v1
    info = {"name": os.path.basename(path), "length": size, "piece length": plen, "pieces": bytes(pieces)}
    t = {"info": info, "comment": comment, "created by": USER_AGENT, "creation date": int(created or time.time())}
    trackers = list(trackers)
    if trackers:
        t["announce"] = trackers[0]
        t["announce-list"] = [[u] for u in trackers]
    if web_seeds:
        t["url-list"] = list(web_seeds)
    data = bencode(t)
    return data, info_hash(data)


# ---------------------------------------------------------------- manifests

def _ok_url(u):
    s = urllib.parse.urlsplit(u or "")
    return s.scheme == "https" or (s.scheme == "http" and s.hostname in ("127.0.0.1", "localhost"))


def fetch_signed(url, pubkey=MANIFEST_PUBKEY, fetch=None):
    """The manifest at url, only if url + '.sig' verifies against the release key."""
    fetch = fetch or (lambda u: http(u, timeout=15)[:2])
    status, body = fetch(url)
    if status != 200:
        raise P2PError(f"The download information answered {status}.")
    status, sig = fetch(url + ".sig")
    try:
        sig = bytes.fromhex(sig.decode("ascii").strip()) if status == 200 else b""
    except (ValueError, UnicodeDecodeError):
        sig = b""
    if not ed25519.verify(bytes.fromhex(pubkey), body, sig):
        raise P2PError("The download information isn't signed by Open Vanilla. Nothing was downloaded.")
    try:
        return json.loads(body.decode("utf-8"))
    except ValueError:
        raise P2PError("The download information is damaged.") from None


def pick_entry(manifest, item=None):
    """The downloadable entry: manifest[item] ("zip", "setup"…) or the manifest itself."""
    e = manifest.get(item) if item else manifest
    if not isinstance(e, dict) or not e.get("url") or not re.fullmatch(r"[0-9a-f]{64}", str(e.get("sha256", "")).lower()):
        raise P2PError("The download information has no file to download.")
    if not _ok_url(e["url"]):
        raise P2PError("Downloads must come over https.")
    return e


def entry_name(e):
    t = e.get("torrent") or {}
    name = t.get("name") or os.path.basename(urllib.parse.urlsplit(e["url"]).path)
    name = urllib.parse.unquote(name)
    if not NAME_RE.match(name) or name in (".", ".."):
        raise P2PError("The download has an unsafe file name.")
    return name


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(chunk), b""):
            h.update(b)
    return h.hexdigest()


def http_download(urls, dest, sha256, size=None, progress_cb=None, opener=None, cancel=None):
    """First URL that yields the right bytes wins. Resumes a .part file. -> dest."""
    import urllib.request
    opener = opener or urllib.request.urlopen
    part = dest + ".part"
    last = None
    for url in urls:
        if not _ok_url(url):
            continue
        for _attempt in range(2):
            have = os.path.getsize(part) if os.path.isfile(part) else 0
            headers = {"User-Agent": USER_AGENT}
            if have:
                headers["Range"] = f"bytes={have}-"
            try:
                with opener(urllib.request.Request(url, headers=headers), timeout=30) as r:
                    status = getattr(r, "status", 200)
                    if have and status != 206:
                        have = 0
                    total = size or (have + int(r.headers.get("Content-Length") or 0)) or None
                    with open(part, "ab" if have else "wb") as f:
                        done = have
                        while True:
                            if cancel is not None and cancel.is_set():
                                raise P2PError("Cancelled.")
                            b = r.read(1 << 16)
                            if not b:
                                break
                            f.write(b)
                            done += len(b)
                            if progress_cb:
                                progress_cb(done, total, "Downloading")
            except P2PError:
                raise
            except Exception as e:   # HTTPError / URLError / OSError: next try or mirror
                last = e
                if getattr(e, "code", None) == 416:
                    os.remove(part)
                continue
            if size and os.path.getsize(part) < size:
                last = OSError("download cut short")
                continue
            if sha256_file(part) == sha256.lower():
                os.replace(part, dest)
                return dest
            os.remove(part)
            last = OSError("checksum mismatch")
            break
    raise P2PError(f"The download failed ({last}).")


# ---------------------------------------------------------------- the launcher's torrent client

def load_libtorrent():
    try:
        import libtorrent
        return libtorrent
    except Exception:
        return None


class Torrents:
    def __init__(self, state_dir, settings=None, lt="auto", fetch=None, opener=None, pubkey=MANIFEST_PUBKEY,
                 listen=LISTEN):
        self.state_dir = state_dir
        os.makedirs(state_dir, exist_ok=True)
        self.state_file = os.path.join(state_dir, "torrents.json")
        st = read_json(self.state_file, {}) or {}
        settings = settings or {}
        self.state = {
            "seeding": bool(settings.get("seeding", st.get("seeding", False))),
            "upload_kbps": int(settings.get("upload_kbps", st.get("upload_kbps", 256)) or 256),
            "seeds": st.get("seeds", []),
        }
        self.lt = load_libtorrent() if lt == "auto" else lt
        self.fetch, self.opener, self.pubkey, self.listen = fetch, opener, pubkey, listen
        self.session = None
        self.handles = {}
        self.current = None
        self.lock = threading.Lock()
        self._save()

    def _save(self):
        write_json(self.state_file, self.state)

    @property
    def backend(self):
        return "libtorrent" if self.lt else "http"

    @property
    def seeding_enabled(self):
        return self.state["seeding"]

    # -- settings
    def _settings(self):
        seeding = self.state["seeding"]
        return {"enable_lsd": True, "enable_dht": False, "enable_upnp": False, "enable_natpmp": False,
                "listen_interfaces": self.listen, "user_agent": USER_AGENT,
                "upload_rate_limit": self.state["upload_kbps"] * 1024 if seeding else 0,
                "unchoke_slots_limit": 8 if seeding else 0,     # 0 = never upload a byte
                "alert_mask": 0}

    def _session(self):
        if self.session is None and self.lt:
            self.session = self.lt.session(self._settings())
        return self.session

    def enable_seeding(self, upload_kbps=256):
        upload_kbps = max(16, min(int(upload_kbps), 100000))
        self.state.update(seeding=True, upload_kbps=upload_kbps)
        self._save()
        if self.lt:
            self._session().apply_settings(self._settings())
            self.resume()

    def disable_seeding(self):
        self.state["seeding"] = False
        self._save()
        if self.session:
            self.session.apply_settings(self._settings())
            for ih in list(self.handles):
                if self.current != ih:
                    self.session.remove_torrent(self.handles.pop(ih))

    def resume(self):
        """Seed again what was downloaded before (only when seeding is on)."""
        if not (self.lt and self.state["seeding"]):
            return 0
        n = 0
        for s in self.state["seeds"]:
            if s["info_hash"] in self.handles or not os.path.isfile(s["torrent"]):
                continue
            target = os.path.join(s["save_path"], s["name"])
            if not os.path.isfile(target):
                continue
            with open(s["torrent"], "rb") as f:
                h = self._add(f.read(), s["save_path"], s.get("web_seeds", []))
            self.handles[s["info_hash"]] = h
            n += 1
        return n

    def _add(self, torrent_bytes, save_path, web_seeds):
        lt = self.lt
        ti = lt.torrent_info(lt.bdecode(torrent_bytes))
        atp = lt.add_torrent_params()
        atp.ti = ti
        atp.save_path = save_path
        h = self._session().add_torrent(atp)
        for u in web_seeds:
            if _ok_url(u):
                h.add_url_seed(u)
        return h

    # -- download
    def download(self, manifest_url, dest, progress_cb=None, item=None, cancel=None):
        """Download the manifest's file into the folder dest; -> its path (sha256 checked)."""
        manifest = fetch_signed(manifest_url, self.pubkey, self.fetch)
        e = pick_entry(manifest, item)
        name = entry_name(e)
        os.makedirs(dest, exist_ok=True)
        target = os.path.join(dest, name)
        want = e["sha256"].lower()
        if os.path.isfile(target) and (not e.get("size") or os.path.getsize(target) == int(e["size"])) \
                and sha256_file(target) == want:
            if progress_cb:
                progress_cb(int(e.get("size") or 0), int(e.get("size") or 0), "Already downloaded")
            return target
        t = e.get("torrent")
        if self.lt and isinstance(t, dict):
            try:
                path = self._download_torrent(e, t, dest, name, progress_cb, cancel)
                if path:
                    return path
            except P2PError:
                raise
            except Exception:
                pass   # anything odd in the torrent path: plain HTTP below
        urls = [e["url"]] + [u for u in ((t or {}).get("web_seeds") or []) if u != e["url"]]
        return http_download(urls, target, want, e.get("size"), progress_cb, self.opener, cancel)

    def _download_torrent(self, e, t, dest, name, progress_cb, cancel):
        status, tbytes = (self.fetch or (lambda u: http(u, timeout=15)[:2]))(t["url"]) if _ok_url(t.get("url")) else (0, b"")
        if status != 200 or info_hash(tbytes) != str(t.get("info_hash", "")).lower():
            return None
        d, _ = raw_info(tbytes)
        if d[b"info"].get(b"name", b"").decode("utf-8", "replace") != name or b"files" in d[b"info"]:
            return None
        ih = t["info_hash"].lower()
        with self.lock:
            self.current = ih
            h = self.handles.get(ih) or self._add(tbytes, dest, t.get("web_seeds") or [e["url"]])
            self.handles[ih] = h
        try:
            stall_since, last_done = time.monotonic(), -1
            while True:
                if cancel is not None and cancel.is_set():
                    raise P2PError("Cancelled.")
                s = h.status()
                if progress_cb:
                    progress_cb(int(s.total_wanted_done), int(s.total_wanted or e.get("size") or 0),
                                f"Downloading ({s.num_peers} peers)")
                if s.is_seeding or s.is_finished:
                    break
                if s.total_wanted_done != last_done:
                    last_done, stall_since = s.total_wanted_done, time.monotonic()
                elif time.monotonic() - stall_since > 120:
                    return None   # nothing moving for two minutes: HTTP
                time.sleep(0.5)
        finally:
            self.current = None
        target = os.path.join(dest, name)
        files = t.get("files") or [{"path": name, "sha256": e["sha256"]}]
        for f in files:
            if f.get("path") == name and sha256_file(target) != str(f.get("sha256", e["sha256"])).lower():
                self.session.remove_torrent(self.handles.pop(ih))
                os.remove(target)
                return None
        if sha256_file(target) != e["sha256"].lower():
            return None
        tfile = os.path.join(self.state_dir, ih + ".torrent")
        with open(tfile, "wb") as f:
            f.write(tbytes)
        seeds = [s for s in self.state["seeds"] if s["info_hash"] != ih]
        seeds.append({"info_hash": ih, "name": name, "save_path": dest, "torrent": tfile,
                      "web_seeds": t.get("web_seeds") or []})
        self.state["seeds"] = seeds[-8:]
        self._save()
        if not self.state["seeding"]:
            self.session.remove_torrent(self.handles.pop(ih))
        return target

    def status(self):
        out = {"backend": self.backend, "seeding_enabled": self.state["seeding"],
               "upload_kbps": self.state["upload_kbps"], "torrents": [], "up_kbps": 0.0, "down_kbps": 0.0,
               "uploaded_total": 0}
        for ih, h in list(self.handles.items()):
            try:
                s = h.status()
            except Exception:
                continue
            out["torrents"].append({"info_hash": ih, "name": getattr(s, "name", ""), "progress": float(s.progress),
                                    "peers": int(s.num_peers), "seeding": bool(s.is_seeding)})
            out["up_kbps"] += s.upload_rate / 1024
            out["down_kbps"] += s.download_rate / 1024
            out["uploaded_total"] += int(s.all_time_upload)
        return out

    def close(self):
        if self.session:
            for h in list(self.handles.values()):
                try:
                    self.session.remove_torrent(h)
                except Exception:
                    pass
            self.handles.clear()
            self.session = None


EXPLAINER = (
    "Seeding shares Open Vanilla's own downloads (the Solo server pack, launcher and client updates, and "
    "the Classic+ patch) with other players near you and on the internet, so updates are faster for "
    "everyone and cost less to host. Only files signed by Open Vanilla are ever shared; your World of "
    "Warcraft game files are never shared. Uploads are capped at the limit you pick ({kbps} KB/s). "
    "Turn it off any time in Settings; nothing is uploaded while it is off."
)
