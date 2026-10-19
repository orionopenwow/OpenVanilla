"""Game clients (launcher/game_clients.py + live content's `clients`): sanitizing, merging defaults, the
maintainer's live list and clients.txt, and the player's "my clients" choices. No Tk.

    python3 -m unittest tests.test_game_clients -v
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))

import game_clients as G  # noqa: E402
import live_content as LC  # noqa: E402

VANILLA = {"id": "vanilla", "name": "Vanilla (stock client)", "version": "1.12.1", "type": "exe", "exe": "WoW.exe",
           "build": 5875, "download_url": "https://archive.org/download/x/x.zip"}
PARKED = [{"id": "openvanilla", "name": "Open Vanilla Classic+", "version": "1.12.1", "type": "engine", "build": 5875,
           "download_url": "https://example.org/OpenVanilla.zip"},
          {"id": "wotlk", "name": "Wrath", "version": "3.3.5a", "type": "exe", "build": 12340, "coming_soon": True,
           "note": "Supported"}]


class SanitizeTests(unittest.TestCase):
    def test_fields_are_allow_listed(self):
        c = LC.sanitize_client({"id": "my-build", "name": "My build", "type": "ENGINE", "version": "1.0",
                                "url": "https://x.org/a.zip", "repo": "https://github.com/x/y", "description": "d",
                                "image": "https://x.org/a.png", "status": "coming_soon", "exe": "evil.exe",
                                "path": "C:/Windows"})
        self.assertEqual(c, {"id": "my-build", "name": "My build", "type": "engine", "version": "1.0",
                             "url": "https://x.org/a.zip", "page": "https://github.com/x/y", "description": "d",
                             "image": "https://x.org/a.png", "status": "coming_soon"})

    def test_rejects_and_drops(self):
        self.assertIsNone(LC.sanitize_client({"name": "x", "type": "bat"}))
        self.assertIsNone(LC.sanitize_client({"type": "exe"}))
        self.assertIsNone(LC.sanitize_client({"id": "../x", "name": "x", "type": "exe"}))
        self.assertIsNone(LC.sanitize_client("nope"))
        c = LC.sanitize_client({"name": "WotLK 3.3.5a", "type": "exe", "url": "http://insecure.example/a.zip",
                                "page": "openvanilla://page/solo", "status": "soon"})
        self.assertEqual(c["id"], "wotlk-3-3-5a")
        self.assertNotIn("url", c)
        self.assertNotIn("page", c)    # pages must be https
        self.assertEqual(c["status"], "available")

    def test_live_doc_clients(self):
        clean = LC.sanitize({"schema": 1, "clients": [{"id": "a", "name": "A", "type": "web"},
                                                      {"id": "a", "name": "dupe", "type": "web"},
                                                      {"name": "bad", "type": "x"}] + [
            {"id": f"c{i}", "name": f"C{i}", "type": "engine"} for i in range(20)]})
        self.assertEqual([c["id"] for c in clean["clients"]][:2], ["a", "c0"])
        self.assertLessEqual(len(clean["clients"]), LC.MAX["clients"])
        self.assertNotIn("clients", LC.sanitize({"schema": 1, "clients": {"not": "a list"}}))

    def test_shipped_source_has_a_documented_empty_list(self):
        with open(os.path.join(ROOT, "www", "downloads", "live.src.json"), encoding="utf-8") as f:
            src = json.load(f)
        self.assertEqual(src["clients"], [])
        self.assertIn("coming_soon", src["_clients"])
        self.assertEqual(src["hero"], {})
        self.assertEqual(src["featured"], [])


class ClientsTxtTests(unittest.TestCase):
    TXT = ("\ufeff# my clients\r\n"
           "name = My Classic+ build\r\n"
           "url = https://example.org/MyClient.zip\r\n"
           "type = engine\r\n"
           "version = 1.12.1\r\n"
           "page = https://github.com/example/my-client\r\n"
           "description = A test build = with an equals sign\r\n"
           "\r\n"
           "\r\n"
           "name = Broken\r\n"
           "type = toaster\r\n"
           "\n"
           "name = Browser\n"
           "type = web\n"
           "name = Back to back\n"
           "type = exe\n"
           "url = ftp://nope\n")

    def test_parse(self):
        got = G.parse_clients_txt(self.TXT)
        self.assertEqual([c["id"] for c in got], ["my-classic-build", "browser", "back-to-back"])
        self.assertEqual(got[0]["url"], "https://example.org/MyClient.zip")
        self.assertEqual(got[0]["page"], "https://github.com/example/my-client")
        self.assertEqual(got[0]["description"], "A test build = with an equals sign")
        self.assertEqual(got[0]["version"], "1.12.1")
        self.assertNotIn("url", got[2])

    def test_read_missing_file_and_example(self):
        self.assertEqual(G.read_clients_txt(os.path.join(tempfile.gettempdir(), "no-such-dir-x", "clients.txt")), [])
        self.assertEqual(G.parse_clients_txt(G.CLIENTS_TXT_EXAMPLE), [])   # the example is all comments
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "clients.txt")
            with open(p, "w", encoding="utf-8") as f:
                f.write("name = X\ntype = web\n")
            self.assertEqual(G.read_clients_txt(p)[0]["id"], "x")


class CatalogTests(unittest.TestCase):
    def cat(self, live=(), local=()):
        return G.catalog([VANILLA], PARKED, live, local)

    def test_sources_in_order(self):
        cat = self.cat([{"id": "live1", "name": "Live one", "type": "engine", "url": "https://x.org/l.zip",
                         "status": "available"}],
                       [{"id": "mine", "name": "Mine", "type": "web", "status": "available"}])
        self.assertEqual([e["id"] for e in cat], ["vanilla", "openvanilla", "wotlk", "live1", "mine"])
        self.assertEqual([e["source"] for e in cat], ["builtin", "parked", "parked", "live", "local"])
        self.assertFalse(cat[0]["removable"])
        self.assertTrue(all(e["removable"] for e in cat[1:]))
        self.assertEqual(cat[0]["url"], VANILLA["download_url"])
        self.assertEqual(cat[2]["status"], "coming_soon")
        self.assertEqual(cat[2]["description"], "Supported")
        self.assertEqual(cat[3]["download_url"], "https://x.org/l.zip")   # what the launcher's download flow reads

    def test_live_and_local_update_known_clients(self):
        cat = self.cat([{"id": "openvanilla", "name": "Open Vanilla Classic+", "type": "web", "version": "1.13",
                         "url": "https://x.org/new.zip", "status": "available"}],
                       [{"id": "openvanilla", "name": "Open Vanilla (my build)", "type": "engine", "status": "available"}])
        e = next(e for e in cat if e["id"] == "openvanilla")
        self.assertEqual((e["version"], e["download_url"], e["name"]), ("1.13", "https://x.org/new.zip", "Open Vanilla (my build)"))
        self.assertEqual(e["type"], "engine")       # a shipped client's type never changes
        self.assertEqual(e["sources"], ["parked", "live", "local"])

    def test_my_clients_follow_the_live_list(self):
        settings = {}
        live = [{"id": "live1", "name": "Live one", "type": "engine", "version": "1", "status": "available"}]
        self.assertEqual([c["id"] for c in G.my_clients(self.cat(live), settings.get("my_clients"))], ["vanilla"])
        G.add(settings, "live1")
        G.add(settings, "live1")
        self.assertEqual(settings["my_clients"], ["live1"])
        self.assertEqual([c["id"] for c in G.my_clients(self.cat(live), settings["my_clients"])], ["vanilla", "live1"])
        live[0]["version"] = "2"                    # the maintainer edits it: the added client follows
        self.assertEqual(G.my_clients(self.cat(live), settings["my_clients"])[1]["version"], "2")
        self.assertEqual([c["id"] for c in G.my_clients(self.cat(), settings["my_clients"])], ["vanilla"])  # removed from live

    def test_remove(self):
        settings = {"my_clients": ["openvanilla"]}
        cat = self.cat()
        self.assertFalse(G.remove(settings, cat[0]))           # Vanilla stays
        self.assertTrue(G.remove(settings, cat[1]))
        self.assertEqual(settings["my_clients"], [])


if __name__ == "__main__":
    unittest.main()
