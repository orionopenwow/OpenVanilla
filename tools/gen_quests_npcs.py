"""Build Data/Interface/AddOns/Quests/NpcData.lua: the built-in list of service NPCs (repairers,
general-goods vendors, innkeepers, flight masters, bankers and class trainers) in the six
capitals and the six starting zones. The Quests addon uses it until the realm sends `NP` packets.

    python3 tools/gen_quests_npcs.py /path/to/ClassicDB_1_12_1_*.sql[.gz]

Source: the CMaNGOS classic world database (creature_template flags and subnames, creature
spawns). Spawn positions are converted to zone map coordinates with the 1.12 WorldMapArea
bounds below, so the coordinates match what GetPlayerMapPosition reports in game.
"""
import gzip
import os
import sys

# zone -> (area id, map, locLeft, locRight, locTop, locBottom, faction); left/right are world Y,
# top/bottom world X (WorldMapArea.dbc, 1.12.1).
ZONES = {
    "Elwynn Forest":   (12,   0, 1535.4166, -1935.4166, -7939.5833, -10254.1666, "Alliance"),
    "Dun Morogh":      (1,    0, 1802.0833, -3122.9166, -3877.0833, -7160.4166, "Alliance"),
    "Teldrassil":      (141,  1, 3814.5833, -1277.0833, 11831.25, 8437.5, "Alliance"),
    "Stormwind City":  (1519, 0, 1380.9713, 36.7014, -8278.8505, -9175.2048, "Alliance"),
    "Ironforge":       (1537, 0, -713.5914, -1504.2164, -4569.2412, -5096.8457, "Alliance"),
    "Darnassus":       (1657, 1, 2938.3626, 1880.0292, 10238.3164, 9532.5869, "Alliance"),
    "Durotar":         (14,   1, -1962.4999, -7249.9999, 1808.3333, -1716.6666, "Horde"),
    "Mulgore":         (215,  1, 2047.9166, -3089.5833, -272.9166, -3697.9166, "Horde"),
    "Tirisfal Glades": (85,   0, 3033.3333, -1485.4166, 3837.4999, 824.9999, "Horde"),
    "Orgrimmar":       (1637, 1, -3680.6011, -5083.2056, 2273.8772, 1338.4606, "Horde"),
    "Thunder Bluff":   (1638, 1, 516.6666, -527.0833, -849.9999, -1545.8333, "Horde"),
    "Undercity":       (1497, 0, 873.1926, -86.1824, 1877.9453, 1237.8412, "Horde"),
}
# A city's map rectangle sits inside its parent zone's; a spawn inside it belongs to the city
# (Undercity only below ground: the Ruins of Lordaeron above it are Tirisfal Glades).
CITY_OF = {"Elwynn Forest": "Stormwind City", "Dun Morogh": "Ironforge", "Teldrassil": "Darnassus",
           "Durotar": "Orgrimmar", "Mulgore": "Thunder Bluff", "Tirisfal Glades": "Undercity"}

VENDOR, FLIGHT, TRAINER, INNKEEPER, BANKER, REPAIR = 0x4, 0x8, 0x10, 0x80, 0x100, 0x4000
CLASSES = {1: "WARRIOR", 2: "PALADIN", 3: "HUNTER", 4: "ROGUE", 5: "PRIEST", 7: "SHAMAN",
           8: "MAGE", 9: "WARLOCK", 11: "DRUID"}
SEASONAL = ("Smokywood", "Hallow", "Argent Dawn", "Treats", "Fireworks", "Quartermaster", "Morale")
GENERAL = ("General", "Trade Supplies", "Trade Supplier", "Trade Goods", "Tradesman")


def tuples(line):
    i = line.index("VALUES") + 6
    out, cur, tok, inq, depth = [], [], "", False, 0
    while i < len(line):
        c = line[i]
        if inq:
            if c == "\\":
                tok += line[i + 1]
                i += 2
                continue
            if c == "'":
                inq = False
            else:
                tok += c
        elif c == "'":
            inq = True
        elif c == "(" and not depth:
            depth, cur, tok = 1, [], ""
        elif c == "," and depth:
            cur.append(tok)
            tok = ""
        elif c == ")" and depth:
            cur.append(tok)
            out.append(cur)
            depth, tok = 0, ""
        elif depth:
            tok += c
        i += 1
    return out


def load(path):
    opener = gzip.open if path.endswith(".gz") else open
    tmpl, spawns = {}, {}
    with opener(path, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("INSERT INTO `creature_template` "):
                for t in tuples(line):
                    # Entry, Name, SubName, NpcFlags, TrainerType, TrainerClass
                    tmpl[int(t[0])] = (t[1], None if t[2] == "NULL" else t[2], int(t[16]), int(t[71]), int(t[73]))
            elif line.startswith("INSERT INTO `creature` "):
                for t in tuples(line):
                    spawns.setdefault(int(t[1]), []).append((int(t[2]), float(t[4]), float(t[5]), float(t[6])))
    return tmpl, spawns


def to_map(zone, m, wx, wy):
    _, zm, l, r, t, b, _ = ZONES[zone]
    if m != zm:
        return None
    x, y = (l - wy) / (l - r), (t - wx) / (t - b)
    if 0 < x < 1 and 0 < y < 1:
        return x, y
    return None


def zone_of(m, wx, wy, wz):
    for parent, city in CITY_OF.items():
        if to_map(city, m, wx, wy) and (city != "Undercity" or wz < 0):
            return city, to_map(city, m, wx, wy)
        p = to_map(parent, m, wx, wy)
        if p:
            return parent, p
    return None, None


def flags_of(sub, npcflags, ttype, tclass):
    sub = sub or ""
    if any(s in sub for s in SEASONAL):
        return ""
    f = ""
    if npcflags & REPAIR:
        f += "R"
    if npcflags & VENDOR and (npcflags & REPAIR or any(g in sub for g in GENERAL)):
        f += "V"
    if npcflags & FLIGHT:
        f += "F"
    if npcflags & INNKEEPER and "Innkeeper" in sub:
        f += "I"
    if npcflags & TRAINER and ttype == 0 and tclass in CLASSES:
        f += "T"
    if npcflags & BANKER:
        f += "B"
    return f


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(src, out):
    tmpl, spawns = load(src)
    rows = {z: [] for z in ZONES}
    for entry, (name, sub, npcflags, ttype, tclass) in sorted(tmpl.items()):
        f = flags_of(sub, npcflags, ttype, tclass)
        if not f or entry not in spawns:
            continue
        m, wx, wy, wz = spawns[entry][0]
        zone, p = zone_of(m, wx, wy, wz)
        if not zone:
            continue
        cls = CLASSES.get(tclass, "") if "T" in f else ""
        rows[zone].append((entry, p[0], p[1], f, name, sub or "", cls))
    lines = [
        "-- NpcData.lua - generated by tools/gen_quests_npcs.py from the CMaNGOS classic world DB.",
        "-- Service NPCs in the six capitals and the six starting zones, used until the realm sends",
        "-- NP packets. Do not edit by hand. Row: { npcId, x, y, flags, name, subname, class }",
        "-- flags: R repair, V vendor, F flight master, I innkeeper, T class trainer, B banker.",
        "",
        "Compass = Compass or {}",
        "Compass.NPC_ZONES = {",
    ]
    for zone in ZONES:
        area, _, _, _, _, _, side = ZONES[zone]
        lines.append("    [%s] = { id = %d, faction = %s, npcs = {" % (lua_str(zone), area, lua_str(side)))
        for (e, x, y, f, name, sub, cls) in sorted(rows[zone], key=lambda r: r[0]):
            lines.append("        { %d, %.3f, %.3f, %s, %s, %s, %s }," % (e, x, y, lua_str(f), lua_str(name), lua_str(sub), lua_str(cls)))
        lines.append("    } },")
    lines.append("}")
    with open(out, "w", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print("wrote", out, sum(len(r) for r in rows.values()), "NPCs")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    here = os.path.dirname(os.path.abspath(__file__))
    main(sys.argv[1], os.path.join(here, "..", "Data", "Interface", "AddOns", "Quests", "NpcData.lua"))
