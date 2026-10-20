"""p2p building blocks: WebSocket, realmd wire bits, PASETO, invites, SOAP, firewall, UPnP/NAT-PMP,
directory.    python3 -m unittest tests.test_p2p_proto -v"""
import json
import os
import shutil
import socket
import struct
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p2p_fakes as F  # noqa: E402
from p2p import P2PError, directory, firewall, invites, paseto, realmproto, soap, upnp, ws  # noqa: E402
import ed25519  # noqa: E402


class WSServer:
    """Echo server: echoes messages back; 'close' closes; 'ping' sends a ping first."""

    def __init__(self, check=None):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.check = check
        self.headers = []
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        w, path, headers = ws.server_handshake(c, self.check)
        if not w:
            return
        self.headers.append((path, headers))
        while True:
            m = w.recv()
            if m is None:
                return
            if m == "close":
                w.close()
                return
            if m == "ping":
                w.ping(b"x")
            if m == "frag":   # a fragmented text message from the server
                w.sock.sendall(bytes([0x01, 3]) + b"abc" + bytes([0x80, 3]) + b"def")
                continue
            w.send(m)


class WebSocketTests(unittest.TestCase):
    def setUp(self):
        self.srv = WSServer()
        self.addCleanup(self.srv.sock.close)

    def test_roundtrip_sizes_and_types(self):
        c = ws.connect(f"ws://127.0.0.1:{self.srv.port}/path?q=1", headers={"Authorization": "Bearer t"})
        for payload in (b"", b"x", os.urandom(125), os.urandom(126), os.urandom(70000), "text ü"):
            c.send(payload)
            self.assertEqual(c.recv(), payload)
        self.assertEqual(self.srv.headers[0][0], "/path?q=1")
        self.assertEqual(self.srv.headers[0][1]["authorization"], "Bearer t")
        c.close()

    def test_ping_is_answered_and_fragments_join(self):
        c = ws.connect(f"ws://127.0.0.1:{self.srv.port}/")
        c.send("ping")
        self.assertEqual(c.recv(), "ping")
        c.send("frag")
        self.assertEqual(c.recv(), "abcdef")
        c.send("close")
        self.assertIsNone(c.recv())
        self.assertTrue(c.closed)

    def test_refused_handshake_has_status(self):
        srv = WSServer(check=lambda p, h: 403)
        self.addCleanup(srv.sock.close)
        with self.assertRaises(ws.WebSocketError) as cm:
            ws.connect(f"ws://127.0.0.1:{srv.port}/x")
        self.assertEqual(cm.exception.status, 403)

    def test_mask(self):
        data = os.urandom(1001)
        self.assertEqual(ws._mask(ws._mask(data, b"abcd"), b"abcd"), data)

    def test_pipe_tcp(self):
        a, b = socket.socketpair()
        c = ws.connect(f"ws://127.0.0.1:{self.srv.port}/")
        seen = []
        t = threading.Thread(target=ws.pipe, args=(c, b), kwargs={"meter": lambda d, n: seen.append((d, n))}, daemon=True)
        t.start()
        a.sendall(b"hello")
        self.assertEqual(realmproto.recv_exact(a, 5), b"hello")
        a.close()
        t.join(5)
        self.assertFalse(t.is_alive())
        self.assertIn(("up", 5), seen)
        self.assertIn(("down", 5), seen)


class RealmProtoTests(unittest.TestCase):
    def test_challenge_shape(self):
        p = realmproto.logon_challenge("probe")
        self.assertEqual(p[0], 0)
        self.assertEqual(struct.unpack("<H", p[2:4])[0], len(p) - 4)
        self.assertEqual(struct.unpack("<H", p[11:13])[0], 5875)
        self.assertTrue(p.endswith(b"\x05PROBE"))

    def test_realm_list_roundtrip_and_rewrite(self):
        pkt = F.realm_list_packet()
        realms, tail = realmproto.parse_realm_list(pkt[3:])
        self.assertEqual(realms[0]["name"], b"Test Realm")
        self.assertEqual(tail, b"\x02\x00")
        self.assertEqual(realmproto.build_realm_list(realms, tail), pkt)
        rw = realmproto.RealmListRewriter("127.0.0.1:5555")
        self.assertEqual(rw.server(b"\x00\x00\x04"), b"\x00\x00\x04")    # before the request: untouched
        rw.client(b"\x10\x00\x00\x00\x00")
        out = b""
        for i in range(0, len(pkt), 4):                                   # arrives in pieces
            out += rw.server(pkt[i:i + 4])
        r2, _ = realmproto.parse_realm_list(out[3:])
        self.assertEqual(r2[0]["address"], b"127.0.0.1:5555")
        self.assertEqual(r2[0]["name"], b"Test Realm")
        self.assertEqual(struct.unpack("<H", out[1:3])[0], len(out) - 3)
        self.assertEqual(rw.server(b"more"), b"more")

    def test_tcp_ping_against_fake_realmd(self):
        r = F.FakeRealmd()
        self.addCleanup(r.close)
        ms = realmproto.tcp_ping("127.0.0.1", r.port)
        self.assertIsNotNone(ms)
        self.assertIsNone(realmproto.tcp_ping("127.0.0.1", F.free_port(), timeout=1))

    def test_login_frames(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        def server():
            head = realmproto.recv_exact(b, 6)
            req = realmproto.decode_frame_body(realmproto.recv_exact(b, struct.unpack(">H", head[4:])[0]))
            b.sendall(realmproto.encode_frame(realmproto.REPLY_MAGIC, {"ok": True, "got": req}))
        threading.Thread(target=server, daemon=True).start()
        reply = realmproto.login_exchange(a.sendall, lambda n: realmproto.recv_exact(a, n), "tok", "CODE")
        self.assertEqual(reply["got"], {"token": "tok", "invite": "CODE"})


class PasetoTests(unittest.TestCase):
    def setUp(self):
        self.now = 1_800_000_000
        self.v = paseto.TokenVerifier(F.keys(), "abcdefghijklmnop", clock=lambda: self.now)

    def tok(self, **kw):
        kw.setdefault("now", self.now)
        return F.token(kw.pop("aud", "abcdefghijklmnop"), **kw)

    def test_valid_once(self):
        t = self.tok()
        self.assertEqual(self.v.verify(t)["sub"], "12345")
        with self.assertRaisesRegex(paseto.TokenError, "already used"):
            self.v.verify(t)

    def test_rejections(self):
        cases = [
            (self.tok(aud="zzzzzzzzzzzzzzzz"), "another realm"),
            (self.tok(now=self.now - 1000), "expired"),
            (self.tok(exp_in=3600), "times"),
            (self.tok(roles=["banned"]), "banned"),
            ("v4.local.xxx", "not a v4.public"),
        ]
        for t, why in cases:
            with self.assertRaisesRegex(paseto.TokenError, why):
                self.v.verify(t)
        t = self.tok()
        body, _, footer = t[len("v4.public."):].partition(".")
        raw = bytearray(paseto.b64u_decode(body))
        raw[5] ^= 1
        with self.assertRaisesRegex(paseto.TokenError, "signature"):
            self.v.verify("v4.public." + paseto.b64u_encode(bytes(raw)) + "." + footer)
        other = paseto.sign(bytes(32), {"sub": "1", "aud": "abcdefghijklmnop", "iat": self.now, "exp": self.now + 300,
                                        "jti": "j"}, kid="k1")
        with self.assertRaisesRegex(paseto.TokenError, "signature"):
            self.v.verify(other)

    def test_no_footer_tries_all_keys_and_rfc3339(self):
        t = paseto.sign(F.SEED, {"sub": 7, "aud": "abcdefghijklmnop", "iat": "2027-01-15T08:00:00Z",
                                 "exp": "2027-01-15T08:05:00+00:00", "jti": "x1"})
        v = paseto.TokenVerifier(F.keys(), "abcdefghijklmnop", clock=lambda: 1_800_000_100)
        self.assertEqual(v.verify(t)["sub"], 7)

    def test_official_vector_4_s_1(self):
        sk = bytes.fromhex("b4cbfb43df4ce210727d953e4a713307fa19bb7d9f85041438d9e11b942a3774")
        pk = bytes.fromhex("1eb9dbbbbc047c03fd70604e0071f0987e16b28b757225c11f00415d0e20b1a2")
        tok = ("v4.public.eyJkYXRhIjoidGhpcyBpcyBhIHNpZ25lZCBtZXNzYWdlIiwiZXhwIjoiMjAyMi0wMS0wMVQwMDowMDowMCswMDowMCJ9"
               "bg_XBBzds8lTZShVlwwKSgeKpLT3yukTw6JUz3W4h_ExsQV-P0V54zemZDcAxFaSeef1QlXEFtkqxT1ciiQEDA")
        self.assertEqual(ed25519.public_key(sk), pk)
        claims = {"data": "this is a signed message", "exp": "2022-01-01T00:00:00+00:00"}
        self.assertEqual(paseto.verify_signature(tok, {"any": pk}), claims)
        self.assertEqual(paseto.sign(sk, claims), tok)          # deterministic: byte-identical

    def test_central_format(self):
        # patch 0012: RFC 3339 UTC strings, string sub, footer kid = 16 hex, empty implicit assertion
        kid = "0123456789abcdef"
        claims = {"sub": "42", "name": "N", "roles": [], "aud": "abcdefghijklmnop", "iat": "2027-01-15T08:00:00Z",
                  "exp": "2027-01-15T08:05:00Z", "jti": "a1b2"}
        t = paseto.sign(F.SEED, claims, kid=kid)
        self.assertTrue(t.endswith("." + paseto.b64u_encode(b'{"kid":"0123456789abcdef"}')))
        now = 1_800_000_000 + 0  # before exp
        import datetime
        now = datetime.datetime(2027, 1, 15, 8, 1, tzinfo=datetime.timezone.utc).timestamp()
        v = paseto.TokenVerifier({kid: F.PUB}, "abcdefghijklmnop", clock=lambda: now)
        self.assertEqual(v.verify(t)["sub"], "42")
        late = paseto.TokenVerifier({kid: F.PUB}, "abcdefghijklmnop", clock=lambda: now + 3600)
        with self.assertRaisesRegex(paseto.TokenError, "expired"):
            late.verify(paseto.sign(F.SEED, dict(claims, jti="z"), kid=kid))

    def test_pae_vector(self):
        # From the PASETO spec: PAE([]) and PAE(['']).
        self.assertEqual(paseto.pae(), b"\x00" * 8)
        self.assertEqual(paseto.pae(b""), b"\x01" + b"\x00" * 15)

    def test_key_cache_and_rotation(self):
        calls = []
        body = json.dumps({"keys": [{"kid": "k1", "alg": "Ed25519", "x": paseto.b64u_encode(F.PUB)}]}).encode()
        def fetch(u):
            calls.append(u)
            return 200, body
        t = [0]
        kc = paseto.KeyCache("https://x/.well-known/openvanilla-keys.json", fetch=fetch, clock=lambda: t[0])
        self.assertEqual(kc.get(), {"k1": F.PUB})
        kc.get()
        self.assertEqual(len(calls), 1)
        t[0] = 30
        kc.refresh(force=True)
        self.assertEqual(len(calls), 1)          # forced at most once a minute
        t[0] = 100
        kc.refresh(force=True)
        self.assertEqual(len(calls), 2)
        v = paseto.TokenVerifier(kc, "abcdefghijklmnop", clock=lambda: 1_800_000_000)
        self.assertTrue(v.verify(F.token("abcdefghijklmnop", now=1_800_000_000)))

    def test_revocation_list(self):
        body = json.dumps({"updated": 5, "sub": ["12345"]}).encode()
        sig = ed25519.sign(F.SEED, body)
        resp = [200, body, {"X-OpenVanilla-Signature": sig.hex(), "X-OpenVanilla-Kid": "k1"}]
        rl = paseto.RevocationList("https://x/api/identity/revoked", F.keys(), fetch=lambda u: tuple(resp))
        self.assertTrue(rl.poll(force=True))
        self.assertTrue(rl.is_revoked("12345"))
        v = paseto.TokenVerifier(F.keys(), "abcdefghijklmnop", clock=lambda: 1_800_000_000, revoked=rl)
        with self.assertRaisesRegex(paseto.TokenError, "banned"):
            v.verify(F.token("abcdefghijklmnop", now=1_800_000_000))
        resp[2] = {"X-OpenVanilla-Signature": paseto.b64u_encode(sig)}      # base64url, no kid
        self.assertTrue(rl.poll(force=True))
        resp[1] = json.dumps({"updated": 6, "sub": []}).encode()          # tampered: old list kept
        self.assertFalse(rl.poll(force=True))
        self.assertTrue(rl.is_revoked("12345"))


class InviteTests(unittest.TestCase):
    def test_store(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        t = [1000.0]
        s = invites.InviteStore(os.path.join(tmp, "inv.json"), clock=lambda: t[0])
        code = s.create(uses=2, hours=1)
        self.assertRegex(code, r"^[A-Z2-7]{10}$")
        self.assertTrue(s.check(code) and s.check(code.lower()))
        self.assertTrue(s.consume(code))
        self.assertTrue(s.consume(code))
        self.assertFalse(s.consume(code))
        c2 = s.create(1, 1)
        t[0] += 3601
        self.assertFalse(s.check(c2))
        s2 = invites.InviteStore(os.path.join(tmp, "inv.json"), clock=lambda: t[0])
        self.assertEqual(s2.data[code]["used"], 2)
        self.assertTrue(s2.revoke(c2))
        with self.assertRaises(P2PError):
            s.create(0, 1)

    def test_links(self):
        link = invites.make_link("abcdefghijklmnop", "ABCDE23456", "Stormwind Nights")
        self.assertEqual(link, "openvanilla://join/abcdefghijklmnop?i=ABCDE23456&n=Stormwind%20Nights")
        self.assertEqual(invites.parse_link(link), ("abcdefghijklmnop", "ABCDE23456", "Stormwind Nights"))
        self.assertEqual(invites.parse_link(invites.https_link("abcdefghijklmnop", "ABCDE23456")),
                         ("abcdefghijklmnop", "ABCDE23456", None))
        self.assertIsNone(invites.parse_link("openvanilla://join/../../x"))
        self.assertIsNone(invites.parse_link("https://evil/join/ABC"))
        self.assertEqual(invites.parse_link("openvanilla://join/abcdefghijklmnop?i=bad")[1], None)


class SoapTests(unittest.TestCase):
    def test_commands_checked(self):
        sent = []
        s = soap.Soap("ADMIN", "pw", 7878, send=lambda c: sent.append(c) or "ok")
        s.create_account("OWABC", "PASS1234")
        s.kick("Thrall")
        s.ban("Thrall", "griefing <b>")
        s.announce("Restart\nsoon")
        self.assertEqual(sent, ["account create OWABC PASS1234", "kick Thrall", "ban character Thrall -1 griefing b",
                                "announce Restartsoon"])
        for bad in ("a b", "x;y", "", "Thrall2"):
            with self.assertRaises(P2PError):
                s.kick(bad)
        with self.assertRaises(ValueError):
            s.create_account("ow abc", "x")
        self.assertRegex(soap.random_password(), r"^[A-Z2-9]{16}$")


class FirewallTests(unittest.TestCase):
    def test_netsh(self):
        calls = []
        def run(argv):
            calls.append(argv)
            class R:
                returncode = 0 if "add" in argv else 1
            return R()
        self.assertEqual(firewall.add_rules([3724, 8085], run, windows=True), {3724: True, 8085: True})
        adds = [c for c in calls if "add" in c]
        self.assertEqual(len(adds), 2)
        self.assertIn("localport=3724", adds[0])
        self.assertIn("name=Open Vanilla Host TCP 3724", adds[0])
        calls.clear()
        firewall.remove_rules([3724], run, windows=True)
        self.assertEqual(calls[0][:5], ["netsh", "advfirewall", "firewall", "delete", "rule"])
        self.assertEqual(firewall.add_rules([1], run, windows=False), {1: True})


IGD_XML = b"""<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceList><device>
<deviceList><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
<controlURL>/ctl/IPConn</controlURL></service></serviceList></device></deviceList></device></deviceList></device></root>"""


class UPnPTests(unittest.TestCase):
    def test_upnp_map_unmap(self):
        actions = []

        def ctl(h, body):
            action = h.headers["SOAPAction"].split("#")[1].strip('"')
            actions.append((action, body.decode()))
            if action == "GetExternalIPAddress":
                return 200, b"<r><NewExternalIPAddress>198.51.100.7</NewExternalIPAddress></r>", {}
            return 200, b"<ok/>", {}
        srv = F.HTTPServer({("GET", "/desc.xml"): lambda h, b: (200, IGD_XML, {}), ("POST", "/ctl/IPConn"): ctl})
        self.addCleanup(srv.close)
        m = upnp.PortMapper(consent=True, discover=lambda: [srv.url("/desc.xml")], gateway=lambda: None,
                            local_ip=lambda gw: "192.168.1.20")
        self.assertEqual(m.map([3724, 8085]), ("upnp", "198.51.100.7"))
        adds = [b for a, b in actions if a == "AddPortMapping"]
        self.assertEqual(len(adds), 2)
        self.assertIn("<NewInternalClient>192.168.1.20</NewInternalClient>", adds[0])
        self.assertIn("<NewExternalPort>3724</NewExternalPort>", adds[0])
        m.unmap()
        self.assertEqual(sum(1 for a, _ in actions if a == "DeletePortMapping"), 2)

    def test_no_consent_does_nothing(self):
        m = upnp.PortMapper(consent=False, discover=lambda: self.fail("must not discover"))
        self.assertEqual(m.map([3724]), (None, None))

    def test_natpmp_fallback(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        self.addCleanup(s.close)
        got = []

        def serve():
            while True:
                try:
                    data, addr = s.recvfrom(64)
                except OSError:
                    return
                got.append(data)
                if data[1] == 0:
                    s.sendto(struct.pack(">BBHI", 0, 128, 0, 1) + socket.inet_aton("198.51.100.8"), addr)
                else:
                    _, op, _, priv, pub, life = struct.unpack(">BBHHHI", data)
                    s.sendto(struct.pack(">BBHIHHI", 0, 130, 0, 1, priv, pub, life), addr)
        threading.Thread(target=serve, daemon=True).start()
        m = upnp.PortMapper(consent=True, discover=lambda: [], gateway=lambda: "127.0.0.1",
                            natpmp_port=s.getsockname()[1])
        self.assertEqual(m.map([3724, 8085]), ("natpmp", "198.51.100.8"))
        m.unmap()
        lifetimes = [struct.unpack(">BBHHHI", d)[5] for d in got if d[1] == 2]
        self.assertEqual(lifetimes, [3600, 3600, 0, 0])

    def test_is_public(self):
        self.assertTrue(upnp.is_public("8.8.8.8"))
        for ip in ("10.0.0.1", "100.64.1.1", "192.168.0.1", "bad"):
            self.assertFalse(upnp.is_public(ip))


class DirectoryTests(unittest.TestCase):
    DATA = {"servers": [
        {"name": "Big", "host": "a.example", "port": 3724, "tags": ["community", "PvP", "Classic+"], "population": 40,
         "last_seen": 5, "host_id": "abcdefghijklmnop", "relay": False, "verified": True},
        {"name": "Relayed", "host": "relay.openvanilla.app", "port": 443, "type": "rp", "population": 3,
         "host_id": "bbbbbbbbbbbbbbbb", "relay": True, "template": "vanilla"},
        {"name": "Hidden", "host": "x", "port": 1, "visibility": "private"},
        {"name": "", "host": "x"}, "junk",
        {"name": "Official", "host": "play.openvanilla.app", "port": 3724, "tags": ["official"], "official": True}],
        "updated": 9}

    def test_parse(self):
        rs = directory.parse(self.DATA)
        self.assertEqual([r.name for r in rs], ["Official", "Big", "Relayed"])
        big = rs[1]
        self.assertEqual((big.type, big.template, big.verified, big.relay), ("pvp", "classicplus", True, False))
        rel = rs[2]
        self.assertEqual((rel.type, rel.template, rel.relay, rel.host_id), ("rp", "vanilla", True, "bbbbbbbbbbbbbbbb"))

    def test_fetch_ping_report(self):
        realmd = F.FakeRealmd()
        self.addCleanup(realmd.close)
        data = json.loads(json.dumps(self.DATA))
        data["servers"][0].update(host="127.0.0.1", port=realmd.port)
        reports = []
        srv = F.HTTPServer({("GET", "/api/directory"): lambda h, b: (200, json.dumps(data).encode(), {}),
                            ("POST", "/api/directory/report"): lambda h, b: (reports.append((h.headers["Authorization"], json.loads(b))) or 201, b"{}", {})})
        self.addCleanup(srv.close)
        rs = directory.fetch(srv.url("/api/directory"))
        big = next(r for r in rs if r.name == "Big")
        self.assertIsNotNone(directory.ping(big))
        self.assertIsNotNone(big.ping)
        self.assertTrue(directory.report("abcdefghijklmnop", "spam   name", "LT", central=srv.url()))
        self.assertEqual(reports[0], ("Bearer LT", {"host_id": "abcdefghijklmnop", "reason": "spam name"}))
        with self.assertRaises(P2PError):
            directory.fetch(srv.url("/nope"))


if __name__ == "__main__":
    unittest.main()
