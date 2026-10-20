"""launcher/layout.py: the folder layout, migrating old installs, and the shared AddOns folder.

    python -m unittest tests.test_launcher_layout -v
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "launcher"))

import layout as L  # noqa: E402


def touch(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def addon(folder, name, body="-- hi"):
    touch(os.path.join(folder, name, name + ".toc"), "## Title: " + name)
    touch(os.path.join(folder, name, "main.lua"), body)


class DetectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_portable_zip_keeps_data_beside_the_exe(self):
        lay = L.detect(self.root, env={})
        self.assertEqual(lay.mode, "portable")
        self.assertEqual(lay.data, os.path.abspath(self.root))
        self.assertEqual(lay.engine_exe, os.path.join(self.root, "Game", "Open Vanilla Game.exe"))
        self.assertEqual(lay.addons_enabled, os.path.join(self.root, "AddOns", "Enabled"))
        self.assertEqual(lay.solo, os.path.join(self.root, "Realms", "Solo"))

    def test_installer_build_uses_localappdata(self):
        touch(os.path.join(self.root, "unins000.exe"))
        lad = os.path.join(self.root, "lad")
        lay = L.detect(self.root, env={"LOCALAPPDATA": lad})
        self.assertEqual(lay.mode, "installed")
        self.assertEqual(lay.data, os.path.join(lad, "OpenVanilla"))
        self.assertEqual(lay.engine_exe, os.path.join(self.root, "Game", "Open Vanilla Game.exe"))  # program files stay put

    def test_read_only_folder_falls_back_to_localappdata(self):
        lad = os.path.join(self.root, "lad")   # a real absolute path: "/x" becomes D:\\x on Windows
        lay = L.detect(self.root, env={"LOCALAPPDATA": lad}, writable=lambda d: False)
        self.assertEqual(lay.mode, "installed")
        self.assertEqual(lay.data, os.path.join(lad, "OpenVanilla"))

    def test_existing_old_data_folder_keeps_being_used(self):
        """The rename never moves %LOCALAPPDATA%\\OpenWoW (Solo and hosted realms keep absolute paths in it)."""
        lad = os.path.join(self.root, "lad")
        os.makedirs(os.path.join(lad, "OpenWoW", "Realms"))
        lay = L.detect(self.root, env={"LOCALAPPDATA": lad}, writable=lambda d: False)
        self.assertEqual(lay.data, os.path.join(lad, "OpenWoW"))
        os.makedirs(os.path.join(lad, "OpenVanilla"))   # once the new one exists it wins
        self.assertEqual(L.detect(self.root, env={"LOCALAPPDATA": lad}, writable=lambda d: False).data,
                         os.path.join(lad, "OpenVanilla"))

    def test_new_data_dir_override(self):
        self.assertEqual(L.detect(self.root, env={"OPENVANILLA_DATA_DIR": "/n"}).data,
                         os.path.abspath("/n"))

    def test_override_and_source(self):
        self.assertEqual(L.detect(self.root, env={"OPENVANILLA_DATA_DIR": "/d"}).data, os.path.abspath("/d"))
        src = L.detect(self.root, source=True, env={})
        self.assertEqual(src.data, os.path.join(self.root, "_local", "launcher-data"))
        self.assertTrue(src.portable)

    def test_ensure_and_env(self):
        lay = L.detect(self.root, env={}).ensure()
        for rel in L.USER_FOLDERS:
            self.assertTrue(os.path.isdir(os.path.join(self.root, *rel.split("/"))), rel)
        env = lay.export_env({})
        self.assertEqual(env["OPENVANILLA_SOLO_DIR"], lay.solo_pack)
        self.assertEqual(env["OPENVANILLA_HOST_DIR"], lay.hosted)


class MigrationTests(unittest.TestCase):
    """An install from before layout 2: OpenWoW Launcher.exe + engine OpenWoW.exe + benilla-config."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        r = self.root = self.tmp.name
        touch(os.path.join(r, "OpenWoW Launcher.exe"), "old launcher")
        touch(os.path.join(r, "_internal", "base_library.zip"), "old internals")
        touch(os.path.join(r, "benilla.exe"), "engine")
        addon(os.path.join(r, "benilla-config", "AddOns"), "ClassicPlus")
        addon(os.path.join(r, "benilla-config", "AddOns"), "MyMod", "-- mine")
        addon(os.path.join(r, "benilla-config", "AddOns.disabled"), "OffMod")
        touch(os.path.join(r, "benilla-config", "WTF", "Config.wtf"), "SET x 1")
        touch(os.path.join(r, "solo", "state.json"), "{}")
        touch(os.path.join(r, "host", "p2p.json"), "{\"host_id\": \"abc\"}")
        touch(os.path.join(r, "launcher", "settings.json"), json.dumps({"wow_folder": "C:/WoW"}))
        self.lay = L.detect(r, env={})

    def tearDown(self):
        self.tmp.cleanup()

    def test_moves_everything_into_place(self):
        did = L.migrate(self.lay, frozen=True, env={}, now=0)
        lay, r = self.lay, self.root
        self.assertTrue(did)
        self.assertEqual(read(os.path.join(lay.addons_enabled, "MyMod", "main.lua")), "-- mine")
        self.assertTrue(os.path.isdir(os.path.join(lay.addons_enabled, "ClassicPlus")))
        self.assertTrue(os.path.isdir(os.path.join(lay.addons_disabled, "OffMod")))
        self.assertEqual(read(os.path.join(lay.engine_config, "WTF", "Config.wtf")), "SET x 1")
        self.assertFalse(os.path.exists(os.path.join(r, "benilla-config")))
        self.assertTrue(os.path.isfile(os.path.join(lay.solo_pack, "state.json")))
        self.assertTrue(os.path.isfile(os.path.join(lay.hosted, "p2p.json")))
        self.assertEqual(json.loads(read(lay.settings_file))["wow_folder"], "C:/WoW")
        self.assertTrue(os.path.isfile(os.path.join(r, "launcher", "settings.json")), "settings are copied, not moved")
        self.assertEqual(read(lay.engine_exe), "engine")
        self.assertTrue(os.path.isfile(os.path.join(lay.backups, "old-launcher", "OpenWoW Launcher.exe")))
        self.assertTrue(os.path.isfile(os.path.join(lay.backups, "old-launcher", "_internal", "base_library.zip")))
        self.assertEqual(json.loads(read(lay.layout_file))["layout"], L.LAYOUT_VERSION)

    def test_idempotent(self):
        L.migrate(self.lay, frozen=True, env={}, now=0)
        before = sorted(os.path.relpath(os.path.join(d, f), self.root) for d, _, fs in os.walk(self.root) for f in fs
                        if not f.endswith("layout.json"))
        self.assertEqual(L.migrate(self.lay, frozen=True, env={}, now=0), [])
        after = sorted(os.path.relpath(os.path.join(d, f), self.root) for d, _, fs in os.walk(self.root) for f in fs
                       if not f.endswith("layout.json"))
        self.assertEqual(before, after)

    def test_conflicts_are_kept_not_deleted(self):
        addon(self.lay.addons_enabled, "MyMod", "-- newer")
        touch(self.lay.settings_file, json.dumps({"wow_folder": "D:/New"}))
        L.migrate(self.lay, frozen=True, env={}, now=0)
        self.assertEqual(read(os.path.join(self.lay.addons_enabled, "MyMod", "main.lua")), "-- newer")
        kept = [os.path.join(d, f) for d, _, fs in os.walk(self.lay.backups) for f in fs if f == "main.lua"]
        self.assertEqual([read(p) for p in kept], ["-- mine"])
        self.assertEqual(json.loads(read(self.lay.settings_file))["wow_folder"], "D:/New")

    def test_source_runs_never_touch_exes(self):
        L.migrate(self.lay, frozen=False, env={}, now=0)
        self.assertTrue(os.path.isfile(os.path.join(self.root, "OpenWoW Launcher.exe")))
        self.assertTrue(os.path.isfile(os.path.join(self.root, "benilla.exe")))

    def test_a_source_checkout_keeps_its_solo_and_host_folders(self):
        # run from a git checkout, solo\ and host\ are tracked build files, not an old install's data
        os.makedirs(os.path.join(self.root, ".git"))
        L.migrate(self.lay, frozen=False, env={}, now=0)
        self.assertTrue(os.path.isfile(os.path.join(self.root, "solo", "state.json")))
        self.assertTrue(os.path.isfile(os.path.join(self.root, "host", "p2p.json")))
        self.assertFalse(os.path.exists(os.path.join(self.lay.solo_pack, "state.json")))

    def test_installed_mode_moves_data_to_localappdata(self):
        touch(os.path.join(self.root, "unins000.exe"))
        lad = os.path.join(self.root, "lad")
        lay = L.detect(self.root, env={"LOCALAPPDATA": lad})
        L.migrate(lay, frozen=True, env={}, now=0)
        self.assertTrue(os.path.isdir(os.path.join(lad, "OpenVanilla", "AddOns", "Enabled", "MyMod")))
        self.assertTrue(os.path.isfile(os.path.join(lad, "OpenVanilla", "Realms", "SoloPack", "state.json")))
        self.assertTrue(os.path.isfile(os.path.join(self.root, "Game", "benilla-config", "WTF", "Config.wtf")))

    def test_old_appdata_settings_are_picked_up(self):
        os.remove(os.path.join(self.root, "launcher", "settings.json"))
        appdata = os.path.join(self.root, "roaming")
        touch(os.path.join(appdata, "OpenWoW", "settings.json"), json.dumps({"client": "vanilla"}))
        L.migrate(self.lay, frozen=True, env={"APPDATA": appdata}, now=0)
        self.assertEqual(json.loads(read(self.lay.settings_file))["client"], "vanilla")


class AddonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lay = L.detect(os.path.join(self.tmp.name, "OpenWoW"), env={}).ensure()

    def tearDown(self):
        self.tmp.cleanup()

    def test_seed_once_per_version_and_respects_disabled(self):
        shipped = os.path.join(self.tmp.name, "shipped")
        addon(shipped, "ClassicPlus", "v1")
        addon(shipped, "Atlas", "v1")
        addon(self.lay.addons_disabled, "Atlas", "old")
        self.assertEqual(L.seed_shipped_addons(shipped, self.lay, "1.0"), ["Atlas", "ClassicPlus"])
        self.assertEqual(read(os.path.join(self.lay.addons_disabled, "Atlas", "main.lua")), "v1")
        self.assertFalse(os.path.exists(os.path.join(self.lay.addons_enabled, "Atlas")))
        self.assertEqual(L.seed_shipped_addons(shipped, self.lay, "1.0"), [])
        addon(shipped, "ClassicPlus", "v2")
        L.seed_shipped_addons(shipped, self.lay, "1.1")
        self.assertEqual(read(os.path.join(self.lay.addons_enabled, "ClassicPlus", "main.lua")), "v2")

    def test_sync_only_touches_managed_addons(self):
        client = os.path.join(self.tmp.name, "WoW", "Interface", "AddOns")
        addon(client, "PlayersOwn", "theirs")
        addon(client, "Clash", "theirs")
        addon(self.lay.addons_enabled, "ClassicPlus")
        addon(self.lay.addons_enabled, "Clash", "ours")
        res = L.sync_addons(self.lay.addons_enabled, client)
        self.assertEqual(res["copied"], ["ClassicPlus"])
        self.assertEqual(res["skipped"], ["Clash"])
        self.assertEqual(read(os.path.join(client, "Clash", "main.lua")), "theirs")
        self.assertEqual(L.sync_addons(self.lay.addons_enabled, client)["copied"], [])   # unchanged: no copy
        os.rename(os.path.join(self.lay.addons_enabled, "ClassicPlus"), os.path.join(self.lay.addons_disabled, "ClassicPlus"))
        res = L.sync_addons(self.lay.addons_enabled, client)
        self.assertEqual(res["removed"], ["ClassicPlus"])
        self.assertFalse(os.path.exists(os.path.join(client, "ClassicPlus")))
        self.assertTrue(os.path.isdir(os.path.join(client, "PlayersOwn")))

    def test_find_engine(self):
        self.assertIsNone(L.find_engine(self.lay))
        touch(self.lay.engine_exe)
        self.assertEqual(L.find_engine(self.lay), self.lay.engine_exe)


if __name__ == "__main__":
    unittest.main()


class RenameBridgeTests(unittest.TestCase):
    """After the rename the launcher's old name is a twin, never mistaken for the engine."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "Install")
        os.makedirs(os.path.join(self.root, L.INTERNAL_DIR))
        self.lay = L.detect(self.root, env={}).ensure()

    def tearDown(self):
        self.tmp.cleanup()

    def test_launcher_twin_is_not_the_engine(self):
        touch(os.path.join(self.root, "OpenVanilla.exe"), "launcher")
        touch(os.path.join(self.root, "OpenWoW.exe"), "launcher twin")
        self.assertIsNone(L.find_engine(self.lay, extra_dirs=(self.root,)))
        plan = L.migration_plan(self.lay, [self.root], frozen=True, env={})
        self.assertFalse([p for p in plan if p[0] == "engine" and os.path.basename(p[1]) == "OpenWoW.exe"])

    def test_old_engine_name_is_found_and_renamed(self):
        touch(os.path.join(self.root, "Game", "OpenWoW Game.exe"), "engine")
        self.assertEqual(L.find_engine(self.lay), os.path.join(self.root, "Game", "OpenWoW Game.exe"))
        L.migrate(self.lay, [self.root], frozen=True, env={})
        self.assertTrue(os.path.isfile(os.path.join(self.root, "Game", "Open Vanilla Game.exe")))
        self.assertEqual(L.find_engine(self.lay), os.path.join(self.root, "Game", "Open Vanilla Game.exe"))

    def test_layout1_engine_still_moves(self):
        touch(os.path.join(self.root, "OpenWoW Launcher.exe"), "old launcher")
        touch(os.path.join(self.root, "OpenWoW.exe"), "old engine")
        plan = L.migration_plan(self.lay, [self.root], frozen=True, env={})
        self.assertTrue([p for p in plan if p[0] == "engine" and os.path.basename(p[1]) == "OpenWoW.exe"])

    def test_running_as_old_name_adds_the_new_one(self):
        old = os.path.join(self.root, "OpenWoW.exe")
        touch(old, "launcher")
        lines = []
        made = L.ensure_launcher_name(self.lay, True, exe=old, log=lines.append)
        self.assertEqual(made, os.path.join(self.root, "OpenVanilla.exe"))
        self.assertTrue(os.path.isfile(made))
        self.assertIsNone(L.ensure_launcher_name(self.lay, True, exe=old))        # only once
        self.assertIsNone(L.ensure_launcher_name(self.lay, False, exe=old))       # never from source
