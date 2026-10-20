"""Shared helpers for Open Vanilla's in-game art scripts (tools/gen_*_art.py).

    from artkit import save, sheet, SLATE, GOLD, ...

One look for every Classic+ addon: dark slate panels, thin grey-blue edges, gold accents, soft
top-left light. Each script draws its pieces with PIL at 4x and calls save(name, img, size), which
downsamples and writes the two copies the client loads:

    Data/Interface/AddOns/WenillaCore/Media/<name>.tga   1.12 client (loose addon art)
    Data/Interface/ClassicPlus/<name>.blp                web client (streamed, in patch-Z)

Sizes must be powers of two (BLP). Then rebuild patch-Z with tools/sync_patchz.py.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "art"))
from blp import write_blp  # noqa: E402

TGA_DIR = os.path.join(ROOT, "Data", "Interface", "AddOns", "WenillaCore", "Media")
BLP_DIR = os.path.join(ROOT, "Data", "Interface", "ClassicPlus")
SS = 4  # draw at 4x, downsample on save

# -- palette (matches UI.lua's window kit) -------------------------------------------------
SLATE = (18, 19, 23)          # panel face
SLATE_HI = (34, 36, 42)       # raised face / title strip
SLATE_LO = (9, 10, 12)
EDGE = (92, 98, 112)          # thin border
EDGE_HI = (150, 156, 170)
GOLD = (255, 209, 0)
GOLD_HI = (255, 236, 168)
GOLD_MID = (196, 146, 52)
GOLD_LO = (98, 62, 18)
GREEN = (74, 222, 128)
RED = (232, 72, 64)
INK = (7, 9, 13)


def p2(n):
    return n > 0 and (n & (n - 1)) == 0


def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def rr_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def vgrad(size, stops):
    """stops: [(t, (r,g,b)), ...] top to bottom."""
    w, h = size
    t = np.linspace(0, 1, h)[:, None]
    out = np.zeros((h, 1, 3))
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        sel = (t >= t0) & (t <= t1)
        k = np.where(sel, (t - t0) / max(t1 - t0, 1e-6), 0)
        for i in range(3):
            out[:, :, i] = np.where(sel, c0[i] + (c1[i] - c0[i]) * k, out[:, :, i])
    arr = np.repeat(out, w, axis=1).astype(np.uint8)
    return Image.fromarray(arr, "RGB").convert("RGBA")


def fill(size, rgb, a=255):
    return Image.new("RGBA", size, tuple(rgb) + (a,))


def paste_masked(base, layer, mask):
    base.alpha_composite(Image.composite(layer, Image.new("RGBA", layer.size, (0, 0, 0, 0)), mask))


_rng = np.random.default_rng(4471)


def grain(img, amount=6, blur=0.5):
    """Fine noise on the colour channels, alpha untouched."""
    w, h = img.size
    n = _rng.normal(0, amount, (h, w)).clip(-30, 30)
    nimg = Image.fromarray((128 + n).astype(np.uint8), "L")
    if blur:
        nimg = nimg.filter(ImageFilter.GaussianBlur(blur * SS))
    a = np.asarray(img, dtype=np.int16)
    a[:, :, :3] = (a[:, :, :3] + (np.asarray(nimg, dtype=np.int16) - 128)[:, :, None]).clip(0, 255)
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def inner_shadow(size, mask, depth=3, strength=160):
    inv = ImageChops.invert(mask)
    off = inv.transform(size, Image.AFFINE, (1, 0, 0, 0, 1, -depth * SS))
    sh = off.filter(ImageFilter.GaussianBlur(depth * SS * 0.8))
    sh = ImageChops.multiply(sh, mask)
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    layer.putalpha(sh.point(lambda v: min(255, v * strength // 255)))
    return layer


def sheen(size, mask, top_frac=0.5, alpha=60, rgb=(255, 248, 225)):
    w, h = size
    ys = np.arange(h)[:, None]
    g = np.clip(1 - ys / (h * top_frac), 0, 1) ** 1.6 * alpha
    g = np.repeat(g, w, axis=1)
    layer = Image.new("RGBA", size, rgb + (0,))
    layer.putalpha(ImageChops.multiply(Image.fromarray(g.astype(np.uint8), "L"), mask))
    return layer


def gold_band(size):
    return vgrad(size, [(0.0, GOLD_HI), (0.2, (226, 172, 74)), (0.55, GOLD_MID), (0.85, GOLD_LO), (1.0, GOLD_MID)])


def drop_shadow(img, offset=(0, 2), blur=3, alpha=150):
    """img with a soft dark shadow underneath (same canvas size; leave margin when drawing)."""
    a = img.getchannel("A")
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    m = a.transform(img.size, Image.AFFINE, (1, 0, -offset[0] * SS, 0, 1, -offset[1] * SS))
    m = m.filter(ImageFilter.GaussianBlur(blur * SS)).point(lambda v: v * alpha // 255)
    sh.putalpha(m)
    sh.alpha_composite(img)
    return sh


def downsample(img, size):
    return img.resize(size, Image.LANCZOS)


def save(name, img, size=None):
    """Downsample a 4x master to `size` (w, h) and write the TGA + BLP pair."""
    if size is None:
        size = (img.width // SS, img.height // SS)
    w, h = size
    if not (p2(w) and p2(h)):
        raise ValueError(f"{name}: {w}x{h} is not a power of two")
    out = downsample(img, size) if img.size != tuple(size) else img
    os.makedirs(TGA_DIR, exist_ok=True)
    os.makedirs(BLP_DIR, exist_ok=True)
    out.save(os.path.join(TGA_DIR, name + ".tga"))
    write_blp(out, os.path.join(BLP_DIR, name + ".blp"))
    return out


def sheet(images, path, bg=(30, 31, 36, 255), zoom=2):
    """A contact sheet of (name, img) pairs for eyeballing the art."""
    pad = 12
    zs = [im.resize((im.width * zoom, im.height * zoom), Image.LANCZOS) for _, im in images]
    w = sum(z.width for z in zs) + pad * (len(zs) + 1)
    h = max(z.height for z in zs) + pad * 2
    c = Image.new("RGBA", (w, h), bg)
    x = pad
    for z in zs:
        c.alpha_composite(z, (x, pad))
        x += z.width + pad
    c.save(path)
    return c
