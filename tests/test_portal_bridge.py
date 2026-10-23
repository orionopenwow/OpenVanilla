"""The desktop game on a browser realm (no public game ports): launcher/p2p/bridge.py PortalBridge carries
the client's TCP over the realm website's /ws/3724 and /ws/8085 with the launcher token.
    python3 -m unittest tests.test_portal_bridge -v"""
import os
import socket
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "launcher"))
import p2p_fakes as F  # noqa: E402
from p2p import P2PError, bridge, realmproto, ws  # noqa: E402

TOKEN = "tok-123"


class FakeRealmSite:
    """A wenilla-realm stand-in: /ws/3724 answers a realm-list request with a list pointing at its own
    world address; /ws/8085 echoes. A missing or wrong token gets 401, like the session gate."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.seen = []
        threading.Thread(target=self._loop, daemon=True).start()

    def check(self, path, headers):
        self.seen.append((path, headers.get("authorization")))
        if headers.get("authorization") != "Bearer " + TOKEN:
            return 401
        if path not in ("/ws/3724", "/ws/8085"):
            return 403
        return None

    def _loop(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        w, path, _ = ws.server_handshake(c, self.check)
        if not w:
            return
        while True:
            m = w.recv()
            if m is None:
                return
            if path == "/ws/3724" and m[:1] == b"\x10":     # CMD_REALM_LIST
                w.send(F.realm_list_packet())
            else:
                w.send(m)


class PortalBridgeTests(unittest.TestCase):
    def setUp(self):
        self.site = FakeRealmSite()
        self.addCleanup(self.site.sock.close)
        self.portal = f"http://127.0.0.1:{self.site.port}/"

    def test_urls_from_portal(self):
        b = bridge.PortalBridge("https://play.openvanilla.app/", TOKEN)
        self.assertEqual(b.url(3724), "wss://play.openvanilla.app/ws/3724")
        self.assertEqual(b.url(8085), "wss://play.openvanilla.app/ws/8085")

    def test_needs_portal_and_token(self):
        with self.assertRaises(P2PError):
            bridge.PortalBridge("", TOKEN)
        with self.assertRaises(P2PError):
            bridge.PortalBridge("https://play.openvanilla.app/", "")

    def test_check(self):
        self.assertIsNone(bridge.PortalBridge(self.portal, TOKEN).check(timeout=5))
        self.assertIn("Sign in again", bridge.PortalBridge(self.portal, "old").check(timeout=5))
        self.assertTrue(all(a in ("Bearer " + TOKEN, "Bearer old") for _, a in self.site.seen))

    def test_old_realm_without_desktop_relay(self):
        # the token is good (/api/launcher/me says 200) but /ws/* takes cookies only: say so, not "sign in"
        import http.server
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.headers.get("Upgrade", "").lower() == "websocket":
                    self.send_response(401)
                else:
                    self.send_response(200 if self.headers.get("Authorization") == "Bearer " + TOKEN else 401)
                self.send_header("Content-Length", "0")
                self.end_headers()
            def log_message(self, *a):
                pass
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.shutdown)
        portal = f"http://127.0.0.1:{srv.server_port}/"
        self.assertIn("Play in the browser", bridge.PortalBridge(portal, TOKEN).check(timeout=5))
        self.assertIn("Sign in again", bridge.PortalBridge(portal, "old").check(timeout=5))

    def test_realm_list_points_at_bridge_and_world_relays(self):
        b = bridge.PortalBridge(self.portal, TOKEN)
        auth = b.start()
        self.addCleanup(b.stop)
        c = socket.create_connection(("127.0.0.1", auth), timeout=5)
        self.addCleanup(c.close)
        c.sendall(b"\x10\x00\x00\x00\x00")
        head = realmproto.recv_exact(c, 3)
        body = realmproto.recv_exact(c, int.from_bytes(head[1:3], "little"))
        realms, _ = realmproto.parse_realm_list(body)
        self.assertEqual(realms[0]["address"], f"127.0.0.1:{b.world_port}".encode())
        w = socket.create_connection(("127.0.0.1", b.world_port), timeout=5)
        self.addCleanup(w.close)
        w.sendall(b"world bytes")
        self.assertEqual(realmproto.recv_exact(w, 11), b"world bytes")
        self.assertIn(("/ws/3724", "Bearer " + TOKEN), self.site.seen)
        self.assertIn(("/ws/8085", "Bearer " + TOKEN), self.site.seen)


if __name__ == "__main__":
    unittest.main()
