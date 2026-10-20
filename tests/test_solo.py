"""Play Solo launcher logic (play_local.py): download/resume/verify, unpack, config writing, map data,
SQL updates, client pointing, server start/stop with fake processes, the busy-realm thresholds.

    python3 -m unittest tests.test_solo -v
"""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import solo_fakes as F  # noqa: E402
import play_local as P  # noqa: E402


class Recorder(P.Reporter):
    def __init__(self):
        self.events = []

    def stage(self, key, text):
        self.events.append(("stage", key, text))

    def progress(self, done, total=None, text=None):
        self.events.append(("progress", done, total, text))

    def info(self, text):
        self.events.append(("info", text))

    def warn(self, text):
        self.events.append(("warn", text))

    def texts(self, kind):
        return [e[-1] for e in self.events if e[0] == kind]


class TempDir(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="solo-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def p(self, *parts):
        return os.path.join(self.tmp, *parts)


# =========================================================================== download

class DownloadTests(TempDir):
    def setUp(self):
        super().setUp()
        self.data = os.urandom(300_000)
        self.sha = hashlib.sha256(self.data).hexdigest()
        self.srv = F.FileServer({"/pack.zip": self.data})
        self.addCleanup(self.srv.close)
        self.dest = self.p("dl", "pack.zip")

    def get(self, **kw):
        return P.download(self.srv.url("/pack.zip"), self.dest, kw.pop("sha", self.sha), kw.pop("size", len(self.data)),
                          kw.pop("reporter", Recorder()), sleep=lambda s: None, chunk=64 * 1024, **kw)

    def test_full_download_verifies_and_moves_into_place(self):
        rec = Recorder()
        self.get(reporter=rec)
        self.assertEqual(open(self.dest, "rb").read(), self.data)
        self.assertFalse(os.path.exists(self.dest + ".part"))
        done = [e for e in rec.events if e[0] == "progress" and e[2]]
        self.assertEqual(done[-1][1], len(self.data))

    def test_resumes_a_partial_download_with_a_range_request(self):
        F.write(self.dest + ".part", self.data[:100_000])
        self.get()
        self.assertEqual(self.srv.requests[0][1], "bytes=100000-")
        self.assertEqual(open(self.dest, "rb").read(), self.data)

    def test_server_ignoring_range_restarts_cleanly(self):
        F.write(self.dest + ".part", self.data[:100_000])
        self.srv.ignore_range = True
        self.get()
        self.assertEqual(open(self.dest, "rb").read(), self.data)

    def test_dropped_connection_retries_from_where_it_stopped(self):
        self.srv.drop_after = 120_000
        self.get()
        self.assertEqual(open(self.dest, "rb").read(), self.data)
        self.assertGreaterEqual(len(self.srv.requests), 2)
        self.assertTrue(self.srv.requests[1][1].startswith("bytes="))

    def test_server_error_is_retried(self):
        self.srv.fail_first = 503
        self.get()
        self.assertEqual(open(self.dest, "rb").read(), self.data)

    def test_checksum_mismatch_deletes_the_part_and_says_so(self):
        with self.assertRaises(P.SoloError) as cm:
            self.get(sha="0" * 64)
        self.assertIn("checksum", str(cm.exception))
        self.assertFalse(os.path.exists(self.dest + ".part"))
        self.assertFalse(os.path.exists(self.dest))

    def test_complete_part_is_only_verified(self):
        F.write(self.dest + ".part", self.data)
        self.get()
        self.assertEqual(self.srv.requests, [])  # nothing left to fetch
        self.assertEqual(open(self.dest, "rb").read(), self.data)

    def test_oversized_part_is_discarded(self):
        F.write(self.dest + ".part", self.data + b"junk")
        self.get()
        self.assertEqual(open(self.dest, "rb").read(), self.data)

    def test_already_downloaded_and_good_is_kept(self):
        F.write(self.dest, self.data)
        self.get()
        self.assertEqual(self.srv.requests, [])

    def test_missing_file_is_a_plain_error(self):
        with self.assertRaises(P.SoloError) as cm:
            P.download(self.srv.url("/nope.zip"), self.dest, self.sha, 10, sleep=lambda s: None)
        self.assertIn("isn't on the download server", str(cm.exception))

    def test_cancel_keeps_the_part_for_later(self):
        cancel = threading.Event()

        class CancelAfterFirst(Recorder):
            def progress(self, done, total=None, text=None):
                if done > 0:
                    cancel.set()

        with self.assertRaises(P.Cancelled):
            self.get(reporter=CancelAfterFirst(), cancel=cancel)
        self.assertTrue(os.path.getsize(self.dest + ".part") > 0)
        cancel.clear()
        self.get()
        self.assertEqual(open(self.dest, "rb").read(), self.data)


class ManifestTests(unittest.TestCase):
    good = {"format": 1, "version": "1.15.0", "url": "https://example.org/p.zip", "sha256": "a" * 64, "size": 10}

    def test_good_manifest(self):
        self.assertEqual(P.validate_manifest(dict(self.good))["version"], "1.15.0")

    def test_bad_manifests(self):
        for bad in ({**self.good, "format": 2}, {**self.good, "sha256": "xyz"}, {**self.good, "url": "http://evil/p.zip"},
                    {k: v for k, v in self.good.items() if k != "size"}, []):
            with self.assertRaises(P.SoloError):
                P.validate_manifest(bad)


class PackStatusTests(TempDir):
    def test_states(self):
        srv = F.FileServer({})
        self.addCleanup(srv.close)
        sess = P.SoloSession(self.p("solo"), Recorder(), manifest_url=srv.url("/solo.json"))
        with self.assertRaises(P.SoloError) as cm:                           # not published yet
            sess.pack_status()
        self.assertIn("isn't published yet", str(cm.exception))
        srv.files["/solo.json"] = json.dumps(ManifestTests.good).encode()
        self.assertEqual(sess.pack_status()[0], "missing")
        F.write(os.path.join(sess.paths.bin, "mangosd.exe"), b"MZ")
        P.write_json(sess.paths.pack_json, {"format": 1, "version": "1.14.0"})
        self.assertEqual(sess.pack_status()[0], "update")
        P.write_json(sess.paths.pack_json, {"format": 1, "version": "1.15.0"})
        self.assertEqual(sess.pack_status()[0], "ok")
        del srv.files["/solo.json"]
        self.assertEqual(sess.pack_status(), ("ok", None))                   # installed: plays offline
        offline = P.SoloSession(self.p("solo2"), Recorder(), manifest_url="http://127.0.0.1:9/solo.json")
        self.assertEqual(offline.pack_status()[0], "offline")


# =========================================================================== unpack

def make_pack_zip(path, files, tamper=None, extra=None):
    pack = {"format": 1, "version": "1.0", "files": {k: {"size": len(v), "sha256": hashlib.sha256(v).hexdigest()}
                                                      for k, v in files.items()}}
    with zipfile.ZipFile(path, "w") as z:
        for k, v in files.items():
            z.writestr(k, tamper.get(k, v) if tamper else v)
        for k, v in (extra or {}).items():
            z.writestr(k, v)
        z.writestr("pack.json", json.dumps(pack))
    return path


class UnpackTests(TempDir):
    files = {"bin/mangosd.exe": b"MZ world", "bin/realmd.exe": b"MZ login", "mariadb/bin/mariadbd.exe": b"MZ db",
             "db/classicmangos.sql.gz": b"\x1f\x8b fake", "conf/my.ini": b"[mysqld]", "README.txt": b"hi"}

    def test_installs_and_keeps_player_data(self):
        paths = P.SoloPaths(self.p("solo"))
        F.write(os.path.join(paths.data, "ibdata1"), b"my characters")
        F.write(os.path.join(paths.custom, "mangosd.conf"), "Rate.XP.Kill = 2\n")
        F.write(os.path.join(paths.bin, "old.dll"), b"from the old pack")
        pack = P.unpack_pack(make_pack_zip(self.p("p.zip"), self.files), paths, Recorder())
        self.assertEqual(pack["version"], "1.0")
        self.assertEqual(open(os.path.join(paths.bin, "mangosd.exe"), "rb").read(), b"MZ world")
        self.assertFalse(os.path.exists(os.path.join(paths.bin, "old.dll")))  # the pack's folders are replaced
        self.assertEqual(open(os.path.join(paths.data, "ibdata1"), "rb").read(), b"my characters")
        self.assertTrue(os.path.isfile(os.path.join(paths.custom, "mangosd.conf")))
        self.assertTrue(paths.pack_installed())
        self.assertFalse(any(n.startswith(".") for n in os.listdir(paths.root)))

    def test_tampered_file_is_refused_and_old_install_kept(self):
        paths = P.SoloPaths(self.p("solo"))
        F.write(os.path.join(paths.bin, "mangosd.exe"), b"the working one")
        z = make_pack_zip(self.p("p.zip"), self.files, tamper={"bin/realmd.exe": b"MZ evil"})
        with self.assertRaises(P.SoloError) as cm:
            P.unpack_pack(z, paths)
        self.assertIn("checksum", str(cm.exception))
        self.assertEqual(open(os.path.join(paths.bin, "mangosd.exe"), "rb").read(), b"the working one")

    def test_zip_slip_and_strays_are_refused(self):
        paths = P.SoloPaths(self.p("solo"))
        for extra in ({"../evil.txt": b"x"}, {"bin/../../evil.txt": b"x"}, {"C:/Windows/evil.dll": b"x"},
                      {"data/ibdata1": b"overwrite my characters"}, {"launcher.exe": b"x"}):
            with self.assertRaises(P.SoloError):
                P.unpack_pack(make_pack_zip(self.p("p.zip"), self.files, extra=extra), paths)
        self.assertFalse(os.path.exists(self.p("evil.txt")))
        self.assertFalse(os.path.exists(os.path.join(paths.data, "ibdata1")))


# =========================================================================== config files

class ConfigTests(TempDir):
    def test_apply_overrides(self):
        dist = ("# header\nDataDir = \".\"\n# AiPlayerbot.SyncLevelWithPlayers = 0\nEnable = 1\n[Other]\nEnable = 1\n"
                "AuctionHouseBot.Chance.Buy  = 10\n")
        out = P.apply_overrides(dist, [("DataDir", '"C:/OpenVanilla/solo/gamedata/"'), ("AiPlayerbot.SyncLevelWithPlayers", "1"),
                                       ("Enable", "0"), ("AuctionHouseBot.Chance.Buy", "30"), ("New.Key", "7")])
        lines = out.splitlines()
        self.assertIn('DataDir = "C:/OpenVanilla/solo/gamedata/"', lines)
        self.assertIn("AiPlayerbot.SyncLevelWithPlayers = 1", lines)          # uncommented in place
        self.assertEqual([l for l in lines if l.startswith("Enable")], ["Enable = 0", "Enable = 1"])  # first only
        self.assertIn("AuctionHouseBot.Chance.Buy = 30", lines)
        self.assertEqual(lines[-1], "New.Key = 7")                            # appended
        self.assertEqual(lines[0], "# header")

    def test_parse_overrides_skips_comments(self):
        self.assertEqual(P.parse_overrides("# c\n\n[Sec]\nA = 1\nB.C = \"x y\"\n"), [("A", "1"), ("B.C", '"x y"')])

    def test_unknown_template_name_is_an_error(self):
        with self.assertRaises(KeyError):
            P.render_template("x = ${NOPE}", {})

    def make_paths(self):
        paths = P.SoloPaths(self.p("solo"))
        F.write(os.path.join(paths.bin, "mangosd.conf.dist"), F.MANGOSD_DIST)
        F.write(os.path.join(paths.bin, "realmd.conf.dist"), F.REALMD_DIST)
        F.write(os.path.join(paths.bin, "aiplayerbot.conf.dist"), F.AIPLAYERBOT_DIST)
        shutil.copytree(os.path.join(F.ROOT, "solo", "templates"), paths.conf)
        return paths

    def test_write_configs_end_to_end(self):
        paths = self.make_paths()
        state = P.load_state(paths)
        F.write(os.path.join(paths.custom, "aiplayerbot.conf"), "AiPlayerbot.MaxRandomBots = 200\n")
        out = P.write_configs(paths, state)
        self.assertEqual(set(out), {"mangosd.conf", "realmd.conf", "aiplayerbot.conf", "my.ini"})
        m = open(out["mangosd.conf"]).read()
        self.assertIn(f'WorldDatabaseInfo = "127.0.0.1;3311;mangos;{state["db_password"]};classicmangos"', m)
        self.assertIn('BindIP = "127.0.0.1"', m)
        self.assertIn("Console.Enable = 0", m)
        self.assertIn("SOAP.Enabled = 1", m)
        self.assertIn("SOAP.Port = 7879", m)
        self.assertIn("mmap.enabled = 0", m)                                  # no movement maps on disk
        self.assertIn('DataDir = "' + P.conf_path(paths.gamedata) + '/"', m)
        self.assertNotIn("${", m)
        r = open(out["realmd.conf"]).read()
        self.assertIn("RealmServerPort = 3724", r)
        self.assertIn('BindIP = "127.0.0.1"', r)
        bots = open(out["aiplayerbot.conf"]).read()
        self.assertIn("AiPlayerbot.Enabled = 1", bots)
        self.assertIn("AiPlayerbot.MaxRandomBots = 200", bots)                # the player's custom file wins
        self.assertIn("AiPlayerbot.SyncLevelWithPlayers = 1", bots)
        ini = open(out["my.ini"]).read()
        self.assertIn("port=3311", ini)
        self.assertIn("bind-address=127.0.0.1", ini)
        self.assertIn('datadir="' + P.conf_path(paths.data) + '"', ini)
        F.write(os.path.join(paths.gamedata, "mmaps", "000.mmap"), b"x")
        self.assertIn("mmap.enabled = 1", open(P.write_configs(paths, state)["mangosd.conf"]).read())

    def test_state_keeps_passwords_and_ports(self):
        paths = P.SoloPaths(self.p("solo"))
        a = P.load_state(paths)
        a["ports"]["db"] = 4000
        P.save_state(paths, a)
        b = P.load_state(paths)
        self.assertEqual(a["db_password"], b["db_password"])
        self.assertRegex(b["db_root_password"], r"^[0-9a-f]{32}$")
        self.assertEqual(b["ports"]["db"], 4000)
        self.assertEqual(b["ports"]["world"], 8085)


# =========================================================================== map data

class GameDataTests(TempDir):
    def fake_gamedata(self, d, mmaps=False):
        F.write(os.path.join(d, "dbc", "Map.dbc"), b"WDBC")
        F.write(os.path.join(d, "maps", "0003232.map"), b"x")
        F.write(os.path.join(d, "vmaps", "000.vmtree"), b"x")
        if mmaps:
            F.write(os.path.join(d, "mmaps", "000.mmap"), b"x")
        return d

    def test_detection(self):
        d = self.fake_gamedata(self.p("gd"))
        self.assertTrue(P.has_gamedata(d))
        self.assertFalse(P.has_mmaps(d))
        os.remove(os.path.join(d, "vmaps", "000.vmtree"))
        self.assertFalse(P.has_gamedata(d))

    def test_adopt_copies_dbc_and_links_the_rest(self):
        src = self.fake_gamedata(self.p("spp", "Data"), mmaps=True)
        paths = P.SoloPaths(self.p("solo"))
        P.adopt_gamedata(src, paths)
        self.assertTrue(P.has_gamedata(paths.gamedata))
        self.assertTrue(P.has_mmaps(paths.gamedata))
        self.assertFalse(os.path.islink(os.path.join(paths.gamedata, "dbc")))  # ours to patch
        self.assertTrue(os.path.islink(os.path.join(paths.gamedata, "maps")))

    def test_candidates_include_the_client_folder(self):
        paths = P.SoloPaths(self.p("solo"))
        c = P.gamedata_candidates(paths, self.p("wow"))
        self.assertEqual(c[0], paths.gamedata)
        self.assertIn(self.p("wow"), c)

    def make_tools(self):
        tools = self.p("tools")
        F.script(os.path.join(tools, "ad.exe"), F.FAKE_AD)
        F.script(os.path.join(tools, "vmap_extractor.exe"), F.FAKE_VMAP_EXTRACTOR)
        F.script(os.path.join(tools, "vmap_assembler.exe"), F.FAKE_VMAP_ASSEMBLER)
        F.script(os.path.join(tools, "MoveMapGen.exe"), F.FAKE_MOVEMAPGEN)
        dbcs = self.p("dbcsrc")
        F.write(os.path.join(dbcs, "CharStartOutfit.dbc"), F.char_start_outfit_dbc())
        os.environ["FAKE_DBC_SRC"] = dbcs
        self.addCleanup(os.environ.pop, "FAKE_DBC_SRC", None)
        return tools

    def test_extractors_run_with_progress(self):
        tools = self.make_tools()
        client = self.p("wow")
        F.write(os.path.join(client, "Data", "base.MPQ"), b"not really")
        rec = Recorder()
        out = self.p("solo", "gamedata")
        P.run_extractors(client, out, tools, rec, mmaps=True, log_path=self.p("extract.log"))
        self.assertTrue(P.has_gamedata(out))
        self.assertTrue(P.has_mmaps(out))
        self.assertFalse(os.path.isdir(os.path.join(out, "Buildings")))
        fracs = [e[1] for e in rec.events if e[0] == "progress" and e[2] == 100]
        self.assertTrue(fracs and max(fracs) >= 85 and fracs == sorted(fracs))
        self.assertEqual(len(rec.texts("stage")), 4)
        self.assertIn("Extract Azeroth (1/3)", open(self.p("extract.log")).read())

    def test_extractors_need_the_tools_and_a_client(self):
        with self.assertRaises(P.SoloError) as cm:
            P.run_extractors(self.p("wow"), self.p("out"), self.p("empty"))
        self.assertIn("extractors", str(cm.exception))
        tools = self.make_tools()
        with self.assertRaises(P.SoloError) as cm:
            P.run_extractors(self.p("wow"), self.p("out"), tools)
        self.assertIn(".MPQ", str(cm.exception))

    def test_failing_extractor_is_reported(self):
        tools = self.make_tools()
        F.script(os.path.join(tools, "vmap_extractor.exe"), "import sys\nprint('boom')\nsys.exit(3)\n")
        F.write(os.path.join(self.p("wow"), "Data", "base.MPQ"), b"x")
        with self.assertRaises(P.SoloError) as cm:
            P.run_extractors(self.p("wow"), self.p("out"), tools, log_path=self.p("x.log"))
        self.assertIn("exit 3", str(cm.exception))

    def test_server_dbc_fixups_use_the_live_scripts(self):
        paths = P.SoloPaths(self.p("solo"))
        F.write(os.path.join(paths.gamedata, "dbc", "CharStartOutfit.dbc"), F.char_start_outfit_dbc())
        F.write(os.path.join(paths.gamedata, "dbc", "SkillRaceClassInfo.dbc"), F.skill_race_class_dbc())
        done = P.fix_server_dbcs(paths, "1\t1\n3\t1\n", Recorder())
        self.assertEqual(sorted(done), ["CharStartOutfit.dbc", "SkillRaceClassInfo.dbc"])
        out = open(os.path.join(paths.gamedata, "dbc", "CharStartOutfit.dbc"), "rb").read()
        self.assertGreater(int.from_bytes(out[4:8], "little"), 1)            # outfits for the new pairs
        self.assertTrue(os.path.isfile(os.path.join(paths.gamedata, "dbc", "CharStartOutfit.dbc.orig")))
        srci = open(os.path.join(paths.gamedata, "dbc", "SkillRaceClassInfo.dbc"), "rb").read()
        race_mask = int.from_bytes(srci[20 + 8:20 + 12], "little")
        self.assertTrue(race_mask & 0b100)                                   # Dwarf (3) Warriors keep Swords
        again = P.fix_server_dbcs(paths, "1\t1\n3\t1\n")                     # from .orig: same result
        self.assertEqual(open(os.path.join(paths.gamedata, "dbc", "CharStartOutfit.dbc"), "rb").read(), out)
        self.assertEqual(len(again), 2)


# =========================================================================== SQL

class SqlTests(TempDir):
    def test_targets_from_the_live_files(self):
        cp = os.path.join(F.ROOT, "realm", "classicplus")
        acct = self.p("accounts.sql")
        with open(acct, "w", encoding="utf-8") as f:
            f.write("-- example (run against classicrealmd; idempotent).\n")
        self.assertEqual(P.sql_target_db(acct), "classicrealmd")
        self.assertEqual(P.sql_target_db(os.path.join(cp, "classicplus_races.sql")), "classicmangos")

    def test_order_runs_races_before_weapons(self):
        cp = os.path.join(F.ROOT, "realm", "classicplus")
        files = {n: os.path.join(cp, n) for n in os.listdir(cp) if n.endswith(".sql")}
        order = P.order_sql(files)
        self.assertEqual(order[0], "classicplus_races.sql")
        self.assertLess(order.index("classicplus_races.sql"), order.index("classicplus_weapons.sql"))
        self.assertEqual(sorted(order), sorted(files))

    def test_run_after_hint(self):
        a = F.write(self.p("a_late.sql"), "-- run after z_first.sql\nSELECT 1;\n")
        z = F.write(self.p("z_first.sql"), "SELECT 2;\n")
        self.assertEqual(P.order_sql({"a_late.sql": a, "z_first.sql": z}), ["z_first.sql", "a_late.sql"])

    def test_forge_dev_sql_runs_last(self):
        paths = P.SoloPaths(self.p("solo"))
        F.write(os.path.join(paths.forge_dev, "forge_dev_ember.sql"), "-- dev\n")
        c = P.sql_candidates(paths)
        self.assertIn("forge_dev_ember.sql", c)
        files = {n: ps[0] for n, ps in c.items()}
        self.assertEqual(P.order_sql(files)[-1], "forge_dev_ember.sql")

    def test_candidates_prefer_checkout_then_live_then_pack(self):
        paths = P.SoloPaths(self.p("solo"))
        F.write(os.path.join(paths.sql, "classicplus_races.sql"), "-- pack\n")
        F.write(os.path.join(paths.sql, "only_in_pack.sql"), "-- pack\n")
        F.write(os.path.join(paths.sql_live, "only_in_pack.sql"), "-- live\n")
        c = P.sql_candidates(paths)
        self.assertTrue(c["classicplus_races.sql"][0].startswith(os.path.join(F.ROOT, "realm", "classicplus")))
        self.assertTrue(c["only_in_pack.sql"][0].startswith(paths.sql_live))
        self.assertFalse(any("pending" in p for ps in c.values() for p in ps))

    def test_fetch_live_sql_checks_checksums(self):
        good, bad = b"-- new races\n", b"-- tampered\n"
        srv = F.FileServer({"/r.sql": good, "/w.sql": bad})
        self.addCleanup(srv.close)
        paths = P.SoloPaths(self.p("solo"))
        # https only in production; the test server is http, so allow it by patching the check's prefix
        items = [{"name": "classicplus_races.sql", "sha256": hashlib.sha256(good).hexdigest(), "url": srv.url("/r.sql")},
                 {"name": "classicplus_weapons.sql", "sha256": hashlib.sha256(good).hexdigest(), "url": srv.url("/w.sql")},
                 {"name": "../evil.sql", "sha256": "0" * 64, "url": srv.url("/r.sql")}]
        orig = str.startswith
        rec = Recorder()

        class Url(str):
            def startswith(self, p, *a):
                return True if p == "https://" else orig(self, p, *a)

        for it in items:
            it["url"] = Url(it["url"])
        self.assertEqual(P.fetch_live_sql({"sql": items}, paths, reporter=rec), 1)
        self.assertEqual(open(os.path.join(paths.sql_live, "classicplus_races.sql"), "rb").read(), good)
        self.assertFalse(os.path.exists(os.path.join(paths.sql_live, "classicplus_weapons.sql")))
        self.assertTrue(any("checksum" in w for w in rec.texts("warn")))
        self.assertEqual(P.fetch_live_sql({"sql": items}, paths), 0)        # already current

    def test_srp6_verifier_matches_the_client_math(self):
        salt = bytes(range(32))
        s, v = P.srp6_verifier("solo", "solo", salt)
        wire_salt = bytes.fromhex(s)[::-1]                                   # what realmd sends
        x = int.from_bytes(hashlib.sha1(wire_salt + hashlib.sha1(b"SOLO:SOLO").digest()).digest(), "little")
        self.assertEqual(int(v, 16), pow(P.SRP_G, x, P.SRP_N))
        self.assertEqual(len(s), 64)
        self.assertIn("ON DUPLICATE KEY UPDATE", P.account_sql("solo", "solo", 0, salt))
        with self.assertRaises(ValueError):
            P.account_sql("x'; DROP TABLE account; --", "p", 0)


# =========================================================================== the game client

class ClientTests(TempDir):
    def state(self, realm=3724):
        return {"ports": {"db": 3311, "realm": realm, "world": 8085, "soap": 7879}}

    def test_point_and_restore_stock_client(self):
        wow = self.p("wow")
        F.write(os.path.join(wow, "realmlist.wtf"), "set realmlist play.openvanilla.app\r\n")
        F.write(os.path.join(wow, "WTF", "Config.wtf"), 'SET gxResolution "1024x768"\nSET accountName "LIVEGUY"\n')
        restore = P.point_client_at_solo(wow, self.state())
        self.assertEqual(open(os.path.join(wow, "realmlist.wtf")).read().strip(), "set realmlist 127.0.0.1")
        cfg = open(os.path.join(wow, "WTF", "Config.wtf")).read()
        self.assertIn('SET accountName "SOLO"', cfg)
        self.assertIn('SET realmName "Open Vanilla Solo"', cfg)
        self.assertNotIn("LIVEGUY", cfg)
        # the game changes an unrelated setting while playing; that stays
        with open(os.path.join(wow, "WTF", "Config.wtf"), "a") as f:
            f.write('SET gxWindow "1"\n')
        restore()
        self.assertEqual(open(os.path.join(wow, "realmlist.wtf")).read().strip(), "set realmlist play.openvanilla.app")
        cfg = open(os.path.join(wow, "WTF", "Config.wtf")).read()
        self.assertIn('SET accountName "LIVEGUY"', cfg)
        self.assertNotIn("SOLO", cfg)
        self.assertIn('SET gxWindow "1"', cfg)

    def test_point_client_fresh_folder_and_custom_port(self):
        wow = self.p("wow")
        os.makedirs(wow)
        restore = P.point_client_at_solo(wow, self.state(3725))
        self.assertIn("127.0.0.1:3725", open(os.path.join(wow, "realmlist.wtf")).read())
        restore()
        self.assertFalse(os.path.exists(os.path.join(wow, "realmlist.wtf")))
        self.assertNotIn("SOLO", open(os.path.join(wow, "WTF", "Config.wtf")).read())

    def test_find_client(self):
        wow = self.p("wow")
        F.write(os.path.join(wow, "WoW.exe"), b"MZ")
        self.assertEqual(P.find_client(None, {"wow_folder": wow})[:2], ("exe", os.path.join(wow, "WoW.exe")))
        eng = F.write(self.p("app", "OpenWoW.exe"), b"MZ")
        kind, exe, data = P.find_client(eng, {"wow_folder": wow})
        self.assertEqual((kind, exe, data), ("engine", eng, wow))
        self.assertEqual(P.find_client(None, {})[:2], (None, None))

    def test_client_root_accepts_the_data_folder(self):
        wow = self.p("wow")
        os.makedirs(os.path.join(wow, "Data"))
        self.assertEqual(P.client_root(os.path.join(wow, "Data")), wow)
        self.assertEqual(P.client_root(wow), wow)
        self.assertEqual(P.client_env(self.state(), os.path.join(wow, "Data"))["WOW_DATA"], os.path.join(wow, "Data"))

    def test_engine_env_signs_in(self):
        wow = self.p("wow")
        os.makedirs(os.path.join(wow, "Data"))
        env = P.client_env(self.state(), wow)
        self.assertEqual((env["WOW_HOST"], env["WOW_USER"], env["WOW_PASS"], env["WOW_REALM"]),
                         ("127.0.0.1", "SOLO", "SOLO", "Open Vanilla Solo"))
        self.assertEqual(env["WOW_DATA"], os.path.join(wow, "Data"))


# =========================================================================== servers with fake processes

class ServerTests(TempDir):
    def setUp(self):
        super().setUp()
        self.paths = P.SoloPaths(self.p("solo"))
        F.write(os.path.join(self.paths.bin, "mangosd.exe"), b"MZ")
        F.write(os.path.join(self.paths.bin, "realmd.exe"), b"MZ")
        self.state = {"ports": dict(P.DEFAULT_PORTS), "soap_password": "a" * 32}
        self.clock = F.FakeClock()
        self.open_ports = set()
        self.spawned = []
        self.soap_calls = []
        self.configs = {"realmd.conf": "etc/realmd.conf", "mangosd.conf": "etc/mangosd.conf",
                        "aiplayerbot.conf": "etc/aiplayerbot.conf", "ahbot.conf": "etc/ahbot.conf"}

    def servers(self, opens_after=None, proc_opts=None, soap=None):
        opens_after = opens_after or {"realmd": 2, "mangosd": 5}
        proc_opts = proc_opts or {}
        port_of = {"realmd": self.state["ports"]["realm"], "mangosd": self.state["ports"]["world"]}

        def popen(argv, **kw):
            name = os.path.basename(argv[0]).split(".")[0]
            self.spawned.append((name, argv, kw))
            proc = F.FakeProc(argv, **proc_opts.get(name, {}))
            proc.started_at = self.clock()
            proc.name = name
            return proc

        def port_open(port):
            for name, proc in list(s.procs.items()):
                if port == port_of.get(name) and proc.returncode is None \
                        and self.clock() - proc.started_at >= opens_after.get(name, 0):
                    return True
            return port in self.open_ports

        def fake_soap(cmd, user, pw, port):
            self.soap_calls.append((cmd, user, pw, port))
            if cmd.startswith("server shutdown"):
                s.procs["mangosd"].returncode = 0

        s = P.ServerSet(self.paths, self.state, popen=popen, port_open=port_open, sleep=self.clock.sleep,
                        soap=soap or fake_soap, clock=self.clock)
        return s

    def test_start_order_flags_and_arguments(self):
        s = self.servers()
        rec = Recorder()
        s.start(self.configs, rec)
        self.assertEqual([n for n, _, _ in self.spawned], ["realmd", "mangosd"])
        self.assertEqual(self.spawned[0][1][1:], ["-c", "etc/realmd.conf"])
        self.assertEqual(self.spawned[1][1][1:], ["-c", "etc/mangosd.conf", "-a", "etc/ahbot.conf", "-p", "etc/aiplayerbot.conf"])
        for _, _, kw in self.spawned:
            self.assertIs(kw["stdin"], subprocess.DEVNULL)
            self.assertEqual(kw["cwd"], self.paths.bin)
        self.assertTrue(self.state["world_started_once"])
        self.assertTrue(any("first start" in t for t in rec.texts("stage")))

    def test_world_crash_while_starting_shows_the_log(self):
        F.write(os.path.join(self.paths.logs, "Server.log"), "Loading...\nERROR: Could not connect to world database\n")
        s = self.servers(proc_opts={"mangosd": {"exits_after": 3}})
        with self.assertRaises(P.SoloError) as cm:
            s.start(self.configs)
        self.assertIn("stopped while starting", str(cm.exception))
        self.assertIn("Could not connect to world database", str(cm.exception))

    def test_world_timeout(self):
        s = self.servers(opens_after={"realmd": 1, "mangosd": 10_000})
        with self.assertRaises(P.SoloError) as cm:
            s.start(self.configs, world_timeout=30)
        self.assertIn("didn't start in time", str(cm.exception))

    def test_cancel_while_waiting(self):
        cancel = threading.Event()
        cancel.set()
        s = self.servers()
        with self.assertRaises(P.Cancelled):
            s.start(self.configs, cancel=cancel)

    def test_ports_in_use_are_reported_before_anything_starts(self):
        s = self.servers()
        self.open_ports.add(8085)
        with self.assertRaises(P.SoloError) as cm:
            s.check_ports_free()
        self.assertIn("8085", str(cm.exception))
        self.assertEqual(self.spawned, [])

    def test_orderly_stop_saves_through_soap(self):
        s = self.servers()
        s.start(self.configs)
        world, login = s.procs["mangosd"], s.procs["realmd"]
        s.stop(Recorder())
        self.assertEqual([c[0] for c in self.soap_calls], ["saveall", "server shutdown 1"])
        self.assertEqual(self.soap_calls[0][1:], ("SOLOADMIN", "a" * 32, 7879))
        self.assertFalse(world.killed)
        self.assertTrue(login.terminated)
        self.assertEqual(s.procs, {})

    def test_stuck_world_is_killed_after_the_grace_period(self):
        def deaf_soap(cmd, *a):
            self.soap_calls.append(cmd)   # takes the command, never exits

        s = self.servers(soap=deaf_soap, proc_opts={"realmd": {"ignore_terminate": True}})
        s.start(self.configs)
        world, login = s.procs["mangosd"], s.procs["realmd"]
        t0 = self.clock()
        s.stop(grace=60)
        self.assertTrue(world.killed)
        self.assertTrue(login.killed)
        self.assertGreaterEqual(self.clock() - t0, 60)

    def test_soap_down_falls_back_to_terminate(self):
        def broken_soap(*a):
            raise P.SoloError("no soap")

        s = self.servers(soap=broken_soap)
        s.start(self.configs)
        world = s.procs["mangosd"]
        s.stop()
        self.assertTrue(world.terminated)


class WindowsFlagsTests(unittest.TestCase):
    """The Windows-only Popen arguments, checked here with a stand-in STARTUPINFO."""

    def test_hidden_flags(self):
        class SI:
            def __init__(self):
                self.dwFlags = 0
                self.wShowWindow = 1

        saved = (P.IS_WINDOWS, getattr(subprocess, "STARTUPINFO", None), getattr(subprocess, "STARTF_USESHOWWINDOW", None))
        P.IS_WINDOWS = True
        subprocess.STARTUPINFO, subprocess.STARTF_USESHOWWINDOW = SI, 1
        try:
            kw = P.hidden_popen_kwargs()
            self.assertEqual(kw["creationflags"], P.CREATE_NO_WINDOW | P.CREATE_NEW_PROCESS_GROUP)
            self.assertFalse(kw["creationflags"] & P.DETACHED_PROCESS)       # never with CREATE_NO_WINDOW
            self.assertEqual((kw["startupinfo"].dwFlags & 1, kw["startupinfo"].wShowWindow), (1, 0))
            self.assertEqual(P.hidden_run_kwargs()["creationflags"], P.CREATE_NO_WINDOW)
            self.assertEqual(P.exe_name("mangosd"), "mangosd.exe")
        finally:
            P.IS_WINDOWS = saved[0]
            for name, v in (("STARTUPINFO", saved[1]), ("STARTF_USESHOWWINDOW", saved[2])):
                if v is None:
                    delattr(subprocess, name)
                else:
                    setattr(subprocess, name, v)

    def test_off_windows_its_own_session(self):
        if not P.IS_WINDOWS:
            self.assertEqual(P.hidden_popen_kwargs(), {"start_new_session": True})


class StaleTests(TempDir):
    def test_stale_servers_are_stopped_only_when_they_are_ours(self):
        paths = P.SoloPaths(self.p("solo"))
        state = {"ports": dict(P.DEFAULT_PORTS), "soap_password": "x"}
        P.write_json(paths.run_file, {"controller": 1, "servers": {"realmd": 11, "mariadb": 12, "mangosd": None}})
        killed = []
        images = {1: "", 11: "realmd.exe", 12: "notepad.exe"}
        P.cleanup_stale(paths, state, Recorder(), alive=lambda pid: pid in images, image=lambda pid: images[pid],
                        kill=killed.append)
        self.assertEqual(killed, [11])                  # pid 12 was reused by another program
        self.assertFalse(os.path.exists(paths.run_file))

    def test_a_live_session_elsewhere_is_not_disturbed(self):
        paths = P.SoloPaths(self.p("solo"))
        P.write_json(paths.run_file, {"controller": 77, "servers": {"realmd": 11}})
        with self.assertRaises(P.SoloError):
            P.cleanup_stale(paths, {"ports": P.DEFAULT_PORTS}, alive=lambda pid: True,
                            image=lambda pid: "openvanilla launcher.exe" if pid == 77 else "realmd.exe", kill=lambda p: None)
        self.assertTrue(os.path.exists(paths.run_file))

    def test_no_record_nothing_to_do(self):
        self.assertFalse(P.cleanup_stale(P.SoloPaths(self.p("solo")), {}))


# =========================================================================== busy realm

class BusyTests(unittest.TestCase):
    def test_thresholds(self):
        cases = [
            ({"reachable": True, "latency_ms": 180, "soap": True, "mariadb": True}, "ok"),
            ({"reachable": True, "latency_ms": P.SLOW_MS - 1, "soap": True}, "ok"),
            ({"reachable": True, "latency_ms": P.SLOW_MS, "soap": True}, "slow"),
            ({"reachable": True, "latency_ms": 200, "soap": False}, "down"),
            ({"reachable": True, "latency_ms": 200, "soap": True, "mariadb": False}, "down"),
            ({"reachable": True, "http": 503, "latency_ms": 90}, "down"),
            ({"reachable": True, "latency_ms": 100, "soap": True, "queue": 12}, "full"),
            ({"reachable": True, "latency_ms": 100, "soap": True, "players": 95, "limit": 100}, "full"),
            ({"reachable": True, "latency_ms": 100, "soap": True, "players": 94, "limit": 100}, "ok"),
            ({"reachable": False, "auth_up": True}, "slow"),
            ({"reachable": False, "auth_up": False}, "down"),
        ]
        for sample, want in cases:
            self.assertEqual(P.classify(sample)[0], want, sample)
        self.assertIn("12 players are in the queue", P.classify(cases[6][0])[1])
        self.assertIn("1 player is", P.classify({"reachable": True, "queue": 1})[1])

    def test_slow_needs_two_samples_down_is_immediate(self):
        t = P.BusyTracker()
        slow = {"reachable": True, "latency_ms": 4000, "soap": True}
        ok = {"reachable": True, "latency_ms": 100, "soap": True}
        self.assertFalse(t.update(slow))
        self.assertTrue(t.update(slow))
        self.assertEqual(t.state, "slow")
        self.assertFalse(t.update(ok))
        self.assertTrue(t.update({"reachable": False}))
        self.assertEqual(t.state, "down")
        self.assertFalse(t.update(ok))

    def test_probe_reads_healthz_and_optional_population(self):
        realm = {"portal": "https://play.example/", "host": "play.example", "port": 3724}
        seen = []

        def fetch(url):
            seen.append(url)
            return 200, {"sqlite": True, "mariadb": True, "soap": True, "world": {"players": 480, "player_limit": 500, "queue": 3}}

        s = P.probe_realm(realm, fetch=fetch)
        self.assertEqual(seen, ["https://play.example/healthz"])
        self.assertEqual((s["players"], s["limit"], s["queue"], s["soap"]), (480, 500, 3, True))
        self.assertEqual(P.classify(s)[0], "full")
        s = P.probe_realm(realm, fetch=lambda u: (200, {"sqlite": True, "mariadb": True, "soap": True, "players_online": 7}))
        self.assertEqual(s["players"], 7)

    def test_probe_falls_back_to_the_login_port(self):
        realm = {"portal": "https://play.example/", "host": "play.example", "port": 3724}

        def down(url):
            raise OSError("connection refused")

        s = P.probe_realm(realm, fetch=down, tcp=lambda h, p: (h, p) == ("play.example", 3724))
        self.assertTrue(s["auth_up"])
        self.assertEqual(P.classify(s)[0], "slow")
        s = P.probe_realm(realm, fetch=down, tcp=lambda h, p: False)
        self.assertEqual(P.classify(s)[0], "down")

    def test_official_realm_from_defaults(self):
        self.assertEqual(P.official_realm()["host"], "play.openvanilla.app")


class CliTests(unittest.TestCase):
    def test_unknown_mode_prints_help(self):
        out = io.StringIO()
        saved = sys.stdout
        sys.stdout = out
        try:
            self.assertEqual(P.main(["nonsense"]), 2)
        finally:
            sys.stdout = saved
        self.assertIn("Play Solo", out.getvalue())


if __name__ == "__main__":
    unittest.main()
