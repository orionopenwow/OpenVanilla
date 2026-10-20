"""glTF/GLB → a WoW 1.12.1 creature or mount: M2 model, BLP textures, and what the DBC rows need.

    port(path, options) -> Ported

How bones carry over: a glTF joint's skinning matrix ``K = World(t) · InverseBind`` is moved into
WoW's axes (``C · K · C⁻¹``), and each M2 bone gets the pivot at its joint's bind position and the
local keys ``T(-p) · (M_parent⁻¹ · M) · T(p)`` decomposed into translation, rotation and scale.
That is exactly what the engine composes back (``T(p+t) · R · S · T(-p)`` under the parent), so
every sampled frame reproduces the glTF pose. Unskinned meshes ride their node as a rigid bone.
"""
import io
import re

import numpy as np
from PIL import Image

from . import blp, m2, names
from .gltf import Gltf, GltfError, decompose

FPS = 30
BONE_LIMIT = 64         # bones per submesh (the 1.12 client's hardware-skinning palette)
YARD = 1.0 / 0.9144     # glTF metres → WoW yards

# default heights (yards) used only when a model's size is clearly not in metres
DEFAULT_HEIGHT = {"mount": 2.3, "creature": 2.0, "doodad": 1.5}
# moveSpeed (yd/s) for in-place locomotion clips: the clip plays at unitSpeed / moveSpeed
DEFAULT_SPEED = {
    "mount": {4: 2.5, 5: 11.0, 13: 4.5, 143: 14.0, 11: 4.5, 12: 4.5, 42: 4.7, 135: 14.0},
    "creature": {4: 2.5, 5: 7.0, 13: 4.5, 143: 9.0, 11: 4.5, 12: 4.5, 42: 4.7, 135: 7.0},
}
LOCOMOTION = {4, 5, 11, 12, 13, 42, 43, 44, 45, 92, 93, 119, 135, 143}
SEAT_NAMES = ("seat", "saddle", "rider", "mountpoint", "mount", "attachseat", "attach0", "attachmountmain")


class Ported:
    def __init__(self):
        self.files = {}       # archive path → bytes
        self.meta = {}
        self.warnings = []
        self.info = []
        self.preview = None

    def warn(self, msg):
        self.warnings.append(msg)

    def note(self, msg):
        self.info.append(msg)


def safe_name(s):
    s = re.sub(r"[^A-Za-z0-9]", "", s or "")
    if not s:
        s = "Model"
    if s[0].isdigit():
        s = "M" + s
    return s[:40]


def _axis_matrix(scale, facing):
    """glTF (Y up, +Z front) → WoW (Z up, +X front, +Y left), then uniform ``scale``."""
    p = np.array([[0, 0, 1, 0], [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 0, 1]], dtype=np.float64)
    yaw = {"+z": 0, "-z": 180, "+x": -90, "-x": 90}.get(facing, 0)
    c, s = np.cos(np.radians(yaw)), np.sin(np.radians(yaw))
    rz = np.array([[c, -s, 0, 0], [s, c, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
    sc = np.diag([scale, scale, scale, 1.0])
    return sc @ rz @ p


def _T(v):
    m = np.eye(4)
    m[:3, 3] = v
    return m


def _slerp_many(a, b, u):
    d = np.sum(a * b, axis=1)
    b = np.where(d[:, None] < 0, -b, b)
    d = np.abs(d)
    th = np.arccos(np.clip(d, -1, 1))
    s = np.sin(th)
    small = s < 1e-6
    s = np.where(small, 1, s)
    wa = np.where(small, 1 - u, np.sin((1 - u) * th) / s)
    wb = np.where(small, u, np.sin(u * th) / s)
    r = wa[:, None] * a + wb[:, None] * b
    return r / np.linalg.norm(r, axis=1, keepdims=True)


def _reduce(keys, kind, tol):
    """Drop keys a straight line (or slerp) between kept neighbours reproduces within ``tol``
    (Douglas-Peucker, vectorised)."""
    n = len(keys)
    if n <= 2:
        return keys
    t = np.array([k[0] for k in keys], dtype=np.float64)
    v = np.array([k[1] for k in keys], dtype=np.float64)
    keep = np.zeros(n, bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        if j - i < 2:
            continue
        mid = np.arange(i + 1, j)
        u = (t[mid] - t[i]) / max(1e-9, t[j] - t[i])
        if kind == "q":
            est = _slerp_many(np.repeat(v[i:i + 1], len(mid), 0), np.repeat(v[j:j + 1], len(mid), 0), u)
            err = 1 - np.abs(np.sum(est * v[mid], axis=1))
        else:
            est = v[i] * (1 - u)[:, None] + v[j] * u[:, None]
            err = np.abs(est - v[mid]).max(1)
        k = int(err.argmax())
        if err[k] > tol:
            m_ = int(mid[k])
            keep[m_] = True
            stack.append((i, m_))
            stack.append((m_, j))
    return [keys[k] for k in range(n) if keep[k]]


def _quant_weights(w):
    """(N, 4) floats summing to 1 → u8 summing to exactly 255."""
    q = np.floor(w * 255.0 + 0.5).astype(np.int32)
    diff = 255 - q.sum(1)
    top = w.argmax(1)
    q[np.arange(len(q)), top] += diff
    return np.clip(q, 0, 255).astype(np.uint8)


def _load_image(data):
    im = Image.open(io.BytesIO(data))
    im.load()
    return im


COLLISION_TRIS = 6000


def _collision_mesh(pos, tri_blocks, out):
    """The render mesh as collision: positions welded (UV seams split them), degenerate triangles
    dropped, and above COLLISION_TRIS a vertex-cluster simplification (coarser grid until it fits),
    since the client tests every collision triangle a player is near."""
    tris = np.concatenate(tri_blocks) if tri_blocks else np.zeros((0, 3), dtype=np.int64)
    size = float(np.max(pos.max(0) - pos.min(0))) if len(pos) else 1.0
    cell = 1e-3
    while True:
        key = np.round(pos / cell).astype(np.int64)
        uniq, inv = np.unique(key, axis=0, return_inverse=True)
        inv = inv.reshape(-1)
        t = inv[tris]
        t = t[(t[:, 0] != t[:, 1]) & (t[:, 1] != t[:, 2]) & (t[:, 0] != t[:, 2])]
        if len(t):
            first = np.unique(np.sort(t, axis=1), axis=0, return_index=True)[1]
            t = t[np.sort(first)]  # each triangle once (two-sided copies too)
        if len(t) <= COLLISION_TRIS and len(uniq) <= 65535:
            break
        cell = max(cell * 1.6, size / 400)
    used = np.unique(t.reshape(-1))
    remap = -np.ones(len(uniq), dtype=np.int64)
    remap[used] = np.arange(len(used))
    # each welded vertex at the mean of the positions it stands for
    acc = np.zeros((len(uniq), 3))
    np.add.at(acc, inv, pos)
    cnt = np.bincount(inv, minlength=len(uniq))[:, None]
    verts = (acc / np.maximum(cnt, 1))[used]
    if cell > 1e-3:
        out.note(f"Collision simplified to {len(t):,} triangles ({cell:.2f}-yard grid).")
    return verts.tolist(), remap[t].reshape(-1).tolist()


def port(path, options=None):
    opts = dict(options or {})
    out = Ported()
    g = Gltf(path)
    kind = opts.get("kind", "mount")
    name = safe_name(opts.get("name") or path.replace("\\", "/").split("/")[-1].rsplit(".", 1)[0])
    out.meta["name"] = name
    out.meta["kind"] = kind
    # a pack made in Open Vanilla Forge keeps its models in its own folder
    folder = opts.get("folder") or f"Creature\\OpenVanilla\\{name}"

    order = g.scene_nodes()
    in_scene = set(order)
    mesh_nodes = [n for n in order if "mesh" in g.nodes[n]]
    if not mesh_nodes:
        raise GltfError("the file has no meshes in its scene")

    # ---- bones -------------------------------------------------------------------------------
    rest_world = g.world_matrices(g.rest)
    ibm = {}
    for n in mesh_nodes:
        sk = g.nodes[n].get("skin")
        if sk is None:
            continue
        skin = g.skins[sk]
        mats = (g.accessor(skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
                if "inverseBindMatrices" in skin else np.tile(np.eye(4), (len(skin["joints"]), 1, 1)))
        for j, node in enumerate(skin["joints"]):
            ibm.setdefault(node, mats[j])
    for n in mesh_nodes:
        if g.nodes[n].get("skin") is None:
            ibm.setdefault(n, np.linalg.inv(rest_world[n]))
    bone_nodes = [n for n in order if n in ibm]
    stray = [n for n in ibm if n not in in_scene]
    bone_nodes += stray  # joints outside the scene graph still deform
    if len(bone_nodes) + 1 > 255:
        raise GltfError(f"{len(bone_nodes)} bones: a 1.12 model holds at most 254")
    bone_of = {n: i + 1 for i, n in enumerate(bone_nodes)}

    def bone_parent(n):
        p = g.parent[n]
        while p >= 0:
            if p in bone_of:
                return bone_of[p]
            p = g.parent[p]
        return 0

    parents = [-1] + [bone_parent(n) for n in bone_nodes]
    for i, p in enumerate(parents):
        assert p < i, "bones must come after their parents"

    # ---- scale and axes ----------------------------------------------------------------------
    # model size from the rest pose, in metres
    pts = []
    for n in mesh_nodes:
        for prim in g.meshes[g.nodes[n]["mesh"]]["primitives"]:
            if "POSITION" in prim["attributes"]:
                p = g.accessor(prim["attributes"]["POSITION"])
                if g.nodes[n].get("skin") is None:
                    p = (rest_world[n] @ np.c_[p, np.ones(len(p))].T).T[:, :3]
                pts.append(p)
    allp = np.concatenate(pts)
    height_m = float(allp[:, 1].max() - allp[:, 1].min())
    if opts.get("height"):
        scale = float(opts["height"]) / max(height_m, 1e-6)
        out.note(f"Scaled to {float(opts['height']):.2f} yards tall.")
    elif opts.get("scale"):
        scale = float(opts["scale"])
    else:
        scale = YARD
        h_yd = height_m * scale
        if h_yd > 30 or h_yd < 0.25:
            scale = DEFAULT_HEIGHT.get(kind, 2.0) / max(height_m, 1e-6)
            out.warn(f"The model is {height_m:g} units tall, not a size in metres; scaled it to "
                     f"{DEFAULT_HEIGHT.get(kind, 2.0)} yards. Set a height to choose.")
    C = _axis_matrix(scale, opts.get("facing", "+z"))
    Ci = np.linalg.inv(C)
    R3 = C[:3, :3] / scale  # rotation part, for normals

    pivots = [np.zeros(3)] + [(C @ np.append(np.linalg.inv(ibm[n])[:3, 3], 1.0))[:3] for n in bone_nodes]

    def bone_mats(world):
        M = [np.eye(4)]
        for n in bone_nodes:
            M.append(C @ world[n] @ ibm[n] @ Ci)
        return M

    # ---- mesh --------------------------------------------------------------------------------
    pos, nrm, uvs, bw, bi, tris_by_mat = [], [], [], [], [], {}
    vbase = 0
    for n in mesh_nodes:
        node = g.nodes[n]
        sk = node.get("skin")
        for prim in g.meshes[node["mesh"]]["primitives"]:
            if prim.get("mode", 4) != 4:
                out.warn(f"Skipped a non-triangle primitive in mesh {node.get('name', n)}.")
                continue
            if prim.get("targets"):
                out.warn("Shape keys (morph targets) aren't supported in 1.12 models; using the base shape.")
            a = prim["attributes"]
            if "POSITION" not in a:
                continue
            p = g.accessor(a["POSITION"])
            cnt = len(p)
            nn = g.accessor(a["NORMAL"]) if "NORMAL" in a else None
            uv = g.accessor(a["TEXCOORD_0"])[:, :2] if "TEXCOORD_0" in a else np.zeros((cnt, 2))
            if sk is None:
                w4 = rest_world[n]
                p = (w4 @ np.c_[p, np.ones(cnt)].T).T[:, :3]
                if nn is not None:
                    nn = (np.linalg.inv(w4[:3, :3]).T @ nn.T).T
                jb = np.zeros((cnt, 4), dtype=np.int64)
                jb[:, 0] = bone_of[n]
                jw = np.zeros((cnt, 4))
                jw[:, 0] = 1.0
            else:
                joints = g.skins[sk]["joints"]
                jl = g.accessor(a["JOINTS_0"], as_float=False).astype(np.int64)
                jw = g.accessor(a["WEIGHTS_0"])
                if "JOINTS_1" in a and "WEIGHTS_1" in a:
                    jl = np.c_[jl, g.accessor(a["JOINTS_1"], as_float=False).astype(np.int64)]
                    jw = np.c_[jw, g.accessor(a["WEIGHTS_1"])]
                lut = np.array([bone_of[j] for j in joints], dtype=np.int64)
                jb = lut[np.clip(jl, 0, len(lut) - 1)]
                if jw.shape[1] > 4:
                    keep = np.argsort(-jw, axis=1)[:, :4]
                    jw = np.take_along_axis(jw, keep, 1)
                    jb = np.take_along_axis(jb, keep, 1)
                    out.note("Kept the 4 strongest bone weights per vertex (1.12's limit).")
                s = jw.sum(1, keepdims=True)
                s[s <= 0] = 1
                jw = jw / s
                jb = np.where(jw > 0, jb, 0)
            p = (C @ np.c_[p, np.ones(cnt)].T).T[:, :3]
            if nn is None:
                nn = np.zeros((cnt, 3))
                need_normals = True
            else:
                need_normals = False
                nn = (R3 @ nn.T).T
            idx = (g.accessor(prim["indices"], as_float=False).reshape(-1).astype(np.int64)
                   if "indices" in prim else np.arange(cnt))
            idx = idx.reshape(-1, 3)
            if need_normals:
                fn = np.cross(p[idx[:, 1]] - p[idx[:, 0]], p[idx[:, 2]] - p[idx[:, 0]])
                for k in range(3):
                    np.add.at(nn, idx[:, k], fn)
            ln = np.linalg.norm(nn, axis=1, keepdims=True)
            nn = np.where(ln > 1e-12, nn / np.maximum(ln, 1e-12), [0, 0, 1])
            pos.append(p)
            nrm.append(nn)
            uvs.append(uv)
            bw.append(jw)
            bi.append(jb)
            mat = prim.get("material", -1)
            tris_by_mat.setdefault(mat, []).append(idx + vbase)
            vbase += cnt
    pos = np.concatenate(pos)
    nrm, uvs = np.concatenate(nrm), np.concatenate(uvs)
    bw, bi = np.concatenate(bw), np.concatenate(bi)
    total_tris = sum(len(t) for ts in tris_by_mat.values() for t in ts)
    cap = int(opts.get("max_triangles") or 20000)
    if total_tris > cap:
        pos, nrm, uvs, bw, bi, tris_by_mat = _decimate(pos, nrm, uvs, bw, bi, tris_by_mat, cap, out)
    if len(pos) > 65535:
        raise GltfError(f"{len(pos)} vertices: a 1.12 model holds at most 65,535. Decimate it first "
                        "(a mount usually looks right at 3,000–12,000).")
    wq = _quant_weights(bw)
    bi = np.where(wq > 0, bi, 0).astype(np.uint8)
    if len(pos) > 20000:
        out.warn(f"{len(pos):,} vertices is heavy for a 2004-era client; 3,000–12,000 is typical.")

    # ---- materials and textures --------------------------------------------------------------
    # Each glTF material becomes an M2 material + texture. Flat-colour materials (no texture) with
    # the same render state are merged into one, drawing from a swatch atlas, so a model with 50
    # painted parts is one draw call, not 50.
    tmax = int(opts.get("texture_max", 512))
    info = {}
    for mi in sorted(tris_by_mat):
        mat = g.materials[mi] if 0 <= mi < len(g.materials) else {}
        pbr = mat.get("pbrMetallicRoughness", {})
        factor = np.array(pbr.get("baseColorFactor", [1, 1, 1, 1]), dtype=np.float64)
        img = None
        if "baseColorTexture" in pbr:
            data = g.texture_image(pbr["baseColorTexture"]["index"])
            if data:
                try:
                    img = _load_image(data).convert("RGBA")
                except Exception as e:  # noqa: BLE001
                    out.warn(f"Couldn't read the texture of material {mat.get('name', mi)}: {e}")
            if pbr["baseColorTexture"].get("texCoord", 0) != 0:
                out.warn("A texture uses a second UV set; 1.12 models draw with the first.")
            if "KHR_texture_transform" in pbr["baseColorTexture"].get("extensions", {}):
                out.warn("A texture transform (tiling/offset) isn't applied; bake it into the UVs.")
        if img is not None and np.any(factor != 1):
            arr = np.asarray(img).astype(np.float64) * factor[None, None, :]
            img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
        blend = {"OPAQUE": 0, "MASK": 1, "BLEND": 2}.get(mat.get("alphaMode", "OPAQUE"), 0)
        flags = (0x04 if mat.get("doubleSided") else 0) | (0x01 if "KHR_materials_unlit" in mat.get("extensions", {}) else 0)
        info[mi] = {"img": img, "factor": factor, "flags": flags, "blend": blend, "name": mat.get("name", f"#{mi}")}
        if mat.get("normalTexture") or pbr.get("metallicRoughnessTexture"):
            out.note("Normal and roughness maps are dropped: 1.12 models use the colour texture only.")

    flat = [mi for mi in info if info[mi]["img"] is None]
    if flat:
        cell = 4
        per = int(np.ceil(np.sqrt(len(flat))))
        side = 1
        while side < per * cell:
            side *= 2
        side = max(side, 8)
        per = side // cell
        atlas = np.full((side, side, 4), 255, dtype=np.uint8)
        merged = {}
        for k, mi in enumerate(flat):
            cx, cy = k % per, k // per
            col = (np.clip(info[mi]["factor"], 0, 1) * 255).astype(np.uint8)
            atlas[cy * cell:(cy + 1) * cell, cx * cell:(cx + 1) * cell] = col
            u, v = (cx * cell + cell / 2) / side, (cy * cell + cell / 2) / side
            vs = np.unique(np.concatenate(tris_by_mat[mi]))
            uvs[vs] = [u, v]
            key = ("swatch", info[mi]["flags"], info[mi]["blend"])
            merged.setdefault(key, []).extend(tris_by_mat.pop(mi))
        swatch = Image.fromarray(atlas, "RGBA")
        for key, tl in merged.items():
            tris_by_mat[key] = tl
            info[key] = {"img": swatch, "factor": np.ones(4), "flags": key[1], "blend": key[2], "name": "colours"}
        out.note(f"{len(flat)} flat-colour material{'s' if len(flat) > 1 else ''} packed into one swatch texture.")

    tex_records, mat_records, mat_tex, tex_of_img = [], [], {}, {}
    order_m = sorted(tris_by_mat, key=lambda k: (isinstance(k, tuple), str(k)))
    for mi in order_m:
        im = info[mi]
        if id(im["img"]) not in tex_of_img:
            data, has_alpha, size = blp.encode(im["img"], tmax)
            if not tex_records and kind != "doodad":
                fname = f"{name}Skin"
                ttype, tfile = 11, ""   # Monster skin 1: the display row names it, so reskins work
                out.meta["texture_variation"] = fname
            else:
                fname = f"{name}_{len(tex_records)}"
                ttype, tfile = 0, f"{folder}\\{fname}.blp"
            out.files[f"{folder}\\{fname}.blp"] = data
            tex_records.append({"type": ttype, "flags": 3, "file": tfile})
            tex_of_img[id(im["img"])] = len(tex_records) - 1
            out.note(f"Texture {fname}.blp: {size[0]}×{size[1]}, {'DXT5 with alpha' if has_alpha else 'DXT1'}.")
        mat_records.append((im["flags"], im["blend"]))
        mat_tex[mi] = (len(mat_records) - 1, tex_of_img[id(im["img"])])
    if len(tex_records) > 1:
        out.note("Only the first texture can be reskinned per display; the others are fixed.")

    # ---- skin: submeshes per material, split to the bone limit -------------------------------
    skin_indices, skin_tris, props, submeshes, batches, bone_lookup = [], [], [], [], [], []
    for mi in order_m:
        tris = np.concatenate(tris_by_mat[mi])
        groups, cur, cur_bones = [], [], set()
        for t in tris:
            tb = set(int(b) for v in t for b, w in zip(bi[v], wq[v]) if w > 0)
            if cur and len(cur_bones | tb) > BONE_LIMIT:
                groups.append((cur, cur_bones))
                cur, cur_bones = [], set()
            cur.append(t)
            cur_bones |= tb
        if cur:
            groups.append((cur, cur_bones))
        for tris_g, bones_g in groups:
            bl = sorted(bones_g) or [0]
            local = {b: k for k, b in enumerate(bl)}
            verts = sorted(set(int(v) for t in tris_g for v in t))
            vstart = len(skin_indices)
            vmap = {v: vstart + k for k, v in enumerate(verts)}
            skin_indices += verts
            for v in verts:
                props.append([local.get(int(b), 0) if w > 0 else 0 for b, w in zip(bi[v], wq[v])])
            istart = len(skin_tris)
            for t in tris_g:
                skin_tris += [vmap[int(t[0])], vmap[int(t[1])], vmap[int(t[2])]]
            infl = int(max((wq[v] > 0).sum() for v in verts))
            usage = np.bincount(np.concatenate([bi[v][wq[v] > 0] for v in verts]), minlength=len(parents))
            submeshes.append({"id": 0, "vstart": vstart, "vcount": len(verts), "istart": istart,
                              "icount": len(skin_tris) - istart, "bone_count": len(bl),
                              "bone_start": len(bone_lookup), "influences": infl,
                              "center_bone": int(usage.argmax()),
                              "center": pos[verts].mean(0).tolist()})
            bone_lookup += bl
            batches.append({"submesh": len(submeshes) - 1, "material": mat_tex[mi][0],
                            "texture": mat_tex[mi][1]})
    if len(skin_indices) > 65535 or len(skin_tris) > 65535:
        raise GltfError(f"{len(skin_tris) // 3:,} triangles: a 1.12 model holds at most 21,845 "
                        "(its index ranges are 16-bit). Decimate it first; mounts look right at 4,000–12,000.")

    # ---- animations --------------------------------------------------------------------------
    clips = []  # (wow id, variation hint, label, sampled bone keys, duration)
    overrides = opts.get("anims", {})
    nb = len(parents)

    def sample_clip(chans, dur):
        if dur <= 0:
            times = [0.0]
        else:
            nfr = max(1, int(np.ceil(dur * FPS)))
            grid = {round(min(dur, k / FPS), 5) for k in range(nfr + 1)}
            for _, _, tk, _, _ in chans:  # the source's own keyframes, so nothing between is lost
                grid |= {round(float(x), 5) for x in tk if 0 <= x <= dur}
            times = sorted(grid)
        frames = []
        for t in times:
            trs = g.pose_at(chans, t) if chans else g.rest
            frames.append(bone_mats(g.world_matrices(trs)))
        return times, frames

    skipped = []
    for ai, a in enumerate(g.animations):
        label = a.get("name") or f"Animation {ai + 1}"
        ov = overrides.get(label, {})
        if ov.get("skip"):
            continue
        if "id" in ov:
            aid, var = int(ov["id"]), 0
        else:
            aid, var = names.parse(label)
        if aid is None:
            skipped.append(label)
            continue
        chans, dur = g.animation_channels(ai)
        times, frames = sample_clip(chans, dur)
        clips.append({"id": aid, "var": var, "label": label, "times": times, "frames": frames,
                      "dur": dur, "speed": ov.get("speed"), "loop": ov.get("loop")})
    if skipped:
        out.warn("Skipped clips with no WoW match (rename them, or pick an animation for them): "
                 + ", ".join(skipped))
    have = {c["id"] for c in clips}
    if 0 not in have:
        times, frames = sample_clip([], 0)
        clips.append({"id": 0, "var": 0, "label": "(rest pose)", "times": [0.0, 1.0],
                      "frames": frames * 2, "dur": 1.0, "speed": None, "loop": True})
        if kind != "doodad":   # a prop standing still is what a doodad is
            out.warn("No idle clip found, so Stand is the rest pose. Add an Idle/Stand animation for life.")
    if 13 not in have and 4 in have:
        w = next(c for c in clips if c["id"] == 4)
        span_w = w["times"][-1]
        clips.append({"id": 13, "var": 0, "label": f"{w['label']} (reversed)",
                      "times": [span_w - t for t in w["times"][::-1]], "frames": w["frames"][::-1], "dur": w["dur"],
                      # the walk's own stride, so the feet keep matching the ground going backwards
                      "speed": w["speed"] or DEFAULT_SPEED.get(kind, DEFAULT_SPEED["creature"])[4], "loop": True})
        out.note("Walk backwards: made from the walk, played in reverse.")
    if kind == "mount":
        for need, what in ((4, "Walk"), (5, "Run")):
            if need not in have and not (need == 4 and 5 in have) and not (need == 5 and 4 in have):
                out.warn(f"No {what} clip: the mount will slide while moving.")

    # model length along +X for root-motion detection
    length = float(pos[:, 0].max() - pos[:, 0].min()) or 1.0
    speeds = DEFAULT_SPEED.get(kind, DEFAULT_SPEED["creature"])

    # timeline and keys
    clips.sort(key=lambda c: (c["id"], c["var"]))
    seq_meta = []
    t_keys = [[] for _ in range(nb)]
    r_keys = [[] for _ in range(nb)]
    s_keys = [[] for _ in range(nb)]
    cursor = 0
    pos_h = np.c_[pos, np.ones(len(pos))]
    wf = wq.astype(np.float64) / 255.0
    report_rows = []
    for c in clips:
        frames = c["frames"]
        times = c["times"]
        dur_ms = max(1, int(round((times[-1] if len(times) > 1 else 1.0) * 1000)))
        if len(times) == 1:
            times = [0.0, dur_ms / 1000.0]
            frames = frames * 2
        start, end = cursor, cursor + dur_ms
        cursor = end + 100
        # locals per frame
        locs = []
        worst_shear = 0.0
        for M in frames:
            lf = []
            for b in range(nb):
                if b == 0:
                    lf.append((np.zeros(3), np.array([0, 0, 0, 1.0]), np.ones(3)))
                    continue
                L = np.linalg.inv(M[parents[b]]) @ M[b]
                X = _T(-pivots[b]) @ L @ _T(pivots[b])
                t, q, s, err = decompose(X)
                worst_shear = max(worst_shear, err)
                lf.append((t, q, s))
            locs.append(lf)
        # root motion: the top bones' forward drift over a locomotion clip
        speed = c["speed"]
        tops = [b for b in range(1, nb) if parents[b] == 0]
        drift = np.zeros(3)
        if c["id"] in LOCOMOTION and tops and len(frames) > 1:
            d = frames[-1][tops[0]][:3, 3] - frames[0][tops[0]][:3, 3]
            if abs(d[0]) > 0.15 * length or abs(d[1]) > 0.15 * length:
                drift = d
                if speed is None:
                    speed = float(np.hypot(d[0], d[1])) / max(1e-6, (times[-1] - times[0]))
                out.note(f"{c['label']}: moved {np.hypot(d[0], d[1]):.2f} yd in place of root motion; "
                         f"kept in place, playback matched to {speed:.1f} yd/s.")
        if speed is None:
            speed = speeds.get(c["id"], 0.0)
        span = max(1e-6, times[-1] - times[0])
        for k, t in enumerate(times):
            ms = start + int(round(t * 1000))
            ms = min(ms, end)
            for b in range(1, nb):
                tr, q, s = locs[k][b]
                if b in tops and drift.any():
                    tr = tr - drift * ((t - times[0]) / span)
                t_keys[b].append((len(seq_meta), ms, tr))
                r_keys[b].append((len(seq_meta), ms, q))
                s_keys[b].append((len(seq_meta), ms, s))
        if worst_shear > 0.02:
            out.warn(f"{c['label']}: a parent bone scales unevenly, which 1.12 bones can't do; "
                     "the nearest pose is used.")
        # per-sequence bounds: skin the mesh at a few frames
        step = max(1, len(frames) // 8)
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        for M in frames[::step] + [frames[-1]]:
            Ms = np.stack(M)
            acc = np.zeros((len(pos), 3))
            for k in range(4):
                acc += wf[:, k:k + 1] * np.einsum("nij,nj->ni", Ms[bi[:, k]], pos_h)[:, :3]
            lo, hi = np.minimum(lo, acc.min(0)), np.maximum(hi, acc.max(0))
        loop = c["loop"] if c["loop"] is not None else c["id"] in names.LOOPING
        seq_meta.append({"id": c["id"], "start": start, "end": end, "move_speed": float(speed),
                         "flags": 0 if loop else 1, "blend": 150, "bmin": lo.tolist(), "bmax": hi.tolist(),
                         "radius": float(np.linalg.norm(np.maximum(np.abs(lo), np.abs(hi)))),
                         "label": c["label"], "dur": dur_ms / 1000.0, "loop": loop})
        report_rows.append((c["label"], c["id"], names.anim_name(c["id"]), dur_ms / 1000.0, speed, loop))

    # variations, lookups
    seen = {}
    for i, s in enumerate(seq_meta):
        s["variation"] = seen.get(s["id"], 0)
        seen[s["id"]] = s["variation"] + 1
    for i, s in enumerate(seq_meta):
        later = [j for j in range(i + 1, len(seq_meta)) if seq_meta[j]["id"] == s["id"]]
        s["next"] = later[0] if later else -1
        s["alias"] = i
        s["frequency"] = 32767 // seen[s["id"]]
    owned = sorted(seen)
    anim_lookup = [0xffff] * (max(owned) + 1)
    for i, s in enumerate(seq_meta):
        if anim_lookup[s["id"]] == 0xffff:
            anim_lookup[s["id"]] = i
    playable = names.playable_lookup(set(owned))

    # bone keys per sequence, reduced, quaternions kept in one hemisphere
    bones_out = []
    animated_bones = 0
    head_bone = None
    for b in range(nb):
        node = bone_nodes[b - 1] if b else None
        bname = (g.nodes[node].get("name", "") if node is not None else "Root").lower()
        if head_bone is None and node is not None and re.search(r"head", bname) and not re.search(r"end|top|nub|tip", bname):
            head_bone = b

        def per_seq(keys, kind_, tol, ident):
            outk = [[] for _ in seq_meta]
            for si, ms, v in keys:
                outk[si].append((ms, np.asarray(v, dtype=np.float64)))
            moving = False
            res = []
            for si, ks in enumerate(outk):
                if kind_ == "q":
                    for k in range(1, len(ks)):
                        if np.dot(ks[k][1], ks[k - 1][1]) < 0:
                            ks[k] = (ks[k][0], -ks[k][1])
                ks = _reduce(ks, kind_, tol)
                if len(ks) == 2 and (np.abs(ks[0][1] - ks[1][1]).max() < 1e-6):
                    ks = ks[:1]
                if any(np.abs(v - ident).max() > 1e-5 for _, v in ks) or len(ks) > 1:
                    moving = True
                res.append([(ms, tuple(float(x) for x in v)) for ms, v in ks])
            return res if moving else [[] for _ in seq_meta]

        tk = per_seq(t_keys[b], "v", 1e-3 * max(1.0, scale), np.zeros(3)) if b else [[] for _ in seq_meta]
        rk = per_seq(r_keys[b], "q", 2e-6, np.array([0, 0, 0, 1.0])) if b else [[] for _ in seq_meta]
        sk_ = per_seq(s_keys[b], "v", 1e-3, np.ones(3)) if b else [[] for _ in seq_meta]
        anim = any(tk) or any(rk) or any(sk_)
        animated_bones += anim
        bones_out.append({"key_bone": -1, "flags": 0x200 if anim else 0, "parent": parents[b],
                          "pivot": pivots[b].tolist(), "t_keys": tk, "r_keys": rk, "s_keys": sk_})
    key_bone_lookup = [-1] * 7
    if head_bone is not None:
        bones_out[head_bone]["key_bone"] = 6
        key_bone_lookup[6] = head_bone

    # ---- attachments -------------------------------------------------------------------------
    bmin, bmax = pos.min(0), pos.max(0)
    for s in seq_meta:
        bmin, bmax = np.minimum(bmin, s["bmin"]), np.maximum(bmax, s["bmax"])
    atts = {}
    named = {}
    for n in order:
        nm = re.sub(r"[^a-z0-9]", "", g.nodes[n].get("name", "").lower())
        m_ = re.match(r"attach(\d+)$", nm)
        wpos = (C @ rest_world[n] @ np.array([0, 0, 0, 1.0]))[:3]
        b = bone_of.get(n) or bone_parent(n)
        if m_:
            named[int(m_.group(1))] = (b, wpos)
        elif nm in SEAT_NAMES and 0 not in named:
            named[0] = (b, wpos)
    if kind == "mount":
        if 0 in named:
            atts[0] = named[0]
            out.note("Rider seat: from the model's own seat marker.")
        elif "seat" in opts:
            sp = np.array(opts["seat"], dtype=np.float64)
            atts[0] = (_nearest_bone(sp, pos, bi, wq), sp)
        else:
            cx = (bmin[0] + bmax[0]) / 2
            band = np.abs(pos[:, 0] - cx) < 0.15 * length
            band &= np.abs(pos[:, 1]) < 0.25 * (bmax[1] - bmin[1] + 1e-6)
            if not band.any():
                band = np.ones(len(pos), bool)
            top = pos[band][:, 2].max()
            sp = np.array([cx, 0.0, top])
            atts[0] = (_nearest_bone(sp, pos, bi, wq), sp)
            out.warn("Rider seat: guessed at the middle of the back. For an exact seat, add an empty "
                     "named \"Seat\" where the rider sits (child of the spine bone) and port again.")
        sb, sp = atts[0]
        atts[29] = (sb, sp + np.array([0, 0, 2.6]))      # name plate while mounted, above the rider
    hb = head_bone if head_bone is not None else 0
    head_p = pivots[hb] if head_bone is not None else np.array([bmax[0] * 0.8, 0, bmax[2] * 0.85])
    atts.setdefault(11, (hb, head_p + np.array([0, 0, 0.1])))   # helm
    atts.setdefault(17, (hb, head_p + np.array([0.15, 0, 0])))  # breath
    atts.setdefault(18, (0, np.array([0, 0, bmax[2] + 0.3])))   # name plate
    atts.setdefault(19, (0, np.zeros(3)))                       # base
    atts.setdefault(20, (hb, head_p))                           # head
    ctr = (bmin + bmax) / 2
    atts.setdefault(15, (_nearest_bone(ctr, pos, bi, wq), np.array([bmax[0] * 0.5, 0, ctr[2]])))
    atts.setdefault(16, (_nearest_bone(ctr, pos, bi, wq), np.array([bmin[0] * 0.5, 0, ctr[2]])))
    for k, v in named.items():
        atts[k] = v
    att_list = [{"id": k, "bone": int(v[0]), "position": [float(x) for x in v[1]]} for k, v in sorted(atts.items())]
    attach_lookup = [-1] * (max(atts) + 1)
    for i, a in enumerate(att_list):
        attach_lookup[a["id"]] = i

    # ---- bounds, collision, portrait camera --------------------------------------------------
    radius = float(np.linalg.norm(np.maximum(np.abs(bmin), np.abs(bmax))))
    # collision: the model's own shape (doodads: walk into a doorway, stand on a roof), its box
    # (creatures and mounts), or none
    coll = opts.get("collision") or ("mesh" if kind == "doodad" else "box")
    if coll == "mesh":
        cverts, ctris = _collision_mesh(pos, [t for ts in tris_by_mat.values() for t in ts], out)
    elif coll == "none":
        cverts, ctris = [], []
    else:
        cverts = [[x, y, z] for x in (bmin[0], bmax[0]) for y in (bmin[1], bmax[1]) for z in (bmin[2], bmax[2])]
        ctris = [0, 1, 3, 0, 3, 2, 4, 6, 7, 4, 7, 5, 0, 4, 5, 0, 5, 1, 2, 3, 7, 2, 7, 6, 0, 2, 6, 0, 6, 4, 1, 5, 7, 1, 7, 3]
    out.meta["collision"] = coll
    cnorms = []
    for k in range(0, len(ctris), 3):
        a_, b_, c_ = (np.array(cverts[ctris[k + j]]) for j in range(3))
        nv = np.cross(b_ - a_, c_ - a_)
        cnorms.append((nv / (np.linalg.norm(nv) or 1)).tolist())
    size = float(max(bmax - bmin))
    target = head_p if head_bone is not None else np.array([bmax[0] * 0.6, 0, bmax[2] * 0.8])
    cam = {"type": 0, "fov": 0.7, "far": 27.777779, "near": 0.22222222,
           "position": (target + np.array([max(0.8, size * 0.45), 0, 0.05])).tolist(),
           "target": target.tolist()}

    model = {
        "name": name,
        "sequences": seq_meta,
        "animation_lookup": anim_lookup,
        "playable_lookup": playable,
        "bones": bones_out,
        "key_bone_lookup": key_bone_lookup,
        "vertices": {"pos": pos.astype(np.float32), "normal": nrm.astype(np.float32),
                     "uv": uvs.astype(np.float32), "weights": wq, "bones": bi},
        "textures": tex_records,
        "replaceable_lookup": [0 if (k == 11 and tex_records and tex_records[0]["type"] == 11) else -1
                               for k in range(14)],
        "materials": mat_records,
        "bone_lookup": bone_lookup,
        "texture_lookup": list(range(len(tex_records))),
        "bounds": (bmin.tolist(), bmax.tolist(), radius),
        "collision_bounds": (bmin.tolist(), bmax.tolist(), radius),
        "collision": (ctris, cverts, cnorms),
        "attachments": att_list,
        "attach_lookup": attach_lookup,
        "cameras": [cam],
        "camera_lookup": [0],
        "skin": {"indices": skin_indices, "triangles": skin_tris, "properties": props,
                 "submeshes": submeshes, "batches": batches,
                 "bone_count_max": max(s["bone_count"] for s in submeshes)},
    }
    data = m2.write(model)
    out.files[f"{folder}\\{name}.m2"] = data
    out.meta.update({
        "model_path": f"{folder}\\{name}.mdx",
        "height": float(bmax[2] - bmin[2]),
        "length": float(bmax[0] - bmin[0]),
        "width": float(bmax[1] - bmin[1]),
        "vertices": int(len(pos)), "triangles": int(len(skin_tris) // 3), "bones": nb,
        "animated_bones": int(animated_bones), "submeshes": len(submeshes),
        "animations": [{"clip": r[0], "id": r[1], "wow": r[2], "seconds": round(r[3], 2),
                        "speed": round(float(r[4]), 2), "loop": bool(r[5])} for r in report_rows],
        "attachments": [a["id"] for a in att_list],
        "seat": [float(x) for x in atts[0][1]] if 0 in atts else None,
        "m2_bytes": len(data),
        "scale": scale,
    })
    out.axis = C
    out.bone_nodes = bone_nodes
    out.ibm = ibm
    out.preview = {"pos": pos, "tris": np.array(skin_indices)[np.array(skin_tris).reshape(-1, 3)],
                   "uv": uvs, "bones": bi, "weights": wq, "batches": batches, "submeshes": submeshes,
                   "skin_indices": skin_indices, "skin_tris": skin_tris}
    out.note(f"{len(pos):,} vertices, {len(skin_tris) // 3:,} triangles, {nb} bones "
             f"({animated_bones} animated), {len(seq_meta)} animations.")
    return out


def _nearest_bone(p, pos, bi, wq):
    d = np.linalg.norm(pos - p, axis=1)
    near = np.argsort(d)[:24]
    votes = {}
    for v in near:
        for b, w in zip(bi[v], wq[v]):
            if w:
                votes[int(b)] = votes.get(int(b), 0) + int(w)
    return max(votes, key=votes.get) if votes else 0


def _decimate(pos, nrm, uvs, bw, bi, tris_by_mat, cap, out):
    """Quadric decimation to ``cap`` triangles, each material on its own. UV seams are kept as
    borders first (so textures stay put); if that can't get low enough, seams may move."""
    try:
        import fast_simplification as fs
    except ImportError:
        raise GltfError("the model has more triangles than 1.12 allows, and automatic decimation needs "
                        "the fast-simplification package (pip install fast-simplification)")
    groups = {m: np.concatenate(t) for m, t in tris_by_mat.items()}
    total = sum(len(t) for t in groups.values())
    new_pos, new_nrm, new_uv, new_bw, new_bi, new_tris = [], [], [], [], [], {}
    base = 0
    for m, tris in groups.items():
        want = max(4, int(len(tris) * cap / total))
        verts = np.unique(tris)
        remap = np.full(len(pos), -1)
        remap[verts] = np.arange(len(verts))
        lt = remap[tris].astype(np.int32)
        lp = pos[verts].astype(np.float64)
        res = None
        for keep_border in (True, False):
            p2, t2, col = fs.simplify(lp, lt, target_count=want, return_collapses=True, preserve_border=keep_border)
            if len(t2) <= want * 1.15 or not keep_border:
                res = (p2, t2, col)
                break
        p2, t2, col = res
        _, _, mapping = fs.replay_simplification(lp, lt, col)
        # each new vertex takes its attributes from the closest original vertex that merged into it
        best = np.full(len(p2), -1)
        bestd = np.full(len(p2), np.inf)
        d = np.linalg.norm(lp - p2[mapping], axis=1)
        for o in np.argsort(d):
            k = mapping[o]
            if best[k] < 0:
                best[k] = o
                bestd[k] = d[o]
        src = verts[best]
        new_pos.append(p2)
        new_nrm.append(nrm[src])
        new_uv.append(uvs[src])
        new_bw.append(bw[src])
        new_bi.append(bi[src])
        new_tris[m] = [t2.astype(np.int64) + base]
        base += len(p2)
    after = sum(len(t[0]) for t in new_tris.values())
    out.meta["decimated"] = True
    out.warn(f"Decimated {total:,} → {after:,} triangles to fit 1.12 (check the preview; for best "
             "results, decimate in Blender and keep the UV seams).")
    return (np.concatenate(new_pos), np.concatenate(new_nrm), np.concatenate(new_uv),
            np.concatenate(new_bw), np.concatenate(new_bi), new_tris)
