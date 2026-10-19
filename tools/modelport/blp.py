"""PNG/JPEG → BLP2 with DXT1 (opaque) or DXT5 (alpha) blocks and a full mip chain: the texture
format the 1.12 client and the browser engine both read (benilla-blp, compression 2).

The DXT encoder is a vectorised principal-axis fit per 4x4 block: good quality, no extra tools.
"""
import io
import struct

import numpy as np
from PIL import Image


def _pow2_floor(n):
    p = 1
    while p * 2 <= n:
        p *= 2
    return p


def prepare(im, max_size=1024):
    """RGBA, power-of-two sides (rounded to nearest), capped at ``max_size``."""
    im = im.convert("RGBA")
    w, h = im.size

    def fit(n):
        lo = _pow2_floor(max(1, n))
        hi = lo * 2
        p = hi if (hi - n) < (n - lo) else lo
        return max(4, min(max_size, p))

    nw, nh = fit(w), fit(h)
    if (nw, nh) != (w, h):
        im = im.resize((nw, nh), Image.Resampling.LANCZOS)
    return im


def _to565(c):
    c = np.clip(np.rint(c), 0, 255).astype(np.int32)
    return ((c[..., 0] >> 3) << 11) | ((c[..., 1] >> 2) << 5) | (c[..., 2] >> 3)


def _from565(v):
    r = (v >> 11) & 31
    g = (v >> 5) & 63
    b = v & 31
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], -1).astype(np.float64)


def _blocks(a):
    """(H, W, C) → (N, 16, C), row-major 4x4 blocks; pads to a multiple of 4."""
    h, w, c = a.shape
    ph, pw = max(4, (h + 3) // 4 * 4), max(4, (w + 3) // 4 * 4)
    if (ph, pw) != (h, w):
        a = np.pad(a, ((0, ph - h), (0, pw - w), (0, 0)), mode="edge")
    b = a.reshape(ph // 4, 4, pw // 4, 4, c).transpose(0, 2, 1, 3, 4).reshape(-1, 16, c)
    return b


def _color_blocks(rgb):
    """(N, 16, 3) floats → (N, 8) bytes of DXT1 colour data in 4-colour mode."""
    mean = rgb.mean(1, keepdims=True)
    d = rgb - mean
    cov = np.einsum("nki,nkj->nij", d, d)
    # principal axis by power iteration
    axis = np.ones((len(rgb), 3)) / np.sqrt(3)
    for _ in range(8):
        axis = np.einsum("nij,nj->ni", cov, axis)
        nrm = np.linalg.norm(axis, axis=1, keepdims=True)
        axis = np.where(nrm > 1e-9, axis / np.maximum(nrm, 1e-12), np.ones_like(axis) / np.sqrt(3))
    proj = np.einsum("nki,ni->nk", d, axis)
    lo = mean[:, 0] + axis * proj.min(1, keepdims=True)
    hi = mean[:, 0] + axis * proj.max(1, keepdims=True)
    c0, c1 = _to565(hi), _to565(lo)
    # 4-colour mode needs c0 > c1; equal endpoints use index 0 everywhere
    swap = c0 < c1
    c0, c1 = np.where(swap, c1, c0), np.where(swap, c0, c1)
    e0, e1 = _from565(c0), _from565(c1)
    pal = np.stack([e0, e1, (2 * e0 + e1) / 3, (e0 + 2 * e1) / 3], 1)  # (N, 4, 3)
    dist = ((rgb[:, :, None, :] - pal[:, None, :, :]) ** 2).sum(-1)  # (N, 16, 4)
    idx = dist.argmin(-1).astype(np.uint32)
    idx = np.where((c0 == c1)[:, None], 0, idx)
    bits = (idx << (2 * np.arange(16, dtype=np.uint32))[None, :]).sum(1).astype(np.uint32)
    out = np.zeros((len(rgb), 8), dtype=np.uint8)
    out[:, 0:2] = np.stack([c0 & 255, c0 >> 8], 1)
    out[:, 2:4] = np.stack([c1 & 255, c1 >> 8], 1)
    out[:, 4:8] = bits.view(np.uint8).reshape(-1, 4)
    return out


def _alpha_blocks(a):
    """(N, 16) floats → (N, 8) bytes of DXT5 alpha (8-value mode, a0 > a1)."""
    a0 = np.clip(np.rint(a.max(1)), 0, 255).astype(np.int32)
    a1 = np.clip(np.rint(a.min(1)), 0, 255).astype(np.int32)
    same = a0 == a1
    a0 = np.where(same & (a0 < 255), a0 + 1, a0)
    a1 = np.where(same & (a0 == 255) & (a1 == 255), 254, a1)
    steps = np.arange(8)
    w0 = np.array([7, 0, 6, 5, 4, 3, 2, 1]) / 7.0
    pal = a0[:, None] * w0[None, :] + a1[:, None] * (1 - w0[None, :])  # code order
    idx = np.abs(a[:, :, None] - pal[:, None, :]).argmin(-1).astype(np.uint64)
    bits = (idx << (3 * np.arange(16, dtype=np.uint64))[None, :]).sum(1).astype(np.uint64)
    out = np.zeros((len(a), 8), dtype=np.uint8)
    out[:, 0] = a0
    out[:, 1] = a1
    out[:, 2:8] = bits.view(np.uint8).reshape(-1, 8)[:, :6]
    del steps
    return out


def encode(im, max_size=1024):
    """PIL image → BLP2 bytes. DXT5 when any pixel is transparent, else DXT1."""
    im = prepare(im, max_size)
    arr = np.asarray(im).astype(np.float64)
    has_alpha = bool((arr[..., 3] < 250).any())
    levels = []
    cur = im
    while True:
        a = np.asarray(cur).astype(np.float64)
        blk = _blocks(a)
        col = _color_blocks(blk[:, :, :3])
        if has_alpha:
            levels.append(np.concatenate([_alpha_blocks(blk[:, :, 3]), col], 1).tobytes())
        else:
            levels.append(col.tobytes())
        if cur.width == 1 and cur.height == 1 or len(levels) == 16:
            break
        cur = cur.resize((max(1, cur.width // 2), max(1, cur.height // 2)), Image.Resampling.BOX)
    w, h = im.size
    header = 4 + 4 + 4 + 4 + 4 + 64 + 64
    at = header + 1024
    offsets, sizes = [], []
    for lv in levels:
        offsets.append(at)
        sizes.append(len(lv))
        at += len(lv)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    out = io.BytesIO()
    out.write(b"BLP2")
    out.write(struct.pack("<I", 1))
    out.write(struct.pack("<BBBB", 2, 8 if has_alpha else 0, 7 if has_alpha else 0, 1))
    out.write(struct.pack("<II", w, h))
    out.write(struct.pack("<16I", *offsets))
    out.write(struct.pack("<16I", *sizes))
    out.write(b"\0" * 1024)
    for lv in levels:
        out.write(lv)
    return out.getvalue(), has_alpha, (w, h)


def decode_dxt_top(blp):
    """BLP2 DXT1/DXT5 top level → RGBA numpy array (for previews and tests)."""
    comp, adepth, atype = blp[8], blp[9], blp[10]
    w, h = struct.unpack_from("<II", blp, 12)
    off = struct.unpack_from("<I", blp, 20)[0]
    assert comp == 2
    alpha = atype == 7
    bs = 16 if alpha else 8
    nb = max(1, w // 4) * max(1, h // 4)
    data = np.frombuffer(blp, dtype=np.uint8, count=nb * bs, offset=off).reshape(nb, bs)
    cd = data[:, 8:16] if alpha else data[:, 0:8]
    c0 = cd[:, 0].astype(np.int32) | (cd[:, 1].astype(np.int32) << 8)
    c1 = cd[:, 2].astype(np.int32) | (cd[:, 3].astype(np.int32) << 8)
    e0, e1 = _from565(c0), _from565(c1)
    pal = np.stack([e0, e1, (2 * e0 + e1) / 3, (e0 + 2 * e1) / 3], 1)
    if not alpha:
        # DXT1 blocks with c0 <= c1 are 3-colour: the midpoint, then black (transparent)
        three = c0 <= c1
        pal[three, 2] = (e0[three] + e1[three]) / 2
        pal[three, 3] = 0
    bits = cd[:, 4:8].copy().view(np.uint32)[:, 0]
    idx = (bits[:, None] >> (2 * np.arange(16, dtype=np.uint32))[None, :]) & 3
    rgb = np.take_along_axis(pal, idx[:, :, None].astype(np.int64).repeat(3, 2), 1)
    if alpha:
        a0 = data[:, 0].astype(np.float64)
        a1 = data[:, 1].astype(np.float64)
        ab = np.zeros(nb, dtype=np.uint64)
        for k in range(6):
            ab |= data[:, 2 + k].astype(np.uint64) << np.uint64(8 * k)
        ai = (ab[:, None] >> (3 * np.arange(16, dtype=np.uint64))[None, :]) & np.uint64(7)
        w0 = np.array([7, 0, 6, 5, 4, 3, 2, 1]) / 7.0
        apal = a0[:, None] * w0[None, :] + a1[:, None] * (1 - w0[None, :])
        av = np.take_along_axis(apal, ai.astype(np.int64), 1)
    else:
        av = np.full((nb, 16), 255.0)
    px = np.concatenate([rgb, av[:, :, None]], 2)
    bw, bh = max(1, w // 4), max(1, h // 4)
    img = px.reshape(bh, bw, 4, 4, 4).transpose(0, 2, 1, 3, 4).reshape(bh * 4, bw * 4, 4)
    return img[:h, :w].astype(np.uint8)
