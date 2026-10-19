"""Live content: a small signed JSON (downloads/live.json) that changes what the launcher shows without
shipping a new launcher. Data only: nothing in it is ever run.

    live = LiveContent(cache_path, url, pubkey_hex)
    live.load_cached()      the last good copy (re-verified from disk), or the built-in defaults
    live.refresh()          fetch live.json + live.json.sig; keep the cache unless the new one verifies
    live.flag("solo")       feature switches, merged over DEFAULT_FLAGS

What it can set (see www/downloads/live.src.json, the file you edit):
    hero        {title, text, image, link, button}                 (no longer drawn on HOME; kept so older
    featured    [{id, title, text, image, link, button}]            launchers read an empty one)
    news        [{title, text, date, link, image}]                 news cards (up to 6)
    clients     [{id, name, type, version, url, page, description,  game clients for Workshop > CLIENTS
                  image, status}]                                   (up to 12; type exe|engine|web,
                                                                    status available|coming_soon)
    flags       {solo, host_friends, relay, browser_play, workshop, dedicated_server, solo_pack, ai}
    realms      [{name, host, port, portal, build}]                realm list defaults (up to 8)
    buttons     {<key>: {label, link}}                             labels/links of named buttons
    links       {SPP_URL, SPP_SHA256, SPP_SIZE, ...}               links.txt keys (allow-listed)
    message     {text, level}                                      a one-line notice under the bar

Signature: live.json.sig is the hex Ed25519 signature of live.json's exact bytes, made by
packaging/live_content.py with the same key as the update manifest (OPENVANILLA_MANIFEST_KEY). An
unsigned, badly signed, malformed or OLDER (lower "serial") live.json is ignored and the cache kept.

Standard library only; Python 3.10 compatible.
"""
import json
import os
import re
import time
import urllib.request

import ed25519

SCHEMA = 1
DEFAULT_FLAGS = {
    "solo": True,              # PLAY > Solo (SPP Classics on this PC)
    "solo_pack": False,        # the older Open Vanilla solo pack (needs downloads/solo.json published)
    "host_friends": True,      # unused: the launcher has no HOST tab (hosting is OpenVanilla-Server.zip)
    "relay": False,            # the Open Vanilla relay/directory is deployed: offer "Through Open Vanilla"
    "nodes": False,            # the volunteer node network is open: HOST > Become a node can switch on, hosts may be
                               # carried by verified nodes, joins seal streams end to end (docs/NODE_NETWORK.md)
    "browser_play": True,      # PLAY > Browser
    "workshop": True,          # WORKSHOP tab
    "dedicated_server": True,  # HOST > Dedicated server
    "online": True,            # PLAY > Online
    "ai": True,                # Settings > AI and the one-time "Activate your AI (optional)" card
}
# Download addresses and checksums of anything a launcher runs (SPP_URL, SPP_SHA256, SPP_SIZE) are NOT
# live content: they come only from links.txt shipped inside the signed release, so a change on main
# (live content is signed from main) can never point launchers at a new program.
LINK_KEYS = ("SPP_PAGE", "DISCORD_INVITE", "PORTAL_URL", "BACKEND_URL",
             "BUG_REPORTS", "DONATE_CRYPTO_URL", "DONATE_CARD_URL", "CLIENT_112_URL", "PATCH_NOTES_URL",
             "SERVER_STUDIO_URL", "HOST_GUIDE_URL")
MAX = {"news": 6, "featured": 4, "realms": 8, "clients": 12}
CLIENT_TYPES = ("exe", "engine", "web")
CLIENT_STATUSES = ("available", "coming_soon")
CLIENT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_\-]{0,39}$")
TEXT_MAX = 600
USER_AGENT = "OpenVanilla-Launcher"


def safe_link(url):
    """https links only (plus openvanilla:// in-launcher links)."""
    url = str(url or "").strip()
    if re.match(r"^openvanilla://[A-Za-z0-9/_\-.?=&%,]{1,300}$", url):
        return url
    if re.match(r"^https://[A-Za-z0-9.\-]+(:\d{1,5})?(/[^\s\"'<>\\]*)?$", url) and len(url) <= 500:
        return url
    return ""


def _text(v, n=TEXT_MAX):
    return "".join(ch for ch in str(v if v is not None else "") if ch.isprintable() or ch == "\n")[:n].strip()


def _card(d, keys=("title", "text", "date", "button", "id")):
    if not isinstance(d, dict):
        return None
    out = {k: _text(d[k], 120 if k != "text" else TEXT_MAX) for k in keys if k in d and d[k] is not None}
    for k in ("link", "image"):
        if d.get(k):
            u = safe_link(d[k])
            if u and not (k == "image" and u.startswith("openvanilla://")):
                out[k] = u
    return out if out.get("title") or out.get("text") else None


def client_id(name):
    """A client id from its name: lower case letters, digits and dashes ("WotLK 3.3.5a" -> "wotlk-3-3-5a")."""
    return re.sub(r"[^a-z0-9]+", "-", str(name or "").lower()).strip("-")[:40]


def sanitize_client(d):
    """One game client (live content's `clients`, or a block of clients.txt), checked; None when unusable.
    Fields: id, name, type exe|engine|web, version, url (https, the download), page (https; `repo` is
    accepted for it), description, image (https), status available|coming_soon."""
    if not isinstance(d, dict):
        return None
    name = _text(d.get("name"), 60)
    ctype = str(d.get("type") or "").strip().lower()
    cid = str(d.get("id") or "").strip().lower() or client_id(name)
    if not name or ctype not in CLIENT_TYPES or not CLIENT_ID_RE.match(cid):
        return None
    out = {"id": cid, "name": name, "type": ctype}
    if d.get("version") is not None and _text(d["version"], 20):
        out["version"] = _text(d["version"], 20)
    if d.get("description"):
        out["description"] = _text(d["description"], 300)
    for key, src in (("url", "url"), ("page", "page"), ("page", "repo"), ("image", "image")):
        if key in out or not d.get(src):
            continue
        u = safe_link(d[src])
        if u.startswith("https://"):
            out[key] = u
    status = str(d.get("status") or "available").strip().lower()
    out["status"] = status if status in CLIENT_STATUSES else "available"
    return out


HOST_RE = re.compile(r"^[A-Za-z0-9.\-]{1,253}$")


def _realm(d):
    if not isinstance(d, dict) or not HOST_RE.match(str(d.get("host", ""))):
        return None
    try:
        port = int(d.get("port", 3724))
        build = int(d.get("build", 5875))
    except (TypeError, ValueError):
        return None
    if not 0 < port < 65536:
        return None
    r = {"name": _text(d.get("name") or d["host"], 40), "host": d["host"], "port": port, "build": build}
    if d.get("portal") and safe_link(d["portal"]).startswith("https://"):
        r["portal"] = safe_link(d["portal"])
    return r


def sanitize(doc):
    """The parts of a live.json the launcher uses, with every value checked. Raises ValueError when
    it isn't a live.json at all."""
    if not isinstance(doc, dict) or int(doc.get("schema", 0) or 0) != SCHEMA:
        raise ValueError("not a live.json (schema 1)")
    out = {"schema": SCHEMA, "serial": int(doc.get("serial", 0) or 0)}
    if doc.get("hero"):
        hero = _card(doc["hero"])
        if hero:
            out["hero"] = hero
    for key in ("news", "featured"):
        items = [c for c in (_card(x) for x in (doc.get(key) or [])[:MAX[key]]) if c]
        if items:
            out[key] = items
    flags = doc.get("flags") or {}
    if isinstance(flags, dict):
        out["flags"] = {k: bool(v) for k, v in flags.items() if k in DEFAULT_FLAGS and isinstance(v, bool)}
    clients, seen = [], set()
    for c in (sanitize_client(x) for x in (doc["clients"] if isinstance(doc.get("clients"), list) else [])[:MAX["clients"]]):
        if c and c["id"] not in seen:
            seen.add(c["id"])
            clients.append(c)
    if clients:
        out["clients"] = clients
    realms = [r for r in (_realm(x) for x in (doc.get("realms") or [])[:MAX["realms"]]) if r]
    if realms:
        out["realms"] = realms
    buttons = {}
    for k, v in (doc.get("buttons") or {}).items() if isinstance(doc.get("buttons"), dict) else ():
        if re.match(r"^[a-z_]{1,32}$", str(k)) and isinstance(v, dict):
            b = {}
            if v.get("label"):
                b["label"] = _text(v["label"], 40)
            if v.get("link") and safe_link(v["link"]):
                b["link"] = safe_link(v["link"])
            if b:
                buttons[k] = b
    if buttons:
        out["buttons"] = buttons
    links = {}
    for k, v in (doc.get("links") or {}).items() if isinstance(doc.get("links"), dict) else ():
        k = str(k).upper()
        if k not in LINK_KEYS:
            continue
        v = str(v).strip()
        if k.endswith("_SHA256"):
            if re.fullmatch(r"[0-9a-fA-F]{64}", v):
                links[k] = v.lower()
        elif k.endswith("_SIZE"):
            if v.isdigit():
                links[k] = v
        elif safe_link(v):
            links[k] = safe_link(v)
    if links:
        out["links"] = links
    msg = doc.get("message")
    if isinstance(msg, dict) and msg.get("text"):
        out["message"] = {"text": _text(msg["text"], 160),
                          "level": msg.get("level") if msg.get("level") in ("info", "warn", "good") else "info"}
    return out


def verify(body, sig_hex, pubkey_hex):
    """The sanitized document when sig_hex is a valid signature of body's bytes, else None."""
    try:
        sig = bytes.fromhex(str(sig_hex).strip())
        if len(sig) != 64 or not ed25519.verify(bytes.fromhex(pubkey_hex), body, sig):
            return None
        return sanitize(json.loads(body.decode("utf-8")))
    except (ValueError, TypeError, UnicodeDecodeError):
        return None


def http_get(url, timeout=6):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(256 * 1024 + 1)


class LiveContent:
    def __init__(self, cache_path, url, pubkey_hex, get=http_get, clock=time.time):
        self.cache_path, self.url, self.pubkey = cache_path, url, pubkey_hex
        self.get, self.clock = get, clock
        self.doc = {}
        self.status = "none"      # none | cached | updated | unchanged | unsigned | bad-signature | older | offline | too-big
        self.fetched = None

    # ---- reading
    @property
    def flags(self):
        return dict(DEFAULT_FLAGS, **self.doc.get("flags", {}))

    def flag(self, name):
        return bool(self.flags.get(name, False))

    def get_link(self, key, default=None):
        return self.doc.get("links", {}).get(key, default)

    def button(self, key, label, link=None):
        b = self.doc.get("buttons", {}).get(key, {})
        return b.get("label", label), b.get("link", link)

    # ---- cache
    def load_cached(self):
        try:
            with open(self.cache_path, encoding="utf-8") as f:
                c = json.load(f)
            doc = verify(c["body"].encode("utf-8"), c["sig"], self.pubkey)
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            doc = None
        if doc is not None:
            self.doc, self.status, self.fetched = doc, "cached", c.get("fetched")
        return self.doc

    def _save(self, body, sig):
        os.makedirs(os.path.dirname(os.path.abspath(self.cache_path)), exist_ok=True)
        tmp = self.cache_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"body": body.decode("utf-8"), "sig": sig, "fetched": int(self.clock()), "url": self.url}, f)
        os.replace(tmp, self.cache_path)

    # ---- network
    def refresh(self):
        """Fetch, verify and (when good and not older) adopt live.json. Returns the status string."""
        if not self.url:
            return self.status
        try:
            body = self.get(self.url)
        except Exception:
            self.status = "offline" if not self.doc else self.status
            return "offline"
        if len(body) > 256 * 1024:
            return "too-big"
        try:
            sig = self.get(self.url + ".sig").decode("ascii", "replace").strip()
        except Exception:
            return "unsigned"
        doc = verify(body, sig, self.pubkey)
        if doc is None:
            return "bad-signature"
        if self.doc and doc.get("serial", 0) < self.doc.get("serial", 0):
            return "older"   # a replayed old file (or a stale mirror): keep what we have
        changed = doc != self.doc
        self.doc, self.fetched = doc, int(self.clock())
        try:
            self._save(body, sig)
        except OSError:
            pass
        self.status = "updated" if changed else "unchanged"
        return self.status
