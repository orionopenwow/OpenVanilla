"""The streams & creators web pages in a real browser (Playwright + Chromium), against the canned
www/community/streams.mock.json: streamers.html, creators.html, the "Live now" strip on index.html /
portal.html, and the realm's link page (realm/www/creator-link.html) with a fake /api/creator/link.
Nothing leaves the machine: every request to another host is answered here or aborted.

    python3 -m unittest tests.test_streams_pages -v        (skips without playwright/chromium)
"""
import functools
import http.server
import json
import os
import threading
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WWW = os.path.join(ROOT, "www")
REALM_WWW = os.path.join(ROOT, "realm", "www")

try:
    from playwright.sync_api import sync_playwright
    HAVE_PW = True
except ImportError:
    HAVE_PW = False


def serve(directory):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=directory))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}/"


@unittest.skipUnless(HAVE_PW, "playwright is not installed")
class StreamsPages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv, cls.base = serve(WWW)
        cls.rsrv, cls.rbase = serve(REALM_WWW)
        with open(os.path.join(WWW, "community", "streams.mock.json"), encoding="utf-8") as f:
            cls.mock = json.load(f)
        cls.pw = sync_playwright().start()
        try:
            cls.browser = cls.pw.chromium.launch()
        except Exception as e:  # noqa: BLE001 - no browser installed
            cls.pw.stop()
            cls.srv.shutdown()
            cls.rsrv.shutdown()
            raise unittest.SkipTest(f"no Chromium for Playwright: {e}")

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()
        cls.srv.shutdown()
        cls.rsrv.shutdown()
        cls.srv.server_close()
        cls.rsrv.server_close()

    def page(self, doc=None, extra_routes=None):
        """A page whose remote streams.json is `doc` (default: the mock); other hosts aborted."""
        ctx = self.browser.new_context()
        self.addCleanup(ctx.close)
        p = ctx.new_page()
        errors = []
        p.on("pageerror", lambda e: errors.append(str(e)))
        body = json.dumps(self.mock if doc is None else doc)
        seen = []

        def route(r):
            url = r.request.url
            seen.append(url)
            for prefix, handler in (extra_routes or {}).items():
                if url.startswith(prefix):
                    return handler(r)
            if url.startswith(("http://127.0.0.1", "http://localhost")):
                return r.continue_()
            if url == "https://play.openvanilla.app/community/streams.json":
                return r.fulfill(status=200, content_type="application/json", body=body,
                                 headers={"Access-Control-Allow-Origin": "*"})
            return r.abort()
        ctx.route("**/*", route)
        return p, errors, seen

    def test_streamers_page(self):
        p, errors, seen = self.page()
        p.goto(self.base + "streamers.html")
        p.wait_for_selector("#live .sc-card")
        self.assertEqual(p.locator("#live .sc-card").count(), len(self.mock["live"]))
        self.assertEqual(p.locator("#scheduled .row").count(), len(self.mock["scheduled"]))
        self.assertRegex(p.locator("#status").inner_text(), r"^(Updated|Last update) ")
        twitch = sum(1 for s in self.mock["live"] if s["platform"] == "twitch")
        self.assertEqual(p.locator('.tab[data-k="twitch"] .n').inner_text(), str(twitch))
        p.click('.tab[data-k="twitch"]')
        self.assertEqual(p.locator("#live .sc-card").count(), twitch)
        p.click('.tab[data-k="tiktok"]')
        self.assertEqual(p.locator("#live .empty").count(), 1)
        p.click('.tab[data-k="all"]')
        # no player until a click; then the official Twitch embed with this host as parent
        self.assertEqual(p.locator("iframe").count(), 0)
        self.assertFalse(any("player.twitch.tv" in u for u in seen))
        p.locator('#live .sc-card[data-platform="twitch"] .sc-media').first.click()
        src = p.locator("#live iframe").first.get_attribute("src")
        self.assertTrue(src.startswith("https://player.twitch.tv/?channel=berraplays&parent=127.0.0.1"), src)
        self.assertEqual(errors, [])

    def test_streamers_page_empty(self):
        p, errors, _ = self.page({"updated": "", "live": []})
        p.goto(self.base + "streamers.html")
        p.wait_for_selector("#live .empty")
        self.assertIn("Nobody is live", p.locator("#live").inner_text())
        self.assertIn("Waiting for the first update", p.locator("#status").inner_text())
        self.assertEqual(errors, [])

    def test_creators_page(self):
        p, errors, _ = self.page()
        p.goto(self.base + "creators.html")
        p.wait_for_selector("#videos .sc-card")
        longs = [v for v in self.mock["videos"] if v["kind"] != "short"]
        shorts = [v for v in self.mock["videos"] if v["kind"] == "short"]
        self.assertEqual(p.locator("#videos .sc-card").count(), len(longs))
        self.assertEqual(p.locator("#shorts .sc-card").count(), len(shorts))
        p.select_option("#f-class", "warlock")
        self.assertEqual(p.locator("#videos .sc-card").count(), 1)
        p.select_option("#f-class", "mage")
        self.assertIn("No videos match", p.locator("#videos").inner_text())
        p.select_option("#f-class", "")
        p.select_option("#f-kind", "short")
        self.assertEqual(p.locator("#shorts .sc-card").count(), len(shorts))
        self.assertEqual(p.locator(".cr").count(), len(self.mock["creators"]))
        self.assertEqual(p.locator("#lb tr").count(), len(self.mock["leaderboard"]["rows"]))
        self.assertEqual(p.locator('#lb img[src$="crown_1.png"]').count(), 1)
        self.assertTrue(p.locator("#lb-month").inner_text().strip())
        # creator links only to the platforms' own hosts
        for href in p.locator(".cr .links a").evaluate_all("els => els.map(e => e.href)"):
            self.assertRegex(href, r"^https://(www\.)?(twitch\.tv|youtube\.com|tiktok\.com|kick\.com)/")
        self.assertEqual(errors, [])

    def test_hostile_data_is_not_html(self):
        evil = json.loads(json.dumps(self.mock))
        evil["live"][0]["title"] = '<img src=x onerror="window.pwned=1">'
        evil["live"][0]["thumbnail"] = "javascript:alert(1)"
        evil["live"][0]["url"] = "https://evil.example/phish"
        evil["creators"][0]["links"] = {"twitch": "javascript:alert(1)"}
        p, errors, _ = self.page(evil)
        p.goto(self.base + "streamers.html")
        p.wait_for_selector("#live .sc-card")
        self.assertIsNone(p.evaluate("window.pwned"))
        first = p.locator("#live .sc-card").first
        self.assertEqual(first.locator("a").count(), 0)           # the off-platform URL is not a link
        self.assertEqual(first.locator(".sc-media img").count(), 1)  # only the platform seal, no thumbnail
        p.goto(self.base + "creators.html")
        p.wait_for_selector(".cr")
        self.assertEqual(p.locator('.cr a[href^="javascript"]').count(), 0)
        self.assertEqual(errors, [])

    def test_live_strip_on_index_and_portal(self):
        for name in ("index.html", "portal.html"):
            p, _, _ = self.page()
            p.goto(self.base + name)
            p.wait_for_selector("#owStreamsLive:not([hidden]) .owl-card")
            self.assertEqual(p.locator("#owStreamsGrid .owl-card").count(), min(4, len(self.mock["live"])))
            self.assertIn("3 streams", p.locator("#owStreamsN").inner_text())
            p.locator("#owStreamsGrid .owl-media").first.click()
            self.assertTrue(p.locator("#owStreamsGrid iframe").first.get_attribute("src").startswith("https://player.twitch.tv/"))
        p, _, _ = self.page({"updated": "", "live": []})
        p.goto(self.base + "index.html")
        p.wait_for_timeout(800)
        self.assertTrue(p.locator("#owStreamsLive").is_hidden(), "hidden when nobody is live")

    def test_realm_link_page(self):
        links = []
        posts = []

        def api(r):
            req = r.request
            if req.method == "GET":
                return r.fulfill(status=200, content_type="application/json",
                                 body=json.dumps({"user": "Alice", "code": "OW-7K2Q9M", "links": links, "csrf": "tok123"}))
            posts.append((req.method, req.headers.get("x-csrf-token"), req.post_data))
            if req.method == "POST":
                b = json.loads(req.post_data)
                if b["handle"] == "taken":
                    return r.fulfill(status=409, content_type="application/json", body=json.dumps({"error": "that channel is already linked to another account"}))
                links[:] = [l for l in links if l["platform"] != b["platform"]] + [{"platform": b["platform"], "handle": b["handle"].lower(), "character": b["character"], "show_live": b["show_live"], "code": "OW-7K2Q9M"}]
            return r.fulfill(status=200, content_type="application/json", body=json.dumps({"ok": True, "links": links}))

        def community(r):
            return r.fulfill(status=200, content_type="application/json",
                             body=json.dumps({"creators": [{"links": {"twitch": "https://www.twitch.tv/aliceplays"}}]}))
        p, errors, _ = self.page(extra_routes={self.rbase + "api/creator/link": api, self.rbase + "community/": community})
        p.goto(self.rbase + "creator-link.html")
        p.wait_for_function("document.getElementById('code').textContent === 'OW-7K2Q9M'")
        self.assertIn("No channels linked yet", p.locator("#links").inner_text())
        p.fill("#handle", "AlicePlays")
        p.click("#add button[type=submit]")
        p.wait_for_selector("#links li a.h")
        self.assertEqual(posts[0][1], "tok123")
        self.assertIn("listed", p.locator("#links").inner_text())
        p.select_option("#platform", "youtube")
        p.fill("#handle", "taken")
        p.click("#add button[type=submit]")
        p.wait_for_function("document.getElementById('msg').textContent.includes('already linked')")
        p.check("#show_live")
        p.fill("#character", "Alicia")
        p.click("#live button[type=submit]")
        p.wait_for_function("document.getElementById('msg').textContent.includes('Social setting')")
        last = json.loads(posts[-1][2])
        self.assertEqual((last["character"], last["show_live"]), ("Alicia", True))
        p.click("#links li button")
        p.wait_for_function("document.getElementById('msg').textContent === 'Unlinked.'")
        self.assertEqual(posts[-1][:2], ("DELETE", "tok123"))
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
