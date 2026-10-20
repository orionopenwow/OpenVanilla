"""launcher/ai_setup.py: "Activate your AI (optional)". Detection with fakes, the kit copy (idempotent,
keeps the player's edits, never writes outside the data folder), the prompt library (the same in the
launcher, the game and the website), the terminal command, the one-time card and the live flag.
No network, no real terminal, no AI.

    python -m unittest tests.test_ai_setup -v
"""
import html
import importlib.util
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))

import ai_setup as AI  # noqa: E402
import live_content as LC  # noqa: E402

KIT = os.path.join(ROOT, "agent")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class DetectTests(unittest.TestCase):
    def test_claude_on_path_comes_first(self):
        found = {"claude": "/usr/bin/claude", "code": "/usr/bin/code"}
        tools = AI.detect_tools(which=found.get, isfile=lambda p: False, env={"HOME": "/home/p"}, platform="linux")
        self.assertEqual(tools[0]["id"], "claude")
        self.assertTrue(tools[0]["found"])
        self.assertEqual(tools[0]["path"], "/usr/bin/claude")
        self.assertTrue(AI.tool(tools, "code")["found"])
        self.assertFalse(AI.tool(tools, "codex")["found"])
        self.assertEqual(AI.tool(tools, "claude")["url"], AI.INSTALL_URL)

    def test_claude_found_in_installer_folder_when_path_is_stale(self):
        home = "C:\\Users\\p"
        want = os.path.join(home, ".local", "bin", "claude.exe")
        tools = AI.detect_tools(which=lambda c: None, isfile=lambda p: p == want,
                                env={"USERPROFILE": home, "APPDATA": "C:\\x"}, platform="win32")
        self.assertEqual(AI.tool(tools, "claude")["path"], want)

    def test_nothing_installed(self):
        tools = AI.detect_tools(which=lambda c: None, isfile=lambda p: False, env={"HOME": "/h"}, platform="darwin")
        self.assertFalse(any(t["found"] for t in tools))
        self.assertEqual([t["id"] for t in tools][0], "claude")


class KitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = os.path.join(self.tmp.name, "OpenVanilla")
        self.home = os.path.join(self.tmp.name, "home")
        os.makedirs(self.home)

    def tearDown(self):
        self.tmp.cleanup()

    def install(self, src=KIT):
        return AI.install_kit(src, self.ws, version="9.9.9", home=self.home)

    def test_shipped_kit_is_complete(self):
        self.assertEqual(AI.kit_source([os.path.join(self.tmp.name, "nope"), KIT]), KIT)
        files = AI.kit_files(KIT)
        for rel in ("CLAUDE.md", "AGENTS.md", "Agent/README.md", "Agent/prompts/first-addon.md",
                    "Agent/prompts/xp-rate.md", "Agent/prompts/custom-npc-vendor.md", "Agent/prompts/host-for-friends.md",
                    "Agent/prompts/fix-addon-error.md", "Agent/prompts/ui-theme.md"):
            self.assertIn(rel, files)
        guide = read(os.path.join(KIT, "CLAUDE.md"))
        for must in ("official", "Blizzard", "Back up first", "password", "Lua 5.0", "table.getn", "AddOns\\Enabled",
                     "Realms\\Hosted\\custom", "Logs\\", "account set gmlevel"):
            self.assertIn(must, guide)

    def test_copy_then_idempotent(self):
        res = self.install()
        self.assertIn("CLAUDE.md", res["written"])
        self.assertIn("Agent/prompts/first-addon.md", res["written"])
        self.assertTrue(os.path.isfile(os.path.join(self.ws, "AGENTS.md")))
        self.assertTrue(AI.kit_installed(self.ws))
        self.assertEqual(read(os.path.join(self.ws, "CLAUDE.md")), read(os.path.join(KIT, "CLAUDE.md")))
        again = self.install()
        self.assertEqual(again["written"] + again["updated"] + again["kept"], [])
        self.assertEqual(sorted(again["unchanged"]), sorted(res["written"]))
        self.assertEqual(AI.summary(again), "AI workspace is up to date")
        manifest = json.loads(read(os.path.join(self.ws, "Agent", AI.MANIFEST)))
        self.assertEqual(manifest["version"], "9.9.9")

    def test_update_refreshes_ours_and_keeps_the_players_edits(self):
        src = os.path.join(self.tmp.name, "kit")
        write(os.path.join(src, "CLAUDE.md"), "guide v1")
        write(os.path.join(src, "AGENTS.md"), "agents v1")
        write(os.path.join(src, "prompts", "a.md"), "prompt v1")
        self.install(src)
        write(os.path.join(self.ws, "AGENTS.md"), "my own notes")          # the player edited this one
        write(os.path.join(src, "CLAUDE.md"), "guide v2")
        write(os.path.join(src, "AGENTS.md"), "agents v2")
        res = self.install(src)
        self.assertEqual(res["updated"], ["CLAUDE.md"])
        self.assertEqual(res["kept"], ["AGENTS.md"])
        self.assertEqual(read(os.path.join(self.ws, "CLAUDE.md")), "guide v2")
        self.assertEqual(read(os.path.join(self.ws, "AGENTS.md")), "my own notes")
        self.assertIn("1 you edited", AI.summary(res))
        res = self.install(src)                                             # still the player's, still kept
        self.assertEqual(res["kept"], ["AGENTS.md"])

    def test_an_existing_file_of_the_player_is_never_overwritten(self):
        write(os.path.join(self.ws, "CLAUDE.md"), "the player's own CLAUDE.md")
        res = self.install()
        self.assertIn("CLAUDE.md", res["kept"])
        self.assertEqual(read(os.path.join(self.ws, "CLAUDE.md")), "the player's own CLAUDE.md")

    def test_path_safety(self):
        for bad in ("../x.md", "/etc/x.md", "C:/x.md", "a/../../x.md", "", "a//b.md"):
            self.assertIsNone(AI.safe_rel(bad), bad)
        self.assertEqual(AI.safe_rel("prompts\\a.md"), "prompts/a.md")
        root = os.path.abspath(os.sep)
        with self.assertRaises(AI.KitError):
            AI.install_kit(KIT, root, home=self.home)
        with self.assertRaises(AI.KitError):
            AI.install_kit(KIT, self.home, home=self.home)
        with self.assertRaises(AI.KitError):
            AI.install_kit(os.path.join(self.tmp.name, "empty"), self.ws, home=self.home)

    def test_kit_skips_links_hidden_and_other_files(self):
        src = os.path.join(self.tmp.name, "kit")
        write(os.path.join(src, "CLAUDE.md"), "g")
        write(os.path.join(src, ".secret.md"), "no")
        write(os.path.join(src, "run.bat"), "no")
        outside = os.path.join(self.tmp.name, "outside.md")
        write(outside, "outside")
        try:
            os.symlink(outside, os.path.join(src, "link.md"))
        except (OSError, NotImplementedError):
            pass
        self.assertEqual(sorted(AI.kit_files(src)), ["CLAUDE.md"])

    def test_never_writes_through_a_symlink(self):
        src = os.path.join(self.tmp.name, "kit")
        write(os.path.join(src, "CLAUDE.md"), "g")
        write(os.path.join(src, "prompts", "a.md"), "p")
        elsewhere = os.path.join(self.tmp.name, "elsewhere")
        os.makedirs(elsewhere)
        os.makedirs(self.ws)
        try:
            os.symlink(elsewhere, os.path.join(self.ws, "Agent"))
        except (OSError, NotImplementedError):
            self.skipTest("no symlinks here")
        with self.assertRaises(AI.KitError):
            self.install(src)
        self.assertEqual(os.listdir(elsewhere), [])


class PromptTests(unittest.TestCase):
    def test_library_parses_in_order(self):
        prompts = AI.list_prompts(KIT)
        ids = [p["id"] for p in prompts]
        self.assertEqual(ids[:2], ["tour-my-install", "first-addon"])
        self.assertEqual(set(ids), set(AI.PROMPT_ORDER))
        for p in prompts:
            self.assertTrue(p["title"] and p["summary"] and p["works"] and len(p["text"]) > 80, p["id"])
            self.assertIn("CLAUDE.md", p["text"], "every prompt starts the agent on the guide")
            self.assertNotIn("api key", p["text"].lower())

    def test_game_copy_matches(self):
        lua = read(os.path.join(ROOT, AI.LUA_PROMPTS))
        self.assertEqual(lua, AI.lua_prompts(AI.list_prompts(KIT)),
                         "Prompts.lua is stale: run python launcher/ai_setup.py --write-lua")

    def test_website_lists_every_prompt(self):
        page = read(os.path.join(ROOT, "www", "ai.html"))
        for p in AI.list_prompts(KIT):
            self.assertIn(html.escape(p["text"]), page, p["id"])
        self.assertNotIn("partner", page.lower().replace("no partnership", ""))
        for name in ("index.html", "portal.html"):
            self.assertIn('href="ai.html"', read(os.path.join(ROOT, "www", name)))
        self.assertEqual(read(os.path.join(ROOT, "www", "index.html")), read(os.path.join(ROOT, "www", "portal.html")))

    def test_parse_needs_a_text_block(self):
        self.assertIsNone(AI.parse_prompt("# T\n\nno block", "x"))
        p = AI.parse_prompt("# T\n\nSum.\n\nWorks on: here.\n\n```text\ndo it\n```\n", "x")
        self.assertEqual((p["title"], p["summary"], p["works"], p["text"]), ("T", "Sum.", "here.", "do it"))


class TerminalTests(unittest.TestCase):
    def test_windows_opens_cmd_in_the_workspace(self):
        argv, kw = AI.terminal_command("C:\\OpenVanilla", "C:\\u\\.local\\bin\\claude.exe", platform="win32")
        self.assertEqual(argv, ["cmd.exe", "/k", "C:\\u\\.local\\bin\\claude.exe"])
        self.assertEqual(kw["cwd"], os.path.abspath("C:\\OpenVanilla"))
        self.assertEqual(kw["creationflags"], AI.CREATE_NEW_CONSOLE)

    def test_macos_quotes_paths(self):
        argv, kw = AI.terminal_command("/Users/p/Open Vanilla's", "/usr/local/bin/claude", platform="darwin")
        self.assertEqual(argv[0], "osascript")
        self.assertIn("cd '/Users/p/Open Vanilla'\"'\"'s'", argv[2].replace('\\"', '"'))
        self.assertIn("/usr/local/bin/claude", argv[2])

    def test_linux_picks_an_installed_terminal_or_none(self):
        argv, _ = AI.terminal_command("/d", "/bin/claude", platform="linux",
                                      which=lambda c: "/usr/bin/xterm" if c == "xterm" else None)
        self.assertEqual(argv[:3], ["xterm", "-e", "bash"])
        self.assertIn("cd /d && /bin/claude", argv[-1])
        self.assertIsNone(AI.terminal_command("/d", None, platform="linux", which=lambda c: None))

    def test_open_terminal_without_claude_still_opens_the_folder(self):
        calls = []
        ok = AI.open_terminal("/d", None, popen=lambda argv, **kw: calls.append((argv, kw)), platform="win32")
        self.assertTrue(ok)
        self.assertEqual(calls[0][0], ["cmd.exe", "/k"])


class LiveFlag:
    def __init__(self, flags):
        self.flags = flags

    def flag(self, name):
        return self.flags.get(name, False)


class LauncherSideTests(unittest.TestCase):
    def test_flag_is_known_and_on_by_default(self):
        self.assertTrue(LC.DEFAULT_FLAGS["ai"])
        self.assertEqual(LC.sanitize({"schema": 1, "serial": 1, "flags": {"ai": False}})["flags"], {"ai": False},
                         "live.json may turn it off")
        self.assertTrue(AI.enabled(LiveFlag(dict(LC.DEFAULT_FLAGS))))
        self.assertFalse(AI.enabled(LiveFlag({"ai": False})), "live content can hide it")

    def test_card_once_from_the_second_launch(self):
        s = {}
        AI.note_launch(s)
        self.assertFalse(AI.should_offer(s, True), "not on the very first launch")
        AI.note_launch(s)
        self.assertTrue(AI.should_offer(s, True))
        self.assertFalse(AI.should_offer(s, False), "hidden by the flag")
        s["ai"]["offered"] = True
        AI.note_launch(s)
        self.assertFalse(AI.should_offer(s, True), "only once")

    def test_on_start_schedules_the_card_and_respects_the_flag(self):
        class App:
            def __init__(self, flags, launches):
                self.settings = {"ai": {"launches": launches}}
                self.live = LiveFlag(flags)
                self.saved = 0
                self.scheduled = []

            def save_settings(self):
                self.saved += 1

            def after(self, ms, fn):
                self.scheduled.append(ms)

        app = App({"ai": True}, 1)
        AI.on_start(app, "/data")
        self.assertEqual(app.settings["ai"]["launches"], 2)
        self.assertEqual(len(app.scheduled), 1)
        hidden = App({"ai": False}, 5)
        AI.on_start(hidden, "/data")
        self.assertEqual(hidden.scheduled, [])

    def test_no_keys_stored(self):
        src = read(os.path.join(ROOT, "launcher", "ai_setup.py"))
        for word in ("api_key", "ANTHROPIC_API_KEY", "urlopen", "requests"):
            self.assertNotIn(word, src)

    def test_launcher_hooks_and_packaging(self):
        launcher = read(os.path.join(ROOT, "launcher", "openvanilla_launcher.py"))
        self.assertIn("import ai_setup", launcher)
        self.assertIn("ai_setup.on_start(self, LAYOUT.data)", launcher)
        self.assertIn("ai_setup.settings_section(", launcher)
        spec = importlib.util.spec_from_file_location("build_repack_ai", os.path.join(ROOT, "packaging", "build_repack.py"))
        B = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(B)
        self.assertIn("ai_setup", B.HIDDEN_IMPORTS)
        with tempfile.TemporaryDirectory() as t:
            launcher_dir = os.path.join(t, "dist")
            write(os.path.join(launcher_dir, "OpenWoW.exe"), "x")
            write(os.path.join(launcher_dir, "app", "base_library.zip"), "x")
            addons = os.path.join(t, "addons")
            write(os.path.join(addons, "Core", "Core.toc"), "## Title: Core\n## X-ClassicPlus: Core\n")
            old = B.ADDON_SRC
            B.ADDON_SRC = addons
            try:
                out = os.path.join(t, "out")
                os.makedirs(out)
                B.assemble(out, launcher_dir, None, "9.9.9", None)
            finally:
                B.ADDON_SRC = old
            shipped = os.path.join(out, "app", "agent")
            self.assertTrue(os.path.isfile(os.path.join(shipped, "CLAUDE.md")))
            self.assertEqual(AI.kit_source(AI.kit_candidates(frozen=True, meipass=os.path.join(out, "app"))), shipped)


try:
    import tkinter as _tk
    _r = _tk.Tk()
    _r.destroy()
    import PIL.ImageTk  # noqa: F401
    HAVE_TK = True
except Exception:
    HAVE_TK = False


@unittest.skipUnless(HAVE_TK, "needs tkinter, Pillow and a display (xvfb-run)")
class SettingsGuiTests(unittest.TestCase):
    """Settings > AI and the one-time card in the real launcher window (xvfb-run -a python3.12 ...)."""

    def setUp(self):
        import shutil
        import openvanilla_launcher as L
        import layout
        self.L = L
        self.tmp = tempfile.mkdtemp(prefix="owai-")
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        saved = dict(LAYOUT=L.LAYOUT, SETTINGS_PATH=L.SETTINGS_PATH, LIVE_CACHE=L.LIVE_CACHE, ADDONS_DIR=L.ADDONS_DIR)
        saved_cls = {k: getattr(L.Launcher, k) for k in ("refresh_realms", "check_for_update", "load_directory")}
        saved_ai = (AI.detect_tools, AI.open_terminal)
        self.app = None

        def restore():
            for k, v in saved.items():
                setattr(L, k, v)
            for k, v in saved_cls.items():
                setattr(L.Launcher, k, v)
            AI.detect_tools, AI.open_terminal = saved_ai
            if self.app is not None:
                try:
                    self.app.destroy()
                except Exception:
                    pass
        self.addCleanup(restore)
        L.LAYOUT = layout.Layout(self.tmp, self.tmp, "portable").ensure()
        L.SETTINGS_PATH = L.LAYOUT.settings_file
        L.LIVE_CACHE = L.LAYOUT.live_cache
        L.ADDONS_DIR = L.LAYOUT.addons_enabled
        for k in saved_cls:
            setattr(L.Launcher, k, lambda s: None)
        self.opened = []
        AI.detect_tools = lambda **kw: [dict(id="claude", name="Claude Code", found=True, path="/opt/claude", url=AI.INSTALL_URL)]
        AI.open_terminal = lambda ws, program=None, **kw: self.opened.append((ws, program)) or True

    def texts(self, root):
        out, stack = [], [root]
        while stack:
            w = stack.pop()
            try:
                out.append(str(w.cget("text")))
            except Exception:
                pass
            stack.extend(w.winfo_children())
        return "\n".join(out)

    def test_settings_section_sets_up_and_opens_claude(self):
        app = self.app = self.L.Launcher()
        app.show_page("settings", animate=False)
        shown = self.texts(app)
        for want in ("AI  (optional)", "found  /opt/claude", "Starter prompt", "Open Vanilla stores no AI keys"):
            self.assertIn(want, shown)
        self.assertNotIn("Install Claude Code", shown)
        AI.install_kit(AI.kit_source(), self.L.LAYOUT.data)
        self.assertTrue(os.path.isfile(os.path.join(self.tmp, "CLAUDE.md")))
        app.show_page("settings", animate=False)
        app._copy(AI.list_prompts(AI.kit_source())[0]["text"], "copied")
        self.assertIn("Read CLAUDE.md", app.clipboard_get())

    def test_flag_hides_the_section(self):
        app = self.app = self.L.Launcher()
        app.live.doc = {"schema": 1, "flags": {"ai": False}}
        app.show_page("settings", animate=False)
        self.assertNotIn("AI  (optional)", self.texts(app))

    def test_card_on_second_launch_only(self):
        write(self.L.SETTINGS_PATH, json.dumps({"ai": {"launches": 1}}))
        app = self.app = self.L.Launcher()
        dlg = AI.offer(app, self.L.LAYOUT.data)
        self.assertIn("ACTIVATE YOUR AI", dlg.title)
        self.assertTrue(app.settings["ai"]["offered"])
        self.assertIn("Show me", dlg.button_cmds)
        dlg.button_cmds["Show me"]()
        self.assertEqual(app.page, "settings")
        self.assertFalse(AI.should_offer(app.settings, True))


if __name__ == "__main__":
    unittest.main()
