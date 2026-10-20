#!/usr/bin/env python3
"""Image -> BLP2 DXT1 (no alpha, full mip chain): full-colour art (loading screens) at 4 bits per pixel.

    python3 tools/png_to_blp_dxt1.py in.png out.blp [WIDTHxHEIGHT]

Sides must be powers of two (the art is resized to the given size, default 1024x1024; the engine
stretches loading screens to 4:3). Our own art only - never convert Blizzard's files.
"""
import struct, sys
import numpy as np
from PIL import Image


def to565(c):
    c = np.clip(c, 0, 255)
    r = (c[..., 0] * 31 + 127) // 255
    g = (c[..., 1] * 63 + 127) // 255
    b = (c[..., 2] * 31 + 127) // 255
    return (r << 11) | (g << 5) | b


def from565(v):
    r = (v >> 11) & 31; g = (v >> 5) & 63; b = v & 31
    return np.stack([(r * 255 + 15) // 31, (g * 255 + 31) // 63, (b * 255 + 15) // 31], -1).astype(np.float64)


def dxt1(img):
    """img: HxWx3 uint8 (H, W multiples of 4, or 1/2) -> DXT1 bytes."""
    h, w, _ = img.shape
    ph, pw = max(4, h), max(4, w)
    a = np.zeros((ph, pw, 3), np.float64); a[:h, :w] = img
    if h < 4: a[h:, :w] = a[h - 1:h, :w]
    if w < 4: a[:, w:] = a[:, w - 1:w]
    blocks = a.reshape(ph // 4, 4, pw // 4, 4, 3).transpose(0, 2, 1, 3, 4).reshape(-1, 16, 3)
    # endpoints: the extremes along the block's principal axis
    mean = blocks.mean(1, keepdims=True); c = blocks - mean
    cov = np.einsum('nki,nkj->nij', c, c)
    _, vecs = np.linalg.eigh(cov); axis = vecs[:, :, -1]
    proj = np.einsum('nki,ni->nk', c, axis)
    lo = mean[:, 0] + axis * proj.min(1)[:, None]; hi = mean[:, 0] + axis * proj.max(1)[:, None]
    e0 = to565(np.rint(hi).astype(np.int64)); e1 = to565(np.rint(lo).astype(np.int64))
    swap = e0 < e1; e0, e1 = np.where(swap, e1, e0), np.where(swap, e0, e1)
    same = e0 == e1
    e0 = np.where(same & (e0 < 0xFFFF), e0 + 1, e0)  # keep 4-colour mode (e0 > e1)
    e1 = np.where(same & (e0 == 0xFFFF) & (e1 == 0xFFFF), 0xFFFE, e1)
    c0 = from565(e0); c1 = from565(e1)
    pal = np.stack([c0, c1, (2 * c0 + c1) / 3, (c0 + 2 * c1) / 3], 1)  # n,4,3
    d = ((blocks[:, :, None, :] - pal[:, None, :, :]) ** 2).sum(-1)
    idx = d.argmin(-1).astype(np.uint32)
    bits = (idx << (2 * np.arange(16, dtype=np.uint32))).sum(1).astype(np.uint32)
    out = np.zeros(len(blocks), dtype=[('e0', '<u2'), ('e1', '<u2'), ('i', '<u4')])
    out['e0'] = e0; out['e1'] = e1; out['i'] = bits
    return out.tobytes()


def encode(im):
    im = im.convert("RGB")
    w, h = im.size
    if w & (w - 1) or h & (h - 1):
        raise SystemExit(f"{w}x{h}: BLP needs power-of-two sides")
    levels = []
    while True:
        levels.append(dxt1(np.asarray(im)))
        if im.width == 1 and im.height == 1 or len(levels) == 16:
            break
        im = im.resize((max(1, im.width // 2), max(1, im.height // 2)), Image.Resampling.LANCZOS)
    header = bytearray(b"BLP2")
    header += struct.pack("<I", 1)                     # type 1: not JPEG
    header += struct.pack("<BBBB", 2, 0, 0, 1)         # DXTC, no alpha bits, alpha type 0 (DXT1), mips
    header += struct.pack("<II", w, h)
    offsets, sizes, pos = [], [], 20 + 64 + 64 + 1024
    for l in levels:
        offsets.append(pos); sizes.append(len(l)); pos += len(l)
    offsets += [0] * (16 - len(offsets)); sizes += [0] * (16 - len(sizes))
    header += struct.pack("<16I", *offsets) + struct.pack("<16I", *sizes) + bytes(1024)
    return bytes(header) + b"".join(levels)


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    w, h = (int(x) for x in (sys.argv[3] if len(sys.argv) > 3 else "1024x1024").lower().split("x"))
    data = encode(Image.open(src).resize((w, h), Image.Resampling.LANCZOS))
    open(dst, "wb").write(data)
    print(f"{dst}: {w}x{h} DXT1, {len(data)} bytes")
