"""The armory pages in a real browser (Playwright + Chromium) against the exporter's own output for the
fixture realm (tests/armory_fixture.py): www/armory.html, www/armory/character.html, and the guild
pages (www/guilds.html, www/guild.html) reading the guild files the exporter wrote. Nothing leaves the
machine: requests to other hosts are aborted (icons fall back to the lettered slot).

    python3 -m unittest tests.test_armory_pages -v        (skips without playwright/chromium)
"""
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import armory_export as AE  # noqa: E402
import armory_fixture as F  # noqa: E402
from test_streams_pages import HAVE_PW, serve  # noqa: E402

if HAVE_PW:
    from playwright.sync_api import sync_playwright


@unittest.skipUnless(HAVE_PW, "playwright is not installed")
class ArmoryPages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="armory-site-")
        site = cls.site = os.path.join(cls.tmp, "www")
        os.makedirs(os.path.join(site, "armory"))
        for f in ("armory.html", "guilds.html", "guild.html", "favicon.ico"):
            shutil.copy(os.path.join(ROOT, "www", f), site)
        shutil.copy(os.path.join(ROOT, "www", "armory", "character.html"), os.path.join(site, "armory"))
        for d in ("armory", "guilds"):
            shutil.copytree(os.path.join(ROOT, "www", "assets", d), os.path.join(site, "assets", d))
        conn = F.sqlite_db()
        AE.Exporter(AE.SqliteDb(conn), os.path.join(site, "armory"), realm="classicplus", realm_name="Open Vanilla Classic+",
                    now=F.NOW, game=AE.GameData(F.make_dbcs(os.path.join(cls.tmp, "dbc")))).run()
        conn.close()
        cls.srv, cls.base = serve(site)
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
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def page(self, path, width=1280):
        ctx = self.browser.new_context(viewport={"width": width, "height": 900})
        self.addCleanup(ctx.close)
        p = ctx.new_page()
        self.errors = []
        p.on("pageerror", lambda e: self.errors.append(str(e)))
        p.on("dialog", lambda d: (self.errors.append("dialog " + d.message), d.dismiss()))
        ctx.route("**/*", lambda r: r.continue_() if r.request.url.startswith("http://127.0.0.1") else r.abort())
        p.goto(self.base + path)
        p.wait_for_timeout(400)
        return p

    def no_hscroll(self, p):
        self.assertLessEqual(p.evaluate("document.documentElement.scrollWidth"), p.evaluate("innerWidth"))

    def test_armory_search_rankings_firsts(self):
        p = self.page("armory.html")
        cards = p.locator(".char .n").all_inner_texts()
        self.assertEqual(cards, ["Aldric", "Eira", "Grom", "Dara"], "public only, highest level first")
        self.assertIn("Open Vanilla Classic+", p.locator("#realm").inner_text())
        p.fill("#q", "ashen")
        p.wait_for_timeout(100)
        self.assertEqual(p.locator(".char .n").all_inner_texts(), ["Aldric"])
        self.assertEqual(p.locator(".char").first.get_attribute("href"), "armory/character.html?r=classicplus&n=Aldric")
        p.fill("#q", "corvin")
        p.wait_for_timeout(100)
        self.assertIn("Nobody by that name", p.inner_text("#view"))
        p.click("#t-points")
        rows = p.locator("#view tbody tr").all_inner_texts()
        self.assertTrue(rows[0].startswith("1\tEira"))
        p.click("#t-profs")
        self.assertIn("Blacksmithing", p.locator("#view select").inner_text())
        p.click("#t-firsts")
        txt = p.inner_text("#view")
        self.assertIn("a private player", txt)
        self.assertNotIn("Corvin", txt)
        self.assertIn('href="guilds.html"', p.content())
        self.assertEqual(self.errors, [])

    def test_armory_phone_width(self):
        p = self.page("armory.html", 390)
        self.no_hscroll(p)
        p.click("#t-level")
        self.no_hscroll(p)

    def test_character_paper_doll_and_tooltips(self):
        p = self.page("armory/character.html?r=classicplus&n=Aldric")
        self.assertEqual(p.title(), "Aldric · Open Vanilla Armory")
        self.assertEqual(p.locator(".slot:not(.empty)").count(), 4)
        head = p.locator('.slot[aria-label^="Head:"]')
        head.hover()
        tip = p.inner_text("#tip")
        for s in ("Helm of Valor", "528 Armor", "+15 Stamina", "+10 Stamina", "Equip: Increased Defense",
                  "Battlegear of Valor (2/4)", "Requires Level 53"):
            self.assertIn(s, tip)
        ring = p.locator('.slot[aria-label^="Finger:"]').first
        ring.hover()
        self.assertIn("<script>alert(1)</script>", p.inner_text("#tip"), "item names are text, never HTML")
        self.assertEqual(p.locator("#tip script").count(), 0)
        txt = p.inner_text("main")
        for s in ("Arms (4/2/0) · active", "Fury (1/5/0)", "Blacksmithing", "Stormwind", "Honored", "Molten Core", "50 pts"):
            self.assertIn(s, txt)
        p.click("text=Fury (1/5/0)")
        self.assertEqual(p.locator(".tree h3 b").all_inner_texts(), ["1", "5", "0"])
        # guild link to the guild page, and back from its roster
        p.click("text=<Ashen Vanguard>")
        p.wait_for_timeout(400)
        self.assertIn("guild.html?r=classicplus&g=ashen-vanguard", p.url)
        self.assertIn("<Ashen Vanguard>", p.inner_text("h1"))
        self.assertIn("(limited)", p.inner_text("table"))
        self.assertNotIn("Corvin", p.inner_text("main"))
        p.click("table >> text=Aldric")
        p.wait_for_timeout(400)
        self.assertIn("armory/character.html?r=classicplus&n=Aldric", p.url)
        self.assertEqual(self.errors, [])

    def test_character_phone_width(self):
        p = self.page("armory/character.html?r=classicplus&n=Aldric", 390)
        self.no_hscroll(p)

    def test_friends_only_links_and_aliases(self):
        p = self.page("armory/character.html?r=classicplus&n=Berra")
        self.assertIn("Not in the armory", p.inner_text("main"))
        p = self.page(f"armory/character.html?r=classicplus&n=Berra&k={F.BERRA_KEY}")
        self.assertIn("Friends-only", p.inner_text("main"))
        self.assertEqual(p.inner_text("h1"), "Berra")
        p = self.page("armory/character.html?r=classicplus&n=Berra&k=wrongkey000000000000")
        self.assertIn("doesn't work any more", p.inner_text("main"))
        # the game builds the link from the realm name it shows
        p = self.page(f"armory/character.html?r=open-vanilla-classic&n=berra&k={F.BERRA_KEY}")
        self.assertEqual(p.inner_text("h1"), "Berra")
        p = self.page("armory/character.html?r=classicplus&n=../index")
        self.assertIn("No character picked", p.inner_text("main"))

    def test_guild_pages_read_the_exporter_output(self):
        p = self.page("guilds.html")
        names = p.locator(".guild .name").all_inner_texts()
        self.assertEqual(names, ["<Ashen Vanguard>", "<<Knights of Ni!>>", "<Knights of Ni>"])
        self.assertEqual(self.errors, [])
        p = self.page("guild.html?r=classicplus&g=knights-of-ni-12")
        self.assertIn("We say Ni.", p.inner_text("main"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
