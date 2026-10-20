"""A small RFC 6455 WebSocket client (ws:// and wss:// via ssl), standard library only.

    ws = connect("wss://relay.openvanilla.app/agent", headers={"Authorization": "Bearer …"})
    ws.send(b"bytes")          # binary frame;  ws.send("text") is a text frame
    msg = ws.recv()            # bytes, str, or None once the connection is closed
    ws.close()

server_handshake(sock) is the other side (tests and fakes only). pipe(ws, sock) copies bytes
between a WebSocket and a TCP socket in both directions until either side closes.
"""
import base64
import hashlib
import os
import socket
import ssl
import struct
import threading
import urllib.parse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_MESSAGE = 16 << 20

OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


class WebSocketError(OSError):
    pass


def accept_key(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")  # nosec B324 - RFC 6455


class WebSocket:
    def __init__(self, sock, client=True, leftover=b""):
        self.sock = sock
        self.client = client          # clients mask their frames
        self._buf = bytearray(leftover)
        self._send_lock = threading.Lock()
        self.closed = False
        self.close_code = None

    # -- low level
    def _fill(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise WebSocketError("connection closed")
            self._buf += chunk

    def _take(self, n):
        self._fill(n)
        out = bytes(self._buf[:n])
        del self._buf[:n]
        return out

    def _frame(self, opcode, payload):
        head = bytearray([0x80 | opcode])
        mask_bit = 0x80 if self.client else 0
        n = len(payload)
        if n < 126:
            head.append(mask_bit | n)
        elif n < 65536:
            head.append(mask_bit | 126)
            head += struct.pack(">H", n)
        else:
            head.append(mask_bit | 127)
            head += struct.pack(">Q", n)
        if self.client:
            key = os.urandom(4)
            head += key
            payload = _mask(payload, key)
        return bytes(head) + payload

    def _send_frame(self, opcode, payload):
        data = self._frame(opcode, payload)
        with self._send_lock:
            if self.closed and opcode != OP_CLOSE:
                raise WebSocketError("websocket closed")
            self.sock.sendall(data)

    def _read_frame(self):
        b0, b1 = self._take(2)
        fin, opcode = b0 & 0x80, b0 & 0x0F
        masked, n = b1 & 0x80, b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._take(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._take(8))[0]
        if n > MAX_MESSAGE:
            raise WebSocketError("frame too large")
        key = self._take(4) if masked else None
        payload = self._take(n)
        if key:
            payload = _mask(payload, key)
        return bool(fin), opcode, payload

    # -- public
    def send(self, data):
        if isinstance(data, str):
            self._send_frame(OP_TEXT, data.encode("utf-8"))
        else:
            self._send_frame(OP_BIN, bytes(data))

    def ping(self, data=b""):
        self._send_frame(OP_PING, data)

    def recv(self):
        """The next message (bytes or str), or None when the peer closed. Pings are answered."""
        if self.closed:
            return None
        parts, first_op = [], None
        try:
            while True:
                fin, op, payload = self._read_frame()
                if op == OP_PING:
                    try:
                        self._send_frame(OP_PONG, payload)
                    except OSError:
                        pass
                    continue
                if op == OP_PONG:
                    continue
                if op == OP_CLOSE:
                    self.close_code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 1005
                    self._shutdown(reply=True)
                    return None
                if op != OP_CONT:
                    first_op = op
                parts.append(payload)
                if sum(len(p) for p in parts) > MAX_MESSAGE:
                    raise WebSocketError("message too large")
                if fin:
                    data = b"".join(parts)
                    return data.decode("utf-8") if first_op == OP_TEXT else data
        except (OSError, ValueError):
            self._shutdown(reply=False)
            return None

    def _shutdown(self, reply):
        if not self.closed:
            if reply:
                try:
                    self._send_frame(OP_CLOSE, struct.pack(">H", 1000))
                except OSError:
                    pass
            self.closed = True
        try:
            self.sock.close()
        except OSError:
            pass

    def close(self, code=1000):
        if self.closed:
            return
        try:
            self._send_frame(OP_CLOSE, struct.pack(">H", code))
        except OSError:
            pass
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

    def settimeout(self, t):
        self.sock.settimeout(t)


def _mask(payload, key):
    n = len(payload)
    k = (key * (n // 4 + 1))[:n]
    return (int.from_bytes(payload, "little") ^ int.from_bytes(k, "little")).to_bytes(n, "little") if n else b""


def _read_http_head(sock, limit=16384):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise WebSocketError("connection closed during the handshake")
        buf += chunk
        if len(buf) > limit:
            raise WebSocketError("handshake too large")
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        k, _, v = line.partition(":")
        headers[k.strip().lower()] = v.strip()
    return lines[0], headers, rest


def connect(url, headers=None, timeout=15, ssl_context=None):
    """Open a WebSocket. Raises WebSocketError (with the HTTP status) when the server refuses."""
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("ws", "wss"):
        raise ValueError("not a ws:// or wss:// URL: " + url)
    port = u.port or (443 if u.scheme == "wss" else 80)
    sock = socket.create_connection((u.hostname, port), timeout=timeout)
    try:
        if u.scheme == "wss":
            ctx = ssl_context or ssl.create_default_context()
            sock = ctx.wrap_socket(sock, server_hostname=u.hostname)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        path = (u.path or "/") + ("?" + u.query if u.query else "")
        host = u.hostname if u.port in (None, 80, 443) else f"{u.hostname}:{u.port}"
        lines = [f"GET {path} HTTP/1.1", f"Host: {host}", "Upgrade: websocket", "Connection: Upgrade",
                 f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13", "User-Agent: OpenVanilla-Node/1"]
        for k, v in (headers or {}).items():
            if "\r" in str(v) or "\n" in str(v):
                raise ValueError("bad header value")
            lines.append(f"{k}: {v}")
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
        status, h, rest = _read_http_head(sock)
        parts = status.split(" ", 2)
        code = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        if code != 101:
            err = WebSocketError(f"WebSocket refused: {status}")
            err.status = code
            raise err
        if h.get("sec-websocket-accept") != accept_key(key):
            raise WebSocketError("bad Sec-WebSocket-Accept")
        sock.settimeout(None)
        return WebSocket(sock, client=True, leftover=rest)
    except BaseException:
        sock.close()
        raise


def server_handshake(sock, check=None):
    """Server side of the opening handshake. check(path, headers) may return an HTTP status (int)
    to refuse. Returns (WebSocket, path, headers)."""
    request, headers, rest = _read_http_head(sock)
    parts = request.split(" ")
    path = parts[1] if len(parts) > 1 else "/"
    status = check(path, headers) if check else None
    if status:
        sock.sendall(f"HTTP/1.1 {int(status)} Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
        sock.close()
        return None, path, headers
    key = headers.get("sec-websocket-key", "")
    sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept_key(key)}\r\n\r\n").encode("latin-1"))
    return WebSocket(sock, client=False, leftover=rest), path, headers


def pipe(ws, sock, to_ws=None, to_sock=None, meter=None):
    """Copy TCP <-> WebSocket until either side ends; blocks. to_ws/to_sock may transform chunks
    (return bytes); meter(direction, n) counts ("up" = TCP->WS, "down" = WS->TCP)."""
    done = threading.Event()

    def tcp_to_ws():
        try:
            while not done.is_set():
                data = sock.recv(65536)
                if not data:
                    break
                if to_ws:
                    data = to_ws(data)
                if data:
                    ws.send(data)
                    if meter:
                        meter("up", len(data))
        except OSError:
            pass
        finally:
            done.set()
            ws.close()

    t = threading.Thread(target=tcp_to_ws, daemon=True)
    t.start()
    try:
        while not done.is_set():
            msg = ws.recv()
            if msg is None:
                break
            if isinstance(msg, str):
                msg = msg.encode("utf-8")
            if to_sock:
                msg = to_sock(msg)
            if msg:
                sock.sendall(msg)
                if meter:
                    meter("down", len(msg))
    except OSError:
        pass
    finally:
        done.set()
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()
        ws.close()
    t.join(timeout=5)
