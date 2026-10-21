#!/usr/bin/env python3
"""Legend: signed, portable character records for Open Vanilla realms.

Zero-dependency reference implementation (Python 3.8+). Licence: MIT.

    python3 legend.py verify FILE_OR_URL [--keys KEYFILE]
    python3 legend.py hero KEYLINE [--sign MESSAGE]

See SPEC.md for the standard.
"""

import base64
import hashlib
import hmac
import json
import os
import re
import sys

__all__ = [
    "canonical", "signing_bytes", "doc_hash", "b64u_encode", "b64u_decode",
    "hkdf_sha256", "ed25519_public_key", "ed25519_sign", "ed25519_verify",
    "make_realm_key", "kid_for", "sign_document", "verify_document",
    "fetch_keys", "hero_from_key", "hero_sign", "hero_verify",
    "LEGEND_PREFIX", "HERO_PREFIX",
]

LEGEND_PREFIX = b"openvanilla-legend-v1\n"
HERO_PREFIX = b"openvanilla-hero-v1\n"
HERO_SALT = b"openvanilla-hero-v1"
HERO_INFO = b"ed25519-seed"
WELL_KNOWN_PATH = "/.well-known/openvanilla-legend.json"
MAX_INT = 2 ** 53 - 1
HOST_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")
HERO_RE = re.compile(r"^ovh1\.[A-Za-z0-9_-]{43}$")

# --------------------------------------------------------------------------
# base64url (no padding)
# --------------------------------------------------------------------------

_B64U_RE = re.compile(r"^[A-Za-z0-9_-]*$")


def b64u_encode(data):
    return base64.urlsafe_b64encode(bytes(data)).rstrip(b"=").decode("ascii")


def b64u_decode(s, length=None):
    """Strict base64url decode. Padding is tolerated; anything else is not."""
    if not isinstance(s, str):
        raise ValueError("base64url value must be a string")
    s = s.rstrip("=")
    if not _B64U_RE.match(s) or len(s) % 4 == 1:
        raise ValueError("bad base64url")
    out = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    if b64u_encode(out) != s:  # reject non-canonical trailing bits
        raise ValueError("non-canonical base64url")
    if length is not None and len(out) != length:
        raise ValueError("expected %d bytes, got %d" % (length, len(out)))
    return out


# --------------------------------------------------------------------------
# Canonical JSON
# --------------------------------------------------------------------------

_ESC = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t",
        "\b": "\\b", "\f": "\\f"}


def _enc_str(s):
    out = ['"']
    for ch in s:
        e = _ESC.get(ch)
        if e is not None:
            out.append(e)
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        elif 0xD800 <= ord(ch) <= 0xDFFF:
            raise ValueError("lone surrogate in string")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _enc(v):
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        if not -MAX_INT <= v <= MAX_INT:
            raise ValueError("integer out of range")
        return str(v)
    if isinstance(v, str):
        return _enc_str(v)
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(_enc(x) for x in v) + "]"
    if isinstance(v, dict):
        for k in v:
            if not isinstance(k, str):
                raise ValueError("object keys must be strings")
        return "{" + ",".join(_enc_str(k) + ":" + _enc(v[k]) for k in sorted(v)) + "}"
    if isinstance(v, float):
        raise ValueError("floats are not allowed (integers only)")
    raise ValueError("unsupported type: %s" % type(v).__name__)


def canonical(value):
    """Canonical JSON bytes (UTF-8) for a JSON value."""
    return _enc(value).encode("utf-8")


def signing_bytes(doc):
    body = {k: v for k, v in doc.items() if k != "sig"}
    return LEGEND_PREFIX + canonical(body)


def doc_hash(doc):
    """Value for the next document's "prev": b64url(sha256(canonical(doc incl. sig)))."""
    return b64u_encode(hashlib.sha256(canonical(doc)).digest())


# --------------------------------------------------------------------------
# HKDF-SHA256 (RFC 5869)
# --------------------------------------------------------------------------

def hkdf_sha256(ikm, salt, info, length):
    if not salt:
        salt = b"\x00" * 32
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm, t, i = b"", b"", 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t
        i += 1
    return okm[:length]


# --------------------------------------------------------------------------
# Ed25519 (RFC 8032), extended twisted Edwards coordinates
# --------------------------------------------------------------------------

_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _P - 2, _P)) % _P
_D2 = (2 * _D) % _P
_I = pow(2, (_P - 1) // 4, _P)  # sqrt(-1)


def _add(P, Q):
    X1, Y1, Z1, T1 = P
    X2, Y2, Z2, T2 = Q
    A = (Y1 - X1) * (Y2 - X2) % _P
    B = (Y1 + X1) * (Y2 + X2) % _P
    C = T1 * _D2 * T2 % _P
    D = 2 * Z1 * Z2 % _P
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % _P, G * H % _P, F * G % _P, E * H % _P)


def _double(P):
    X1, Y1, Z1, _ = P
    A = X1 * X1 % _P
    B = Y1 * Y1 % _P
    C = 2 * Z1 * Z1 % _P
    H = A + B
    E = H - (X1 + Y1) * (X1 + Y1)
    G = A - B
    F = C + G
    return (E * F % _P, G * H % _P, F * G % _P, E * H % _P)


_ZERO = (0, 1, 1, 0)


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P:
        x = x * _I % _P
    if (x * x - x2) % _P:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * pow(5, _P - 2, _P) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _mul(s, P):
    Q = _ZERO
    while s > 0:
        if s & 1:
            Q = _add(Q, P)
        P = _double(P)
        s >>= 1
    return Q


_BASE_TABLE = None


def _base_mul(s):
    """s*G using a 4-bit fixed-base comb (64 additions per call)."""
    global _BASE_TABLE
    if _BASE_TABLE is None:
        table, B = [], _G
        for _ in range(64):
            row = [_ZERO, B]
            for _ in range(14):
                row.append(_add(row[-1], B))
            table.append(row)
            for _ in range(4):
                B = _double(B)
        _BASE_TABLE = table
    Q, i = _ZERO, 0
    s %= _L
    while s:
        n = s & 15
        if n:
            Q = _add(Q, _BASE_TABLE[i][n])
        s >>= 4
        i += 1
    return Q


def _encode(P):
    X, Y, Z, _ = P
    zi = pow(Z, _P - 2, _P)
    x, y = X * zi % _P, Y * zi % _P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decode(b):
    if len(b) != 32:
        return None
    y = int.from_bytes(b, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % _P)


def _equal(P, Q):
    return ((P[0] * Q[2] - Q[0] * P[2]) % _P == 0 and
            (P[1] * Q[2] - Q[1] * P[2]) % _P == 0)


def _sha512_int(*parts):
    return int.from_bytes(hashlib.sha512(b"".join(parts)).digest(), "little")


def _expand(seed):
    if len(seed) != 32:
        raise ValueError("Ed25519 seed must be 32 bytes")
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def ed25519_public_key(seed):
    a, _ = _expand(bytes(seed))
    return _encode(_base_mul(a))


def ed25519_sign(seed, msg, pub=None):
    a, prefix = _expand(bytes(seed))
    A = pub if pub is not None else _encode(_base_mul(a))
    r = _sha512_int(prefix, msg) % _L
    R = _encode(_base_mul(r))
    k = _sha512_int(R, A, msg) % _L
    S = (r + k * a) % _L
    return R + S.to_bytes(32, "little")


def ed25519_verify(pub, msg, sig):
    if len(pub) != 32 or len(sig) != 64:
        return False
    A = _decode(pub)
    R = _decode(sig[:32])
    if A is None or R is None:
        return False
    S = int.from_bytes(sig[32:], "little")
    if S >= _L:
        return False
    k = _sha512_int(sig[:32], pub, msg) % _L
    return _equal(_base_mul(S), _add(R, _mul(k, A)))


# --------------------------------------------------------------------------
# Realm keys and Legend documents
# --------------------------------------------------------------------------

def kid_for(pub):
    return b64u_encode(hashlib.sha256(pub).digest())[:16]


def make_realm_key():
    """Returns (seed, pub, kid) for a fresh realm signing key."""
    seed = os.urandom(32)
    pub = ed25519_public_key(seed)
    return seed, pub, kid_for(pub)


def sign_document(doc, seed, kid, pub=None):
    """Returns a copy of doc with "kid" set and "sig" added."""
    if pub is None:
        pub = ed25519_public_key(seed)
    if kid_for(pub) != kid:
        raise ValueError("kid does not match this key")
    out = {k: v for k, v in doc.items() if k != "sig"}
    out["kid"] = kid
    out["sig"] = b64u_encode(ed25519_sign(seed, signing_bytes(out), pub))
    return out


def _load(obj):
    if isinstance(obj, (bytes, bytearray)):
        obj = obj.decode("utf-8")
    if isinstance(obj, str):
        obj = json.loads(obj)
    return obj


def verify_document(doc, keyfile_json):
    """Verify a Legend against its realm key file (dict, str or bytes).

    Returns a dict: valid (bool), reason (str), realm, issued, hero (bool), kid.
    """
    res = {"valid": False, "reason": "", "realm": None, "issued": None,
           "hero": False, "kid": None}

    def fail(msg):
        res["reason"] = msg
        return res

    try:
        doc = _load(doc)
    except ValueError as e:
        return fail("document is not valid JSON: %s" % e)
    if not isinstance(doc, dict):
        return fail("document is not a JSON object")
    if doc.get("legend") != 1 or isinstance(doc.get("legend"), bool):
        return fail("unsupported legend version")
    realm, kid, issued, sig = doc.get("realm"), doc.get("kid"), doc.get("issued"), doc.get("sig")
    res["realm"], res["kid"] = realm, kid
    if not isinstance(realm, str) or not HOST_RE.match(realm):
        return fail("bad realm host")
    if not isinstance(issued, int) or isinstance(issued, bool):
        return fail("bad issued time")
    res["issued"] = issued
    if not isinstance(kid, str) or not isinstance(sig, str):
        return fail("missing kid or sig")
    if not isinstance(doc.get("kind"), str):
        return fail("missing kind")
    hero = doc.get("hero")
    if hero is not None and (not isinstance(hero, str) or not HERO_RE.match(hero)):
        return fail("bad hero id")
    res["hero"] = hero is not None
    subject = doc.get("subject")
    if doc["kind"] == "character":
        if not isinstance(subject, dict) or not isinstance(subject.get("id"), str) \
                or not subject["id"].startswith(realm + "/"):
            return fail("subject id does not belong to this realm")
    try:
        sig_b = b64u_decode(sig, 64)
    except ValueError:
        return fail("bad signature encoding")
    try:
        msg = signing_bytes(doc)
    except ValueError as e:
        return fail("document is not canonical-able: %s" % e)

    try:
        kf = _load(keyfile_json)
    except ValueError as e:
        return fail("realm key file is not valid JSON: %s" % e)
    if not isinstance(kf, dict) or kf.get("legend") != 1:
        return fail("bad realm key file")
    if not isinstance(kf.get("realm"), dict) or kf["realm"].get("host") != realm:
        return fail("key file is for a different realm")
    revoked = kf.get("revoked") or []
    if not isinstance(revoked, list):
        return fail("bad realm key file")
    if kid in revoked:
        return fail("key %s is revoked" % kid)
    key = None
    for k in kf.get("keys") or []:
        if isinstance(k, dict) and k.get("kid") == kid:
            key = k
            break
    if key is None:
        return fail("key %s not published by %s" % (kid, realm))
    if key.get("alg") != "Ed25519":
        return fail("unsupported key algorithm")
    try:
        pub = b64u_decode(key.get("pub"), 32)
    except ValueError:
        return fail("bad public key")
    if kid_for(pub) != kid:
        return fail("published kid does not match its public key")
    since, until = key.get("since"), key.get("until")
    if not isinstance(since, int) or since > issued:
        return fail("issued before the key was valid")
    if until is not None and (not isinstance(until, int) or issued >= until):
        return fail("issued after the key expired")
    if not ed25519_verify(pub, msg, sig_b):
        return fail("signature does not match")
    res["valid"] = True
    res["reason"] = "verified by %s" % realm
    return res


def fetch_keys(host, timeout=10):
    if not HOST_RE.match(host or ""):
        raise ValueError("bad realm host")
    return _https_get("https://" + host + WELL_KNOWN_PATH, timeout)


def _https_get(url, timeout=10):
    import urllib.request
    if not url.startswith("https://"):
        raise ValueError("only https:// URLs are allowed")
    req = urllib.request.Request(url, headers={"User-Agent": "legend.py/1"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(1 << 20)


# --------------------------------------------------------------------------
# Hero IDs
# --------------------------------------------------------------------------

def _hero_seed(line):
    parts = line.strip().split(".")
    if len(parts) < 3 or parts[0] != "ovk1" or not parts[1]:
        raise ValueError("not a Hero Key line (ovk1.<key_id>.<secret>)")
    secret = b64u_decode(parts[-1], 32)
    return hkdf_sha256(secret, HERO_SALT, HERO_INFO, 32)


def hero_from_key(line):
    return "ovh1." + b64u_encode(ed25519_public_key(_hero_seed(line)))


def hero_sign(line, message):
    if isinstance(message, str):
        message = message.encode("utf-8")
    return b64u_encode(ed25519_sign(_hero_seed(line), HERO_PREFIX + message))


def hero_verify(hero, message, sig):
    if isinstance(message, str):
        message = message.encode("utf-8")
    if not isinstance(hero, str) or not HERO_RE.match(hero):
        return False
    try:
        pub = b64u_decode(hero[5:], 32)
        sig_b = b64u_decode(sig, 64)
    except ValueError:
        return False
    return ed25519_verify(pub, HERO_PREFIX + message, sig_b)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _cli(argv):
    import argparse
    import time
    ap = argparse.ArgumentParser(prog="legend.py", description="Open Vanilla Legend tools")
    sub = ap.add_subparsers(dest="cmd")
    v = sub.add_parser("verify", help="verify a Legend file or https URL")
    v.add_argument("source")
    v.add_argument("--keys", help="use this realm key file instead of fetching it")
    h = sub.add_parser("hero", help="print the Hero ID for a Hero Key line")
    h.add_argument("keyline")
    h.add_argument("--sign", metavar="MESSAGE", help="also sign MESSAGE")
    a = ap.parse_args(argv)

    if a.cmd == "verify":
        try:
            if a.source.startswith("https://"):
                raw = _https_get(a.source)
            else:
                with open(a.source, "rb") as f:
                    raw = f.read()
            doc = _load(raw)
            if a.keys:
                with open(a.keys, "rb") as f:
                    keys = f.read()
            else:
                keys = fetch_keys(doc.get("realm") if isinstance(doc, dict) else None)
        except Exception as e:  # noqa: BLE001 - CLI reports any failure
            print("INVALID: %s" % e)
            return 1
        r = verify_document(doc, keys)
        print(("VALID" if r["valid"] else "INVALID") + ": " + r["reason"])
        print("realm:  %s" % r["realm"])
        if r["issued"] is not None:
            print("issued: %s UTC" % time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(r["issued"])))
        print("hero:   %s" % ("yes" if r["hero"] else "no"))
        return 0 if r["valid"] else 1
    if a.cmd == "hero":
        try:
            print(hero_from_key(a.keyline))
            if a.sign is not None:
                print(hero_sign(a.keyline, a.sign))
        except ValueError as e:
            print("error: %s" % e, file=sys.stderr)
            return 2
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
