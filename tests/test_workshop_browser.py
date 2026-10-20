"""Workshop addons in browser play: the builder's `browser` flag (tools/workshop_build.py browser_ok)
and the page layer that adds and loads them (realm/www/workshop.js, realm/classicplus/addons-loader.js)."""
import io
import json
import os
import sys
import tempfile
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import workshop_build  # noqa: E402


def make_zip(files):
    fd, path = tempfile.mkstemp(suffix=".zip")
    os.close(fd)
    with zipfile.ZipFile(path, "w") as z:
        for name, text in files.items():
            z.writestr(name, text)
    return path


class BrowserFlag(unittest.TestCase):
    def check(self, files, want):
        p = make_zip(files)
        self.addCleanup(os.remove, p)
        self.assertEqual(workshop_build.browser_ok(p), want, files)

    def test_lua_only_is_browser(self):
        self.check({"A/A.toc": "## Interface: 11200\n## SavedVariables: A_DB\nA.lua\nsub\\b.lua\n", "A/A.lua": "x=1", "A/sub/b.lua": "y=1"}, True)

    def test_xml_is_not(self):
        self.check({"A/A.toc": "## Interface: 11200\nA.xml\n", "A/A.xml": "<Ui/>"}, False)

    def test_missing_dependency_is_not(self):
        self.check({"A/A.toc": "## Dependencies: pfQuest\nA.lua\n", "A/A.lua": "x=1"}, False)

    def test_dependency_in_the_package_is_fine(self):
        self.check({"A/A.toc": "## RequiredDeps: B\nA.lua\n", "A/A.lua": "", "B/B.toc": "B.lua\n", "B/B.lua": ""}, True)

    def test_no_toc_or_bad_zip(self):
        self.check({"README.txt": "hi"}, False)
        fd, path = tempfile.mkstemp(suffix=".zip")
        os.write(fd, b"not a zip")
        os.close(fd)
        self.addCleanup(os.remove, path)
        self.assertFalse(workshop_build.browser_ok(path))

    def test_published_index_matches_the_packages(self):
        out = os.path.join(ROOT, "www", "community", "workshop")
        idx = json.load(open(os.path.join(out, "index.json"), encoding="utf-8"))
        for a in idx["addons"]:
            if a.get("ours") or not a.get("install"):
                self.assertFalse(a.get("browser"), a["id"])
                continue
            d = json.load(open(os.path.join(out, a["id"] + ".json"), encoding="utf-8"))
            zp = os.path.join(out, "files", d["files"][0]["name"])
            if os.path.isfile(zp):
                self.assertEqual(bool(a.get("browser")), workshop_build.browser_ok(zp), a["id"])


class PageLayer(unittest.TestCase):
    def read(self, rel):
        return open(os.path.join(ROOT, rel), encoding="utf-8").read()

    def test_workshop_js_checks_and_never_parses_html(self):
        js = self.read("realm/www/workshop.js")
        self.assertIn("crypto.subtle.digest('SHA-256'", js)          # the download must match the Workshop's checksum
        self.assertIn("unsafe path in zip", js)
        self.assertIn("noaddons", js)                                # safe mode
        for bad in ("innerHTML", "eval(", "new Function"):
            self.assertNotIn(bad, js)

    def test_wired_in(self):
        self.assertIn("import(BASE + 'workshop.js')", self.read("realm/www/openvanilla.js"))
        self.assertIn(" workshop.js ", self.read("hetzner/openvanilla_realm_up.sh"))
        loader = self.read("realm/classicplus/addons-loader.js")
        self.assertIn("await loadWorkshop();", loader)
        self.assertIn("dispatchFrom", loader)                        # login events only to the Workshop addons' frames
        self.assertIn("play.openvanilla.app/?addon=", self.read("www/workshop/addon.html"))


if __name__ == "__main__":
    unittest.main()
