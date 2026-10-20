#!/usr/bin/env python3
"""Open Vanilla check: the Star Pouches (90100-90105) are complete and their loot resolves.

    python3 check_starpouch.py [mysql args...]       e.g. classicmangos
Fails (exit 1) on a missing pouch, a stackable pouch (an emptied container is destroyed as a
whole item, so a stack would vanish together), an item or reference that does not exist, a pouch with no
gold, or a boost the band's players could never use (required level above the band's top).
"""
import subprocess, sys

BANDS = {90100: (2, 10), 90101: (11, 20), 90102: (21, 30), 90103: (31, 40), 90104: (41, 50), 90105: (51, 60)}


def q(args, sql):
    out = subprocess.run(["mysql", "-N", "-B", *args, "-e", sql], capture_output=True, text=True, check=True).stdout
    return [l.split("\t") for l in out.splitlines() if l]


def main(args):
    bad = 0
    for entry, (lo, hi) in BANDS.items():
        row = q(args, f"SELECT Flags, minMoneyLoot, maxMoneyLoot, stackable FROM item_template WHERE entry={entry}")
        if not row:
            print(f"FAIL {entry}: no item_template row"); bad += 1; continue
        flags, mn, mx, stack = map(int, row[0])
        if stack != 1:
            print(f"FAIL {entry}: stackable = {stack}, must be 1"); bad += 1
        if not flags & 4 or mn <= 0 or mx < mn:
            print(f"FAIL {entry}: not openable or no gold ({flags=}, {mn}-{mx})"); bad += 1
        loot = q(args, f"SELECT item, mincountOrRef, groupid, ChanceOrQuestChance FROM item_loot_template WHERE entry={entry}")
        refs = [int(r[1]) for r in loot if int(r[1]) < 0]
        items = [int(r[0]) for r in loot if int(r[1]) > 0]
        for ref in refs:
            if not q(args, f"SELECT 1 FROM reference_loot_template WHERE entry={-ref} LIMIT 1"):
                print(f"FAIL {entry}: reference {-ref} is empty"); bad += 1
        for it in items:
            r = q(args, f"SELECT RequiredLevel FROM item_template WHERE entry={it}")
            if not r:
                print(f"FAIL {entry}: item {it} does not exist"); bad += 1
            elif int(r[0][0]) > hi:
                print(f"FAIL {entry}: item {it} needs level {r[0][0]}, above the band's {hi}"); bad += 1
        if not refs:
            print(f"FAIL {entry}: no world-drop reference"); bad += 1
        print(f"{entry} (levels {lo}-{hi}): gold {mn}-{mx}c, {len(items)} boosts, {len(refs)} world-drop rolls")
    print("Star Pouches:", "FAIL" if bad else "ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
