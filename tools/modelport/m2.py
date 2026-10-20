"""Write an MD20 version 256 model (WoW 1.12.1) with its skin profile embedded.

The layout follows the engine's own readers (benilla-m2 ``parse_m2``, benilla-formats
``parse_m2_animations``, the asset loader): a 0x144-byte header of ``(count, offset)`` arrays,
68-byte sequences, 108-byte bones with three 28-byte tracks keyed on one shared timeline (one
``(lo, hi)`` key window per sequence), 48-byte vertices, and four 44-byte views sharing one skin.
"""
import struct

import numpy as np

HEADER_SIZE = 0x144


class Blob:
    def __init__(self):
        self.b = bytearray(HEADER_SIZE)

    def add(self, data, align=16):
        if not data:
            return 0
        while len(self.b) % align:
            self.b.append(0)
        o = len(self.b)
        self.b += data
        return o

    def arr(self, at, count, offset):
        struct.pack_into("<II", self.b, at, count, offset if count else 0)


def _track(blob, keys_per_seq, value_fmt, interp=1):
    """One M2Track: ``keys_per_seq`` is a list (per sequence) of [(abs_ms, value), ...].
    Returns the 28-byte record. No keys at all → an empty track."""
    total = sum(len(k) for k in keys_per_seq)
    if total == 0:
        return struct.pack("<Hh6I", 0, -1, 0, 0, 0, 0, 0, 0)
    ranges, times, vals = [], [], []
    for keys in keys_per_seq:
        lo = len(times)
        for t, v in keys:
            times.append(t)
            vals.append(v)
        hi = max(lo, len(times) - 1)
        ranges.append((lo, hi))
    r_off = blob.add(b"".join(struct.pack("<II", a, b) for a, b in ranges), 4)
    t_off = blob.add(struct.pack(f"<{len(times)}I", *times), 4)
    v_off = blob.add(b"".join(struct.pack(value_fmt, *v) for v in vals), 4)
    return struct.pack("<Hh6I", interp, -1, len(ranges), r_off, len(times), t_off, len(vals), v_off)


def _empty_track():
    return struct.pack("<Hh6I", 0, -1, 0, 0, 0, 0, 0, 0)


def write(model):
    """``model`` is the dict ``port.build`` makes. Returns the file bytes."""
    m = model
    blob = Blob()
    hdr = blob.b
    hdr[0:4] = b"MD20"
    struct.pack_into("<I", hdr, 4, 256)

    name = m["name"].encode("ascii", "replace") + b"\0"
    blob.arr(0x08, len(name), blob.add(name, 4))
    struct.pack_into("<I", hdr, 0x10, 0)  # flags
    blob.arr(0x14, 0, 0)  # global sequences

    # sequences
    seqs = m["sequences"]
    seq_bytes = b""
    for s in seqs:
        seq_bytes += struct.pack(
            "<HHIIfIhHIII3f3ffhH",
            s["id"], s["variation"], s["start"], s["end"], s["move_speed"], s["flags"],
            s["frequency"], 0, 0, 0, s["blend"],
            *s["bmin"], *s["bmax"], s["radius"], s["next"], s["alias"],
        )
    blob.arr(0x1c, len(seqs), blob.add(seq_bytes))
    lookup = m["animation_lookup"]
    blob.arr(0x24, len(lookup), blob.add(struct.pack(f"<{len(lookup)}H", *lookup), 4))
    pal = m["playable_lookup"]
    blob.arr(0x2c, len(pal), blob.add(b"".join(struct.pack("<HH", a, b) for a, b in pal), 4))

    # bones: tracks first (their arrays), then the records
    recs = []
    for bone in m["bones"]:
        tt = _track(blob, bone["t_keys"], "<3f")
        rt = _track(blob, bone["r_keys"], "<4f")
        st = _track(blob, bone["s_keys"], "<3f")
        recs.append(struct.pack("<iIhH", bone["key_bone"], bone["flags"], bone["parent"], 0)
                    + tt + rt + st + struct.pack("<3f", *bone["pivot"]))
    blob.arr(0x34, len(recs), blob.add(b"".join(recs)))
    kbl = m["key_bone_lookup"]
    blob.arr(0x3c, len(kbl), blob.add(struct.pack(f"<{len(kbl)}h", *kbl), 4))

    # vertices: 48 bytes
    v = m["vertices"]
    n = len(v["pos"])
    vb = np.zeros(n, dtype=[("p", "<f4", 3), ("w", "u1", 4), ("i", "u1", 4), ("n", "<f4", 3),
                            ("uv", "<f4", 2), ("uv2", "<f4", 2)])
    vb["p"], vb["w"], vb["i"], vb["n"], vb["uv"] = v["pos"], v["weights"], v["bones"], v["normal"], v["uv"]
    assert vb.dtype.itemsize == 48
    blob.arr(0x44, n, blob.add(vb.tobytes()))

    # colours: none
    blob.arr(0x54, 0, 0)

    # textures (16 bytes: type, flags, filename)
    trecs = []
    for t in m["textures"]:
        fn = t["file"].encode("ascii") + b"\0" if t["file"] else b"\0"
        fo = blob.add(fn, 4)
        trecs.append(struct.pack("<IIII", t["type"], t["flags"], len(fn) if t["file"] else 0, fo if t["file"] else 0))
    blob.arr(0x5c, len(trecs), blob.add(b"".join(trecs)))

    # texture weights: one, constant 1.0 (fix16 32767), keyed in every sequence
    one_key = [[(s["start"], (32767,))] for s in seqs]
    wt = _track(blob, one_key, "<h", interp=0)
    blob.arr(0x64, 1, blob.add(wt))
    blob.arr(0x6c, 0, 0)  # texture flipbooks
    blob.arr(0x74, 0, 0)  # texture transforms
    rtl = m["replaceable_lookup"]
    blob.arr(0x7c, len(rtl), blob.add(struct.pack(f"<{len(rtl)}h", *rtl), 4))
    mats = m["materials"]
    blob.arr(0x84, len(mats), blob.add(b"".join(struct.pack("<HH", f, b) for f, b in mats), 4))
    bl = m["bone_lookup"]
    blob.arr(0x8c, len(bl), blob.add(struct.pack(f"<{len(bl)}H", *bl), 4))
    tl = m["texture_lookup"]
    blob.arr(0x94, len(tl), blob.add(struct.pack(f"<{len(tl)}H", *tl), 4))
    blob.arr(0x9c, 1, blob.add(struct.pack("<H", 0), 4))  # texture unit lookup: UV 0
    blob.arr(0xa4, 1, blob.add(struct.pack("<H", 0), 4))  # transparency lookup → weight 0
    blob.arr(0xac, 1, blob.add(struct.pack("<h", -1), 4))  # texture transform lookup: none

    bmin, bmax, rad = m["bounds"]
    struct.pack_into("<3f3ff", hdr, 0xb4, *bmin, *bmax, rad)
    cmin, cmax, crad = m["collision_bounds"]
    struct.pack_into("<3f3ff", hdr, 0xd0, *cmin, *cmax, crad)
    ctri, cvert, cnorm = m["collision"]
    blob.arr(0xec, len(ctri), blob.add(struct.pack(f"<{len(ctri)}H", *ctri), 4))
    blob.arr(0xf4, len(cvert), blob.add(b"".join(struct.pack("<3f", *p) for p in cvert), 4))
    blob.arr(0xfc, len(cnorm), blob.add(b"".join(struct.pack("<3f", *p) for p in cnorm), 4))

    # attachments: 48 bytes (id, bone, position, a visibility track)
    arecs = []
    for a in m["attachments"]:
        vis = _track(blob, [[(s["start"], (1,))] for s in seqs], "<I", interp=0)
        arecs.append(struct.pack("<II3f", a["id"], a["bone"], *a["position"]) + vis)
    blob.arr(0x104, len(arecs), blob.add(b"".join(arecs)))
    al = m["attach_lookup"]
    blob.arr(0x10c, len(al), blob.add(struct.pack(f"<{len(al)}h", *al), 4))
    blob.arr(0x114, 0, 0)  # events
    blob.arr(0x11c, 0, 0)  # lights

    # cameras: 0x7c bytes (type, fov, far, near, position track, position base, target track,
    # target base, roll track), all tracks keyless
    crecs = []
    for c in m["cameras"]:
        crecs.append(struct.pack("<ifff", c["type"], c["fov"], c["far"], c["near"]) + _empty_track()
                     + struct.pack("<3f", *c["position"]) + _empty_track()
                     + struct.pack("<3f", *c["target"]) + _empty_track())
    assert all(len(r) == 0x7c for r in crecs)
    blob.arr(0x124, len(crecs), blob.add(b"".join(crecs)))
    cl = m["camera_lookup"]
    blob.arr(0x12c, len(cl), blob.add(struct.pack(f"<{len(cl)}h", *cl), 4))
    blob.arr(0x134, 0, 0)  # ribbons
    blob.arr(0x13c, 0, 0)  # particles

    # the skin profile, embedded; four LOD views share it (the 1.12 client picks by detail level)
    sk = m["skin"]
    o_idx = blob.add(struct.pack(f"<{len(sk['indices'])}H", *sk["indices"]), 4)
    o_tri = blob.add(struct.pack(f"<{len(sk['triangles'])}H", *sk["triangles"]), 4)
    o_prop = blob.add(bytes(np.asarray(sk["properties"], dtype=np.uint8).reshape(-1)), 4)
    subs = b""
    for s in sk["submeshes"]:
        subs += struct.pack("<10H3f", s["id"], 0, s["vstart"], s["vcount"], s["istart"], s["icount"],
                            s["bone_count"], s["bone_start"], s["influences"], s["center_bone"], *s["center"])
    o_sub = blob.add(subs, 4)
    bats = b""
    for i, bt in enumerate(sk["batches"]):
        bats += struct.pack("<BbHHHHHHHHHHH", 16, 0, 0, bt["submesh"], bt["submesh"], 0xffff, bt["material"],
                            0, 1, bt["texture"], 0, 0, 0)
    o_bat = blob.add(bats, 4)
    view = struct.pack("<10II", len(sk["indices"]), o_idx, len(sk["triangles"]), o_tri,
                       len(sk["indices"]), o_prop, len(sk["submeshes"]), o_sub,
                       len(sk["batches"]), o_bat, sk["bone_count_max"])
    blob.arr(0x4c, 4, blob.add(view * 4, 4))
    return bytes(blob.b)
