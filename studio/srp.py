"""SRP6 helpers for 1.12.1 accounts (the same maths realmd uses).

The account table stores the salt `s` and verifier `v` as big-endian hex; the protocol hashes
the salt little-endian. generate() makes a new pair; check() proves a password against a stored
pair without talking to realmd, so Studio sign-in works even while the login server is down.
"""
import hashlib
import hmac
import os

N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
G = 7


def _x(username, password, salt_be):
    h1 = hashlib.sha1(f"{username.upper()}:{password.upper()}".encode("utf-8")).digest()  # nosec B324 - SHA1 is mandated by the 1.12.1 SRP6 protocol
    h2 = hashlib.sha1(salt_be[::-1] + h1).digest()  # nosec B324
    return int.from_bytes(h2, "little")


def generate(username, password):
    """(s_hex, v_hex) for a new password, upper-case hex like the rest of the table."""
    salt = os.urandom(32)
    v = pow(G, _x(username, password, salt), N)
    return salt.hex().upper(), v.to_bytes(32, "big").hex().upper()


def check(username, password, s_hex, v_hex):
    """True when password matches the stored salt/verifier."""
    try:
        salt = bytes.fromhex((s_hex or "").rjust(64, "0"))
        stored = int(v_hex or "0", 16)
    except ValueError:
        return False
    if not stored:
        return False
    v = pow(G, _x(username, password, salt), N)
    return hmac.compare_digest(v.to_bytes(32, "big"), stored.to_bytes(32, "big"))
