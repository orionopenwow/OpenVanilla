#!/usr/bin/env python3
"""Achievements: turn realm/achievements/achievements.yml into everything that uses it.

    python3 tools/gen_achievements.py            check the catalogue, then write the outputs below
    python3 tools/gen_achievements.py --check    check only (exit 1 on any problem)
    python3 tools/gen_achievements.py --refresh-ids --socket /path/mysql.sock --db classicmangos
                                                 re-snapshot the names of every referenced creature,
                                                 quest and item from a CMaNGOS classic world DB

Outputs
    Data/Interface/AddOns/Achievements/Data.lua          the addon's catalogue (Lua 5.0 table)
    realm/classicplus/pending/classicplus_achievements.sql   tables + catalogue for the world server
    www/achievements.json                                the website / armory catalogue

The self-check: every achievement id is unique and in its category's id block; names are unique;
points, categories, factions and classes are known; every criterion has a known type and its
parameters are in range; zone, skill, faction and battleground ids are real 1.12 ids (tables
below); creature, quest and item ids appear in realm/achievements/known_ids.json (a snapshot of
the CMaNGOS classic-db) and a kill criterion's name matches the creature's name there; meta
criteria point at existing achievements without cycles; icons are Interface\\ paths.
"""
import argparse
import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("gen_achievements.py needs PyYAML: python3 -m pip install pyyaml")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
YML = os.path.join(ROOT, "realm", "achievements", "achievements.yml")
KNOWN = os.path.join(ROOT, "realm", "achievements", "known_ids.json")
LUA_OUT = os.path.join(ROOT, "Data", "Interface", "AddOns", "Achievements", "Data.lua")
SQL_OUT = os.path.join(ROOT, "realm", "classicplus", "pending", "classicplus_achievements.sql")
JSON_OUT = os.path.join(ROOT, "www", "achievements.json")

# ---- real 1.12 ids --------------------------------------------------------------------------
ZONES = {  # AreaTable.dbc zone ids
    1: "Dun Morogh", 3: "Badlands", 4: "Blasted Lands", 8: "Swamp of Sorrows", 10: "Duskwood", 11: "Wetlands",
    12: "Elwynn Forest", 14: "Durotar", 15: "Dustwallow Marsh", 16: "Azshara", 17: "The Barrens", 28: "Western Plaguelands",
    33: "Stranglethorn Vale", 36: "Alterac Mountains", 38: "Loch Modan", 40: "Westfall", 41: "Deadwind Pass",
    44: "Redridge Mountains", 45: "Arathi Highlands", 46: "Burning Steppes", 47: "The Hinterlands", 51: "Searing Gorge",
    85: "Tirisfal Glades", 130: "Silverpine Forest", 139: "Eastern Plaguelands", 141: "Teldrassil", 148: "Darkshore",
    215: "Mulgore", 267: "Hillsbrad Foothills", 331: "Ashenvale", 357: "Feralas", 361: "Felwood", 400: "Thousand Needles",
    405: "Desolace", 406: "Stonetalon Mountains", 440: "Tanaris", 490: "Un'Goro Crater", 493: "Moonglade",
    618: "Winterspring", 1377: "Silithus",
}
SKILLS = {  # SkillLine.dbc
    129: "First Aid", 164: "Blacksmithing", 165: "Leatherworking", 171: "Alchemy", 182: "Herbalism", 185: "Cooking",
    186: "Mining", 197: "Tailoring", 202: "Engineering", 333: "Enchanting", 356: "Fishing", 393: "Skinning", 762: "Riding",
}
FACTIONS = {  # Faction.dbc
    21: "Booty Bay", 47: "Ironforge", 54: "Gnomeregan Exiles", 59: "Thorium Brotherhood", 68: "Undercity", 69: "Darnassus",
    72: "Stormwind", 76: "Orgrimmar", 81: "Thunder Bluff", 87: "Bloodsail Buccaneers", 270: "Zandalar Tribe",
    349: "Ravenholdt", 369: "Gadgetzan", 470: "Ratchet", 509: "League of Arathor", 510: "The Defilers", 529: "Argent Dawn",
    530: "Darkspear Trolls", 576: "Timbermaw Hold", 577: "Everlook", 589: "Wintersaber Trainers", 609: "Cenarion Circle",
    729: "Frostwolf Clan", 730: "Stormpike Guard", 749: "Hydraxian Waterlords", 809: "Shen'dralar", 889: "Warsong Outriders",
    890: "Silverwing Sentinels", 909: "Darkmoon Faire", 910: "Brood of Nozdormu",
}
BG_MAPS = {489: "Warsong Gulch", 529: "Arathi Basin", 30: "Alterac Valley"}
STANDINGS = {"hated": 0, "hostile": 1, "unfriendly": 2, "neutral": 3, "friendly": 4, "honored": 5, "revered": 6, "exalted": 7}
CLASSES = {"WARRIOR": 1, "PALADIN": 2, "HUNTER": 3, "ROGUE": 4, "PRIEST": 5, "SHAMAN": 7, "MAGE": 8, "WARLOCK": 9, "DRUID": 11}
FACTION_SIDE = {"alliance": 1, "horde": 2}
POINTS = {0, 5, 10, 15, 20, 25, 50}
# id blocks per category: ids are stable, and a block keeps related achievements together
BLOCKS = {"general": (1, 99), "quests": (100, 299), "exploration": (300, 399), "dungeons": (400, 499),
          "raids": (500, 749), "professions": (750, 809), "reputation": (810, 899), "pvp": (900, 999),
          "feats": (1000, 1199)}

# criterion type -> (server number, required params, optional params)
TYPES = {
    "level": (1, ["level"], []),
    "quests": (2, ["count"], []),
    "zone_quests": (3, ["zone", "alliance", "horde"], []),
    "quest": (4, [], ["quest", "quests"]),
    "explore": (5, ["zone"], []),
    "meta": (6, ["achievement"], []),
    "kill": (7, [], ["creature", "creatures", "count", "no_deaths", "within"]),
    "skill": (8, ["skill", "value"], []),
    "skills_at": (9, ["value", "count", "skills"], []),
    "reputation": (10, ["faction", "standing"], []),
    "exalted": (11, ["count"], []),
    "money": (12, ["gold"], []),
    "bags": (13, ["count", "slots"], []),
    "pets": (14, ["count"], []),
    "item": (15, [], ["item", "items"]),
    "honor_kills": (16, ["count"], []),
    "bg_wins": (17, ["map", "count"], []),
    "pvp_rank": (18, ["rank"], []),
}
COMMON = {"type", "name"}
FLAG_REALM_FIRST, FLAG_GROUP_FIRST, FLAG_FEAT = 1, 2, 4


def load():
    with open(YML, encoding="utf-8") as f:
        return yaml.safe_load(f)


def known_ids():
    if not os.path.exists(KNOWN):
        return None
    with open(KNOWN, encoding="utf-8") as f:
        d = json.load(f)
    return {k: {int(i): n for i, n in v.items()} for k, v in d.items() if isinstance(v, dict)}


def alts(c, one, many):
    if c.get(many) is not None:
        return list(c[many])
    if c.get(one) is not None:
        return [c[one]]
    return []


# ---- checks ---------------------------------------------------------------------------------
def check(data, known):
    errs = []
    cats = [c["key"] for c in data.get("categories", [])]
    if len(set(cats)) != len(cats):
        errs.append("duplicate category key")
    pets = data.get("lists", {}).get("pet_items", [])
    A = data.get("achievements", [])
    by_id = {}
    names = {}
    for a in A:
        where = "achievement %s" % a.get("id")
        for k in ("id", "name", "description", "points", "category", "icon", "criteria"):
            if a.get(k) in (None, "", []):
                errs.append("%s: missing %s" % (where, k))
        aid = a.get("id")
        if not isinstance(aid, int) or aid <= 0 or aid > 9999:
            errs.append("%s: id must be 1..9999" % where)
            continue
        if aid in by_id:
            errs.append("%s: duplicate id" % where)
        by_id[aid] = a
        key = (a.get("name"), a.get("faction"), tuple(a.get("classes") or ()))
        if key in names:
            errs.append("%s: same name as achievement %s (%s)" % (where, names[key], a.get("name")))
        names[key] = aid
        cat = a.get("category")
        if cat not in cats:
            errs.append("%s: unknown category %s" % (where, cat))
        elif cat in BLOCKS and not (BLOCKS[cat][0] <= aid <= BLOCKS[cat][1]):
            errs.append("%s: id outside the %s block %s" % (where, cat, BLOCKS[cat]))
        if a.get("points") not in POINTS:
            errs.append("%s: points %s not one of %s" % (where, a.get("points"), sorted(POINTS)))
        if cat == "feats" and a.get("points"):
            errs.append("%s: Feats of Strength give no points" % where)
        if cat != "feats" and not a.get("points"):
            errs.append("%s: only Feats of Strength may give 0 points" % where)
        if a.get("faction") not in (None, "alliance", "horde"):
            errs.append("%s: faction must be alliance or horde" % where)
        for cl in a.get("classes") or []:
            if cl not in CLASSES:
                errs.append("%s: unknown class %s" % (where, cl))
        icon = a.get("icon", "")
        if not re.match(r"^Interface\\[A-Za-z]+\\[A-Za-z0-9_]+$", icon or ""):
            errs.append("%s: icon must be an Interface\\...\\Name path, got %r" % (where, icon))
        if any(ch in (a.get("name", "") + a.get("description", "")) for ch in ";|\t\n"):
            errs.append("%s: name/description may not contain ; | tab or newline" % where)
        crit = a.get("criteria") or []
        if len(crit) > 99:
            errs.append("%s: at most 99 criteria" % where)
        need = a.get("need")
        if need is not None and not (1 <= need <= len(crit)):
            errs.append("%s: need must be 1..%d" % (where, len(crit)))
        for i, c in enumerate(crit):
            cw = "%s criterion %d" % (where, i + 1)
            t = c.get("type")
            if t not in TYPES:
                errs.append("%s: unknown type %s" % (cw, t))
                continue
            _, req, opt = TYPES[t]
            for k in req:
                if c.get(k) is None:
                    errs.append("%s: %s needs %s" % (cw, t, k))
            for k in c:
                if k not in COMMON and k not in req and k not in opt:
                    errs.append("%s: unexpected parameter %s for %s" % (cw, k, t))
            v = c.get
            if t == "level" and not (1 <= v("level", 0) <= 60):
                errs.append("%s: level 1..60" % cw)
            if t in ("zone_quests", "explore") and v("zone") not in ZONES:
                errs.append("%s: zone %s is not a 1.12 zone id" % (cw, v("zone")))
            if t == "zone_quests" and not (v("alliance") or v("horde")):
                errs.append("%s: zone_quests needs a count for at least one faction" % cw)
            if t == "zone_quests":
                if a.get("faction") == "alliance" and v("horde"):
                    errs.append("%s: alliance-only but has a horde count" % cw)
                if a.get("faction") == "horde" and v("alliance"):
                    errs.append("%s: horde-only but has an alliance count" % cw)
                if not a.get("faction") and not (v("alliance") and v("horde")):
                    errs.append("%s: both factions need a count unless the achievement has a faction" % cw)
            if t in ("skill",) and v("skill") not in SKILLS:
                errs.append("%s: skill %s is not a known SkillLine id" % (cw, v("skill")))
            if t == "skill" and not (1 <= v("value", 0) <= 300):
                errs.append("%s: skill value 1..300" % cw)
            if t == "skills_at":
                for s in v("skills") or []:
                    if s not in SKILLS:
                        errs.append("%s: skill %s unknown" % (cw, s))
                if not (1 <= v("count", 0) <= len(v("skills") or [])):
                    errs.append("%s: count must fit the skill list" % cw)
            if t == "reputation":
                if v("faction") not in FACTIONS:
                    errs.append("%s: faction %s is not a known Faction id" % (cw, v("faction")))
                if v("standing") not in STANDINGS:
                    errs.append("%s: standing %s unknown" % (cw, v("standing")))
            if t == "bg_wins" and v("map") not in BG_MAPS:
                errs.append("%s: map %s is not a battleground" % (cw, v("map")))
            if t == "pvp_rank" and not (1 <= v("rank", 0) <= 14):
                errs.append("%s: rank 1..14" % cw)
            if t in ("quests", "exalted", "honor_kills", "bg_wins", "pets", "bags") and not (1 <= v("count", 0) <= 1000000):
                errs.append("%s: count out of range" % cw)
            if t == "pets" and v("count", 0) > len(pets):
                errs.append("%s: more pets than lists.pet_items holds" % cw)
            if t == "bags" and not (1 <= v("count", 0) <= 4 and 1 <= v("slots", 0) <= 36):
                errs.append("%s: bags count 1..4, slots 1..36" % cw)
            if t == "money" and not (1 <= v("gold", 0) <= 200000):
                errs.append("%s: gold out of range" % cw)
            if t == "kill":
                ids = alts(c, "creature", "creatures")
                if not ids:
                    errs.append("%s: kill needs creature or creatures" % cw)
                if v("within") is not None and not (60 <= v("within") <= 4 * 3600):
                    errs.append("%s: within must be 60..14400 seconds" % cw)
                for e in ids:
                    if not (1 <= e <= 30000):
                        errs.append("%s: creature %s out of range" % (cw, e))
                    elif known is not None:
                        nm = known["creature"].get(e)
                        if nm is None:
                            errs.append("%s: creature %s is not in known_ids.json" % (cw, e))
                        elif len(ids) == 1 and c.get("name") and c["name"] != nm:
                            errs.append("%s: creature %s is %r, not %r" % (cw, e, nm, c["name"]))
            if t == "quest":
                ids = alts(c, "quest", "quests")
                if not ids:
                    errs.append("%s: quest needs quest or quests" % cw)
                for q in ids:
                    if not (1 <= q <= 30000):
                        errs.append("%s: quest %s out of range" % (cw, q))
                    elif known is not None and q not in known["quest"]:
                        errs.append("%s: quest %s is not in known_ids.json" % (cw, q))
            if t == "item":
                ids = alts(c, "item", "items")
                if not ids:
                    errs.append("%s: item needs item or items" % cw)
                for it in ids:
                    if known is not None and it not in known["item"]:
                        errs.append("%s: item %s is not in known_ids.json" % (cw, it))
    if known is not None:
        for it in pets:
            if it not in known["item"]:
                errs.append("lists.pet_items: item %s is not in known_ids.json" % it)
    if len(set(pets)) != len(pets):
        errs.append("lists.pet_items has duplicates")
    # meta references and cycles
    for a in A:
        for c in a.get("criteria") or []:
            if c.get("type") == "meta":
                ref = c.get("achievement")
                if ref not in by_id:
                    errs.append("achievement %s: meta points at unknown achievement %s" % (a.get("id"), ref))
                elif ref == a.get("id"):
                    errs.append("achievement %s: meta points at itself" % a.get("id"))
    seen, stack = set(), set()

    def visit(i):
        if i in stack:
            errs.append("meta cycle through achievement %s" % i)
            return
        if i in seen or i not in by_id:
            return
        stack.add(i)
        for c in by_id[i].get("criteria") or []:
            if c.get("type") == "meta":
                visit(c.get("achievement"))
        stack.discard(i)
        seen.add(i)
    for i in by_id:
        visit(i)
    return errs


# ---- derived fields --------------------------------------------------------------------------
def progress_info(a):
    """(goal_alliance, goal_horde, label) for a progress bar, or (None, None, None) for a plain yes/no."""
    crit = a["criteria"]
    if len(crit) > 1:
        n = a.get("need") or len(crit)
        kinds = set(c["type"] for c in crit)
        if kinds == {"meta"}:
            label = {"raids": "Bosses", "dungeons": "Dungeons", "exploration": "Zones"}.get(a["category"], "Achievements")
        else:
            label = "Bosses" if kinds == {"kill"} else "Steps"
        return n, n, label
    c = crit[0]
    t = c["type"]
    if t == "level":
        return c["level"], c["level"], "Level"
    if t == "quests":
        return c["count"], c["count"], "Quests"
    if t == "zone_quests":
        return c["alliance"] or None, c["horde"] or None, "Quests"
    if t == "skill":
        return c["value"], c["value"], SKILLS[c["skill"]]
    if t == "skills_at":
        return c["count"], c["count"], "Professions"
    if t == "exalted":
        return c["count"], c["count"], "Exalted"
    if t == "money":
        return c["gold"], c["gold"], "Gold"
    if t == "bags":
        return c["count"], c["count"], "Bags"
    if t == "pets":
        return c["count"], c["count"], "Pets"
    if t == "honor_kills" and c["count"] > 1:
        return c["count"], c["count"], "Honorable kills"
    if t == "bg_wins" and c["count"] > 1:
        return c["count"], c["count"], "Wins"
    if t == "kill" and (c.get("count") or 1) > 1:
        return c["count"], c["count"], "Kills"
    if t == "explore":
        return None, None, "Areas"          # the server sends the goal with the progress
    return None, None, None


def crit_label(c):
    if c.get("name"):
        return c["name"]
    t = c["type"]
    if t in ("explore", "zone_quests"):
        return ZONES[c["zone"]]
    if t == "reputation":
        return FACTIONS[c["faction"]]
    if t == "skill":
        return "%s %d" % (SKILLS[c["skill"]], c["value"])
    if t == "bg_wins":
        return BG_MAPS[c["map"]]
    return ""


def flags(a):
    f = 0
    if a.get("realm_first"):
        f |= FLAG_REALM_FIRST
    if a.get("group_first"):
        f |= FLAG_GROUP_FIRST
    if a["category"] == "feats":
        f |= FLAG_FEAT
    return f


def class_mask(a):
    m = 0
    for cl in a.get("classes") or []:
        m |= 1 << (CLASSES[cl] - 1)
    return m


# ---- Lua -------------------------------------------------------------------------------------
def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_lua(data):
    out = []
    w = out.append
    w("-- Achievements/Data.lua: the achievement catalogue.")
    w("-- GENERATED by tools/gen_achievements.py from realm/achievements/achievements.yml; do not edit.")
    w("-- Fields: id, n name, d description, p points, c category, i icon, f faction (\"Alliance\"/\"Horde\"),")
    w("-- cl classes {TOKEN=true}, rf realm first, ga/gh progress goal (Alliance/Horde), pl progress label,")
    w("-- k kind of a single criterion (level, skill, money, ...), kv its main value (skill id, ...),")
    w("-- cr criteria { {id, label, meta = achievement id} }.")
    w("")
    w("Achievements_Data = {")
    w("    version = %d," % data.get("version", 1))
    w("    categories = {")
    for c in data["categories"]:
        w("        { key = %s, name = %s, icon = %s }," % (lua_str(c["key"]), lua_str(c["name"]), lua_str(c["icon"])))
    w("    },")
    w("    list = {")
    for a in data["achievements"]:
        ga, gh, pl = progress_info(a)
        parts = ["id = %d" % a["id"], "n = %s" % lua_str(a["name"]), "d = %s" % lua_str(a["description"]),
                 "p = %d" % a["points"], "c = %s" % lua_str(a["category"]), "i = %s" % lua_str(a["icon"])]
        if a.get("faction"):
            parts.append("f = %s" % lua_str(a["faction"].capitalize()))
        if a.get("classes"):
            parts.append("cl = { %s }" % ", ".join("%s = true" % c for c in a["classes"]))
        if a.get("realm_first"):
            parts.append("rf = true")
        if ga:
            parts.append("ga = %d" % ga)
        if gh:
            parts.append("gh = %d" % gh)
        if pl:
            parts.append("pl = %s" % lua_str(pl))
        crit = a["criteria"]
        if len(crit) == 1:
            c = crit[0]
            parts.append("k = %s" % lua_str(c["type"]))
            kv = c.get("skill") or c.get("faction") or c.get("map") or c.get("zone")
            if kv:
                parts.append("kv = %d" % kv)
        if len(crit) > 1:
            cr = []
            for i, c in enumerate(crit):
                cid = a["id"] * 100 + i + 1
                item = "{ id = %d, label = %s" % (cid, lua_str(crit_label(c)))
                if c["type"] == "meta":
                    item += ", meta = %d" % c["achievement"]
                cr.append(item + " }")
            parts.append("cr = { %s }" % ", ".join(cr))
        w("        { %s }," % ", ".join(parts))
    w("    },")
    w("}")
    os.makedirs(os.path.dirname(LUA_OUT), exist_ok=True)
    with open(LUA_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")


# ---- SQL -------------------------------------------------------------------------------------
def sql_str(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "''") + "'"


def criteria_rows(a, pets):
    """(criteria id, alt, type, value1, value2, value3, count, label) rows for one achievement."""
    rows = []
    for i, c in enumerate(a["criteria"]):
        cid = a["id"] * 100 + i + 1
        t = c["type"]
        tn = TYPES[t][0]
        label = crit_label(c)
        if t == "level":
            rows.append((cid, 0, tn, c["level"], 0, 0, 0, label))
        elif t in ("quests", "exalted", "honor_kills"):
            rows.append((cid, 0, tn, 0, 0, 0, c["count"], label))
        elif t == "zone_quests":
            rows.append((cid, 0, tn, c["zone"], c["horde"], 0, c["alliance"], label))
        elif t == "quest":
            for n, q in enumerate(alts(c, "quest", "quests")):
                rows.append((cid, n, tn, q, 0, 0, 0, label))
        elif t == "explore":
            rows.append((cid, 0, tn, c["zone"], 0, 0, 0, label))
        elif t == "meta":
            rows.append((cid, 0, tn, c["achievement"], 0, 0, 0, label))
        elif t == "kill":
            fl = 1 if c.get("no_deaths") else 0
            for n, e in enumerate(alts(c, "creature", "creatures")):
                rows.append((cid, n, tn, e, fl, c.get("within") or 0, c.get("count") or 1, label))
        elif t == "skill":
            rows.append((cid, 0, tn, c["skill"], 0, 0, c["value"], label))
        elif t == "skills_at":
            for n, s in enumerate(c["skills"]):
                rows.append((cid, n, tn, c["value"], s, 0, c["count"], label))
        elif t == "reputation":
            rows.append((cid, 0, tn, c["faction"], STANDINGS[c["standing"]], 0, 0, label))
        elif t == "money":
            rows.append((cid, 0, tn, 0, 0, 0, c["gold"] * 10000, label))
        elif t == "bags":
            rows.append((cid, 0, tn, c["slots"], 0, 0, c["count"], label))
        elif t == "pets":
            for n, it in enumerate(pets):
                rows.append((cid, n, tn, 0, it, 0, c["count"], label))
        elif t == "item":
            for n, it in enumerate(alts(c, "item", "items")):
                rows.append((cid, n, tn, it, 0, 0, 0, label))
        elif t == "bg_wins":
            rows.append((cid, 0, tn, c["map"], 0, 0, c["count"], label))
        elif t == "pvp_rank":
            rows.append((cid, 0, tn, c["rank"], 0, 0, 0, label))
    return rows


def write_sql(data):
    pets = data.get("lists", {}).get("pet_items", [])
    out = []
    w = out.append
    w("-- Open Vanilla: achievements (PENDING: install on launch day with realm/mangos/pending/0002-openvanilla-achievements.patch).")
    w("-- GENERATED by tools/gen_achievements.py from realm/achievements/achievements.yml; do not edit.")
    w("-- Run against the world database (classicmangos); the per-character tables are created in")
    w("-- classiccharacters by name. Idempotent: tables are created if missing and the catalogue is replaced.")
    w("-- Achievements give points and recognition only, never power.")
    w("")
    w("-- -- characters -----------------------------------------------------------------------------")
    w("CREATE TABLE IF NOT EXISTS classiccharacters.character_achievement (")
    w("  guid         INT UNSIGNED NOT NULL COMMENT 'characters.guid',")
    w("  achievement  INT UNSIGNED NOT NULL COMMENT 'openvanilla_achievement.id',")
    w("  date         INT UNSIGNED NOT NULL COMMENT 'unix time it was earned',")
    w("  PRIMARY KEY (guid, achievement)")
    w(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: earned achievements';")
    w("")
    w("CREATE TABLE IF NOT EXISTS classiccharacters.character_achievement_progress (")
    w("  guid         INT UNSIGNED NOT NULL COMMENT 'characters.guid',")
    w("  criteria     INT UNSIGNED NOT NULL COMMENT 'openvanilla_achievement_criteria.id (achievement*100+n); 0 = retroactive grant done',")
    w("  counter      INT UNSIGNED NOT NULL DEFAULT 0,")
    w("  date         INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'unix time of the last change',")
    w("  PRIMARY KEY (guid, criteria)")
    w(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: achievement counters (kills, wins, honorable kills)';")
    w("")
    w("CREATE TABLE IF NOT EXISTS classiccharacters.openvanilla_realm_first (")
    w("  achievement  INT UNSIGNED NOT NULL PRIMARY KEY,")
    w("  guid         INT UNSIGNED NOT NULL,")
    w("  name         VARCHAR(12)  NOT NULL,")
    w("  date         INT UNSIGNED NOT NULL")
    w(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: realm firsts, stored once';")
    w("")
    w("-- -- world: settings and catalogue ---------------------------------------------------------")
    w("CREATE TABLE IF NOT EXISTS openvanilla_achievement_config (")
    w("  name   VARCHAR(32)  NOT NULL PRIMARY KEY,")
    w("  value  INT UNSIGNED NOT NULL")
    w(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: achievement settings';")
    w("-- release_date: what is already done when a character first logs in after launch is granted")
    w("-- retroactively, dated this day. Installing this file on launch day sets it to that day.")
    w("INSERT IGNORE INTO openvanilla_achievement_config (name, value) VALUES ('release_date', UNIX_TIMESTAMP(CURDATE()));")
    w("")
    w("CREATE TABLE IF NOT EXISTS openvanilla_achievement (")
    w("  id           INT UNSIGNED NOT NULL PRIMARY KEY,")
    w("  name         VARCHAR(80)  NOT NULL,")
    w("  description  VARCHAR(255) NOT NULL,")
    w("  points       TINYINT UNSIGNED NOT NULL,")
    w("  category     VARCHAR(16)  NOT NULL,")
    w("  icon         VARCHAR(80)  NOT NULL,")
    w("  faction      TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0 both, 1 Alliance, 2 Horde',")
    w("  class_mask   INT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0 every class, else 1<<(class-1)',")
    w("  need         TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'criteria needed; 0 = all',")
    w("  flags        INT UNSIGNED NOT NULL DEFAULT 0 COMMENT '1 realm first, 2 group first, 4 feat of strength'")
    w(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: achievement catalogue';")
    w("")
    w("CREATE TABLE IF NOT EXISTS openvanilla_achievement_criteria (")
    w("  id           INT UNSIGNED NOT NULL COMMENT 'achievement*100+n: one requirement',")
    w("  alt          TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'alternatives of one requirement (any one counts)',")
    w("  achievement  INT UNSIGNED NOT NULL,")
    w("  type         TINYINT UNSIGNED NOT NULL COMMENT 'see realm/achievements/PROTOCOL.md',")
    w("  value1       INT UNSIGNED NOT NULL DEFAULT 0,")
    w("  value2       INT UNSIGNED NOT NULL DEFAULT 0,")
    w("  value3       INT UNSIGNED NOT NULL DEFAULT 0,")
    w("  count        INT UNSIGNED NOT NULL DEFAULT 0,")
    w("  label        VARCHAR(80)  NOT NULL DEFAULT '',")
    w("  PRIMARY KEY (id, alt),")
    w("  KEY achievement (achievement)")
    w(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Open Vanilla: achievement criteria';")
    w("")
    w("DELETE FROM openvanilla_achievement_criteria;")
    w("DELETE FROM openvanilla_achievement;")
    w("")
    rows = []
    for a in data["achievements"]:
        rows.append("(%d, %s, %s, %d, %s, %s, %d, %d, %d, %d)" % (
            a["id"], sql_str(a["name"]), sql_str(a["description"]), a["points"], sql_str(a["category"]),
            sql_str(a["icon"]), FACTION_SIDE.get(a.get("faction"), 0), class_mask(a), a.get("need") or 0, flags(a)))
    for i in range(0, len(rows), 50):
        w("INSERT INTO openvanilla_achievement (id, name, description, points, category, icon, faction, class_mask, need, flags) VALUES")
        w(",\n".join(rows[i:i + 50]) + ";")
    w("")
    crows = []
    for a in data["achievements"]:
        for r in criteria_rows(a, pets):
            crows.append("(%d, %d, %d, %d, %d, %d, %d, %d, %s)" % (r[0], r[1], a["id"], r[2], r[3], r[4], r[5], r[6], sql_str(r[7])))
    for i in range(0, len(crows), 100):
        w("INSERT INTO openvanilla_achievement_criteria (id, alt, achievement, type, value1, value2, value3, count, label) VALUES")
        w(",\n".join(crows[i:i + 100]) + ";")
    w("")
    os.makedirs(os.path.dirname(SQL_OUT), exist_ok=True)
    with open(SQL_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    return len(rows), len(crows)


# ---- JSON ------------------------------------------------------------------------------------
def write_json(data):
    cats = []
    for c in data["categories"]:
        members = [a for a in data["achievements"] if a["category"] == c["key"]]
        cats.append({"key": c["key"], "name": c["name"], "icon": icon_base(c["icon"]),
                     "count": len(members), "points": sum(a["points"] for a in members)})
    out = {
        "version": data.get("version", 1),
        "generated_by": "tools/gen_achievements.py",
        "note": "Achievements give points and recognition only, never power. Earned achievements come from the realm's armory API.",
        "categories": cats,
        "achievements": [],
    }
    for a in data["achievements"]:
        ga, gh, pl = progress_info(a)
        e = {"id": a["id"], "name": a["name"], "description": a["description"], "points": a["points"],
             "category": a["category"], "icon": icon_base(a["icon"]), "icon_path": a["icon"]}
        if a.get("faction"):
            e["faction"] = a["faction"]
        if a.get("classes"):
            e["classes"] = [c.lower() for c in a["classes"]]
        if a.get("realm_first"):
            e["realm_first"] = True
        if ga or gh:
            e["goal"] = {"alliance": ga, "horde": gh, "label": pl}
        if len(a["criteria"]) > 1:
            e["criteria"] = [crit_label(c) or ("Achievement %d" % c.get("achievement", 0)) for c in a["criteria"]]
        meta = [c["achievement"] for c in a["criteria"] if c["type"] == "meta"]
        if meta:
            e["requires"] = meta
        out["achievements"].append(e)
    with open(JSON_OUT, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write("\n")


def icon_base(path):
    return path.split("\\")[-1].lower()


# ---- id snapshot -----------------------------------------------------------------------------
def refresh_ids(data, socket, db):
    want = {"creature": set(), "quest": set(), "item": set(data.get("lists", {}).get("pet_items", []))}
    for a in data["achievements"]:
        for c in a["criteria"]:
            if c["type"] == "kill":
                want["creature"].update(alts(c, "creature", "creatures"))
            elif c["type"] == "quest":
                want["quest"].update(alts(c, "quest", "quests"))
            elif c["type"] == "item":
                want["item"].update(alts(c, "item", "items"))
    table = {"creature": ("creature_template", "entry", "name"), "quest": ("quest_template", "entry", "Title"),
             "item": ("item_template", "entry", "name")}
    snap = {}
    for k, ids in want.items():
        t, key, col = table[k]
        if not ids:
            snap[k] = {}
            continue
        sql = "SELECT %s, %s FROM %s WHERE %s IN (%s)" % (key, col, t, key, ",".join(str(i) for i in sorted(ids)))
        res = subprocess.run(["mysql", "-S", socket, "-uroot", "-N", "-B", db, "-e", sql], check=True,
                             capture_output=True, text=True).stdout
        snap[k] = {}
        for line in res.splitlines():
            i, n = line.split("\t", 1)
            snap[k][i] = n
    with open(KNOWN, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"source": "cmangos/classic-db (creature_template, quest_template, item_template)", **snap}, f, indent=1,
                  ensure_ascii=False, sort_keys=True)
        f.write("\n")
    missing = {k: sorted(i for i in want[k] if str(i) not in snap[k]) for k in want}
    print("known_ids.json: %s; missing from the DB: %s" % ({k: len(v) for k, v in snap.items()}, missing))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="check only")
    ap.add_argument("--refresh-ids", action="store_true", help="re-snapshot known_ids.json from a world DB")
    ap.add_argument("--socket", default="/run/mysqld/mysqld.sock")
    ap.add_argument("--db", default="classicmangos")
    args = ap.parse_args()
    data = load()
    if args.refresh_ids:
        refresh_ids(data, args.socket, args.db)
    known = known_ids()
    errs = check(data, known)
    if known is None:
        print("note: realm/achievements/known_ids.json missing; creature/quest/item ids only range-checked")
    if errs:
        for e in errs:
            print("ERROR", e)
        print("%d problem(s) in %s" % (len(errs), os.path.relpath(YML, ROOT)))
        return 1
    A = data["achievements"]
    print("achievements.yml ok: %d achievements, %d points (%d feats of strength)" % (
        len(A), sum(a["points"] for a in A), sum(1 for a in A if a["category"] == "feats")))
    if args.check:
        return 0
    write_lua(data)
    n, c = write_sql(data)
    write_json(data)
    print("wrote %s, %s (%d achievements, %d criteria rows), %s" % (
        os.path.relpath(LUA_OUT, ROOT), os.path.relpath(SQL_OUT, ROOT), n, c, os.path.relpath(JSON_OUT, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
