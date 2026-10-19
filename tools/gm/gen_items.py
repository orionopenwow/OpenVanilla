"""Export the server's item table for the GM panel's Armory (www/gm/data/items.json).

Run from the Open Vanilla folder with the database running:  python gen_items.py
Re-run it whenever you add or change items in the world database. Read-only on the database.
"""
import json
import os
import sys

import server_control

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "www", "gm", "data", "items.json")


def unescape(v):
    # mysql batch mode escapes \t \n \\ \0 inside values
    if v == "NULL":
        return None
    out, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v):
            n = v[i + 1]
            out.append({"t": "\t", "n": "\n", "\\": "\\", "0": ""}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def main():
    ret, out, err = server_control.run_mysql_query(
        "SET NAMES utf8; USE classicmangos; SELECT * FROM item_template ORDER BY entry;"
    )
    if ret != 0:
        sys.exit(f"[ERROR] Database query failed (is the database running?): {err.strip()}")
    lines = out.split("\n")
    header = [h.lower() for h in lines[0].split("\t")]
    col = {h: i for i, h in enumerate(header)}

    def g(row, name, default=0):
        i = col.get(name.lower())
        if i is None or i >= len(row):
            return default
        v = unescape(row[i])
        return default if v is None else v

    def n(row, name):
        try:
            return int(float(g(row, name, 0)))
        except ValueError:
            return 0

    fields = ["id", "name", "q", "inv", "cls", "sub", "ilvl", "req", "allow", "disp", "set", "bond",
              "armor", "dur", "delay", "dmin", "dmax", "dtype", "stats", "res", "spells", "stack", "desc", "slots", "block"]
    rows = []
    for line in lines[1:]:
        if not line.strip():
            continue
        r = line.split("\t")
        stats = [[n(r, f"stat_type{i}"), n(r, f"stat_value{i}")] for i in range(1, 11) if n(r, f"stat_value{i}")]
        spells = [[n(r, f"spellid_{i}"), n(r, f"spelltrigger_{i}")] for i in range(1, 6) if n(r, f"spellid_{i}")]
        res = [n(r, k) for k in ("holy_res", "fire_res", "nature_res", "frost_res", "shadow_res", "arcane_res")]
        rows.append([
            n(r, "entry"), g(r, "name", ""), n(r, "quality"), n(r, "inventorytype"), n(r, "class"), n(r, "subclass"),
            n(r, "itemlevel"), n(r, "requiredlevel"), n(r, "allowableclass"), n(r, "displayid"), n(r, "itemset"),
            n(r, "bonding"), n(r, "armor"), n(r, "maxdurability"), n(r, "delay"),
            round(float(g(r, "dmg_min1", 0) or 0)), round(float(g(r, "dmg_max1", 0) or 0)), n(r, "dmg_type1"),
            stats, res if any(res) else 0, spells, n(r, "stackable"), g(r, "description", "") or "", n(r, "containerslots"), n(r, "block"),
        ])
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"fields": fields, "rows": rows}, f, ensure_ascii=False, separators=(",", ":"))
    print(f"[OK] Exported {len(rows)} items to {OUT} ({os.path.getsize(OUT) // 1024} KB).")


if __name__ == "__main__":
    main()
