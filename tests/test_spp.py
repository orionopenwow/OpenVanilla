"""launcher/spp.py: Play Solo with SPP Classics, as a state machine with fakes (no network, no Windows).

    missing -> downloaded -> unpacked -> base -> (guided Vanilla setup) -> ready -> play/stop

    python -m unittest tests.test_spp -v
"""
import hashlib
import io
import os
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))
sys.path.insert(0, ROOT)
sys.path.insert(0, HERE)

import fetch  # noqa: E402
import spp as S  # noqa: E402
from test_launcher_updater import FakeWeb  # noqa: E402


def touch(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def spp_zip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("SPP_Classics_V2/Server_Update.bat", "@echo off")
        z.writestr("SPP_Classics_V2/Server_Start.bat", "@echo off")
        z.writestr("SPP_Classics_V2/Git/cmd/git.exe", "git")
    return buf.getvalue()


def make_vanilla(paths):
    for f in (paths.mysqld, paths.mysql, paths.mysqladmin, paths.realmd, paths.mangosd):
        touch(f)
    touch(os.path.join(paths.maps, "0002035.map"))
    touch(os.path.join(paths.versions, "vanilla_world_version.spp"), "29")
    touch(os.path.join(paths.settings, "mangosd.conf"),
          'LoginDatabaseInfo     = "127.0.0.1;3310;root;secret;classicrealmd"\n')


class FakeGit:
    """Plays SPP's `git clone`: progress on stdout, then the SPP_Server folder."""

    def __init__(self, ok=True):
        self.ok, self.calls = ok, []

    def __call__(self, argv, cwd=None, **kw):
        self.calls.append((argv, cwd))
        target = os.path.join(cwd, argv[-2])
        ok = self.ok

        class P:
            def __init__(self):
                lines = b"Cloning into 'SPP_Server'...\r\nReceiving objects:  10% (1/10)\rReceiving objects: 100% (10/10)\r\n" \
                        b"Resolving deltas: 100% (5/5)\r\nUpdating files: 100% (9/9)\n"
                self.stdout = io.BytesIO(lines if ok else b"fatal: unable to access\n")

            def wait(self):
                if ok:
                    touch(os.path.join(target, "Launcher.bat"), "@echo off")
                    touch(os.path.join(target, "Server", "Tools", "Server_Update.bat"), "new")
                return 0 if ok else 128

            def kill(self):
                pass
        return P()


class FakeProc:
    def __init__(self, argv, ports, on_start=None):
        self.argv, self.ports, self.code = argv, ports, None
        self.stdin = io.BytesIO() if "mangosd" in argv[0] else None
        self.pid = 1000 + len(argv[0])
        if on_start:
            on_start(self)

    def poll(self):
        if self.stdin is not None and b"server shutdown" in self.stdin.getvalue():
            self.code = 0
            self.ports.discard(8085)
        return self.code

    def terminate(self):
        self.code = 0
        name = os.path.basename(self.argv[0])
        self.ports.discard({"realmd.exe": 3724, "mysqld.exe": 3310}.get(name))

    def kill(self):
        self.terminate()

    def wait(self):
        return self.code


class Machine:
    """Fake processes and ports for SppServers / SoloPlay."""

    def __init__(self, preopen=()):
        self.ports = set(preopen)
        self.started, self.sql = [], []

    def popen(self, argv, **kw):
        name = os.path.basename(argv[0])
        port = {"mysqld.exe": 3310, "realmd.exe": 3724, "mangosd.exe": 8085}.get(name)
        self.started.append(name)
        if port:
            self.ports.add(port)
        proc = FakeProc(argv, self.ports)
        self.procs = getattr(self, "procs", {})
        self.procs[name] = proc
        if name.lower().startswith("wow"):
            proc.code = 0   # the game: closes right away in tests
        return proc

    def run(self, argv, **kw):
        self.sql.append((os.path.basename(argv[0]), argv, kw.get("env", {}).get("MYSQL_PWD")))
        if os.path.basename(argv[0]) == "mysqladmin.exe":
            self.ports.discard(3310)
            if "mysqld.exe" in getattr(self, "procs", {}):
                self.procs["mysqld.exe"].code = 0

        class R:
            returncode, stdout, stderr = 0, "", ""
        return R()

    def port_open(self, port, *a, **k):
        return int(port) in self.ports


class StateMachineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.paths = S.SppPaths(os.path.join(self.tmp.name, "Realms", "Solo"))
        self.data = spp_zip()
        self.url = "https://example.test/SPP_Classics_V2.zip"
        self.events = []

    def tearDown(self):
        self.tmp.cleanup()

    def installer(self, **kw):
        kw.setdefault("sha256", hashlib.sha256(self.data).hexdigest())
        kw.setdefault("size", len(self.data))
        return S.SppInstaller(self.paths, url=self.url, report=lambda st, text, frac=None: self.events.append((st, frac)),
                              opener=FakeWeb({self.url: self.data}), popen=FakeGit(), **kw)

    def test_full_path_to_base_then_ready(self):
        inst = self.installer()
        self.assertEqual(inst.state(), "missing")
        self.assertEqual(inst.run("base"), "base")
        stages = [s for s, _ in self.events]
        self.assertEqual([s for i, s in enumerate(stages) if i == 0 or stages[i - 1] != s], ["download", "unpack", "base"])
        self.assertIn(0.85, [f for s, f in self.events if s == "base"], "git progress mapped onto the bar")
        self.assertTrue(os.path.isfile(os.path.join(self.paths.base, "Server_Update.bat")))
        self.assertEqual(open(os.path.join(self.paths.base, "Server_Update.bat")).read(), "new",
                         "SPP's updated scripts are copied up like Server_Update.bat does")
        make_vanilla(self.paths)
        self.assertEqual(S.detect_state(self.paths), "ready")

    def test_resumes_from_each_state(self):
        inst = self.installer()
        self.assertEqual(inst.run("downloaded"), "downloaded")
        self.assertEqual(inst.run("unpacked"), "unpacked")
        git = FakeGit()
        inst.popen = git
        self.assertEqual(inst.run("base"), "base")
        self.assertEqual(len(git.calls), 1)
        self.assertEqual(git.calls[0][0][1:4], ["clone", "--progress", "--filter=tree:0"])
        self.assertEqual(inst.run("base"), "base")
        self.assertEqual(len(git.calls), 1, "nothing is redone")

    def test_bad_download_is_removed(self):
        inst = self.installer(sha256="0" * 64)
        with self.assertRaises(S.SppError):
            inst.run("base")
        self.assertEqual(S.detect_state(self.paths), "missing")
        self.assertFalse(os.path.exists(self.paths.zip + ".part"))

    def test_not_spp_zip_is_refused(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("Something/readme.txt", "no")
        self.data = buf.getvalue()
        with self.assertRaises(S.SppError):
            self.installer().run("base")
        self.assertFalse(os.path.isdir(self.paths.base))

    def test_failed_clone_is_put_aside_and_retried(self):
        inst = self.installer()
        inst.run("unpacked")
        inst.popen = FakeGit(ok=False)
        os.makedirs(self.paths.server)
        touch(os.path.join(self.paths.server, "half.txt"))
        with self.assertRaises(S.SppError):
            inst.clone_base()
        inst.popen = FakeGit()
        inst.clone_base()
        self.assertEqual(S.detect_state(self.paths), "base")
        asides = [n for n in os.listdir(self.paths.base) if n.startswith("SPP_Server.partial-")]
        self.assertEqual(len(asides), 1, "the half clone is kept aside, not deleted")

    def test_cancel(self):
        inst = self.installer()
        inst.cancel = {"cancel": True}
        with self.assertRaises(fetch.Cancelled):
            inst.run("base")

    def test_existing_install_is_found(self):
        home = os.path.join(self.tmp.name, "home")
        server = os.path.join(home, "Desktop", "SPP_Classics_V2", "SPP_Server")
        touch(os.path.join(server, "Launcher.bat"))
        os.makedirs(os.path.join(server, "Server"))
        self.assertEqual(S.find_existing(home=home), server)
        p = S.SppPaths(self.paths.root, server=server)
        self.assertEqual(S.detect_state(p), "base")


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.paths = S.SppPaths(os.path.join(self.tmp.name, "Solo"))
        make_vanilla(self.paths)

    def tearDown(self):
        self.tmp.cleanup()

    def servers(self, m):
        return S.SppServers(self.paths, popen=m.popen, run=m.run, port_open=m.port_open, sleep=lambda s: None,
                            logs_dir=os.path.join(self.tmp.name, "Logs"))

    def test_start_prepare_and_stop(self):
        m = Machine()
        sv = self.servers(m)
        self.assertEqual(sv.db, ("127.0.0.1", 3310, "root", "secret"))
        sv.start()
        self.assertEqual(m.started, ["mysqld.exe", "realmd.exe", "mangosd.exe"])
        sqls = [a[-2] if a[-1] == "classicrealmd" else a[-1] for _, a, _ in m.sql]
        self.assertTrue(any("realmlist SET address='127.0.0.1'" in q for q in sqls))
        self.assertTrue(any("INSERT INTO account" in q and "'SOLO'" in q for q in sqls))
        self.assertTrue(all(pw == "secret" for _, _, pw in m.sql), "password via MYSQL_PWD, never argv")
        self.assertFalse(any("secret" in " ".join(a) for _, a, _ in m.sql))
        world = sv.procs["mangosd"]
        sv.stop()
        self.assertIn(b"saveall\nserver shutdown 1\n", world.stdin.getvalue())
        self.assertEqual(m.ports, set())

    def test_reuses_running_services_and_never_stops_them(self):
        m = Machine(preopen={3310, 3724, 8085})
        sv = self.servers(m)
        sv.start()
        self.assertEqual(m.started, [])
        sv.stop()
        self.assertEqual(m.ports, {3310, 3724, 8085}, "SPP's own servers are left running")
        with self.assertRaises(S.SppError):
            sv.console("announce hi")

    def test_missing_binaries(self):
        os.remove(self.paths.mangosd)
        with self.assertRaises(S.SppError):
            self.servers(Machine()).start()

    def test_solo_play_points_client_and_restores(self):
        wow = os.path.join(self.tmp.name, "WoW")
        touch(os.path.join(wow, "WoW.exe"))
        touch(os.path.join(wow, "realmlist.wtf"), "set realmlist play.openvanilla.app")
        m = Machine()
        seen = []

        def popen(argv, **kw):
            if argv[0].endswith("WoW.exe"):
                seen.append(open(os.path.join(wow, "realmlist.wtf")).read().strip())
            return m.popen(argv, **kw)

        sv = S.SppServers(self.paths, popen=popen, run=m.run, port_open=m.port_open, sleep=lambda s: None,
                          logs_dir=os.path.join(self.tmp.name, "Logs"))
        events = []
        S.SoloPlay(self.paths, os.path.join(wow, "WoW.exe"), servers=sv, popen=popen, sleep=lambda s: None,
                   report=lambda st, t, f=None: events.append(st)).run()
        self.assertEqual(seen, ["set realmlist 127.0.0.1"])
        self.assertEqual(open(os.path.join(wow, "realmlist.wtf")).read().strip(), "set realmlist play.openvanilla.app")
        self.assertEqual(m.ports, set(), "servers stopped when the game closed")
        self.assertEqual(events[-1], "done")


if __name__ == "__main__":
    unittest.main()
