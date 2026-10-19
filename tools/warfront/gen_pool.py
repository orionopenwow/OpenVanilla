"""
gen_pool.py  (Open Vanilla / Warfront)

Builds warfront_item_pool: every item a Warfront character may pick in the gear picker, with the
unlock tier it needs. Sources are read from the world database's own loot tables, so "Molten Core
item" means "dropped by a creature or chest spawned on map 409", not a guess.

  tier 0  baseline   Molten Core, Onyxia, Blackwing Lair, Zul'Gurub loot; PvP items to Rank 13;
                     every item in a starter kit (kits.json, some are quest rewards)
  tier 2             Ahn'Qiraj (20 and 40) loot; Rank 14 (Grand Marshal / High Warlord) items
  tier 3             Naxxramas loot; legendaries (Thunderfury, Sulfuras ...)
  (tier 1 is the consumable stack: buffs, not items)

Never in the pool: Corrupted Ashbringer and Atiesh (see the plan), test and placeholder items,
items above Open Vanilla's custom item range start, anything not wearable at level 60.

Run: python3 gen_pool.py <dir with the *.tsv world tables> kits.json out/warfront_item_pool.sql
"""
import csv
import json
import sys
from collections import defaultdict

csv.field_size_limit(1 << 24)

MAPS = {409: 0, 249: 0, 469: 0, 309: 0, 509: 2, 531: 2, 533: 3}
MAP_NAME = {409: "Molten Core", 249: "Onyxia's Lair", 469: "Blackwing Lair", 309: "Zul'Gurub",
            509: "Ruins of Ahn'Qiraj", 531: "Temple of Ahn'Qiraj", 533: "Naxxramas"}
EXCLUDE = {22691,                                  # Corrupted Ashbringer: never obtainable in 1.12.1
           22589, 22630, 22631, 22632}             # Atiesh, all four
CUSTOM_FROM = 90000                                # Open Vanilla's own items start here
WEARABLE = {1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 20, 21, 22, 23, 25, 26, 28}
BAD_WORDS = ("[PH]", "TEST", "Test ", "DEP", "Monster -", "UNUSED", "Deprecated", "zz", "QA ")


def table(d, name):
    with open("%s/%s.tsv" % (d, name), encoding="utf-8") as f:
        r = csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE)
        hdr = next(r)
        for row in r:
            yield dict(zip(hdr, row))


def build(d, kits_path):
    # where each creature / chest entry spawns
    cmaps = defaultdict(set)
    for r in table(d, "creature"):
        cmaps[int(r["id"])].add(int(r["map"]))
    gmaps = defaultdict(set)
    for r in table(d, "gameobject"):
        gmaps[int(r["id"])].add(int(r["map"]))
    # loot id -> maps it drops on
    loot_maps = defaultdict(set)
    for r in table(d, "creature_template"):
        lid = int(r["LootId"] or 0)
        if lid:
            loot_maps[("c", lid)] |= cmaps.get(int(r["Entry"]), set())
    for r in table(d, "gameobject_template"):
        if r["type"] == "3":                       # chest: data1 is its loot id
            lid = int(r["data1"] or 0)
            if lid:
                loot_maps[("g", lid)] |= gmaps.get(int(r["entry"]), set())
    refs = defaultdict(list)
    for r in table(d, "reference_loot_template"):
        refs[int(r["entry"])].append(r)

    item_maps = defaultdict(set)

    def walk(rows, maps, depth=0):
        for r in rows:
            mc = int(r["mincountOrRef"])
            if mc < 0 and depth < 6:
                walk(refs.get(-mc, []), maps, depth + 1)
            else:
                item_maps[int(r["item"])] |= maps

    grouped = defaultdict(list)
    for r in table(d, "creature_loot_template"):
        grouped[("c", int(r["entry"]))].append(r)
    for r in table(d, "gameobject_loot_template"):
        grouped[("g", int(r["entry"]))].append(r)
    for key, rows in grouped.items():
        maps = loot_maps.get(key, set()) & set(MAPS)
        if maps:
            walk(rows, maps)

    kit_items = set()
    for k in json.load(open(kits_path)):
        for it in k["items"].values():
            kit_items.add(it["id"])

    pool = {}
    for r in table(d, "item_template"):
        e = int(r["entry"])
        inv = int(r["InventoryType"])
        if e in EXCLUDE or e >= CUSTOM_FROM or inv not in WEARABLE:
            continue
        if any(w in r["name"] for w in BAD_WORDS):
            continue
        if int(r["RequiredLevel"]) > 60 or int(r["Quality"]) < 3:
            continue
        if int(r["ItemLevel"]) < 58 and e not in kit_items:
            continue                               # low-level world drops: not worth a picker row
        tier, why = None, None
        honor = int(r["requiredhonorrank"])
        if e in kit_items:
            tier, why = 0, "kit"
        elif 7 <= honor <= 17:
            tier, why = 0, "PvP rank %d" % (honor - 4)
        elif honor == 18:
            tier, why = 2, "PvP rank 14"
        else:
            maps = item_maps.get(e, set())
            if maps:
                tier = min(MAPS[m] for m in maps)
                why = "world drop" if len(maps) > 3 else ", ".join(sorted(MAP_NAME[m] for m in maps))
        if tier is None:
            continue
        if int(r["Quality"]) == 5 and e not in kit_items:
            tier = 3
        pool[e] = (tier, why, r["name"], inv, int(r["AllowableClass"]))
    return pool


def write_sql(pool, path):
    with open(path, "w") as f:
        f.write("-- Warfront gear picker pool (generated by tools/warfront/gen_pool.py; do not edit)\n")
        f.write("CREATE TABLE IF NOT EXISTS `warfront_item_pool` (\n"
                "  `item` mediumint unsigned NOT NULL,\n"
                "  `tier` tinyint unsigned NOT NULL,\n"
                "  `source` varchar(96) NOT NULL DEFAULT '',\n"
                "  PRIMARY KEY (`item`)\n) ENGINE=InnoDB;\n")
        f.write("DELETE FROM `warfront_item_pool`;\n")
        rows = ["(%d,%d,'%s')" % (e, t, w.replace("'", "''")[:96]) for e, (t, w, _, _, _) in sorted(pool.items())]
        for i in range(0, len(rows), 500):
            f.write("INSERT INTO `warfront_item_pool` (`item`,`tier`,`source`) VALUES\n" + ",\n".join(rows[i:i + 500]) + ";\n")


if __name__ == "__main__":
    pool = build(sys.argv[1], sys.argv[2])
    write_sql(pool, sys.argv[3])
    by = defaultdict(int)
    for t, *_ in pool.values():
        by[t] += 1
    print("%d items: %s" % (len(pool), ", ".join("tier %d: %d" % (t, n) for t, n in sorted(by.items()))))
