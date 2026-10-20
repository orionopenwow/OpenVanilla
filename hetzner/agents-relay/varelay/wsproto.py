# Copied from Vanilla Agents (vanilla_agents/remote/wsproto.py) by scripts/export_browser_access.py. Change it there, not here.
"""WebSocket (RFC 6455) framing and a small blocking client, standard library only (V-054).

The relay (relay.py) uses the framing with asyncio; the window's bridge (bridge.py) uses Client. Text messages only (JSON),
ping/pong, close; fragmented messages are joined. Nothing here knows what the messages say.
"""
import base64
import hashlib
import os
import socket
import ssl
import struct
import threading
from urllib.parse import urlsplit

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_MESSAGE = 4 * 1024 * 1024
TEXT, BINARY, CLOSE, PING, PONG, CONT = 0x1, 0x2, 0x8, 0x9, 0xA, 0x0


class Closed(Exception):
    pass


def accept_value(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")


def encode(opcode, payload, mask):
    """One final frame. Clients must mask, servers must not."""
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    n = len(payload)
    head = bytes([0x80 | opcode])
    mbit = 0x80 if mask else 0
    if n < 126:
        head += bytes([mbit | n])
    elif n < 65536:
        head += bytes([mbit | 126]) + struct.pack(">H", n)
    else:
        head += bytes([mbit | 127]) + struct.pack(">Q", n)
    if not mask:
        return head + payload
    m = os.urandom(4)
    return head + m + _xor(payload, m)


def _xor(data, m):
    if not data:
        return b""
    big = (m * (len(data) // 4 + 1))[:len(data)]
    return (int.from_bytes(data, "big") ^ int.from_bytes(big, "big")).to_bytes(len(data), "big")


def parse_head(b2):
    """(fin, opcode, masked, length code) from the first two bytes."""
    return bool(b2[0] & 0x80), b2[0] & 0x0F, bool(b2[1] & 0x80), b2[1] & 0x7F


class Assembler:
    """Joins frames into messages. feed(fin, opcode, payload) -> ('text'|'ping'|'pong'|'close', data) or None (needs more)."""
    def __init__(self, limit=MAX_MESSAGE):
        self.parts, self.size, self.limit = None, 0, limit

    def feed(self, fin, op, payload):
        if op in (CLOSE, PING, PONG):
            if not fin or len(payload) > 125:
                raise Closed("bad control frame")
            return ({CLOSE: "close", PING: "ping", PONG: "pong"}[op], payload)
        if op in (TEXT, BINARY):
            if self.parts is not None:
                raise Closed("new message before the last one ended")
            self.parts, self.size = [], 0
        elif op == CONT:
            if self.parts is None:
                raise Closed("continuation without a message")
        else:
            raise Closed("unknown opcode")
        self.size += len(payload)
        if self.size > self.limit:
            raise Closed("message too big")
        self.parts.append(payload)
        if not fin:
            return None
        data, self.parts = b"".join(self.parts), None
        return ("text", data.decode("utf-8"))


class Client:
    """Blocking client. recv() from one thread, send() from any (a lock keeps frames whole)."""
    def __init__(self, url, timeout=15, context=None, headers=None):
        u = urlsplit(url)
        if u.scheme not in ("ws", "wss") or not u.hostname:
            raise ValueError("the relay address must start with ws:// or wss://")
        port = u.port or (443 if u.scheme == "wss" else 80)
        raw = socket.create_connection((u.hostname, port), timeout=timeout)
        if u.scheme == "wss":
            raw = (context or ssl.create_default_context()).wrap_socket(raw, server_hostname=u.hostname)
        self.sock, self.lock, self.asm = raw, threading.Lock(), Assembler()
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        path = (u.path or "/") + ("?" + u.query if u.query else "")
        host = u.hostname + ("" if u.port in (None, 80, 443) else ":%d" % u.port)
        extra = "".join("%s: %s\r\n" % kv for kv in (headers or {}).items())
        raw.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                     "Sec-WebSocket-Version: 13\r\nUser-Agent: vanilla-agents\r\n%s\r\n" % (path, host, key, extra)).encode("ascii"))
        head = b""
        while b"\r\n\r\n" not in head:
            c = raw.recv(1)
            if not c or len(head) > 16384:
                raise Closed("the relay closed the connection during the handshake")
            head += c
        lines = head.decode("latin-1").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise Closed("the relay refused the connection (%s)" % lines[0][:80])
        hdr = {k.strip().lower(): v.strip() for k, _, v in (ln.partition(":") for ln in lines[1:] if ":" in ln)}
        if hdr.get("sec-websocket-accept") != accept_value(key):
            raise Closed("the relay's handshake answer is wrong")
        raw.settimeout(None)

    def _read(self, n):
        out = b""
        while len(out) < n:
            c = self.sock.recv(n - len(out))
            if not c:
                raise Closed("connection closed")
            out += c
        return out

    def recv(self):
        """The next text message (str). Answers pings itself; raises Closed when the connection ends."""
        while True:
            fin, op, masked, ln = parse_head(self._read(2))
            if ln == 126:
                ln = struct.unpack(">H", self._read(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._read(8))[0]
            if ln > MAX_MESSAGE:
                raise Closed("frame too big")
            m = self._read(4) if masked else None
            payload = self._read(ln)
            if m:
                payload = _xor(payload, m)
            got = self.asm.feed(fin, op, payload)
            if got is None or got[0] == "pong":
                continue
            if got[0] == "ping":
                self._send(PONG, got[1])
                continue
            if got[0] == "close":
                try:
                    self._send(CLOSE, b"")
                except OSError:
                    pass
                raise Closed("closed by the relay")
            return got[1]

    def _send(self, op, payload):
        with self.lock:
            self.sock.sendall(encode(op, payload, mask=True))

    def send(self, text):
        self._send(TEXT, text)

    def ping(self):
        self._send(PING, b"")

    def close(self):
        try:
            self._send(CLOSE, b"")
        except OSError:
            pass
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
