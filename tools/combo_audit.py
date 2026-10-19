#!/usr/bin/env python3
"""Audit the 56 Classic+ race/class combos against a world database.

    python3 tools/combo_audit.py --socket /run/mysqld/mysqld.sock          a running server (local socket)
    python3 tools/combo_audit.py -H 127.0.0.1 -P 3306 -u root -p secret    ... or over TCP
    python3 tools/combo_audit.py --fixtures [--pending]                    a throwaway mariadbd (devkit/db):
        loads devkit/db/fixtures (stock rows), applies realm/classicplus/*.sql as realm_up does and,
        with --pending, realm/classicplus/pending/ (races, class quests) on top; then audits.

For every combo in realm/classicplus/combos.json (race id -> class ids) it checks:
  create    a playercreateinfo row (start map/zone)          spells   the class's starting spells,
  racials   the race's racials (Berserking for the class's    actions  Attack and a class spell on
            power: rage/energy/mana; Orc Command for the               the bars
            pet classes)                                      skills   playercreateinfo_skills rows
  stats     player_levelstats for levels 1-60                 outfit   CharStartOutfit.dbc rows for
  quests    the class quests are reachable for that race:              both genders (realm/classicplus)
            hunter taming chain (Tame Beast + Beast Training), warlock Imp / Voidwalker / Succubus /
            Felhunter, druid Bear Form / Cure Poison / Aquatic Form, paladin Redemption, shaman
            Earth/Fire/Water/Air totems, rogue poisons, warrior Defensive/Berserker stance.
            "Reachable": a quest rewarding the spell allows the race and class, every quest before
            it in its chain does too, and the chain's first quest has a spawned quest giver.
            (Skipped when the database has no quest tables, e.g. the devkit fixtures.)
Exit 0 = every check passed. --json prints the full result.
"""
import argparse
import importlib.util
import json
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CP = os.path.join(ROOT, "realm", "classicplus")

RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
CLASSES = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}

# Starting spells every character of the class must know (stock 1.12).
CLASS_START = {
    1: {78: "Heroic Strike", 2457: "Battle Stance"},
    2: {635: "Holy Light", 20154: "Seal of Righteousness"},
    3: {2973: "Raptor Strike", 75: "Auto Shot"},
    4: {1752: "Sinister Strike", 2098: "Eviscerate"},
    5: {585: "Smite", 2050: "Lesser Heal"},
    7: {403: "Lightning Bolt", 331: "Healing Wave"},
    8: {133: "Fireball", 168: "Frost Armor"},
    9: {686: "Shadow Bolt", 687: "Demon Skin"},
    11: {5176: "Wrath", 5185: "Healing Touch"},
}
# Racials every class of the race has (stock 1.12).
RACIALS = {
    1: {20597: "Sword Specialization", 20598: "The Human Spirit", 20599: "Diplomacy", 20600: "Perception", 20864: "Mace Specialization"},
    2: {20572: "Blood Fury", 20573: "Hardiness", 20574: "Axe Specialization"},
    3: {20594: "Stoneform", 20595: "Gun Specialization", 20596: "Frost Resistance", 2481: "Find Treasure"},
    4: {20580: "Shadowmeld", 20582: "Quickness", 20583: "Nature Resistance", 20585: "Wisp Spirit"},
    5: {20577: "Cannibalize", 20579: "Shadow Resistance", 5227: "Underwater Breathing", 7744: "Will of the Forsaken"},
    6: {20549: "War Stomp", 20550: "Endurance", 20551: "Nature Resistance", 20552: "Cultivation"},
    7: {20589: "Escape Artist", 20591: "Expansive Mind", 20592: "Arcane Resistance", 20593: "Engineering Specialist"},
    8: {20555: "Regeneration", 20557: "Beast Slaying", 20558: "Throwing Specialization", 26290: "Bow Specialization"},
}


def class_racials(race, cls):
    if race == 8:   # Berserking by power type
        return {26296: "Berserking (rage)"} if cls == 1 else {26297: "Berserking (energy)"} if cls == 4 else {20554: "Berserking (mana)"}
    if race == 2 and cls == 3:
        return {20576: "Command (pet)"}
    if race == 2 and cls == 9:
        return {20575: "Command (demon)"}
    return {}


# Class quests: (what, spells any of which the quest teaches (RewSpellCast/RewSpell) or the class may start with)
CLASS_QUESTS = {
    3: [("Tame Beast (taming chain)", [1579, 1515]), ("Beast Training (taming chain)", [5300, 5149])],
    9: [("Imp", [7763, 688]), ("Voidwalker", [11520, 697]), ("Succubus", [11519, 712]), ("Felhunter", [1373, 691])],
    11: [("Bear Form", [19179, 5487]), ("Cure Poison", [8947, 8946]), ("Aquatic Form", [1446, 1066])],
    2: [("Redemption", [7329, 7328])],
    7: [("Earth totem", [8073, 8071]), ("Fire totem", [2075, 3599]), ("Water totem", [5396, 5394]), ("Air totem", [8385])],
    4: [("Poisons", [2995, 2842])],
    1: [("Defensive Stance", [8121, 71]), ("Berserker Stance", [8616, 2458])],
}


def load_test_sql():
    spec = importlib.util.spec_from_file_location("ow_test_sql", os.path.join(ROOT, "devkit", "db", "test_sql.py"))
    mod = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = [saved[0]]
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = saved
    return mod


class Client:
    def __init__(self, db, world):
        self.db, self.world = db, world

    def rows(self, sql):
        out = self.db.run(sql, self.world).strip()
        return [line.split("\t") for line in out.splitlines()] if out else []

    def ints(self, sql):
        return {int(r[0]) for r in self.rows(sql) if r and r[0] not in ("NULL", "")}

    def has_table(self, name):
        return bool(self.rows(f"SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '{name}'"))


def outfits(path):
    have = set()
    if not os.path.exists(path):
        return None
    d = open(path, "rb").read()
    n, fc, rs, ss = struct.unpack("<4I", d[4:20])
    for i in range(n):
        rec = d[20 + i * rs:20 + (i + 1) * rs]
        items = struct.unpack("<12i", rec[8:56]) if rs >= 56 else ()
        if any(x > 0 for x in items):
            have.add((rec[4], rec[5], rec[6]))
    return have


class Quests:
    """Class-quest reachability: quest rows, chains and spawned givers, loaded once."""

    def __init__(self, c):
        self.q = {}
        for r in c.rows("SELECT entry, RequiredRaces, RequiredClasses, PrevQuestId, NextQuestId, RewSpell, RewSpellCast FROM quest_template"):
            self.q[int(r[0])] = dict(races=int(r[1]), classes=int(r[2]), prev=int(r[3]), next=int(r[4]), rew={int(r[5]), int(r[6])} - {0})
        # As the core reads them: a quest's positive prerequisites are its PrevQuestId plus every quest
        # naming it as NextQuestId, and finishing any one of them opens it.
        self.prereq = {}
        for qid, q in self.q.items():
            if q["prev"] > 0:
                self.prereq.setdefault(qid, set()).add(q["prev"])
            if q["next"] > 0:
                self.prereq.setdefault(q["next"], set()).add(qid)
        self.given = c.ints("""SELECT r.quest FROM creature_questrelation r WHERE EXISTS (SELECT 1 FROM creature s WHERE s.id = r.id)""")
        if c.has_table("gameobject_questrelation"):
            self.given |= c.ints("SELECT r.quest FROM gameobject_questrelation r WHERE EXISTS (SELECT 1 FROM gameobject s WHERE s.id = r.id)")
        self.given |= c.ints("SELECT startquest FROM item_template WHERE startquest <> 0")

    def allows(self, qid, race, cls):
        q = self.q.get(qid)
        if not q:
            return False
        return (q["races"] == 0 or q["races"] & (1 << (race - 1))) and (q["classes"] == 0 or q["classes"] & (1 << (cls - 1)))

    def reachable(self, qid, race, cls, seen=frozenset()):
        if qid in seen or not self.allows(qid, race, cls):
            return False
        seen = seen | {qid}
        before = self.prereq.get(qid)
        if before:
            return any(self.reachable(p, race, cls, seen) for p in before)
        # a chain's first quest needs a giver standing in the world (or an item that starts it)
        return qid in self.given

    def find(self, spells, race, cls):
        for qid, q in self.q.items():
            if q["rew"] & set(spells) and self.reachable(qid, race, cls):
                return qid
        return None


def audit(c, combos):
    results = []
    quests = Quests(c) if c.has_table("quest_template") else None
    dbc = outfits(os.path.join(CP, "CharStartOutfit.dbc"))
    for race, classes in combos:
        for cls in classes:
            name = f"{RACES[race]} {CLASSES[cls]}"
            checks = []

            def check(what, ok, detail=""):
                checks.append({"check": what, "ok": bool(ok), "detail": detail})

            pci = c.rows(f"SELECT map, zone FROM playercreateinfo WHERE race={race} AND class={cls}")
            check("create", bool(pci), f"map {pci[0][0]} zone {pci[0][1]}" if pci else "no playercreateinfo row")
            known = c.ints(f"SELECT Spell FROM playercreateinfo_spell WHERE race={race} AND class={cls}")
            miss = [n for s, n in CLASS_START[cls].items() if s not in known]
            check("spells", len(known) >= 15 and not miss, f"{len(known)} spells" + (f"; missing {', '.join(miss)}" if miss else ""))
            want = dict(RACIALS[race]); want.update(class_racials(race, cls))
            miss = [n for s, n in want.items() if s not in known]
            check("racials", not miss, "missing " + ", ".join(miss) if miss else f"{len(want)} racials")
            bar = {int(r[0]): int(r[1]) for r in c.rows(f"SELECT button, action FROM playercreateinfo_action WHERE race={race} AND class={cls} AND type=0")}
            on_bar = [s for s in CLASS_START[cls] if s in bar.values()]
            check("actions", 6603 in bar.values() and on_bar, f"{len(bar)} spell buttons" + ("" if 6603 in bar.values() else "; no Attack") + ("" if on_bar else "; no class spell"))
            skills = c.ints(f"""SELECT skill FROM playercreateinfo_skills WHERE (raceMask = 0 OR raceMask & {1 << (race - 1)})
                                AND (classMask = 0 OR classMask & {1 << (cls - 1)})""") if c.has_table("playercreateinfo_skills") else set()
            check("skills", len(skills) >= 3, f"{len(skills)} skill rows")
            lv = c.ints(f"SELECT level FROM player_levelstats WHERE race={race} AND class={cls} AND level BETWEEN 1 AND 60")
            check("stats", len(lv) == 60, f"{len(lv)}/60 levels")
            if dbc is None:
                check("outfit", False, "realm/classicplus/CharStartOutfit.dbc missing")
            else:
                g = [x for x in (0, 1) if (race, cls, x) not in dbc]
                check("outfit", not g, "missing " + "/".join("male" if x == 0 else "female" for x in g) if g else "both genders")
            if quests is None:
                check("quests", True, "skipped (no quest tables in this database)")
            else:
                bad = []
                for what, spells in CLASS_QUESTS.get(cls, []):
                    if any(s in known for s in spells):
                        continue   # starts with it
                    if quests.find(spells, race, cls) is None:
                        bad.append(what)
                n = len(CLASS_QUESTS.get(cls, []))
                check("quests", not bad, ("unreachable: " + ", ".join(bad)) if bad else (f"{n} reachable" if n else "none needed"))
            results.append({"race": race, "class": cls, "name": name, "checks": checks})
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--socket")
    ap.add_argument("-H", "--host")
    ap.add_argument("-P", "--port", default="3306")
    ap.add_argument("-u", "--user", default="root")
    ap.add_argument("-p", "--password", default=os.environ.get("MYSQL_PWD", ""))
    ap.add_argument("--world", default="classicmangos")
    ap.add_argument("--fixtures", action="store_true", help="throwaway mariadbd with devkit/db/fixtures")
    ap.add_argument("--pending", action="store_true", help="with --fixtures: also apply realm/classicplus/pending")
    ap.add_argument("--combos", default=os.path.join(CP, "combos.json"))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    data = json.load(open(args.combos))
    combos = sorted((int(r), sorted(cs)) for r, cs in data["combos"].items())
    total = sum(len(cs) for _, cs in combos)

    ts = load_test_sql()
    stop = lambda: None
    if args.fixtures:
        db, stop = ts.start_local()
        for name in ("classicmangos", "classicrealmd", "classiccharacters"):
            db.run(f"DROP DATABASE IF EXISTS {name}; CREATE DATABASE {name} DEFAULT CHARSET utf8mb4;")
        db.run(path=os.path.join(ts.FIX, "classicmangos.sql"), db="classicmangos")
        db.run(path=os.path.join(ts.FIX, "classiccharacters.sql"), db="classiccharacters")
        for dbname, f in ts.ORDER:
            db.run(path=os.path.join(CP, f), db=dbname)
        if args.pending:
            for f in ("classicplus_races.sql", "classicplus_classquests.sql"):
                p = os.path.join(CP, "pending", f)
                if os.path.exists(p):
                    try:
                        db.run(path=p, db="classicmangos")
                    except RuntimeError as e:   # class quests need quest tables the fixtures lack
                        print(f"note: {f} not applied to the fixtures ({str(e)[:120]})", file=sys.stderr)
    else:
        cli = [ts.client(), "-N", "-B", "-u" + args.user]
        if args.password:
            cli.append("-p" + args.password)
        cli += [f"--socket={args.socket}"] if args.socket else (["-h" + args.host, "-P" + args.port, "--protocol=TCP"] if args.host else [])
        db = ts.DB(cli)
    try:
        results = audit(Client(db, args.world), combos)
    finally:
        stop()

    bad = [(r["name"], c) for r in results for c in r["checks"] if not c["ok"]]
    if args.json:
        print(json.dumps({"combos": total, "failed": len(bad), "results": results}, indent=1))
    else:
        cols = [c["check"] for c in results[0]["checks"]] if results else []
        print(f"{'combo':<18}" + "".join(f"{c:<9}" for c in cols))
        for r in results:
            print(f"{r['name']:<18}" + "".join(f"{'ok' if c['ok'] else 'FAIL':<9}" for c in r["checks"]))
        for name, c in bad:
            print(f"FAIL {name}: {c['check']} - {c['detail']}")
        print(f"\n{total} combos, {len(results) * len(cols) - len(bad)} checks passed, {len(bad)} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
