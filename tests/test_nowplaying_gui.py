"""The launcher's "Share what I'm listening to" switch (Settings > Privacy), headless. Skips without
Tk or a display (run it under xvfb-run).

    xvfb-run -a python3.12 -m unittest tests.test_nowplaying_gui -v
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "launcher"))
sys.path.insert(0, HERE)

try:
    import tkinter as tk
    _root = tk.Tk()
    _root.destroy()
    import PIL.ImageTk  # noqa: F401
    HAVE_TK = True
except Exception:  # no tkinter, no Pillow, or no display
    HAVE_TK = False


@unittest.skipUnless(HAVE_TK, "needs tkinter, Pillow and a display (xvfb-run)")
class NowPlayingSettingTests(unittest.TestCase):
    def setUp(self):
        import p2p_gui_fakes as p2p_fakes
        p2p_fakes.install()
        self.addCleanup(p2p_fakes.uninstall)
        import openvanilla_launcher as L
        self.L = L
        self.tmp = tempfile.mkdtemp(prefix="ownp-")
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        saved = (L.SETTINGS_PATH, L.STATE_DIR, L.CONFIG_DIR, L.Launcher.refresh_realms, L.Launcher.check_for_update,
                 L.Launcher.load_directory, list(sys.argv))
        self.addCleanup(self._restore, saved)
        L.SETTINGS_PATH = os.path.join(self.tmp, "settings.json")
        L.STATE_DIR = os.path.join(self.tmp, "launcher")
        L.CONFIG_DIR = os.path.join(self.tmp, "benilla-config")
        os.makedirs(os.path.join(L.CONFIG_DIR, "saved", "Realm-Berra"))
        L.Launcher.refresh_realms = lambda s: None
        L.Launcher.check_for_update = lambda s: None
        L.Launcher.load_directory = lambda s: None
        sys.argv = ["openvanilla_launcher.py"]
        self.app = None

    def _restore(self, saved):
        L = self.L
        if self.app is not None:
            self.app.nowplaying.stop()
            try:
                self.app.destroy()
            except Exception:
                pass
        (L.SETTINGS_PATH, L.STATE_DIR, L.CONFIG_DIR, L.Launcher.refresh_realms, L.Launcher.check_for_update,
         L.Launcher.load_directory, sys.argv[:]) = saved

    def widgets(self, w):
        yield w
        for c in w.winfo_children():
            yield from self.widgets(c)

    def test_switch_is_off_by_default_and_shares_when_on(self):
        self.app = app = self.L.Launcher()
        app.nowplaying.stop()                      # drive ticks by hand
        app.nowplaying.windows_reader = lambda: {"title": "Tavern Song", "artist": "Unknown Bard"}
        app.show_page("settings", animate=False)
        app.update()
        box = [w for w in self.widgets(app) if isinstance(w, tk.Checkbutton) and "listening" in str(w.cget("text"))]
        self.assertEqual(len(box), 1)
        self.assertFalse(app._setting_vars["share_listening"].get(), "off by default")
        self.assertEqual(app.nowplaying.tick(), "")
        self.assertFalse(os.path.exists(os.path.join(self.L.STATE_DIR, "nowplaying.json")))

        box[0].invoke()
        with open(self.L.SETTINGS_PATH, encoding="utf-8") as f:
            self.assertTrue(json.load(f)["share_listening"])
        self.assertEqual(app.nowplaying.tick(), "Tavern Song - Unknown Bard")
        with open(os.path.join(self.L.STATE_DIR, "nowplaying.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["artist"], "Unknown Bard")
        with open(os.path.join(self.L.CONFIG_DIR, "saved", "Realm-Berra", "Persona.lua"), encoding="utf-8") as f:
            self.assertIn("Tavern Song - Unknown Bard", f.read())


if __name__ == "__main__":
    unittest.main()
