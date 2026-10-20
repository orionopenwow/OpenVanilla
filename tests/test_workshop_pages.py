"""The Workshop web pages: HTML well-formedness and local links for every page, then the pages in a real
browser (Playwright + Chromium) against the committed www/community/workshop JSON and a fake realm
API (/api/workshop/*, patch 0013). Nothing leaves the machine: requests to other hosts are answered
here or aborted.

    python3 -m unittest tests.test_workshop_pages -v        (the browser half skips without playwright)
"""
import html.parser
import json
import os
import re
import sys
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WWW = os.path.join(ROOT, "www")
sys.path.insert(0, HERE)
from test_streams_pages import HAVE_PW, serve  # noqa: E402

if HAVE_PW:
    from playwright.sync_api import sync_playwright

PAGES = ["workshop.html", "workshop/addon.html", "workshop/creator.html", "workshop/collection.html"]
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class Checker(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors, self.refs, self.ids = [], [], [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.append(a["id"])
        for k in ("href", "src"):
            if a.get(k):
                self.refs.append(a[k])
        if tag not in VOID:
            self.stack.append((tag, self.getpos()))

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack or self.stack[-1][0] != tag:
            self.errors.append(f"</{tag}> at {self.getpos()} does not close {self.stack[-1] if self.stack else 'anything'}")
            return
        self.stack.pop()


class HtmlTests(unittest.TestCase):
    def test_pages_parse_and_links_resolve(self):
        for page in PAGES:
            with open(os.path.join(WWW, page), encoding="utf-8") as f:
                src = f.read()
            c = Checker()
            c.feed(src)
            c.close()
            self.assertEqual(c.errors, [], page)
            self.assertEqual(c.stack, [], f"{page}: unclosed {c.stack}")
            self.assertEqual(len(c.ids), len(set(c.ids)), f"{page}: duplicate ids")
            self.assertIn("<title>", src)
            self.assertIn('name="viewport"', src)
            for ref in c.refs:
                if re.match(r"^(https?:|mailto:|#|openvanilla:)", ref) or "{" in ref:
                    continue
                path = urllib.parse.urlsplit(ref).path
                target = os.path.normpath(os.path.join(WWW, os.path.dirname(page), path))
                self.assertTrue(os.path.exists(target), f"{page}: broken link {ref}")

    def test_footer_link_on_index_and_portal(self):
        with open(os.path.join(WWW, "index.html"), encoding="utf-8") as f:
            index = f.read()
        with open(os.path.join(WWW, "portal.html"), encoding="utf-8") as f:
            portal = f.read()
        self.assertEqual(index, portal, "index.html and portal.html stay identical")
        self.assertEqual(index.count('href="workshop.html"'), 1)

    def test_assets_exist(self):
        for name in ("hero_workshop.webp", "badge_works.webp", "badge_partly.webp", "badge_needs.webp", "badge_ours.webp",
                     "badge_unknown.webp", "star_full.png", "star_half.png", "star_empty.png", "creator_banner.webp",
                     "collection_raiders.webp", "collection_roleplay.webp", "og_workshop.jpg"):
            self.assertTrue(os.path.isfile(os.path.join(WWW, "assets", "workshop", name)), name)
        with open(os.path.join(WWW, "community", "workshop", "index.json"), encoding="utf-8") as f:
            idx = json.load(f)
        for c in idx["categories"]:
            self.assertTrue(os.path.isfile(os.path.join(WWW, c["banner"])), c["banner"])


class FakeRealm:
    """/api/workshop/* answered in the browser's network layer."""

    def __init__(self, signed_in=False, online=True):
        self.signed_in, self.online = signed_in, online
        self.posts = []

    def handle(self, route):
        req = route.request
        if not self.online:
            return route.abort()
        path = urllib.parse.urlsplit(req.url).path.replace("/api/workshop/", "")
        # What the realm's CORS layer sends: the caller's origin, with credentials (never "*").
        hdr = {"access-control-allow-origin": req.headers.get("origin", ""), "access-control-allow-credentials": "true",
               "access-control-allow-headers": "content-type, x-csrf-token", "access-control-allow-methods": "GET, POST, DELETE",
               "content-type": "application/json", "vary": "Origin"}

        def ok(obj, status=200):
            route.fulfill(status=status, headers=hdr, body=json.dumps(obj))
        if req.method == "OPTIONS":
            return route.fulfill(status=204, headers=hdr, body="")
        if path == "stats":
            return ok({"addons": {"bigwigs": {"rating": 4.8, "votes": 40, "installs": 900},
                                  "pfui": {"rating": 4.2, "votes": 12, "installs": 5000}}})
        if path == "me":
            if not self.signed_in:
                return ok({"error": "no"}, 401)
            return ok({"user": "Tester", "csrf": "tok123", "moderator": False, "ratings": {}})
        if path.startswith("reviews/"):
            return ok({"addon": path[8:], "rating": 4.5, "votes": 2, "histogram": [0, 0, 0, 1, 1], "page": 0, "per_page": 20,
                       "reviews": [{"user": "Berra", "user_id": 1, "stars": 5, "text": "<img src=x onerror=alert(1)> Great!",
                                    "hidden": False, "created_at": 1760000000, "updated_at": 1760000000},
                                   {"user": "Rude", "user_id": 2, "stars": 4, "text": "", "hidden": True,
                                    "created_at": 1760000000, "updated_at": 1760000000}]})
        if path.startswith("installs/"):
            return ok({"addon": path[9:], "installs": 1234})
        if path == "collections":
            return ok({"collections": [{"id": "u7", "n": 7, "curator": "Berra", "name": "Berra's healer kit", "summary": "Heals.",
                                        "addons": ["healersmate", "decursive"], "updated": 1760000000}]})
        if path == "collections/u7":
            return ok({"id": "u7", "n": 7, "curator": "Berra", "name": "Berra's healer kit", "summary": "Heals.",
                       "addons": ["healersmate", "decursive"], "updated": 1760000000})
        if path == "rate" and req.method == "POST":
            self.posts.append(("rate", req.headers.get("x-csrf-token"), json.loads(req.post_data)))
            return ok({"ok": True, "rating": 4.0, "votes": 3})
        return ok({"error": "not found"}, 404)


@unittest.skipUnless(HAVE_PW, "playwright is not installed")
class WorkshopPages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv, cls.base = serve(WWW)
        with open(os.path.join(WWW, "community", "workshop", "index.json"), encoding="utf-8") as f:
            cls.index = json.load(f)
        cls.pw = sync_playwright().start()
        try:
            cls.browser = cls.pw.chromium.launch()
        except Exception as e:  # noqa: BLE001
            cls.pw.stop()
            cls.srv.shutdown()
            raise unittest.SkipTest(f"no Chromium for Playwright: {e}")

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()
        cls.srv.shutdown()
        cls.srv.server_close()

    def page(self, path, realm=None, width=1280):
        realm = realm or FakeRealm()
        ctx = self.browser.new_context(viewport={"width": width, "height": 900})
        self.addCleanup(ctx.close)
        p = ctx.new_page()
        self.errors = []
        p.on("pageerror", lambda e: self.errors.append(str(e)))
        p.on("dialog", lambda d: (self.errors.append("dialog " + d.message), d.dismiss()))

        def route(r):
            u = r.request.url
            if u.startswith("http://127.0.0.1"):
                return r.continue_()
            if u.startswith("https://play.openvanilla.app/api/workshop/"):
                return realm.handle(r)
            return r.abort()
        ctx.route("**/*", route)
        p.goto(self.base + path)
        p.wait_for_timeout(500)
        return p

    def no_hscroll(self, p):
        self.assertLessEqual(p.evaluate("document.documentElement.scrollWidth"), p.evaluate("innerWidth"))

    def test_listing_search_filters_sort(self):
        p = self.page("workshop.html")
        n = self.index["count"]
        self.assertEqual(p.locator("#grid .card").count(), n)
        self.assertIn(f"All addons ({n})", p.inner_text("#listTitle"))
        # live stats: top rated (several votes) first, and installs sort
        self.assertEqual(p.locator("#grid .card .name").first.inner_text(), "BigWigs")
        p.select_option("#sort", "installs")
        self.assertEqual(p.locator("#grid .card .name").first.inner_text(), "pfUI")
        p.fill("#q", "pfquest")
        p.wait_for_timeout(100)
        names = p.locator("#grid .card .name").all_inner_texts()
        self.assertTrue({"pfQuest", "pfQuest Icons", "pfQuest (Turtle data)"} <= set(names), names)
        self.assertNotIn("pfUI", names)
        self.assertIn("q=pfquest", p.url)
        p.fill("#q", "zzzz-no-such")
        p.wait_for_timeout(100)
        self.assertTrue(p.is_visible("#empty"))
        p.fill("#q", "")
        p.click('.filters button[data-f="ours"]')
        ours = [c for c in self.index["addons"] if c["ours"]]
        self.assertEqual(p.locator("#grid .card").count(), len(ours))
        self.assertEqual(p.locator("#grid .card .badge.ours").count(), len(ours))
        p.click('.filters button[data-f="all"]')
        p.click('.cat[data-cat="raid"]')
        raid = [c for c in self.index["addons"] if c["category"] == "raid"]
        self.assertEqual(p.locator("#grid .card").count(), len(raid))
        self.assertEqual(p.get_attribute('.cat[data-cat="raid"]', "aria-pressed"), "true")
        first = p.locator("#grid .card").first.get_attribute("href")
        self.assertTrue(first.startswith("workshop/addon.html?id="), first)
        # collections: the two seeded packs + a player's from the realm
        cols = p.locator("#cols .col b").all_inner_texts()
        self.assertEqual(cols[:2], ["Raider's pack", "Roleplay pack"])
        self.assertIn("Berra's healer kit", cols)
        # signed out: upload asks to sign in on the realm
        self.assertIn("Sign in on the realm to upload", p.inner_text("#uploadBox"))
        self.assertEqual(self.errors, [])

    def test_listing_offline_is_read_only(self):
        p = self.page("workshop.html", FakeRealm(online=False))
        self.assertEqual(p.locator("#grid .card").count(), self.index["count"])
        self.assertIn("read-only", p.inner_text("#status"))
        self.assertIn("cannot be reached", p.inner_text("#uploadBox"))
        self.assertEqual(self.errors, [])

    def test_hosted_addon_page_rating_and_reviews(self):
        realm = FakeRealm(signed_in=True)
        p = self.page("workshop/addon.html?id=pfui", realm)
        self.assertEqual(p.title(), "pfUI · Open Vanilla Workshop")
        self.assertEqual(p.get_attribute("#install", "href"), "openvanilla://workshop/install/pfui")
        self.assertIn("Licence:  MIT", p.inner_text("#credits"))
        self.assertIn("1.2k installs", p.inner_text("#get"))
        self.assertIn("SHA-256", p.inner_text("#versions"))
        self.assertIn("<img src=x onerror=alert(1)> Great!", p.inner_text("#reviewList"), "review text is text, never HTML")
        self.assertEqual(p.locator("#reviewList img[src=x]").count(), 0)
        self.assertIn("Hidden by a moderator", p.inner_text("#reviewList"))
        self.assertEqual(p.inner_text("#avg"), "4.5")
        p.click('#pick button[data-s="4"]')
        p.fill("#rt", "Works with the Classic+ bags.")
        p.click("#rf button[type=submit]")
        p.wait_for_timeout(300)
        self.assertEqual(realm.posts, [("rate", "tok123", {"addon": "pfui", "stars": 4, "review": "Works with the Classic+ bags."})])
        self.assertIn("saved", p.inner_text("#rm"))
        self.assertEqual(self.errors, [])

    def test_link_out_addon_page(self):
        lo = next(c for c in self.index["addons"] if not c["install"] and not c["ours"])
        p = self.page("workshop/addon.html?id=" + lo["id"])
        txt = p.inner_text("#get")
        self.assertIn("Get it from the author", txt)
        self.assertEqual(p.locator('#get a[href^="openvanilla://"]').count(), 0, "never an install link for a link-out")
        self.assertIn("Linked, not hosted", p.inner_text("#licNote"))
        self.assertIn("Sign in on the realm", p.inner_text("#rateBox"))
        self.assertEqual(self.errors, [])

    def test_addon_page_offline_and_missing(self):
        p = self.page("workshop/addon.html?id=pfui", FakeRealm(online=False))
        self.assertIn("read-only", p.inner_text("#reviewList"))
        self.assertEqual(p.get_attribute("#install", "href"), "openvanilla://workshop/install/pfui")
        p = self.page("workshop/addon.html?id=no-such-addon")
        self.assertEqual(p.inner_text("#name"), "Addon not found")
        self.assertEqual(self.errors, [])

    def test_creator_and_collections(self):
        p = self.page("workshop/creator.html?u=shagu")
        self.assertEqual(p.inner_text("#name"), "Shagu")
        names = p.locator("#grid .card .name").all_inner_texts()
        self.assertIn("pfUI", names)
        self.assertTrue(all(c["creator"] == "shagu" for c in self.index["addons"] if c["name"] in names))
        self.assertIn("github.com/shagu", p.inner_text("#links"))
        p = self.page("workshop/collection.html?id=raiders-pack")
        self.assertEqual(p.inner_text("#name"), "Raider's pack")
        href = p.get_attribute("#act a", "href")
        self.assertTrue(href.startswith("openvanilla://workshop/install/") and "cp-raid" in href, href)
        col = next(c for c in self.index["collections"] if c["id"] == "raiders-pack")
        hosted = {c["id"] for c in self.index["addons"] if c["install"]}
        self.assertEqual(set(href.rsplit("/", 1)[1].split(",")), set(col["addons"]) & hosted, "install-all only hosts what it may")
        self.assertEqual(p.locator("#grid .card").count(), len(col["addons"]))
        p = self.page("workshop/collection.html?id=u7")
        self.assertEqual(p.inner_text("#name"), "Berra's healer kit")
        self.assertEqual(p.locator("#grid .card").count(), 2)
        self.assertEqual(self.errors, [])

    def test_phone_width(self):
        for path in ("workshop.html", "workshop/addon.html?id=pfui", "workshop/collection.html?id=roleplay-pack",
                     "workshop/creator.html?u=shagu"):
            p = self.page(path, width=390)
            self.no_hscroll(p)
        self.assertEqual(self.errors, [])


if __name__ == "__main__":
    unittest.main()
