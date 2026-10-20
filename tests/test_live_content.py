"""Live content: packaging/live_content.py builds + signs www/downloads/live.src.json, and
launcher/live_content.py only adopts a live.json that verifies, keeps the cache otherwise, refuses an
older serial, and exposes flags/links/buttons. Data only.

    python -m unittest tests.test_live_content -v
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))

import ed25519  # noqa: E402
import live_content as LC  # noqa: E402  (launcher/live_content.py)

import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location("pkg_live", os.path.join(ROOT, "packaging", "live_content.py"))
PKG = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(PKG)

SEED = bytes(range(32))
PUB = ed25519.public_key(SEED).hex()
URL = "https://example.test/downloads/live.json"


def signed(doc, serial):
    body, _, _ = PKG.build(doc, serial)
    return body, ed25519.sign(SEED, body).hex()


class Web:
    def __init__(self):
        self.files = {}

    def put(self, body, sig):
        self.files[URL] = body
        if sig is None:
            self.files.pop(URL + ".sig", None)
        else:
            self.files[URL + ".sig"] = sig.encode()

    def __call__(self, url, timeout=6):
        if url not in self.files:
            raise OSError("offline")
        return self.files[url]


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = os.path.join(self.tmp.name, "Cache", "live.json")
        self.web = Web()
        self.doc = {"hero": {"title": "Hi", "text": "there", "link": "openvanilla://page/notes"},
                    "flags": {"solo": False, "relay": True},
                    "featured": [{"id": "herald", "title": "The Herald", "link": "https://x.test/herald.html",
                                  "image": "https://x.test/h.webp"}],
                    "links": {"SPP_PAGE": "https://github.com/a/releases", "SPP_URL": "https://evil.test/b.zip", "SPP_SHA256": "AB" * 32}}

    def tearDown(self):
        self.tmp.cleanup()

    def live(self):
        return LC.LiveContent(self.cache, URL, PUB, get=self.web)

    def test_good_file_is_adopted_and_cached(self):
        self.web.put(*signed(self.doc, 10))
        lv = self.live()
        self.assertEqual(lv.refresh(), "updated")
        self.assertFalse(lv.flag("solo"))
        self.assertTrue(lv.flag("relay"))
        self.assertTrue(lv.flag("host_friends"), "unset flags keep their defaults")
        self.assertEqual(lv.doc["featured"][0]["id"], "herald")
        self.assertEqual(lv.get_link("SPP_PAGE"), "https://github.com/a/releases")
        self.assertIsNone(lv.get_link("SPP_URL"), "live content can't change what a launcher downloads and runs")
        self.assertIsNone(lv.get_link("SPP_SHA256"))
        self.assertEqual(lv.button("discord", "JOIN"), ("JOIN", None))
        again = self.live()
        again.load_cached()
        self.assertEqual(again.status, "cached")
        self.assertEqual(again.doc, lv.doc)
        self.assertEqual(again.refresh(), "unchanged")

    def test_unsigned_bad_or_older_keeps_cache(self):
        self.web.put(*signed(self.doc, 10))
        lv = self.live()
        lv.refresh()
        kept = dict(lv.doc)
        body, sig = signed(dict(self.doc, flags={"solo": True}), 11)
        self.web.put(body, None)
        self.assertEqual(lv.refresh(), "unsigned")
        self.web.put(body, "00" * 64)
        self.assertEqual(lv.refresh(), "bad-signature")
        self.web.put(body.replace(b"true", b"false"), sig)
        self.assertEqual(lv.refresh(), "bad-signature", "a changed body fails its signature")
        self.web.put(*signed(dict(self.doc, flags={"solo": True}), 9))
        self.assertEqual(lv.refresh(), "older")
        self.assertEqual(lv.doc, kept)
        self.web.files.clear()
        self.assertEqual(lv.refresh(), "offline")
        fresh = self.live()
        fresh.load_cached()
        self.assertEqual(fresh.doc, kept)

    def test_tampered_cache_is_ignored(self):
        self.web.put(*signed(self.doc, 10))
        self.live().refresh()
        with open(self.cache, encoding="utf-8") as f:
            c = json.load(f)
        c["body"] = c["body"].replace('"solo": false', '"solo": true')
        with open(self.cache, "w", encoding="utf-8") as f:
            json.dump(c, f)
        lv = self.live()
        self.assertEqual(lv.load_cached(), {})
        self.assertTrue(lv.flag("solo"), "defaults when nothing verified")

    def test_sanitize_drops_unsafe_values(self):
        clean = LC.sanitize({"schema": 1, "serial": 1,
                             "hero": {"title": "x", "link": "javascript:alert(1)", "image": "http://x/y.png"},
                             "news": [{"title": "ok", "link": "file:///c:/x"}, {"nothing": 1}],
                             "flags": {"solo": "yes", "relay": True, "evil": True},
                             "realms": [{"name": "R", "host": "bad host;", "port": 1}, {"name": "G", "host": "g.example", "port": 3724}],
                             "links": {"SPP_URL": "ftp://x", "EXEC": "https://x"},
                             "buttons": {"discord": {"label": "D", "link": "https://discord.gg/x"}, "BAD KEY": {"label": "x"}}})
        self.assertEqual(clean["hero"], {"title": "x"})
        self.assertEqual(clean["news"], [{"title": "ok"}])
        self.assertEqual(clean["flags"], {"relay": True})
        self.assertEqual([r["host"] for r in clean["realms"]], ["g.example"])
        self.assertNotIn("links", clean)
        self.assertEqual(list(clean["buttons"]), ["discord"])
        with self.assertRaises(ValueError):
            LC.sanitize({"schema": 2})

    def test_shipped_source_builds_and_cli_signs(self):
        src = os.path.join(ROOT, "www", "downloads", "live.src.json")
        with open(src, encoding="utf-8") as f:
            body, clean, warnings = PKG.build(json.load(f), 5)
        self.assertEqual(warnings, [])
        self.assertNotIn("featured", clean)   # HOME draws no cards; empty so 1.17.0 launchers drop theirs too
        self.assertNotIn("hero", clean)
        self.assertFalse(clean["flags"]["relay"])
        out = os.path.join(self.tmp.name, "out")
        env = dict(os.environ, OPENVANILLA_MANIFEST_KEY=SEED.hex())
        r = subprocess.run([sys.executable, os.path.join(ROOT, "packaging", "live_content.py"), "--src", src,
                            "--out-dir", out, "--require-signature", "--serial", "7"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(out, "live.json"), "rb") as f:
            body = f.read()
        with open(os.path.join(out, "live.json.sig"), encoding="ascii") as f:
            sig = f.read()
        self.assertEqual(LC.verify(body, sig, PUB)["serial"], 7)
        env.pop("OPENVANILLA_MANIFEST_KEY")
        r = subprocess.run([sys.executable, os.path.join(ROOT, "packaging", "live_content.py"), "--src", src,
                            "--out-dir", out, "--require-signature", "--key-file", os.path.join(self.tmp.name, "none")],
                           env=env, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(out, "live.json.sig")), "a stale signature is removed")


if __name__ == "__main__":
    unittest.main()
