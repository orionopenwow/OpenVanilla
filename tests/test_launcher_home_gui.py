"""HOME in the launcher (launcher/openvanilla_launcher.py), driven headless: the ONLINE | SOLO | BROWSER switch,
Play Solo's steps with a fake SPP, the Update ready button, the client button and menu, Workshop > CLIENTS,
Advanced and folder shortcuts.
Skips without Tk or a display (run it under xvfb-run).

    xvfb-run -a python3.12 -m unittest tests.test_launcher_home_gui -v
"""
import os
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))

try:
    import tkinter as tk
    _root = tk.Tk()
    _root.destroy()
    import PIL.ImageTk  # noqa: F401
    HAVE_TK = True
except Exception:
    HAVE_TK = False


@unittest.skipUnless(HAVE_TK, "needs tkinter, Pillow and a display (xvfb-run)")
class HomeGuiTests(unittest.TestCase):
    def setUp(self):
        import openvanilla_launcher as L
        import layout
        self.L = L
        self.tmp = tempfile.mkdtemp(prefix="owhome-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        saved = dict(LAYOUT=L.LAYOUT, SETTINGS_PATH=L.SETTINGS_PATH, LIVE_CACHE=L.LIVE_CACHE, ADDONS_DIR=L.ADDONS_DIR)
        saved_cls = {k: getattr(L.Launcher, k) for k in ("refresh_realms", "check_for_update", "load_directory")}
        saved_mb = {k: getattr(L.messagebox, k) for k in ("askokcancel", "showerror", "askyesno")}

        def restore():
            for k, v in saved.items():
                setattr(L, k, v)
            for k, v in saved_cls.items():
                setattr(L.Launcher, k, v)
            for k, v in saved_mb.items():
                setattr(L.messagebox, k, v)
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
        self.asked, self.errors = [], []
        L.messagebox.askokcancel = lambda *a, **k: self.asked.append(a) or True
        L.messagebox.askyesno = lambda *a, **k: True
        L.messagebox.showerror = lambda *a, **k: self.errors.append(a)
        self.app = None

    def start(self, flags=None):
        self.app = self.L.Launcher()
        if flags is not None:
            self.app.live.doc = {"schema": 1, "flags": flags}
        self.app.show_page("play", animate=False)
        return self.app

    def pump(self, seconds=0.5, until=None):
        end = time.monotonic() + seconds
        app = self.app

        def tick():
            if (until and until()) or time.monotonic() >= end:
                app.quit()
            else:
                app.after(20, tick)

        app.after(20, tick)
        app.mainloop()
        return until() if until else True

    # ------------------------------------------------------------ the mode switch

    def test_one_play_button_with_a_mode_switch(self):
        app = self.start()
        self.assertEqual([k for k, _ in app.play_modes()], ["online", "solo", "browser"])
        self.assertEqual(len(app.cv.find_withtag("modes")), 3)
        app.set_play_mode("solo")
        self.assertEqual(app.settings["play_mode"], "solo")
        self.assertIn("SOLO", app.cv.itemcget(app.play_sub, "text"))
        app.set_play_mode("browser")
        self.assertIn("BROWSER", app.cv.itemcget(app.play_sub, "text"))

    def test_live_flags_hide_modes_and_fall_back(self):
        app = self.start()
        app.set_play_mode("solo")
        app.live.doc = {"schema": 1, "flags": {"solo": False, "browser_play": False}}
        app._live_updated()
        self.assertEqual(app.play_modes(), [("online", "ONLINE")])
        self.assertEqual(app.play_mode(), "online")
        self.assertEqual(len(app.cv.find_withtag("modes")), 1)

    def test_dropdown_opens_with_one_client(self):
        app = self.start()
        self.assertEqual(len(app.desktop_clients()), 1)
        app.set_play_mode("online")
        self.assertTrue(app.cv.itemcget(app.dd_label, "text").endswith("▾"))
        app._client_line_click()
        self.assertTrue(app.cv.find_withtag("menu"))
        texts = [app.cv.itemcget(i, "text") for i in app.cv.find_withtag("menu") if app.cv.type(i) == "text"]
        self.assertIn("Vanilla (stock client)", texts)
        self.assertTrue(any(t.startswith("More clients in Workshop") for t in texts))
        app._menu_more()
        self.assertTrue(self.pump(1, until=lambda: app.page == "mods"))
        self.assertEqual(app.tab_state["mods"], "clients")
        self.assertFalse(app.cv.find_withtag("menu"))

    # ------------------------------------------------------------ Play Solo

    def test_solo_download_then_guided_step(self):
        L = self.L
        app = self.start()
        app.set_play_mode("solo")
        ok, head, _, _, action = app.readiness()
        self.assertTrue(ok)
        self.assertIn("DOWNLOAD SPP CLASSICS (110 MB)", head)
        self.assertEqual(action, "solo_install")
        made = []

        class FakeInstaller:
            def __init__(self, paths, url=None, sha256=None, size=None, report=None, cancel=None, **kw):
                made.append((url, sha256, size))
                self.report = report

            def run(self, until="base"):
                self.report("download", "Downloading SPP Classics: 55 MB of 110 MB", 0.5)
                time.sleep(0.2)
                self.report("base", "Fetching", None)
                return "base"

        vanilla = []
        saved = L.spp.SppInstaller
        self.addCleanup(lambda: setattr(L.spp, "SppInstaller", saved))
        L.spp.SppInstaller = FakeInstaller
        app.solo_vanilla = lambda: vanilla.append(1)
        app.play()                                         # PLAY in Solo mode = the next step
        self.assertEqual(len(self.asked), 1)               # asked first, with the size and the folder
        self.assertIn("110 MB", self.asked[0][1])
        self.assertIn(os.path.join("Realms", "Solo"), self.asked[0][1])
        self.assertTrue(self.pump(2, until=lambda: app.job and app.job.get("progress") == 0.5))
        self.assertIn("DOWNLOADING SPP CLASSICS", app.cv.itemcget(app.bar_text, "text"))
        self.assertTrue(self.pump(3, until=lambda: vanilla))
        self.assertIsNone(app.job)
        self.assertEqual(made[0][0], L.spp.SPP_ZIP_URL)

    def test_solo_states_drive_play(self):
        L = self.L
        app = self.start()
        app.set_play_mode("solo")
        calls = []
        for st, action in (("base", "solo_vanilla"), ("ready", "choose_install")):
            app.spp_state = lambda st=st: st
            self.assertEqual(app.readiness()[4], action)
        app.solo_client = lambda: ("C:/WoW/WoW.exe", "exe", None)
        self.assertEqual(app.readiness()[4], "solo_play")

        class FakeSoloPlay:
            def __init__(self, paths, exe, kind="exe", report=None, cancel=None, data_folder=None, servers=None):
                calls.append((exe, kind))
                self.report, self.servers = report, servers

            def run(self):
                self.report("play", "Playing solo.", None)
                time.sleep(0.2)
                self.report("done", "Solo stopped.", 1.0)

        saved = L.spp.SoloPlay
        self.addCleanup(lambda: setattr(L.spp, "SoloPlay", saved))
        L.spp.SoloPlay = FakeSoloPlay
        app.play()
        self.assertEqual(calls, [("C:/WoW/WoW.exe", "exe")])
        self.assertIsNotNone(app.solo_run)
        self.assertFalse(app.readiness()[0])               # running: PLAY is off until the game closes
        self.assertTrue(self.pump(3, until=lambda: app.solo_run is None))
        self.assertEqual(self.errors, [])

    def test_solo_page_and_live_link(self):
        app = self.start()
        app.open_live_link("openvanilla://page/solo")
        self.assertEqual(app.page, "solo")
        app.open_live_link("openvanilla://page/nothere")
        self.assertEqual(app.page, "solo")

    # ------------------------------------------------------------ updates

    def test_update_ready_button_and_pill(self):
        app = self.start()
        app.download = {"progress": 0.3}
        app.update_info = {"version": "9.0.0"}
        app.update_status()
        self.assertEqual(app.cv.itemcget(app.bar_side, "text"), "Downloading update 30%")
        self.assertFalse(app.cv.find_withtag("updatebtn"))
        app.download = {"done": True, "progress": 1.0}
        app._set_update_ready({"version": "9.0.0"})
        self.assertTrue(app.cv.find_withtag("updatebtn"))          # the gold button above PLAY on HOME
        self.assertIn("ready", app.cv.itemcget(app.bar_side, "text"))
        app.show_page("settings", animate=False)
        self.assertFalse(app.cv.find_withtag("updatebtn"))         # elsewhere the text beside the bar says it
        handed = []
        self.L.updater.handoff, saved = (lambda info, lay: handed.append(info["version"])), self.L.updater.handoff
        self.addCleanup(lambda: setattr(self.L.updater, "handoff", saved))
        app._exit_for_update = lambda: handed.append("exit")
        app._update_click()
        self.assertEqual(handed[0], "9.0.0")

    # ------------------------------------------------------------ live cards, settings

    def _overlaps(self, app, tag):
        """Page items whose box overlaps the item tagged `tag`."""
        cv = app.cv
        x1, y1, x2, y2 = cv.bbox(tag)
        mine = set(cv.find_withtag(tag))
        hits = []
        for it in cv.find_withtag("page"):
            if it in mine or cv.itemcget(it, "state") == "hidden":
                continue
            b = cv.bbox(it)
            if b and b[0] < x2 and x1 < b[2] and b[1] < y2 and y1 < b[3]:
                hits.append((cv.type(it), cv.itemcget(it, "text") if cv.type(it) == "text" else b))
        return hits

    def test_home_has_the_client_button_and_no_cards(self):
        L = self.L
        app = self.start()
        app.live.doc = {"schema": 1, "hero": {"title": "Welcome to Open Vanilla"},
                        "featured": [{"id": "herald", "title": "Meet Herald", "text": "x"}]}   # a 1.17.0-era live.json
        app.show_page("play", animate=False)
        self.assertFalse(app.cv.find_withtag("clientbtn"))      # GET VANILLA CLIENT V1.3 is hidden for now
        self.assertEqual(app._client_btn_label, "")
        self.addCleanup(setattr, L.home_logic, "HIDE_GET_VANILLA_CLIENT", True)
        L.home_logic.HIDE_GET_VANILLA_CLIENT = False            # the layout checks below, with it shown
        for session in ({}, {"user": "TESTER", "display": "Tester", "password": "pw"}):
            app.session = session
            app.show_page("play", animate=False)
            texts = [app.cv.itemcget(i, "text") for i in app.cv.find_withtag("page") if app.cv.type(i) == "text"]
            self.assertNotIn("WELCOME TO OPEN VANILLA", texts)
            self.assertNotIn("MEET HERALD", texts)
            self.assertTrue(app.cv.find_withtag("clientbtn"))
            self.assertEqual(app._client_btn_label, "GET VANILLA CLIENT V1.3")     # Vanilla, not installed yet
            self.assertEqual(self._overlaps(app, "clientbtn"), [], session)
            x1, y1, x2, y2 = app.cv.bbox("clientbtn")
            self.assertLessEqual(y2, L.WIN_H - L.BOT)
            self.assertLessEqual(x2, L.ART_X + 18 + L.LEFT_W + 2)
        self.assertFalse(hasattr(app, "_shipped_cards"))
        app.job = {"label": "x", "progress": 0.1}
        app.show_page("play", animate=False)
        self.assertEqual(app._client_btn_label, "CANCEL DOWNLOAD")
        app.job = None

    def test_workshop_clients_tab(self):
        L = self.L
        app = self.start()
        with open(L.LAYOUT.clients_txt, "w", encoding="utf-8") as f:
            f.write("name = My Test Client\ntype = engine\nversion = 0.1\nurl = https://example.org/t.zip\n"
                    "page = https://github.com/example/t\ndescription = From clients.txt\n")
        app.live.doc = {"schema": 1, "clients": [{"id": "live-one", "name": "Live One", "type": "web",
                                                  "version": "Web", "status": "coming_soon"}]}
        app._live_updated()
        app.open_workshop_clients()
        self.assertEqual(app.page, "mods")

        def labels():
            out, stack = [], list(app.page_widgets)
            while stack:
                w = stack.pop()
                stack.extend(w.winfo_children())
                if isinstance(w, tk.Label):
                    out.append(w.cget("text"))
            return out

        shown = labels()
        for name in ("Vanilla (stock client)", "Open Vanilla Classic+", "Live One", "My Test Client"):
            self.assertIn(name, shown)
        self.assertIn("COMING SOON", shown)
        self.assertIn("From clients.txt", shown)
        cat = {e["id"]: e for e in app.client_catalog()}
        app.workshop_add_client(cat["my-test-client"])
        self.assertEqual(app.settings["my_clients"], ["my-test-client"])
        self.assertEqual([c["id"] for c in app.clients], ["vanilla", "my-test-client"])
        self.assertEqual(app.clients[1]["download_url"], "https://example.org/t.zip")
        app.workshop_remove_client(cat["vanilla"])                 # built in: stays
        self.assertEqual(len(app.clients), 2)
        fetched = []
        app.fetch_or_open = lambda url, label, then=None: fetched.append(url)
        app.workshop_get_client(cat["my-test-client"])            # the usual client download flow
        self.assertEqual(app.client()["id"], "my-test-client")
        self.assertEqual(fetched, ["https://example.org/t.zip"])
        app.workshop_remove_client(cat["my-test-client"])
        self.assertEqual([c["id"] for c in app.clients], ["vanilla"])
        self.assertEqual(app.client()["id"], "vanilla")

    def test_advanced_switch_and_folders(self):
        app = self.start()

        def entries():
            out, stack = 0, list(app.page_widgets)
            while stack:
                w = stack.pop()
                stack.extend(w.winfo_children())
                out += isinstance(w, tk.Entry)
            return out

        app.show_page("settings", animate=False)
        plain = entries()
        app.settings["advanced"] = True
        app.show_page("settings", animate=False)
        self.assertGreater(entries(), plain)                       # the client download link field
        names = [n for n, _, _ in app.folder_shortcuts()]
        self.assertEqual(names[:4], ["AddOns", "Screenshots", "Logs", "Realms"])
        self.assertEqual(app.folder_shortcuts()[0][1], self.L.ADDONS_DIR)


if __name__ == "__main__":
    unittest.main()
