"""Play Solo end to end, on Linux: tools/build_solo_pack.py builds a pack from stub inputs (scripts
for the Windows programs, the system MariaDB behind wrapper scripts, devkit's fixture databases), a
local web server hands it out, and play_local.SoloSession downloads, verifies, unpacks, extracts maps
with fake extractors, sets up a real MariaDB, applies the live realm's Classic+ SQL, starts the
servers, runs a fake game client and shuts everything down. Then a pack update.

    python3 -m unittest tests.test_solo_e2e -v

With a real CMaNGOS realmd (built from the pinned commit) the fake game also logs in with the 1.12.1
SRP6 handshake as SOLO/SOLO and reads the realm list:
    OW_TEST_REALMD=/path/to/realmd OW_TEST_REALMD_SQL=/path/to/mangos-classic/sql/base/realmd.sql \\
        python3 -m unittest tests.test_solo_e2e -v
"""
import contextlib
import gzip
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import solo_fakes as F  # noqa: E402
import play_local as P  # noqa: E402

sys.path.insert(0, os.path.join(F.ROOT, "tools"))
import build_solo_pack as B  # noqa: E402

HAVE_MARIADB = all(shutil.which(n) or os.path.isfile("/usr/sbin/" + n) for n in ("mariadbd", "mariadb", "mariadb-install-db"))
REALMD = os.environ.get("OW_TEST_REALMD")
REALMD_SQL = os.environ.get("OW_TEST_REALMD_SQL")
REAL_LOGIN = bool(REALMD and REALMD_SQL and os.path.isfile(REALMD) and os.path.isfile(REALMD_SQL))


def build(args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = B.main(args)
    return code, out.getvalue()


class BuilderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="solo-build-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.srv, self.mdb, self.dumps = F.stub_inputs(self.tmp)
        self.out = os.path.join(self.tmp, "dist")

    def args(self, *extra):
        return ["--server", self.srv, "--mariadb", self.mdb, "--db", self.dumps, "--version", "1.15.0",
                "--out", self.out, "--base-url", "https://example.org/solo", "--commit", "abc123"] + list(extra)

    def test_dry_run_writes_nothing(self):
        code, out = build(self.args("--dry-run"))
        self.assertEqual(code, 0, out)
        self.assertIn("dry run: nothing written", out)
        self.assertIn("playerbots on", out)
        self.assertFalse(os.path.exists(self.out))

    def test_build_contents_and_manifests(self):
        code, out = build(self.args("--sql-applied"))
        self.assertEqual(code, 0, out)
        zpath = os.path.join(self.out, "OpenVanilla-Solo-1.15.0.zip")
        manifest = F.read_json(os.path.join(self.out, "solo.json"))
        self.assertEqual(manifest["sha256"], P.sha256_file(zpath))
        self.assertEqual(manifest["size"], os.path.getsize(zpath))
        self.assertEqual(manifest["url"], "https://example.org/solo/OpenVanilla-Solo-1.15.0.zip")
        P.validate_manifest(manifest)
        sql = {s["name"]: s for s in manifest["sql"]}
        self.assertEqual(sql["classicplus_races.sql"]["db"], "classicmangos")
        self.assertTrue(sql["classicplus_races.sql"]["url"].endswith("/abc123/realm/classicplus/classicplus_races.sql"))
        with zipfile.ZipFile(zpath) as z:
            names = set(z.namelist())
            pack = json.loads(z.read("pack.json"))
            for n, meta in pack["files"].items():
                self.assertEqual(F.sha256(z.read(n)), meta["sha256"], n)
            self.assertEqual(gzip.decompress(z.read("db/classicmangos.sql.gz"))[:20],
                             open(os.path.join(self.dumps, "classicmangos.sql"), "rb").read()[:20])
        for want in ("bin/mangosd.exe", "bin/realmd.exe", "bin/libmariadb.dll", "bin/aiplayerbot.conf.dist",
                     "bin/anticheat.conf.dist", "bin/tools/ad.exe", "bin/tools/MoveMapGen.exe", "bin/tools/offmesh.txt",
                     "mariadb/bin/mariadbd.exe", "mariadb/bin/mariadb-install-db.exe", "mariadb/lib/plugin/auth_x.dll",
                     "db/classicmangos.sql.gz", "db/classiclogs.sql.gz", "sql/classicplus_races.sql",
                     "conf/mangosd.conf.overrides", "conf/my.ini", "tools/gen_outfits.py",
                     "tools/fix_skillraceclassinfo.py", "README.txt", "pack.json"):
            self.assertIn(want, names)
        for n in names:
            self.assertFalse(n.endswith(".pdb") or "warden_modules" in n or "mysql-test" in n or n.startswith("mariadb/include"), n)
            self.assertIn(n.split("/")[0], P.PACK_DIRS + P.PACK_FILES, n)   # the launcher's unpack accepts it
            self.assertNotIn("pending", n)
        self.assertTrue(pack["playerbots"])
        self.assertEqual(set(pack["sql_baseline"]), {n[4:] for n in names if n.startswith("sql/")})

    def test_refuses_game_data(self):
        F.write(os.path.join(self.srv, "storm.dll"), b"MPQ\x1a" + b"\x00" * 60)
        code, out = build(self.args())
        self.assertEqual(code, 1)
        self.assertIn("Refusing to pack game data", out)
        self.assertIn("bin/storm.dll", out)
        os.remove(os.path.join(self.srv, "storm.dll"))
        F.write(os.path.join(self.mdb, "share", "dbc", "Spell.txt"), b"hello")
        code, out = build(self.args())
        self.assertEqual(code, 1)
        self.assertIn("mariadb/share/dbc/Spell.txt", out)

    def test_guard_rules(self):
        self.assertIsNotNone(B.blizzard_guard("bin/x.MPQ", b""))
        self.assertIsNotNone(B.blizzard_guard("conf/Map.dbc", b""))
        self.assertIsNotNone(B.blizzard_guard("tools/thing.bin", b"WDBC...."))
        self.assertIsNotNone(B.blizzard_guard("bin/maps/0003232.bin", b""))
        self.assertIsNone(B.blizzard_guard("mariadb/share/english/errmsg.sys", b"\xfe\xfe"))
        self.assertIsNone(B.blizzard_guard("bin/mangosd.exe", b"MZ"))

    def test_needs_playerbots_and_extractors(self):
        os.remove(os.path.join(self.srv, "aiplayerbot.conf.dist"))
        code, out = build(self.args("--dry-run"))
        self.assertEqual(code, 1)
        self.assertIn("PlayerBots", out)
        code, out = build(self.args("--dry-run", "--allow-no-bots"))
        self.assertEqual(code, 0, out)
        os.remove(os.path.join(self.srv, "tools", "vmap_assembler.exe"))
        code, out = build(self.args("--dry-run", "--allow-no-bots"))
        self.assertEqual(code, 1)
        self.assertIn("vmap_assembler.exe", out)

    def test_bad_dumps(self):
        F.write(os.path.join(self.dumps, "classicmangos.sql"), "-- MariaDB dump\nCREATE TABLE x (id int);\n")
        code, out = build(self.args("--dry-run"))
        self.assertEqual(code, 1)
        self.assertIn("not a world database", out)
        os.remove(os.path.join(self.dumps, "classiccharacters.sql"))
        code, out = build(self.args("--dry-run"))
        self.assertIn("classiccharacters.sql", out)

    def test_zip_inputs_work_like_folders(self):
        zsrv = shutil.make_archive(os.path.join(self.tmp, "server"), "zip", os.path.dirname(self.srv))
        zmdb = shutil.make_archive(os.path.join(self.tmp, "mariadb-11.4.5-winx64"), "zip", self.tmp,
                                   os.path.basename(self.mdb))
        code, out = build(["--server", zsrv, "--mariadb", zmdb, "--db", self.dumps, "--version", "1.15.0", "--dry-run"])
        self.assertEqual(code, 0, out)


@unittest.skipUnless(HAVE_MARIADB, "needs mariadbd, mariadb and mariadb-install-db")
class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="solo-e2e-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.srv_dir, self.mdb, self.dumps = F.stub_inputs(self.tmp, REALMD if REAL_LOGIN else None,
                                                          REALMD_SQL if REAL_LOGIN else None)
        self.dist = os.path.join(self.tmp, "dist")
        self.web = F.FileServer({})
        self.addCleanup(self.web.close)
        self.publish("1.15.0")
        # the player's PC: a 1.12 client folder and the OpenVanilla\solo folder
        self.wow = os.path.join(self.tmp, "World of Warcraft")
        F.write(os.path.join(self.wow, "Data", "base.MPQ"), b"stand-in")
        F.write(os.path.join(self.wow, "realmlist.wtf"), "set realmlist play.openvanilla.app\r\n")
        F.script(os.path.join(self.wow, "WoW.exe"), F.FAKE_GAME)
        dbcs = os.path.join(self.tmp, "client-dbc")
        F.write(os.path.join(dbcs, "CharStartOutfit.dbc"), F.char_start_outfit_dbc())
        F.write(os.path.join(dbcs, "SkillRaceClassInfo.dbc"), F.skill_race_class_dbc())
        self.root = os.path.join(self.tmp, "OpenVanilla", "solo")
        ports = {"db": F.free_port(), "realm": F.free_port(), "world": F.free_port(), "soap": F.free_port()}
        P.write_json(os.path.join(self.root, "state.json"), {"ports": ports})
        self.ports = ports
        self.game_out = os.path.join(self.tmp, "game.json")
        self.env = {"FAKE_DBC_SRC": dbcs, "FAKE_GAME_OUT": self.game_out, "FAKE_GAME_LOGIN": "1" if REAL_LOGIN else "0"}
        os.environ.update(self.env)
        self.addCleanup(lambda: [os.environ.pop(k, None) for k in self.env])

    def publish(self, version, world_extra=b""):
        if world_extra:
            with open(os.path.join(self.dumps, "classicmangos.sql"), "ab") as f:
                f.write(world_extra)
        code, out = build(["--server", self.srv_dir, "--mariadb", self.mdb, "--db", self.dumps, "--version", version,
                           "--out", self.dist, "--base-url", self.web.url("/dl"), "--commit", "test"])
        self.assertEqual(code, 0, out)
        zname = f"OpenVanilla-Solo-{version}.zip"
        with open(os.path.join(self.dist, zname), "rb") as f:
            self.web.files["/dl/" + zname] = f.read()
        with open(os.path.join(self.dist, "solo.json"), "rb") as f:
            manifest = json.loads(f.read())
        manifest["sql"] = []  # the checkout's realm/classicplus is newer anyway
        self.web.files["/solo.json"] = json.dumps(manifest).encode()

    def session(self, rec):
        return P.SoloSession(self.root, rec, manifest_url=self.web.url("/solo.json"),
                             client=os.path.join(self.wow, "WoW.exe"), settings={})

    def db_query(self, sql, db=None):
        paths = P.SoloPaths(self.root)
        state = P.load_state(paths)
        d = P.SoloDB(paths, state)
        d.start()
        try:
            return d.query(sql, db)
        finally:
            d.shutdown()

    def assert_all_stopped(self):
        for name, port in self.ports.items():
            self.assertFalse(P.is_port_open(port), f"{name} port {port} still open")
        self.assertFalse(os.path.exists(os.path.join(self.root, "run.json")))

    def test_play_solo_first_run_second_run_and_update(self):
        rec = _Rec()
        self.assertEqual(self.session(rec).run(), 0)

        game = F.read_json(self.game_out)
        self.assertEqual(game["realmlist"].strip(), f"set realmlist 127.0.0.1:{self.ports['realm']}")
        self.assertIn('SET accountName "SOLO"', game["config"])
        if REAL_LOGIN:
            self.assertEqual((game["challenge"], game["proof"]), (0, 0), game)
            self.assertIn("Open Vanilla Solo", game["realms"])
            self.assertIn(f"127.0.0.1:{self.ports['world']}", game["realms"])
        logs = os.path.join(self.root, "logs")
        world = F.read_json(os.path.join(logs, "fake_mangosd.json"))
        self.assertRegex(world["world_db"], r"^\d+$")                         # mangos user + grants work
        self.assertEqual(world["conf"]["BindIP"], "127.0.0.1")
        self.assertEqual(world["conf"]["Console.Enable"], "0")
        self.assertEqual(world["conf"]["mmap.enabled"], "0")
        self.assertTrue(world["conf"]["DataDir"].endswith("/gamedata/"))
        self.assertEqual(world["bots"], ["AiPlayerbot.Enabled = 1"])
        self.assertEqual([c for _, c in world["commands"]], ["saveall", "server shutdown 1"])
        self.assertEqual({u for u, _ in world["commands"]}, {"SOLOADMIN"})
        self.assertIn("-a", world["argv"])
        self.assertIn("-p", world["argv"])
        self.assert_all_stopped()
        self.assertEqual(open(os.path.join(self.wow, "realmlist.wtf")).read().strip(), "set realmlist play.openvanilla.app")
        gd = os.path.join(self.root, "gamedata")
        self.assertTrue(P.has_gamedata(gd))
        self.assertTrue(os.path.isfile(os.path.join(gd, "dbc", "CharStartOutfit.dbc.orig")))
        applied = rec.texts("info")
        self.assertTrue(any("classicplus_races.sql" in t for t in applied))
        stages = " | ".join(rec.texts("stage"))
        for words in ("Downloading the solo server", "Unpacking", "Making the solo world's maps",
                      "Loading the Classic+ world", "Starting the login server", "Starting the game", "Solo stopped"):
            self.assertIn(words, stages)

        # Second run: nothing downloaded, nothing extracted, no SQL re-applied.
        zip_gets = sum(1 for p, _ in self.web.requests if p.endswith(".zip"))
        rec2 = _Rec()
        self.assertEqual(self.session(rec2).run(), 0)
        self.assertEqual(sum(1 for p, _ in self.web.requests if p.endswith(".zip")), zip_gets)
        self.assertFalse(any("Applying" in t for t in rec2.texts("info")), rec2.texts("info"))
        self.assertFalse(any("maps from your game client" in t for t in rec2.texts("stage")))
        self.assert_all_stopped()

        # A character, then a pack update with a new world: the world reloads, the character stays.
        self.db_query("INSERT INTO characters (guid, account, name, race, class, online) VALUES (1, 5, 'Solohero', 1, 1, 0)",
                      "classiccharacters")
        self.publish("1.15.1", world_extra=b"\n-- world fix\nCREATE TABLE solo_world_marker (id INT);\n")
        rec3 = _Rec()
        self.assertEqual(self.session(rec3).run(), 0)
        self.assertTrue(any("Updating the solo server" in t for t in rec3.texts("stage")))
        reapplied = [t for t in rec3.texts("info") if t.startswith("Applying")]
        self.assertTrue(any("races" in t for t in reapplied))
        self.assertFalse(any("magic" in t for t in reapplied))                  # classicrealmd untouched
        self.assertEqual(self.db_query("SELECT name FROM characters", "classiccharacters").strip(), "Solohero")
        self.assertEqual(self.db_query("SHOW TABLES LIKE 'solo_world_marker'", "classicmangos").strip(), "solo_world_marker")
        self.assertEqual(F.read_json(os.path.join(self.root, "pack.json"))["version"], "1.15.1")
        self.assert_all_stopped()

    def test_no_play_leaves_servers_for_solo_stop(self):
        rec = _Rec()
        s = P.SoloSession(self.root, rec, manifest_url=self.web.url("/solo.json"),
                          client=os.path.join(self.wow, "WoW.exe"), settings={}, play=False)
        try:
            self.assertEqual(s.run(), 0)
            self.assertTrue(P.is_port_open(self.ports["world"]))
            self.assertTrue(F.read_json(os.path.join(self.root, "run.json"))["detached"])
        finally:
            P.solo_stop(self.root, _Rec())
        self.assert_all_stopped()

    def test_offline_first_run_says_so(self):
        s = P.SoloSession(self.root, _Rec(), manifest_url="http://127.0.0.1:9/solo.json",
                          client=os.path.join(self.wow, "WoW.exe"), settings={})
        with self.assertRaises(P.SoloError) as cm:
            s.run()
        self.assertIn("Connect to the internet once", str(cm.exception))


class _Rec(P.Reporter):
    def __init__(self):
        self.events = []

    def stage(self, key, text):
        self.events.append(("stage", text))

    def info(self, text):
        self.events.append(("info", text))

    def warn(self, text):
        self.events.append(("warn", text))

    def texts(self, kind):
        return [t for k, t in self.events if k == kind]


if __name__ == "__main__":
    unittest.main()
