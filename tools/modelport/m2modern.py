"""Read a modern WoW model (Wrath and later: .m2 + .skin, and Legion-era .skel / .anim) and write
it as a .glb the porter's normal path takes, so it gets the same preview, checks and 1.12 output.

    to_glb(m2_path, out_glb) -> (options, notes)

Handled: chunked (MD21) and plain MD20 v264-274 models; external skins (Name00.skin); skeleton
files (.skel: SKB1 bones, SKS1 sequences, SKA1 attachments); animation data inline, in .anim files
(raw or AFM2/AFSB chunks) or in the skeleton; compressed quaternions; BLP2 textures (palettized,
DXT1/3/5, raw BGRA), found by name, by TXID file id, or among the .blp files beside the model.
"""
import glob
import io
import json
import os
import re
import struct

import numpy as np
from PIL import Image

from . import blp as blpmod


class M2Error(Exception):
    pass


def _readb(path):
    with open(path, "rb") as f:
        return f.read()


def chunks(b):
    """4CC chunks (M2/skel/anim files store the id as plain text)."""
    out, o = {}, 0
    while o + 8 <= len(b):
        tag = b[o:o + 4].decode("latin1")
        n = struct.unpack_from("<I", b, o + 4)[0]
        if not re.fullmatch(r"[A-Z0-9]{4}", tag) or o + 8 + n > len(b):
            break
        out.setdefault(tag, (o + 8, n))
        o += 8 + n
    return out


def arr(b, at, base=0):
    n, o = struct.unpack_from("<II", b, base + at)
    return n, o


# ---- BLP2, every form the client uses --------------------------------------------------------

def blp_rgba(data):
    if data[:4] != b"BLP2":
        raise M2Error("not a BLP2 texture")
    comp, adepth, atype, _mips = data[8], data[9], data[10], data[11]
    w, h = struct.unpack_from("<II", data, 12)
    off = struct.unpack_from("<I", data, 20)[0]
    size = struct.unpack_from("<I", data, 84)[0]
    if comp == 2:
        if atype == 1:  # DXT3: explicit 4-bit alpha, then a DXT1 colour block
            nb = max(1, w // 4) * max(1, h // 4)
            raw = np.frombuffer(data, np.uint8, nb * 16, off).reshape(nb, 16)
            fake = bytearray(data[:off]) + raw[:, 8:].tobytes()
            fake[9], fake[10] = 0, 0
            rgb = blpmod.decode_dxt_top(bytes(fake))
            a = raw[:, :8]
            nib = np.stack([a & 15, a >> 4], -1).reshape(nb, 16).astype(np.float64) * 17
            bw, bh = max(1, w // 4), max(1, h // 4)
            al = nib.reshape(bh, bw, 4, 4).transpose(0, 2, 1, 3).reshape(bh * 4, bw * 4)[:h, :w]
            rgb[..., 3] = al.astype(np.uint8)
            return rgb
        if atype == 7 or adepth == 8:
            return blpmod.decode_dxt_top(data)
        fake = bytearray(data)
        fake[9], fake[10] = 0, 0
        return blpmod.decode_dxt_top(bytes(fake))
    if comp == 3:  # raw BGRA
        px = np.frombuffer(data, np.uint8, w * h * 4, off).reshape(h, w, 4)
        return px[..., [2, 1, 0, 3]].copy()
    if comp == 1:  # 256-colour palette + alpha plane
        pal = np.frombuffer(data, np.uint8, 1024, 148).reshape(256, 4)[:, [2, 1, 0, 3]]
        idx = np.frombuffer(data, np.uint8, w * h, off)
        rgba = pal[idx].copy()
        rgba[:, 3] = 255
        ab = data[off + w * h: off + size]
        if adepth == 8:
            rgba[:, 3] = np.frombuffer(ab, np.uint8, w * h)
        elif adepth == 1:
            bits = np.unpackbits(np.frombuffer(ab, np.uint8), bitorder="little")[: w * h]
            rgba[:, 3] = bits * 255
        elif adepth == 4:
            nib = np.frombuffer(ab, np.uint8)
            vals = np.stack([nib & 15, nib >> 4], -1).reshape(-1)[: w * h]
            rgba[:, 3] = vals * 17
        return rgba.reshape(h, w, 4)
    raise M2Error(f"BLP compression {comp} isn't supported")


# ---- the model ----------------------------------------------------------------------------

def _cquat(v):
    out = []
    for x in v:
        out.append((x + 32768 if x < 0 else x - 32767) / 32767.0)
    return out


class Modern:
    def __init__(self, path, extra_files=()):
        self.path = path
        self.dir = os.path.dirname(os.path.abspath(path))
        self.base = os.path.splitext(os.path.basename(path))[0]
        self.notes = []
        raw = _readb(path)
        self.chunks = chunks(raw)
        if raw[:4] == b"MD20":
            self.md = raw
            self.chunks = {}
        elif "MD21" in self.chunks:
            o, n = self.chunks["MD21"]
            self.md = raw[o:o + n]
            self.raw = raw
        else:
            raise M2Error("not an M2 model (no MD20/MD21)")
        self.raw = raw
        self.version = struct.unpack_from("<I", self.md, 4)[0]
        if self.version < 264:
            raise M2Error(f"this .m2 is version {self.version}, a 1.12-era model already; "
                          "it needs no conversion (drop the .glb source instead, or use it as is)")
        self.files = {os.path.basename(f).lower(): f for f in glob.glob(os.path.join(self.dir, "*"))}
        for f in extra_files:
            self.files[os.path.basename(f).lower()] = f
        self._read()

    def chunk_ids(self, tag, fmt="<I"):
        if tag not in self.chunks:
            return []
        o, n = self.chunks[tag]
        sz = struct.calcsize(fmt)
        return [struct.unpack_from(fmt, self.raw, o + i * sz) for i in range(n // sz)]

    def find(self, *names):
        for n in names:
            if n and n.lower() in self.files:
                return self.files[n.lower()]
        return None

    # -- tracks: per-sequence arrays (v264+) --
    def _track(self, block, at, vfmt, vsize, conv=None, anims=None):
        interp, gseq = struct.unpack_from("<Hh", block, at)
        tn, to = struct.unpack_from("<II", block, at + 4)
        vn, vo = struct.unpack_from("<II", block, at + 12)
        out = []
        for s in range(len(self.seqs)):
            if gseq >= 0:
                si = 0
            else:
                si = s
            if si >= tn or si >= vn:
                out.append([])
                continue
            src = block
            seq = self.seqs[s]
            if gseq < 0 and not (seq["flags"] & 0x20) and anims is not None:
                src = anims.get((seq["id"], seq["var"]))
                if src is None:
                    out.append([])
                    continue
            n1, o1 = struct.unpack_from("<II", block, to + si * 8)
            n2, o2 = struct.unpack_from("<II", block, vo + si * 8)
            n = min(n1, n2)
            try:
                ts = struct.unpack_from(f"<{n}I", src, o1) if n else ()
                vals = [struct.unpack_from(vfmt, src, o2 + k * vsize) for k in range(n)]
            except struct.error:
                out.append([])
                continue
            if conv:
                vals = [conv(v) for v in vals]
            out.append(list(zip(ts, vals)))
        return {"interp": interp, "gseq": gseq, "keys": out}

    def _anim_files(self, block_kind):
        """(id, variation) -> bytes the per-sequence offsets point into."""
        res = {}
        afid = {(a, b): f for a, b, f in self.chunk_ids("AFID", "<HHI")}
        for s in self.seqs:
            if s["flags"] & 0x20 or s["flags"] & 0x40:
                continue
            key = (s["id"], s["var"])
            p = self.find(f"{self.base}{s['id']:04d}-{s['var']:02d}.anim",
                          f"{afid.get(key, -1)}.anim" if key in afid else None)
            if not p:
                continue
            data = _readb(p)
            ch = chunks(data)
            if block_kind in ch:
                o, n = ch[block_kind]
                res[key] = data[o:o + n]
            elif "AFM2" in ch:
                o, n = ch["AFM2"]
                res[key] = data[o:o + n]
            else:
                res[key] = data
        return res

    def _read(self):
        md = self.md
        self.name = md[struct.unpack_from("<I", md, 0x0c)[0]:][:struct.unpack_from("<I", md, 0x08)[0]].split(b"\0")[0].decode("latin1", "replace")
        self.flags = struct.unpack_from("<I", md, 0x10)[0]
        # skeleton source: the .skel when there is one, else the model itself
        skel_path = self.find(f"{self.base}.skel")
        skid = self.chunk_ids("SKID")
        if not skel_path and skid:
            skel_path = self.find(f"{skid[0][0]}.skel")
        self.gseqs = []
        if skel_path:
            sk = _readb(skel_path)
            ch = chunks(sk)
            if "SKPD" in ch:
                self.notes.append("This skeleton inherits from a parent .skel; only its own bones are read.")
            self._read_seqs(sk, *ch["SKS1"]) if "SKS1" in ch else self._read_seqs_md()
            anims = self._anim_files("AFSB")
            if "SKB1" in ch:
                o, n = ch["SKB1"]
                self._read_bones(sk[o:o + n], 0, anims)
            else:
                self._read_bones(md, 0x2c, anims)
            if "SKA1" in ch:
                o, n = ch["SKA1"]
                self._read_atts(sk[o:o + n], 0)
            else:
                self._read_atts(md, 0xf0)
            self.notes.append(f"Skeleton and animations read from {os.path.basename(skel_path)}.")
        else:
            self._read_seqs_md()
            anims = self._anim_files("AFM2")
            self._read_bones(md, 0x2c, anims)
            self._read_atts(md, 0xf0)
        missing = [s for s in self.seqs if not (s["flags"] & 0x20) and not (s["flags"] & 0x40)
                   and (s["id"], s["var"]) not in anims]
        if missing:
            self.notes.append(f"{len(missing)} animation(s) live in .anim files that weren't dropped with the "
                              "model; drop the .anim files too to keep them (they're skipped for now).")
        self.missing_anims = {(s["id"], s["var"]) for s in missing}
        self._read_mesh()

    def _read_seqs_md(self):
        self._read_seqs(self.md, 0, None, at=0x1c)

    def _read_seqs(self, b, o, n, at=None):
        # SKS1: global loops @0, sequences @8, sequence lookups @16 (relative to the chunk)
        if at is None:
            block, at_g, at_s = b[o:o + n], 0, 8
        else:
            block, at_g, at_s = b, 0x14, at
        gn, go = struct.unpack_from("<II", block, at_g)
        self.gseqs = list(struct.unpack_from(f"<{gn}I", block, go)) if gn else []
        sn, so = struct.unpack_from("<II", block, at_s)
        self.seqs = []
        for i in range(sn):
            r = struct.unpack_from("<HHIfIhHIIHH3f3ffhH", block, so + i * 64)
            self.seqs.append({"id": r[0], "var": r[1], "dur": r[2], "speed": r[3], "flags": r[4],
                              "next": r[15], "alias": r[16]})

    def _read_bones(self, block, at, anims):
        bn, bo = struct.unpack_from("<II", block, at)
        self.bones = []
        for i in range(bn):
            o = bo + i * 88
            key, flags, parent, _sub, _crc = struct.unpack_from("<iIhHI", block, o)
            self.bones.append({
                "key": key, "flags": flags, "parent": parent,
                "t": self._track(block, o + 16, "<3f", 12, anims=anims),
                "r": self._track(block, o + 36, "<4h", 8, conv=_cquat, anims=anims),
                "s": self._track(block, o + 56, "<3f", 12, anims=anims),
                "pivot": struct.unpack_from("<3f", block, o + 76),
            })
        for i, b in enumerate(self.bones):
            if b["parent"] >= i:
                raise M2Error("bones out of order (a child before its parent)")

    def _read_atts(self, block, at):
        an, ao = struct.unpack_from("<II", block, at)
        self.atts = []
        for i in range(an):
            aid, bone = struct.unpack_from("<IH", block, ao + i * 40)
            pos = struct.unpack_from("<3f", block, ao + i * 40 + 8)
            self.atts.append({"id": aid, "bone": bone, "pos": pos})

    def _read_mesh(self):
        md = self.md
        vn, vo = arr(md, 0x3c)
        vb = np.frombuffer(md, dtype=[("p", "<f4", 3), ("w", "u1", 4), ("i", "u1", 4), ("n", "<f4", 3),
                                      ("uv", "<f4", 2), ("uv2", "<f4", 2)], count=vn, offset=vo)
        self.verts = vb
        # skin profile 0
        sfid = self.chunk_ids("SFID")
        skin = self.find(f"{self.base}00.skin", f"{sfid[0][0]}.skin" if sfid else None)
        if not skin:
            raise M2Error(f"needs its skin file ({self.base}00.skin): drop it together with the .m2")
        sb = _readb(skin)
        if sb[:4] != b"SKIN":
            raise M2Error(f"{os.path.basename(skin)} isn't a skin file")
        (n_i, o_i), (n_t, o_t), _, (n_s, o_s), (n_b, o_b) = [struct.unpack_from("<II", sb, 4 + k * 8) for k in range(5)]
        lookup = np.frombuffer(sb, "<u2", n_i, o_i).astype(np.int64)
        tris = np.frombuffer(sb, "<u2", n_t, o_t).astype(np.int64)
        subs = []
        for k in range(n_s):
            r = struct.unpack_from("<10H", sb, o_s + k * 48)
            subs.append({"id": r[0], "istart": r[4] + (r[1] << 16), "icount": r[5]})
        # textures
        tn, to = arr(md, 0x50)
        txid = [x[0] for x in self.chunk_ids("TXID")]
        self.textures = []
        for k in range(tn):
            ttype, tflags, fnn, fno = struct.unpack_from("<IIII", md, to + k * 16)
            name = md[fno:fno + fnn].split(b"\0")[0].decode("latin1") if fnn else ""
            self.textures.append({"type": ttype, "name": name, "fid": txid[k] if k < len(txid) else 0})
        mn, mo = arr(md, 0x70)
        mats = [struct.unpack_from("<HH", md, mo + k * 4) for k in range(mn)]
        ln, lo = arr(md, 0x80)
        tlook = struct.unpack_from(f"<{ln}H", md, lo) if ln else ()
        self.batches = []
        used = set()
        for k in range(n_b):
            u = struct.unpack_from("<BbHHHHHHHHHHH", sb, o_b + k * 24)
            sec = u[3]
            if sec in used or sec >= len(subs):
                continue  # extra texture layers of the same section: 1.12 draws one
            used.add(sec)
            s = subs[sec]
            t = tlook[u[9]] if u[9] < len(tlook) else 0
            self.batches.append({"tris": lookup[tris[s["istart"]:s["istart"] + s["icount"]]].reshape(-1, 3),
                                 "material": mats[u[6]] if u[6] < len(mats) else (0, 0), "texture": t,
                                 "geoset": s["id"]})
        groups = {}
        for b in self.batches:
            groups.setdefault(b["geoset"] // 100, set()).add(b["geoset"])
        if any(len(v) > 1 and g > 0 for g, v in groups.items()):
            self.notes.append("The model has optional parts (geoset variants); all of them are kept. "
                              "Delete the ones you don't want in Blender if needed.")

    def texture_image(self, k):
        t = self.textures[k] if k < len(self.textures) else {"name": "", "fid": 0, "type": 0}
        cands = []
        if t["name"]:
            cands += [os.path.basename(t["name"].replace("\\", "/"))]
        if t["fid"]:
            cands += [f"{t['fid']}.blp"]
        p = self.find(*cands)
        if not p:
            blps = sorted(v for k_, v in self.files.items() if k_.endswith(".blp"))
            # creature skins (types 11-13) and unnamed textures: the .blp files beside the model
            if blps:
                p = blps[min(k, len(blps) - 1)] if len(blps) == len(self.textures) else blps[0]
        if not p:
            return None, None
        try:
            return Image.fromarray(blp_rgba(_readb(p)), "RGBA"), os.path.basename(p)
        except Exception as e:  # noqa: BLE001
            self.notes.append(f"Couldn't read {os.path.basename(p)}: {e}")
            return None, None


# ---- write a glTF the porter reads ------------------------------------------------------------

def _g(v):
    """WoW axes (X fwd, Y left, Z up), yards → glTF (Y up, +Z front), metres."""
    return [v[1] * 0.9144, v[2] * 0.9144, v[0] * 0.9144]


def _gq(q):
    return [q[1], q[2], q[0], q[3]]


def _gs(s):
    return [s[1], s[2], s[0]]


def to_glb(path, out, extra_files=()):
    m = Modern(path, extra_files)
    from .animdata import ANIMS
    buf = bytearray()
    views, accs = [], []

    def add(arr_, ctype, typ, minmax=False):
        a = np.ascontiguousarray(arr_)
        while len(buf) % 4:
            buf.append(0)
        views.append({"buffer": 0, "byteOffset": len(buf), "byteLength": a.nbytes})
        buf.extend(a.tobytes())
        acc = {"bufferView": len(views) - 1, "componentType": ctype, "count": int(a.shape[0]), "type": typ}
        if minmax:
            acc["min"] = a.min(0).tolist()
            acc["max"] = a.max(0).tolist()
        accs.append(acc)
        return len(accs) - 1

    nb = len(m.bones)
    if nb == 0:
        m.bones = [{"parent": -1, "pivot": (0, 0, 0), "t": {"keys": []}, "r": {"keys": []}, "s": {"keys": []}, "key": -1}]
        nb = 1
    nodes = []
    for i, b in enumerate(m.bones):
        par = m.bones[b["parent"]]["pivot"] if b["parent"] >= 0 else (0, 0, 0)
        nodes.append({"name": f"Bone{i}" + ("_Head" if b["key"] == 6 else ""),
                      "translation": _g([b["pivot"][k] - par[k] for k in range(3)]), "children": []})
    for i, b in enumerate(m.bones):
        if b["parent"] >= 0:
            nodes[b["parent"]]["children"].append(i)
    for a in m.atts:
        if a["bone"] < nb:
            piv = m.bones[a["bone"]]["pivot"]
            nodes.append({"name": f"Attach_{a['id']}", "translation": _g([a["pos"][k] - piv[k] for k in range(3)])})
            nodes[a["bone"]]["children"].append(len(nodes) - 1)
    for n in nodes:
        if not n.get("children"):
            n.pop("children", None)
    roots = [i for i, b in enumerate(m.bones) if b["parent"] < 0]

    ibm = np.stack([np.eye(4) for _ in range(nb)])
    for i, b in enumerate(m.bones):
        ibm[i][:3, 3] = [-x for x in _g(b["pivot"])]
    ibm_acc = add(ibm.transpose(0, 2, 1).reshape(nb, 16).astype(np.float32), 5126, "MAT4")

    v = m.verts
    pos = np.array([_g(p) for p in v["p"]], np.float32)
    nrm = np.array([[n[1], n[2], n[0]] for n in v["n"]], np.float32)
    joints = np.minimum(v["i"].astype(np.uint16), nb - 1)
    weights = v["w"].astype(np.float32) / 255.0
    weights[weights.sum(1) == 0, 0] = 1.0
    a_pos = add(pos, 5126, "VEC3", True)
    a_nrm = add(nrm, 5126, "VEC3")
    a_uv = add(v["uv"].astype(np.float32), 5126, "VEC2")
    a_j = add(joints, 5123, "VEC4")
    a_w = add(weights, 5126, "VEC4")

    images, textures, materials, tex_index = [], [], [], {}
    prims = []
    for b in m.batches:
        t = b["texture"]
        if t not in tex_index:
            im, src = m.texture_image(t)
            if im is None:
                tex_index[t] = None
            else:
                png = io.BytesIO()
                im.save(png, "PNG")
                data = png.getvalue()
                while len(buf) % 4:
                    buf.append(0)
                views.append({"buffer": 0, "byteOffset": len(buf), "byteLength": len(data)})
                buf.extend(data)
                images.append({"bufferView": len(views) - 1, "mimeType": "image/png", "name": src})
                textures.append({"source": len(images) - 1})
                tex_index[t] = len(textures) - 1
        flags, blend = b["material"]
        mat = {"name": f"m{len(materials)}", "doubleSided": bool(flags & 4),
               "alphaMode": {0: "OPAQUE", 1: "MASK"}.get(blend, "BLEND"),
               "pbrMetallicRoughness": {"metallicFactor": 0, "roughnessFactor": 1}}
        if flags & 1:
            mat["extensions"] = {"KHR_materials_unlit": {}}
        if tex_index[t] is not None:
            mat["pbrMetallicRoughness"]["baseColorTexture"] = {"index": tex_index[t]}
        materials.append(mat)
        idx = add(b["tris"].reshape(-1).astype(np.uint32), 5125, "SCALAR")
        prims.append({"attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv,
                                     "JOINTS_0": a_j, "WEIGHTS_0": a_w}, "indices": idx,
                      "material": len(materials) - 1})
    if any(i is None for i in tex_index.values()):
        m.notes.append("Some textures weren't found beside the model; those parts get a flat colour. "
                       "Drop the .blp files together with the .m2.")

    # animations: one glTF clip per sequence, named so the porter keeps its id
    anims, opt_anims = [], {}
    count = {}
    for si, s in enumerate(m.seqs):
        if s["flags"] & 0x40 or (s["id"], s["var"]) in m.missing_anims:
            continue
        nm = ANIMS[s["id"]][0] if s["id"] in ANIMS else f"Retail{s['id']}"
        count[s["id"]] = count.get(s["id"], 0) + 1
        label = f"{nm} [{s['id']}]" + (f" #{count[s['id']]}" if count[s["id"]] > 1 else "")
        samplers, channels = [], []
        dur = max(1, s["dur"]) / 1000.0
        for bi, b in enumerate(m.bones):
            par = m.bones[b["parent"]]["pivot"] if b["parent"] >= 0 else (0, 0, 0)
            rest = [b["pivot"][k] - par[k] for k in range(3)]
            for path, conv in (("translation", lambda x: _g([rest[k] + x[k] for k in range(3)])),
                               ("rotation", _gq), ("scale", _gs)):
                tr = b[path[0]]
                keys = tr["keys"][si] if si < len(tr["keys"]) else []
                if not keys:
                    continue
                if tr["gseq"] >= 0 and tr["gseq"] < len(m.gseqs) and m.gseqs[tr["gseq"]]:
                    period = m.gseqs[tr["gseq"]]
                    keys = [(t % period, val) for t, val in keys]
                times = np.array([min(t, s["dur"]) / 1000.0 for t, _ in keys], np.float32)
                order = np.argsort(times, kind="stable")
                times = times[order]
                vals = np.array([conv(list(keys[k][1])) for k in order], np.float32)
                if path == "rotation":
                    vals /= np.maximum(np.linalg.norm(vals, axis=1, keepdims=True), 1e-9)
                times, uniq = np.unique(times, return_index=True)
                vals = vals[uniq]
                ti = add(times.reshape(-1, 1), 5126, "SCALAR")
                accs[ti]["min"], accs[ti]["max"] = [float(times.min())], [float(times.max())]
                vi = add(vals, 5126, "VEC4" if path == "rotation" else "VEC3")
                samplers.append({"input": ti, "output": vi, "interpolation": "STEP" if tr["interp"] == 0 else "LINEAR"})
                channels.append({"sampler": len(samplers) - 1, "target": {"node": bi, "path": path}})
        if not channels:
            # a sequence with no keys still has a length: hold the rest pose for it
            t0 = add(np.array([[0.0], [dur]], np.float32), 5126, "SCALAR")
            accs[t0]["min"], accs[t0]["max"] = [0.0], [dur]
            r0 = add(np.array([[0, 0, 0, 1], [0, 0, 0, 1]], np.float32), 5126, "VEC4")
            samplers.append({"input": t0, "output": r0})
            channels.append({"sampler": 0, "target": {"node": 0, "path": "rotation"}})
        anims.append({"name": label, "samplers": samplers, "channels": channels})
        if s["id"] in ANIMS:
            opt_anims[label] = {"id": s["id"]}
            if s["speed"] > 0:
                opt_anims[label]["speed"] = round(s["speed"], 3)
    retail = sorted({s["id"] for s in m.seqs if s["id"] not in ANIMS})
    if retail:
        m.notes.append("Animations newer than 1.12 (ids " + ", ".join(map(str, retail[:12]))
                       + ("…" if len(retail) > 12 else "") + ") have no 1.12 slot; pick one for any you "
                       "want in the Animations table, or leave them skipped.")

    mesh_node = len(nodes)
    nodes.append({"name": m.name or m.base, "mesh": 0, "skin": 0})
    j = {"asset": {"version": "2.0", "generator": "Open Vanilla modelport (modern M2)"}, "scene": 0,
         "scenes": [{"nodes": roots + [mesh_node]}], "nodes": nodes,
         "skins": [{"joints": list(range(nb)), "inverseBindMatrices": ibm_acc}],
         "meshes": [{"primitives": prims}], "materials": materials, "accessors": accs,
         "bufferViews": views, "buffers": [{"byteLength": len(buf)}]}
    if images:
        j["images"], j["textures"] = images, textures
    if anims:
        j["animations"] = anims
    if any("extensions" in mt for mt in materials):
        j["extensionsUsed"] = ["KHR_materials_unlit"]
    js = json.dumps(j).encode()
    while len(js) % 4:
        js += b" "
    while len(buf) % 4:
        buf.append(0)
    blob = struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(js) + 8 + len(buf))
    blob += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(buf), 0x004E4942) + bytes(buf)
    with open(out, "wb") as f:
        f.write(blob)
    opts = {"name": re.sub(r"[^A-Za-z0-9]", "", m.base) or "Model"}
    if opt_anims:
        opts["anims"] = opt_anims
    m.notes.insert(0, f"Converted from a v{m.version} model ({len(m.bones)} bones, {len(m.seqs)} sequences, "
                      f"{len(m.batches)} parts).")
    return opts, m.notes
