"""Forge Lite (www/forge/lite/): the static browser editor that writes a Vanilla Forge project folder.

    python3 -m unittest tests.test_forge_lite -v

The node half runs lite.js's pure helpers (skips without node); the browser half drives the page in
headless Chromium through Playwright (skips without playwright).
"""
import functools
import hashlib
import html.parser
import http.server
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
try:
    import tomllib
except ImportError:          # Python before 3.11: the zip checks need tomllib
    tomllib = None
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WWW = os.path.join(ROOT, "www")
LITE = os.path.join(WWW, "forge", "lite")
BANNED = ["WoW", "World of Warcraft", "1.12.1"]
NODE = shutil.which("node")


def read(name):
    with open(os.path.join(LITE, name), encoding="utf-8") as f:
        return f.read()


class VisibleText(html.parser.HTMLParser):
    """Text a visitor can see or hear: body text plus title, alt, aria-label, placeholder, meta content."""

    def __init__(self):
        super().__init__()
        self.parts, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        for k, v in attrs:
            if v and k in ("alt", "title", "aria-label", "placeholder", "content", "value"):
                self.parts.append(v)

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def js_string_literals(src):
    """String and template literals in JS source (comments skipped)."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            i = src.find("\n", i)
            i = n if i < 0 else i
        elif src.startswith("/*", i):
            i = src.find("*/", i + 2) + 2
        elif c in "'\"`":
            j, buf = i + 1, []
            while j < n and src[j] != c:
                if src[j] == "\\":
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                buf.append(src[j])
                j += 1
            out.append("".join(buf))
            i = j + 1
        else:
            i += 1
    return out


class Pages(unittest.TestCase):
    def test_files_exist(self):
        for name in ("index.html", "lite.js", "lite.css", "world.json"):
            self.assertTrue(os.path.isfile(os.path.join(LITE, name)), name)

    def test_brand_rule(self):
        p = VisibleText()
        p.feed(read("index.html"))
        text = " ".join(p.parts)
        for word in BANNED:
            self.assertNotIn(word, text, "index.html visible text")
        for lit in js_string_literals(read("lite.js")):
            for word in BANNED:
                self.assertNotIn(word, lit, "lite.js string literal")
        self.assertIn("11200", read("lite.js"))  # the interface number in the .toc is allowed

    def test_csp_and_no_inline_code(self):
        src = read("index.html")
        self.assertIsNone(re.search(r"<script(?![^>]*\bsrc=)[^>]*>", src, re.I), "inline <script>")
        self.assertNotRegex(src, r"(?i)\sstyle\s*=", "inline style attribute")
        self.assertNotRegex(src, r"(?i)<style", "inline <style> block")
        self.assertNotRegex(src, r"(?i)\son[a-z]+\s*=", "inline event handler")
        m = re.search(r'<meta http-equiv="Content-Security-Policy" content="([^"]+)"', src)
        self.assertIsNotNone(m)
        csp = m.group(1)
        for part in ("default-src 'self'", "script-src 'self'", "style-src 'self' https://fonts.googleapis.com",
                     "font-src https://fonts.gstatic.com", "base-uri 'none'", "form-action 'none'", "connect-src 'self'"):
            self.assertIn(part, csp)
        self.assertNotIn("setAttribute('style'", read("lite.js"))
        self.assertIn("../../forge.html", src)
        self.assertIn("../../privacy.html", src)
        self.assertIn("not affiliated with Blizzard Entertainment", src)


NODE_SCRIPT = r"""
const L = require(process.argv[2]);
const fs = require('fs');
const schema = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
(async () => {
  const s = L.newState();
  s.pack.name = 'Tide "Caller" Pack';
  s.pack.id = 'tide-caller';
  s.pack.author = 'Ana';
  s.pack.description = 'Line one\nline two\ttabbed \\ back';
  s.pack.realms = ['classicplus', 'community'];
  const item = await L.addRow(s, 'item_template', { name: 'Pearl of the Tide', Quality: 3, class: 4, InventoryType: 12,
    ItemLevel: 20, RequiredLevel: 15, SellPrice: 12345, stat_type1: 7, stat_value1: 5, dmg_min1: 2.5, dmg_max1: 4.5 });
  const item2 = await L.addRow(s, 'item_template', { name: 'Kelp', class: 12 });
  const npc = await L.addRow(s, 'creature_template', { Name: 'Marla Tidecaller', SubName: 'Harbour Master', MinLevel: 20, MaxLevel: 21,
    Faction: 35, Scale: 1.5 });
  const q = await L.addRow(s, 'quest_template', { Title: 'Kelp for Marla', Details: 'Bring me kelp.', Objectives: 'Collect 5 Kelp.',
    MinLevel: 15, QuestLevel: 20, ReqItemId1: item2.entry, ReqItemCount1: 5, RewItemId1: item.entry, RewItemCount1: 1,
    RewOrReqMoney: 500, _giver: npc.Entry, _ender: npc.Entry });
  s.addon.enabled = true;
  const zip = L.projectZip(s, schema, new Date(2026, 0, 2, 3, 4, 6));
  fs.writeFileSync(process.argv[4], Buffer.from(zip));
  // Round trip through the zip reader and importer.
  const files = await L.readZip(zip);
  const back = L.importProject(files, schema).state;
  const zip2 = L.projectZip(back, schema, new Date(2026, 0, 2, 3, 4, 6));
  const issues = L.validate(s, schema);
  console.log(JSON.stringify({ item: item.entry, item2: item2.entry, npc: npc.Entry, quest: q.entry, ids: s.ids,
    roundtrip: Buffer.from(zip).equals(Buffer.from(zip2)), issues: issues,
    crc: L.crc32(L.utf8('The quick brown fox jumps over the lazy dog')),
    empty: L.validate(L.newState(), schema).map(i => i.msg),
    bad: L.validate(Object.assign(L.newState(), { tables: { item_template: [{ entry: 1, name: '', dmg_min1: 3 }],
      creature_template: [{ Entry: 2, Name: 'X', MinLevel: 10, MaxLevel: 5 }], quest_template: [{ entry: 3, Title: 'Q', _giver: 99 }] } }), schema).map(i => i.msg) }));
})().catch(e => { console.error(e.stack || e); process.exit(1); });
"""


def expected_range(pack, table, lo, hi, reserved=()):
    n = (hi - lo) // 1000
    idx = int.from_bytes(hashlib.sha256(f"{pack}:{table}".encode()).digest()[:4], "big") % n
    for i in range(n):
        s = lo + ((idx + i) % n) * 1000
        if not any(s < r[1] and r[0] < s + 1000 for r in reserved):
            return s, s + 1000


@unittest.skipUnless(NODE, "node not installed")
@unittest.skipIf(tomllib is None, "needs Python 3.11+ (tomllib)")
class NodeHelpers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        script = os.path.join(cls.tmp, "run.js")
        with open(script, "w") as f:
            f.write(NODE_SCRIPT)
        cls.zip_path = os.path.join(cls.tmp, "pack.zip")
        out = subprocess.run([NODE, script, os.path.join(LITE, "lite.js"), os.path.join(LITE, "world.json"), cls.zip_path],
                             capture_output=True, text=True, timeout=60)
        if out.returncode:
            raise AssertionError(out.stderr)
        cls.info = json.loads(out.stdout)
        cls.zf = zipfile.ZipFile(cls.zip_path)
        with open(os.path.join(LITE, "world.json"), encoding="utf-8") as f:
            cls.schema = json.load(f)

    @classmethod
    def tearDownClass(cls):
        cls.zf.close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def toml(self, path):
        return tomllib.loads(self.zf.read("tide-caller/" + path).decode("utf-8"))

    def test_zip_is_valid(self):
        self.assertIsNone(self.zf.testzip())
        names = self.zf.namelist()
        self.assertTrue(all(n.startswith("tide-caller/") for n in names))
        self.assertEqual(names, sorted(names))
        for zi in self.zf.infolist():
            self.assertEqual(zi.compress_type, zipfile.ZIP_STORED)
            self.assertTrue(zi.flag_bits & 0x800)
        self.assertEqual(self.info["crc"], 0x414FA339)
        self.assertTrue(self.info["roundtrip"], "import then export changed the project")
        for want in ("forge.toml", "credits.toml", "README.md", ".gitignore", ".forge/ids.lock",
                     "data/world/item_template.toml", "data/world/creature_template.toml", "data/world/quest_template.toml",
                     "data/world/creature_questrelation.toml", "data/world/creature_involvedrelation.toml",
                     "addons/TideCaller/TideCaller.toc", "addons/TideCaller/Core.lua"):
            self.assertIn("tide-caller/" + want, names)

    def test_forge_toml(self):
        f = self.toml("forge.toml")
        self.assertEqual(f["depends"], [])
        self.assertEqual(f["pack"]["id"], "tide-caller")
        self.assertEqual(f["pack"]["name"], 'Tide "Caller" Pack')
        self.assertEqual(f["pack"]["version"], "0.1.0")
        self.assertEqual(f["pack"]["authors"], ["Ana"])
        self.assertEqual(f["pack"]["license"], "MIT")
        self.assertEqual(f["pack"]["description"], "Line one\nline two\ttabbed \\ back")
        self.assertEqual(f["targets"]["realms"], ["classicplus", "community"])
        credits = self.zf.read("tide-caller/credits.toml").decode()
        self.assertTrue(credits.startswith("# Every file in this pack that you did not make yourself"))
        self.assertEqual(tomllib.loads(credits), {})
        self.assertEqual(self.zf.read("tide-caller/.gitignore").decode(), "build/\n.forge/undo/\n")
        self.assertTrue(self.zf.read("tide-caller/README.md").decode().endswith("\n\nMade with Vanilla Forge Lite.\n"))

    def test_ids_in_range_and_lock(self):
        lock = self.toml(".forge/ids.lock")
        cases = [("item_template", 1100000, 2100000, [self.info["item"], self.info["item2"]]),
                 ("creature_template", 1100000, 2100000, [self.info["npc"]]),
                 ("quest_template", 110000, 210000, [self.info["quest"]])]
        for table, lo, hi, ids in cases:
            start, end = expected_range("tide-caller", table, lo, hi, [(990000, 1000000)])
            t = lock["tables"][table]
            self.assertEqual((t["start"], t["end"]), (start, end), table)
            self.assertEqual(t["next"], max(ids) + 1)
            self.assertEqual(t["source"], "local")
            self.assertEqual(ids[0], start)
            for i in ids:
                self.assertTrue(start <= i < end)
        self.assertEqual(lock["names"][f"item_template:{self.info['item']}"], "Pearl of the Tide")
        self.assertEqual(lock["names"][f"quest_template:{self.info['quest']}"], "Kelp for Marla")

    def test_data_rows(self):
        cols = {t: {c["name"] for c in self.schema[t]["columns"]} for t in self.schema}
        items = self.toml("data/world/item_template.toml")["row"]
        self.assertEqual(len(items), 2)
        it = items[0]
        self.assertEqual(it["entry"], self.info["item"])
        self.assertEqual((it["name"], it["Quality"], it["class"], it["InventoryType"]), ("Pearl of the Tide", 3, 4, 12))
        self.assertEqual((it["SellPrice"], it["stat_type1"], it["stat_value1"]), (12345, 7, 5))
        self.assertIsInstance(it["dmg_min1"], float)
        self.assertNotIn("delay", it)  # default values are left out
        self.assertNotIn("BuyCount", it)
        cr = self.toml("data/world/creature_template.toml")["row"][0]
        self.assertEqual((cr["Entry"], cr["Name"], cr["SubName"]), (self.info["npc"], "Marla Tidecaller", "Harbour Master"))
        self.assertEqual(cr["NpcFlags"] & 2, 2, "the quest giver gets the quest-giver flag")
        self.assertEqual(cr["Scale"], 1.5)
        q = self.toml("data/world/quest_template.toml")["row"][0]
        self.assertEqual((q["entry"], q["Title"], q["ReqItemId1"], q["ReqItemCount1"]), (self.info["quest"], "Kelp for Marla", self.info["item2"], 5))
        self.assertEqual((q["RewItemId1"], q["RewOrReqMoney"]), (self.info["item"], 500))
        for t, rows in (("item_template", items), ("creature_template", [cr]), ("quest_template", [q])):
            for row in rows:
                self.assertLessEqual(set(row) - {"override"}, cols[t], t)
        raw = self.zf.read("tide-caller/data/world/item_template.toml").decode()
        self.assertTrue(raw.startswith("# item_template: rows this pack adds or (override = true) changes."))
        for rel in ("creature_questrelation", "creature_involvedrelation"):
            rows = self.toml(f"data/world/{rel}.toml")["row"]
            self.assertEqual(rows, [{"id": self.info["npc"], "quest": self.info["quest"]}])

    def test_addon(self):
        toc = self.zf.read("tide-caller/addons/TideCaller/TideCaller.toc").decode()
        self.assertEqual(toc, "## Interface: 11200\n## Title: Tide \"Caller\" Pack\n## Notes: Made with Vanilla Forge Lite.\n"
                              "## Author: Ana\n## Version: 0.1.0\n## SavedVariables: TideCallerDB\n\nCore.lua\n")
        lua = self.zf.read("tide-caller/addons/TideCaller/Core.lua").decode()
        self.assertIn('SLASH_TIDECALLER1 = "/tidecaller"', lua)
        self.assertIn("TideCallerDB", lua)
        self.assertNotIn("gmatch(", lua)
        self.assertNotRegex(lua, r"#\w")

    def test_validation(self):
        self.assertFalse([i for i in self.info["issues"] if i["level"] == "error"], self.info["issues"])
        self.assertTrue(any("empty" in m for m in self.info["empty"]))
        bad = " | ".join(self.info["bad"])
        for want in ("needs a name", "Maximum damage is lower", "Maximum level must be", "quest giver is not a creature"):
            self.assertIn(want, bad)


class _Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


@unittest.skipIf(tomllib is None, "needs Python 3.11+ (tomllib)")
class Browser(unittest.TestCase):
    def test_page_builds_a_zip(self):
        try:
            from playwright.sync_api import sync_playwright
        except Exception as e:  # noqa: BLE001
            self.skipTest(f"playwright missing: {e}")
        os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", "/opt/pw-browsers")
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(_Quiet, directory=WWW))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        url = f"http://127.0.0.1:{srv.server_address[1]}/forge/lite/index.html"
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        errors = []
        with sync_playwright() as pw:
            try:
                browser = pw.chromium.launch()
            except Exception as e:  # noqa: BLE001
                self.skipTest(f"chromium not available: {e}")
            try:
                ctx = browser.new_context(viewport={"width": 375, "height": 800}, accept_downloads=True)
                # No network here: answer the font requests with nothing.
                ctx.route(re.compile(r"https://fonts\.(googleapis|gstatic)\.com/.*"),
                          lambda r: r.fulfill(status=200, content_type="text/css", body=""))
                page = ctx.new_page()
                page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.goto(url)
                page.wait_for_function("!document.getElementById('btn-download').disabled")
                page.fill("#pack-name", "Harbour Tales")
                self.assertEqual(page.input_value("#pack-id"), "harbour-tales")
                page.fill("#pack-author", "Tester")
                page.click("#add-row")
                page.wait_for_selector("#panel .row-btn")
                page.fill("#panel .grid input[type=text]", "Salty Cutlass")
                page.select_option("#panel select >> nth=1", "2")  # Kind: Weapon
                # Creatures and quests tabs, and the all-columns view, must render too.
                page.click("#tab-creatures")
                page.click("#add-row")
                page.wait_for_selector("#panel .row-btn")
                page.click("#tab-quests")
                page.click("#add-row")
                page.wait_for_selector("#panel .row-btn")
                page.click("details.allcols summary")
                page.wait_for_selector(".grid-all input")
                giver = page.locator("#panel select").first
                giver.select_option(index=1)
                page.click("#tab-addon")
                page.check("#addon-on")
                for tab in ("#tab-items", "#tab-quests", "#tab-addon"):
                    page.click(tab)
                    sw = page.evaluate("[document.documentElement.scrollWidth, document.documentElement.clientWidth]")
                    self.assertLessEqual(sw[0], sw[1], f"horizontal scroll at 375 px on {tab}")
                with page.expect_download() as dl:
                    page.click("#btn-download")
                path = os.path.join(tmp, "out.zip")
                dl.value.save_as(path)
                self.assertEqual(dl.value.suggested_filename, "harbour-tales.zip")
                stored = page.evaluate("JSON.parse(localStorage.getItem('forge-lite:v1')).pack.name")
                self.assertEqual(stored, "Harbour Tales")
                page.reload()
                page.wait_for_function("!document.getElementById('btn-download').disabled")
                self.assertEqual(page.input_value("#pack-name"), "Harbour Tales")
                visible = page.inner_text("body")
                for word in BANNED:
                    self.assertNotIn(word, visible)
            finally:
                browser.close()
        self.assertEqual(errors, [])
        with zipfile.ZipFile(path) as z:
            self.assertIsNone(z.testzip())
            f = tomllib.loads(z.read("harbour-tales/forge.toml").decode())
            self.assertEqual(f["pack"]["name"], "Harbour Tales")
            self.assertEqual(f["pack"]["authors"], ["Tester"])
            items = tomllib.loads(z.read("harbour-tales/data/world/item_template.toml").decode())["row"]
            self.assertEqual(items[0]["name"], "Salty Cutlass")
            self.assertEqual(items[0]["class"], 2)
            cr = tomllib.loads(z.read("harbour-tales/data/world/creature_template.toml").decode())["row"][0]
            self.assertEqual(cr["NpcFlags"] & 2, 2)
            rel = tomllib.loads(z.read("harbour-tales/data/world/creature_questrelation.toml").decode())["row"]
            self.assertEqual(rel[0]["id"], cr["Entry"])
            self.assertIn("harbour-tales/addons/HarbourTales/HarbourTales.toc", z.namelist())
            tomllib.loads(z.read("harbour-tales/.forge/ids.lock").decode())




class SchemaInStep(unittest.TestCase):
    def test_lite_schema_matches_forge(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        forge = os.path.join(root, "forge", "crates", "forge-core", "schemas", "world.json")
        if not os.path.isfile(forge):
            self.skipTest("no forge checkout")
        with open(forge, "rb") as a, open(os.path.join(root, "www", "forge", "lite", "world.json"), "rb") as b:
            self.assertEqual(a.read(), b.read(), "copy forge/crates/forge-core/schemas/world.json to www/forge/lite/world.json")


if __name__ == "__main__":
    unittest.main()
