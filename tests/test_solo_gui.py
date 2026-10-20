"""PLAY SOLO in the host panel (launcher_gui.py), driven headless: the busy-realm banner and the Play
Solo flow with a fake session. Skips without Tk or a display (run it under xvfb-run).

    xvfb-run -a python3 -m unittest tests.test_solo_gui -v
"""
import os
import sys
import threading
import time
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

try:
    import tkinter as tk
    _root = tk.Tk()
    _root.destroy()
    HAVE_TK = True
except Exception:  # no tkinter, or no display
    HAVE_TK = False


def stub_modules():
    """launcher_gui imports the SPP helpers and Pillow; the parts under test need neither."""
    if "server_control" not in sys.modules:
        sc = types.ModuleType("server_control")
        sc.run_mysql_query = lambda q: (1, "", "stub")
        sc.start_database = sc.start_realmd = sc.start_mangosd = lambda: False
        sc.stop_started_services = lambda: None
        sys.modules["server_control"] = sc
    if "authcheck" not in sys.modules:
        ac = types.ModuleType("authcheck")
        ac.verify_realm_login = lambda u, p: (None, "stub")
        sys.modules["authcheck"] = ac
    try:
        import importlib
        importlib.import_module("PIL.Image")
        importlib.import_module("PIL.ImageTk")
    except ImportError:
        pil = types.ModuleType("PIL")
        pil.Image = types.SimpleNamespace(open=lambda p: (_ for _ in ()).throw(OSError("stub")),
                                          Resampling=types.SimpleNamespace(LANCZOS=1))
        pil.ImageTk = types.SimpleNamespace(PhotoImage=lambda im: None)
        sys.modules["PIL"] = pil
        sys.modules["PIL.Image"] = pil.Image
        sys.modules["PIL.ImageTk"] = pil.ImageTk


@unittest.skipUnless(HAVE_TK, "needs tkinter and a display (xvfb-run)")
class SoloGuiTests(unittest.TestCase):
    def setUp(self):
        stub_modules()
        import launcher_gui as G
        self.G = G
        G.messagebox.showerror = lambda *a, **k: self.errors.append(a)
        G.messagebox.showinfo = lambda *a, **k: None
        G.messagebox.askokcancel = lambda *a, **k: True
        G.messagebox.askyesno = lambda *a, **k: True
        self.errors = []
        G.is_port_open = lambda port: False
        G.WarcraftLauncher._poll_live_realm = lambda self: None   # no network in tests
        G.WarcraftLauncher._poll_players = lambda self: None
        self.app = G.WarcraftLauncher()
        self.addCleanup(self._destroy)

    def _destroy(self):
        try:
            self.app.destroy()
        except Exception:
            pass

    def pump(self, seconds=0.5, until=None):
        """Run Tk's main loop (worker threads hand results over with after(), which needs it) until
        until() is true or the time is up."""
        end = time.monotonic() + seconds

        def tick():
            if (until and until()) or time.monotonic() >= end:
                self.app.quit()
            else:
                self.app.after(20, tick)

        self.app.after(20, tick)
        self.app.mainloop()
        return until() if until else True

    def test_busy_banner_shows_and_hides(self):
        self.pump(0.2)
        self.assertFalse(self.app.busy_banner.winfo_ismapped())
        self.app._live_realm_sample({"reachable": True, "soap": False, "latency_ms": 100})
        self.pump(0.2)
        self.assertTrue(self.app.busy_banner.winfo_ismapped())
        self.assertIn("world server is down", self.app.lbl_busy.cget("text"))
        self.app._dismiss_busy_banner()
        self.app._live_realm_sample({"reachable": True, "soap": False, "latency_ms": 100})
        self.pump(0.2)
        self.assertFalse(self.app.busy_banner.winfo_ismapped())       # dismissed for this state
        self.app._live_realm_sample({"reachable": True, "soap": True, "latency_ms": 100})
        self.app._live_realm_sample({"reachable": True, "soap": True, "queue": 7, "latency_ms": 100})
        self.pump(0.2)
        self.assertTrue(self.app.busy_banner.winfo_ismapped())         # a new state shows again
        self.assertIn("7 players are in the queue", self.app.lbl_busy.cget("text"))

    def test_play_solo_flow_with_a_fake_session(self):
        G = self.G
        events = []

        class FakeSession:
            def __init__(self, reporter=None, **kw):
                self.reporter = reporter
                self.cancel = threading.Event()

            def pack_status(self):
                return "missing", {"version": "1.15.0", "size": 300 * 1024 * 1024}

            def run(self):
                r = self.reporter
                r.stage("download", "Downloading the solo server (300.0 MB, once)…")
                for i in range(5):
                    r.progress(i * 60, 300, "Downloading…")
                    time.sleep(0.02)
                r.progress(0, None, "Checking the download…")
                r.stage("play", "Starting the game.")
                r.info("Sign in with account SOLO, password SOLO.")
                events.append("ran")
                self.cancel.wait(5)
                r.stage("done", "Solo stopped.")
                return 0

            def stop(self):
                self.cancel.set()

        saved = G.solo.SoloSession
        G.solo.SoloSession = FakeSession
        self.addCleanup(setattr, G.solo, "SoloSession", saved)
        self.app.play_solo()
        self.assertTrue(self.pump(3, until=lambda: "ran" in events and self.app.solo_dialog is not None))
        dialog = self.app.solo_dialog
        self.pump(0.3)
        self.assertEqual(dialog.btn.cget("text"), "Stop Solo")
        self.assertIn("SOLO", dialog.lbl_detail.cget("text"))
        self.app.play_solo()                                            # a second click just shows the window
        self.assertIs(self.app.solo_dialog, dialog)
        dialog._cancel()                                                # Stop Solo
        self.assertTrue(self.pump(3, until=lambda: self.app.solo_session is None))
        self.assertEqual(self.errors, [])
        logs = "\n".join(t for _, t in self.app.all_log_entries)
        self.assertIn("[SOLO] Downloading the solo server", logs)

    def test_error_is_shown(self):
        G = self.G

        class Broken:
            def __init__(self, reporter=None, **kw):
                self.reporter = reporter

            def pack_status(self):
                return "ok", None

            def run(self):
                raise G.solo.SoloError("No game client found.")

            def stop(self):
                pass

        saved = G.solo.SoloSession
        G.solo.SoloSession = Broken
        self.addCleanup(setattr, G.solo, "SoloSession", saved)
        self.app.play_solo()
        self.assertTrue(self.pump(3, until=lambda: self.errors))
        self.assertIn("No game client found.", self.errors[0][1])
        self.assertIsNone(self.app.solo_session)

    def test_local_realm_running_blocks_solo(self):
        self.G.is_port_open = lambda port: port == 3724
        self.app.play_solo()
        self.assertIn("HALT ALL SERVICES", self.errors[0][1])


if __name__ == "__main__":
    unittest.main()
