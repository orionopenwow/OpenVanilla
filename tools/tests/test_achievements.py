#!/usr/bin/env python3
"""Checks for the achievements catalogue and tools/gen_achievements.py.

    python3 tools/tests/test_achievements.py

The catalogue passes the generator's self-check, the generated files are up to date, and the
check really catches the mistakes it is meant to (duplicate ids, unknown creatures, wrong boss
names, broken metas, out-of-range values).
"""
import copy
import filecmp
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import gen_achievements as G  # noqa: E402


class Catalogue(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = G.load()
        cls.known = G.known_ids()

    def errs(self, data):
        return G.check(data, self.known)

    def test_catalogue_is_clean(self):
        self.assertIsNotNone(self.known, "realm/achievements/known_ids.json is missing")
        self.assertEqual(self.errs(self.data), [])

    def test_size_and_categories(self):
        A = self.data["achievements"]
        self.assertGreaterEqual(len(A), 250)
        cats = {a["category"] for a in A}
        self.assertEqual(cats, {"general", "quests", "exploration", "dungeons", "raids", "professions",
                                "reputation", "pvp", "feats"})
        self.assertEqual(len({a["id"] for a in A}), len(A), "ids unique")

    def test_every_id_referenced_is_real(self):
        # every creature/quest/item id resolves to a name in the classic-db snapshot
        for a in self.data["achievements"]:
            for c in a["criteria"]:
                for e in G.alts(c, "creature", "creatures"):
                    self.assertIn(e, self.known["creature"], (a["id"], e))
                for q in G.alts(c, "quest", "quests"):
                    self.assertIn(q, self.known["quest"], (a["id"], q))

    def test_raid_bosses_by_their_real_names(self):
        names = {a["name"] for a in self.data["achievements"]}
        for boss in ("Ragnaros", "Onyxia's Lair", "Nefarian", "Hakkar", "Ossirian the Unscarred", "C'Thun",
                     "Kel'Thuzad", "The Four Horsemen", "The Twin Emperors", "Molten Core", "Naxxramas"):
            self.assertIn(boss, names)

    def test_generated_files_are_current(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved = (G.LUA_OUT, G.SQL_OUT, G.JSON_OUT)
            try:
                G.LUA_OUT, G.SQL_OUT, G.JSON_OUT = (os.path.join(tmp, n) for n in ("Data.lua", "a.sql", "a.json"))
                G.write_lua(self.data)
                G.write_sql(self.data)
                G.write_json(self.data)
                for new, old in zip((G.LUA_OUT, G.SQL_OUT, G.JSON_OUT), saved):
                    self.assertTrue(filecmp.cmp(new, old, shallow=False),
                                    "%s is stale: run python3 tools/gen_achievements.py" % os.path.relpath(old, G.ROOT))
            finally:
                G.LUA_OUT, G.SQL_OUT, G.JSON_OUT = saved

    # -- the check catches mistakes ---------------------------------------------------------
    def broken(self, fn):
        d = copy.deepcopy(self.data)
        fn(d)
        return "\n".join(self.errs(d))

    def find(self, d, aid):
        return next(a for a in d["achievements"] if a["id"] == aid)

    def test_catches_duplicate_id(self):
        self.assertIn("duplicate id", self.broken(lambda d: d["achievements"].append(copy.deepcopy(d["achievements"][0]))))

    def test_catches_unknown_creature_and_wrong_name(self):
        def bad(d):
            self.find(d, 509)["criteria"][0]["creature"] = 29999       # not in the snapshot
            self.find(d, 560)["criteria"][0]["name"] = "Nefarian"       # 10184 is Onyxia
        out = self.broken(bad)
        self.assertIn("creature 29999 is not in known_ids.json", out)
        self.assertIn("is 'Onyxia', not 'Nefarian'", out)

    def test_catches_bad_meta_and_cycle(self):
        def bad(d):
            self.find(d, 529)["criteria"][0]["achievement"] = 4242
            self.find(d, 390)["criteria"].append({"type": "meta", "achievement": 392})
        out = self.broken(bad)
        self.assertIn("unknown achievement 4242", out)
        self.assertIn("meta cycle", out)

    def test_catches_ranges_and_ids(self):
        def bad(d):
            self.find(d, 1)["criteria"][0]["level"] = 70
            self.find(d, 300)["criteria"][0]["zone"] = 3456                 # Naxxramas is not a zone to explore
            self.find(d, 810)["criteria"][0]["faction"] = 935               # a TBC faction
            self.find(d, 750)["criteria"][0]["skill"] = 755                 # jewelcrafting
            self.find(d, 10)["points"] = 7
            self.find(d, 1000)["points"] = 10                                # feats give none
            self.find(d, 2)["icon"] = "INV_Misc_Note_01"
        out = self.broken(bad)
        for needle in ("level 1..60", "zone 3456 is not a 1.12 zone id", "faction 935 is not a known Faction id",
                       "skill 755 is not a known SkillLine id", "points 7 not one of", "Feats of Strength give no points",
                       "icon must be an Interface"):
            self.assertIn(needle, out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
