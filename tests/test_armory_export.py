"""The armory exporter (tools/armory_export.py) against a fixture realm: privacy modes, the character
schema (docs/ARMORY.md), the guild contract (docs/ARMORY_GUILDS.md), incremental and idempotent
runs, community realm merging, the host agent's CLI adapter, publishing plans and the snapshot.

    python3 -m unittest tests.test_armory_export -v

The fixture runs in SQLite (always) and, when mariadbd is installed, also in a private MariaDB with
the real CMaNGOS DDL for characters/item_template (devkit/db/fixtures) and the pending SQL applied
twice (realm/classicplus/classicplus_characters.sql + pending/classicplus_armory.sql).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import armory_export as AE  # noqa: E402
import armory_fixture as F  # noqa: E402

CLASS_TOKENS = {"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"}
PROFS = {"Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Herbalism", "Leatherworking", "Mining", "Skinning",
         "Tailoring", "Cooking", "First Aid", "Fishing"}
ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
DAY = re.compile(r"^\d{4}-\d\d-\d\d$")
SECRET_STRINGS = ("secret motd", "officer note", "public note")


def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def all_text(d):
    out = []
    for root, _, files in os.walk(d):
        for fn in files:
            if fn.endswith(".json") and not fn.startswith(".armory-state"):
                with open(os.path.join(root, fn), encoding="utf-8") as f:
                    out.append(f.read())
    return "\n".join(out)


# ---- the guild contract, as docs/ARMORY_GUILDS.md states it ------------------------------------

def check_guild_index(t, gi):
    t.assertEqual(gi["schema"], 1)
    t.assertRegex(gi["generated"], ISO)
    for r in gi["realms"]:
        t.assertRegex(r["realm"], r"^[a-z0-9-]{1,64}$")
        t.assertIsInstance(r["name"], str)
        prev = None
        for g in r["guilds"]:
            t.assertLessEqual(set(g), {"slug", "name", "faction", "leader", "members", "level60", "achievementPoints", "created"})
            t.assertRegex(g["slug"], r"^[a-z0-9-]{1,64}$")
            t.assertIn(g["faction"], ("Alliance", "Horde"))
            if "leader" in g:
                t.assertIsInstance(g["leader"], str)
                t.assertTrue(g["leader"])
            for k in ("members", "level60", "achievementPoints"):
                t.assertIsInstance(g[k], int)
            if "created" in g:
                t.assertRegex(g["created"], DAY)
            if prev:
                t.assertTrue((-prev["members"], prev["name"]) <= (-g["members"], g["name"]), "sorted by members, name")
            prev = g


def check_guild(t, d, realm):
    t.assertEqual(d["schema"], 1)
    t.assertRegex(d["generated"], ISO)
    t.assertEqual(d["realm"], realm)
    t.assertEqual(d["slug"], AE.slugify(d["name"]) if not re.search(r"-\d+$", d["slug"]) else d["slug"])
    t.assertIn(d["faction"], ("Alliance", "Horde"))
    if "created" in d:
        t.assertRegex(d["created"], DAY)
    if "info" in d:
        t.assertLessEqual(len(d["info"]), 500)
        t.assertTrue(d["info"])
    t.assertNotIn("motd", d)
    ranks = {r["index"]: r["name"] for r in d["ranks"]}
    t.assertIn(0, ranks)
    t.assertLessEqual(set(d), {"schema", "generated", "realm", "realmName", "name", "slug", "faction", "created", "leader",
                               "info", "ranks", "members", "totals", "recentAchievements"})
    full = {"name", "level", "class", "race", "rank", "rankName", "online", "lastSeen", "achievementPoints", "professions"}
    limited = {"name", "level", "class", "rank", "rankName", "limited"}
    for m in d["members"]:
        t.assertIn(m["class"], CLASS_TOKENS)
        t.assertEqual(m["rankName"], ranks.get(m["rank"], m["rankName"]))
        if m.get("limited"):
            t.assertEqual(set(m), limited)
        else:
            t.assertLessEqual(set(m), full)
            t.assertTrue({"name", "level", "class", "race", "rank", "rankName", "online", "achievementPoints", "professions"} <= set(m))
            if m["online"]:
                t.assertNotIn("lastSeen", m)
            else:
                t.assertRegex(m["lastSeen"], ISO)
            skills = [p["skill"] for p in m["professions"]]
            t.assertEqual(skills, sorted(skills, reverse=True))
            for p in m["professions"]:
                t.assertIn(p["name"], PROFS)
    keys = [(m["rank"], -m["level"], m["name"]) for m in d["members"]]
    t.assertEqual(keys, sorted(keys), "members sorted by rank, level desc, name")
    tot = d["totals"]
    t.assertEqual(set(tot), {"members", "listed", "private", "level60", "averageLevel", "achievementPoints", "classes", "professions"})
    t.assertEqual(tot["listed"], len(d["members"]))
    t.assertEqual(tot["members"], tot["listed"] + tot["private"])
    t.assertEqual(sum(tot["classes"].values()), tot["members"])
    t.assertEqual(tot["achievementPoints"], sum(m.get("achievementPoints", 0) for m in d["members"] if not m.get("limited")))
    t.assertIsInstance(tot["averageLevel"], (int, float))
    t.assertEqual(round(tot["averageLevel"], 1), tot["averageLevel"])
    ra = d["recentAchievements"]
    t.assertLessEqual(len(ra), 10)
    for a in ra:
        t.assertEqual(set(a), {"id", "name", "icon", "points", "member", "date"})
    t.assertEqual([a["date"] for a in ra], sorted([a["date"] for a in ra], reverse=True))


def check_character(t, d):
    """docs/ARMORY.md, character file."""
    t.assertEqual(d["schema"], 1)
    for k in ("generated", "realm", "realmName", "name", "level", "class", "race", "gender", "faction", "privacy", "online",
              "honor", "equipment", "achievements", "professions"):
        t.assertIn(k, d)
    t.assertIn(d["class"], CLASS_TOKENS)
    t.assertIn(d["privacy"], ("public", "friends"))
    for it in d["equipment"]:
        t.assertIn(it["slot"], AE.SLOTS)
        t.assertEqual(AE.SLOTS[it["slotId"]], it["slot"])
        t.assertIsInstance(it["name"], str)
        t.assertIn(it["quality"], range(7))
    for s in d.get("talents", []):
        t.assertEqual(len(s["points"]), len(s["trees"]))
        for tr, p in zip(s["trees"], s["points"]):
            t.assertEqual(sum(x["rank"] for x in tr["talents"]), p)
            for x in tr["talents"]:
                t.assertLessEqual(x["rank"], x["max"])
    t.assertEqual(d["achievements"]["points"], sum(a["points"] for a in d["achievements"]["list"]))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="armory-")
        self.out = os.path.join(self.tmp, "armory")
        self.dbc = F.make_dbcs(os.path.join(self.tmp, "dbc"))
        self.conn = F.sqlite_db()
        self.db = AE.SqliteDb(self.conn)

    def tearDown(self):
        self.conn.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_export(self, **kw):
        kw.setdefault("realm", "classicplus")
        kw.setdefault("realm_name", "Open Vanilla Classic+")
        kw.setdefault("now", F.NOW)
        ex = AE.Exporter(self.db, self.out, game=AE.GameData(self.dbc), **kw)
        return ex.run()

    def p(self, *parts):
        return os.path.join(self.out, *parts)

    def sql(self, s, args=()):
        self.conn.execute(s.replace("%s", "?"), args)
        self.conn.commit()


class FullExport(Base):
    def test_files_and_privacy(self):
        res = self.run_export()
        self.assertEqual(res["characters"], 6, "bot account and deleted character left out")
        self.assertTrue(os.path.exists(self.p("classicplus", "aldric.json")))
        self.assertTrue(os.path.exists(self.p("classicplus", "dara.json")))
        self.assertFalse(os.path.exists(self.p("classicplus", "berra.json")), "friends-only has no public file")
        self.assertTrue(os.path.exists(self.p("classicplus", f"berra~{F.BERRA_KEY}.json")))
        self.assertFalse(any(n.startswith("corvin") for n in os.listdir(self.p("classicplus"))), "hidden: nothing")
        self.assertFalse(any(n.startswith("botter") or n.startswith("gone") for n in os.listdir(self.p("classicplus"))))
        idx = load(self.p("classicplus", "index.json"))
        names = [c["name"] for c in idx["characters"]]
        self.assertEqual(names, ["Aldric", "Dara", "Eira", "Grom"])
        self.assertEqual(idx["aliases"], ["open-vanilla-classic"])
        text = all_text(self.out)
        for s in SECRET_STRINGS:
            self.assertNotIn(s, text, "never export motd or notes")
        self.assertNotIn("Corvin", json.dumps(load(self.p("classicplus", "rankings.json"))))
        self.assertNotIn("Berra", json.dumps(load(self.p("classicplus", "rankings.json"))))
        # the friends file says what it is
        b = load(self.p("classicplus", f"berra~{F.BERRA_KEY}.json"))
        self.assertEqual(b["privacy"], "friends")
        check_character(self, b)

    def test_character_detail(self):
        self.run_export()
        d = load(self.p("classicplus", "aldric.json"))
        check_character(self, d)
        self.assertEqual((d["class"], d["race"], d["faction"], d["level"]), ("WARRIOR", "Human", "Alliance", 60))
        self.assertEqual(d["guild"], {"name": "Ashen Vanguard", "slug": "ashen-vanguard", "rank": 0, "rankName": "Guild Master"})
        self.assertEqual(d["lastSeen"], AE.iso(F.NOW - 2 * F.DAY))
        eq = {i["slot"]: i for i in d["equipment"]}
        self.assertEqual(set(eq), {"head", "chest", "mainhand", "finger1"}, "bags are not equipment")
        head = eq["head"]
        self.assertEqual(head["icon"], "INV_Helmet_03")
        self.assertEqual(head["enchant"], "+10 Stamina")
        self.assertEqual(head["stats"], [{"stat": "Stamina", "value": 15}, {"stat": "Strength", "value": 12}])
        self.assertEqual(head["effects"], [{"trigger": "Equip", "text": "Increased Defense"}])
        self.assertEqual(head["set"], {"id": 990, "name": "Battlegear of Valor", "equipped": 2, "pieces": 4})
        self.assertEqual((head["armor"], head["subType"], head["invType"], head["qualityName"]), (528, "Plate", "Head", "rare"))
        sword = eq["mainhand"]
        self.assertEqual(sword["damage"], {"min": 229, "max": 344, "speed": 3.5, "dps": 81.9})
        self.assertEqual(sword["resist"], {"fire": 10})
        self.assertEqual(sword["enchant"], "Crusader")
        ring = eq["finger1"]
        self.assertTrue(ring["name"].endswith(" of the Monkey"))
        self.assertEqual(ring["randomStats"], ["+7 Agility", "+7 Stamina"])
        self.assertEqual(ring["bonding"], "Binds when equipped")
        # professions, highest first; weapon skills are not professions
        self.assertEqual([(p["name"], p["skill"]) for p in d["professions"]],
                         [("Blacksmithing", 300), ("Mining", 285), ("Cooking", 120)])
        # reputations: visible ones, base from the DBC added
        reps = {r["name"]: r for r in d["reputations"]}
        self.assertEqual(set(reps), {"Stormwind", "Ironforge"})
        self.assertEqual((reps["Stormwind"]["value"], reps["Stormwind"]["standing"], reps["Stormwind"]["progress"]),
                         (12600, "Honored", 3600))
        self.assertEqual(reps["Ironforge"]["standing"], "Friendly")
        # honor
        self.assertEqual(d["honor"]["honorableKills"], 1205)
        self.assertEqual(d["honor"]["highestRankName"], "Knight-Captain")
        # achievements newest first, points summed
        self.assertEqual([a["id"] for a in d["achievements"]["list"]], [412, 6])
        self.assertEqual(d["achievements"]["points"], 50)
        self.assertEqual(d["achievements"]["list"][0]["icon"], "INV_Misc_Head_Dragon_01")
        # both specs
        specs = {s["index"]: s for s in d["talents"]}
        self.assertEqual((specs[1]["name"], specs[1]["active"], specs[1]["points"]), ("Arms", True, [4, 2, 0]))
        self.assertEqual((specs[2]["name"], specs[2]["active"], specs[2]["points"]), ("Fury", False, [1, 5, 0]))
        ihs = specs[1]["trees"][0]["talents"][0]
        self.assertEqual((ihs["name"], ihs["rank"], ihs["max"], ihs["icon"]), ("Improved Heroic Strike", 3, 3, "Ability_Rogue_Ambush"))
        self.assertEqual(d["stats"]["health"], 5400)
        self.assertEqual(d["stats"]["dodge"], 7.5)
        # online character: no lastSeen
        dara = load(self.p("classicplus", "dara.json"))
        self.assertTrue(dara["online"])
        self.assertNotIn("lastSeen", dara)
        self.assertNotIn("guild", dara)

    def test_without_dbc_or_optional_tables(self):
        for t in ("openvanilla_character", "openvanilla_spec", "character_achievement", "openvanilla_realm_first", "character_stats",
                  "character_honor_cp"):
            self.sql(f"DROP TABLE classiccharacters.{t}")
        self.sql("DROP TABLE classicmangos.spell_template")
        ex = AE.Exporter(self.db, self.out, realm="classicplus", now=F.NOW, game=AE.GameData(None))
        res = ex.run()
        self.assertEqual(ex.realm_name, "Vanilla Reloaded", "display name from the realmlist")
        self.assertEqual(res["characters"], 6)
        d = load(self.p("classicplus", "aldric.json"))
        check_character(self, d)
        self.assertNotIn("talents", d)
        self.assertNotIn("reputations", d)
        self.assertNotIn("icon", d["equipment"][0])
        self.assertEqual(d["achievements"], {"points": 0, "count": 0, "list": []})
        self.assertTrue(os.path.exists(self.p("classicplus", "berra.json")), "no privacy table: everyone is public")
        self.assertFalse(os.path.exists(self.p("classicplus", "firsts.json")))

    def test_rankings_and_firsts(self):
        self.run_export()
        r = load(self.p("classicplus", "rankings.json"))
        self.assertEqual([e["name"] for e in r["level"]], ["Eira", "Aldric", "Grom", "Dara"], "ties: more points first")
        self.assertEqual([(e["name"], e["points"]) for e in r["achievementPoints"]], [("Eira", 75), ("Aldric", 50)])
        self.assertEqual([(e["name"], e["kills"]) for e in r["honorableKills"]][:2], [("Aldric", 1205), ("Grom", 400)])
        self.assertEqual([e["name"] for e in r["professions"]["Mining"]], ["Aldric"])
        self.assertNotIn("Tailoring", r["professions"], "Corvin is hidden")
        self.assertEqual(r["level"][1]["guild"], "Ashen Vanguard")
        f = load(self.p("classicplus", "firsts.json"))["firsts"]
        self.assertEqual([x["id"] for x in f], [6, 412, 500])
        self.assertEqual(f[0]["character"], "Eira")
        self.assertTrue(f[2]["private"])
        self.assertNotIn("character", f[2], "hidden Corvin's first is not named")


class Guilds(Base):
    def test_contract(self):
        self.run_export()
        gi = load(self.p("guilds.json"))
        check_guild_index(self, gi)
        self.assertEqual([r["realm"] for r in gi["realms"]], ["classicplus"])
        rows = gi["realms"][0]["guilds"]
        self.assertEqual([g["slug"] for g in rows], ["ashen-vanguard", "knights-of-ni", "knights-of-ni-12"])
        ash = rows[0]
        self.assertEqual(ash, {"slug": "ashen-vanguard", "name": "Ashen Vanguard", "faction": "Alliance", "leader": "Aldric",
                               "members": 3, "level60": 2, "achievementPoints": 50, "created": AE.day(F.NOW - 200 * F.DAY)})
        self.assertEqual(rows[1]["faction"], "Horde")
        for g in rows:
            check_guild(self, load(self.p("classicplus", "guilds", g["slug"] + ".json")), "classicplus")
        d = load(self.p("classicplus", "guilds", "ashen-vanguard.json"))
        self.assertEqual([m["name"] for m in d["members"]], ["Aldric", "Berra"], "hidden Corvin is not listed")
        self.assertEqual(d["members"][1], {"name": "Berra", "level": 41, "class": "HUNTER", "rank": 4, "rankName": "Initiate",
                                           "limited": True})
        self.assertEqual(d["totals"], {"members": 3, "listed": 2, "private": 1, "level60": 2, "averageLevel": 53.7,
                                       "achievementPoints": 50, "classes": {"WARRIOR": 1, "HUNTER": 1, "MAGE": 1},
                                       "professions": {"Blacksmithing": 1, "Mining": 1, "Cooking": 1}})
        self.assertEqual([a["id"] for a in d["recentAchievements"]], [412, 6])
        self.assertEqual(d["recentAchievements"][0]["member"], "Aldric")
        self.assertEqual(d["info"], "Raids MC/BWL Tue and Thu 20:00 server time.")
        self.assertEqual(d["leader"], "Aldric")
        k = load(self.p("classicplus", "guilds", "knights-of-ni.json"))
        self.assertEqual(k["name"], "<Knights of Ni!>")
        self.assertNotIn("info", k, "empty info is omitted")

    def test_hidden_leader_and_disbanded_guild(self):
        self.run_export()
        self.sql("UPDATE classiccharacters.openvanilla_character SET armory='hidden' WHERE guid=1")
        self.sql("DELETE FROM classiccharacters.guild_member WHERE guildid=12")
        self.run_export()
        gi = load(self.p("guilds.json"))
        ash = gi["realms"][0]["guilds"][0]
        self.assertNotIn("leader", ash, "leader omitted (not null) when the guild master is hidden")
        d = load(self.p("classicplus", "guilds", "ashen-vanguard.json"))
        self.assertNotIn("leader", d)
        self.assertEqual(d["totals"]["private"], 2)
        self.assertEqual(d["totals"]["achievementPoints"], 0)
        self.assertEqual(d["recentAchievements"], [], "only public members' achievements")
        self.assertFalse(os.path.exists(self.p("classicplus", "guilds", "knights-of-ni-12.json")), "empty guild removed")
        self.assertFalse(os.path.exists(self.p("classicplus", "aldric.json")))
        check_guild_index(self, gi)


class Incremental(Base):
    def test_idempotent_and_dry_run(self):
        self.run_export()
        res = self.run_export(now=F.NOW + 600)
        self.assertEqual((res["exported"], res["written"], res["deleted"]), (0, [], []), "nothing new: nothing written")
        self.sql("UPDATE classiccharacters.characters SET level=31, logout_time=%s WHERE guid=4", (F.NOW + 100,))
        before = load(self.p("classicplus", "dara.json"))
        res = self.run_export(now=F.NOW + 1200, dry_run=True)
        self.assertEqual(res["exported"], 1)
        self.assertIn("classicplus/dara.json", res["written"])
        self.assertEqual(load(self.p("classicplus", "dara.json")), before, "dry run writes nothing")
        res = self.run_export(now=F.NOW + 1200)
        self.assertEqual(res["exported"], 1, "only the character whose logout changed")
        self.assertEqual(load(self.p("classicplus", "dara.json"))["level"], 31)
        self.assertIn("classicplus/index.json", res["written"])
        self.assertNotIn("guilds.json", res["written"], "Dara has no guild: the guild index is untouched")

    def test_privacy_switches_and_renames(self):
        self.run_export()
        friends = self.p("classicplus", f"berra~{F.BERRA_KEY}.json")
        # friends -> public: the secret file goes, the public one comes
        self.sql("UPDATE classiccharacters.openvanilla_character SET armory='public' WHERE guid=2")
        res = self.run_export(now=F.NOW + 600)
        self.assertEqual(res["exported"], 1)
        self.assertFalse(os.path.exists(friends))
        self.assertTrue(os.path.exists(self.p("classicplus", "berra.json")))
        self.assertIn("Berra", [c["name"] for c in load(self.p("classicplus", "index.json"))["characters"]])
        # public -> friends with a new key
        self.sql("UPDATE classiccharacters.openvanilla_character SET armory='friends', armory_key='newkey00000000000000' WHERE guid=2")
        self.run_export(now=F.NOW + 1200)
        self.assertFalse(os.path.exists(self.p("classicplus", "berra.json")))
        self.assertTrue(os.path.exists(self.p("classicplus", "berra~newkey00000000000000.json")))
        # a broken key: treated as hidden
        self.sql("UPDATE classiccharacters.openvanilla_character SET armory_key='x' WHERE guid=2")
        self.run_export(now=F.NOW + 1800)
        self.assertFalse(any(n.startswith("berra") for n in os.listdir(self.p("classicplus"))))
        # a rename while logged out (the logout time stays)
        self.sql("UPDATE classiccharacters.characters SET name='Aldrik' WHERE guid=1")
        self.run_export(now=F.NOW + 2400)
        self.assertFalse(os.path.exists(self.p("classicplus", "aldric.json")))
        self.assertTrue(os.path.exists(self.p("classicplus", "aldrik.json")))
        # deleted character
        self.sql("DELETE FROM classiccharacters.characters WHERE guid=4")
        res = self.run_export(now=F.NOW + 3000)
        self.assertIn("classicplus/dara.json", res["deleted"])

    def test_login_and_logout_reexport(self):
        self.run_export()
        self.sql("UPDATE classiccharacters.characters SET online=1 WHERE guid=6")
        res = self.run_export(now=F.NOW + 600)
        self.assertEqual(res["exported"], 1)
        g = load(self.p("classicplus", "guilds", "knights-of-ni.json"))
        self.assertTrue(g["members"][0]["online"])
        self.assertNotIn("lastSeen", g["members"][0])


class Community(Base):
    def test_merge_community_realms(self):
        host = "abcdefghijklmnop"
        os.makedirs(self.p(host))
        with open(self.p(host, "index.json"), "w") as f:
            json.dump({"schema": 1, "generated": "2026-10-15T10:00:00Z", "realm": host, "name": "Stormwind Nights",
                       "community": False, "aliases": ["stormwind-nights", "BAD ALIAS"], "characters": [{"name": "X"}],
                       "guilds": [{"slug": "night-watch", "name": "Night Watch", "faction": "Horde", "members": 4,
                                   "level60": 1, "achievementPoints": 10, "leader": "Zed"},
                                  {"slug": "../evil", "name": "Evil"}]}, f)
        os.makedirs(self.p("not a realm"))
        self.run_export()
        idx = load(self.p("index.json"))
        self.assertEqual([r["realm"] for r in idx["realms"]], ["classicplus", host])
        comm = idx["realms"][1]
        self.assertTrue(comm["community"], "an upload folder (host id) is always a community realm")
        self.assertEqual(comm["aliases"], ["stormwind-nights"])
        self.assertEqual(comm["characters"], 1)
        gi = load(self.p("guilds.json"))
        check_guild_index(self, gi)
        self.assertEqual([g["slug"] for g in gi["realms"][1]["guilds"]], ["night-watch"])

    def test_upload_store_is_copied_json_only(self):
        store = os.path.join(self.tmp, "uploads")
        host = "qrstuvwxyz234567"
        os.makedirs(os.path.join(store, host, "guilds"))
        os.makedirs(os.path.join(store, host, "deep", "er"))
        os.makedirs(os.path.join(store, "Not-A-Host"))
        files = {"index.json": {"schema": 1, "name": "Host Realm", "characters": [], "guilds": []},
                 "zed.json": {"schema": 1, "name": "Zed"}, "guilds/night-watch.json": {"schema": 1},
                 "deep/er/x.json": {"a": 1}}
        for rel, obj in files.items():
            with open(os.path.join(store, host, rel), "w") as f:
                json.dump(obj, f)
        with open(os.path.join(store, host, "evil.html"), "w") as f:
            f.write("<script>")
        with open(os.path.join(store, host, "broken.json"), "w") as f:
            f.write("{not json")
        with open(os.path.join(store, "Not-A-Host", "index.json"), "w") as f:
            json.dump({"schema": 1}, f)
        self.run_export(community_dir=store)
        got = sorted(os.path.relpath(os.path.join(r, f), self.p(host)) for r, _, fs in os.walk(self.p(host)) for f in fs)
        self.assertEqual(got, ["guilds/night-watch.json", "index.json", "zed.json"])
        self.assertFalse(os.path.exists(self.p("Not-A-Host")))
        self.assertIn(host, [r["realm"] for r in load(self.p("index.json"))["realms"]])
        os.remove(os.path.join(store, host, "zed.json"))
        self.run_export(community_dir=store, now=F.NOW + 600)
        self.assertFalse(os.path.exists(self.p(host, "zed.json")), "a file gone from the upload goes from the site")
        shutil.rmtree(os.path.join(store, host))
        self.run_export(community_dir=store, now=F.NOW + 1200)
        self.assertFalse(os.path.exists(self.p(host, "index.json")), "a removed realm leaves the site")
        self.assertEqual([r["realm"] for r in load(self.p("index.json"))["realms"]], ["classicplus"])

    def test_community_export_writes_no_root_files(self):
        res = self.run_export(realm="abcdefghijklmnop", realm_name="Stormwind Nights", community=True)
        self.assertNotIn("index.json", res["written"])
        self.assertNotIn("guilds.json", res["written"])
        self.assertTrue(load(self.p("abcdefghijklmnop", "index.json"))["community"])


class Adapters(unittest.TestCase):
    def test_cli_db(self):
        seen = []

        def query(sql):
            seen.append(sql)
            return "1\tAl\\tdric\tNULL\t-5\n2\tB\\\\x\t3.5\t0\n"
        db = AE.CliDb(query)
        rows = db.rows("SELECT a FROM t WHERE n = %s AND m = %s", ("O'Brien\\", 7))
        self.assertIn("n = 'O\\'Brien\\\\' AND m = 7", seen[0])
        self.assertEqual(rows, [(1, "Al\tdric", None, -5), (2, "B\\x", "3.5", 0)])
        with self.assertRaises(ValueError):
            db.rows("SELECT %s", ())

    def test_slugify(self):
        self.assertEqual(AE.slugify("Ashen Vanguard"), "ashen-vanguard")
        self.assertEqual(AE.slugify("<Knights of Ni!>"), "knights-of-ni")
        self.assertEqual(AE.slugify("Vanilla Reloaded"), "vanilla-reloaded")
        self.assertEqual(AE.slugify("Über"), "ber")

    def test_rep_levels(self):
        self.assertEqual(AE.rep_level(0), ("Neutral", 0, 3000))
        self.assertEqual(AE.rep_level(-1), ("Unfriendly", 2999, 3000))
        self.assertEqual(AE.rep_level(42999), ("Exalted", 999, 1000))
        self.assertEqual(AE.rep_level(-50000)[0], "Hated")

    def test_publish_plans(self):
        env = {"ARMORY_R2_ENDPOINT": "https://acc.r2.cloudflarestorage.com", "ARMORY_R2_BUCKET": "site",
               "AWS_ACCESS_KEY_ID": "AKID", "AWS_SECRET_ACCESS_KEY": "secret"}
        plan = AE.publish_r2("/x", ["a/b.json"], ["a/c.json"], env=env, dry=True)
        self.assertEqual(plan, [("PUT", "a/b.json"), ("DELETE", "a/c.json")])
        with self.assertRaises(SystemExit):
            AE.publish_r2("/x", [], [], env={}, dry=True)
        h = AE.s3_sign("PUT", "https://acc.r2.cloudflarestorage.com/site/armory/a.json", b"{}", "AKID", "secret", now=F.NOW)
        self.assertTrue(h["authorization"].startswith("AWS4-HMAC-SHA256 Credential=AKID/"))
        self.assertIn("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date", h["authorization"])
        self.assertEqual(h, AE.s3_sign("PUT", "https://acc.r2.cloudflarestorage.com/site/armory/a.json", b"{}", "AKID",
                                       "secret", now=F.NOW), "deterministic")
        with self.assertRaises(SystemExit):
            AE.publish_git("/x", env={}, dry=True)


class Publish(Base):
    def test_sync_keeps_pages(self):
        self.run_export()
        dest = os.path.join(self.tmp, "site", "armory")
        os.makedirs(dest)
        with open(os.path.join(dest, "character.html"), "w") as f:
            f.write("page")
        with open(os.path.join(dest, "stale.json"), "w") as f:
            f.write("{}")
        AE.sync_json(self.out, dest)
        self.assertTrue(os.path.exists(os.path.join(dest, "character.html")))
        self.assertFalse(os.path.exists(os.path.join(dest, "stale.json")))
        self.assertTrue(os.path.exists(os.path.join(dest, "classicplus", "aldric.json")))
        self.assertFalse(any(f.startswith(".armory-state") for f in os.listdir(dest)))


class Snapshot(Base):
    def test_daily_zip_has_no_friends_files(self):
        self.run_export()
        snap = os.path.join(self.tmp, "snap")
        z = AE.torrent_snapshot(self.out, snap, now=F.NOW, env={})
        import zipfile
        names = zipfile.ZipFile(z).namelist()
        self.assertIn("classicplus/aldric.json", names)
        self.assertFalse(any("~" in n for n in names))
        self.assertTrue(os.path.exists(z + ".torrent"))
        self.assertIsNone(AE.torrent_snapshot(self.out, snap, now=F.NOW, env={}), "once a day")


# ---- MariaDB with the real CMaNGOS DDL ---------------------------------------------------------

def _mariadb():
    srv = shutil.which("mariadbd") or shutil.which("mysqld")
    inst = shutil.which("mariadb-install-db") or shutil.which("mysql_install_db")
    if not srv or not inst or os.environ.get("ARMORY_SKIP_MARIADB"):
        return None
    try:
        import pymysql  # noqa: F401
    except ImportError:
        return None
    return srv, inst


@unittest.skipUnless(_mariadb(), "needs mariadbd + pymysql")
class MariaDB(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        srv, inst = _mariadb()
        cls.d = tempfile.mkdtemp(prefix="armory-db-")
        cls.sock = os.path.join(cls.d, "s.sock")
        user = os.environ.get("USER", "root")
        subprocess.run([inst, f"--datadir={cls.d}/data", "--auth-root-authentication-method=normal", "--skip-test-db",
                        "--user=" + user], check=True, capture_output=True)
        cls.proc = subprocess.Popen([srv, f"--datadir={cls.d}/data", f"--socket={cls.sock}", "--skip-networking",
                                     "--user=" + user, "--innodb-buffer-pool-size=16M", "--innodb-log-file-size=8M"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        import pymysql
        for _ in range(60):
            try:
                cls.conn = pymysql.connect(unix_socket=cls.sock, user="root", charset="utf8mb4", autocommit=True)
                break
            except Exception:
                time.sleep(0.5)
        else:
            raise unittest.SkipTest("mariadbd did not start")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()
        cls.proc.terminate()
        cls.proc.wait()
        shutil.rmtree(cls.d, ignore_errors=True)

    def run_sql_file(self, path, db):
        cli = shutil.which("mariadb") or shutil.which("mysql")
        with open(path, "rb") as f:
            r = subprocess.run([cli, "-uroot", f"--socket={self.sock}", db], stdin=f, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr.decode()[:500])

    def test_real_schema_and_pending_sql(self):
        c = self.conn.cursor()
        for db in (F.CHARS, F.WORLD, F.REALMD):
            c.execute(f"CREATE DATABASE {db}")
        fx = os.path.join(ROOT, "devkit", "db", "fixtures")
        self.run_sql_file(os.path.join(fx, "classiccharacters.sql"), F.CHARS)     # real CMaNGOS characters DDL
        self.run_sql_file(os.path.join(fx, "classicmangos.sql"), F.WORLD)         # real item_template DDL + rows
        real = {(F.CHARS, "characters"), (F.WORLD, "item_template"), (F.CHARS, "openvanilla_character")}
        for (db, table), cols in F.TABLES.items():
            if (db, table) not in real:
                c.execute(f"CREATE TABLE {db}.{table} ({cols})")
        pend = os.path.join(ROOT, "realm", "classicplus", "pending")
        for _ in range(2):   # both files must be safe to run twice
            self.run_sql_file(os.path.join(ROOT, "realm", "classicplus", "classicplus_characters.sql"), F.WORLD)
            self.run_sql_file(os.path.join(pend, "classicplus_armory.sql"), F.WORLD)
        c.execute("SELECT COLUMN_NAME, COLUMN_DEFAULT FROM information_schema.columns WHERE table_schema='classiccharacters' "
                  "AND table_name='openvanilla_character' AND COLUMN_NAME LIKE 'armory%%' ORDER BY COLUMN_NAME")
        self.assertEqual([r[0] for r in c.fetchall()], ["armory", "armory_key"])
        for sql, args in F.rows():
            c.execute(sql, args)
        tmp = tempfile.mkdtemp(prefix="armory-out-")
        try:
            db = AE.PyMySQLDb(unix_socket=self.sock, user="root")
            ex = AE.Exporter(db, os.path.join(tmp, "armory"), realm="classicplus", realm_name="Open Vanilla Classic+", now=F.NOW,
                             game=AE.GameData(F.make_dbcs(os.path.join(tmp, "dbc"))))
            res = ex.run()
            self.assertEqual(res["characters"], 6)
            d = load(os.path.join(tmp, "armory", "classicplus", "aldric.json"))
            check_character(self, d)
            self.assertEqual(len(d["equipment"]), 4)
            self.assertEqual(d["talents"][0]["points"], [4, 2, 0])
            self.assertTrue(os.path.exists(os.path.join(tmp, "armory", "classicplus", f"berra~{F.BERRA_KEY}.json")))
            gi = load(os.path.join(tmp, "armory", "guilds.json"))
            check_guild_index(self, gi)
            res2 = AE.Exporter(db, os.path.join(tmp, "armory"), realm="classicplus", realm_name="Open Vanilla Classic+",
                               now=F.NOW + 60, game=AE.GameData(os.path.join(tmp, "dbc"))).run()
            self.assertEqual(res2["written"], [])
            # the host agent's CLI path reads the same thing
            cli = shutil.which("mariadb") or shutil.which("mysql")

            def q(sql):
                r = subprocess.run([cli, "-uroot", f"--socket={self.sock}", "--batch", "--skip-column-names"],
                                   input=sql, capture_output=True, text=True)
                if r.returncode:
                    raise RuntimeError(r.stderr)
                return r.stdout
            res3 = AE.Exporter(AE.CliDb(q), os.path.join(tmp, "cli"), realm="abcdefghijklmnop", realm_name="Host",
                               now=F.NOW, community=True, game=AE.GameData(os.path.join(tmp, "dbc"))).run()
            self.assertEqual(res3["characters"], 6)
            a = load(os.path.join(tmp, "cli", "abcdefghijklmnop", "aldric.json"))
            b = dict(d, realm=a["realm"], realmName=a["realmName"])
            self.assertEqual(a, b, "CLI and pymysql give the same character")
            db.conn.close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
