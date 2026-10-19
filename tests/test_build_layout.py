"""packaging/build_repack.py lays out the release as layout 2 (OpenVanilla.exe + its OpenWoW.exe twin + app/ + Game/ + Server/,
user folders in the zip), freezes every lazily imported module in, and writes a README/links.txt
that match. PyInstaller itself is not run here (the release workflow does that on Windows).

    python -m unittest tests.test_build_layout -v
"""
import importlib.util
import os
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))

_spec = importlib.util.spec_from_file_location("build_repack", os.path.join(ROOT, "packaging", "build_repack.py"))
B = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(B)

import layout as L  # noqa: E402


def touch(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


class BuildLayoutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.addons = os.path.join(t, "addons")
        touch(os.path.join(self.addons, "ClassicPlus", "ClassicPlus.toc"), "## Title: Classic+\n## Author: OpenVanilla\n## X-ClassicPlus: Core\n")
        touch(os.path.join(self.addons, "Blizzard_Thing", "Blizzard_Thing.toc"), "## Title: no\n")
        self.launcher = os.path.join(t, "dist", "OpenVanilla")
        touch(os.path.join(self.launcher, "OpenVanilla.exe"), "launcher")
        touch(os.path.join(self.launcher, "app", "base_library.zip"), "internals")
        self.engine = os.path.join(t, "benilla.exe")
        touch(self.engine, "engine")
        self._old = B.ADDON_SRC
        B.ADDON_SRC = self.addons

    def tearDown(self):
        B.ADDON_SRC = self._old
        self.tmp.cleanup()

    def test_pyinstaller_bundles_everything(self):
        args = B.pyinstaller_args(self.tmp.name, "x.ico")
        joined = " ".join(args)
        self.assertIn("--contents-directory app", joined)
        self.assertIn("--name OpenVanilla ", joined)
        self.assertIn("--onedir", args)
        for mod in ("play_local", "workshop", "updater", "live_content", "spp", "server_host", "asset_server"):
            self.assertIn(f"--hidden-import {mod}", joined)
        self.assertIn("--collect-submodules p2p", joined)
        self.assertEqual(B.CONTENTS_DIR, L.INTERNAL_DIR)
        self.assertEqual(B.LAUNCHER_NAME + ".exe", L.LAUNCHER_EXE)

    def test_assemble_layout_and_zip(self):
        out = os.path.join(self.tmp.name, "release", "OpenVanilla_9.9.9_Win64")
        os.makedirs(out)
        addons, notes = B.assemble(out, self.launcher, self.engine, "9.9.9", None)
        exists = lambda *p: os.path.exists(os.path.join(out, *p))
        self.assertTrue(exists("OpenVanilla.exe"))
        # the rename bridge: an identical twin under the old name, for launchers whose updater only knows it
        self.assertTrue(exists("OpenWoW.exe"))
        with open(os.path.join(out, "OpenWoW.exe"), encoding="utf-8") as f:
            self.assertEqual(f.read(), "launcher")
        self.assertEqual(L.ENGINE_EXE, "Open Vanilla Game.exe")
        self.assertTrue(exists("app", "base_library.zip"))
        self.assertTrue(exists("Game", L.ENGINE_EXE))
        self.assertTrue(exists("app", "addons", "ClassicPlus", "ClassicPlus.toc"))
        self.assertFalse(exists("app", "addons", "Blizzard_Thing"))
        for f in ("defaults.json", "version.json", "patch_notes.json", "links.txt"):
            self.assertTrue(exists("app", "data", f), f)
        self.assertTrue(exists("Server", "README.txt"))
        self.assertFalse(exists("benilla-config"))
        self.assertFalse(exists("OpenWoW Launcher.exe"))
        with open(os.path.join(out, "README.txt"), encoding="utf-8") as f:
            readme = f.read()
        self.assertIn("double-click OpenVanilla.exe", readme)
        self.assertNotIn("OpenWoW Launcher.exe", readme)
        with open(os.path.join(out, "links.txt"), encoding="utf-8") as f:
            user = [ln for ln in f.read().splitlines() if ln.strip() and not ln.startswith("#")]
        self.assertEqual(user, [], "the player's links.txt starts with every line commented out")
        self.assertEqual(B.forbidden_files(out), [])
        z = os.path.join(self.tmp.name, "r.zip")
        B.make_zip(out, z, B.USER_FOLDERS_IN_ZIP)
        names = zipfile.ZipFile(z).namelist()
        self.assertIn("OpenVanilla_9.9.9_Win64/OpenVanilla.exe", names)
        self.assertIn("OpenVanilla_9.9.9_Win64/OpenWoW.exe", names)
        self.assertIn("OpenVanilla_9.9.9_Win64/AddOns/Enabled/", names)
        self.assertIn("OpenVanilla_9.9.9_Win64/Realms/Solo/", names)

    def test_version_comes_from_VERSION(self):
        with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
            self.assertEqual(B.read_version(), f.read().strip())


if __name__ == "__main__":
    unittest.main()
