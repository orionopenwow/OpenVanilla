"""Open Vanilla identity tokens: PASETO v4.public (Ed25519), verified on the host.

    keys = KeyCache(CENTRAL_URL + "/.well-known/openvanilla-keys.json")
    v = TokenVerifier(keys, host_id)
    claims = v.verify(token)        # raises TokenError; checks signature, aud, exp, iat, single-use jti

Token: "v4.public." + b64url(message || signature64) [+ "." + b64url(footer)], signature over
PAE("v4.public.", message, footer, implicit=""). The footer, when present, is JSON {"kid": "..."};
without a kid every published key is tried. Claims: sub, name, roles, aud, iat, exp (iat + 300), jti.

RevocationList polls GET /api/identity/revoked: {"updated": ..., "sub": [...]}, signed with the same
keys: header X-OpenVanilla-Signature (hex or base64url of the 64-byte Ed25519 signature over the exact
body) and the key id in X-OpenVanilla-Kid (also accepted: X-OpenVanilla-Key-Id).
"""
import base64
import json
import struct
import threading
import time

import ed25519

from . import http

HEADER = b"v4.public."
TOKEN_TTL_MAX = 600       # refuse tokens that claim to live longer than this
CLOCK_SKEW = 60


class TokenError(Exception):
    pass


def b64u_decode(s):
    s = s.strip()
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def b64u_encode(b):
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def pae(*pieces):
    out = struct.pack("<Q", len(pieces))
    for p in pieces:
        out += struct.pack("<Q", len(p) & 0x7FFFFFFFFFFFFFFF) + p
    return out


def sign(secret, claims, kid=None, footer=None, implicit=b""):
    """A v4.public token (tests and tools; the central service signs real ones)."""
    msg = json.dumps(claims, separators=(",", ":")).encode("utf-8")
    if footer is None and kid:
        footer = json.dumps({"kid": kid}, separators=(",", ":")).encode("utf-8")
    footer = footer or b""
    sig = ed25519.sign(secret, pae(HEADER, msg, footer, implicit))
    tok = HEADER.decode() + b64u_encode(msg + sig)
    return tok + ("." + b64u_encode(footer) if footer else "")


def parse(token):
    """(message bytes, signature, footer bytes)."""
    if not isinstance(token, str) or not token.startswith(HEADER.decode()) or len(token) > 8192:
        raise TokenError("not a v4.public token")
    rest = token[len(HEADER):]
    parts = rest.split(".")
    if len(parts) not in (1, 2):
        raise TokenError("malformed token")
    try:
        raw = b64u_decode(parts[0])
        footer = b64u_decode(parts[1]) if len(parts) == 2 else b""
    except (ValueError, TypeError):
        raise TokenError("malformed token") from None
    if len(raw) < 64:
        raise TokenError("malformed token")
    return raw[:-64], raw[-64:], footer


def verify_signature(token, keys, implicit=b""):
    """keys: {kid: 32-byte public key}. -> claims dict (signature only, no claim checks)."""
    msg, sig, footer = parse(token)
    kid = None
    if footer:
        try:
            kid = json.loads(footer.decode("utf-8")).get("kid")
        except (ValueError, AttributeError):
            kid = None
    cands = [keys[kid]] if kid in keys else ([] if kid else list(keys.values()))
    m2 = pae(HEADER, msg, footer, implicit)
    if not any(ed25519.verify(k, m2, sig) for k in cands):
        raise TokenError("bad signature")
    try:
        claims = json.loads(msg.decode("utf-8"))
    except ValueError:
        raise TokenError("bad claims") from None
    if not isinstance(claims, dict):
        raise TokenError("bad claims")
    return claims


def _ts(v):
    """PASETO uses RFC 3339 times; the brief says unix seconds. Take both."""
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    if isinstance(v, str):
        import datetime
        try:
            return datetime.datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
    raise TokenError("bad time claim")


class KeyCache:
    """GET /.well-known/openvanilla-keys.json -> {kid: pubkey}, cached (ttl), kept when offline."""

    def __init__(self, url, ttl=3600, fetch=None, clock=time.time, keys=None):
        self.url, self.ttl, self.clock = url, ttl, clock
        self.fetch = fetch or (lambda u: http(u, timeout=8)[:2])
        self.keys = dict(keys or {})
        self.fetched = 0 if not keys else clock()
        self.lock = threading.Lock()

    def refresh(self, force=False):
        with self.lock:
            age = self.clock() - self.fetched
            if self.keys and (age < self.ttl if not force else age < 60):
                return self.keys   # forced refreshes (unknown key) at most once a minute
            try:
                status, body = self.fetch(self.url)
                if status == 200:
                    data = json.loads(body.decode("utf-8") if isinstance(body, bytes) else body)
                    keys = {}
                    for k in data.get("keys", []):
                        if k.get("alg", "Ed25519") == "Ed25519" and k.get("kid") and k.get("x"):
                            x = b64u_decode(k["x"])
                            if len(x) == 32:
                                keys[str(k["kid"])] = x
                    if keys:
                        self.keys, self.fetched = keys, self.clock()
            except (OSError, ValueError, AttributeError):
                pass
            return self.keys

    def get(self):
        return self.refresh()


class TokenVerifier:
    def __init__(self, keys, host_id, clock=time.time, revoked=None):
        self.keys, self.host_id, self.clock = keys, host_id, clock
        self.revoked = revoked          # RevocationList or None
        self.seen = {}                  # jti -> exp
        self.lock = threading.Lock()

    def verify(self, token):
        cache = isinstance(self.keys, KeyCache)
        try:
            claims = verify_signature(token, self.keys.get() if cache else self.keys)
        except TokenError:
            if cache:
                claims = verify_signature(token, self.keys.refresh(force=True))   # a rotated key
            else:
                raise
        now = self.clock()
        aud = claims.get("aud")
        if aud != self.host_id and not (isinstance(aud, list) and self.host_id in aud):
            raise TokenError("token is for another realm")
        exp = _ts(claims.get("exp"))
        iat = _ts(claims.get("iat", now))
        if exp < now - CLOCK_SKEW:
            raise TokenError("token expired")
        if iat > now + CLOCK_SKEW or exp - iat > TOKEN_TTL_MAX:
            raise TokenError("token times are wrong")
        sub, jti = claims.get("sub"), claims.get("jti")
        if sub in (None, "") or not jti or not isinstance(jti, str) or len(jti) > 128:
            raise TokenError("token is missing sub or jti")
        roles = claims.get("roles") or []
        if isinstance(roles, list) and "banned" in roles:
            raise TokenError("this Open Vanilla account is banned")
        if self.revoked is not None and self.revoked.is_revoked(str(sub)):
            raise TokenError("this Open Vanilla account is banned")
        with self.lock:
            for j, e in list(self.seen.items()):
                if e < now - CLOCK_SKEW:
                    del self.seen[j]
            if jti in self.seen:
                raise TokenError("token already used")
            self.seen[jti] = exp
        return claims


class RevocationList:
    """Central bans: polled (every 5 minutes by the host), signature-checked, kept when offline."""

    def __init__(self, url, keys, fetch=None, clock=time.time, every=300):
        self.url, self.keys, self.clock, self.every = url, keys, clock, every
        self.fetch = fetch or (lambda u: http(u, timeout=8))
        self.subs = set()
        self.updated = None
        self.last = 0

    def _keys(self):
        return self.keys.get() if isinstance(self.keys, KeyCache) else self.keys

    def poll(self, force=False):
        if not force and self.clock() - self.last < self.every:
            return False
        self.last = self.clock()
        try:
            status, body, headers = self.fetch(self.url)
        except OSError:
            return False
        if status != 200:
            return False
        headers = {k.lower(): v for k, v in (headers or {}).items()}
        sig_txt = headers.get("x-openvanilla-signature", "")
        kid = headers.get("x-openvanilla-kid") or headers.get("x-openvanilla-key-id")
        try:
            sig = bytes.fromhex(sig_txt) if len(sig_txt) == 128 else b64u_decode(sig_txt)
        except ValueError:
            return False
        keys = self._keys()
        cands = [keys[kid]] if kid in keys else list(keys.values())
        if len(sig) != 64 or not any(ed25519.verify(k, body, sig) for k in cands):
            return False
        try:
            data = json.loads(body.decode("utf-8"))
            subs = {str(s) for s in data.get("sub", [])}
        except (ValueError, AttributeError, TypeError):
            return False
        self.subs, self.updated = subs, data.get("updated")
        return True

    def is_revoked(self, sub):
        return str(sub) in self.subs
