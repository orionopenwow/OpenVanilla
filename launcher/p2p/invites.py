"""Invite codes (host side) and invite links.

Links: openvanilla://join/<host_id>?i=<code>&n=<urlencoded name>
       https://play.openvanilla.app/join/<host_id>?i=<code>
Codes are 10 upper-case base32 characters with a number of uses and an expiry. check() does not
spend a use (the relay asks for every stream); consume() does, when a new player's account is made.
A pass is a personal code the gate hands a player at sign-in (bound to their Open Vanilla id): it lets
their game connections through the relay of a private realm, and can't make new accounts.
"""
import threading
import time
import urllib.parse

from . import CENTRAL_URL, CODE_RE, HOST_ID_RE, P2PError, random_code, read_json, write_json


def make_link(host_id, code=None, name=None, guest=None, fp=None):
    q = {}
    if code:
        q["i"] = code
    if guest:
        q["g"] = guest
    if name:
        q["n"] = name
    if fp:
        q["k"] = fp
    return f"openvanilla://join/{host_id}" + ("?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote) if q else "")


def https_link(host_id, code=None, base=CENTRAL_URL):
    return f"{base}/join/{host_id}" + (f"?i={code}" if code else "")


def parse_link(text):
    """(host_id, code or None, name or None) from either link form; None if it isn't one."""
    text = (text or "").strip()
    u = urllib.parse.urlsplit(text)
    if u.scheme == "openvanilla" and u.netloc == "join":
        path = u.path.strip("/")
    elif u.scheme in ("https", "http") and u.path.startswith("/join/"):
        path = u.path[len("/join/"):].strip("/")
    else:
        return None
    host_id = path.lower()
    if not HOST_ID_RE.match(host_id):
        return None
    q = urllib.parse.parse_qs(u.query)
    code = (q.get("i") or [None])[0]
    code = code.upper() if code and CODE_RE.match(code.upper()) else None
    name = (q.get("n") or [None])[0]
    if name:
        name = "".join(ch for ch in name if ch.isprintable())[:40]
    return host_id, code, name


class InviteStore:
    """invites.json in the host folder: {code: {"uses": n, "used": n, "expires": unix, "created": unix}}."""

    def __init__(self, path, clock=time.time):
        self.path, self.clock = path, clock
        self.lock = threading.Lock()
        self.data = read_json(path, {}) or {}

    def _save(self):
        write_json(self.path, self.data)

    def create(self, uses=1, hours=24):
        uses, hours = int(uses), float(hours)
        if not 1 <= uses <= 1000 or not 0 < hours <= 24 * 30:
            raise P2PError("An invite can have 1-1000 uses and last up to 30 days.")
        with self.lock:
            self._prune()
            code = random_code(10)
            while code in self.data:
                code = random_code(10)
            now = self.clock()
            self.data[code] = {"uses": uses, "used": 0, "created": int(now), "expires": int(now + hours * 3600)}
            self._save()
            return code

    def pass_for(self, sub, days=30):
        """The player's pass (made or extended)."""
        with self.lock:
            now = self.clock()
            for c, v in self.data.items():
                if v.get("pass") == str(sub):
                    v["expires"] = int(now + days * 86400)
                    self._save()
                    return c
            code = random_code(10)
            while code in self.data:
                code = random_code(10)
            self.data[code] = {"uses": 1, "used": 0, "created": int(now), "expires": int(now + days * 86400),
                               "pass": str(sub)}
            self._save()
            return code

    def revoke_pass(self, sub):
        with self.lock:
            for c in [c for c, v in self.data.items() if v.get("pass") == str(sub)]:
                del self.data[c]
            self._save()

    def _valid(self, code, for_new=False):
        inv = self.data.get((code or "").upper())
        if not inv or inv["expires"] <= self.clock():
            return None
        if inv.get("pass"):
            return None if for_new else inv
        return inv if inv["used"] < inv["uses"] else None

    def check(self, code):
        with self.lock:
            return self._valid(code) is not None

    def consume(self, code):
        with self.lock:
            inv = self._valid(code, for_new=True)
            if not inv:
                return False
            inv["used"] += 1
            self._save()
            return True

    def revoke(self, code):
        with self.lock:
            if self.data.pop((code or "").upper(), None) is not None:
                self._save()
                return True
            return False

    def list(self):
        with self.lock:
            self._prune()
            return {c: dict(v, valid=self._valid(c) is not None) for c, v in self.data.items() if not v.get("pass")}

    def _prune(self):
        dead = [c for c, v in self.data.items() if v["expires"] < self.clock() - 7 * 86400]
        for c in dead:
            del self.data[c]


# ---------------------------------------------------------------- direct / LAN links (no central at all)

HOSTNAME_RE = __import__("re").compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")
FP_RE = __import__("re").compile(r"^[a-z2-7]{16}$")


def make_direct_link(kind, host, port, guest=None, name=None, fp=None):
    """openvanilla://join/direct/<host>:<port>?g=<code>&n=<name>&k=<fingerprint> (kind "direct" or "lan")."""
    q = {}
    if guest:
        q["g"] = guest
    if name:
        q["n"] = name
    if fp:
        q["k"] = fp
    return f"openvanilla://join/{kind}/{host}:{int(port)}" + ("?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote) if q else "")


def split_hostport(text, default_port=3724):
    text = text.strip()
    host, sep, port = text.rpartition(":")
    if not sep:
        host, port = text, str(default_port)
    if not port.isdigit() or not 0 < int(port) < 65536 or not HOSTNAME_RE.match(host or ""):
        return None
    return host, int(port)


def parse_any(text):
    """Every way to name a realm, as a dict:
    {"kind": "relay"|"direct"|"lan"|"plain", "host_id", "host", "port", "invite", "guest", "name", "fp"}.
    Plain "host[:port]" is kind "plain". None when it is none of these."""
    text = (text or "").strip()
    out = {"kind": None, "host_id": None, "host": None, "port": None, "invite": None, "guest": None, "name": None,
           "fp": None}
    u = urllib.parse.urlsplit(text)
    if u.scheme in ("openvanilla", "https", "http"):
        path = u.path.strip("/") if u.scheme == "openvanilla" and u.netloc == "join" else (
            u.path[len("/join/"):].strip("/") if u.path.startswith("/join/") else None)
        if path is None:
            return None
        q = urllib.parse.parse_qs(u.query)
        one = lambda k: (q.get(k) or [None])[0]  # noqa: E731
        for k, key in (("i", "invite"), ("g", "guest")):
            v = (one(k) or "").upper()
            out[key] = v if CODE_RE.match(v) else None
        name = one("n")
        out["name"] = "".join(ch for ch in name if ch.isprintable())[:40] if name else None
        fp = (one("k") or "").lower()
        out["fp"] = fp if FP_RE.match(fp) else None
        first, _, rest = path.partition("/")
        if first in ("direct", "lan") and rest:
            hp = split_hostport(rest)
            if not hp:
                return None
            out.update(kind=first, host=hp[0], port=hp[1])
            return out
        if HOST_ID_RE.match(path.lower()):
            out.update(kind="relay", host_id=path.lower())
            return out
        return None
    hp = split_hostport(text)
    if not hp:
        return None
    out.update(kind="plain", host=hp[0], port=hp[1])
    return out
