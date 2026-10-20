"""Herald's in-game LIVE list (bot/herald_streams.py): streams.json -> ".wnl livestreamers ..." over SOAP.

    python3 -m unittest tests.test_herald_streams -v
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bot"))
import herald_streams as hs  # noqa: E402

NOW = 1_800_000_000.0
UPDATED = "2027-01-15T08:00:00Z"          # == NOW


class Soap:
    def __init__(self, fail=False):
        self.calls, self.fail = [], fail

    def __call__(self, cmd):
        self.calls.append(cmd)
        if self.fail:
            raise OSError("connection refused")
        return ""


class TestNames(unittest.TestCase):
    def doc(self, rows, updated=UPDATED):
        return {"updated": updated, "ingame": rows}

    def test_valid_sorted_unique(self):
        d = self.doc([{"character": "zed"}, {"character": "Berra"}, {"character": "Berra"}, {"character": "Åsa"}])
        self.assertEqual(hs.live_names(d, NOW), ["Berra", "Zed", "Åsa"])

    def test_rejects_injection(self):
        d = self.doc([{"character": "Bob;Eve"}, {"character": "a"}, {"character": "x\n.ban"}, {"character": "Toolongname13"},
                      "Mallory", None, {"character": 5}])
        self.assertEqual(hs.live_names(d, NOW), [])

    def test_stale_or_bad_file_clears(self):
        self.assertEqual(hs.live_names(self.doc([{"character": "Berra"}], "2027-01-15T07:30:00Z"), NOW), [])
        self.assertEqual(hs.live_names(self.doc([{"character": "Berra"}], "2027-01-15T07:50:00Z"), NOW), ["Berra"])
        self.assertEqual(hs.live_names(None, NOW), [])
        self.assertEqual(hs.live_names({"ingame": [{"character": "Berra"}]}, NOW), [])

    def test_command(self):
        self.assertEqual(hs.command(["A", "Bb"]), ".wnl livestreamers A;Bb")
        self.assertEqual(hs.command([]), ".wnl livestreamers -")

    def test_cap(self):
        rows = [{"character": "N" + "abcdefghij"[i // 10] + "abcdefghij"[i % 10]} for i in range(100)]
        self.assertEqual(len(hs.live_names(self.doc(rows), NOW)), hs.MAX_NAMES)


class TestPusher(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.d.name, "streams.json")

    def tearDown(self):
        self.d.cleanup()

    def write(self, rows, updated=UPDATED):
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump({"updated": updated, "ingame": rows}, f)

    def test_pushes_every_time(self):
        soap = Soap()
        p = hs.Pusher(soap, self.path, now=lambda: NOW)
        self.write([{"character": "Berra", "platform": "twitch"}])
        self.assertEqual(p.tick(), ["Berra"])
        self.assertEqual(p.tick(), ["Berra"])
        self.write([])
        self.assertEqual(p.tick(), [])
        self.assertEqual(soap.calls, [".wnl livestreamers Berra"] * 2 + [".wnl livestreamers -"])

    def test_missing_file_and_console_down(self):
        soap = Soap(fail=True)
        p = hs.Pusher(soap, self.path, now=lambda: NOW)
        self.assertIsNone(p.tick())
        self.assertEqual(soap.calls, [".wnl livestreamers -"])
        self.assertEqual(p.errors, 1)

    def test_install_paths(self):
        live = hs.install(bot=None, soap=Soap(), path=self.path, now=lambda: NOW)
        self.assertEqual(live.pusher.path, self.path)
        self.write([{"character": "Berra"}])
        self.assertEqual(live.pusher.tick(), ["Berra"])

    def test_herald_hook_compiles_and_wires(self):
        with open(os.path.join(os.path.dirname(hs.__file__), "herald.py"), encoding="utf-8") as f:
            src = f.read()
        self.assertIn("import herald_streams", src)
        self.assertIn("livemarks.start()", src)


if __name__ == "__main__":
    unittest.main()
