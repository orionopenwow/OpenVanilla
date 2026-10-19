"""The launcher's Workshop: launcher/workshop.py (install links, checksums, link-outs never downloaded,
install counting) and, headless, the WORKSHOP > ADDONS tab plus an openvanilla://workshop/install/<id>
link on the command line (launcher/openvanilla_launcher.py). The GUI half skips without Tk or a display
(run it under xvfb-run).

    xvfb-run -a python3 -m unittest tests.test_workshop_launcher -v
"""
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LAUNCHER = os.path.join(ROOT, "launcher")
sys.path.insert(0, LAUNCHER)

import workshop as WS  # noqa: E402  (launcher/workshop.py)

try:
    import tkinter as tk
    _root = tk.Tk()
    _root.destroy()
    import PIL.ImageTk  # noqa: F401
    HAVE_TK = True
except Exception:  # no tkinter, no Pillow, or no display
    HAVE_TK = False

GOOD = os.path.join(HERE, "fixtures", "workshop", "GoodAddon")


def good_zip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for f in sorted(os.listdir(GOOD)):
            z.write(os.path.join(GOOD, f), "GoodAddon/" + f)
    return buf.getvalue()


class FakeSite:
    """openvanilla.app and the realm API in memory."""

    def __init__(self):
        self.zip = good_zip()
        sha = hashlib.sha256(self.zip).hexdigest()
        self.files = {"community/workshop/files/goodaddon-%s.zip" % sha[:12]: self.zip,
                      "community/workshop/files/tampered-000000000000.zip": self.zip + b"x"}
        good = {"id": "goodaddon", "name": "Good Addon", "author": "Test Author", "summary": "Well behaved.", "category": "interface",
                "compat": "works", "ours": False, "rehost": True, "install": True, "license": "MIT", "tags": ["test"],
                "stats": {"rating": 4.5, "votes": 2, "installs": 7},
                "files": [{"name": "goodaddon.zip", "url": "community/workshop/files/goodaddon-%s.zip" % sha[:12], "sha256": sha,
                           "size": len(self.zip)}], "homepage": "https://github.com/test/GoodAddon"}
        linked = {"id": "linked", "name": "Linked Addon", "author": "Someone", "summary": "All rights reserved.", "category": "maps",
                  "compat": "unknown", "ours": False, "rehost": False, "install": False, "license": "Proprietary", "tags": [],
                  "files": [], "homepage": "https://example.invalid/linked"}
        tampered = dict(good, id="tampered", name="Tampered",
                        files=[{"name": "t.zip", "url": "community/workshop/files/tampered-000000000000.zip", "sha256": sha, "size": 1}])
        offsite = dict(good, id="offsite", name="Offsite",
                       files=[{"name": "o.zip", "url": "https://evil.example/o.zip", "sha256": sha, "size": 1}])
        self.addons = {a["id"]: a for a in (good, linked, tampered, offsite)}
        self.gets, self.posts = [], []

    def get(self, url, timeout=20, limit=WS.MAX_PACKAGE):
        self.gets.append(url)
        base = "https://openvanilla.app/"
        if not url.startswith(base):
            raise AssertionError("fetched off the site: " + url)
        path = url[len(base):]
        if path == "community/workshop/index.json":
            cards = [{k: v for k, v in a.items() if k not in ("files", "homepage")} for a in self.addons.values()]
            return json.dumps({"addons": cards, "count": len(cards)}).encode()
        if path.startswith("community/workshop/") and path.endswith(".json"):
            a = self.addons.get(path.rsplit("/", 1)[1][:-5])
            if not a:
                raise OSError("HTTP 404")
            return json.dumps(a).encode()
        if path in self.files:
            return self.files[path]
        raise OSError("HTTP 404 " + path)

    def post(self, url, timeout=8):
        self.posts.append(url)
        return {"installs": 8}


def install_zip(zip_path, addons_dir):
    """The launcher's install_zip without importing Tk (same contract)."""
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(addons_dir)
        return sorted({n.split("/")[0] for n in z.namelist()})


class WorkshopModuleTests(unittest.TestCase):
    def setUp(self):
        self.site = FakeSite()
        self.ws = WS.Workshop(get=self.site.get, post=self.site.post)
        self.dir = tempfile.mkdtemp(prefix="ws-addons-")
        self.addCleanup(shutil.rmtree, self.dir, True)

    def test_links(self):
        self.assertEqual(WS.parse_link("openvanilla://workshop/install/pfui"), ["pfui"])
        self.assertEqual(WS.parse_link("openvanilla://workshop/install/cp-raid,bigwigs,cp-raid/"), ["cp-raid", "bigwigs"])
        for bad in ("openvanilla://workshop/install/", "openvanilla://workshop/install/PfUI", "openvanilla://join/abcdefghijklmnop",
                    "https://openvanilla.app/workshop/install/pfui", "openvanilla://workshop/install/../x", None, ""):
            self.assertIsNone(WS.parse_link(bad), bad)

    def test_install_counts_and_skips_linkouts(self):
        res = self.ws.install(["goodaddon", "linked", "tampered", "offsite", "nosuch"], self.dir, install_zip)
        by = {r["id"]: r for r in res}
        self.assertTrue(by["goodaddon"]["ok"])
        self.assertEqual(by["goodaddon"]["folders"], ["GoodAddon"])
        self.assertTrue(os.path.isfile(os.path.join(self.dir, "GoodAddon", "GoodAddon.toc")))
        self.assertFalse(by["linked"]["ok"])
        self.assertEqual(by["linked"]["link"], "https://example.invalid/linked")
        self.assertIn("checksum mismatch", by["tampered"]["error"])
        self.assertIn("unexpected package location", by["offsite"]["error"])
        self.assertFalse(by["nosuch"]["ok"])
        self.assertEqual(self.site.posts, ["https://play.openvanilla.app/api/workshop/installs/goodaddon"], "only good installs count")
        self.assertFalse(any("linked" in u and u.endswith(".zip") for u in self.site.gets), "a link-out is never downloaded")
        line = WS.summary(res)
        self.assertIn("Installed: Good Addon", line)
        self.assertIn("1 from the author's page", line)
        self.assertIn("Tampered", line)

    def test_index_and_search(self):
        self.ws.load_index()
        self.assertEqual([c["id"] for c in self.ws.cards("good")], ["goodaddon"])
        self.assertEqual(len(self.ws.cards("")), 4)
        self.assertEqual(self.ws.cards("maps")[0]["id"], "linked")

    def test_counting_is_best_effort(self):
        def down(url, timeout=8):
            raise OSError("offline")
        ws = WS.Workshop(get=self.site.get, post=down)
        self.assertTrue(ws.install(["goodaddon"], self.dir, install_zip)[0]["ok"])


@unittest.skipUnless(HAVE_TK, "needs tkinter, Pillow and a display (xvfb-run)")
class WorkshopGuiTests(unittest.TestCase):
    def setUp(self):
        import openvanilla_launcher as L
        self.L = L
        self.site = FakeSite()
        self.tmp = tempfile.mkdtemp(prefix="ws-gui-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.addons = os.path.join(self.tmp, "Interface", "AddOns")
        self.opened, self.errors = [], []
        saved = (L.messagebox.showerror, L.SETTINGS_PATH, L.Launcher.refresh_realms, L.Launcher.check_for_update,
                 L.Launcher.load_directory, L.Launcher.client_addons_dir, L.Launcher._workshop, L.safe_open, list(sys.argv))
        self.addCleanup(self._restore, saved)
        L.messagebox.showerror = lambda *a, **k: self.errors.append(a)
        L.SETTINGS_PATH = os.path.join(self.tmp, "settings.json")
        L.Launcher.refresh_realms = lambda s: None
        L.Launcher.check_for_update = lambda s: None
        L.Launcher.load_directory = lambda s: None
        L.Launcher.client_addons_dir = lambda s, c=None: self.addons
        site = self.site
        L.Launcher._workshop = lambda s: WS.Workshop(get=site.get, post=site.post)
        L.safe_open = self.opened.append
        sys.argv = ["openvanilla_launcher.py"]
        self.app = None

    def _restore(self, saved):
        L = self.L
        (L.messagebox.showerror, L.SETTINGS_PATH, L.Launcher.refresh_realms, L.Launcher.check_for_update,
         L.Launcher.load_directory, L.Launcher.client_addons_dir, L.Launcher._workshop, L.safe_open, sys.argv[:]) = saved
        if self.app is not None:
            try:
                self.app.destroy()
            except Exception:
                pass

    def pump(self, seconds, until):
        end = time.monotonic() + seconds
        app = self.app

        def tick():
            if until() or time.monotonic() >= end:
                app.quit()
            else:
                app.after(20, tick)

        app.after(20, tick)
        app.mainloop()
        return until()

    def texts(self, w):
        out = [w.cget("text")] if isinstance(w, (tk.Label, tk.Button)) else []
        for c in w.winfo_children():
            out += self.texts(c)
        return out

    def rows(self, w, out=None):
        """{addon name: [its image buttons]} for every list row on the page."""
        out = {} if out is None else out
        for c in w.winfo_children():
            if isinstance(c, tk.Frame):
                btns = [b for b in c.winfo_children() if isinstance(b, tk.Label) and str(b.cget("image"))]
                names = [t for t in self.texts(c) if t]
                if btns and names:
                    out[names[0]] = btns
                else:
                    self.rows(c, out)
            else:
                self.rows(c, out)
        return out

    def test_addons_tab_lists_and_installs(self):
        self.app = app = self.L.Launcher()
        app.tab_state["mods"] = "workshop"
        app.show_page("mods", animate=False)
        self.assertTrue(self.pump(5, lambda: app.wsx.get("index") is not None))
        app.show_page("mods", animate=False)
        app.update()
        shown = " | ".join(self.texts(app))
        for s in ("Good Addon", "Linked Addon", "Works", "Not checked", "★ 4.5 (2)"):
            self.assertIn(s, shown)
        rows = self.rows(app)
        self.assertEqual(len(rows["Good Addon"]), 2, "Install + Page")
        self.assertEqual(len(rows["Linked Addon"]), 1, "only 'Get from author': a link-out has no Install")
        # search box filters the list
        app.ws_query = "linked"
        app.show_page("mods", animate=False)
        app.update()
        shown = " | ".join(self.texts(app))
        self.assertIn("Linked Addon", shown)
        self.assertNotIn("Good Addon", shown)
        app.ws_query = ""
        app.show_page("mods", animate=False)
        app.update()
        install = self.rows(app)["Good Addon"][0]   # created first: Install, then Page
        install.event_generate("<Button-1>")
        self.assertTrue(self.pump(5, lambda: app.wsx.get("last") is not None))
        self.assertTrue(os.path.isfile(os.path.join(self.addons, "GoodAddon", "GoodAddon.toc")))
        self.assertIn("Installed: Good Addon", app._notice[0])
        self.assertEqual(self.errors, [])

    def test_install_link_on_the_command_line(self):
        sys.argv = ["openvanilla_launcher.py", "openvanilla://workshop/install/goodaddon,linked"]
        self.app = app = self.L.Launcher()
        self.assertTrue(self.pump(8, lambda: app.wsx.get("last") is not None))
        self.assertEqual(app.page, "mods")
        self.assertEqual(app.tab_state["mods"], "workshop")
        res = {r["id"]: r for r in app.wsx["last"]}
        self.assertTrue(res["goodaddon"]["ok"])
        self.assertFalse(res["linked"]["ok"])
        self.assertEqual(self.opened, ["https://example.invalid/linked"], "a link-out opens the author's page")
        self.assertTrue(os.path.isdir(os.path.join(self.addons, "GoodAddon")))
        self.assertIn("/api/workshop/installs/goodaddon", " ".join(self.site.posts))


if __name__ == "__main__":
    unittest.main()
