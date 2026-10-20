"""Server copy of CreatureModelData.dbc / CreatureDisplayInfo.dbc: the stock table plus the rows
the model porter made (classicplus_world_models.json), so mangosd knows every ported model.

    python3 apply_models_dbc.py <rows.json> <table name> <stock.dbc> <out.dbc>

Idempotent: works from the stock file, replacing rows with the same id.
"""
import json
import struct
import sys

rows_path, table, src, dst = sys.argv[1:5]
rows = json.load(open(rows_path)).get(table, [])
b = open(src, "rb").read()
n, f, rs, ss = struct.unpack_from("<4I", b, 4)
recs = bytearray(b[20:20 + n * rs])
strs = bytearray(b[20 + n * rs:20 + n * rs + ss])
index = {struct.unpack_from("<I", recs, i * rs)[0]: i for i in range(n)}
for r in rows:
    vals = []
    for v in r:
        if isinstance(v, list):  # ["s", text]: a string, appended to the string block
            off = len(strs)
            strs += v[1].encode("latin1", "replace") + b"\0"
            vals.append(off if v[1] else 0)
        else:
            vals.append(v & 0xFFFFFFFF)
    data = struct.pack(f"<{f}I", *vals)
    if vals[0] in index:
        i = index[vals[0]]
        recs[i * rs:(i + 1) * rs] = data
    else:
        index[vals[0]] = n
        recs += data
        n += 1
open(dst, "wb").write(b"WDBC" + struct.pack("<4I", n, f, rs, len(strs)) + bytes(recs) + bytes(strs))
print(f"{table}: +{len(rows)} ported model row(s), {n} records")
