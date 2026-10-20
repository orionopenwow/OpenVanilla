"""Read a ported M2 back for the preview, so what the porter shows is what was written."""
import struct

import numpy as np


def _arr(b, at):
    return struct.unpack_from("<II", b, at)


def _track(b, at, vfmt, vsize, nseq):
    interp, gseq, rn, ro, tn, to, vn, vo = struct.unpack_from("<Hh6I", b, at)
    n = min(tn, vn)
    times = struct.unpack_from(f"<{n}I", b, to) if n else ()
    vals = [struct.unpack_from(vfmt, b, vo + i * vsize) for i in range(n)]
    ranges = [struct.unpack_from("<II", b, ro + i * 8) for i in range(rn)]
    out = []
    for s in range(nseq):
        if not n:
            out.append([])
            continue
        lo, hi = ranges[s] if s < len(ranges) else (0, n - 1)
        out.append([(times[k], vals[k]) for k in range(lo, min(hi, n - 1) + 1)])
    return out


def read(b):
    assert b[:4] == b"MD20"
    sn, so = _arr(b, 0x1c)
    seqs = []
    for i in range(sn):
        r = struct.unpack_from("<HHIIfIhHIII3f3ffhH", b, so + i * 0x44)
        seqs.append({"id": r[0], "var": r[1], "start": r[2], "end": r[3], "speed": r[4], "loop": not (r[5] & 1)})
    bn, bo = _arr(b, 0x34)
    bones = []
    for i in range(bn):
        o = bo + i * 108
        kb, fl, parent, _ = struct.unpack_from("<iIhH", b, o)
        pivot = struct.unpack_from("<3f", b, o + 96)
        bones.append({
            "parent": parent, "pivot": pivot,
            "t": _track(b, o + 0x0c, "<3f", 12, sn),
            "r": _track(b, o + 0x28, "<4f", 16, sn),
            "s": _track(b, o + 0x44, "<3f", 12, sn),
        })
    vn, vo = _arr(b, 0x44)
    vb = np.frombuffer(b, dtype=[("p", "<f4", 3), ("w", "u1", 4), ("i", "u1", 4), ("n", "<f4", 3),
                                 ("uv", "<f4", 2), ("uv2", "<f4", 2)], count=vn, offset=vo)
    tn, to = _arr(b, 0x5c)
    textures = []
    for i in range(tn):
        ttype, fl, fnn, fno = struct.unpack_from("<IIII", b, to + i * 16)
        name = b[fno:fno + fnn].split(b"\0")[0].decode("latin1") if fnn else ""
        textures.append({"type": ttype, "file": name})
    mn, mo = _arr(b, 0x84)
    mats = [struct.unpack_from("<HH", b, mo + i * 4) for i in range(mn)]
    tln, tlo = _arr(b, 0x94)
    tlookup = struct.unpack_from(f"<{tln}H", b, tlo) if tln else ()
    an, ao = _arr(b, 0x104)
    atts = []
    for i in range(an):
        aid, bone = struct.unpack_from("<II", b, ao + i * 48)
        atts.append({"id": aid, "bone": bone, "pos": struct.unpack_from("<3f", b, ao + i * 48 + 8)})
    _, vwo = _arr(b, 0x4c)
    ni, oi, nt, ot, _, _, ns, os_, nb, ob, _ = struct.unpack_from("<10II", b, vwo)
    idx = np.frombuffer(b, dtype="<u2", count=ni, offset=oi)
    tris = np.frombuffer(b, dtype="<u2", count=nt, offset=ot)
    subs = [struct.unpack_from("<10H3f", b, os_ + i * 32) for i in range(ns)]
    batches = []
    for i in range(nb):
        u = b[ob + i * 24: ob + i * 24 + 24]
        sub, = struct.unpack_from("<H", u, 4)
        mat, = struct.unpack_from("<H", u, 0x0a)
        tcombo, = struct.unpack_from("<H", u, 0x10)
        istart, icount = subs[sub][4], subs[sub][5]
        batches.append({"start": istart, "count": icount, "material": mats[mat] if mat < len(mats) else (0, 0),
                        "texture": tlookup[tcombo] if tcombo < len(tlookup) else 0})
    return {"seqs": seqs, "bones": bones, "verts": vb, "index": idx[tris], "batches": batches,
            "textures": textures, "attachments": atts}


def preview_json(b):
    """The model as plain JSON for the viewer: mesh, skeleton, and every animation's keys."""
    m = read(b)
    v = m["verts"]
    seqs = m["seqs"]
    bones = []
    for bone in m["bones"]:
        bones.append({"parent": bone["parent"], "pivot": [round(x, 5) for x in bone["pivot"]]})
    anims = []
    for si, s in enumerate(seqs):
        tracks = []
        for bi, bone in enumerate(m["bones"]):
            tk, rk, sk = bone["t"][si], bone["r"][si], bone["s"][si]
            if not (tk or rk or sk):
                continue
            rel = lambda keys: [[round((t - s["start"]) / 1000.0, 4)] + [round(x, 5) for x in val] for t, val in keys]
            tracks.append({"bone": bi, "t": rel(tk), "r": rel(rk), "s": rel(sk)})
        anims.append({"id": s["id"], "var": s["var"], "dur": (s["end"] - s["start"]) / 1000.0,
                      "speed": s["speed"], "loop": s["loop"], "tracks": tracks})
    return {
        "pos": np.round(v["p"], 5).reshape(-1).tolist(),
        "normal": np.round(v["n"], 4).reshape(-1).tolist(),
        "uv": np.round(v["uv"], 5).reshape(-1).tolist(),
        "joints": v["i"].reshape(-1).tolist(),
        "weights": v["w"].reshape(-1).tolist(),
        "index": m["index"].astype(int).tolist(),
        "batches": m["batches"],
        "textures": m["textures"],
        "bones": bones,
        "anims": anims,
        "attachments": m["attachments"],
    }
