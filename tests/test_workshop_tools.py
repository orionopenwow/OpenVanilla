"""The Workshop tools: the indexer (with a fake network), the builder's JSON schema (fixture catalogue
and the real www/community/workshop output), the scanner on a good and a bad addon, and the porting
helper (refuses addons whose licence does not allow redistribution).

    python3 -m unittest tests.test_workshop_tools -v
"""
import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))

import workshop_build as B  # noqa: E402
import workshop_index as I  # noqa: E402
import workshop_lib as W  # noqa: E402
import workshop_port as P  # noqa: E402
import workshop_scan as S  # noqa: E402

FIX = os.path.join(HERE, "fixtures", "workshop")
GOOD = os.path.join(FIX, "GoodAddon")
BAD = os.path.join(FIX, "BadAddon")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


MIT_TEXT = read(os.path.join(GOOD, "LICENSE"))
SHA = "a" * 40


class FakeNet:
    """The indexer's network, scripted. The GitHub API is refused (as through this proxy), so the
    indexer must fall back to git ls-remote + raw LICENSE files."""

    def __init__(self, repos, api_ok=False, topics=None):
        self.repos = repos            # repo -> {"license_file": name, "text": ...} or None (missing)
        self.api_ok = api_ok
        self.topics = topics or {}
        self.api_blocked = None
        self.calls = []

    def github_api(self, path):
        self.calls.append(("api", path))
        if not self.api_ok:
            self.api_blocked = "GitHub API refused (HTTP 403)"
            return False, self.api_blocked
        m = re.match(r"^/search/repositories\?q=topic:([\w-]+)", path)
        if m:
            return True, {"items": self.topics.get(m.group(1), [])}
        m = re.match(r"^/repos/([^/]+/[^/]+)$", path)
        if m:
            r = self.repos.get(m.group(1))
            if not r:
                return False, "HTTP 404"
            return True, {"full_name": m.group(1), "default_branch": "main", "license": {"spdx_id": r.get("spdx", "NOASSERTION")},
                          "owner": {"login": m.group(1).split("/")[0]}, "description": "d"}
        m = re.match(r"^/repos/([^/]+/[^/]+)/commits/", path)
        if m:
            return True, {"sha": SHA}
        return False, "HTTP 404"

    def ls_remote(self, repo):
        self.calls.append(("git", repo))
        if repo not in self.repos or self.repos[repo] is None:
            return False, "fatal: repository not found"
        return True, f"ref: refs/heads/main\tHEAD\n{SHA}\tHEAD\n"

    def raw(self, repo, branch, path):
        r = self.repos.get(repo) or {}
        if r.get("license_file") == path:
            return True, r["text"]
        return False, "HTTP 404"

    def http(self, url, headers=None):
        self.calls.append(("http", url))
        return False, "not in tests"


def seed_row(sid, repos, cat="interface"):
    return (sid, sid.title(), "Tester", cat, repos, f"{sid} summary.", ["t"])


class IndexerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ws-index-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.catalog = os.path.join(self.tmp, "catalog")
        self.addons = os.path.join(self.tmp, "AddOns")
        os.makedirs(os.path.join(self.addons, "Raid"))
        os.makedirs(os.path.join(self.addons, "NotOurs"))
        with open(os.path.join(self.addons, "Raid", "Raid.toc"), "w") as f:
            f.write("## Title: Raid\n## Notes: Raid frames. With more.\n## Version: 2.0\n## X-ClassicPlus: Raid\nRaid.lua\n")
        with open(os.path.join(self.addons, "NotOurs", "NotOurs.toc"), "w") as f:
            f.write("## Title: Not ours\nNotOurs.lua\n")
        os.makedirs(os.path.join(self.addons, "Staff"))
        with open(os.path.join(self.addons, "Staff", "Staff.toc"), "w") as f:
            f.write("## Title: Staff\n## X-ClassicPlus: Staff\n## X-Unlisted: 1\nStaff.lua\n")
        self.saved = I.SEED
        I.SEED = [seed_row("freeaddon", ["gone/FreeAddon", "alive/FreeAddon"]),
                  seed_row("closedaddon", ["someone/ClosedAddon"]),
                  seed_row("noaddon", ["nobody/Missing"]),
                  seed_row("gpladdon", ["gnu/GplAddon"])]
        self.addCleanup(setattr, I, "SEED", self.saved)
        os.environ.pop("CURSEFORGE_KEY", None)

    def args(self, **kw):
        return argparse.Namespace(catalog=self.catalog, addons=self.addons, offline=kw.get("offline", False), only=kw.get("only"))

    def load(self):
        return {e["id"]: e for e in W.load_catalog(self.catalog)}

    def test_git_fallback_licences_and_ours(self):
        net = FakeNet({
            "alive/FreeAddon": {"license_file": "LICENSE", "text": MIT_TEXT},
            "someone/ClosedAddon": {"license_file": "LICENSE.txt", "text": "Copyright 2006. All rights reserved."},
            "gnu/GplAddon": {"license_file": "COPYING", "text": "GNU GENERAL PUBLIC LICENSE\nVersion 2, June 1991"},
        })
        _w, notes = I.run(self.args(), net=net, log=lambda *a: None)
        cat = self.load()
        free = cat["freeaddon"]
        self.assertEqual((free["license"], free["rehost"], free["verified"]), ("MIT", True, True))
        self.assertEqual(free["source_url"], "https://github.com/alive/FreeAddon", "first candidate that exists wins")
        self.assertEqual(free["upstream"]["how"], "git")
        self.assertEqual(free["upstream"]["commit"], SHA)
        self.assertEqual(free["version"], "git-" + SHA[:7])
        self.assertEqual((cat["closedaddon"]["license"], cat["closedaddon"]["rehost"]), ("Proprietary", False))
        self.assertEqual((cat["gpladdon"]["license"], cat["gpladdon"]["rehost"]), ("GPL-2.0", True))
        self.assertFalse(cat["noaddon"]["verified"], "an unreachable repository stays unverified")
        self.assertFalse(cat["noaddon"]["rehost"])
        ours = cat["cp-raid"]
        self.assertTrue(ours["ours"] and ours["rehost"])
        self.assertEqual((ours["category"], ours["folders"], ours["version"]), ("classicplus", ["Raid"], "2.0"))
        self.assertNotIn("cp-notours", cat, "only folders with ## X-ClassicPlus")
        self.assertNotIn("cp-staff", cat, "## X-Unlisted folders stay out of the Workshop")
        self.assertTrue(any("ls-remote" in n for n in notes), notes)
        self.assertTrue(any("CURSEFORGE_KEY not set" in n for n in notes), notes)
        self.assertFalse(any(c[0] == "http" for c in net.calls), "no CurseForge call without a key")

    def test_hand_edits_survive_and_api_path(self):
        os.makedirs(self.catalog)
        W.write_entry({"id": "freeaddon", "name": "Free Addon (hand-named)", "description": "Written by a person.",
                       "screenshots": ["assets/x.webp"], "compat": "works", "license": "NOASSERTION"}, self.catalog)
        topic_item = {"full_name": "new/TurtleThing", "default_branch": "main", "license": {"spdx_id": "MIT"},
                      "owner": {"login": "new"}, "description": "A new thing", "fork": False}
        net = FakeNet({"alive/FreeAddon": {"spdx": "MIT"}}, api_ok=True, topics={"turtle-wow": [topic_item]})
        I.run(self.args(), net=net, log=lambda *a: None)
        cat = self.load()
        free = cat["freeaddon"]
        self.assertEqual(free["name"], "Free Addon (hand-named)")
        self.assertEqual(free["description"], "Written by a person.")
        self.assertEqual(free["compat"], "works")
        self.assertEqual((free["license"], free["upstream"]["how"]), ("MIT", "api"))
        new = cat["turtlething"]
        self.assertIs(new["listed"], False, "topic finds wait for a person")
        self.assertTrue(new["rehost"])

    def test_offline_touches_no_network(self):
        net = FakeNet({})
        I.run(self.args(offline=True), net=net, log=lambda *a: None)
        self.assertEqual(net.calls, [])
        self.assertFalse(self.load()["freeaddon"]["verified"])

    def test_licence_helpers(self):
        self.assertEqual(W.classify_license_text(MIT_TEXT), "MIT")
        self.assertEqual(W.classify_license_text("GNU LESSER GENERAL PUBLIC LICENSE Version 2.1"), "LGPL-2.1")
        self.assertEqual(W.classify_license_text("Creative Commons Attribution-NonCommercial"), "CC-BY-NC")
        for ok in ("MIT", "gplv3", "BSD-3-Clause", "Apache-2.0", "MPL-2.0", "Unlicense", "CC0-1.0", "lgpl-2.1"):
            self.assertTrue(W.may_rehost(ok), ok)
        for no in ("NOASSERTION", "Proprietary", "AGPL-3.0", "CC-BY-NC", None, "", "Open Vanilla"):
            self.assertFalse(W.may_rehost(no), no)
        self.assertGreaterEqual(len(self.saved), 75, "the seed list of well-known vanilla addons")


CARD_KEYS = {"id", "name", "author", "creator", "summary", "category", "compat", "ours", "rehost", "install", "license",
             "version", "added", "tags", "thumb", "verified", "browser", "stats"}
FULL_KEYS = CARD_KEYS | {"description", "screenshots", "source_url", "homepage", "files", "folders", "requires", "scan",
                         "credits", "install_url", "versions"}


def check_schema(t, out_dir, index):
    t.assertEqual(set(index) >= {"updated", "base", "count", "categories", "badges", "addons", "collections", "creators", "api"}, True)
    t.assertEqual(index["count"], len(index["addons"]))
    ids = set()
    for c in index["addons"]:
        t.assertEqual(set(c), CARD_KEYS, c["id"])
        t.assertRegex(c["id"], W.ID_RE)
        t.assertIn(c["compat"], W.COMPAT_VALUES)
        t.assertIn(c["category"], W.CATEGORIES)
        ids.add(c["id"])
        with open(os.path.join(out_dir, c["id"] + ".json"), encoding="utf-8") as f:
            full = json.load(f)
        t.assertEqual(set(full), FULL_KEYS, c["id"])
        if full["install"]:
            t.assertTrue(full["ours"] or W.may_rehost(full["license"]), f"{c['id']} is hosted under {full['license']}")
            t.assertEqual(full["install_url"], f"openvanilla://workshop/install/{c['id']}")
            for fl in full["files"]:
                t.assertRegex(fl["sha256"], r"^[0-9a-f]{64}$")
                t.assertRegex(fl["url"], r"^community/workshop/files/[a-z0-9-]+-[0-9a-f]{12}\.zip$")
        else:
            t.assertIsNone(full["install_url"])
        if not full["rehost"]:
            t.assertEqual(full["files"], [], f"{c['id']} must not offer a package")
            t.assertIsNone(full["credits"]["text"])
    for col in index["collections"]:
        t.assertTrue(set(col["addons"]) <= ids, col["id"])
    for cr in index["creators"]:
        t.assertTrue(set(cr["addons"]) <= ids)
    return ids


class BuilderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ws-build-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.catalog = os.path.join(self.tmp, "catalog")
        self.cols = os.path.join(self.tmp, "collections")
        self.out = os.path.join(self.tmp, "out")
        os.makedirs(self.cols)
        os.makedirs(os.path.join(self.out, "files"))
        zpath = os.path.join(self.out, "files", "freeaddon-0123456789ab.zip")
        with zipfile.ZipFile(zpath, "w") as z:
            z.writestr("FreeAddon/FreeAddon.toc", "## Interface: 11200\n")
        sha = B.sha256(zpath)
        base = {"author": "Tester (and friends)", "summary": "s", "description": "d", "category": "interface",
                "source_url": "https://github.com/t/x", "homepage": "https://github.com/t/x", "version": "1", "added": "2026-10-01",
                "screenshots": [], "tags": [], "compat": "unknown", "ours": False, "verified": True}
        W.write_entry(dict(base, id="freeaddon", name="Free", license="MIT", compat="works",
                           files=[{"name": "freeaddon-0123456789ab.zip", "url": "community/workshop/files/freeaddon-0123456789ab.zip",
                                   "sha256": sha, "size": 10, "folders": ["FreeAddon"]}],
                           upstream={"commit": SHA}), self.catalog)
        # A licence that does not allow rehosting, with a stray `files:` a person left in: never offered.
        W.write_entry(dict(base, id="closedaddon", name="Closed", license="Proprietary", rehost=True,
                           files=[{"name": "x.zip", "url": "community/workshop/files/x.zip", "sha256": "0" * 64, "size": 1}]),
                      self.catalog)
        W.write_entry(dict(base, id="hidden", name="Hidden", license="MIT", listed=False), self.catalog)
        W.write_entry(dict(base, id="cp-raid", name="Raid", author="Open Vanilla", license="Open Vanilla", ours=True, category="classicplus",
                           compat="bogus", folders=["Raid"]), self.catalog)
        with open(os.path.join(self.cols, "pack.yml"), "w") as f:
            f.write("id: pack\nname: Pack\ncurator: OpenVanilla\nsummary: s\naddons: [freeaddon, cp-raid, nosuch]\n")
        with open(os.path.join(self.out, "stale.json"), "w") as f:
            f.write("{}")

    def test_schema_and_rules(self):
        args = argparse.Namespace(catalog=self.catalog, collections=self.cols, out=self.out, cache=self.tmp, fetch=False,
                                  only=None, stats=None, max_mb=8)
        index, problems = B.build(args, log=lambda *a: None)
        ids = check_schema(self, self.out, index)
        self.assertEqual(ids, {"freeaddon", "closedaddon", "cp-raid"}, "listed: false stays out")
        self.assertFalse(os.path.exists(os.path.join(self.out, "stale.json")))
        self.assertEqual([c["id"] for c in index["addons"]][0], "cp-raid", "ours first")
        by = {c["id"]: c for c in index["addons"]}
        self.assertTrue(by["freeaddon"]["install"])
        self.assertFalse(by["closedaddon"]["install"] or by["closedaddon"]["rehost"])
        self.assertEqual(by["cp-raid"]["compat"], "unknown", "bad compat values are normalised")
        self.assertFalse(by["cp-raid"]["install"], "no package built yet")
        self.assertEqual(index["collections"][0]["addons"], ["freeaddon", "cp-raid"])
        self.assertTrue(any("nosuch" in p for p in problems))
        self.assertEqual(by["freeaddon"]["creator"], "tester")
        with open(os.path.join(self.out, "freeaddon.json"), encoding="utf-8") as f:
            full = json.load(f)
        self.assertIn("Licence:  MIT", full["credits"]["text"])
        self.assertIn(SHA, full["credits"]["text"])

    def test_stats_snapshot(self):
        stats = os.path.join(self.tmp, "stats.json")
        with open(stats, "w") as f:
            json.dump({"freeaddon": {"rating": 4.5, "votes": 8, "installs": 120}}, f)
        args = argparse.Namespace(catalog=self.catalog, collections=self.cols, out=self.out, cache=self.tmp, fetch=False,
                                  only=None, stats=stats, max_mb=8)
        index, _ = B.build(args, log=lambda *a: None)
        self.assertEqual({c["id"]: c["stats"] for c in index["addons"]}["freeaddon"], {"rating": 4.5, "votes": 8, "installs": 120})

    def test_deterministic_zip(self):
        a, b = os.path.join(self.tmp, "a.zip"), os.path.join(self.tmp, "b.zip")
        B.det_zip(a, [(GOOD, "GoodAddon")], {"GoodAddon/OPENVANILLA-CREDITS.txt": "c"})
        B.det_zip(b, [(GOOD, "GoodAddon")], {"GoodAddon/OPENVANILLA-CREDITS.txt": "c"})
        self.assertEqual(B.sha256(a), B.sha256(b))
        with zipfile.ZipFile(a) as z:
            self.assertIn("GoodAddon/GoodAddon.toc", z.namelist())

    def test_published_output(self):
        """The committed www/community/workshop matches the schema, and every hosted package exists
        with the checksum the catalogue lists."""
        out = W.OUT_DIR
        with open(os.path.join(out, "index.json"), encoding="utf-8") as f:
            index = json.load(f)
        check_schema(self, out, index)
        self.assertGreaterEqual(index["count"], 80)
        for c in index["addons"]:
            with open(os.path.join(out, c["id"] + ".json"), encoding="utf-8") as f:
                full = json.load(f)
            for fl in full["files"]:
                path = os.path.join(W.ROOT, "www", fl["url"])
                self.assertTrue(os.path.isfile(path), path)
                self.assertEqual(B.sha256(path), fl["sha256"], path)
        ours = {c["id"] for c in index["addons"] if c["ours"]}
        for folder in os.listdir(W.ADDONS_DIR):
            toc = W.read_toc(os.path.join(W.ADDONS_DIR, folder, folder + ".toc"))
            if toc and "X-ClassicPlus" in toc["meta"]:
                if toc["meta"].get("X-Unlisted"):
                    self.assertNotIn("cp-" + W.slug(folder), ours, f"{folder} is unlisted but has a Workshop entry")
                    continue
                self.assertIn("cp-" + W.slug(folder), ours, f"{folder} has no Workshop entry")
        cols = {c["id"] for c in index["collections"]}
        self.assertTrue({"raiders-pack", "roleplay-pack"} <= cols)


@unittest.skipUnless(S.LUA, "lua5.1 is not installed")
class ScannerTests(unittest.TestCase):
    def test_good_addon_works(self):
        r = S.scan_path(GOOD, known={"OtherAddonDB"})
        self.assertEqual(r["compat"], "works", S.summary(r))
        self.assertFalse([f for f in r["findings"] if f["severity"] in ("high", "medium")], r["findings"])
        self.assertEqual(r["addons"][0]["toc"]["SavedVariables"], "GoodAddonDB")

    def test_bad_addon_is_flagged(self):
        r = S.scan_path(BAD, known={"OtherAddonDB"})
        self.assertEqual(r["compat"], "needs-fixes")
        kinds = {f["kind"]: f["severity"] for f in r["findings"]}
        self.assertEqual(kinds.get("chat-at-load"), "high", kinds)
        self.assertEqual(kinds.get("os-io"), "high")
        self.assertEqual(kinds.get("reads-other-saved"), "medium")
        self.assertTrue(any("'#'" in e for e in r["addons"][0]["errors"]), r["addons"][0]["errors"])

    def test_upload_queue(self):
        q = tempfile.mkdtemp(prefix="ws-queue-")
        self.addCleanup(shutil.rmtree, q, True)
        for name, src in (("1", GOOD), ("2", BAD)):
            with zipfile.ZipFile(os.path.join(q, name + ".zip"), "w") as z:
                for f in os.listdir(src):
                    z.write(os.path.join(src, f), os.path.basename(src) + "/" + f)
        with zipfile.ZipFile(os.path.join(q, "3.zip"), "w") as z:
            z.writestr("../../escape.lua", "x")
        with open(os.path.join(q, "4.zip"), "wb") as f:
            f.write(b"PK\x03\x04 not really")
        self.assertEqual(S.scan_queue(q, log=lambda *a: None), 4)
        res = {n: json.loads(read(os.path.join(q, n + ".scan.json"))) for n in "1234"}
        self.assertEqual((res["1"]["compat"], res["1"]["held"]), ("works", False))
        self.assertTrue(res["2"]["held"])
        self.assertTrue(res["3"]["held"])
        self.assertIn("unsafe path", res["3"]["findings"][0]["detail"])
        self.assertTrue(res["4"]["held"])
        self.assertFalse(os.path.exists(os.path.join(q, "..", "escape.lua")))
        self.assertEqual(S.scan_queue(q, log=lambda *a: None), 0, "already scanned")


class PortTests(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix="ws-port-")
        self.addCleanup(shutil.rmtree, self.out, True)

    def test_refuses_all_rights_reserved(self):
        with self.assertRaises(P.Refused) as cm:
            P.port(BAD, self.out, scan=False, log=lambda *a: None)
        self.assertIn("does not allow redistribution", str(cm.exception))
        self.assertEqual(os.listdir(self.out), [], "nothing written for a refused port")
        self.assertEqual(P.main([BAD, "--out", self.out, "--no-scan"]), 2)

    def test_refuses_without_licence_and_bad_flag(self):
        tmp = tempfile.mkdtemp(prefix="ws-nolic-")
        self.addCleanup(shutil.rmtree, tmp, True)
        dst = os.path.join(tmp, "GoodAddon")
        shutil.copytree(GOOD, dst)
        os.remove(os.path.join(dst, "LICENSE"))
        with self.assertRaises(P.Refused):
            P.port(dst, self.out, scan=False, log=lambda *a: None)
        with self.assertRaises(P.Refused):
            P.port(GOOD, self.out, license="CC-BY-NC", scan=False, log=lambda *a: None)

    def test_ports_an_mit_addon(self):
        logs = []
        r = P.port(GOOD, self.out, source="https://github.com/test/GoodAddon", scan=bool(S.LUA), log=logs.append)
        self.assertEqual(r["license"], "MIT")
        self.assertEqual(r["saved"], ["GoodAddonDB"])
        self.assertEqual({(s["on"], s["off"]) for s in r["switches"]}, {("lock", "unlock"), ("show", "hide")})
        self.assertIn("reset", r["commands"])
        d = r["wrapper"]
        toc = read(os.path.join(d, "GoodAddonPlus.toc"))
        self.assertIn("## X-ClassicPlus: GoodAddon", toc)
        self.assertIn("## Dependencies: WenillaCore, GoodAddon", toc)
        self.assertIn("## X-License: MIT", toc)
        lua = read(os.path.join(d, "GoodAddonPlus.lua"))
        self.assertIn("W:RegisterSchema(ID", lua)
        self.assertIn("W:RegisterAddon(ID", lua)
        for bad in ("#", "select(", "string.match", "string.gmatch"):
            code = "\n".join(ln for ln in lua.splitlines() if not ln.lstrip().startswith("--"))
            self.assertNotIn(bad, code.replace("\\\\Icons", ""), f"Lua 5.0 only: {bad}")
        notes = read(os.path.join(d, "PORT_NOTES.txt"))
        self.assertIn("A person must review this port", notes)
        self.assertIn("Original author : Test Author", notes)
        self.assertTrue(any("Licence         : MIT" in str(x) for x in logs), "credits block printed")
        if S.LUA:
            self.assertIn(r["scan_wrapper"]["compat"], ("works", "partly"), S.summary(r["scan_wrapper"]))


if __name__ == "__main__":
    unittest.main()
