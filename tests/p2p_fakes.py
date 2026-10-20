"""Fakes for the P2P tests: a relay speaking the brief's protocol (built on p2p.ws), a realmd that
answers challenges and realm lists, a tiny HTTP server, and key helpers."""
import http.server
import json
import os
import queue
import socket
import struct
import sys
import threading
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))
sys.path.insert(0, ROOT)

import ed25519  # noqa: E402
from p2p import paseto, realmproto, ws  # noqa: E402

SEED = bytes(range(32))
PUB = ed25519.public_key(SEED)
KID = "k1"


def keys():
    return {KID: PUB}


def token(aud, sub="12345", exp_in=300, now=None, jti=None, **extra):
    import time
    now = now or time.time()
    claims = {"sub": sub, "name": "Tester", "roles": [], "aud": aud, "iat": int(now), "exp": int(now + exp_in),
              "jti": jti or os.urandom(8).hex()}
    claims.update(extra)
    return paseto.sign(SEED, claims, kid=KID)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class HTTPServer:
    """routes: {(method, path): fn(handler, body) -> (status, bytes, headers)} or static {path: bytes}."""

    def __init__(self, routes=None, files=None):
        self.routes, self.files, self.requests = routes or {}, files or {}, []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _do(self, method):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                path = urllib.parse.urlsplit(self.path).path
                outer.requests.append((method, self.path, dict(self.headers), body))
                fn = outer.routes.get((method, path))
                if fn:
                    status, data, headers = fn(self, body)
                elif method == "GET" and path in outer.files:
                    data = outer.files[path]
                    rng = self.headers.get("Range")
                    if rng:
                        start = int(rng.split("=")[1].split("-")[0])
                        status, data, headers = 206, data[start:], {}
                    else:
                        status, headers = 200, {}
                else:
                    status, data, headers = 404, b"", {}
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self._do("GET")

            def do_POST(self):
                self._do("POST")

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self, path=""):
        return f"http://127.0.0.1:{self.httpd.server_address[1]}{path}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


# ---------------------------------------------------------------- fake realmd

def realm_list_packet(name=b"Test Realm", address=b"203.0.113.9:8085", icon=1):
    return realmproto.build_realm_list([{"icon": icon, "flags": 0, "name": name, "address": address,
                                         "population": 0.5, "chars": 2, "category": 1, "unk": 0}])


class FakeRealmd:
    """Answers a challenge with WOW_FAIL_UNKNOWN_ACCOUNT-ish 3 bytes + junk and 0x10 with a list."""

    def __init__(self, bind="127.0.0.1", address=b"203.0.113.9:8085"):
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((bind, 0))
        self.sock.listen(16)
        self.port = self.sock.getsockname()[1]
        self.address = address
        self.seen = []
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        try:
            while True:
                cmd = c.recv(1)
                if not cmd:
                    break
                if cmd == b"\x00":
                    rest = realmproto.recv_exact(c, 3)
                    size = struct.unpack("<H", rest[1:3])[0]
                    body = realmproto.recv_exact(c, size)
                    self.seen.append(("challenge", body))
                    c.sendall(b"\x00\x00\x04")
                elif cmd == b"\x10":
                    realmproto.recv_exact(c, 4)
                    self.seen.append(("list", None))
                    pkt = realm_list_packet(address=self.address)
                    c.sendall(pkt[:5])        # split on purpose: the rewriter must buffer
                    c.sendall(pkt[5:])
                else:
                    self.seen.append(("other", cmd))
                    c.sendall(b"echo:" + cmd + c.recv(100))
        except OSError:
            pass
        finally:
            c.close()

    def close(self):
        self.sock.close()


# ---------------------------------------------------------------- fake relay

class FakeRelay:
    """wss://relay contract over plain ws://127.0.0.1:<port>."""

    def __init__(self, tokens=None, private=()):
        self.tokens = tokens if tokens is not None else {}   # host_id -> directory token
        self.private = set(private)
        self.agents = {}            # host_id -> control ws
        self.pending = {}           # stream id -> queue for the agent's data ws
        self.replies = {}           # stream id -> queue for invite replies
        self.control_log = []
        self.next_id = 100
        self.lock = threading.Lock()
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(64)
        self.port = self.sock.getsockname()[1]
        self.url = f"ws://127.0.0.1:{self.port}"
        self.agent_connected = threading.Event()
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _auth(self, headers):
        hid = headers.get("x-host-id", "")
        tok = headers.get("authorization", "")
        return hid if hid in self.tokens and tok == "Bearer " + self.tokens[hid] else None

    def _check(self, path, headers):
        u = urllib.parse.urlsplit(path)
        if u.path.startswith("/agent"):
            return None if self._auth(headers) else 403
        parts = u.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "h" and parts[2] == "ws" and parts[3] in ("3724", "8085"):
            return None if parts[1] in self.agents else 404
        return 404

    def _serve(self, c):
        sock, path, headers = ws.server_handshake(c, self._check)
        if sock is None:
            return
        u = urllib.parse.urlsplit(path)
        if u.path == "/agent":
            hid = self._auth(headers)
            self.agents[hid] = sock
            self.agent_connected.set()
            while True:
                m = sock.recv()
                if m is None:
                    break
                msg = json.loads(m)
                self.control_log.append(msg)
                for k in ("invite_ok", "invite_no"):
                    if k in msg and msg[k] in self.replies:
                        self.replies[msg[k]].put(k)
            self.agents.pop(hid, None)
        elif u.path.startswith("/agent/stream/"):
            sid = u.path.rsplit("/", 1)[1]
            q = self.pending.get(sid)
            if q:
                q.put(sock)
        else:
            parts = u.path.strip("/").split("/")
            hid, port = parts[1], int(parts[3])
            with self.lock:
                self.next_id += 1
                sid = str(self.next_id)
            agent = self.agents.get(hid)
            if hid in self.private:
                inv = urllib.parse.parse_qs(u.query).get("invite", [""])[0]
                self.replies[sid] = queue.Queue()
                agent.send(json.dumps({"invite_check": inv, "stream": sid}))
                try:
                    ans = self.replies[sid].get(timeout=5)
                except queue.Empty:
                    ans = "invite_no"
                if ans != "invite_ok":
                    sock.close()
                    return
            self.pending[sid] = queue.Queue()
            agent.send(json.dumps({"open": int(sid), "port": port}))
            try:
                other = self.pending[sid].get(timeout=10)
            except queue.Empty:
                sock.close()
                return
            pump(sock, other)

    def send_control(self, hid, obj):
        self.agents[hid].send(json.dumps(obj))

    def close(self):
        self.sock.close()
        for a in list(self.agents.values()):
            a.close()


def pump(a, b):
    def one(x, y):
        while True:
            m = x.recv()
            if m is None:
                break
            try:
                y.send(m)
            except OSError:
                break
        x.close()
        y.close()
    t = threading.Thread(target=one, args=(b, a), daemon=True)
    t.start()
    one(a, b)
    t.join(5)


def fresh_pins(tc):
    """A private host-key pin file for one test (join's TOFU store)."""
    import tempfile
    d = tempfile.mkdtemp(prefix="pins-")
    old = os.environ.get("OPENVANILLA_PINS_FILE")
    os.environ["OPENVANILLA_PINS_FILE"] = os.path.join(d, "pins.json")
    tc.addCleanup(lambda: os.environ.__setitem__("OPENVANILLA_PINS_FILE", old) if old else os.environ.pop("OPENVANILLA_PINS_FILE", None))
    return os.environ["OPENVANILLA_PINS_FILE"]
