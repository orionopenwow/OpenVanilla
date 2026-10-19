"""The launcher's "Share what I'm listening to" (launcher/nowplaying.py): formatting, the Persona
SavedVariables shim (checked with a real Lua), the Spotify Web API reader with a fake HTTP, and the
worker's on/off behaviour. No network, no Windows needed.

    python3 -m unittest tests.test_nowplaying -v
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "launcher"))
import nowplaying as np  # noqa: E402


class FakeHttp:
    def __init__(self, answers):
        self.answers = answers          # list of (status, json) or exceptions, popped in order
        self.calls = []

    def call(self, method, url, headers=None, data=None, timeout=10):
        self.calls.append((method, url, headers or {}, data))
        a = self.answers.pop(0)
        if isinstance(a, Exception):
            raise a
        return a


PLAYING = (200, {"is_playing": True, "item": {"name": "Bloodborne", "artists": [{"name": "Ryan Amon"}],
                                               "external_urls": {"spotify": "https://open.spotify.com/track/1"}}})


class TestFormat(unittest.TestCase):
    def test_text(self):
        self.assertEqual(np.format_text("Song", "Band"), "Song - Band")
        self.assertEqual(np.format_text("Song", ""), "Song")
        self.assertEqual(np.format_text("A|cffff0000red|r\n", "B"), "A cffff0000red r - B")
        long = np.format_text("x" * 100, "y")
        self.assertEqual(len(long), 80)
        self.assertTrue(long.endswith("..."))

    @unittest.skipUnless(shutil.which("lua5.1"), "lua5.1 not installed")
    def test_shim_is_valid_lua_with_the_value(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "Persona.lua")
            np.write_atomic(p, np.shim_body('Say "hi" \\ Ünïcode - Bänd', 1760000000))
            out = subprocess.run(["lua5.1", "-e", f"dofile([[{p}]]) print(Persona_NowPlaying.text) print(Persona_NowPlaying.at)"],
                                 capture_output=True, text=True, check=True).stdout.splitlines()
            self.assertEqual(out, ['Say "hi" \\ Ünïcode - Bänd', "1760000000"])
            np.write_atomic(p, np.shim_body("", 1))
            out = subprocess.run(["lua5.1", "-e", f"dofile([[{p}]]) print(Persona_NowPlaying.text == nil)"],
                                 capture_output=True, text=True, check=True).stdout.strip()
            self.assertEqual(out, "true")


class TestShimPaths(unittest.TestCase):
    def test_only_existing_character_folders(self):
        with tempfile.TemporaryDirectory() as d:
            eng = os.path.join(d, "benilla-config")
            os.makedirs(os.path.join(eng, "saved", "Vanilla_Reloaded-Berra"))
            os.makedirs(os.path.join(eng, "saved", "account"))           # account scope: not a character
            wow = os.path.join(d, "WoW")
            os.makedirs(os.path.join(wow, "WTF", "Account", "WR000001", "SavedVariables"))
            os.makedirs(os.path.join(wow, "WTF", "Account", "WR000001", "Vanilla Reloaded", "Orlen", "SavedVariables"))
            got = np.shim_paths([eng], [wow, os.path.join(d, "missing")])
            self.assertEqual([os.path.relpath(p, d) for p in got], [
                os.path.join("benilla-config", "saved", "Vanilla_Reloaded-Berra", "Persona.lua"),
                os.path.join("WoW", "WTF", "Account", "WR000001", "Vanilla Reloaded", "Orlen", "SavedVariables", "Persona.lua")])


class TestSpotify(unittest.TestCase):
    SP = {"client": "cid", "access": "tok", "refresh": "ref", "expires": 2000}

    def test_playing(self):
        got, sp = np.read_spotify(dict(self.SP), FakeHttp([PLAYING]), now=1000)
        self.assertEqual(got, {"title": "Bloodborne", "artist": "Ryan Amon", "link": "https://open.spotify.com/track/1"})
        self.assertEqual(sp["access"], "tok")

    def test_nothing_playing(self):
        got, _ = np.read_spotify(dict(self.SP), FakeHttp([(204, None)]), now=1000)
        self.assertEqual(got["title"], "")

    def test_refresh_then_read(self):
        http = FakeHttp([(200, {"access_token": "new", "expires_in": 3600}), PLAYING])
        got, sp = np.read_spotify(dict(self.SP), http, now=5000)
        self.assertEqual(sp["access"], "new")
        self.assertEqual(sp["refresh"], "ref")            # Spotify may not send a new one
        self.assertEqual(http.calls[0][3]["grant_type"], "refresh_token")
        self.assertEqual(http.calls[1][2]["Authorization"], "Bearer new")
        self.assertEqual(got["artist"], "Ryan Amon")

    def test_revoked_unlinks(self):
        err = urllib.error.HTTPError("u", 400, "bad", {}, None)
        got, sp = np.read_spotify(dict(self.SP), FakeHttp([err]), now=5000)
        self.assertIsNone(got)
        self.assertIsNone(sp)

    def test_pkce(self):
        v, c = np.pkce_pair()
        self.assertGreaterEqual(len(v), 43)
        self.assertNotIn("=", c)
        url = np.spotify_authorize_url("cid", c, "st")
        self.assertIn("scope=user-read-currently-playing", url)
        self.assertIn("code_challenge_method=S256", url)
        self.assertIn("redirect_uri=http%3A%2F%2F127.0.0.1%3A43129%2Fcallback", url)


class TestWorker(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        self.json = os.path.join(d, "launcher", "nowplaying.json")
        self.char = os.path.join(d, "benilla-config", "saved", "Realm-Berra")
        os.makedirs(self.char)
        self.settings = {}
        self.saved = 0
        self.playing = None
        self.now = 1_760_000_005

    def tearDown(self):
        self.dir.cleanup()

    def worker(self, http=None):
        def save():
            self.saved += 1
        return np.NowPlaying(self.json, lambda: ([os.path.join(self.dir.name, "benilla-config")], []),
                             lambda: self.settings, save, http=http, windows_reader=lambda: self.playing,
                             clock=lambda: self.now)

    def doc(self):
        with open(self.json, encoding="utf-8") as f:
            return json.load(f)

    def shim(self):
        with open(os.path.join(self.char, "Persona.lua"), encoding="utf-8") as f:
            return f.read()

    def test_off_by_default_touches_nothing(self):
        w = self.worker()
        self.playing = {"title": "Secret", "artist": "Song"}
        self.assertEqual(w.tick(), "")
        self.assertFalse(os.path.exists(self.json))
        self.assertFalse(os.path.exists(os.path.join(self.char, "Persona.lua")))

    def test_on_then_off(self):
        w = self.worker()
        self.settings["share_listening"] = True
        self.playing = {"title": "Tavern Song", "artist": "Unknown Bard"}
        self.assertEqual(w.tick(), "Tavern Song - Unknown Bard")
        doc = self.doc()
        self.assertEqual((doc["title"], doc["artist"], doc["source"], doc["at"]), ("Tavern Song", "Unknown Bard", "windows", self.now))
        self.assertEqual(set(doc), {"title", "artist", "link", "at", "source"})
        self.assertIn('"Tavern Song - Unknown Bard"', self.shim())
        self.settings["share_listening"] = False
        self.assertEqual(w.tick(), "")
        self.assertEqual(self.doc()["title"], "")
        self.assertNotIn("text", self.shim())
        # a new launcher after an earlier shared session clears what was left behind
        self.settings["share_listening"] = True
        w.tick()
        self.settings["share_listening"] = False
        w2 = self.worker()
        w2.tick()
        self.assertNotIn("text", self.shim())

    def test_spotify_when_windows_has_nothing(self):
        self.settings.update(share_listening=True, spotify={"client": "cid", "access": "old", "refresh": "r", "expires": 0})
        http = FakeHttp([(200, {"access_token": "fresh", "expires_in": 3600}), PLAYING])
        w = self.worker(http)
        self.assertEqual(w.tick(), "Bloodborne - Ryan Amon")
        self.assertEqual(self.settings["spotify"]["access"], "fresh")
        self.assertEqual(self.saved, 1)
        self.assertEqual(self.doc()["link"], "https://open.spotify.com/track/1")


if __name__ == "__main__":
    unittest.main()
