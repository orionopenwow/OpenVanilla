"""Hosting end to end on Linux with real servers: a real MariaDB (the host folder's own data dir, set
up by play_local.SoloDB), a real CMaNGOS realmd behind the host's gate, the fake relay, the player's
bridge and join(): an Open Vanilla identity token becomes a realmd account, and a full 1.12.1 SRP6 login
plus the realm list go through relay -> agent -> gate -> realmd. Then a real backup.

    python3 -m unittest tests.test_p2p_e2e -v

realmd: OW_TEST_REALMD (default /tmp/claude-0/mcrealmd/src/realmd/realmd), its schema
OW_TEST_REALMD_SQL (default /tmp/claude-0/mc/sql/base/realmd.sql). Skipped when either is missing.
"""
import gzip
import hashlib
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p2p_fakes as F  # noqa: E402
import solo_fakes as SF  # noqa: E402
import play_local as P  # noqa: E402
from p2p import host, join, realmproto  # noqa: E402

REALMD = os.environ.get("OW_TEST_REALMD", "/tmp/claude-0/mcrealmd/src/realmd/realmd")
REALMD_SQL = os.environ.get("OW_TEST_REALMD_SQL", "/tmp/claude-0/mc/sql/base/realmd.sql")
MARIADB = {n: shutil.which(n) or ("/usr/sbin/" + n if os.path.isfile("/usr/sbin/" + n) else None)
           for n in ("mariadbd", "mariadb", "mariadb-admin", "mariadb-install-db", "mariadb-dump")}
READY = os.path.isfile(REALMD) and os.path.isfile(REALMD_SQL) and all(MARIADB.values())
HOST_ID = "e2ehostidxxxxxxx"
DIR_TOKEN = "e" * 64


def srp_login_and_list(host_, port, user, password, tries=3):
    """Retries a refused proof: the 1.12 SRP6 math has a rare padding mismatch between a pure client and
    CMaNGOS (about 1 in 100 random ephemerals), unrelated to the account or the tunnel."""
    for _ in range(tries):
        out = _srp_login_and_list(host_, port, user, password)
        if out[1] != 4:
            return out
    return out


def _srp_login_and_list(host_, port, user, password):
    """The 1.12.1 handshake (as the game does it) and the realm list. -> (challenge, proof, realms)."""
    N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
    G = 7
    le = lambda n, k=32: n.to_bytes(k, "little")  # noqa: E731

    def sha(*a):
        h = hashlib.sha1()
        for b in a:
            h.update(b)
        return h.digest()
    u_, p_ = user.upper().encode(), password.upper().encode()
    with socket.create_connection((host_, port), timeout=15) as s:
        s.settimeout(15)
        rx = lambda n: realmproto.recv_exact(s, n)  # noqa: E731
        s.sendall(realmproto.logon_challenge(user))
        _, _, res = rx(3)
        if res != 0:
            return res, None, None
        B = int.from_bytes(rx(32), "little")
        rx(rx(1)[0])
        rx(rx(1)[0])
        salt = rx(32)
        rx(16)
        rx(1)
        a = int.from_bytes(os.urandom(32), "little") % N
        A = pow(G, a, N)
        Ab, Bb = le(A), le(B)
        x = int.from_bytes(sha(salt, sha(u_ + b":" + p_)), "little")
        u = int.from_bytes(sha(Ab, Bb), "little")
        S = le(pow((B - 3 * pow(G, x, N)) % N, a + u * x, N))
        e, o = sha(S[0::2]), sha(S[1::2])
        K = bytes(b for pr in zip(e, o) for b in pr)
        M1 = sha(bytes(i ^ j for i, j in zip(sha(le(N)), sha(le(G, 1)))), sha(u_), salt, Ab, Bb, K)
        s.sendall(bytes([1]) + Ab + M1 + bytes(20) + bytes([0, 0]))
        _, res = rx(2)
        if res != 0:
            return 0, res, None
        rx(20 + 4)
        s.sendall(b"\x10\x00\x00\x00\x00")
        head = rx(3)
        realms, _ = realmproto.parse_realm_list(rx(struct.unpack("<H", head[1:])[0]))
        return 0, 0, realms


@unittest.skipUnless(READY, "needs a built CMaNGOS realmd, its realmd.sql and MariaDB")
class HostEndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p2p-e2e-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        F.fresh_pins(self)
        solo = os.path.join(self.tmp, "OpenVanilla", "solo")
        mbin = os.path.join(solo, "mariadb", "bin")
        os.makedirs(mbin)
        for n, path in MARIADB.items():
            os.symlink(path, os.path.join(mbin, n))
        shutil.copytree(os.path.join(F.ROOT, "solo", "templates"), os.path.join(solo, "templates"))
        SF.write(os.path.join(solo, "bin", "realmd.conf.dist"), SF.REALMD_DIST)
        self.relay = F.FakeRelay(tokens={HOST_ID: DIR_TOKEN})
        self.addCleanup(self.relay.close)
        self.central = F.HTTPServer({})
        self.addCleanup(self.central.close)
        root = os.path.join(self.tmp, "OpenVanilla", "host")
        os.makedirs(root)
        self.ports = {"gate": F.free_port(), "realm": F.free_port(), "world": F.free_port(), "db": F.free_port(),
                      "soap": F.free_port()}
        P.write_json(os.path.join(root, "state.json"), {"ports": self.ports})
        cfg = host.HostConfig(name="E2E Realm", type="pvp", visibility="public", data_dir=root, solo_root=solo,
                              central=self.central.url(), relay=self.relay.url)
        self.s = host.HostSession(cfg, keys=F.keys(), start_servers=False,
                                  http_post=lambda u, p, h: (201, {"token": DIR_TOKEN, "host_id": HOST_ID}))
        self.addCleanup(self.s.stop)

    def bring_up_database_and_realmd(self):
        s = self.s
        s._load_state()
        paths, state = s.paths, s.state
        configs = P.write_configs(paths, state)
        host.apply_host_overrides(configs, host.host_conf_overrides(s.cfg, False, state))
        db = P.SoloDB(paths, state)
        db.initialize()
        db.start()
        s.db = db
        db.query("CREATE DATABASE classicrealmd; CREATE DATABASE classiccharacters;")
        db.import_file(REALMD_SQL, "classicrealmd")
        db.query("CREATE TABLE characters (guid INT PRIMARY KEY, account INT, name VARCHAR(12), online TINYINT);",
                 "classiccharacters")
        pw = state["db_password"]
        db.query(f"CREATE USER 'mangos'@'127.0.0.1' IDENTIFIED BY '{pw}'; CREATE USER 'mangos'@'localhost' IDENTIFIED BY '{pw}';"
                 "GRANT ALL ON `classic%`.* TO 'mangos'@'127.0.0.1'; GRANT ALL ON `classic%`.* TO 'mangos'@'localhost';"
                 "FLUSH PRIVILEGES;")
        db.query(host.realmlist_host_sql(s.cfg, state, "127.0.0.1") + P.account_sql("RNDBOT1", "x", 0), "classicrealmd")
        log = open(os.path.join(paths.logs, "realmd.out"), "w")
        self.realmd = subprocess.Popen([REALMD, "-c", configs["realmd.conf"]], cwd=paths.logs, stdout=log,
                                       stderr=subprocess.STDOUT)
        self.addCleanup(lambda: (self.realmd.terminate(), self.realmd.wait(10), log.close()))
        for _ in range(100):
            if P.is_port_open(self.ports["realm"]):
                break
            time.sleep(0.1)
        self.assertTrue(P.is_port_open(self.ports["realm"]), open(os.path.join(paths.logs, "realmd.out")).read())
        # the host's realmd listens on loopback only
        conf = open(configs["realmd.conf"]).read()
        self.assertIn('BindIP = "127.0.0.1"', conf)

    def test_token_to_game_login_through_relay(self):
        self.bring_up_database_and_realmd()
        self.s.start()
        self.assertTrue(self._wait(lambda: self.s.agent and self.s.agent.connected))
        # SOAP is down (no mangosd here): the account is still made, straight in classicrealmd
        sess = join.join(f"openvanilla://join/{HOST_ID}", lambda env, rl: None, token_provider=lambda aud: F.token(aud, sub="4242"),
                         relay_url=self.relay.url)
        self.addCleanup(sess.stop)
        self.assertEqual(sess.creds["user"], host.account_for("4242"))
        challenge, proof, realms = srp_login_and_list("127.0.0.1", sess.bridge.auth_port, sess.creds["user"],
                                                      sess.creds["password"])
        self.assertEqual((challenge, proof), (0, 0))
        self.assertEqual(realms[0]["name"], b"E2E Realm")
        self.assertEqual(realms[0]["icon"], 1)                                   # PvP
        self.assertEqual(realms[0]["address"], f"127.0.0.1:{sess.bridge.world_port}".encode())
        # wrong password is refused by the real realmd (through the same path)
        self.assertEqual(srp_login_and_list("127.0.0.1", sess.bridge.auth_port, sess.creds["user"], "WRONGPASS")[1], 4)
        # direct (LAN) path through the gate, no relay
        ch, pr, _ = srp_login_and_list("127.0.0.1", self.ports["gate"], sess.creds["user"], sess.creds["password"])
        self.assertEqual((ch, pr), (0, 0))

        # population excludes bots
        acc_id = self.s.db.query(f"SELECT id FROM account WHERE username='{sess.creds['user']}'", "classicrealmd").strip()
        bot_id = self.s.db.query("SELECT id FROM account WHERE username='RNDBOT1'", "classicrealmd").strip()
        self.s.db.query(f"INSERT INTO characters VALUES (1,{acc_id},'Hero',1),(2,{bot_id},'Botty',1);", "classiccharacters")
        self.assertEqual((self.s.population(), self.s.bots_online()), (1, 1))
        self.assertEqual(self.s.heartbeat_payload()["population"], 1)

        # backup: a real mariadb-dump of characters + accounts
        path = self.s.backup()
        with gzip.open(path, "rt", errors="replace") as f:
            dump = f.read()
        self.assertIn("CREATE DATABASE", dump)
        self.assertIn("'Hero'", dump)
        self.assertIn(sess.creds["user"], dump)
        st = self.s.status()
        self.assertEqual((st["players"], st["reachability"], st["host_id"]), (1, "relay", HOST_ID))
        self.assertGreater(st["ram"], 0)

    def test_direct_guest_invite_with_central_down(self):
        """Home connection, everything central unreachable: a guest link made on the host gets a friend
        through a real SRP6 login; a host-made named account works with plain host:port."""
        dead = "http://127.0.0.1:9"
        cfg = host.HostConfig(name="Home Realm", type="pve", visibility="private", connection="direct",
                              public_host="127.0.0.1", data_dir=self.s.cfg.data_dir, solo_root=self.s.cfg.solo_root,
                              central=dead, relay="ws://127.0.0.1:9")
        def offline(*a):
            raise OSError("central offline")
        self.s = host.HostSession(cfg, start_servers=False, http_post=offline)
        self.addCleanup(self.s.stop)
        self.bring_up_database_and_realmd()
        st = self.s.start()
        self.assertEqual((st["connection"], st["reachability"], st["host_id"]), ("direct", "direct", None))
        self.assertEqual(st["exposed_ports"], [self.ports["gate"], self.ports["world"]])
        self.assertEqual(self.s.bind_address(), "0.0.0.0")
        self.assertIn(("BindIP", '"0.0.0.0"'), host.host_conf_overrides(cfg, self.s.bind_address(), self.s.state)["mangosd.conf"])
        link = self.s.guest_invite(uses=2, hours=1)
        no_central = lambda *a: self.fail("central was called")  # noqa: E731
        sess = join.join(link, lambda e, r: None, guest_name="Buddy", token_provider=no_central, central=dead,
                         relay_url=dead)
        self.assertEqual(sess.creds["user"], "BUDDY")
        ch, pr, realms = srp_login_and_list("127.0.0.1", self.ports["gate"], sess.creds["user"], sess.creds["password"])
        self.assertEqual((ch, pr, realms[0]["name"]), (0, 0, b"Home Realm"))
        self.assertEqual(realms[0]["address"], f"127.0.0.1:{self.ports['world']}".encode())   # not rewritten: direct
        acc = self.s.create_account("pal", "pass1234")
        sess2 = join.join(f"127.0.0.1:{self.ports['gate']}", lambda e, r: None, username="PAL", password="PASS1234",
                          central=dead, token_provider=no_central)
        self.assertEqual(srp_login_and_list("127.0.0.1", self.ports["gate"], acc["user"], acc["password"])[:2], (0, 0))
        self.assertEqual(sess2.realmlist, f"127.0.0.1:{self.ports['gate']}")

    def _wait(self, cond, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            if cond():
                return True
            time.sleep(0.05)
        return False


@unittest.skipUnless(READY, "needs a built CMaNGOS realmd, its realmd.sql and MariaDB")
class FullHostStart(unittest.TestCase):
    """HostSession.start() from an installed Solo pack (fake mangosd script, real realmd, real MariaDB):
    the host folder, configs, databases, Solo account removal, realmlist, and Stop hosting."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p2p-full-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        F.fresh_pins(self)
        solo = self.solo = os.path.join(self.tmp, "OpenVanilla", "solo")
        b = os.path.join(solo, "bin")
        SF.script(os.path.join(b, "mangosd.exe"), SF.FAKE_MANGOSD)
        SF.script(os.path.join(b, "realmd.exe"), SF.REAL_REALMD_WRAPPER.format(realmd=REALMD))
        SF.write(os.path.join(b, "mangosd.conf.dist"), SF.MANGOSD_DIST)
        SF.write(os.path.join(b, "realmd.conf.dist"), SF.REALMD_DIST)
        SF.write(os.path.join(b, "aiplayerbot.conf.dist"), SF.AIPLAYERBOT_DIST)
        mbin = os.path.join(solo, "mariadb", "bin")
        os.makedirs(mbin)
        for n, path in MARIADB.items():
            os.symlink(path, os.path.join(mbin, n))
        shutil.copytree(os.path.join(F.ROOT, "solo", "templates"), os.path.join(solo, "templates"))
        db = os.path.join(solo, "db")
        SF.write(os.path.join(db, "classicmangos.sql"), "CREATE TABLE creature_template (entry INT);"
                 "INSERT INTO creature_template VALUES (1),(2);CREATE TABLE playercreateinfo (race INT, class INT);"
                 "INSERT INTO playercreateinfo VALUES (1,1);")
        shutil.copy(REALMD_SQL, os.path.join(db, "classicrealmd.sql"))
        SF.write(os.path.join(db, "classiccharacters.sql"),
                 "CREATE TABLE characters (guid INT PRIMARY KEY, account INT, name VARCHAR(12), race INT, class INT, online TINYINT);")
        SF.write(os.path.join(db, "classiclogs.sql"), "CREATE TABLE logs_x (id INT);")
        for sub, name in (("dbc", "Map.dbc"), ("maps", "0003232.map"), ("vmaps", "000.vmtree")):
            SF.write(os.path.join(solo, "gamedata", sub, name), b"stand-in")
        SF.write(os.path.join(solo, "pack.json"), '{"format": 1, "version": "1.0", "world_version": "w1"}')
        os.environ["OPENVANILLA_SOLO_MANIFEST"] = "http://127.0.0.1:9/solo.json"   # offline: the installed pack is used
        self.addCleanup(os.environ.pop, "OPENVANILLA_SOLO_MANIFEST", None)
        self.relay = F.FakeRelay(tokens={HOST_ID: DIR_TOKEN})
        self.addCleanup(self.relay.close)
        self.central = F.HTTPServer({})
        self.addCleanup(self.central.close)
        root = self.root = os.path.join(self.tmp, "OpenVanilla", "host")
        self.ports = {"gate": F.free_port(), "realm": F.free_port(), "world": F.free_port(), "db": F.free_port(),
                      "soap": F.free_port()}
        P.write_json(os.path.join(root, "state.json"), {"ports": self.ports})
        self.progress = []
        cfg = host.HostConfig(name="Full Realm", type="rp", visibility="private", bots=12, max_players=30,
                              data_dir=root, solo_root=solo, central=self.central.url(), relay=self.relay.url)
        self.s = host.HostSession(cfg, lambda *a: self.progress.append(a), keys=F.keys(), settings={},
                                  http_post=lambda u, p, h: (201, {"token": DIR_TOKEN, "host_id": HOST_ID}))
        self.addCleanup(self.s.stop)

    def test_start_join_stop(self):
        st = self.s.start()
        self.assertEqual((st["reachability"], st["host_id"], st["listed"]), ("relay", HOST_ID, False))
        logs = os.path.join(self.root, "logs")
        world = SF.read_json(os.path.join(logs, "fake_mangosd.json"))
        self.assertEqual(world["conf"]["BindIP"], "127.0.0.1")              # relay-only host: loopback
        self.assertEqual(world["conf"]["SOAP.Port"], str(self.ports["soap"]))
        self.assertRegex(world["world_db"], r"^\d+$")
        conf = open(os.path.join(self.root, "etc", "mangosd.conf")).read()
        self.assertIn("GameType = 6", conf)
        self.assertIn("PlayerLimit = 30", conf)
        bots = open(os.path.join(self.root, "etc", "aiplayerbot.conf")).read()
        self.assertIn("AiPlayerbot.MaxRandomBots = 12", bots)
        self.assertTrue(os.path.isdir(os.path.join(self.root, "data", "mysql")))      # the host's own database
        self.assertFalse(os.path.exists(os.path.join(self.solo, "data")))             # never the Solo one
        users = self.s.db.query("SELECT username FROM account", "classicrealmd").split()
        self.assertNotIn("SOLO", users)
        self.assertIn("SOLOADMIN", users)
        row = self.s.db.query("SELECT name, icon, port FROM realmlist", "classicrealmd").strip().split("\t")
        self.assertEqual(row, ["Full Realm", "6", str(self.ports["world"])])
        # a private realm: an invite link gets a player in with a real SRP6 login
        link = self.s.invite(uses=1, hours=2)
        self.assertTrue(self._wait(lambda: self.s.agent and self.s.agent.connected))
        sess = join.join(link, lambda env, rl: None, token_provider=lambda aud: F.token(aud, sub="77"), relay_url=self.relay.url)
        self.addCleanup(sess.stop)
        ch, pr, realms = srp_login_and_list("127.0.0.1", sess.bridge.auth_port, sess.creds["user"], sess.creds["password"])
        self.assertEqual((ch, pr, realms[0]["name"]), (0, 0, b"Full Realm"))
        # the SOLO account can't log in here
        self.assertEqual(srp_login_and_list("127.0.0.1", self.ports["gate"], "SOLO", "SOLO")[0], 4)
        self.assertTrue(any(stage == "ready" for stage, _, _ in self.progress))
        self.s.stop()
        for name, port in self.ports.items():
            self.assertFalse(P.is_port_open(port), name)
        self.assertFalse(os.path.exists(os.path.join(self.root, "run.json")))
        self.assertEqual([c for _, c in SF.read_json(os.path.join(logs, "fake_mangosd.json"))["commands"]],
                         [f"account create {sess.creds['user']} {sess.creds['password']}", "saveall", "server shutdown 1"])

    _wait = HostEndToEnd._wait


if __name__ == "__main__":
    unittest.main()
