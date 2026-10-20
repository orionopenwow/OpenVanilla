#!/usr/bin/env python3
"""Copy a LITE set of server world data: the starting zones and the two capitals only.

    python3 devkit/staging/make_lite_maps.py <full data dir> <out dir> [--margin 1]

<full data dir> holds dbc/ maps/ vmaps/ mmaps/ as `realmctl extract` makes them. The output has
all of dbc/, the per-map headers, and only the map/vmap/mmap tiles around:
  Eastern Kingdoms: Northshire, Elwynn Forest, Stormwind      Kalimdor: Valley of Trials, Durotar, Orgrimmar
For a realm on your PC where the full set (gigabytes) is too much. The staging realm on the
server doesn't need this: it shares the live realm's data read-only at no cost.

Unproven: whether the world server is happy with missing tiles everywhere else. Characters must
stay inside these areas (Herald does). Tile names differ between files, so both orders of the
grid numbers are kept; a few extra tiles cost nothing.
"""
import math
import os
import re
import shutil
import sys

GRID = 533.3333
# (map id, x min, x max, y min, y max) in world coordinates
AREAS = [
    (0, -10200, -7900, -1600, 1400),    # Northshire, Elwynn Forest, Stormwind City
    (1, -1200, 2400, -5400, -3700),     # Valley of Trials, Durotar, Orgrimmar
]


def tiles(margin):
    keep = set()
    for m, x0, x1, y0, y1 in AREAS:
        gx = sorted({int(math.floor(32 - x / GRID)) for x in (x0, x1)})
        gy = sorted({int(math.floor(32 - y / GRID)) for y in (y0, y1)})
        for a in range(gx[0] - margin, gx[-1] + margin + 1):
            for b in range(gy[0] - margin, gy[-1] + margin + 1):
                for p, q in ((a, b), (b, a), (63 - a, 63 - b), (63 - b, 63 - a)):
                    keep.add((m, p, q))
    return keep


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    margin = int(sys.argv[sys.argv.index("--margin") + 1]) if "--margin" in sys.argv else 1
    keep = tiles(margin)
    maps = {m for m, _, _, _, _ in AREAS}
    tile_re = re.compile(r"^(\d{3})(\d{2})(\d{2})\.(map|mmtile|vmtile)$|^(\d{3})_(\d{2})_(\d{2})\.vmtile$")
    copied = skipped = 0
    for sub in ("dbc", "maps", "vmaps", "mmaps"):
        d = os.path.join(src, sub)
        if not os.path.isdir(d):
            continue
        os.makedirs(os.path.join(out, sub), exist_ok=True)
        for name in os.listdir(d):
            full = os.path.join(d, name)
            if sub == "dbc":
                ok = True
            else:
                m = tile_re.match(name)
                if m:
                    g = m.groups()
                    mid, a, b = (int(g[0]), int(g[1]), int(g[2])) if g[0] else (int(g[4]), int(g[5]), int(g[6]))
                    ok = (mid, a, b) in keep
                else:
                    head = re.match(r"^(\d{3})", name)   # per-map headers (000.mmap, 000.vmtree) and models
                    ok = not head or int(head.group(1)) in maps
            if ok:
                (shutil.copytree if os.path.isdir(full) else shutil.copy2)(full, os.path.join(out, sub, name))
                copied += 1
            else:
                skipped += 1
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(out) for f in fs)
    print(f"kept {copied} files, left out {skipped}; {size / 1e6:.0f} MB in {out}")


if __name__ == "__main__":
    main()
