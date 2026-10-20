"""The host agent (gate, sign-in, heartbeat, relay agent) and the player side (bridge, join) against a
fake relay and a fake realmd.    python3 -m unittest tests.test_p2p_host -v"""
import json
import os
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p2p_fakes as F  # noqa: E402
from p2p import P2PError, host, invites, join, realmproto, soap  # noqa: E402
from p2p.bridge import Bridge  # noqa: E402

HOST_ID = "abcdefghijklmnop"
DIR_TOKEN = "d" * 64


class EchoServer:
    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._echo, args=(c,), daemon=True).start()

    @staticmethod
    def _echo(c):
        try:
            while True:
                d = c.recv(4096)
                if not d:
                    break
                c.sendall(d.upper())
        except OSError:
            pass
        c.close()

    def close(self):
        self.sock.close()


class FakeDB:
    def shutdown(self):
        pass

    def __init__(self):
        self.queries = []
        self.answers = {}

    def query(self, sql, db=None):
        self.queries.append((sql, db))
        for k, v in self.answers.items():
            if k in sql:
                return v
        return ""


def wait_for(cond, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return False


class HostHarness:
    """A HostSession (start_servers=False) on free ports, its fakes, and a fake directory."""

    def __init__(self, tc, visibility="public", private_relay=False, register=True, **cfg_extra):
        self.tmp = tempfile.mkdtemp(prefix="p2p-host-")
        F.fresh_pins(tc)
        tc.addCleanup(shutil.rmtree, self.tmp, True)
        self.realmd = F.FakeRealmd()
        tc.addCleanup(self.realmd.close)
        self.world = EchoServer()
        tc.addCleanup(self.world.close)
        self.relay = F.FakeRelay(tokens={HOST_ID: DIR_TOKEN}, private={HOST_ID} if private_relay else ())
        tc.addCleanup(self.relay.close)
        self.central = F.HTTPServer({("GET", "/api/identity/revoked"): lambda h, b: (404, b"", {})})
        tc.addCleanup(self.central.close)
        self.beats = []
        self.register = register
        root = os.path.join(self.tmp, "host")
        os.makedirs(root)
        with open(os.path.join(root, "state.json"), "w") as f:
            json.dump({"ports": {"gate": F.free_port(), "realm": self.realmd.port, "world": self.world.port,
                                 "db": F.free_port(), "soap": F.free_port()}}, f)
        cfg = host.HostConfig(name="Test Realm", type="rp", visibility=visibility, data_dir=root,
                              solo_root=os.path.join(self.tmp, "solo"), **dict(dict(central=self.central.url(), relay=self.relay.url), **cfg_extra))
        self.soap_cmds = []
        self.s = host.HostSession(cfg, lambda *a: None, http_post=self.post, keys=F.keys(), start_servers=False)
        self.s._soap = soap.Soap("A", "B", 1, send=lambda c: self.soap_cmds.append(c) or "ok")
        tc.addCleanup(self.s.stop)

    def post(self, url, payload, headers):
        self.beats.append((url, payload, dict(headers)))
        if not self.register:
            raise OSError("offline")
        if headers.get("Authorization") == "Bearer " + DIR_TOKEN:
            return 200, {"ok": True}
        return 201, {"token": DIR_TOKEN, "ttl": 180, "heartbeat_every": 60, "host_id": HOST_ID}


def realm_client(port, world_port_check=None):
    """Challenge + realm list request against a local auth port; -> (challenge reply, realms)."""
    with socket.create_connection(("127.0.0.1", port), timeout=10) as c:
        c.settimeout(10)
        c.sendall(realmproto.logon_challenge("TESTER"))
        reply = realmproto.recv_exact(c, 3)
        c.sendall(b"\x10\x00\x00\x00\x00")
        head = realmproto.recv_exact(c, 3)
        body = realmproto.recv_exact(c, struct.unpack("<H", head[1:])[0])
        return reply, realmproto.parse_realm_list(body)[0]


class HostRelayJoinTests(unittest.TestCase):
    def test_public_realm_through_relay(self):
        h = HostHarness(self)
        st = h.s.start()
        self.assertEqual(st["host_id"], HOST_ID)
        self.assertTrue(wait_for(lambda: h.s.agent and h.s.agent.connected))
        self.assertEqual(h.s.reachability, "relay")
        beat = h.beats[0][1]
        self.assertEqual((beat["relay"], beat["visibility"], beat["template"], beat["region"], beat["build"]),
                         (True, "public", "classicplus", "us", 5875))
        self.assertNotIn("host", beat)
        self.assertNotIn("port", beat)
        self.assertIn("Classic+", beat["tags"])
        self.assertEqual(beat["type"], "rp")

        launched = {}
        s = join.join(join.Realm(name="Test Realm", host="relay", relay=True, host_id=HOST_ID),
                      lambda env, rl: launched.update(env=env, rl=rl),
                      token_provider=lambda aud: F.token(aud), relay_url=h.relay.url)
        self.addCleanup(s.stop)
        self.assertEqual(s.creds["user"], host.account_for("12345"))
        self.assertRegex(s.creds["password"], r"^[A-Z2-9]{16}$")
        self.assertEqual(launched["env"]["WOW_USER"], s.creds["user"])
        self.assertEqual(launched["env"]["WOW_REALM"], "Test Realm")
        self.assertEqual(launched["rl"], f"127.0.0.1:{s.bridge.auth_port}")
        self.assertEqual(h.soap_cmds, [f"account create {s.creds['user']} {s.creds['password']}"])

        reply, realms = realm_client(s.bridge.auth_port)
        self.assertEqual(reply, b"\x00\x00\x04")
        self.assertEqual(realms[0]["address"], f"127.0.0.1:{s.bridge.world_port}".encode())
        # the world port goes through the relay to mangosd's port (an upper-casing echo here)
        with socket.create_connection(("127.0.0.1", s.bridge.world_port), timeout=10) as c:
            c.settimeout(10)
            c.sendall(b"hello world")
            self.assertEqual(realmproto.recv_exact(c, 11), b"HELLO WORLD")
        self.assertTrue(wait_for(lambda: h.s.meter.up > 0 and h.s.meter.down > 0))

        # second visit: same account, no new SOAP account, token single use
        s2 = join.join(join.Realm(name="Test Realm", host="relay", relay=True, host_id=HOST_ID), lambda env, rl: None,
                       token_provider=lambda aud: F.token(aud), relay_url=h.relay.url)
        self.addCleanup(s2.stop)
        self.assertEqual(s2.creds, s.creds)
        self.assertEqual(len(h.soap_cmds), 1)
        tok = F.token(HOST_ID)
        b = Bridge(HOST_ID, h.relay.url)
        self.assertTrue(b.login(tok)["ok"])
        self.assertIn("already used", b.login(tok)["error"])
        self.assertIn("another realm", b.login(F.token("zzzzzzzzzzzzzzzz"))["error"])

        status = h.s.status()
        for k in ("players", "cpu", "ram", "up_kbps", "down_kbps", "reachability", "listed", "host_id", "running"):
            self.assertIn(k, status)
        self.assertTrue(status["listed"])
        self.assertTrue(status["relay_connected"])

    def test_private_realm_needs_invite(self):
        h = HostHarness(self, visibility="private", private_relay=True)
        h.s.start()
        self.assertTrue(wait_for(lambda: h.s.agent and h.s.agent.connected))
        link = h.s.invite(uses=1, hours=1)
        hid, code, name = invites.parse_link(link)
        self.assertEqual((hid, name), (HOST_ID, "Test Realm"))
        self.assertFalse(h.s.status()["listed"])
        # no invite: the relay asks the agent, the agent says no
        with self.assertRaises(P2PError):
            join.join(f"openvanilla://join/{HOST_ID}", lambda e, r: None, token_provider=lambda a: F.token(a),
                      relay_url=h.relay.url)
        self.assertTrue(any("invite_no" in m for m in h.relay.control_log))
        s = join.join(link, lambda e, r: None, token_provider=lambda a: F.token(a), relay_url=h.relay.url)
        self.addCleanup(s.stop)
        self.assertTrue(s.creds["user"].startswith("OW"))
        self.assertRegex(s.pass_code, r"^[A-Z2-7]{10}$")
        self.assertEqual(s.bridge.invite, s.pass_code)
        self.assertNotIn(s.pass_code, h.s.status()["invites"])
        self.assertFalse(h.s.invites.consume(s.pass_code))        # a pass can't make new accounts
        self.assertEqual(realm_client(s.bridge.auth_port)[0], b"\x00\x00\x04")
        # the single use is spent on the new account: another new player is refused at the gate
        b = Bridge(HOST_ID, h.relay.url, invite=code)
        with self.assertRaises(P2PError):
            b.login(F.token(HOST_ID, sub="999"))
        # ...but the first player comes back without needing the invite any more uses
        h.s.invites.data[code]["uses"] = 5
        self.assertEqual(Bridge(HOST_ID, h.relay.url, invite=code).login(F.token(HOST_ID))["user"], s.creds["user"])

    def test_heartbeat_reclaims_and_offline(self):
        h = HostHarness(self, register=False)
        h.s.start()
        self.assertIsNone(h.s.host_id)
        self.assertIn("offline", h.s.last_error)
        self.assertIsNone(h.s.agent)
        h.register = True
        self.assertTrue(h.s.heartbeat())
        self.assertEqual(h.s.p2p["token"], DIR_TOKEN)
        self.assertTrue(h.s.heartbeat())
        self.assertEqual(h.beats[-1][2]["Authorization"], "Bearer " + DIR_TOKEN)
        # a refused token: dropped and re-claimed in the same beat
        h.s.p2p["token"] = "stale"
        calls = []
        orig = h.post
        def post(url, payload, headers):
            calls.append(headers.get("Authorization"))
            if headers.get("Authorization") == "Bearer stale":
                return 403, {"error": "bad token"}
            return orig(url, payload, headers)
        h.s._http_post = post
        self.assertTrue(h.s.heartbeat())
        self.assertEqual(calls, ["Bearer stale", None])
        saved = json.load(open(h.s.paths.p2p_file))
        self.assertEqual(saved, {"token": DIR_TOKEN, "host_id": HOST_ID})

    def test_gate_rejects_garbage_and_rate_limits(self):
        h = HostHarness(self)
        h.s.start()
        port = h.s.gate.port
        with socket.create_connection(("127.0.0.1", port), timeout=5) as c:
            c.sendall(b"OWLG\x00\x05notjs")
            head = realmproto.recv_exact(c, 6)
            self.assertEqual(head[:4], realmproto.REPLY_MAGIC)
            body = json.loads(realmproto.recv_exact(c, struct.unpack(">H", head[4:])[0]))
            self.assertFalse(body["ok"])
        with socket.create_connection(("127.0.0.1", port), timeout=5) as c:
            c.sendall(b"OWXX\x00\x01")
            self.assertEqual(c.recv(10), b"")
        # plain realmd traffic passes
        self.assertEqual(realm_client(port)[0], b"\x00\x00\x04")
        h.s._login_times = [time.monotonic()] * host.LOGINS_PER_MINUTE
        self.assertIn("Too many", h.s._login({"token": F.token(HOST_ID)}, "1.2.3.4")["error"])


DEAD = "http://127.0.0.1:9"


class OfflineAndGuestTests(unittest.TestCase):
    """Central services (directory, identity, relay) unreachable: hosting and joining still work."""

    def test_relay_host_starts_with_central_down(self):
        h = HostHarness(self, register=False, central=DEAD, relay="ws://127.0.0.1:9")
        st = h.s.start()
        self.assertTrue(st["running"])
        self.assertEqual((st["reachability"], st["connection"], st["exposed_ports"]), ("none", "relay", []))
        self.assertIn("offline", st["last_error"])
        self.assertEqual(realm_client(h.s.gate.port)[0], b"\x00\x00\x04")     # the realm itself runs
        with self.assertRaisesRegex(P2PError, "Direct or LAN"):
            h.s.guest_invite()

    def test_direct_guest_invite_and_host_port_join_offline(self):
        h = HostHarness(self, register=False, central=DEAD, relay="ws://127.0.0.1:9", connection="direct",
                        public_host="127.0.0.1")
        st = h.s.start()
        gate = h.s.gate.port
        self.assertEqual((st["connection"], st["reachability"]), ("direct", "direct"))
        self.assertEqual(st["exposed_ports"], [gate, h.world.port])
        self.assertRegex(st["fingerprint"], r"^[a-z2-7]{16}$")
        link = h.s.guest_invite(uses=1, hours=1)
        info = invites.parse_any(link)
        self.assertEqual((info["kind"], info["host"], info["port"], info["fp"]), ("direct", "127.0.0.1", gate, st["fingerprint"]))
        boom = lambda *a, **k: self.fail("no central calls")  # noqa: E731
        s = join.join(link, lambda e, r: None, guest_name="my pal!", token_provider=boom, central=DEAD, relay_url=DEAD)
        self.addCleanup(s.stop)
        self.assertEqual(s.creds["user"], "MYPAL")
        self.assertEqual(s.realmlist, f"127.0.0.1:{gate}")
        self.assertEqual(s.fingerprint, st["fingerprint"])
        self.assertEqual(json.load(open(os.environ["OPENVANILLA_PINS_FILE"])), {f"127.0.0.1:{gate}": st["fingerprint"]})
        with self.assertRaisesRegex(P2PError, "used up"):                       # one use only
            join.join(link, lambda e, r: None, guest_name="other", token_provider=boom)
        # plain host:port with a username/password the host handed out (stock-client style)
        acc = h.s.create_account("friend1", "secret12")
        self.assertEqual((acc["user"], acc["password"]), ("FRIEND1", "SECRET12"))
        self.assertIn("account create FRIEND1 SECRET12", h.soap_cmds)
        got = {}
        s2 = join.join(f"127.0.0.1:{gate}", lambda e, r: got.update(e=e, r=r), username="friend1", password="SECRET12",
                       token_provider=boom, central=DEAD)
        self.assertEqual((got["r"], got["e"]["WOW_USER"], got["e"]["WOW_PASS"]), (f"127.0.0.1:{gate}", "FRIEND1", "SECRET12"))
        self.assertIsNone(s2.bridge)

    def test_tofu_mismatch_refused(self):
        h = HostHarness(self, register=False, central=DEAD, connection="lan")
        h.s.lan_ip = "127.0.0.1"
        st = h.s.start()
        self.assertEqual(st["reachability"], "lan")
        link = h.s.guest_invite(uses=5, hours=1)
        self.assertTrue(link.startswith("openvanilla://join/lan/127.0.0.1:"))
        join.join(link, lambda e, r: None, guest_name="a")
        # a link naming another key: refused (and nothing is pinned over)
        bad = link.replace("k=" + st["fingerprint"], "k=" + "a" * 16)
        with self.assertRaisesRegex(P2PError, "doesn't match the invite"):
            join.join(bad, lambda e, r: None, guest_name="b")
        # the host's key changes (someone else on that address): refused against the pin
        os.remove(os.path.join(h.s.host_root, "host_key.seed"))
        h.s._host_pub = None
        info = invites.parse_any(link)
        with self.assertRaisesRegex(P2PError, "changed since"):
            join.join(f"{info['host']}:{info['port']}", lambda e, r: None, guest=info["guest"], guest_name="c")

    def test_parse_any(self):
        self.assertEqual(invites.parse_any("play.example.org")["port"], 3724)
        self.assertEqual(invites.parse_any("10.0.0.5:4000")[  "kind"], "plain")
        self.assertIsNone(invites.parse_any("bad host:x"))
        self.assertIsNone(invites.parse_any("openvanilla://join/direct/a b:1"))
        r = invites.parse_any("openvanilla://join/abcdefghijklmnop?g=ABCDEFGH23&k=" + "b" * 16)
        self.assertEqual((r["kind"], r["guest"], r["fp"]), ("relay", "ABCDEFGH23", "b" * 16))


class RelayAgentTests(unittest.TestCase):
    def test_control_messages(self):
        relay = F.FakeRelay(tokens={HOST_ID: DIR_TOKEN})
        self.addCleanup(relay.close)
        states = []
        a = host.RelayAgent(relay.url, HOST_ID, DIR_TOKEN, {3724: 1, 8085: 2}, lambda c: c == "GOOD",
                            on_state=states.append, ping_every=0.2)
        a.start()
        self.addCleanup(a.stop)
        self.assertTrue(relay.agent_connected.wait(5))
        relay.send_control(HOST_ID, {"ping": 7})
        relay.send_control(HOST_ID, {"invite_check": "GOOD", "stream": 3})
        relay.send_control(HOST_ID, {"invite_check": "BAD", "stream": 4})
        relay.send_control(HOST_ID, {"limits": {"max_streams": 64}})
        relay.send_control(HOST_ID, {"open": 9, "port": 3306})        # never: only the two game ports
        self.assertTrue(wait_for(lambda: {"pong": 7} in relay.control_log and {"invite_ok": 3} in relay.control_log
                                 and {"invite_no": 4} in relay.control_log and {"close": 9} in relay.control_log
                                 and any("ping" in m for m in relay.control_log)))
        self.assertEqual(a.limits, {"max_streams": 64})
        self.assertEqual(states, [True])

    def test_bad_token_retries(self):
        relay = F.FakeRelay(tokens={HOST_ID: "other"})
        self.addCleanup(relay.close)
        a = host.RelayAgent(relay.url, HOST_ID, DIR_TOKEN, {}, lambda c: False)
        a.start()
        self.addCleanup(a.stop)
        self.assertTrue(wait_for(lambda: a.last_error is not None))
        self.assertIn("403", a.last_error)
        self.assertFalse(a.connected)


class HostPieceTests(unittest.TestCase):
    def test_account_names(self):
        self.assertEqual(host.account_for("12345"), "OW" + "GA4Q")   # 0x3039 -> base32
        self.assertRegex(host.account_for("discord:1234567890123456789"), r"^OW[A-Z2-7]{13,14}$")
        self.assertLessEqual(len(host.account_for(str(2 ** 64 - 1))), 16)
        self.assertNotEqual(host.account_for("1"), host.account_for("2"))

    def test_config_validation(self):
        with self.assertRaises(P2PError):
            host.HostConfig(name="x").validate()
        with self.assertRaises(P2PError):
            host.HostConfig(name="Good Name", type="ffa").validate()
        with self.assertRaises(P2PError):
            host.HostConfig(name="Bad'Name").validate()
        c = host.HostConfig(name="  Good Name ", bots=99999, max_players=0, tags=["a"] * 9).validate()
        self.assertEqual((c.name, c.bots, c.max_players, len(c.tags)), ("Good Name", 2000, 1, 4))

    def test_conf_overrides(self):
        cfg = host.HostConfig(name="Night Realm", type="rppvp", bots=0, max_players=50).validate()
        o = host.host_conf_overrides(cfg, False, {"ports": {"realm": 3725}})
        m = dict(o["mangosd.conf"])
        self.assertEqual((m["BindIP"], m["GameType"], m["PlayerLimit"], m["SOAP.IP"]), ('"127.0.0.1"', "8", "50", "127.0.0.1"))
        self.assertEqual(dict(o["aiplayerbot.conf"])["AiPlayerbot.Enabled"], "0")
        self.assertEqual(dict(o["realmd.conf"])["BindIP"], '"127.0.0.1"')
        self.assertEqual(dict(host.host_conf_overrides(cfg, True, {"ports": {"realm": 1}})["mangosd.conf"])["BindIP"], '"0.0.0.0"')
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        p = os.path.join(tmp, "mangosd.conf")
        with open(p, "w") as f:
            f.write('BindIP = "127.0.0.1"\nGameType = 0\n# PlayerLimit = 100\n')
        host.apply_host_overrides({"mangosd.conf": p}, o)
        text = open(p).read()
        self.assertIn("GameType = 8", text)
        self.assertIn("PlayerLimit = 50", text)
        sql = host.realmlist_host_sql(cfg, {"ports": {"world": 8085}}, "203.0.113.4")
        self.assertIn("'Night Realm','203.0.113.4',8085,8", sql)

    def test_ban_kick_announce_population(self):
        h = HostHarness(self)
        db = FakeDB()
        h.s.db = db
        h.s._load_state()
        h.s.accounts = {"777": {"user": "OWABC", "password": "X"}}
        db.answers = {"WHERE c.name = 'Griefer'": "OWABC\n", "NOT LIKE 'RNDBOT%'": "3\n", "LIKE 'RNDBOT%'": "40\n"}
        h.s.ban("Griefer")
        self.assertEqual(h.s.p2p["banned_subs"], ["777"])
        self.assertIn("ban character Griefer -1 Banned by the host", h.soap_cmds)
        h.s.kick("Griefer")
        h.s.announce("Hello all")
        self.assertEqual(h.soap_cmds[-2:], ["kick Griefer", "announce Hello all"])
        self.assertEqual((h.s.population(), h.s.bots_online()), (3, 40))
        h.s.accounts["777"]["user"] = "OWABC"
        h.s.verifier = __import__("p2p.paseto", fromlist=["x"]).TokenVerifier(F.keys(), HOST_ID)
        self.assertIn("banned", h.s._login({"token": F.token(HOST_ID, sub="777")}, "x")["error"])

    def test_revoked_players_are_kicked(self):
        h = HostHarness(self)
        db = FakeDB()
        db.answers = {"a.username IN ('OWABC')": "Badguy\n"}
        h.s.db = db
        h.s.accounts = {"5": {"user": "OWABC", "password": "x"}, "6": {"user": "OWDEF", "password": "y"}}
        h.s.revoked.subs = {"5"}
        h.s._kick_revoked()
        self.assertEqual(h.soap_cmds, ["kick Badguy"])

    def test_prune_backups(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        now = time.mktime((2026, 10, 15, 12, 0, 0, 0, 0, -1))
        for stamp in ("20261015-113000", "20261009-120000", "20261007-120000", "20260101-000000"):
            open(os.path.join(tmp, f"backup-{stamp}.sql.gz"), "w").close()
        open(os.path.join(tmp, "notes.txt"), "w").close()
        removed = host.prune_backups(tmp, now)
        self.assertEqual(sorted(os.path.basename(p) for p in removed),
                         ["backup-20260101-000000.sql.gz", "backup-20261007-120000.sql.gz"])
        self.assertEqual(len(os.listdir(tmp)), 3)

    def test_bot_cap(self):
        self.assertEqual(host.bot_cap_for_ram(8192), 512)
        self.assertEqual(host.bot_cap_for_ram(2048), 0)
        self.assertEqual(host.bot_cap_for_ram(0), 200)

    def test_rate_meter(self):
        m = host.RateMeter()
        m("up", 2048)
        up, down = m.rates()
        self.assertGreater(up, 0)
        self.assertEqual(down, 0)


class JoinTests(unittest.TestCase):
    def test_direct_join_and_stock_launcher(self):
        h = HostHarness(self)
        h.s.start()
        gate = h.s.gate.port
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        exe = os.path.join(tmp, "WoW.exe")
        with open(os.path.join(tmp, "realmlist.wtf"), "w") as f:
            f.write("set realmlist play.openvanilla.app\n")
        procs = []

        class P:
            def __init__(self, argv, cwd=None):
                procs.append((argv, cwd))
                self.done = threading.Event()

            def wait(self):
                self.done.wait(5)
        launcher = join.stock_launcher(exe, popen=P)
        s = join.join({"name": "Direct", "host": "127.0.0.1", "port": gate, "host_id": HOST_ID, "relay": False},
                      launcher, token_provider=lambda a: F.token(a))
        self.assertIsNone(s.bridge)
        self.assertEqual(s.realmlist, f"127.0.0.1:{gate}")
        self.assertEqual(open(os.path.join(tmp, "realmlist.wtf")).read().strip(), f"set realmlist 127.0.0.1:{gate}")
        self.assertIn(f'SET accountName "{s.creds["user"]}"', open(os.path.join(tmp, "WTF", "Config.wtf")).read())
        s.process.done.set()
        self.assertTrue(wait_for(lambda: "play.openvanilla.app" in open(os.path.join(tmp, "realmlist.wtf")).read()))

    def test_identity_token_request(self):
        got = []
        srv = F.HTTPServer({("POST", "/api/identity/token"): lambda h, b: (
            got.append((h.headers["Authorization"], json.loads(b))) or 200,
            json.dumps({"token": "v4.public.abc", "exp": 1}).encode(), {})})
        self.addCleanup(srv.close)
        self.assertEqual(join.identity_token(HOST_ID, "LT", srv.url()), "v4.public.abc")
        self.assertEqual(got, [("Bearer LT", {"aud": HOST_ID})])
        with self.assertRaises(P2PError):
            join.identity_token(HOST_ID, None, srv.url())

    def test_bad_link_and_offline_realm(self):
        with self.assertRaises(P2PError):
            join.join("https://example.org/", lambda e, r: None, token_provider=lambda a: "t")
        relay = F.FakeRelay()
        self.addCleanup(relay.close)
        with self.assertRaisesRegex(P2PError, "isn't online"):
            join.join(f"openvanilla://join/{HOST_ID}", lambda e, r: None, token_provider=lambda a: "t", relay_url=relay.url)


if __name__ == "__main__":
    unittest.main()
