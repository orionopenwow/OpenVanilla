"""End-to-end encryption between a player's launcher bridge and the host's agent, so a relay in the
middle (Open Vanilla's own, or a volunteer's node) carries only ciphertext.

    connect = connector(host_id, expected_fp)        # player side: a ws.connect replacement
    sock = connect("ws://node.example:3728/h/<host_id>/ws/3724")   # adds ?e2e=1, does the handshake
    sock.send(b"..."); sock.recv(); sock.close()     # same interface as ws.WebSocket

    sock = server_handshake(data_ws, host_id, host_secret)          # host agent side

The 1.12 game protocol is mostly plaintext (only world packet headers are scrambled), so without
this a relay operator could read chat, names and sign-in frames. With it the relay sees: which
host id a stream is for, when it opens and closes, and how many bytes flow. Nothing else.

Handshake (inside the WebSocket stream, binary frames):

    player -> host   "OWE2E1C" || c_pub(32)
    host   -> player "OWE2E1S" || s_pub(32) || host_pub(32) || Ed25519(host_key, "OWE2E1|" host_id "|" c_pub s_pub)

c_pub/s_pub are fresh X25519 keys (one pair per stream, forward secret). The player checks the
signature and that fingerprint(host_pub) is the one it expected (invite link k=, the directory
entry's "key", or its trust-on-first-use pin); a node that tries to sit in the middle cannot sign
as the host, so the player refuses. Keys: HKDF-SHA256(shared, salt=c_pub||s_pub,
info="openvanilla-e2e-v1|"host_id) -> 4 x 32 bytes (each direction: cipher key, MAC key).

Frames: c = m XOR SHAKE256(key || seq), tag = HMAC-SHA256(mac_key, seq || c)[:16]; seq is an
implicit per-direction counter, so dropped, replayed or reordered frames fail the tag and the
stream closes. Standard library only (the launcher has no crypto dependency): X25519 is RFC 7748
in Python integers, the cipher is a SHAKE256 keystream (a KMAC-style PRF) with encrypt-then-MAC.
v1: have it reviewed before volunteer nodes carry public traffic; a later version can switch to
ChaCha20-Poly1305 behind the same handshake (the magic carries the version).
"""
import hashlib
import hmac
import os
import socket
import urllib.parse

import ed25519

from . import P2PError, b32

MAGIC = b"OWE2E1"
TAG_LEN = 16
P = 2 ** 255 - 19
A24 = 121665


class E2EError(P2PError):
    pass


# ---------------------------------------------------------------- X25519 (RFC 7748)

def _scalar(k):
    b = bytearray(k)
    b[0] &= 248
    b[31] &= 127
    b[31] |= 64
    return int.from_bytes(b, "little")


def x25519(k, u):
    if len(k) != 32 or len(u) != 32:
        raise ValueError("X25519 takes 32-byte inputs")
    n = _scalar(k)
    ub = bytearray(u)
    ub[31] &= 127
    x1 = int.from_bytes(ub, "little") % P
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in range(254, -1, -1):
        bit = (n >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = x2 + z2, x2 - z2
        aa, bb = a * a % P, b * b % P
        e = aa - bb
        c, d = x3 + z3, x3 - z3
        da, cb = d * a % P, c * b % P
        x3 = (da + cb) ** 2 % P
        z3 = x1 * (da - cb) ** 2 % P
        x2 = aa * bb % P
        z2 = e * (aa + A24 * e) % P
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


BASE = (9).to_bytes(32, "little")


def keypair():
    sk = os.urandom(32)
    return sk, x25519(sk, BASE)


def fingerprint(pub):
    """Same as host.key_fingerprint: 16 lowercase base32 chars of SHA-256(host public key)."""
    return b32(hashlib.sha256(pub).digest()[:10])


def hkdf(ikm, salt, info, n):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:n]


def _transcript(host_id, c_pub, s_pub):
    return b"OWE2E1|" + host_id.encode("ascii") + b"|" + c_pub + s_pub


def _keys(shared, host_id, c_pub, s_pub):
    if shared == bytes(32):
        raise E2EError("The encrypted connection failed (bad key).")
    okm = hkdf(shared, c_pub + s_pub, b"openvanilla-e2e-v1|" + host_id.encode("ascii"), 128)
    return (okm[0:32], okm[32:64]), (okm[64:96], okm[96:128])   # (c2s enc, mac), (s2c enc, mac)


# ---------------------------------------------------------------- frames

class _Dir:
    def __init__(self, keys):
        self.enc, self.mac = keys
        self.seq = 0

    def _pad(self, seq, n):
        return hashlib.shake_256(b"owk1" + self.enc + seq).digest(n)

    def seal(self, m):
        seq = self.seq.to_bytes(8, "big")
        self.seq += 1
        n = len(m)
        c = (int.from_bytes(m, "little") ^ int.from_bytes(self._pad(seq, n), "little")).to_bytes(n, "little") if n else b""
        return c + hmac.new(self.mac, seq + c, hashlib.sha256).digest()[:TAG_LEN]

    def open(self, frame):
        if len(frame) < TAG_LEN:
            raise E2EError("short frame")
        c, tag = frame[:-TAG_LEN], frame[-TAG_LEN:]
        seq = self.seq.to_bytes(8, "big")
        if not hmac.compare_digest(tag, hmac.new(self.mac, seq + c, hashlib.sha256).digest()[:TAG_LEN]):
            raise E2EError("frame failed its check (tampered, replayed or out of order)")
        self.seq += 1
        n = len(c)
        return (int.from_bytes(c, "little") ^ int.from_bytes(self._pad(seq, n), "little")).to_bytes(n, "little") if n else b""


class E2ESocket:
    """A ws.WebSocket look-alike whose frames are sealed: send/recv/close/settimeout/closed."""

    def __init__(self, sock, send_keys, recv_keys, peer_key=None):
        self.sock = sock
        self._tx, self._rx = _Dir(send_keys), _Dir(recv_keys)
        self.peer_key = peer_key
        self.e2e = True

    @property
    def closed(self):
        return getattr(self.sock, "closed", False)

    def send(self, data):
        if isinstance(data, str):
            data = data.encode("utf-8")
        self.sock.send(self._tx.seal(bytes(data)))

    def recv(self):
        m = self.sock.recv()
        if m is None:
            return None
        if isinstance(m, str):
            self.close()
            return None
        try:
            return self._rx.open(m)
        except E2EError:
            self.close()
            return None

    def close(self, code=1000):
        self.sock.close(code)

    def settimeout(self, t):
        self.sock.settimeout(t)


def _recv_exact_msg(sock, size, timeout):
    sock.settimeout(timeout)
    try:
        m = sock.recv()
    except (OSError, socket.timeout):
        m = None
    if not isinstance(m, bytes) or len(m) != size:
        raise E2EError("The realm didn't answer the encrypted connection (old host software, or the relay "
                       "isn't carrying it).")
    return m


def client_handshake(sock, host_id, expected_fp, timeout=15):
    """Player side. expected_fp: the host key fingerprint to insist on (required: without one a relay
    could sit in the middle)."""
    if not expected_fp:
        raise E2EError("This realm's host key isn't known yet, so an encrypted connection can't be checked. "
                       "Ask the host for a fresh invite link.")
    c_sk, c_pub = keypair()
    sock.send(MAGIC + b"C" + c_pub)
    m = _recv_exact_msg(sock, 7 + 32 + 32 + 64, timeout)
    if m[:7] != MAGIC + b"S":
        raise E2EError("The realm answered the encrypted connection with something else.")
    s_pub, host_pub, sig = m[7:39], m[39:71], m[71:]
    if not ed25519.verify(host_pub, _transcript(host_id, c_pub, s_pub), sig):
        raise E2EError("The encrypted connection wasn't signed by the host. Someone between you and the realm "
                       "may be tampering; not connecting.")
    if fingerprint(host_pub) != expected_fp:
        raise E2EError("The realm's host key doesn't match the one you expected. Someone may be pretending to "
                       "be the host; not connecting.")
    c2s, s2c = _keys(x25519(c_sk, s_pub), host_id, c_pub, s_pub)
    sock.settimeout(None)
    return E2ESocket(sock, c2s, s2c, peer_key=host_pub)


def server_handshake(sock, host_id, host_secret, timeout=15, host_pub=None):
    """Host agent side. host_secret: the host's 32-byte Ed25519 seed."""
    m = _recv_exact_msg(sock, 7 + 32, timeout)
    if m[:7] != MAGIC + b"C":
        raise E2EError("not an Open Vanilla encrypted stream")
    c_pub = m[7:]
    s_sk, s_pub = keypair()
    host_pub = host_pub or ed25519.public_key(host_secret)
    sig = ed25519.sign(host_secret, _transcript(host_id, c_pub, s_pub))
    sock.send(MAGIC + b"S" + s_pub + host_pub + sig)
    c2s, s2c = _keys(x25519(s_sk, c_pub), host_id, c_pub, s_pub)
    sock.settimeout(None)
    return E2ESocket(sock, s2c, c2s)


def with_e2e_query(url):
    u = urllib.parse.urlsplit(url)
    q = urllib.parse.parse_qsl(u.query)
    if ("e2e", "1") not in q:
        q.append(("e2e", "1"))
    return urllib.parse.urlunsplit((u.scheme, u.netloc, u.path, urllib.parse.urlencode(q), u.fragment))


def connector(host_id, expected_fp, connect=None, timeout=15):
    """A drop-in for ws.connect (url[, headers]) that asks the relay for an e2e stream and does the
    player side of the handshake."""
    if connect is None:
        from . import ws
        connect = ws.connect

    def _connect(url, *a, **kw):
        s = connect(with_e2e_query(url), *a, **kw)
        try:
            return client_handshake(s, host_id, expected_fp, timeout)
        except BaseException:
            s.close()
            raise
    _connect.e2e_fp = expected_fp
    return _connect
