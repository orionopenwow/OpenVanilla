"""Generate Open Vanilla's UI art kit: text-free, stretchable gold-and-stone pieces.

    py -3 tools/gen_ui_art.py            writes art/ui-kit/*.png (4x masters)
    py -3 tools/build_ui_kit.py          slices them into www/studio/kit/ (1x/2x WebP + kit.css)

Every piece is drawn in code from one palette and one light source (top-left), so the whole
kit can be restyled by changing PALETTE below and re-running both scripts. No piece carries
words: labels are live text laid over the art, so they translate and stay sharp at any size.
Pieces that stretch are drawn as 9-slices: their corners (the `slice` inset in build_ui_kit.py)
stay fixed and the edges and centre stretch.
"""
import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 4  # masters are drawn at 4x the 1x CSS size
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "art", "ui-kit")

PALETTE = {
    "outline": (12, 8, 3),
    "gold_hi": (255, 236, 168),
    "gold": (226, 172, 74),
    "gold_mid": (176, 122, 40),
    "gold_lo": (98, 62, 18),
    "bronze": (109, 84, 38),
    "ink": (7, 9, 13),
    # faces: (top, bottom)
    "face_gold": ((132, 82, 30), (66, 37, 11)),
    "face_stone": ((44, 50, 66), (16, 19, 27)),
    "face_blood": ((140, 34, 26), (58, 11, 8)),
    "face_panel": ((17, 21, 31), (9, 11, 17)),
    "green": (74, 222, 128),
    "amber": (236, 140, 24),
    "red": (248, 90, 90),
    "grey": (120, 128, 140),
}

rng = np.random.default_rng(1559)  # fixed seed: the same art every run


# ── primitives ────────────────────────────────────────────────────────────────────────────
def canvas(w, h):
    return Image.new("RGBA", (w * S, h * S), (0, 0, 0, 0))


def rr_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def vgrad(size, top, bottom, stops=None):
    """Vertical gradient. stops: list of (t, rgb) overriding top/bottom."""
    w, h = size
    stops = stops or [(0.0, top), (1.0, bottom)]
    t = np.linspace(0, 1, h)[:, None]
    out = np.zeros((h, 1, 3))
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        sel = (t >= t0) & (t <= t1)
        k = np.where(sel, (t - t0) / max(t1 - t0, 1e-6), 0)
        for i in range(3):
            out[:, :, i] = np.where(sel, c0[i] + (c1[i] - c0[i]) * k, out[:, :, i])
    arr = np.repeat(out, w, axis=1).astype(np.uint8)
    return Image.fromarray(arr, "RGB").convert("RGBA")


def noise(size, amount=10, blur=0.6):
    w, h = size
    n = rng.normal(0, amount, (h, w)).clip(-40, 40)
    img = Image.fromarray((128 + n).astype(np.uint8), "L")
    return img.filter(ImageFilter.GaussianBlur(blur * S)) if blur else img


def apply_noise(img, amount=8, blur=0.4):
    """Overlay-style grain, keeping alpha."""
    n = np.asarray(noise(img.size, amount, blur), dtype=np.int16) - 128
    a = np.asarray(img, dtype=np.int16)
    a[:, :, :3] = (a[:, :, :3] + n[:, :, None]).clip(0, 255)
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def paste_masked(base, layer, mask):
    base.alpha_composite(Image.composite(layer, Image.new("RGBA", layer.size, (0, 0, 0, 0)), mask))


def gold_band(size):
    return vgrad(size, None, None, [(0.0, PALETTE["gold_hi"]), (0.18, PALETTE["gold"]), (0.55, PALETTE["gold_mid"]),
                                   (0.85, PALETTE["gold_lo"]), (1.0, PALETTE["gold_mid"])])


def tint(rgb, k):
    return tuple(int(max(0, min(255, c * k))) for c in rgb)


def desaturate(img, k=0.75, dim=0.7):
    a = np.asarray(img, dtype=np.float32)
    grey = a[:, :, :3].mean(axis=2, keepdims=True)
    a[:, :, :3] = (a[:, :, :3] * (1 - k) + grey * k) * dim
    return Image.fromarray(a.clip(0, 255).astype(np.uint8), "RGBA")


def inner_shadow(size, mask, depth=3, strength=150, top_only=False):
    """A dark shadow inside `mask`, falling from its top (and sides unless top_only)."""
    w, h = size
    sh = Image.new("L", size, 0)
    inv = ImageChops.invert(mask)
    off = inv.transform(size, Image.AFFINE, (1, 0, 0, 0, 1, -depth * S if top_only else -depth * S // 2))
    sh = off.filter(ImageFilter.GaussianBlur(depth * S * 0.8))
    sh = ImageChops.multiply(sh, mask)
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    layer.putalpha(sh.point(lambda v: min(255, v * strength // 255)))
    return layer


def sheen(size, mask, top_frac=0.48, alpha=70):
    w, h = size
    g = np.zeros((h, w), dtype=np.float32)
    ys = np.arange(h)[:, None]
    g[:] = np.clip(1 - ys / (h * top_frac), 0, 1) ** 1.6 * alpha
    layer = Image.new("RGBA", size, (255, 248, 225, 0))
    layer.putalpha(ImageChops.multiply(Image.fromarray(g.astype(np.uint8), "L"), mask))
    return layer


def stud(draw_img, cx, cy, r):
    """A small gold rivet at (cx, cy) in master pixels."""
    d = ImageDraw.Draw(draw_img)
    d.ellipse((cx - r - S, cy - r - S, cx + r + S, cy + r + S), fill=PALETTE["outline"] + (255,))
    disc = Image.new("RGBA", (2 * r, 2 * r), (0, 0, 0, 0))
    m = Image.new("L", disc.size, 0)
    ImageDraw.Draw(m).ellipse((0, 0, 2 * r - 1, 2 * r - 1), fill=255)
    g = gold_band(disc.size)
    disc = Image.composite(g, disc, m)
    hl = Image.new("L", disc.size, 0)
    ImageDraw.Draw(hl).ellipse((r * 0.35, r * 0.25, r * 0.95, r * 0.8), fill=170)
    hl = hl.filter(ImageFilter.GaussianBlur(r * 0.2))
    white = Image.new("RGBA", disc.size, (255, 250, 230, 255))
    white.putalpha(ImageChops.multiply(hl, m))
    disc.alpha_composite(white)
    draw_img.alpha_composite(disc, (int(cx - r), int(cy - r)))


def diamond(img, cx, cy, r, fill_rgb=None):
    d = ImageDraw.Draw(img)
    pts = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    o = r + 1.5 * S
    d.polygon([(cx, cy - o), (cx + o, cy), (cx, cy + o), (cx - o, cy)], fill=PALETTE["outline"] + (255,))
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    g = gold_band(img.size) if fill_rgb is None else vgrad(img.size, tint(fill_rgb, 1.25), tint(fill_rgb, 0.55))
    paste_masked(img, g, m)
    hl = [(cx, cy - r * 0.7), (cx + r * 0.35, cy - r * 0.3), (cx, cy), (cx - r * 0.35, cy - r * 0.3)]
    ImageDraw.Draw(img).polygon(hl, fill=(255, 250, 225, 110))


# ── pieces ────────────────────────────────────────────────────────────────────────────────
def plate(w, h, face, state="normal", radius=6, open_bottom=False, studs=True):
    """Bevelled button plate: dark outline, gold band, dark keyline, gradient face."""
    img = canvas(w, h)
    W, H = img.size
    k = {"normal": 1.0, "hover": 1.22, "pressed": 0.78, "disabled": 1.0}[state]
    ext = 3 * radius * S if open_bottom else 0  # push the bottom edge off-canvas for tabs
    r = radius * S
    # outline
    m0 = rr_mask((W, H + ext), (0, 0, W - 1, H + ext - 1), r)
    m0 = m0.crop((0, 0, W, H))
    paste_masked(img, Image.new("RGBA", (W, H), PALETTE["outline"] + (255,)), m0)
    # gold band
    m1 = rr_mask((W, H + ext), (S, S, W - 1 - S, H + ext - 1 - S), r - S).crop((0, 0, W, H))
    band = gold_band((W, H))
    if state == "hover":
        band = Image.blend(band, Image.new("RGBA", (W, H), PALETTE["gold_hi"] + (255,)), 0.25)
    if state == "pressed":
        band = Image.blend(band, Image.new("RGBA", (W, H), PALETTE["gold_lo"] + (255,)), 0.3)
    paste_masked(img, band, m1)
    # keyline
    m2 = rr_mask((W, H + ext), (3 * S, 3 * S, W - 1 - 3 * S, H + ext - 1 - 3 * S), r - 3 * S).crop((0, 0, W, H))
    paste_masked(img, Image.new("RGBA", (W, H), (30, 19, 7, 255)), m2)
    # face
    m3 = rr_mask((W, H + ext), (4 * S, 4 * S, W - 1 - 4 * S, H + ext - 1 - 4 * S), max(r - 4 * S, S)).crop((0, 0, W, H))
    top, bottom = face
    if state == "pressed":
        top, bottom = bottom, top
    f = vgrad((W, H), tint(top, k), tint(bottom, k))
    f = apply_noise(f, 7, 0.5)
    paste_masked(img, f, m3)
    if state == "pressed":
        img.alpha_composite(inner_shadow((W, H), m3, depth=3, strength=200, top_only=True))
    else:
        img.alpha_composite(sheen((W, H), m3, 0.5, 64 if state != "hover" else 90))
        img.alpha_composite(inner_shadow((W, H), m3, depth=2, strength=90))
    if studs:
        rs = int(1.4 * S)
        for cx in (int(7.5 * S), W - int(7.5 * S)):
            for cy in ((int(7.5 * S), H - int(7.5 * S)) if not open_bottom else (int(7.5 * S),)):
                stud(img, cx, cy, rs)
    if state == "disabled":
        img = desaturate(img)
    return img


def frame(w=128, h=128, face=None, selected=False, ornate=True):
    """Window frame: outline, gold band, gap, fine gold line, dark stone face, corner jewels."""
    img = canvas(w, h)
    W, H = img.size
    r = 8 * S
    paste_masked(img, Image.new("RGBA", (W, H), PALETTE["outline"] + (255,)), rr_mask((W, H), (0, 0, W - 1, H - 1), r))
    paste_masked(img, gold_band((W, H)) if ornate or selected else vgrad((W, H), PALETTE["bronze"], tint(PALETTE["bronze"], 0.6)),
                 rr_mask((W, H), (S, S, W - 1 - S, H - 1 - S), r - S))
    inset = 3 * S if ornate else 2 * S
    paste_masked(img, Image.new("RGBA", (W, H), (10, 8, 5, 255)), rr_mask((W, H), (inset, inset, W - 1 - inset, H - 1 - inset), r - inset))
    if ornate:
        fine = 5 * S
        paste_masked(img, vgrad((W, H), tint(PALETTE["gold_mid"], 0.9), tint(PALETTE["gold_lo"], 0.9)),
                     rr_mask((W, H), (fine, fine, W - 1 - fine, H - 1 - fine), r - fine))
        inner = 6 * S
    else:
        inner = inset + S
    top, bottom = face or PALETTE["face_panel"]
    f = vgrad((W, H), top, bottom)
    f = apply_noise(f, 9, 1.2)
    fm = rr_mask((W, H), (inner, inner, W - 1 - inner, H - 1 - inner), max(r - inner, 2 * S))
    paste_masked(img, f, fm)
    img.alpha_composite(inner_shadow((W, H), fm, depth=5, strength=170))
    if selected:
        glow = ImageChops.subtract(fm, fm.filter(ImageFilter.MinFilter(9)))
        glow = glow.filter(ImageFilter.GaussianBlur(3 * S))
        g = Image.new("RGBA", (W, H), PALETTE["gold"] + (0,))
        g.putalpha(ImageChops.multiply(glow.point(lambda v: min(255, v * 2)), fm))
        img.alpha_composite(g)
    if ornate:
        c = int(6 * S)
        for cx, cy in ((c, c), (W - c, c), (c, H - c), (W - c, H - c)):
            diamond(img, cx, cy, int(4.2 * S))
    return img


def field(w=64, h=36, state="normal"):
    img = canvas(w, h)
    W, H = img.size
    r = 4 * S
    edge = {"normal": PALETTE["bronze"], "focus": PALETTE["gold"], "error": PALETTE["red"]}[state]
    paste_masked(img, Image.new("RGBA", (W, H), PALETTE["outline"] + (255,)), rr_mask((W, H), (0, 0, W - 1, H - 1), r))
    paste_masked(img, vgrad((W, H), tint(edge, 0.7), tint(edge, 1.15)), rr_mask((W, H), (S, S, W - 1 - S, H - 1 - S), r - S))
    fm = rr_mask((W, H), (2 * S, 2 * S, W - 1 - 2 * S, H - 1 - 2 * S), r - 2 * S)
    paste_masked(img, apply_noise(vgrad((W, H), (5, 7, 11), (12, 15, 22)), 5, 0.6), fm)
    img.alpha_composite(inner_shadow((W, H), fm, depth=3, strength=210, top_only=True))
    return img


def plaque(w=192, h=48):
    """Header plaque with cut corners."""
    img = canvas(w, h)
    W, H = img.size
    c = 12 * S

    def poly(i):
        return [(c + i * 0.4, i), (W - c - i * 0.4, i), (W - i, c * 0.0 + H / 2), (W - c - i * 0.4, H - i), (c + i * 0.4, H - i), (i, H / 2)]

    d = ImageDraw.Draw(img)
    d.polygon(poly(0), fill=PALETTE["outline"] + (255,))
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).polygon(poly(S * 1.2), fill=255)
    paste_masked(img, gold_band((W, H)), m)
    m2 = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m2).polygon(poly(S * 3.2), fill=255)
    paste_masked(img, Image.new("RGBA", (W, H), (26, 17, 6, 255)), m2)
    m3 = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m3).polygon(poly(S * 4.2), fill=255)
    paste_masked(img, apply_noise(vgrad((W, H), (40, 30, 18), (14, 11, 8)), 8, 0.8), m3)
    img.alpha_composite(sheen((W, H), m3, 0.5, 40))
    diamond(img, int(4.5 * S + S), H // 2, int(2.6 * S))
    diamond(img, W - int(4.5 * S + S), H // 2, int(2.6 * S))
    return img


def gem(color, size=20):
    img = canvas(size, size)
    W, H = img.size
    d = ImageDraw.Draw(img)
    d.ellipse((0, 0, W - 1, H - 1), fill=PALETTE["outline"] + (255,))
    bez = Image.new("L", (W, H), 0)
    ImageDraw.Draw(bez).ellipse((S, S, W - 1 - S, H - 1 - S), fill=255)
    paste_masked(img, gold_band((W, H)), bez)
    core = Image.new("L", (W, H), 0)
    ImageDraw.Draw(core).ellipse((3.2 * S, 3.2 * S, W - 1 - 3.2 * S, H - 1 - 3.2 * S), fill=255)
    # radial colour: bright centre, deep rim
    yy, xx = np.mgrid[0:H, 0:W]
    cx, cy = W * 0.45, H * 0.42
    dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (W * 0.42)
    dist = dist.clip(0, 1)[:, :, None]
    hi = np.array(tint(color, 1.35), dtype=np.float32)
    lo = np.array(tint(color, 0.35), dtype=np.float32)
    col = (hi * (1 - dist) + lo * dist).clip(0, 255).astype(np.uint8)
    layer = Image.fromarray(np.dstack([col, np.full((H, W, 1), 255, np.uint8)]), "RGBA")
    paste_masked(img, layer, core)
    spec = Image.new("L", (W, H), 0)
    ImageDraw.Draw(spec).ellipse((W * 0.3, H * 0.22, W * 0.55, H * 0.42), fill=220)
    spec = spec.filter(ImageFilter.GaussianBlur(0.8 * S))
    white = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    white.putalpha(spec)
    img.alpha_composite(white)
    return img


def rail(w=48, h=24, on=False):
    img = canvas(w, h)
    W, H = img.size
    r = H // 2
    paste_masked(img, Image.new("RGBA", (W, H), PALETTE["outline"] + (255,)), rr_mask((W, H), (0, 0, W - 1, H - 1), r))
    paste_masked(img, vgrad((W, H), tint(PALETTE["bronze"], 0.7), PALETTE["gold_mid"]), rr_mask((W, H), (S, S, W - 1 - S, H - 1 - S), r - S))
    fm = rr_mask((W, H), (2.5 * S, 2.5 * S, W - 1 - 2.5 * S, H - 1 - 2.5 * S), r - 2.5 * S)
    face = ((20, 70, 40), (8, 34, 18)) if on else ((10, 12, 18), (20, 23, 31))
    paste_masked(img, apply_noise(vgrad((W, H), *face), 5, 0.5), fm)
    img.alpha_composite(inner_shadow((W, H), fm, depth=3, strength=220, top_only=True))
    if on:
        glow = Image.new("RGBA", (W, H), PALETTE["green"] + (0,))
        g = fm.filter(ImageFilter.MinFilter(13)).filter(ImageFilter.GaussianBlur(4 * S))
        glow.putalpha(g.point(lambda v: v * 70 // 255))
        img.alpha_composite(glow)
    return img


def knob(size=20):
    img = canvas(size, size)
    W, H = img.size
    d = ImageDraw.Draw(img)
    d.ellipse((0, 0, W - 1, H - 1), fill=PALETTE["outline"] + (255,))
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).ellipse((S, S, W - 1 - S, H - 1 - S), fill=255)
    paste_masked(img, gold_band((W, H)), m)
    ring = Image.new("L", (W, H), 0)
    ImageDraw.Draw(ring).ellipse((4.5 * S, 4.5 * S, W - 1 - 4.5 * S, H - 1 - 4.5 * S), outline=255, width=S)
    paste_masked(img, Image.new("RGBA", (W, H), PALETTE["gold_lo"] + (255,)), ring)
    img.alpha_composite(sheen((W, H), m, 0.55, 90))
    return img


def bar(w=64, h=12, fill=False):
    img = canvas(w, h)
    W, H = img.size
    r = H // 2
    paste_masked(img, Image.new("RGBA", (W, H), PALETTE["outline"] + (255,)), rr_mask((W, H), (0, 0, W - 1, H - 1), r))
    if fill:
        m = rr_mask((W, H), (S, S, W - 1 - S, H - 1 - S), r - S)
        paste_masked(img, apply_noise(gold_band((W, H)), 6, 0.4), m)
        img.alpha_composite(sheen((W, H), m, 0.5, 80))
    else:
        paste_masked(img, Image.new("RGBA", (W, H), PALETTE["bronze"] + (255,)), rr_mask((W, H), (S, S, W - 1 - S, H - 1 - S), r - S))
        fm = rr_mask((W, H), (2 * S, 2 * S, W - 1 - 2 * S, H - 1 - 2 * S), r - 2 * S)
        paste_masked(img, Image.new("RGBA", (W, H), (6, 8, 12, 255)), fm)
        img.alpha_composite(inner_shadow((W, H), fm, depth=2, strength=220, top_only=True))
    return img


def checkbox(on=False, size=20):
    img = canvas(size, size)
    W, H = img.size
    r = 3 * S
    paste_masked(img, Image.new("RGBA", (W, H), PALETTE["outline"] + (255,)), rr_mask((W, H), (0, 0, W - 1, H - 1), r))
    paste_masked(img, gold_band((W, H)), rr_mask((W, H), (S, S, W - 1 - S, H - 1 - S), r - S))
    fm = rr_mask((W, H), (2.5 * S, 2.5 * S, W - 1 - 2.5 * S, H - 1 - 2.5 * S), r - 2 * S)
    paste_masked(img, vgrad((W, H), (8, 10, 15), (18, 22, 30)), fm)
    img.alpha_composite(inner_shadow((W, H), fm, depth=2, strength=200, top_only=True))
    if on:
        d = ImageDraw.Draw(img)
        pts = [(W * 0.25, H * 0.52), (W * 0.43, H * 0.70), (W * 0.76, H * 0.30)]
        d.line(pts, fill=PALETTE["outline"] + (255,), width=int(3.6 * S), joint="curve")
        d.line(pts, fill=PALETTE["gold_hi"] + (255,), width=int(2.2 * S), joint="curve")
    return img


def divider(w=320, h=16):
    img = canvas(w, h)
    W, H = img.size
    cy = H // 2
    xs = np.arange(W)
    fade = np.clip(1 - np.abs(xs - W / 2) / (W / 2), 0, 1) ** 0.8
    line = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    a = np.zeros((H, W), dtype=np.uint8)
    a[cy - S: cy + S, :] = (fade * 230).astype(np.uint8)
    col = Image.new("RGBA", (W, H), PALETTE["gold_mid"] + (255,))
    col.putalpha(Image.fromarray(a, "L"))
    line.alpha_composite(col)
    sh = np.zeros((H, W), dtype=np.uint8)
    sh[cy + S: cy + 2 * S, :] = (fade * 200).astype(np.uint8)
    dark = Image.new("RGBA", (W, H), PALETTE["outline"] + (255,))
    dark.putalpha(Image.fromarray(sh, "L"))
    line.alpha_composite(dark)
    img.alpha_composite(line)
    diamond(img, W // 2, cy, int(5 * S))
    for off in (16 * S, -16 * S):
        diamond(img, W // 2 + off, cy, int(2.2 * S))
    return img


def stone_tile(size=256):
    """Seamless dark stone texture for page backgrounds (1x, not upscaled)."""
    n = size
    base = rng.normal(0, 1, (n, n))
    # tileable low-frequency blotches: sum of wrapped sinusoids
    yy, xx = np.mgrid[0:n, 0:n] / n
    low = np.zeros((n, n))
    for _ in range(18):
        fx, fy = rng.integers(1, 5, 2)
        ph = rng.uniform(0, 2 * math.pi, 2)
        low += np.sin(2 * math.pi * fx * xx + ph[0]) * np.sin(2 * math.pi * fy * yy + ph[1]) / (fx + fy)
    low = (low - low.min()) / (low.max() - low.min())
    # tileable blur of fine grain: average with wrapped shifts
    fine = sum(np.roll(np.roll(base, dx, 0), dy, 1) for dx in (-1, 0, 1) for dy in (-1, 0, 1)) / 9
    v = 14 + low * 6 + fine * 1.8
    r = (v * 0.92).clip(0, 255)
    g = (v * 0.98).clip(0, 255)
    b = (v * 1.22).clip(0, 255)
    return Image.fromarray(np.dstack([r, g, b, np.full((n, n), 255)]).astype(np.uint8), "RGBA")


# ── write ─────────────────────────────────────────────────────────────────────────────────
def main():
    os.makedirs(OUT, exist_ok=True)
    pieces = {}
    for name, face in (("gold", PALETTE["face_gold"]), ("stone", PALETTE["face_stone"]), ("blood", PALETTE["face_blood"])):
        for st in ("normal", "hover", "pressed", "disabled"):
            pieces[f"plate-{name}-{st}"] = plate(96, 40, face, st)
    for st in ("normal", "hover"):
        pieces[f"tab-active-{st}"] = plate(96, 40, PALETTE["face_gold"], st, open_bottom=True, studs=False)
        pieces[f"tab-inactive-{st}"] = plate(96, 40, PALETTE["face_stone"], st, open_bottom=True, studs=False)
    pieces["frame-window"] = frame(128, 128)
    pieces["card-normal"] = frame(96, 96, ornate=False)
    pieces["card-selected"] = frame(96, 96, ornate=False, selected=True)
    for st in ("normal", "focus", "error"):
        pieces[f"field-{st}"] = field(64, 36, st)
    pieces["plaque"] = plaque(192, 48)
    for c in ("green", "amber", "red", "grey"):
        pieces[f"gem-{c}"] = gem(PALETTE[c])
    pieces["toggle-off"] = rail(48, 24, False)
    pieces["toggle-on"] = rail(48, 24, True)
    pieces["knob"] = knob(20)
    pieces["bar-rail"] = bar(64, 12, False)
    pieces["bar-fill"] = bar(64, 12, True)
    pieces["check-off"] = checkbox(False)
    pieces["check-on"] = checkbox(True)
    pieces["divider"] = divider(320, 16)
    for name, img in pieces.items():
        img.save(os.path.join(OUT, name + ".png"), optimize=True)
    stone_tile(256).save(os.path.join(OUT, "stone-tile.png"), optimize=True)
    print(f"wrote {len(pieces) + 1} masters to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
