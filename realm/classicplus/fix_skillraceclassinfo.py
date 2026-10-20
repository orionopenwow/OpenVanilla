"""Open Vanilla Classic+: let every new race/class combination use its class's weapon skills.

classicplus_weapons.sql grants each class its whole weapon list on every race, but the 1.12
SkillRaceClassInfo.dbc only lists the stock race/class pairs. Where no row allows a skill for a
(race, class) pair, the client hides the skill and CMaNGOS drops it at login, so e.g. a Human
Hunter loses Axes/Guns/Daggers and a Troll Druid loses Maces/Daggers.

This script ORs the missing race bit into the row that already covers that skill for that
class (the same row trainers use), or appends a row when the class has none. Idempotent.

    python3 fix_skillraceclassinfo.py IN.dbc OUT.dbc --combos CharBaseInfo.dbc|pairs.txt [--sql classicplus_weapons.sql]
    python3 fix_skillraceclassinfo.py IN.dbc --check --combos CharBaseInfo.dbc    # report only, exit 1 if gaps

The same output goes to both places:
  * the client: DBFilesClient\\SkillRaceClassInfo.dbc inside realm/classicplus/patch-Z.MPQ
  * the server: <gamedata>/dbc/SkillRaceClassInfo.dbc, then restart mangosd
"""
import argparse
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Fields: id, skillId, raceMask, classMask, flags, minLevel, skillTierId, skillCostIndex
F_ID, F_SKILL, F_RACE, F_CLASS = 0, 1, 2, 3


def read_dbc(path):
    data = open(path, "rb").read()
    magic, n, fields, size, ssize = struct.unpack_from("<4s4I", data)
    if magic != b"WDBC" or fields != 8 or size != 32:
        sys.exit(f"{path}: not a 1.12 SkillRaceClassInfo.dbc ({fields} fields, {size} bytes)")
    rows = [list(struct.unpack_from("<8I", data, 20 + i * size)) for i in range(n)]
    strings = data[20 + n * size:20 + n * size + ssize]
    return rows, strings


def write_dbc(path, rows, strings):
    out = struct.pack("<4s4I", b"WDBC", len(rows), 8, 32, len(strings))
    out += b"".join(struct.pack("<8I", *r) for r in rows) + strings
    with open(path, "wb") as f:
        f.write(out)


def read_combos(path):
    """Every (race, class) pair: from CharBaseInfo.dbc (one byte pair per record), or from a
    text file of "race class" lines (e.g. `SELECT race, class FROM playercreateinfo` on a server)."""
    data = open(path, "rb").read()
    if data[:4] != b"WDBC":
        pairs = re.findall(rb"(\d+)\s+(\d+)", data)
        return sorted({(int(r), int(c)) for r, c in pairs})
    magic, n, fields, size, _ = struct.unpack_from("<4s4I", data)
    assert magic == b"WDBC" and size == 2, f"{path}: unexpected CharBaseInfo layout"
    return sorted({(data[20 + i * 2], data[21 + i * 2]) for i in range(n)})


def class_skills(sql_path):
    """classMask -> weapon skill ids, from the playercreateinfo_skills rows of the SQL."""
    out = {}
    for cmask, skill in re.findall(r"\(0,(\d+),(\d+),0,'Weapon:", open(sql_path, encoding="utf-8").read()):
        out.setdefault(int(cmask), set()).add(int(skill))
    return out


def covered(rows, skill, rbit, cbit):
    return any(r[F_SKILL] == skill and (r[F_RACE] == 0 or r[F_RACE] & rbit)
               and (r[F_CLASS] == 0 or r[F_CLASS] & cbit) for r in rows)


def gaps(rows, combos, skills):
    for race, cls in combos:
        rbit, cbit = 1 << (race - 1), 1 << (cls - 1)
        for skill in sorted(skills.get(cbit, ())):
            if not covered(rows, skill, rbit, cbit):
                yield race, cls, skill


def fix(rows, combos, skills):
    changes = []
    for race, cls, skill in list(gaps(rows, combos, skills)):
        rbit, cbit = 1 << (race - 1), 1 << (cls - 1)
        if covered(rows, skill, rbit, cbit):  # an earlier change already covered it
            continue
        same = [r for r in rows if r[F_SKILL] == skill and r[F_CLASS] & cbit]
        if same:
            r = min(same, key=lambda r: r[F_ID])
            r[F_RACE] |= rbit
            changes.append(f"row {r[F_ID]}: skill {skill} class {cls} += race {race}")
        else:
            tmpl = next((r for r in rows if r[F_SKILL] == skill), None)
            if tmpl is None:
                changes.append(f"! skill {skill} has no row at all; skipped (race {race} class {cls})")
                continue
            new = list(tmpl)
            new[F_ID] = max(r[F_ID] for r in rows) + 1
            new[F_RACE], new[F_CLASS] = rbit, cbit
            rows.append(new)
            changes.append(f"row {new[F_ID]} (new): skill {skill} race {race} class {cls}")
    return changes


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dbc")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--combos", required=True, help="CharBaseInfo.dbc listing every race/class pair")
    ap.add_argument("--sql", default=os.path.join(HERE, "classicplus_weapons.sql"))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    rows, strings = read_dbc(a.dbc)
    combos, skills = read_combos(a.combos), class_skills(a.sql)
    if a.check:
        missing = list(gaps(rows, combos, skills))
        for race, cls, skill in missing:
            print(f"missing: race {race} class {cls} skill {skill}")
        print(f"{len(missing)} gap(s) across {len(combos)} race/class pairs")
        sys.exit(1 if missing else 0)
    if not a.out:
        sys.exit("give an output path, or --check")
    changes = fix(rows, combos, skills)
    for c in changes:
        print(" ", c)
    write_dbc(a.out, rows, strings)
    left = list(gaps(rows, combos, skills))
    print(f"{len(changes)} change(s); {len(left)} gap(s) left -> {a.out}")
    sys.exit(1 if left else 0)


if __name__ == "__main__":
    main()
