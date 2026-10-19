#!/usr/bin/env python3
"""Static validity check of the Classic+ Human hunter taming chain (quests 90601-90604) and, for
reference, the Undead one (90605-90608), against the world DB built by kb_build.py --setup.

  chain_check.py [--data /tmp/claude-0/autopilot_data] [--out out/chain_check.txt]

Checks: rows exist; race/class masks; MinLevel; PrevQuestId links and NextQuestInChain; no exclusive
group; giver/ender relations, the NPC template (quest giver flag, friendly faction) and its spawn;
the Taming Rods (item rows, rod spell, item_required_target -> the right beast, the beast is spawned
in the zone); the cast objective (ReqSpellCast is the spell the core's tame-aura script casts at the
end of the rod's aura, see SpellAuras.cpp IsQuestTameSpell); reward spells exist; no leftover
requirement fields copied from the stock quests. Exit code 1 if any check FAILs.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import OUT_DIR  # noqa: E402
from kb_build import DB, DEFAULT_DATA, in_region  # noqa: E402

# rod aura -> final spell, as hard-coded in cmangos-classic SpellAuras.cpp (Aura::HandleAuraDummy, remove)
CORE_TAME_FINAL = {19548: 19597, 19674: 19677, 19687: 19676, 19688: 19678, 19689: 19679, 19692: 19680,
                   19693: 19684, 19694: 19681, 19696: 19682, 19697: 19683, 19699: 19685, 19700: 19686}
CHAINS = {
    "Human (Goldshire)": {"race": 1, "npc": 990601, "spawn": 9100601, "near": (-9460.0, 60.0),
                          "quests": [90601, 90602, 90603, 90604], "beasts": {90601: 113, 90602: 822, 90603: 118}},
    "Undead (Brill)": {"race": 16, "npc": 990602, "spawn": 9100602, "near": (2270.0, 290.0),
                       "quests": [90605, 90606, 90607, 90608], "beasts": {90605: 1553, 90606: 1554, 90607: 1555}},
}
CREATURE_TYPE_BEAST = 1


def check(db):
    lines, fails = [], 0

    def res(ok, msg, warn=False):
        nonlocal fails
        tag = "ok  " if ok else ("WARN" if warn else "FAIL")
        if not ok and not warn:
            fails += 1
        lines.append(f"  [{tag}] {msg}")

    for label, ch in CHAINS.items():
        lines.append(f"{label}: quests {ch['quests'][0]}-{ch['quests'][-1]}")
        qs = {r["entry"]: r for r in db.q(
            "SELECT entry, Title, MinLevel, QuestLevel, RequiredRaces, RequiredClasses, PrevQuestId, NextQuestId, "
            "ExclusiveGroup, NextQuestInChain, SrcItemId, SrcItemCount, ReqItemId1, ReqItemCount1, ReqCreatureOrGOId1, "
            "ReqCreatureOrGOCount1, ReqSpellCast1, RewSpell, RewSpellCast, RewMoneyMaxLevel, RequiredSkill, "
            "RequiredCondition, RequiredMinRepFaction, RequiredMaxRepFaction, LimitTime, BreadcrumbForQuestId, "
            "SpecialFlags, QuestFlags FROM quest_template WHERE entry IN (%s)" % ",".join(map(str, ch["quests"])))}
        res(len(qs) == 4, f"quest_template rows: {sorted(qs)}")
        if len(qs) != 4:
            continue
        for i, qid in enumerate(ch["quests"]):
            q = qs[qid]
            res(q["RequiredRaces"] == ch["race"] and q["RequiredClasses"] == 4,
                f"{qid} '{q['Title']}' races={q['RequiredRaces']} classes={q['RequiredClasses']} MinLevel={q['MinLevel']} "
                f"QuestLevel={q['QuestLevel']} xp={round(q['RewMoneyMaxLevel'] / 0.6)}")
            want_prev = ch["quests"][i - 1] if i else 0
            res(q["PrevQuestId"] == want_prev, f"{qid} PrevQuestId={q['PrevQuestId']} (want {want_prev})")
            if i < 3:
                res(q["NextQuestInChain"] == ch["quests"][i + 1],
                    f"{qid} NextQuestInChain={q['NextQuestInChain']} (want {ch['quests'][i + 1]})", warn=True)
            res(q["ExclusiveGroup"] == 0 and q["NextQuestId"] == 0, f"{qid} ExclusiveGroup/NextQuestId unset")
            extra = {k: q[k] for k in ("RequiredSkill", "RequiredCondition", "RequiredMinRepFaction",
                                       "RequiredMaxRepFaction", "LimitTime", "BreadcrumbForQuestId") if q[k]}
            res(not extra, f"{qid} no leftover requirements {extra or ''}".rstrip())
        # giver / ender
        rel_s = db.q("SELECT id, quest FROM creature_questrelation WHERE quest IN (%s)" % ",".join(map(str, ch["quests"])))
        rel_e = db.q("SELECT id, quest FROM creature_involvedrelation WHERE quest IN (%s)" % ",".join(map(str, ch["quests"])))
        for name, rel in (("starter", rel_s), ("ender", rel_e)):
            got = {r["quest"]: r["id"] for r in rel}
            res(all(got.get(q) == ch["npc"] for q in ch["quests"]) and len(rel) == 4,
                f"{name} of every quest is creature {ch['npc']} ({len(rel)} rows)")
        go_rel = db.q("SELECT COUNT(*) n FROM gameobject_questrelation WHERE quest IN (%s)" % ",".join(map(str, ch["quests"])))
        res(go_rel[0]["n"] == 0, "no gameobject starters competing")
        npc = db.q(f"SELECT Entry, Name, NpcFlags, Faction, MinLevel, TrainerType, TrainerClass FROM creature_template "
                   f"WHERE Entry={ch['npc']}")
        res(bool(npc), f"creature_template {ch['npc']} exists" + (f": {npc[0]['Name']}" if npc else ""))
        if npc:
            n = npc[0]
            res(bool(n["NpcFlags"] & 2), f"NpcFlags={n['NpcFlags']} has QUESTGIVER (2)")
            res(n["Faction"] in ((12, 11, 1575, 123) if ch["race"] == 1 else (68, 71, 118)),
                f"faction {n['Faction']} friendly to the race")
            res(bool(n["NpcFlags"] & 16) and n["TrainerClass"] == 3, f"trainer flag + TrainerClass={n['TrainerClass']}")
            tr = db.q(f"SELECT COUNT(*) n FROM npc_trainer WHERE entry={ch['npc']}")
            res(tr[0]["n"] > 0, f"npc_trainer rows: {tr[0]['n']}", warn=True)
        sp = db.q(f"SELECT guid, id, map, position_x x, position_y y, spawntimesecsmin FROM creature WHERE guid={ch['spawn']}")
        if sp:
            s = sp[0]
            d = ((s["x"] - ch["near"][0]) ** 2 + (s["y"] - ch["near"][1]) ** 2) ** 0.5
            res(s["id"] == ch["npc"] and s["map"] == 0 and d < 60,
                f"spawn {ch['spawn']} id={s['id']} map={s['map']} at ({s['x']:.1f}, {s['y']:.1f}), {d:.0f} yd from hub")
        else:
            res(False, f"spawn {ch['spawn']} missing")
        other = db.q(f"SELECT COUNT(*) n FROM creature WHERE id={ch['npc']}")
        res(other[0]["n"] == 1, f"exactly one spawn of {ch['npc']} ({other[0]['n']})", warn=True)
        # rods, beasts, cast objective
        for qid, beast in ch["beasts"].items():
            q = qs[qid]
            it = db.q(f"SELECT entry, name, spellid_1, AllowableClass FROM item_template WHERE entry={q['SrcItemId'] or 0}")
            res(bool(it) and q["SrcItemId"] == q["ReqItemId1"] and q["SrcItemCount"] >= 1,
                f"{qid} rod {q['SrcItemId']} exists, given at accept (SrcItemCount={q['SrcItemCount']}) and required at turn-in")
            if not it:
                continue
            rod_spell = it[0]["spellid_1"]
            final = CORE_TAME_FINAL.get(rod_spell)
            res(final is not None, f"{qid} rod spell {rod_spell} is one of the core's quest tame spells")
            res(final == q["ReqSpellCast1"], f"{qid} ReqSpellCast1={q['ReqSpellCast1']} == core final spell {final}")
            ss = db.q(f"SELECT Id, SpellName FROM spell_template WHERE Id IN ({rod_spell}, {q['ReqSpellCast1'] or 0})")
            res(len(ss) == 2, f"{qid} spells exist: " + ", ".join(f"{s['Id']} {s['SpellName']}" for s in ss))
            irt = db.q(f"SELECT type, targetEntry FROM item_required_target WHERE entry={q['SrcItemId']}")
            res([(r["type"], r["targetEntry"]) for r in irt] == [(1, beast)],
                f"{qid} item_required_target -> {[(r['type'], r['targetEntry']) for r in irt]} (want [(1, {beast})])")
            res(q["ReqCreatureOrGOId1"] == beast and q["ReqCreatureOrGOCount1"] == 1,
                f"{qid} objective creature {q['ReqCreatureOrGOId1']} x{q['ReqCreatureOrGOCount1']} "
                f"(core sets KILL_OR_CAST at load because ReqCreatureOrGOId1 != 0)")
            bt = db.q(f"SELECT Entry, Name, MinLevel, MaxLevel, CreatureType FROM creature_template WHERE Entry={beast}")
            bs = db.q(f"SELECT position_x x, position_y y FROM creature WHERE id={beast} AND map=0")
            inzone = sum(1 for s in bs if in_region(s["x"], s["y"])) if ch["race"] == 1 else len(bs)
            res(bool(bt) and bt[0]["CreatureType"] == CREATURE_TYPE_BEAST and inzone > 0,
                f"{qid} target {beast} {bt[0]['Name'] if bt else '?'} L{bt[0]['MinLevel'] if bt else '?'}-"
                f"{bt[0]['MaxLevel'] if bt else '?'} is a beast with {inzone} spawns in the zone")
            fin = db.q(f"SELECT EffectMiscValue2 FROM spell_template WHERE Id={q['ReqSpellCast1'] or 0} AND Effect2=16")
            if fin:
                lines.append(f"  [info] {qid} the final spell also completes stock quest {fin[0]['EffectMiscValue2']} "
                             f"(harmless: not in this character's log)")
        for qid in ch["quests"]:
            q = qs[qid]
            if q["RewSpell"] or q["RewSpellCast"]:
                ss = db.q(f"SELECT Id, SpellName FROM spell_template WHERE Id IN ({q['RewSpell'] or 0}, {q['RewSpellCast'] or 0})")
                res(len(ss) == len({x for x in (q["RewSpell"], q["RewSpellCast"]) if x}),
                    f"{qid} reward spells: " + ", ".join(f"{s['Id']} {s['SpellName']}" for s in ss))
        res(qs[ch["quests"][2]]["RewSpellCast"] == 1579, "third quest teaches Tame Beast (1579)")
        res(qs[ch["quests"][3]]["RewSpellCast"] == 5300, "fourth quest teaches Beast Training (5300)")
        lines.append("")
    verdict = "PASS" if fails == 0 else f"FAIL ({fails} failed checks)"
    return [f"Classic+ hunter taming chain static check: {verdict}", ""] + lines, fails


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", default=DEFAULT_DATA)
    ap.add_argument("--out", default=os.path.join(OUT_DIR, "chain_check.txt"))
    a = ap.parse_args()
    sock = os.path.join(a.data, "mdb", "sock")
    if not os.path.exists(sock):
        sys.exit(f"no MariaDB socket at {sock}: run kb_build.py --setup first")
    lines, fails = check(DB(sock))
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
