"""The player's local bridge to a relayed realm: the desktop client speaks raw TCP to 127.0.0.1, the
bridge carries each connection over its own WebSocket to the relay.

    b = Bridge(host_id, RELAY_URL, invite="ABCDEFGH23")
    auth_port = b.start()           # 127.0.0.1:<auth_port> is the realmlist; b.world_port is the second port
    creds = b.login(token)          # Open Vanilla sign-in through the host's gate -> {"user","password","realm"}
    b.stop()

The realm list reply (CMD_REALM_LIST, plaintext) is rewritten so every realm's address is
127.0.0.1:<world_port>, which this bridge forwards to the relay's /ws/8085.
"""
import socket
import threading
import urllib.parse

from . import RELAY_URL, HOST_ID_RE, P2PError, realmproto, ws


class Bridge:
    def __init__(self, host_id, relay_url=RELAY_URL, invite=None, connect=ws.connect, bind="127.0.0.1", e2e_fp=None):
        if not HOST_ID_RE.match(host_id or ""):
            raise P2PError("That isn't a realm id.")
        self.host_id, self.relay_url, self.invite = host_id, relay_url.rstrip("/"), invite
        self._connect, self.bind = connect, bind
        self.e2e_fp = e2e_fp
        if e2e_fp:   # every stream is sealed between this PC and the host; the relay sees ciphertext
            from . import e2e
            self._connect = e2e.connector(host_id, e2e_fp, connect)
        self.auth_port = self.world_port = None
        self._socks = []
        self._stop = threading.Event()
        self.bytes_up = self.bytes_down = 0
        self.connections = 0
        self.errors = []

    def url(self, port):
        u = f"{self.relay_url}/h/{self.host_id}/ws/{int(port)}"
        return u + ("?invite=" + urllib.parse.quote(self.invite) if self.invite else "")

    def _listen(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind((self.bind, 0))
        s.listen(16)
        self._socks.append(s)
        return s

    def start(self):
        auth, world = self._listen(), self._listen()
        self.auth_port, self.world_port = auth.getsockname()[1], world.getsockname()[1]
        for s, port in ((auth, 3724), (world, 8085)):
            threading.Thread(target=self._accept_loop, args=(s, port), daemon=True,
                             name=f"bridge-{port}").start()
        return self.auth_port

    def _meter(self, direction, n):
        if direction == "up":
            self.bytes_up += n
        else:
            self.bytes_down += n

    def _accept_loop(self, srv, port):
        while not self._stop.is_set():
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=self._serve, args=(conn, port), daemon=True).start()

    def _serve(self, conn, port):
        self.connections += 1
        try:
            sock = self._connect(self.url(port))
        except (OSError, ValueError) as e:
            self.errors.append(str(e))
            conn.close()
            return
        if port == 3724:
            rw = realmproto.RealmListRewriter(f"127.0.0.1:{self.world_port}")
            ws.pipe(sock, conn, to_ws=rw.client, to_sock=rw.server, meter=self._meter)
        else:
            ws.pipe(sock, conn, meter=self._meter)

    def login(self, token, timeout=20, extra=None):
        """Open Vanilla sign-in through the host's gate on its own relay stream."""
        try:
            sock = self._connect(self.url(3724))
        except OSError as e:
            status = getattr(e, "status", 0)
            if status == 403:
                raise P2PError("This realm is private: you need a valid invite link.") from None
            if status == 404:
                raise P2PError("This realm isn't online right now.") from None
            raise P2PError(f"Couldn't reach the realm through the relay ({e}).") from None
        sock.settimeout(timeout)
        buf = bytearray()

        def recv_exact(n):
            while len(buf) < n:
                m = sock.recv()
                if m is None:
                    raise ConnectionError("the realm closed the connection")
                buf.extend(m if isinstance(m, bytes) else m.encode())
            out = bytes(buf[:n])
            del buf[:n]
            return out

        try:
            return realmproto.login_exchange(sock.send, recv_exact, token, self.invite, extra)
        except (OSError, ValueError) as e:
            raise P2PError(f"The realm didn't accept the sign-in ({e}).") from None
        finally:
            sock.close()

    def stop(self):
        self._stop.set()
        for s in self._socks:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass
        self._socks = []
