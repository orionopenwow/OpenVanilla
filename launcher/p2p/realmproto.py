"""realmd wire bits shared by the directory ping, the bridge and the host's gate.

* logon_challenge(): a valid 1.12.1 (build 5875) AUTH_LOGON_CHALLENGE, e.g. for account PROBE.
* RealmListRewriter: watches one auth connection and rewrites the address of every realm in the
  CMD_REALM_LIST reply (plaintext) to the bridge's own world port.
* The gate's login frames: before any realmd byte, a launcher may send
      b"OWLG" + uint16 length (big-endian) + JSON {"token": "v4.public…", "invite": "CODE"}
  and gets back b"OWLR" + uint16 length + JSON {"ok": true, "user", "password", "realm"} or
  {"ok": false, "error"}. realmd packets start with 0x00/0x01/0x02/0x03/0x10, never 'O', so the
  gate can tell them apart from the first byte.
"""
import json
import socket
import struct
import time

CMD_AUTH_LOGON_CHALLENGE = 0x00
CMD_REALM_LIST = 0x10
LOGIN_MAGIC = b"OWLG"
REPLY_MAGIC = b"OWLR"
MAX_FRAME = 8192


def logon_challenge(account="PROBE", build=5875, ip="127.0.0.1"):
    user = account.upper().encode("ascii")
    body = (b"WoW\x00" + bytes([1, 12, 1]) + struct.pack("<H", build) + b"68x\x00" + b"niW\x00" + b"SUne"
            + struct.pack("<I", 0) + socket.inet_aton(ip) + bytes([len(user)]) + user)
    return bytes([CMD_AUTH_LOGON_CHALLENGE, 3]) + struct.pack("<H", len(body)) + body


def is_challenge_reply(data):
    """realmd answered a challenge: cmd 0, then 0x00, then a result code."""
    return len(data) >= 3 and data[0] == CMD_AUTH_LOGON_CHALLENGE and data[1] == 0


def recv_exact(sock, n):
    out = b""
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise ConnectionError("closed")
        out += chunk
    return out


def tcp_ping(host, port, timeout=3.0, clock=time.perf_counter):
    """Milliseconds for a realmd challenge round trip (connect excluded), or None."""
    try:
        with socket.create_connection((host, int(port)), timeout=timeout) as s:
            s.settimeout(timeout)
            t0 = clock()
            s.sendall(logon_challenge())
            reply = recv_exact(s, 3)
            ms = (clock() - t0) * 1000
            return int(round(ms)) if is_challenge_reply(reply) else None
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------- realm list

def parse_realm_list(body):
    """body = the packet after cmd + uint16 size. -> (realms, tail). Build 5875 layout."""
    pos = 4  # uint32 unused
    count = body[pos]
    pos += 1
    realms = []
    for _ in range(count):
        icon, flags = struct.unpack_from("<IB", body, pos)
        pos += 5
        end = body.index(b"\x00", pos)
        name = body[pos:end]
        pos = end + 1
        end = body.index(b"\x00", pos)
        address = body[pos:end]
        pos = end + 1
        pop, chars, cat, unk = struct.unpack_from("<fBBB", body, pos)
        pos += 7
        realms.append({"icon": icon, "flags": flags, "name": name, "address": address, "population": pop,
                       "chars": chars, "category": cat, "unk": unk})
    return realms, body[pos:]


def build_realm_list(realms, tail=b"\x02\x00", head=b"\x00\x00\x00\x00"):
    body = bytearray(head) + bytes([len(realms)])
    for r in realms:
        body += struct.pack("<IB", r["icon"], r["flags"]) + r["name"] + b"\x00" + r["address"] + b"\x00"
        body += struct.pack("<fBBB", r["population"], r["chars"], r["category"], r["unk"])
    body += tail
    return bytes([CMD_REALM_LIST]) + struct.pack("<H", len(body)) + bytes(body)


class RealmListRewriter:
    """One auth connection. client(data) sees client->server bytes; server(data) returns what to
    forward to the client. After the client asks for the realm list (0x10), the next server packet
    is the list: it is buffered whole and every realm's address becomes `address`."""

    def __init__(self, address):
        self.address = address.encode("ascii")
        self.expect = False
        self.buf = b""

    def client(self, data):
        if data[:1] == bytes([CMD_REALM_LIST]):
            self.expect = True
        return data

    def server(self, data):
        if not self.expect:
            return data
        self.buf += data
        if len(self.buf) < 3:
            return b""
        if self.buf[0] != CMD_REALM_LIST:
            out, self.buf, self.expect = self.buf, b"", False
            return out
        size = struct.unpack_from("<H", self.buf, 1)[0]
        if len(self.buf) < 3 + size:
            return b""
        packet, rest = self.buf[:3 + size], self.buf[3 + size:]
        self.buf, self.expect = b"", False
        try:
            realms, tail = parse_realm_list(packet[3:])
            for r in realms:
                r["address"] = self.address
            packet = build_realm_list(realms, tail, packet[3:7])
        except (IndexError, ValueError, struct.error):
            pass  # not a list we understand: pass it on untouched
        return packet + rest


# ---------------------------------------------------------------- the gate's login frames

def encode_frame(magic, obj):
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_FRAME:
        raise ValueError("frame too large")
    return magic + struct.pack(">H", len(data)) + data


def decode_frame_body(raw):
    obj = json.loads(raw.decode("utf-8"))
    if not isinstance(obj, dict):
        raise ValueError("not an object")
    return obj


def login_exchange(send, recv_exact_fn, token, invite=None, extra=None):
    """Client side: send the login frame, read the reply dict. send(bytes), recv_exact_fn(n).
    extra: more request fields ({"guest", "name", "nonce"})."""
    payload = {"token": token} if token else {}
    if invite:
        payload["invite"] = invite
    payload.update(extra or {})
    send(encode_frame(LOGIN_MAGIC, payload))
    head = recv_exact_fn(6)
    if head[:4] != REPLY_MAGIC:
        raise ValueError("this realm doesn't take Open Vanilla sign-in")
    n = struct.unpack(">H", head[4:6])[0]
    return decode_frame_body(recv_exact_fn(n))
