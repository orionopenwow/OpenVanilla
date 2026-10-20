"""The Open Vanilla Manual (docs/manual -> www/manual): it builds, every link and anchor resolves,
the committed pages match the sources, and the deep links the site, launcher and Herald use exist."""
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load():
    spec = importlib.util.spec_from_file_location("build_manual", os.path.join(ROOT, "tools", "build_manual.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ManualTests(unittest.TestCase):
    def test_pages_are_current(self):
        bm = load()
        tmp = tempfile.mkdtemp()
        try:
            bm.OUT = tmp
            bm.build()
            for f in os.listdir(tmp):
                with open(os.path.join(tmp, f), encoding="utf-8") as a, \
                        open(os.path.join(ROOT, "www", "manual", f), encoding="utf-8") as b:
                    self.assertEqual(a.read(), b.read(), f"www/manual/{f} is stale: run python tools/build_manual.py")
        finally:
            shutil.rmtree(tmp)

    def test_links_resolve(self):
        bm = load()
        self.assertEqual(bm.check_links(), 0)

    def test_deep_links_used_elsewhere_exist(self):
        links = json.load(open(os.path.join(ROOT, "www", "manual", "links.json"), encoding="utf-8"))
        for key in ("ai#setup", "workshop#upload", "workshop#fork", "editing#lua50", "launcher#client-setup",
                    "community#tickets", "classic-plus#commands", "contributing#fix-the-manual"):
            self.assertIn(key, links)


if __name__ == "__main__":
    unittest.main()
