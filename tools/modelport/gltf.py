"""A small glTF 2.0 / GLB reader: nodes, meshes, skins, animations and images, as numpy arrays.

Only what porting a model needs. Matrices are 4x4, column vectors (``M @ v``); quaternions are
``[x, y, z, w]`` as glTF stores them.
"""
import base64
import json
import os
import struct

import numpy as np


def _readb(path):
    with open(path, "rb") as f:
        return f.read()


def _writeb(path, data):
    with open(path, "wb") as f:
        f.write(data)

COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NORM = {5120: 127.0, 5121: 255.0, 5122: 32767.0, 5123: 65535.0}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}


class GltfError(Exception):
    pass


# -- quaternion and matrix helpers --------------------------------------------------------------

def quat_to_mat3(q):
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def mat3_to_quat(m):
    """Rotation matrix (orthonormal) to [x, y, z, w], w >= 0."""
    t = m[0, 0] + m[1, 1] + m[2, 2]
    if t > 0:
        s = np.sqrt(t + 1.0) * 2
        q = [(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s]
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = [0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s]
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = [(m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s]
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = [(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s]
    q = np.array(q, dtype=np.float64)
    q /= np.linalg.norm(q)
    return -q if q[3] < 0 else q


def slerp(a, b, t):
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    d = float(np.dot(a, b))
    if d < 0:
        b, d = -b, -d
    if d > 0.9995:
        r = a + t * (b - a)
        return r / np.linalg.norm(r)
    th = np.arccos(min(1.0, d))
    s = np.sin(th)
    return (np.sin((1 - t) * th) / s) * a + (np.sin(t * th) / s) * b


def trs_matrix(t, r, s):
    m = np.eye(4)
    m[:3, :3] = quat_to_mat3(r) * np.asarray(s, dtype=np.float64)[None, :]
    m[:3, 3] = t
    return m


def decompose(m):
    """4x4 → (translation, quaternion, scale, shear_error). Polar decomposition, so a sheared or
    mirrored matrix still gives the nearest rotation; ``shear_error`` says how far off it was."""
    t = m[:3, 3].copy()
    a = m[:3, :3]
    u, sig, vt = np.linalg.svd(a)
    r = u @ vt
    if np.linalg.det(r) < 0:
        u[:, -1] *= -1
        r = u @ vt
    p = r.T @ a  # stretch, in the rotated frame
    s = np.array([p[0, 0], p[1, 1], p[2, 2]])
    err = float(np.abs(p - np.diag(s)).max())
    return t, mat3_to_quat(r), s, err


# -- the file ------------------------------------------------------------------------------------

class Gltf:
    def __init__(self, path):
        self.path = path
        self.dir = os.path.dirname(os.path.abspath(path))
        raw = _readb(path)
        self.bin = None
        if raw[:4] == b"glTF":
            _, version, length = struct.unpack_from("<4sII", raw, 0)
            if version != 2:
                raise GltfError(f"glTF version {version}: only glTF 2.0 is supported")
            off = 12
            self.json = None
            while off < min(length, len(raw)):
                clen, ctype = struct.unpack_from("<II", raw, off)
                chunk = raw[off + 8: off + 8 + clen]
                if ctype == 0x4E4F534A:
                    self.json = json.loads(chunk.decode("utf-8"))
                elif ctype == 0x004E4942:
                    self.bin = chunk
                off += 8 + clen
            if self.json is None:
                raise GltfError("GLB has no JSON chunk")
        else:
            try:
                self.json = json.loads(raw.decode("utf-8"))
            except ValueError:
                raise GltfError("not a .glb or .gltf file")
        j = self.json
        if j.get("asset", {}).get("version", "2.0").split(".")[0] != "2":
            raise GltfError("only glTF 2.0 is supported")
        required = set(j.get("extensionsRequired", [])) - {"KHR_materials_unlit", "KHR_texture_transform"}
        if required:
            raise GltfError("needs glTF extensions this porter can't read: " + ", ".join(sorted(required))
                            + " (re-export without Draco / meshopt compression)")
        self.nodes = j.get("nodes", [])
        self.meshes = j.get("meshes", [])
        self.skins = j.get("skins", [])
        self.animations = j.get("animations", [])
        self.materials = j.get("materials", [])
        self._buffers = {}
        self.parent = [-1] * len(self.nodes)
        for i, n in enumerate(self.nodes):
            for c in n.get("children", []):
                self.parent[c] = i
        self.rest = [self._rest_trs(n) for n in self.nodes]

    # buffers and accessors
    def _buffer(self, i):
        if i in self._buffers:
            return self._buffers[i]
        b = self.json["buffers"][i]
        uri = b.get("uri")
        if uri is None:
            data = self.bin
        elif uri.startswith("data:"):
            data = base64.b64decode(uri.split(",", 1)[1])
        else:
            data = _readb(os.path.join(self.dir, _unquote(uri)))
        if data is None:
            raise GltfError(f"buffer {i} has no data")
        self._buffers[i] = data
        return data

    def view_bytes(self, i):
        v = self.json["bufferViews"][i]
        b = self._buffer(v["buffer"])
        o = v.get("byteOffset", 0)
        return b[o: o + v["byteLength"]], v.get("byteStride")

    def accessor(self, i, as_float=True):
        a = self.json["accessors"][i]
        dt = np.dtype(COMP[a["componentType"]])
        n = NCOMP[a["type"]]
        count = a["count"]
        if "bufferView" in a:
            data, stride = self.view_bytes(a["bufferView"])
            off = a.get("byteOffset", 0)
            esize = dt.itemsize * n
            if stride and stride != esize:
                rows = np.frombuffer(data, dtype=np.uint8, count=stride * (count - 1) + esize, offset=off)
                rows = np.lib.stride_tricks.as_strided(rows, shape=(count, esize), strides=(stride, 1))
                arr = np.frombuffer(rows.copy().tobytes(), dtype=dt).reshape(count, n)
            else:
                arr = np.frombuffer(data, dtype=dt, count=count * n, offset=off).reshape(count, n)
        else:
            arr = np.zeros((count, n), dtype=dt)
        arr = arr.copy()
        sp = a.get("sparse")
        if sp:
            idx_a = sp["indices"]
            idata, _ = self.view_bytes(idx_a["bufferView"])
            idx = np.frombuffer(idata, dtype=COMP[idx_a["componentType"]], count=sp["count"],
                                offset=idx_a.get("byteOffset", 0))
            vdata, _ = self.view_bytes(sp["values"]["bufferView"])
            vals = np.frombuffer(vdata, dtype=dt, count=sp["count"] * n,
                                 offset=sp["values"].get("byteOffset", 0)).reshape(-1, n)
            arr[idx.astype(np.int64)] = vals
        if as_float:
            if a.get("normalized") and a["componentType"] in NORM:
                out = arr.astype(np.float64) / NORM[a["componentType"]]
                return np.maximum(out, -1.0) if a["componentType"] in (5120, 5122) else out
            return arr.astype(np.float64)
        return arr

    def image_bytes(self, img_index):
        im = self.json["images"][img_index]
        if "bufferView" in im:
            return bytes(self.view_bytes(im["bufferView"])[0])
        uri = im.get("uri", "")
        if uri.startswith("data:"):
            return base64.b64decode(uri.split(",", 1)[1])
        return _readb(os.path.join(self.dir, _unquote(uri)))

    def texture_image(self, tex_index):
        t = self.json["textures"][tex_index]
        src = t.get("source")
        if src is None:
            for ext in t.get("extensions", {}).values():
                if "source" in ext:
                    src = ext["source"]
        return None if src is None else self.image_bytes(src)

    # transforms
    @staticmethod
    def _rest_trs(n):
        if "matrix" in n:
            m = np.array(n["matrix"], dtype=np.float64).reshape(4, 4).T
            t, r, s, _ = decompose(m)
            return t, r, s
        return (np.array(n.get("translation", [0, 0, 0]), dtype=np.float64),
                np.array(n.get("rotation", [0, 0, 0, 1]), dtype=np.float64),
                np.array(n.get("scale", [1, 1, 1]), dtype=np.float64))

    def world_matrices(self, trs):
        """World matrix per node from per-node (t, r, s)."""
        out = [None] * len(self.nodes)

        def w(i):
            if out[i] is None:
                local = trs_matrix(*trs[i])
                p = self.parent[i]
                out[i] = local if p < 0 else w(p) @ local
            return out[i]

        for i in range(len(self.nodes)):
            w(i)
        return out

    def scene_nodes(self):
        j = self.json
        sc = j.get("scenes", [{"nodes": [i for i, p in enumerate(self.parent) if p < 0]}])
        s = sc[j.get("scene", 0)] if sc else {"nodes": []}
        order = []

        def walk(i):
            order.append(i)
            for c in self.nodes[i].get("children", []):
                walk(c)

        for r in s.get("nodes", []):
            walk(r)
        return order

    # animation
    def animation_channels(self, ai):
        a = self.animations[ai]
        chans = []
        dur = 0.0
        for ch in a.get("channels", []):
            tgt = ch.get("target", {})
            if "node" not in tgt or tgt.get("path") not in ("translation", "rotation", "scale"):
                continue
            smp = a["samplers"][ch["sampler"]]
            times = self.accessor(smp["input"])[:, 0]
            vals = self.accessor(smp["output"])
            interp = smp.get("interpolation", "LINEAR")
            if len(times):
                dur = max(dur, float(times[-1]))
            chans.append((tgt["node"], tgt["path"], times, vals, interp))
        return chans, dur

    def pose_at(self, chans, t):
        trs = [(r[0].copy(), r[1].copy(), r[2].copy()) for r in self.rest]
        for node, path, times, vals, interp in chans:
            v = _sample(times, vals, interp, t, path == "rotation")
            tt, rr, ss = trs[node]
            if path == "translation":
                tt = v
            elif path == "rotation":
                rr = v / np.linalg.norm(v)
            else:
                ss = v
            trs[node] = (tt, rr, ss)
        return trs


def _unquote(u):
    from urllib.parse import unquote
    return unquote(u)


def _sample(times, vals, interp, t, is_quat):
    n = len(times)
    cubic = interp == "CUBICSPLINE"
    if cubic:
        vals = vals.reshape(n, 3, -1)
        key = lambda i: vals[i, 1]
    else:
        key = lambda i: vals[i]
    if n == 1 or t <= times[0]:
        return key(0).copy()
    if t >= times[-1]:
        return key(n - 1).copy()
    i = int(np.searchsorted(times, t, side="right")) - 1
    i = min(max(i, 0), n - 2)
    t0, t1 = times[i], times[i + 1]
    u = 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
    if interp == "STEP":
        return key(i).copy()
    if cubic:
        dt = t1 - t0
        p0, m0 = vals[i, 1], vals[i, 2] * dt
        p1, m1 = vals[i + 1, 1], vals[i + 1, 0] * dt
        u2, u3 = u * u, u * u * u
        r = (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1
        return r / np.linalg.norm(r) if is_quat else r
    if is_quat:
        return slerp(key(i), key(i + 1), u)
    return key(i) * (1 - u) + key(i + 1) * u
