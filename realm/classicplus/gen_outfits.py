"""Starting gear for every race/class combo: extend the server's own CharStartOutfit.dbc.

    python3 gen_outfits.py <stock CharStartOutfit.dbc> <output.dbc>

Each missing (race, class, gender) copies the gear of the same class and gender from a race of the
same faction (any race if none). Runs on the realm server against the DBC extracted from the
operator's own client, so no game data lives in the Open Vanilla repository.
"""
import struct
import sys

RACES = range(1, 9)
CLASSES = [1, 2, 3, 4, 5, 7, 8, 9, 11]
ALLIANCE = {1, 3, 4, 7}

src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
if d[:4] != b"WDBC":
    sys.exit(f"{src} is not a DBC file")
n, fc, rs, ss = struct.unpack("<4I", d[4:20])
recs = [bytearray(d[20 + i * rs:20 + (i + 1) * rs]) for i in range(n)]
strings = d[20 + n * rs:]
by = {(r[4], r[5], r[6]): r for r in recs}
next_id = max(struct.unpack("<I", r[:4])[0] for r in recs) + 1
added = 0
for race in RACES:
    for cls in CLASSES:
        for g in (0, 1):
            if (race, cls, g) in by:
                continue
            cands = sorted(k for k in by if k[1] == cls and k[2] == g)
            same = [k for k in cands if (k[0] in ALLIANCE) == (race in ALLIANCE)]
            if not cands:
                continue
            rec = bytearray(by[(same or cands)[0]])
            struct.pack_into("<I", rec, 0, next_id)
            rec[4] = race
            recs.append(rec)
            by[(race, cls, g)] = rec
            next_id += 1
            added += 1
open(dst, "wb").write(b"WDBC" + struct.pack("<4I", len(recs), fc, rs, len(strings)) + b"".join(recs) + strings)
print(f"CharStartOutfit: {n} -> {len(recs)} records (+{added})")
