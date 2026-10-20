#!/usr/bin/env python3
"""Open Vanilla pre-launch check: every race/class combination starts with its class's full weapon list.

Reads the world database the realm creates characters from (playercreateinfo*), and for each of
the 58 combinations (modern WoW's, for the vanilla races) compares the weapon-skill spells and starting weapon skills with the class's
list. Any missing or extra weapon fails the check (exit 1).

    python3 check_weapon_skills.py [mysql args...]      e.g. -h 127.0.0.1 -uroot classicmangos
On the realm:  docker compose exec -T mariadb mariadb -uroot -p... classicmangos  is the same DB.
"""
import subprocess, sys

WEAPON_SPELLS = {196, 197, 198, 199, 200, 201, 202, 227, 1180, 15590, 264, 266, 5011, 2567, 5009}
SKILL_OF = {196: 44, 197: 172, 198: 54, 199: 160, 200: 229, 201: 43, 202: 55, 227: 136, 1180: 173,
            15590: 473, 264: 45, 266: 46, 5011: 226, 2567: 176, 5009: 228}
CLASS = {
    1: ("Warrior", {196, 197, 198, 199, 200, 201, 202, 227, 1180, 15590, 264, 266, 5011, 2567}),
    2: ("Paladin", {196, 197, 198, 199, 200, 201, 202}),
    3: ("Hunter", {196, 197, 200, 201, 202, 227, 1180, 15590, 264, 266, 5011, 2567}),
    4: ("Rogue", {198, 201, 1180, 15590, 264, 266, 5011, 2567}),
    5: ("Priest", {198, 227, 1180, 5009}),
    7: ("Shaman", {196, 197, 198, 199, 227, 1180, 15590}),
    8: ("Mage", {201, 227, 1180, 5009}),
    9: ("Warlock", {201, 227, 1180, 5009}),
    11: ("Druid", {198, 199, 227, 1180, 15590}),
}
# Racial weapon skills on top of the class list are allowed (stock racials, e.g. none today, but
# a race's own bonus line must not count as a failure if a future racial adds one).
RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}


def q(args, sql):
    out = subprocess.run(["mysql", "-N", "-B", *args, "-e", sql], capture_output=True, text=True, check=True).stdout
    return [line.split("\t") for line in out.splitlines() if line]


def main(args):
    combos = [(int(r), int(c)) for r, c in q(args, "SELECT race, class FROM playercreateinfo")]
    spells = {}
    for r, c, s in q(args, "SELECT race, class, Spell FROM playercreateinfo_spell"):
        spells.setdefault((int(r), int(c)), set()).add(int(s))
    skills = q(args, "SELECT raceMask, classMask, skill FROM playercreateinfo_skills")
    failures = 0
    for race, cls in sorted(combos):
        name, want = CLASS[cls]
        have = spells.get((race, cls), set()) & WEAPON_SPELLS
        start = {int(k) for rm, cm, k in skills
                 if (int(rm) == 0 or int(rm) & (1 << (race - 1))) and (int(cm) == 0 or int(cm) & (1 << (cls - 1)))}
        missing_skill = {SKILL_OF[s] for s in want} - start
        if have != want or missing_skill:
            failures += 1
            print(f"FAIL {RACES[race]} {name}: missing spells {sorted(want - have)}, extra {sorted(have - want)}, "
                  f"missing starting skills {sorted(missing_skill)}")
    print(f"{len(combos)} combinations checked, {failures} failing")
    if len(combos) < 58:
        print("FAIL expected at least 58 combinations")
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
