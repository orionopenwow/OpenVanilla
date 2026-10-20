"""launcher/updater.py + launcher/fetch.py: staging an update in the background, the
"Update ready" check, the hand-off (installer: silent setup; zip: swap step) and the swap itself.

    python -m unittest tests.test_launcher_updater -v
"""
import hashlib
import io
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
import zipfile
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "launcher"))

import fetch  # noqa: E402
import layout as L  # noqa: E402
import updater as U  # noqa: E402


def touch(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def release_zip(version, exe_text="new launcher"):
    buf = io.BytesIO()
    top = f"OpenVanilla_{version}_Win64/"
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(top + "OpenWoW.exe", exe_text)
        z.writestr(top + "app/base_library.zip", "new internals")
        z.writestr(top + "Game/OpenWoW Game.exe", "new engine")
        z.writestr(top + "Server/README.txt", "server notes")
        z.writestr(top + "README.txt", "readme " + version)
        z.writestr(top + "links.txt", "# defaults")
    return buf.getvalue()


class FakeResp:
    def __init__(self, data, status=200, headers=None):
        self.data, self.status = data, status
        self.headers = {"Content-Length": str(len(data)), **(headers or {})}
        self.pos = 0

    def read(self, n=-1):
        n = len(self.data) - self.pos if n < 0 else n
        out = self.data[self.pos:self.pos + n]
        self.pos += len(out)
        return out

    def getcode(self):
        return self.status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeWeb:
    def __init__(self, files, fail_after=None):
        self.files, self.calls, self.fail_after = files, [], fail_after

    def __call__(self, req, timeout=None):
        self.calls.append((req.full_url, req.headers.get("Range")))
        if req.full_url not in self.files:
            raise urllib.error.HTTPError(req.full_url, 404, "nf", {}, None)
        data = self.files[req.full_url]
        rng = req.headers.get("Range")
        if rng:
            start = int(rng.split("=")[1].rstrip("-"))
            return FakeResp(data[start:], 206, {"Content-Range": f"bytes {start}-{len(data) - 1}/{len(data)}"})
        if self.fail_after is not None:
            cut, self.fail_after = self.fail_after, None
            return FakeResp(data[:cut])   # a dropped connection: short body
        return FakeResp(data)


def manifest(version, data, kind="zip"):
    entry = {"url": f"https://example.test/{'OpenVanilla-Setup-' + version + '.exe' if kind == 'setup' else 'OpenVanilla_' + version + '_Win64.zip'}",
             "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    return {"version": version, **entry, kind: entry}


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_resume_after_drop(self):
        data = os.urandom(300000)
        web = FakeWeb({"https://x.test/f.bin": data}, fail_after=100000)
        dest = os.path.join(self.tmp.name, "f.bin")
        fetch.download("https://x.test/f.bin", dest, sha256=hashlib.sha256(data).hexdigest(), size=len(data),
                       opener=web, sleep=lambda s: None, chunk=4096)
        with open(dest, "rb") as f:
            self.assertEqual(f.read(), data)
        self.assertEqual(web.calls[1][1], "bytes=100000-")

    def test_bad_checksum_removes_part(self):
        dest = os.path.join(self.tmp.name, "f.bin")
        with self.assertRaises(fetch.FetchError):
            fetch.download("https://x.test/f.bin", dest, sha256="0" * 64, opener=FakeWeb({"https://x.test/f.bin": b"abc"}))
        self.assertFalse(os.path.exists(dest + ".part"))
        self.assertFalse(os.path.exists(dest))

    def test_refuses_non_web_and_unsafe_zip(self):
        with self.assertRaises(fetch.FetchError):
            fetch.download("file:///etc/passwd", os.path.join(self.tmp.name, "x"))
        bad = os.path.join(self.tmp.name, "bad.zip")
        with zipfile.ZipFile(bad, "w") as z:
            z.writestr("../evil.txt", "no")
        with self.assertRaises(fetch.FetchError):
            fetch.safe_extract(bad, os.path.join(self.tmp.name, "out"))
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "evil.txt")))


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.install = os.path.join(self.tmp.name, "OpenWoW")
        touch(os.path.join(self.install, "OpenWoW.exe"), "old launcher")
        touch(os.path.join(self.install, "app", "base_library.zip"), "old internals")
        touch(os.path.join(self.install, "app", "only-in-old.pyd"), "stale")
        touch(os.path.join(self.install, "Game", "OpenWoW Game.exe"), "old engine")
        touch(os.path.join(self.install, "Game", "benilla-config", "WTF", "Config.wtf"), "player settings")
        touch(os.path.join(self.install, "AddOns", "Enabled", "Mine", "Mine.toc"), "mine")
        touch(os.path.join(self.install, "links.txt"), "MY_KEY = mine")
        self.lay = L.detect(self.install, env={}).ensure()

    def tearDown(self):
        self.tmp.cleanup()

    def test_pick_asset(self):
        m = {"version": "2", "url": "u", "setup": {"url": "s"}, "zip": {"url": "z"}}
        self.assertEqual(U.pick_asset(m, "installed")[0], "setup")
        self.assertEqual(U.pick_asset(m, "portable")[0], "zip")
        self.assertIsNone(U.pick_asset(m, "source"))
        self.assertEqual(U.pick_asset({"version": "2", "url": "https://x/OpenVanilla_2_Win64.zip"}, "portable")[0], "zip")

    def test_zip_stage_ready_handoff_apply(self):
        data = release_zip("1.20.0")
        m = manifest("1.20.0", data)
        web = FakeWeb({m["url"]: data})
        info = U.stage(m, self.lay, opener=web)
        self.assertEqual(info["kind"], "zip")
        self.assertTrue(os.path.isfile(os.path.join(info["staged"], "OpenWoW.exe")))
        self.assertEqual(U.ready(self.lay, "1.19.0")["version"], "1.20.0")
        self.assertIsNone(U.ready(self.lay, "1.20.0"), "not newer than what runs")

        calls = []
        U.handoff(info, self.lay, popen=lambda argv, **kw: calls.append((argv, kw)), pid=4242)
        argv = calls[0][0]
        self.assertEqual(argv[0], os.path.join(info["staged"], "OpenWoW.exe"))
        self.assertEqual(argv[1:], ["--apply-update", info["staged"], "--target", self.lay.install, "--wait-pid", "4242"])

        started = []
        code = U.main_apply(argv[1:], popen=lambda a, **kw: started.append(a))
        self.assertEqual(code, 0)
        i = self.install
        self.assertEqual(read(os.path.join(i, "OpenWoW.exe")), "new launcher")
        self.assertEqual(read(os.path.join(i, "Game", "OpenWoW Game.exe")), "new engine")
        self.assertFalse(os.path.exists(os.path.join(i, "app", "only-in-old.pyd")), "app\\ is replaced whole")
        self.assertEqual(read(os.path.join(i, "Game", "benilla-config", "WTF", "Config.wtf")), "player settings")
        self.assertTrue(os.path.isfile(os.path.join(i, "AddOns", "Enabled", "Mine", "Mine.toc")))
        self.assertEqual(read(os.path.join(i, "links.txt")), "MY_KEY = mine", "the player's links.txt is kept")
        self.assertFalse(os.path.exists(os.path.join(i, ".update-old")))
        self.assertEqual(started, [[os.path.join(i, "OpenWoW.exe"), "--updated"]])
        self.assertIn("update applied", read(os.path.join(i, "Logs", "update.log")))
        self.assertEqual(U.cleanup(self.lay, "1.20.0"), ["1.20.0"])

    def test_failed_swap_rolls_back(self):
        data = release_zip("1.20.0")
        m = manifest("1.20.0", data)
        info = U.stage(m, self.lay, opener=FakeWeb({m["url"]: data}))
        real = shutil.copytree

        def boom(src, dst, *a, **kw):
            if os.path.basename(src) == "Server":
                raise OSError("disk full")
            return real(src, dst, *a, **kw)

        with mock.patch.object(U.shutil, "copytree", boom):
            with self.assertRaises(OSError):
                U.apply_staged(info["staged"], self.install)
        self.assertEqual(read(os.path.join(self.install, "OpenWoW.exe")), "old launcher")
        self.assertEqual(read(os.path.join(self.install, "app", "only-in-old.pyd")), "stale")
        self.assertEqual(read(os.path.join(self.install, "Game", "OpenWoW Game.exe")), "old engine")

    def test_waits_for_the_launcher_to_exit(self):
        data = release_zip("1.20.0")
        m = manifest("1.20.0", data)
        info = U.stage(m, self.lay, opener=FakeWeb({m["url"]: data}))
        state = {"n": 3}

        def alive(pid):
            state["n"] -= 1
            return state["n"] > 0

        U.apply_staged(info["staged"], self.install, wait_pid=99, alive=alive, sleep=lambda s: None)
        self.assertEqual(state["n"], 0)
        with self.assertRaises(U.UpdateError):
            U.apply_staged(info["staged"], self.install, wait_pid=99, alive=lambda p: True, sleep=lambda s: None, timeout=-1)

    def test_setup_build_runs_silent_installer(self):
        lay = L.Layout(self.install, os.path.join(self.tmp.name, "data"), "installed").ensure()
        data = b"MZ fake setup"
        m = manifest("1.20.0", data, kind="setup")
        info = U.stage(m, lay, opener=FakeWeb({m["url"]: data}))
        argv, _ = U.handoff_command(info, lay)
        self.assertEqual(argv[0], info["file"])
        for flag in ("/VERYSILENT", "/SUPPRESSMSGBOXES", "/CLOSEAPPLICATIONS", "/RELAUNCH"):
            self.assertIn(flag, argv)

    def test_tampered_or_unchecked_downloads_are_not_used(self):
        data = release_zip("1.20.0")
        m = manifest("1.20.0", data)
        bad = dict(m, zip=dict(m["zip"], sha256="ab" * 32))
        with self.assertRaises(fetch.FetchError):
            U.stage(bad, self.lay, opener=FakeWeb({m["url"]: data}))
        self.assertIsNone(U.ready(self.lay, "1.0.0"))
        with self.assertRaises(U.UpdateError):
            U.stage(dict(m, zip=dict(m["zip"], sha256="")), self.lay, opener=FakeWeb({m["url"]: data}))
        info = U.stage(m, self.lay, opener=FakeWeb({m["url"]: data}))
        with open(info["file"], "ab") as f:
            f.write(b"tamper")
        self.assertIsNone(U.ready(self.lay, "1.0.0"))
        with self.assertRaises(U.UpdateError):
            U.handoff(info, self.lay, popen=lambda *a, **k: None)

    def test_zip_without_launcher_is_refused(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("OpenVanilla_9_Win64/README.txt", "no exe")
        data = buf.getvalue()
        m = manifest("9.0.0", data)
        with self.assertRaises(U.UpdateError):
            U.stage(m, self.lay, opener=FakeWeb({m["url"]: data}))


if __name__ == "__main__":
    unittest.main()


class NewNameTests(unittest.TestCase):
    """Releases after the rename: OpenVanilla.exe (+ the OpenWoW.exe twin); the updater handles both kinds."""

    def test_launcher_in_prefers_the_new_name(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(U.launcher_in(d))
            touch(os.path.join(d, "OpenWoW.exe"), "old")
            self.assertEqual(U.launcher_in(d), os.path.join(d, "OpenWoW.exe"))
            touch(os.path.join(d, "OpenVanilla.exe"), "new")
            self.assertEqual(U.launcher_in(d), os.path.join(d, "OpenVanilla.exe"))

    def test_both_names_are_program_files(self):
        self.assertIn("OpenVanilla.exe", U.PROGRAM_ITEMS)
        self.assertIn("OpenWoW.exe", U.PROGRAM_ITEMS)
