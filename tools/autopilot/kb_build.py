#!/usr/bin/env python3
"""Build the Autopilot knowledge base for a Human Hunter, levels 1-12, Northshire + Elwynn Forest.

  kb_build.py --setup        # one time: private MariaDB + classic-db dump + updates + Classic+ SQL
  kb_build.py                # query it and write kb/elwynn_human_hunter.json

Data: cmangos classic-db (shallow clone under --data, NOT in the repo), every Updates/*.sql in
version order, then our realm/classicplus SQL (races, weapons, classquests, xp, trainers,
starpouch, starpouch_money) on top. The database runs as a throwaway mariadbd on a unix socket
under --data (no network listener). Needs the `mariadb`, `mariadbd` and `mariadb-install-db`
binaries (apt install mariadb-server); no Python driver (we shell out to the client).
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import KB_PATH, save_json, quest_full_xp  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLASSICPLUS = os.path.join(REPO, "realm", "classicplus")
CLASSICPLUS_FILES = ["races", "weapons", "classquests", "xp", "trainers", "starpouch", "starpouch_money"]
DEFAULT_DATA = "/tmp/claude-0/autopilot_data"

RACE_MASK, CLASS_MASK, MAX_QUEST_MINLEVEL = 1, 4, 12
GOLDSHIRE = (-9460.0, 60.0)
NORTHSHIRE = (-8915.0, -140.0)
FRIENDLY_FACTIONS = {11, 12, 35, 55, 57, 84, 123, 188, 210, 534, 1555, 114}   # Alliance / neutral-friendly
# 1.12 UNIT_NPC_FLAG_* values (not the TBC+ ones)
NPCFLAG_VENDOR, NPCFLAG_TRAINER, NPCFLAG_FLIGHT, NPCFLAG_REPAIR, NPCFLAG_INN = 0x4, 0x10, 0x8, 0x4000, 0x80
EXTRA_NO_XP = 0x40
# AreaTrigger.dbc is not in the world DB: approximate entrances for the exploration triggers we meet
# (centroids of the mines' kobold spawns). Anything else lands in "unresolved".
EXPLORE_POINTS = {87: (-9140.0, -600.0, "Jasperlode Mine (approx.)"), 88: (-9800.0, 140.0, "Fargodeep Mine (approx.)")}
HUNTER_SPELLS = [75, 2973, 14260, 1978, 13549, 3044, 14281, 5116, 2974, 1130, 13163, 13165, 1494,
                 1579, 23356, 23357, 5300, 883, 2641, 6991, 982, 136, 6197, 19883, 1513, 5118, 13795]


def in_region(x, y):
    """Northshire + Elwynn Forest, map 0 (rough box; Stormwind City and Westfall cut out)."""
    if not (-10120 <= x <= -8550 and -1650 <= y <= 950):
        return False
    if x > -9100 and y > 280:      # Stormwind City
        return False
    return True


def area_of(x, y):
    if x > -9150 and -480 < y < 120:
        return "Northshire"
    return "Elwynn"


class DB:
    def __init__(self, sock, name="classicmangos"):
        self.base = ["mariadb", "--no-defaults", "-S", sock, "-uroot", "--batch", "--raw", name]

    def q(self, sql):
        out = subprocess.run(self.base + ["-e", sql], check=True, capture_output=True, text=True).stdout
        lines = out.split("\n")
        if not lines or not lines[0]:
            return []
        cols = lines[0].split("\t")
        rows = []
        for ln in lines[1:]:
            if not ln:
                continue
            vals = ln.split("\t")
            rows.append({c: _conv(v) for c, v in zip(cols, vals)})
        return rows


def _conv(v):
    if v == "NULL":
        return None
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


def ids(xs):
    xs = sorted({int(x) for x in xs})
    return ",".join(map(str, xs)) if xs else "NULL"


# ── one-time setup ──
def setup(data):
    os.makedirs(data, exist_ok=True)
    cdb = os.path.join(data, "classic-db")
    if not os.path.isdir(cdb):
        subprocess.run(["git", "clone", "--depth", "1", "https://github.com/cmangos/classic-db.git", cdb], check=True)
    mdb = os.path.join(data, "mdb")
    sock = os.path.join(mdb, "sock")
    if not os.path.isdir(os.path.join(mdb, "data")):
        os.makedirs(mdb, exist_ok=True)
        subprocess.run(["mariadb-install-db", "--no-defaults", "--datadir=" + os.path.join(mdb, "data"),
                        "--user=" + os.environ.get("USER", "root"), "--auth-root-authentication-method=normal"],
                       check=True, capture_output=True)
    if not os.path.exists(sock):
        subprocess.Popen(["mariadbd", "--no-defaults", "--datadir=" + os.path.join(mdb, "data"), "--socket=" + sock,
                          "--skip-networking", "--user=" + os.environ.get("USER", "root"),
                          "--max-allowed-packet=256M", "--log-error=" + os.path.join(mdb, "err.log")],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(60):
            if os.path.exists(sock):
                break
            time.sleep(0.5)
        time.sleep(2)
    cli = ["mariadb", "--no-defaults", "-S", sock, "-uroot"]

    def run_sql(path, db="classicmangos", gz=False):
        if gz:
            p = subprocess.Popen(["zcat", path], stdout=subprocess.PIPE)
            subprocess.run(cli + [db], stdin=p.stdout, check=True)
        else:
            with open(path) as f:
                subprocess.run(cli + [db], stdin=f, check=True)

    subprocess.run(cli + ["-e", "DROP DATABASE IF EXISTS classicmangos; CREATE DATABASE classicmangos; "
                          "CREATE DATABASE IF NOT EXISTS classiccharacters; CREATE TABLE IF NOT EXISTS "
                          "classiccharacters.characters (guid INT PRIMARY KEY, race TINYINT, class TINYINT)"], check=True)
    full = [f for f in os.listdir(os.path.join(cdb, "Full_DB")) if f.endswith(".sql.gz")]
    run_sql(os.path.join(cdb, "Full_DB", full[0]), gz=True)
    ups = sorted((f for f in os.listdir(os.path.join(cdb, "Updates")) if f.endswith(".sql")),
                 key=lambda s: [int(t) if t.isdigit() else t for t in s.replace("_", " ").split()])
    for f in ups:
        run_sql(os.path.join(cdb, "Updates", f))
    subprocess.run(cli + ["classicmangos", "-e", "CREATE TABLE stock_xp_for_level SELECT * FROM player_xp_for_level"],
                   check=True)
    for name in CLASSICPLUS_FILES:
        run_sql(os.path.join(CLASSICPLUS, f"classicplus_{name}.sql"))
    print("setup done: socket", sock)


# ── build ──
def loot_chances(rows):
    """Resolve group 'equal chance' entries (chance 0 inside a group)."""
    out = []
    groups = {}
    for r in rows:
        groups.setdefault((r["entry"], r["groupid"]), []).append(r)
    for (_, gid), rs in groups.items():
        if gid:
            explicit = sum(abs(r["ChanceOrQuestChance"]) for r in rs if r["ChanceOrQuestChance"] != 0)
            zeros = [r for r in rs if r["ChanceOrQuestChance"] == 0]
            for r in rs:
                c = abs(r["ChanceOrQuestChance"]) if r["ChanceOrQuestChance"] else max(0.0, 100 - explicit) / max(1, len(zeros))
                out.append((r, c))
        else:
            for r in rs:
                out.append((r, abs(r["ChanceOrQuestChance"])))
    return out


def build(db):
    unresolved = []
    kb = {"meta": {}, "player": {}, "quests": {}, "creatures": {}, "gameobjects": {}, "items": {},
          "item_sources": {}, "services": {}, "spells": {}, "unresolved": unresolved}
    ver = db.q("SELECT version FROM db_version")
    kb["meta"] = {
        "source": "cmangos classic-db (Full_DB + all Updates) + realm/classicplus/" +
                  ",".join(f"classicplus_{n}.sql" for n in CLASSICPLUS_FILES),
        "db_version": ver[0]["version"] if ver else None,
        "race": 1, "class": 3, "map": 0, "zones": {"9": "Northshire Valley", "12": "Elwynn Forest"},
        "region_box": "x -10120..-8550, y -1650..950, minus Stormwind (x>-9100 and y>280)",
        "levels": [1, 12],
    }
    # player
    P = kb["player"]
    pc = db.q("SELECT map, zone, position_x x, position_y y, position_z z FROM playercreateinfo WHERE race=1 AND class=3")
    P["start"] = pc[0] if pc else None
    if not pc:
        unresolved.append("playercreateinfo for race 1 / class 3 missing (classicplus_races.sql not applied?)")
    P["levelstats"] = {r["level"]: r for r in db.q("SELECT level, str, agi, sta, inte, spi FROM player_levelstats "
                                                    "WHERE race=1 AND class=3 AND level<=20")}
    P["classlevelstats"] = {r["level"]: r for r in db.q("SELECT level, basehp, basemana FROM player_classlevelstats "
                                                         "WHERE class=3 AND level<=20")}
    P["xp_for_level"] = {r["lvl"]: r["xp_for_next_level"] for r in db.q("SELECT * FROM player_xp_for_level WHERE lvl<=20")}
    try:
        P["xp_for_level_stock"] = {r["lvl"]: r["xp_for_next_level"] for r in
                                   db.q("SELECT * FROM stock_xp_for_level WHERE lvl<=20")}
    except subprocess.CalledProcessError:
        unresolved.append("stock_xp_for_level snapshot missing (setup creates it before classicplus_xp.sql)")
    P["start_items"] = db.q("SELECT itemid, amount FROM playercreateinfo_item WHERE race=1 AND class=3")
    P["start_spells"] = [r["Spell"] for r in db.q("SELECT * FROM playercreateinfo_spell WHERE race=1 AND class=3")]
    if not P["start_items"]:
        unresolved.append("start gear comes from CharStartOutfit.dbc (not in the DB): assumed Worn Shortbow 2504 + "
                          "Rough Arrows 2512 + a 1-3 dmg melee weapon")
    P["pet_levelstats"] = {r["level"]: r for r in db.q("SELECT level, hp, armor, str, agi FROM pet_levelstats "
                                                        "WHERE creature_entry=1 AND level<=20")}
    # spells
    for r in db.q(f"SELECT Id, SpellName, Rank1, SpellLevel, ManaCost, RecoveryTime, CategoryRecoveryTime, "
                  f"DurationIndex, Effect1, EffectApplyAuraName1, EffectBasePoints1, EffectDieSides1, "
                  f"EffectAmplitude1, Effect2, EffectApplyAuraName2, EffectBasePoints2 FROM spell_template "
                  f"WHERE Id IN ({ids(HUNTER_SPELLS)})"):
        kb["spells"][r["Id"]] = r

    # quests available to race 1 / class 3
    qcols = ("entry, Title, Method, ZoneOrSort, MinLevel, QuestLevel, Type, RequiredClasses, RequiredRaces, "
             "QuestFlags, SpecialFlags, PrevQuestId, NextQuestId, ExclusiveGroup, NextQuestInChain, "
             "BreadcrumbForQuestId, SrcItemId, SrcItemCount, RewMoneyMaxLevel, RewOrReqMoney, RewSpell, RewSpellCast, "
             "RewItemId1, RewItemId2, RewItemId3, RewItemId4, RewChoiceItemId1, RewChoiceItemId2, RewChoiceItemId3, "
             "RewChoiceItemId4, RewChoiceItemId5, RewChoiceItemId6, LimitTime, RequiredSkill, " +
             ", ".join(f"ReqItemId{i}, ReqItemCount{i}, ReqSourceId{i}, ReqSourceCount{i}, ReqCreatureOrGOId{i}, "
                       f"ReqCreatureOrGOCount{i}, ReqSpellCast{i}" for i in range(1, 5)))
    allq = {r["entry"]: r for r in db.q(
        f"SELECT {qcols} FROM quest_template WHERE (RequiredRaces=0 OR RequiredRaces & {RACE_MASK}) "
        f"AND (RequiredClasses=0 OR RequiredClasses & {CLASS_MASK}) AND MinLevel <= {MAX_QUEST_MINLEVEL} "
        f"AND entry NOT IN (SELECT quest FROM game_event_quest)")}
    starters = {}
    for r in db.q(f"SELECT id, quest FROM creature_questrelation WHERE quest IN ({ids(allq)})"):
        starters.setdefault(r["quest"], []).append(("creature", r["id"]))
    for r in db.q(f"SELECT id, quest FROM gameobject_questrelation WHERE quest IN ({ids(allq)})"):
        starters.setdefault(r["quest"], []).append(("gameobject", r["id"]))
    for r in db.q(f"SELECT entry, startquest FROM item_template WHERE startquest IN ({ids(allq)})"):
        starters.setdefault(r["startquest"], []).append(("item", r["entry"]))
    enders = {}
    for r in db.q(f"SELECT id, quest FROM creature_involvedrelation WHERE quest IN ({ids(allq)})"):
        enders.setdefault(r["quest"], []).append(("creature", r["id"]))
    for r in db.q(f"SELECT id, quest FROM gameobject_involvedrelation WHERE quest IN ({ids(allq)})"):
        enders.setdefault(r["quest"], []).append(("gameobject", r["id"]))

    def creature_spawns(entries):
        out = {}
        if not entries:
            return out
        rows = db.q(f"SELECT c.guid, c.id, c.position_x x, c.position_y y, c.position_z z, c.spawntimesecsmin rmin, "
                    f"c.spawntimesecsmax rmax, c.spawndist, c.MovementType FROM creature c WHERE c.map=0 AND c.id IN ({ids(entries)}) "
                    f"AND c.guid NOT IN (SELECT guid FROM game_event_creature) "
                    f"UNION ALL SELECT c.guid, e.entry, c.position_x, c.position_y, c.position_z, c.spawntimesecsmin, "
                    f"c.spawntimesecsmax, c.spawndist, c.MovementType FROM creature c JOIN creature_spawn_entry e ON e.guid=c.guid "
                    f"WHERE c.map=0 AND e.entry IN ({ids(entries)})")
        for r in rows:
            out.setdefault(r["id"], []).append([round(r["x"], 1), round(r["y"], 1), round(r["z"], 1),
                                                r["rmin"], r["rmax"], r["guid"]])
        return out

    def go_spawns(entries):
        out = {}
        if not entries:
            return out
        for r in db.q(f"SELECT guid, id, position_x x, position_y y, position_z z, spawntimesecsmin rmin, spawntimesecsmax rmax "
                      f"FROM gameobject WHERE map=0 AND id IN ({ids(entries)}) "
                      f"AND guid NOT IN (SELECT guid FROM game_event_gameobject)"):
            out.setdefault(r["id"], []).append([round(r["x"], 1), round(r["y"], 1), round(r["z"], 1),
                                                r["rmin"], r["rmax"], r["guid"]])
        return out

    rel_c = {e for v in list(starters.values()) + list(enders.values()) for t, e in v if t == "creature"}
    rel_g = {e for v in list(starters.values()) + list(enders.values()) for t, e in v if t == "gameobject"}
    csp = creature_spawns(rel_c)
    gsp = go_spawns(rel_g)

    # loot -> item sources (needed for item-started quests too)
    def item_sources(items):
        src = {}
        if not items:
            return src
        direct = db.q(f"SELECT * FROM creature_loot_template WHERE item IN ({ids(items)}) AND mincountOrRef >= 0")
        refs = db.q(f"SELECT * FROM reference_loot_template WHERE item IN ({ids(items)}) AND mincountOrRef >= 0")
        ref_users = []
        if refs:
            ref_users = db.q(f"SELECT * FROM creature_loot_template WHERE mincountOrRef IN "
                             f"({','.join(str(-r['entry']) for r in refs)})")
        loot_ids = {r["entry"] for r in direct} | {r["entry"] for r in ref_users}
        owners = {}
        for r in db.q(f"SELECT Entry, LootId FROM creature_template WHERE LootId IN ({ids(loot_ids)})"):
            owners.setdefault(r["LootId"], []).append(r["Entry"])
        for r, c in loot_chances(direct):
            for e in owners.get(r["entry"], []):
                src.setdefault(r["item"], []).append({"type": "creature", "entry": e, "chance": round(c, 3),
                                                      "quest_only": r["ChanceOrQuestChance"] < 0})
        refc = {(r["entry"], r["item"]): c for r, c in loot_chances(refs)}
        for u in ref_users:
            for (rent, item), c in refc.items():
                if -u["mincountOrRef"] == rent:
                    ch = c * (u["ChanceOrQuestChance"] or 100) / 100.0
                    for e in owners.get(u["entry"], []):
                        src.setdefault(item, []).append({"type": "creature", "entry": e, "chance": round(ch, 3),
                                                         "quest_only": False, "via_reference": rent})
        gl = db.q(f"SELECT * FROM gameobject_loot_template WHERE item IN ({ids(items)}) AND mincountOrRef >= 0")
        if gl:
            gowners = {}
            for r in db.q(f"SELECT entry, type, data1 FROM gameobject_template WHERE type IN (3, 25) "
                          f"AND data1 IN ({ids(r['entry'] for r in gl)})"):
                gowners.setdefault(r["data1"], []).append(r["entry"])
            for r, c in loot_chances(gl):
                for e in gowners.get(r["entry"], []):
                    src.setdefault(r["item"], []).append({"type": "gameobject", "entry": e, "chance": round(c, 3),
                                                          "quest_only": r["ChanceOrQuestChance"] < 0})
        return src

    item_starter_ids = {e for v in starters.values() for t, e in v if t == "item"}
    item_starter_src = item_sources(item_starter_ids)

    def pts(rel):
        out = []
        for t, e in rel:
            if t == "creature":
                out += [(s[0], s[1]) for s in csp.get(e, [])]
            elif t == "gameobject":
                out += [(s[0], s[1]) for s in gsp.get(e, [])]
        return out

    chosen = {}
    for qid, q in allq.items():
        st = starters.get(qid, [])
        ok = any(in_region(x, y) for x, y in pts(st))
        if not ok:
            for t, e in st:
                if t == "item":
                    for s in item_starter_src.get(e, []):
                        if s["type"] == "creature":
                            ok = True   # checked against region spawns below (creature list)
        if ok:
            chosen[qid] = q
    # pull in prerequisite quests that are also region quests (so chains stay whole)
    # objectives
    obj_creatures, obj_gos, obj_items = set(), set(), set()
    for qid, q in chosen.items():
        objs = []
        for i in range(1, 5):
            cid, cc = q[f"ReqCreatureOrGOId{i}"], q[f"ReqCreatureOrGOCount{i}"]
            if cid and cc:
                kind = "cast" if q[f"ReqSpellCast{i}"] else ("kill" if cid > 0 else "use_go")
                objs.append({"kind": kind, "creature" if cid > 0 else "gameobject": abs(cid), "count": cc,
                             "spell": q[f"ReqSpellCast{i}"] or None})
                (obj_creatures if cid > 0 else obj_gos).add(abs(cid))
            iid, ic = q[f"ReqItemId{i}"], q[f"ReqItemCount{i}"]
            if iid and ic:
                objs.append({"kind": "item", "item": iid, "count": ic,
                             "provided": iid == q["SrcItemId"]})
                obj_items.add(iid)
            sid, sc = q[f"ReqSourceId{i}"], q[f"ReqSourceCount{i}"]
            if sid and sc:
                objs.append({"kind": "source_item", "item": sid, "count": sc})
                obj_items.add(sid)
        # exploration objectives (SpecialFlags & 2 in the core) live in areatrigger_involvedrelation
        for r in db.q(f"SELECT id FROM areatrigger_involvedrelation WHERE quest={qid}"):
            pt = EXPLORE_POINTS.get(r["id"])
            if pt:
                objs.append({"kind": "explore", "trigger": r["id"], "pos": [pt[0], pt[1]], "name": pt[2],
                             "approx": True})
            else:
                unresolved.append(f"quest {qid}: exploration areatrigger {r['id']} has no coordinates")
        q["objectives"] = objs
        q["starters"] = [{"type": t, "entry": e} for t, e in starters.get(qid, [])]
        q["enders"] = [{"type": t, "entry": e} for t, e in enders.get(qid, [])]
        q["xp_full"] = round(quest_full_xp(q["RewMoneyMaxLevel"], q["QuestLevel"]), 1)
        rel_c.update(e for t, e in enders.get(qid, []) if t == "creature")
        rel_g.update(e for t, e in enders.get(qid, []) if t == "gameobject")
    srcs = item_sources(obj_items | item_starter_ids)
    for it, ss in srcs.items():
        for s in ss:
            (obj_creatures if s["type"] == "creature" else obj_gos).add(s["entry"])
    kb["item_sources"] = {str(k): v for k, v in srcs.items()}

    # grind candidates: attackable, XP-giving mobs spawned in the region, level <= 15
    grind = db.q("SELECT DISTINCT ct.Entry FROM creature c JOIN creature_template ct ON ct.Entry=c.id "
                 "WHERE c.map=0 AND c.position_x BETWEEN -10120 AND -8550 AND c.position_y BETWEEN -1650 AND 950 "
                 "AND NOT (c.position_x > -9100 AND c.position_y > 280) AND ct.NpcFlags=0 AND ct.CreatureType<>8 "
                 f"AND ct.Faction NOT IN ({ids(FRIENDLY_FACTIONS)}) AND ct.MaxLevel<=15 AND (ct.ExtraFlags & {EXTRA_NO_XP})=0 "
                 "AND c.guid NOT IN (SELECT guid FROM game_event_creature)")
    grind_ids = {r["Entry"] for r in grind}
    all_c = rel_c | obj_creatures | grind_ids
    csp = creature_spawns(all_c)
    gsp = go_spawns(rel_g | obj_gos)
    tcols = ("Entry, Name, SubName, MinLevel, MaxLevel, Rank, Faction, CreatureType, Family, NpcFlags, UnitFlags, "
             "ExtraFlags, SpeedWalk, SpeedRun, UnitClass, HealthMultiplier, DamageMultiplier, DamageVariance, "
             "ArmorMultiplier, ExperienceMultiplier, MinLevelHealth, MaxLevelHealth, MinLevelMana, MaxLevelMana, "
             "MinMeleeDmg, MaxMeleeDmg, MinRangedDmg, MaxRangedDmg, Armor, MeleeAttackPower, RangedAttackPower, "
             "MeleeBaseAttackTime, RangedBaseAttackTime, DamageSchool, LootId, KillCredit1, KillCredit2, "
             "Civilian, AIName, ScriptName, SpellList, CallForHelp, Detection")
    cls_stats = {}
    for r in db.q("SELECT * FROM creature_template_classlevelstats WHERE Level <= 20"):
        cls_stats[(r["Level"], r["Class"])] = r
    for r in db.q(f"SELECT {tcols} FROM creature_template WHERE Entry IN ({ids(all_c)})"):
        e = r["Entry"]
        sp = csp.get(e, [])
        r["spawns"] = sp
        r["spawns_in_region"] = sum(1 for s in sp if in_region(s[0], s[1]))
        r["grind_candidate"] = e in grind_ids
        # class-level fallback stats per level (used when the template has 0s)
        r["levelstats"] = {}
        for lv in range(r["MinLevel"], r["MaxLevel"] + 1):
            cs = cls_stats.get((lv, r["UnitClass"] or 1))
            if cs:
                r["levelstats"][lv] = {"hp": round(cs["BaseHealthExp0"] * (r["HealthMultiplier"] or 1)),
                                       "base_dmg": round(cs["BaseDamageExp0"], 3),
                                       "melee_ap": cs["BaseMeleeAttackPower"], "armor": cs["BaseArmor"]}
        kb["creatures"][e] = r
    for e in all_c - set(kb["creatures"]):
        unresolved.append(f"creature_template {e} missing")
    for r in db.q(f"SELECT entry, type, name, data0, data1, faction, flags FROM gameobject_template "
                  f"WHERE entry IN ({ids(rel_g | obj_gos)})"):
        r["spawns"] = gsp.get(r["entry"], [])
        kb["gameobjects"][r["entry"]] = r

    # spawn positions for quest NPCs
    for qid, q in chosen.items():
        for rel in q["starters"] + q["enders"]:
            if rel["type"] == "creature":
                c = kb["creatures"].get(rel["entry"])
                rel["name"] = c["Name"] if c else None
                rel["spawns"] = [s[:3] for s in csp.get(rel["entry"], [])]
            elif rel["type"] == "gameobject":
                g = kb["gameobjects"].get(rel["entry"])
                rel["name"] = g["name"] if g else None
                rel["spawns"] = [s[:3] for s in gsp.get(rel["entry"], [])]
            else:
                rel["sources"] = srcs.get(rel["entry"], [])
            if rel["type"] != "item" and not rel.get("spawns"):
                unresolved.append(f"quest {qid}: {rel['type']} {rel['entry']} ({rel.get('name')}) has no map-0 spawn")
        pts_all = [(s[0], s[1]) for rel in q["starters"] + q["enders"] for s in rel.get("spawns", [])]
        q["enders_in_region"] = any(in_region(s[0], s[1]) for rel in q["enders"] for s in rel.get("spawns", []))
        q["area"] = area_of(*pts_all[0]) if pts_all else None
        if not q["enders"]:
            unresolved.append(f"quest {qid} ({q['Title']}): no ender")
        for o in q["objectives"]:
            if o["kind"] in ("item", "source_item") and not o.get("provided") and not srcs.get(o["item"]):
                unresolved.append(f"quest {qid} ({q['Title']}): no creature/GO loot source for item {o['item']}")
            if o["kind"] == "use_go" and not gsp.get(o["gameobject"]):
                unresolved.append(f"quest {qid}: objective GO {o['gameobject']} not spawned")
            if o["kind"] == "cast":
                unresolved.append(f"quest {qid} ({q['Title']}): spell-cast objective {o['spell']} on creature "
                                  f"{o.get('creature')} (credit depends on the core's spell script; modelled as a "
                                  f"10 s channel on one live target)")
        kb["quests"][qid] = q

    # items: objectives, starters, rods, rewards
    want = obj_items | item_starter_ids | {q["SrcItemId"] for q in chosen.values() if q["SrcItemId"]}
    for q in chosen.values():
        want |= {q[f"RewItemId{i}"] for i in range(1, 5) if q[f"RewItemId{i}"]}
        want |= {q[f"RewChoiceItemId{i}"] for i in range(1, 7) if q[f"RewChoiceItemId{i}"]}
    want |= {2504, 2512, 2508, 2516, 37}
    for r in db.q(f"SELECT entry, name, class, subclass, Quality, ItemLevel, RequiredLevel, InventoryType, delay, "
                  f"dmg_min1, dmg_max1, armor, AllowableClass, AllowableRace, stackable, startquest, BuyPrice, "
                  f"spellid_1, bonding FROM item_template WHERE entry IN ({ids(want)})"):
        kb["items"][r["entry"]] = r

    # services near Goldshire / Northshire, and the nearest flight master
    flags = NPCFLAG_VENDOR | NPCFLAG_FLIGHT | NPCFLAG_INN | NPCFLAG_TRAINER | NPCFLAG_REPAIR
    svc = db.q(f"SELECT c.guid, ct.Entry, ct.Name, ct.SubName, ct.NpcFlags, ct.VendorTemplateId, ct.TrainerClass, "
               f"c.position_x x, c.position_y y, c.position_z z FROM creature c JOIN creature_template ct ON ct.Entry=c.id "
               f"WHERE c.map=0 AND (ct.NpcFlags & {flags}) AND c.position_x BETWEEN -10200 AND -8300 "
               f"AND c.position_y BETWEEN -1700 AND 1400 AND c.guid NOT IN (SELECT guid FROM game_event_creature)")
    food_spells = {r["Id"]: r for r in db.q("SELECT Id, EffectApplyAuraName1 aura, EffectBasePoints1 bp, DurationIndex "
                                            "FROM spell_template WHERE EffectApplyAuraName1 IN (84, 85)")}
    out_v, out_i, out_f, out_t = [], [], [], []
    for s in svc:
        d_g = ((s["x"] - GOLDSHIRE[0]) ** 2 + (s["y"] - GOLDSHIRE[1]) ** 2) ** 0.5
        d_n = ((s["x"] - NORTHSHIRE[0]) ** 2 + (s["y"] - NORTHSHIRE[1]) ** 2) ** 0.5
        near = min(d_g, d_n) <= 300
        base = {"entry": s["Entry"], "name": s["Name"], "subname": s["SubName"], "pos": [s["x"], s["y"], s["z"]],
                "yd_from_goldshire": round(d_g), "in_region": in_region(s["x"], s["y"])}
        if s["NpcFlags"] & NPCFLAG_FLIGHT:
            out_f.append(base)
        if not near:
            continue
        if s["NpcFlags"] & NPCFLAG_INN:
            out_i.append(base)
        if s["NpcFlags"] & NPCFLAG_TRAINER:
            out_t.append(dict(base, trainer_class=s["TrainerClass"]))
        if s["NpcFlags"] & NPCFLAG_VENDOR:
            items = db.q(f"SELECT v.item, it.name, it.class, it.subclass, it.RequiredLevel, it.BuyPrice, it.delay, "
                         f"it.dmg_min1, it.dmg_max1, it.spellid_1 FROM (SELECT item FROM npc_vendor WHERE entry={s['Entry']} "
                         f"UNION SELECT item FROM npc_vendor_template WHERE entry={s['VendorTemplateId'] or -1}) v "
                         f"JOIN item_template it ON it.entry=v.item")
            keep = []
            for it in items:
                fs = food_spells.get(it["spellid_1"])
                if fs:
                    kind = "food" if fs["aura"] == 84 else "drink"
                    keep.append({"item": it["item"], "name": it["name"], "kind": kind, "req_level": it["RequiredLevel"],
                                 "per_sec": round((fs["bp"] + 1) / 5.0, 2), "price": it["BuyPrice"]})
                elif it["class"] == 6 or (it["class"] == 2 and it["subclass"] in (2, 3, 18)):
                    keep.append({"item": it["item"], "name": it["name"], "kind": "ammo" if it["class"] == 6 else "ranged",
                                 "req_level": it["RequiredLevel"], "price": it["BuyPrice"], "speed": it["delay"],
                                 "dmg": [it["dmg_min1"], it["dmg_max1"]]})
            out_v.append(dict(base, goods=keep))
    out_f.sort(key=lambda r: r["yd_from_goldshire"])
    kb["services"] = {"vendors": out_v, "innkeepers": out_i, "flight_masters": out_f[:3], "trainers": out_t}
    if not out_f:
        unresolved.append("no flight master found near Elwynn")
    unresolved.append("exploration trigger points (AreaTrigger.dbc) are approximated: " +
                      ", ".join(v[2] for v in EXPLORE_POINTS.values()))
    unresolved.append("pools (pool_creature) are not modelled: pooled spawns are counted as always up")
    unresolved.append("creature_template_spells / EventAI abilities of mobs are not modelled (melee only)")
    unresolved.append("hostility is a faction blacklist (FactionTemplate.dbc is not in the DB)")
    unresolved.append("quest givers inside Stormwind City and quests ending outside the region are excluded "
                      "from the route (flagged enders_in_region=false)")
    return kb


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", default=DEFAULT_DATA, help="where the classic-db clone and the MariaDB live")
    ap.add_argument("--setup", action="store_true", help="clone classic-db, start MariaDB, load and patch the world DB")
    ap.add_argument("--out", default=KB_PATH)
    a = ap.parse_args()
    if a.setup:
        setup(a.data)
    sock = os.path.join(a.data, "mdb", "sock")
    if not os.path.exists(sock):
        sys.exit(f"no MariaDB socket at {sock}: run with --setup first")
    kb = build(DB(sock))
    save_json(a.out, kb)
    size = os.path.getsize(a.out)
    if size > 2_000_000:
        import gzip
        import shutil
        with open(a.out, "rb") as f, gzip.open(a.out + ".gz", "wb") as g:
            shutil.copyfileobj(f, g)
        os.remove(a.out)
        print(f"KB {size} bytes > 2 MB: wrote {a.out}.gz")
    print(f"quests {len(kb['quests'])}, creatures {len(kb['creatures'])}, gameobjects {len(kb['gameobjects'])}, "
          f"unresolved {len(kb['unresolved'])} -> {a.out}")


if __name__ == "__main__":
    main()
