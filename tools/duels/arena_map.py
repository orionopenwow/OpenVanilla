"""
arena_map.py  (Open Vanilla / Duels)

Gurubashi Arena as a map of its own: map 900, a party-instance copy of Eastern Kingdoms. Every
duel gets its own copy of it (an instance per match, like the Ring of Law), on the very same
terrain, so dozens of 1v1s run at once on Gurubashi's sand without seeing each other.

What a new map needs, and where this script puts it:

    Map.dbc    a row 900: directory "Azeroth" (the client streams Eastern Kingdoms' own tiles),
               instance type 1 (party), name "Gurubashi Arena", area 1741 (Gurubashi Arena)
    Light.dbc  map 0's light rows again for map 900 (else the sky falls back to Azeroth's global
               light, not Stranglethorn's)

    server     python3 arena_map.py server DBC_DIR               edits DBC_DIR/Map.dbc in place
    client     python3 arena_map.py client DBC_DIR IN.MPQ OUT.MPQ  IN plus the two tables -> OUT
    check      python3 arena_map.py check DBC_DIR                  prints the new rows

DBC_DIR holds the stock tables (the server's extracted dbc folder: the same files as the client's).
Run by hetzner/duels_up.sh at install and update, on the server: the tables are Blizzard's data, so
the result is never committed or published anywhere but the realm's own client patch. The maps,
vmaps and mmaps for map 900 are links to map 0's files (duels_up.sh, arena_links). Both steps
are idempotent: a table that already has the row is rewritten the same.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
for p in (os.path.join(HERE, "..", "modelport"), os.path.join(HERE, "modelport")):
    if os.path.exists(os.path.join(p, "mpq.py")):
        sys.path.insert(0, p)

ARENA_MAP = 900
SOURCE_MAP = 0          # its terrain, models and directory
TEMPLATE_MAP = 230      # an instance row (Blackrock Depths) for the other columns
NAME = "Gurubashi Arena"
AREA = 1741             # AreaTable: Gurubashi Arena (zone 33, Stranglethorn Vale)
LOADING_SCREEN = 4      # Eastern Kingdoms

MAP_FIELDS = 42
F_ID, F_DIR, F_TYPE, F_PVP, F_NAME, F_AREA, F_LOADING = 0, 1, 2, 3, 4, 19, 38
NAME_FIELDS = range(4, 12)      # MapName, eight locales (field 12 is the locale mask)
LIGHT_FIELDS = 12


def parse(data):
    magic, n, f, rs, ss = struct.unpack("<4s4I", data[:20])
    if magic != b"WDBC":
        raise ValueError("not a DBC")
    rows = [bytearray(data[20 + i * rs:20 + (i + 1) * rs]) for i in range(n)]
    strings = bytearray(data[20 + n * rs:20 + n * rs + ss])
    return f, rs, rows, strings


def build(f, rs, rows, strings):
    return struct.pack("<4s4I", b"WDBC", len(rows), f, rs, len(strings)) + b"".join(bytes(r) for r in rows) + bytes(strings)


def u32(row, k):
    return struct.unpack_from("<I", row, k * 4)[0]


def put(row, k, v):
    struct.pack_into("<I", row, k * 4, v)


def add_string(strings, s):
    b = s.encode("utf-8") + b"\0"
    at = strings.find(b"\0" + b)
    if at >= 0:
        return at + 1
    off = len(strings)
    strings += b
    return off


def map_dbc(data):
    f, rs, rows, strings = parse(data)
    if f != MAP_FIELDS:
        raise ValueError("Map.dbc with %d fields, expected %d (1.12)" % (f, MAP_FIELDS))
    rows = [r for r in rows if u32(r, F_ID) != ARENA_MAP]
    by_id = {u32(r, F_ID): r for r in rows}
    src, tpl = by_id[SOURCE_MAP], by_id[TEMPLATE_MAP]
    row = bytearray(tpl)
    put(row, F_ID, ARENA_MAP)
    put(row, F_DIR, u32(src, F_DIR))        # "Azeroth": the client loads Eastern Kingdoms' tiles
    put(row, F_TYPE, 1)                     # a party instance: one copy per match
    put(row, F_PVP, 0)
    name = add_string(strings, NAME)
    for k in NAME_FIELDS:
        put(row, k, name if k == F_NAME else 0)
    put(row, F_AREA, AREA)
    put(row, F_LOADING, LOADING_SCREEN)
    rows.append(row)
    rows.sort(key=lambda r: u32(r, F_ID))
    return build(f, rs, rows, strings)


def light_dbc(data):
    f, rs, rows, strings = parse(data)
    if f != LIGHT_FIELDS:
        raise ValueError("Light.dbc with %d fields, expected %d (1.12)" % (f, LIGHT_FIELDS))
    rows = [r for r in rows if u32(r, 1) != ARENA_MAP]
    next_id = max(u32(r, 0) for r in rows) + 1
    added = []
    for r in rows:
        if u32(r, 1) == SOURCE_MAP:
            c = bytearray(r)
            put(c, 0, next_id)
            put(c, 1, ARENA_MAP)
            next_id += 1
            added.append(c)
    return build(f, rs, rows + added, strings)


def find(dbc_dir, name):
    for n in os.listdir(dbc_dir):
        if n.lower() == name.lower():
            return os.path.join(dbc_dir, n)
    raise FileNotFoundError(os.path.join(dbc_dir, name))


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def write(path, data):
    tmp = path + ".new"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


def check(dbc_dir):
    f, rs, rows, strings = parse(map_dbc(read(find(dbc_dir, "Map.dbc"))))
    row = [r for r in rows if u32(r, F_ID) == ARENA_MAP][0]
    s = lambda o: strings[o:strings.index(b"\0", o)].decode()
    print("Map.dbc %d: %s, type %d, \"%s\", area %d, loading screen %d" % (
        ARENA_MAP, s(u32(row, F_DIR)), u32(row, F_TYPE), s(u32(row, F_NAME)), u32(row, F_AREA), u32(row, F_LOADING)))
    lf, lrs, lrows, _ = parse(light_dbc(read(find(dbc_dir, "Light.dbc"))))
    print("Light.dbc: %d rows for map %d" % (sum(1 for r in lrows if u32(r, 1) == ARENA_MAP), ARENA_MAP))


def main(argv):
    if len(argv) >= 2 and argv[0] == "server":
        p = find(argv[1], "Map.dbc")
        write(p, map_dbc(read(p)))
        print("%s: map %d (%s)" % (p, ARENA_MAP, NAME))
        return 0
    if len(argv) >= 4 and argv[0] == "client":
        import mpq
        src = mpq.Archive(argv[2])
        files = {}
        for n in src.names():
            if n.startswith("(") or n.lower() in ("dbfilesclient\\map.dbc", "dbfilesclient\\light.dbc"):
                continue
            files[n] = src.read(n)
        files["DBFilesClient\\Map.dbc"] = map_dbc(read(find(argv[1], "Map.dbc")))
        files["DBFilesClient\\Light.dbc"] = light_dbc(read(find(argv[1], "Light.dbc")))
        tmp = argv[3] + ".new"
        mpq.write(tmp, files)
        back = mpq.Archive(tmp)
        assert back.read("DBFilesClient\\Map.dbc") == files["DBFilesClient\\Map.dbc"], "Map.dbc did not read back"
        os.replace(tmp, argv[3])
        print("%s: %d files, with map %d in Map.dbc and Light.dbc" % (argv[3], len(files), ARENA_MAP))
        return 0
    if len(argv) >= 2 and argv[0] == "check":
        check(argv[1])
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
