"""Model porter: a synthetic rigged, animated glTF in, an M2 out that poses exactly like the source.

    python -m pytest tests/test_modelport.py   (or: python tests/test_modelport.py)
"""
import io
import json
import os
import struct
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from modelport import blp, m2read, mpq, names  # noqa: E402
from modelport.gltf import Gltf, quat_to_mat3  # noqa: E402
from modelport.port import port  # noqa: E402


def make_glb(path):
    """A 2-bone bar (a tail that bends), textured, with Idle, Walk (root motion) and Bite clips."""
    # bar along glTF +Z (forward), 1 m long, 4 rings of 4 vertices
    pos, joints, weights, uv = [], [], [], []
    for r in range(4):
        z = r / 3.0
        for (x, y) in ((-.1, 0), (.1, 0), (.1, .2), (-.1, .2)):
            pos.append((x, y + .5, z))
            w = min(1.0, max(0.0, (z - .3) / .4))
            joints.append((0, 1, 0, 0))
            weights.append((1 - w, w, 0, 0))
            uv.append((x + .5, z))
    idx = []
    for r in range(3):
        for k in range(4):
            a, b = r * 4 + k, r * 4 + (k + 1) % 4
            c, d = a + 4, b + 4
            idx += [a, b, d, a, d, c]
    pos = np.array(pos, np.float32)
    bufs = [pos.tobytes(), np.array(joints, np.uint8).tobytes(), np.array(weights, np.float32).tobytes(),
            np.array(uv, np.float32).tobytes(), np.array(idx, np.uint16).tobytes()]
    # inverse binds: joint 0 at origin, joint 1 at z=0.5 (y=0.5)
    ibm = np.stack([np.eye(4), np.linalg.inv(np.array([[1, 0, 0, 0], [0, 1, 0, .5], [0, 0, 1, .5], [0, 0, 0, 1.]]))])
    bufs.append(ibm.transpose(0, 2, 1).astype(np.float32).tobytes())

    def q(axis, ang):
        s = np.sin(ang / 2)
        return [axis[0] * s, axis[1] * s, axis[2] * s, np.cos(ang / 2)]

    t = np.array([0, .5, 1.0], np.float32)
    bend = np.array([q((1, 0, 0), 0), q((1, 0, 0), .8), q((1, 0, 0), 0)], np.float32)
    walk_root = np.array([[0, 0, 0], [0, 0, .6], [0, 0, 1.2]], np.float32)  # walks 1.2 m forward
    bufs += [t.tobytes(), bend.tobytes(), walk_root.tobytes()]
    png = io.BytesIO()
    Image.new("RGBA", (64, 32), (200, 120, 40, 255)).save(png, "PNG")
    bufs.append(png.getvalue())
    views, off, blob = [], 0, b""
    for bb in bufs:
        while len(blob) % 4:
            blob += b"\0"
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(bb)})
        blob += bb
    acc = [
        {"bufferView": 0, "componentType": 5126, "count": 16, "type": "VEC3", "min": pos.min(0).tolist(), "max": pos.max(0).tolist()},
        {"bufferView": 1, "componentType": 5121, "count": 16, "type": "VEC4"},
        {"bufferView": 2, "componentType": 5126, "count": 16, "type": "VEC4"},
        {"bufferView": 3, "componentType": 5126, "count": 16, "type": "VEC2"},
        {"bufferView": 4, "componentType": 5123, "count": len(idx), "type": "SCALAR"},
        {"bufferView": 5, "componentType": 5126, "count": 2, "type": "MAT4"},
        {"bufferView": 6, "componentType": 5126, "count": 3, "type": "SCALAR", "min": [0], "max": [1]},
        {"bufferView": 7, "componentType": 5126, "count": 3, "type": "VEC4"},
        {"bufferView": 8, "componentType": 5126, "count": 3, "type": "VEC3"},
    ]
    j = {
        "asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0, 3]}],
        "nodes": [{"name": "Root", "children": [1]}, {"name": "Tail", "translation": [0, .5, .5], "children": [2]},
                  {"name": "Seat", "translation": [0, .2, -.2]},
                  {"name": "Body", "mesh": 0, "skin": 0}],
        "skins": [{"joints": [0, 1], "inverseBindMatrices": 5}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2, "TEXCOORD_0": 3},
                                    "indices": 4, "material": 0}]}],
        "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
        "textures": [{"source": 0}], "images": [{"bufferView": 9, "mimeType": "image/png"}],
        "animations": [
            {"name": "Idle", "samplers": [{"input": 6, "output": 7}], "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}}]},
            {"name": "Walk", "samplers": [{"input": 6, "output": 7}, {"input": 6, "output": 8}],
             "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}}, {"sampler": 1, "target": {"node": 0, "path": "translation"}}]},
            {"name": "Armature|Bite_2", "samplers": [{"input": 6, "output": 7}], "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}}]},
        ],
        "accessors": acc, "bufferViews": views, "buffers": [{"byteLength": len(blob)}],
    }
    js = json.dumps(j).encode()
    while len(js) % 4:
        js += b" "
    out = struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(js) + 8 + len(blob))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    with open(path, "wb") as f:
        f.write(out)


def m2_pose(m, seq, t):
    """Bone matrices of the read-back M2 at ``t`` seconds into sequence ``seq`` (the engine's way)."""
    s = m["seqs"][seq]
    ms = s["start"] + t * 1000
    out = []

    def samp(keys, d):
        if not keys:
            return np.array(d, float)
        ts = [k[0] for k in keys]
        if ms <= ts[0]:
            return np.array(keys[0][1], float)
        if ms >= ts[-1]:
            return np.array(keys[-1][1], float)
        i = max(k for k in range(len(ts)) if ts[k] <= ms)
        u = (ms - ts[i]) / max(1, ts[i + 1] - ts[i])
        a, b = np.array(keys[i][1], float), np.array(keys[i + 1][1], float)
        if len(a) == 4 and np.dot(a, b) < 0:
            b = -b
        v = a * (1 - u) + b * u
        return v / np.linalg.norm(v) if len(a) == 4 else v

    for i, b in enumerate(m["bones"]):
        p = np.array(b["pivot"])
        tr, rq, sc = samp(b["t"][seq], [0, 0, 0]), samp(b["r"][seq], [0, 0, 0, 1]), samp(b["s"][seq], [1, 1, 1])
        L = np.eye(4)
        L[:3, :3] = quat_to_mat3(rq) * sc[None, :]
        L[:3, 3] = p + tr - L[:3, :3] @ p
        out.append(L if b["parent"] < 0 else out[b["parent"]] @ L)
    return out


class ModelPorter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.glb = os.path.join(cls.tmp, "tail.glb")
        make_glb(cls.glb)
        cls.r = port(cls.glb, {"kind": "mount", "name": "Tail", "height": 2.0})
        cls.m = m2read.read(cls.r.files["Creature\\OpenVanilla\\Tail\\Tail.m2"])

    def test_animations_are_named_and_complete(self):
        ids = [s["id"] for s in self.m["seqs"]]
        self.assertEqual(ids, sorted(ids))
        for want in (0, 4, 13, 16):  # Stand, Walk, Walkbackwards (reversed walk), AttackUnarmed (Bite_2)
            self.assertIn(want, ids)
        self.assertEqual(names.parse("Armature|Gallop")[0], 5)
        self.assertEqual(names.parse("Idle [97]")[0], 97)

    def test_poses_match_the_gltf(self):
        g = Gltf(self.glb)
        C = self.r.axis
        Ci = np.linalg.inv(C)
        walk = next(i for i, s in enumerate(self.m["seqs"]) if s["id"] == 4)
        for t in (0.0, 0.25, 0.5, 0.8):
            chans, _ = g.animation_channels(1)
            W = g.world_matrices(g.pose_at(chans, t))
            pose = m2_pose(self.m, walk, t)
            for b, n in enumerate(self.r.bone_nodes, start=1):
                ref = C @ W[n] @ self.r.ibm[n] @ Ci
                # the walk's forward drift is root motion: kept in place, so compare without it
                drift = (C @ np.array([0, 0, 1.2 * t, 0]))[:3]
                ref[:3, 3] -= drift
                for off in np.eye(3):
                    pt = np.append(off, 1.0)
                    self.assertLess(np.linalg.norm((ref @ pt)[:3] - (pose[b] @ pt)[:3]), 0.01)
        speed = self.m["seqs"][walk]["speed"]
        self.assertAlmostEqual(speed, 1.2 / 1.0 * self.r.meta["scale"], places=2)

    def test_mount_seat_and_texture(self):
        self.assertIn(0, [a["id"] for a in self.m["attachments"]])
        self.assertEqual(self.m["textures"][0]["type"], 11)
        data = self.r.files["Creature\\OpenVanilla\\Tail\\TailSkin.blp"]
        px = blp.decode_dxt_top(data)
        self.assertEqual(px.shape[:2], (32, 64))
        self.assertLess(np.abs(px[..., :3].astype(int) - [200, 120, 40]).max(), 12)

    def test_collision_shapes(self):
        import struct
        def coll(opts):
            r = port(self.glb, dict({"kind": "doodad", "name": "Prop", "height": 2.0}, **opts))
            d = next(v for k, v in r.files.items() if k.endswith(".m2"))
            n, o = struct.unpack_from("<II", d, 0xec)
            nv, _ = struct.unpack_from("<II", d, 0xf4)
            nn, _ = struct.unpack_from("<II", d, 0xfc)
            idx = struct.unpack_from("<%dH" % n, d, o)
            self.assertEqual(n, nn * 3, "a normal per triangle")
            self.assertTrue(all(i < nv for i in idx))
            return n // 3, nv
        mesh_t, mesh_v = coll({})  # a doodad: its own shape
        box_t, box_v = coll({"collision": "box"})
        none_t, _ = coll({"collision": "none"})
        self.assertEqual((box_t, box_v), (12, 8))
        self.assertEqual(none_t, 0)
        self.assertGreater(mesh_t, 12)
        # a heavy model's collision is simplified to the budget
        import modelport.port as P
        old = P.COLLISION_TRIS
        P.COLLISION_TRIS = max(4, mesh_t // 3)
        try:
            small_t, _ = coll({})
        finally:
            P.COLLISION_TRIS = old
        self.assertLessEqual(small_t, max(4, mesh_t // 3))
        self.assertGreater(small_t, 0)

    def test_mpq_round_trip(self):
        p = os.path.join(self.tmp, "t.MPQ")
        files = {k: v for k, v in self.r.files.items()}
        files["DBFilesClient\\Empty.dbc"] = b""
        mpq.write(p, files)
        a = mpq.Archive(p)
        self.assertEqual(sorted(a.names()), sorted(files))
        for k, v in files.items():
            self.assertEqual(a.read(k), v)



# ---- modern models (.m2 + .skin + .skel + .anim + .blp) ------------------------------------------

def _cq(f):
    """float → the M2CompQuat int16 the reader decodes back."""
    f = max(-1.0, min(1.0, f))
    return int(round(f * 32767)) - 32768 if f >= 0 else int(round(f * 32767)) + 32767


def write_modern(vm, folder, base, tex_blp, anim_file_seq=1):
    """Write a 1.12 model ``vm`` (m2read.read) as a Legion-style set: base.m2 (MD21), base00.skin,
    base.skel (SKS1/SKB1/SKA1), and sequence ``anim_file_seq``'s bone keys in an .anim (AFSB)."""
    seqs, bones = vm["seqs"], vm["bones"]

    class Blk:
        def __init__(self, head):
            self.b = bytearray(head)

        def add(self, data):
            while len(self.b) % 16:
                self.b.append(0)
            o = len(self.b)
            self.b += data
            return o if data else 0

    # .anim: the keys of one sequence
    anim = Blk(0)
    skb = Blk(16)  # bones M2Array @0, key bone lookup @8
    recs = []
    for b in bones:
        tracks = []
        for kind, fmt in (("t", "<3f"), ("r", "<4h"), ("s", "<3f")):
            ts_arrs, v_arrs = [], []
            for si, s in enumerate(seqs):
                keys = b[kind][si]
                tgt = anim if si == anim_file_seq else skb
                times = [int(t - s["start"]) for t, _ in keys]
                if kind == "r":
                    vals = b"".join(struct.pack(fmt, *[_cq(x) for x in v]) for _, v in keys)
                else:
                    vals = b"".join(struct.pack(fmt, *v) for _, v in keys)
                to = tgt.add(struct.pack(f"<{len(times)}I", *times)) if times else 0
                vo = tgt.add(vals) if keys else 0
                ts_arrs.append((len(times), to))
                v_arrs.append((len(keys), vo))
            o1 = skb.add(b"".join(struct.pack("<II", *a) for a in ts_arrs))
            o2 = skb.add(b"".join(struct.pack("<II", *a) for a in v_arrs))
            tracks.append(struct.pack("<Hh4I", 1, -1, len(seqs), o1, len(seqs), o2))
        recs.append(struct.pack("<iIhHI", -1, 0, b["parent"], 0, 0) + b"".join(tracks) + struct.pack("<3f", *b["pivot"]))
    bo = skb.add(b"".join(recs))
    struct.pack_into("<II", skb.b, 0, len(recs), bo)
    sks = Blk(24)
    seq_recs = b"".join(struct.pack("<HHIfIhHIIHH3f3ffhH", s["id"], s["var"], s["end"] - s["start"], s["speed"],
                                    (0 if i == anim_file_seq else 0x20) | (0 if s["loop"] else 1), 32767, 0, 0, 0,
                                    150, 150, 0, 0, 0, 1, 1, 1, 1, -1, i) for i, s in enumerate(seqs))
    struct.pack_into("<II", sks.b, 8, len(seqs), sks.add(seq_recs))
    ska = Blk(16)
    atts = b"".join(struct.pack("<IHH3f", a["id"], a["bone"], 0, *a["pos"]) + struct.pack("<Hh4I", 0, -1, 0, 0, 0, 0)
                    for a in vm["attachments"])
    struct.pack_into("<II", ska.b, 0, len(vm["attachments"]), ska.add(atts))

    def chunk(tag, data):
        return tag.encode() + struct.pack("<I", len(data)) + bytes(data)

    with open(os.path.join(folder, base + ".skel"), "wb") as f:
        f.write(chunk("SKL1", b"\0" * 16) + chunk("SKS1", sks.b) + chunk("SKA1", ska.b) + chunk("SKB1", skb.b))
    seq = seqs[anim_file_seq]
    with open(os.path.join(folder, f"{base}{seq['id']:04d}-{seq['var']:02d}.anim"), "wb") as f:
        f.write(chunk("AFM2", b"") + chunk("AFSB", anim.b))

    # base.m2: MD21 with the mesh, textures and materials; no bones of its own
    md = Blk(0x130)
    md.b[0:4], md.b[4:8] = b"MD20", struct.pack("<I", 272)
    name = base.encode() + b"\0"
    struct.pack_into("<II", md.b, 0x08, len(name), md.add(name))
    v = vm["verts"]
    struct.pack_into("<II", md.b, 0x3c, len(v), md.add(v.tobytes()))
    struct.pack_into("<I", md.b, 0x44, 1)
    struct.pack_into("<II", md.b, 0x50, 1, md.add(struct.pack("<IIII", 11, 3, 0, 0)))
    struct.pack_into("<II", md.b, 0x70, 1, md.add(struct.pack("<HH", 0, 0)))
    struct.pack_into("<II", md.b, 0x80, 1, md.add(struct.pack("<H", 0)))
    with open(os.path.join(folder, base + ".m2"), "wb") as f:
        f.write(chunk("MD21", md.b))

    # base00.skin: every triangle in one section
    idx = vm["index"].astype(np.uint16)
    lookup = np.arange(len(v), dtype=np.uint16)
    sk = Blk(4 + 5 * 8 + 4)
    sk.b[0:4] = b"SKIN"
    struct.pack_into("<II", sk.b, 4, len(lookup), sk.add(lookup.tobytes()))
    struct.pack_into("<II", sk.b, 12, len(idx), sk.add(idx.tobytes()))
    struct.pack_into("<II", sk.b, 28, 1, sk.add(struct.pack("<10H3f3ff", 0, 0, 0, len(v), 0, len(idx), 1, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0)))
    struct.pack_into("<II", sk.b, 36, 1, sk.add(struct.pack("<BbHHHHHHHHHHH", 16, 0, 0, 0, 0, 0xffff, 0, 0, 1, 0, 0, 0, 0)))
    with open(os.path.join(folder, base + "00.skin"), "wb") as f:
        f.write(sk.b)
    with open(os.path.join(folder, base + "Skin.blp"), "wb") as f:
        f.write(tex_blp)


class ModernModels(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from modelport import m2modern
        cls.tmp = tempfile.mkdtemp()
        glb = os.path.join(cls.tmp, "tail.glb")
        make_glb(glb)
        first = port(glb, {"kind": "mount", "name": "Tail", "height": 2.0})
        cls.vm = m2read.read(first.files["Creature\\OpenVanilla\\Tail\\Tail.m2"])
        folder = os.path.join(cls.tmp, "modern")
        os.makedirs(folder)
        write_modern(cls.vm, folder, "TailMount", first.files["Creature\\OpenVanilla\\Tail\\TailSkin.blp"])
        cls.opts, cls.notes = m2modern.to_glb(os.path.join(folder, "TailMount.m2"), os.path.join(cls.tmp, "back.glb"))
        o = dict(cls.opts, kind="mount")
        cls.r = port(os.path.join(cls.tmp, "back.glb"), o)
        cls.m = m2read.read(cls.r.files["Creature\\OpenVanilla\\TailMount\\TailMount.m2"])

    def test_every_sequence_and_speed_carries_over(self):
        self.assertEqual([(s["id"], s["var"]) for s in self.m["seqs"]], [(s["id"], s["var"]) for s in self.vm["seqs"]])
        for a, b in zip(self.m["seqs"], self.vm["seqs"]):
            self.assertAlmostEqual(a["speed"], b["speed"], places=2)
            self.assertEqual(a["loop"], b["loop"])

    def test_poses_survive_the_round_trip(self):
        size = float(np.ptp(self.vm["verts"]["p"], axis=0).max())
        for si, s in enumerate(self.vm["seqs"]):
            dur = (s["end"] - s["start"]) / 1000.0
            for f in (0.0, 0.3, 0.7):
                a, b = m2_pose(self.vm, si, dur * f), m2_pose(self.m, si, dur * f)
                pa = np.einsum("bij,j->bi", np.stack(a), [0.1, 0.1, 0.1, 1])
                pb = np.einsum("bij,j->bi", np.stack(b), [0.1, 0.1, 0.1, 1])
                # bones match one to one (the porter adds a root bone each time)
                self.assertLess(np.abs(pa[:, :3] - pb[1:len(pa) + 1, :3] if len(pb) > len(pa) else pa[:, :3] - pb[:, :3]).max(), 0.02 * size)

    def test_texture_mesh_and_seat(self):
        self.assertEqual(len(self.m["verts"]), len(self.vm["verts"]))
        self.assertIn(0, [a["id"] for a in self.m["attachments"]])
        px = blp.decode_dxt_top(self.r.files["Creature\\OpenVanilla\\TailMount\\TailMountSkin.blp"])
        self.assertLess(np.abs(px[..., :3].astype(int) - [200, 120, 40]).max(), 16)
        self.assertTrue(any("Skeleton and animations read from TailMount.skel" in n for n in self.notes))


if __name__ == "__main__":
    unittest.main()
