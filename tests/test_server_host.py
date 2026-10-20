"""launcher/server_host.py: HOST > Dedicated server reads the saved openvanilla.json, finds the SPP install,
runs the servers without the Solo account, starts the web backend (frozen: OpenVanilla.exe --run
web-backend), installs missing packages from source, and routes GM commands.

    python -m unittest tests.test_server_host -v
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))
sys.path.insert(0, ROOT)
sys.path.insert(0, HERE)

import layout as L  # noqa: E402
import server_host as SH  # noqa: E402
import spp as S  # noqa: E402
from test_spp import Machine, make_vanilla, touch  # noqa: E402


class DedicatedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lay = L.detect(os.path.join(self.tmp.name, "OpenVanilla"), env={}).ensure()
        self.server = os.path.join(self.tmp.name, "SPP_Classics_V2", "SPP_Server")
        touch(os.path.join(self.server, "Launcher.bat"))
        self.paths = S.SppPaths(self.lay.solo, server=self.server)
        make_vanilla(self.paths)
        self.old_dir = os.path.join(self.tmp.name, "OpenVanilla-Host", "OpenVanilla-Server")
        touch(os.path.join(self.old_dir, "openvanilla.json"),
              json.dumps({"spp_root": self.server, "mysql_user": "root", "mysql_password": "s3cret", "unknown": 1}))

    def tearDown(self):
        self.tmp.cleanup()

    def test_reads_the_saved_openvanilla_json(self):
        cfg = SH.load_config({"server_dir": self.old_dir}, self.lay)
        self.assertEqual(cfg["spp_root"], self.server)
        self.assertEqual(cfg["mysql_password"], "s3cret")
        self.assertNotIn("unknown", cfg)
        paths = SH.resolve_paths(cfg, self.lay, find=lambda: None)
        self.assertEqual(paths.server, self.server)
        SH.save_config(self.lay, dict(cfg, realm_address="192.168.1.9"))
        self.assertEqual(SH.load_config({}, self.lay)["realm_address"], "192.168.1.9")

    def test_falls_back_to_solo_install_or_search(self):
        cfg = SH.load_config({}, self.lay)
        self.assertIsNone(SH.resolve_paths(cfg, self.lay, find=lambda: None))
        self.assertEqual(SH.resolve_paths(cfg, self.lay, find=lambda: self.server).server, self.server)

    def test_runs_without_the_solo_account(self):
        m = Machine()
        cfg = SH.load_config({"server_dir": self.old_dir}, self.lay)
        ded = SH.Dedicated(self.paths, dict(cfg, realm_address="203.0.113.7"), self.lay, popen=m.popen, run=m.run,
                           port_open=m.port_open, sleep=lambda s: None)
        ded.start_all()
        sql = " ".join(a[a.index("-e") + 1] for name, a, _ in m.sql if name == "mysql.exe")
        self.assertIn("address='203.0.113.7'", sql)
        self.assertIn("DELETE FROM account WHERE username='SOLO'", sql)
        self.assertNotIn("INSERT INTO account", sql)
        self.assertTrue(all(pw == "s3cret" for _, _, pw in m.sql))
        self.assertEqual(ded.gm("server info"), "sent (the reply appears in the world log below)")
        self.assertIn(b"server info\n", ded.servers.procs["mangosd"].stdin.getvalue())
        ded.stop_all()
        self.assertEqual(m.ports, set())

    def test_gm_needs_our_world_or_soap(self):
        m = Machine(preopen={3310, 3724, 8085})
        ded = SH.Dedicated(self.paths, SH.load_config({}, self.lay), self.lay, popen=m.popen, run=m.run,
                           port_open=m.port_open, sleep=lambda s: None)
        with self.assertRaises(S.SppError):
            ded.gm("server info")

    def test_web_backend_frozen_and_source(self):
        self.assertEqual(SH.web_backend_argv(True, "C:/OpenVanilla/OpenVanilla.exe", None),
                         ["C:/OpenVanilla/OpenVanilla.exe", "--run", "web-backend", "18090"])
        self.assertEqual(SH.web_backend_argv(False, "py", "/src")[1], os.path.join("/src", "asset_server.py"))
        m = Machine()
        started = []
        ded = SH.Dedicated(self.paths, SH.load_config({}, self.lay), self.lay, frozen=True, exe="OpenVanilla.exe",
                           popen=lambda argv, **kw: started.append((argv, kw)) or m.popen(argv, **kw), run=m.run,
                           port_open=m.port_open)
        ded.start_web()
        argv, kw = started[0]
        self.assertEqual(argv[1:3], ["--run", "web-backend"])
        self.assertEqual(kw["env"]["OPENVANILLA_SERVER_DIR"], self.lay.server)
        self.assertEqual(kw["env"]["SPP_ROOT"], self.server)

    def test_source_installs_missing_packages(self):
        calls = []

        class R:
            returncode, stderr = 0, ""
        ok, msg = SH.ensure_packages(False, run=lambda argv, **kw: calls.append(argv) or R(),
                                     find_spec=lambda m: None if m == "aiohttp" else object())
        self.assertTrue(ok)
        self.assertEqual(calls[0][-1], "aiohttp")
        self.assertIn("--user", calls[0])
        self.assertEqual(SH.ensure_packages(True), (True, "bundled"))


if __name__ == "__main__":
    unittest.main()
