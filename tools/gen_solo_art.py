#!/usr/bin/env python3
"""Website art for the Play Solo page (www/solo.html) and the hero's "Play Solo" card.

    python tools/gen_solo_art.py [out_dir]

Writes into www/assets/solo/ (or out_dir):
    solo_hero.webp        1200x520  a lone adventurer at a campfire with two companions,
                                    under the Orion constellation
    step_download.webp     480x300  step cards: download, unzip, play
    step_unzip.webp
    step_play.webp
    solo_vs_realm.webp     960x360  your PC's campfire vs a whole realm's
    solo_card.webp         480x300  the small card next to Play in the site's hero
    solo_og.webp          1200x630  social preview (og:image / twitter:image)
    solo_og.jpg           1200x630  the same, as JPEG for crawlers that skip WebP

Procedural, painterly PIL art in the style of www/assets/orion (night sky,
violet nebula, gold rims, white four-point stars). Everything is drawn from shapes; no game art.
Deterministic: the same seeds draw the same pictures.
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "www", "assets", "solo")
S = 2  # supersampling
GOLD = (232, 188, 84)
GOLD_HI = (255, 230, 150)
GOLD_DK = (150, 108, 40)
VIOLET = (126, 58, 196)
FIRE = (255, 150, 64)
INK = (9, 8, 16)
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"


# -- small helpers ---------------------------------------------------------------------------
def glow(size, xy, r, color, alpha=255, blur=None):
    layer = Image.new("RGBA", size, color + (0,))
    m = Image.new("L", size, 0)
    x, y = xy
    ImageDraw.Draw(m).ellipse((x - r, y - r, x + r, y + r), fill=alpha)
    layer.putalpha(m.filter(ImageFilter.GaussianBlur(blur or r * 0.6)))
    return layer


def sparkle(d, x, y, r, col=(255, 255, 255, 255), waist=0.22):
    w = r * waist
    d.polygon([(x, y - r), (x + w, y - w), (x + r, y), (x + w, y + w), (x, y + r), (x - w, y + w),
               (x - r, y), (x - w, y - w)], fill=col)


def font(px):
    try:
        return ImageFont.truetype(FONT, px)
    except OSError:
        return ImageFont.load_default()


def sky(w, h, seed, nebula, horizon=0.72, stars=520, star_scale=1.0):
    """Night sky: deep navy at the top, a violet haze toward the horizon, nebulae and stars."""
    yy = np.linspace(0, 1, h)[:, None]
    xx = np.linspace(0, 1, w)[None, :]
    t = np.clip(yy / horizon, 0, 1)
    top, low = np.array([7, 7, 20], np.float32), np.array([34, 24, 66], np.float32)
    base = top + (low - top) * (t ** 1.6)[..., None]
    vign = 1 - 0.35 * np.clip(np.hypot(xx - 0.5, (yy - 0.45) * 1.2) * 1.4, 0, 1)
    img = Image.fromarray((base * vign[..., None]).clip(0, 255).astype(np.uint8), "RGB").convert("RGBA")
    for x, y, r, col, a in nebula:
        img.alpha_composite(glow((w, h), (x * w, y * h), r * w, col, a))
    rnd = random.Random(seed)
    st = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(st)
    for _ in range(stars):
        x, y = rnd.randrange(w), rnd.randrange(int(h * horizon))
        b = rnd.choice([60, 100, 140, 190, 255])
        r = rnd.choice([1, 1, 1.4, 1.8, 2.4]) * S * (1.3 if b == 255 else 1) * star_scale
        d.ellipse((x - r, y - r, x + r, y + r), fill=(235, 236, 255, b))
    img.alpha_composite(st.filter(ImageFilter.GaussianBlur(S * 0.4)))
    return img


ORION = [(0.0, 0.0), (0.58, -0.10), (0.92, 0.42), (0.34, 0.72), (0.45, 0.76), (0.56, 0.80),
         (0.18, 1.32), (1.08, 1.36)]
ORION_EDGES = [(0, 1), (1, 2), (0, 3), (2, 5), (3, 4), (4, 5), (3, 6), (5, 7)]


def constellation(img, ox, oy, scale, alpha=90):
    """Orion: thin gold-white lines, white stars, the three belt stars as sparkles."""
    pts = [(ox + x * scale, oy + y * scale) for x, y in ORION]
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for a, b in ORION_EDGES:
        d.line([pts[a], pts[b]], fill=(230, 214, 170, alpha), width=max(1, int(1.2 * S)))
    img.alpha_composite(lay)
    d = ImageDraw.Draw(img)
    for i, (x, y) in enumerate(pts):
        if i in (3, 4, 5):
            img.alpha_composite(glow(img.size, (x, y), 9 * S, (200, 190, 255), 150))
            d = ImageDraw.Draw(img)
            sparkle(d, x, y, 7 * S)
        else:
            col = (255, 196, 140, 240) if i == 0 else (236, 240, 255, 235)
            r = 2.6 * S if i in (0, 7) else 2.0 * S
            d.ellipse((x - r, y - r, x + r, y + r), fill=col)


def ridge(w, h, base, amp, seed, waves=5):
    rnd = random.Random(seed)
    ph = [(rnd.uniform(0.6, 3.2), rnd.uniform(0, 6.3), rnd.uniform(0.3, 1.0)) for _ in range(waves)]
    pts = []
    for i in range(0, w + 8, 8):
        x = i / w
        y = sum(a * math.sin(x * f * math.pi * 2 + p) for f, p, a in ph) / sum(a for _, _, a in ph)
        pts.append((i, base + y * amp))
    return pts + [(w, h), (0, h)]


def pine(d, x, y, hgt, col):
    for k in range(4):
        top = y - hgt * (1 - k * 0.2)
        half = hgt * (0.16 + k * 0.07)
        d.polygon([(x, top), (x + half, top + hgt * 0.34), (x - half, top + hgt * 0.34)], fill=col)
    d.rectangle((x - hgt * 0.03, y - hgt * 0.08, x + hgt * 0.03, y), fill=col)


def landscape(img, seed, horizon, fire_xy=None, trees=True):
    w, h = img.size
    far = ridge(w, h, horizon * h - 0.05 * h, 0.05 * h, seed, 4)
    near = ridge(w, h, horizon * h + 0.02 * h, 0.035 * h, seed + 1, 5)
    lay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(lay).polygon(far, fill=(22, 18, 46, 255))
    img.alpha_composite(lay)
    # a soft mist on the far hills
    img.alpha_composite(glow((w, h), (w * 0.5, horizon * h - 0.02 * h), w * 0.6, (90, 70, 160), 50, h * 0.08))
    lay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    d.polygon(near, fill=(13, 11, 26, 255))
    if trees:
        rnd = random.Random(seed + 7)
        for _ in range(int(w / (26 * S))):
            x = rnd.uniform(0, w)
            if fire_xy and abs(x - fire_xy[0]) < w * 0.2:
                continue
            i = min(len(near) - 3, int(x / 8))
            pine(d, x, near[i][1] + 3 * S, rnd.uniform(0.07, 0.15) * h, (11, 9, 22, 255))
    img.alpha_composite(lay)
    # foreground ground
    lay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(lay).rectangle((0, horizon * h + 0.05 * h, w, h), fill=(8, 7, 15, 255))
    img.alpha_composite(lay.filter(ImageFilter.GaussianBlur(0.02 * h)))


# -- the campfire and the three silhouettes -------------------------------------------------
def campfire(img, x, y, k, seed=3, light=True, body=True):
    """Logs, layered flames and rising embers. k = scale (px per unit). `light` draws the glow
    and the lit ground (put it under the figures), `body` the stones, logs, flames and embers."""
    w, h = img.size
    if light:
        campfire_light(img, x, y, k)
    if body:
        campfire_body(img, x, y, k, seed)


def campfire_light(img, x, y, k):
    w, h = img.size
    img.alpha_composite(glow((w, h), (x, y - 18 * k), 210 * k, FIRE, 120, 120 * k))
    img.alpha_composite(glow((w, h), (x, y - 14 * k), 80 * k, (255, 196, 110), 170, 40 * k))
    # firelight pooled on the ground
    pool = Image.new("L", (w, h), 0)
    ImageDraw.Draw(pool).ellipse((x - 190 * k, y - 30 * k, x + 190 * k, y + 40 * k), fill=150)
    lay = Image.new("RGBA", (w, h), (255, 130, 60, 0))
    lay.putalpha(pool.filter(ImageFilter.GaussianBlur(40 * k)))
    img.alpha_composite(lay)


def campfire_body(img, x, y, k, seed):
    w, h = img.size
    d = ImageDraw.Draw(img)
    # stones
    for a in range(9):
        ang = math.pi * (0.05 + a / 8 * 0.9)
        sx, sy = x + math.cos(ang) * 34 * k, y + 4 * k - math.sin(ang) * -6 * k
        d.ellipse((sx - 7 * k, sy - 5 * k, sx + 7 * k, sy + 5 * k), fill=(40, 30, 34, 255))
        d.arc((sx - 7 * k, sy - 5 * k, sx + 7 * k, sy + 5 * k), 200, 330, fill=(190, 110, 70, 255), width=max(1, int(1.5 * k)))
    # logs
    for (x0, y0, x1, y1) in ((-26, 4, 22, -6), (24, 4, -20, -7), (-8, 6, 10, -12)):
        d.line([(x + x0 * k, y + y0 * k), (x + x1 * k, y + y1 * k)], fill=(46, 28, 20, 255), width=int(8 * k))
        d.line([(x + x0 * k, y + (y0 - 3) * k), (x + x1 * k, y + (y1 - 3) * k)], fill=(150, 80, 40, 255), width=max(1, int(2 * k)))
    # flames: outer red-orange, mid orange, inner yellow, core white
    rnd = random.Random(seed)
    for col, scale, n in (((232, 84, 40), 1.0, 7), ((255, 150, 50), 0.78, 6), ((255, 214, 100), 0.52, 5), ((255, 246, 220), 0.28, 3)):
        lay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        dl = ImageDraw.Draw(lay)
        for i in range(n):
            off = (i - (n - 1) / 2) * 7 * k * scale
            fh = (52 + rnd.uniform(-10, 14)) * k * scale * (1.15 - abs(i - (n - 1) / 2) / n)
            fw = 11 * k * scale
            sway = rnd.uniform(-8, 8) * k * scale
            cx0, cy0 = x + off, y - 2 * k
            pts = [(cx0 - fw * math.cos(j / 20 * math.pi), cy0 + fw * 0.6 * math.sin(j / 20 * math.pi)) for j in range(21)]
            # curved sides up to a swaying tip
            right = [(cx0 + fw * (1 - t) ** 1.4 + sway * t * t, cy0 - (fh - fw * 0.2) * t) for t in (i / 12 for i in range(1, 13))]
            left = [(cx0 - fw * (1 - t) ** 1.4 + sway * t * t, cy0 - (fh - fw * 0.2) * t) for t in (i / 12 for i in range(12, 0, -1))]
            dl.polygon(pts + right + left, fill=col + (235,))
        img.alpha_composite(lay.filter(ImageFilter.GaussianBlur(2.2 * k)))
    # embers rising
    d = ImageDraw.Draw(img)
    for _ in range(30):
        ex = x + rnd.gauss(0, 22) * k + rnd.uniform(0, 1) ** 2 * 30 * k
        ey = y - rnd.uniform(46, 220) * k
        r = rnd.choice([0.7, 0.9, 1.1, 1.5]) * k
        a = int(255 * max(0.25, 1 - (y - ey) / (260 * k)))
        d.ellipse((ex - r, ey - r, ex + r, ey + r), fill=(255, rnd.choice([170, 200, 230]), 120, a))


def rim_light(img, mask, toward, depth, color=(255, 160, 80), alpha=235):
    """Paint the thin edge of `mask` that faces the fire with warm light."""
    dx, dy = toward
    n = math.hypot(dx, dy) or 1
    dx, dy = dx / n * depth, dy / n * depth
    shifted = mask.transform(mask.size, Image.AFFINE, (1, 0, dx, 0, 1, dy))
    rim = np.clip(np.asarray(mask, np.int16) - np.asarray(shifted, np.int16), 0, 255).astype(np.uint8)
    rim = Image.fromarray(rim, "L").filter(ImageFilter.GaussianBlur(max(1, depth * 0.25)))
    rim = Image.fromarray((np.asarray(rim, np.float32) * alpha / 255 * (np.asarray(mask, np.float32) / 255)).astype(np.uint8), "L")
    lay = Image.new("RGBA", img.size, color + (0,))
    lay.putalpha(rim)
    img.alpha_composite(lay)


def silhouette(img, draw_fn, fire_xy, anchor, depth):
    m = Image.new("L", img.size, 0)
    draw_fn(ImageDraw.Draw(m))
    m = m.filter(ImageFilter.GaussianBlur(0.6))
    lay = Image.new("RGBA", img.size, INK + (0,))
    lay.putalpha(m)
    img.alpha_composite(lay)
    rim_light(img, m, (fire_xy[0] - anchor[0], fire_xy[1] - anchor[1]), depth)
    return m


def _pen(x, gy, k, f):
    def P(px, py):
        return (x + px * k * f, gy - py * k)

    def E(d, px, py, rx, ry):
        cx, cy = P(px, py)
        d.ellipse((cx - rx * k, cy - ry * k, cx + rx * k, cy + ry * k), fill=255)

    def L(d, pts, wid):
        d.line([P(*q) for q in pts], fill=255, width=max(2, int(wid * k)), joint="curve")
        for q in (pts[0], pts[-1]):
            E(d, q[0], q[1], wid / 2, wid / 2)

    def G(d, pts):
        d.polygon([P(*q) for q in pts], fill=255)
    return P, E, L, G


def seated_adventurer(x, gy, k, face=1):
    """A hooded, cloaked adventurer on a log, one hand to the fire, a sword planted behind."""
    P, E, L, G = _pen(x, gy, k, face)

    def draw(d):
        # the log
        G(d, [(-46, 0), (-46, 13), (-40, 17), (26, 17), (32, 13), (32, 0)])
        # cloak over the back, sweeping to the ground
        G(d, [(-6, 74), (-16, 66), (-24, 46), (-34, 22), (-42, 6), (-30, 4), (-8, 14), (10, 16), (8, 50), (4, 70)])
        # thighs forward and shins down
        L(d, [(-2, 22), (26, 26)], 15)
        L(d, [(26, 26), (34, 3)], 11)
        G(d, [(28, 0), (44, 0), (42, 6), (30, 7)])  # boot
        # torso leaning to the fire
        G(d, [(-8, 18), (12, 20), (16, 46), (10, 66), (-6, 70), (-12, 52)])
        # arm reaching toward the flames
        L(d, [(10, 62), (24, 50), (40, 48)], 8)
        E(d, 43, 48, 4.5, 4)
        # hooded head
        E(d, 6, 80, 10, 11)
        G(d, [(-6, 92), (8, 93), (16, 84), (14, 72), (-10, 66), (-14, 80)])
        # sword planted in the ground behind the log
        L(d, [(-52, -2), (-50, 62)], 4)
        L(d, [(-58, 50), (-42, 50)], 4)
        E(d, -50, 68, 4, 4)
    return draw


def warrior(x, gy, k, face=1):
    """A companion in plate: cape, round shield toward the fire, an axe resting on the shoulder."""
    P, E, L, G = _pen(x, gy, k, face)

    def draw(d):
        G(d, [(-16, 108), (-26, 80), (-30, 40), (-27, 6), (-14, 12), (-10, 60)])  # cape
        L(d, [(-6, 58), (-8, 6)], 10)   # legs
        L(d, [(7, 58), (10, 6)], 10)
        G(d, [(-16, 0), (-1, 0), (-3, 8), (-14, 8)])
        G(d, [(5, 0), (20, 0), (18, 8), (7, 8)])
        G(d, [(-11, 54), (11, 54), (13, 70), (18, 92), (20, 106), (12, 112), (-12, 112), (-20, 106), (-18, 92), (-13, 70)])
        G(d, [(-14, 62), (14, 62), (17, 50), (-17, 50)])  # belt and tassets
        E(d, -18, 107, 9, 7)
        E(d, 18, 107, 9, 7)
        E(d, 0, 122, 8.5, 9.5)  # helm
        G(d, [(-8, 126), (-3, 136), (0, 129), (3, 136), (8, 126)])
        L(d, [(-17, 100), (-24, 82)], 7)  # back arm up to the axe
        L(d, [(-28, 74), (-38, 156)], 3.5)  # haft
        G(d, [(-38, 156), (-53, 166), (-57, 146), (-47, 142), (-36, 146)])  # blade
        L(d, [(17, 100), (22, 84)], 7)    # front arm
        G(d, [(22, 104), (34, 98), (37, 74), (31, 54), (22, 58), (18, 84)])  # shield, side-on
    return draw


def mage(x, gy, k, face=-1):
    """A companion in robes with a tall staff topped by a star."""
    P, E, L, G = _pen(x, gy, k, face)

    def draw(d):
        G(d, [(-28, 0), (26, 0), (18, 30), (14, 70), (17, 98), (8, 106), (-8, 106), (-17, 98), (-15, 70), (-20, 30)])
        E(d, -15, 98, 7, 6)
        E(d, 15, 98, 7, 6)
        E(d, 0, 114, 9.5, 10.5)
        G(d, [(-12, 112), (-10, 128), (4, 150), (6, 128), (12, 112), (0, 104)])  # pointed hood
        L(d, [(14, 96), (26, 80), (34, 82)], 7)  # arm to the staff
        L(d, [(34, -2), (34, 138)], 3.5)
    return draw


def party(img, fire_xy, k):
    """The three silhouettes around the fire, plus the mage's star light."""
    fx, fy = fire_xy
    gy = fy + 6 * k
    w_draw = warrior(fx - 158 * k, gy - 16 * k, k * 0.86, face=1)
    silhouette(img, w_draw, fire_xy, (fx - 158 * k, gy - 60 * k), 2.6 * k)
    a_draw = seated_adventurer(fx - 72 * k, gy + 8 * k, k, face=1)
    silhouette(img, a_draw, fire_xy, (fx - 72 * k, gy - 40 * k), 2.6 * k)
    m_draw = mage(fx + 108 * k, gy + 2 * k, k * 0.95, face=-1)
    silhouette(img, m_draw, fire_xy, (fx + 108 * k, gy - 60 * k), 2.6 * k)
    sx, sy = fx + 108 * k - 34 * k * 0.95, gy + 2 * k - 142 * k * 0.95
    img.alpha_composite(glow(img.size, (sx, sy), 30 * k, (180, 150, 255), 200, 16 * k))
    sparkle(ImageDraw.Draw(img), sx, sy, 9 * k)


def scene(w, h, seed=11, fire=(0.56, 0.86), k=1.35, orion=(0.70, 0.10, 0.20), horizon=0.70):
    W, H = w * S, h * S
    img = sky(W, H, seed, [(0.68, 0.28, 0.30, VIOLET, 150), (0.25, 0.34, 0.26, (50, 70, 190), 120),
                           (0.86, 0.50, 0.14, (255, 120, 140), 50)], horizon=horizon,
              stars=int(520 * min(1.0, w * h / (1200 * 520)) ** 0.7), star_scale=max(0.6, min(1.0, h / 520)))
    ox, oy, sc = orion
    constellation(img, ox * W, oy * H, sc * W * 0.55)
    fire_xy = (fire[0] * W, fire[1] * H)
    landscape(img, seed, horizon, fire_xy)
    kk = k * S * (h / 520)
    img.alpha_composite(glow(img.size, (fire_xy[0], fire_xy[1] - 40 * kk), 260 * kk, FIRE, 40, 160 * kk))
    campfire(img, fire_xy[0], fire_xy[1], kk, light=True, body=False)
    party(img, fire_xy, kk)
    campfire(img, fire_xy[0], fire_xy[1], kk, light=False, body=True)
    return img


# -- step cards ------------------------------------------------------------------------------
def card_base(w, h, seed, tint):
    W, H = w * S, h * S
    img = sky(W, H, seed, [(0.5, 0.45, 0.45, tint, 150), (0.15, 0.2, 0.3, (50, 70, 190), 90)], horizon=1.0, stars=180)
    img.alpha_composite(glow((W, H), (W * 0.5, H * 0.5), W * 0.28, (170, 120, 255), 90))
    return img


def medallion(img, cx, cy, r):
    """A gold-rimmed indigo disc, to hold an icon."""
    d = ImageDraw.Draw(img)
    img.alpha_composite(glow(img.size, (cx, cy + r * 0.12), r * 1.2, (0, 0, 0), 160, r * 0.25))
    d = ImageDraw.Draw(img)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=GOLD + (255,))
    d.arc((cx - r + 2 * S, cy - r + 2 * S, cx + r - 2 * S, cy + r - 2 * S), 150, 300, fill=GOLD_HI + (255,), width=int(3 * S))
    d.ellipse((cx - r * 0.86, cy - r * 0.86, cx + r * 0.86, cy + r * 0.86), fill=(43, 29, 7, 255))
    d.ellipse((cx - r * 0.82, cy - r * 0.82, cx + r * 0.82, cy + r * 0.82), fill=(30, 24, 84, 255))
    img.alpha_composite(glow(img.size, (cx - r * 0.2, cy - r * 0.25), r * 0.7, (90, 70, 190), 170, r * 0.4))


def number_badge(img, x, y, n):
    d = ImageDraw.Draw(img)
    r = 22 * S
    d.ellipse((x - r, y - r, x + r, y + r), fill=GOLD + (255,), outline=GOLD_HI + (255,), width=S)
    f = font(26 * S)
    d.text((x, y + S), str(n), font=f, fill=(27, 19, 5, 255), anchor="mm")


def icon_download(img, cx, cy, r):
    d = ImageDraw.Draw(img)
    wcol = (246, 240, 226, 255)
    d.rectangle((cx - r * 0.1, cy - r * 0.5, cx + r * 0.1, cy + r * 0.08), fill=wcol)
    d.polygon([(cx - r * 0.32, cy + 0.02 * r), (cx + r * 0.32, cy + 0.02 * r), (cx, cy + r * 0.36)], fill=wcol)
    d.line([(cx - r * 0.46, cy + r * 0.22), (cx - r * 0.46, cy + r * 0.48), (cx + r * 0.46, cy + r * 0.48), (cx + r * 0.46, cy + r * 0.22)],
           fill=GOLD_HI + (255,), width=int(r * 0.09), joint="curve")


def icon_unzip(img, cx, cy, r):
    d = ImageDraw.Draw(img)
    # a folder, its zipper half open, stars spilling out
    fx0, fy0, fx1, fy1 = cx - r * 0.5, cy - r * 0.3, cx + r * 0.5, cy + r * 0.42
    d.rounded_rectangle((fx0, fy0 - r * 0.1, fx0 + r * 0.38, fy0 + r * 0.1), radius=int(r * 0.05), fill=GOLD_DK + (255,))
    d.rounded_rectangle((fx0, fy0, fx1, fy1), radius=int(r * 0.07), fill=GOLD + (255,))
    d.rounded_rectangle((fx0 + r * 0.04, fy0 + r * 0.04, fx1 - r * 0.04, fy0 + r * 0.12), radius=int(r * 0.03), fill=GOLD_HI + (255,))
    # zipper teeth down the middle, opening at the top
    for i in range(7):
        ty = fy0 + r * 0.08 + i * r * 0.05
        gap = max(0, (3 - i)) * r * 0.035
        d.rectangle((cx - gap - r * 0.06, ty, cx - gap - r * 0.01, ty + r * 0.03), fill=(60, 40, 12, 255))
        d.rectangle((cx + gap + r * 0.01, ty + r * 0.02, cx + gap + r * 0.06, ty + r * 0.05), fill=(60, 40, 12, 255))
    d.rounded_rectangle((cx - r * 0.04, fy0 + r * 0.42, cx + r * 0.04, fy0 + r * 0.58), radius=int(r * 0.02), fill=(60, 40, 12, 255))
    for sx, sy, sr in ((-0.18, -0.52, 0.1), (0.06, -0.66, 0.13), (0.26, -0.48, 0.08)):
        img.alpha_composite(glow(img.size, (cx + sx * r, cy + sy * r), sr * r * 1.6, (200, 180, 255), 160))
        sparkle(ImageDraw.Draw(img), cx + sx * r, cy + sy * r, sr * r)


def icon_play(img, cx, cy, r):
    # a play triangle with a small campfire flame inside
    d = ImageDraw.Draw(img)
    tri = [(cx - r * 0.3, cy - r * 0.42), (cx + r * 0.46, cy), (cx - r * 0.3, cy + r * 0.42)]
    d.polygon(tri, fill=(246, 240, 226, 255))
    fx, fy = cx - r * 0.04, cy + r * 0.16
    for col, s in (((232, 84, 40), 1.0), ((255, 170, 60), 0.7), ((255, 230, 140), 0.42)):
        d.polygon([(fx - r * 0.12 * s, fy), (fx - r * 0.02, fy - r * 0.34 * s), (fx + r * 0.12 * s, fy)], fill=col + (255,))
        d.ellipse((fx - r * 0.12 * s, fy - r * 0.1 * s, fx + r * 0.12 * s, fy + r * 0.06 * s), fill=col + (255,))


def step_card(n, icon, seed, tint):
    img = card_base(480, 300, seed, tint)
    W, H = img.size
    medallion(img, W * 0.5, H * 0.52, 92 * S)
    icon(img, W * 0.5, H * 0.52, 92 * S)
    number_badge(img, 40 * S, 40 * S, n)
    return img


# -- solo vs realm ---------------------------------------------------------------------------
def tiny_camp(img, x, y, k):
    campfire(img, x, y, k, seed=int(x) % 97, body=False)
    party(img, (x, y), k)
    campfire(img, x, y, k, seed=int(x) % 97, light=False)


def solo_vs_realm():
    W, H = 960 * S, 360 * S
    img = sky(W, H, 31, [(0.25, 0.4, 0.25, VIOLET, 140), (0.75, 0.4, 0.28, (50, 80, 200), 140)], horizon=0.74, stars=320)
    landscape(img, 31, 0.74, None, trees=False)
    # left: one campfire inside a soft gold ring (your PC)
    lx, ly = W * 0.25, H * 0.72
    tiny_camp(img, lx, ly, 0.62 * S)
    d = ImageDraw.Draw(img)
    # right: a hilltop keep with many campfires around it (a whole realm)
    rx, ry = W * 0.75, H * 0.66
    keep = Image.new("L", img.size, 0)
    kd = ImageDraw.Draw(keep)
    kd.polygon([(rx - 120 * S, H * 0.78), (rx - 70 * S, ry - 4 * S), (rx + 70 * S, ry - 4 * S), (rx + 120 * S, H * 0.78)], fill=255)
    for tx, th in ((-46, 94), (0, 128), (46, 94)):
        kd.rectangle((rx + (tx - 14) * S, ry - th * S, rx + (tx + 14) * S, ry), fill=255)
        for b in range(3):
            kd.rectangle((rx + (tx - 14 + b * 11) * S, ry - (th + 8) * S, rx + (tx - 8 + b * 11) * S, ry - th * S), fill=255)
    lay = Image.new("RGBA", img.size, (14, 12, 28, 0))
    lay.putalpha(keep)
    img.alpha_composite(lay)
    d = ImageDraw.Draw(img)
    rnd = random.Random(5)
    for tx, th in ((-46, 94), (0, 128), (46, 94)):  # lit windows
        for _ in range(3):
            wx, wy = rx + (tx + rnd.uniform(-7, 7)) * S, ry - rnd.uniform(20, th - 16) * S
            d.rectangle((wx - 2 * S, wy - 4 * S, wx + 2 * S, wy + 4 * S), fill=(255, 200, 120, 255))
    # the realm's beacon of light up to the stars
    img.alpha_composite(glow(img.size, (rx, ry - 150 * S), 60 * S, (180, 150, 255), 120, 40 * S))
    for i in range(14):  # campfires of many players on the slopes
        a = i / 13
        x = rx + (a - 0.5) * 380 * S + rnd.uniform(-10, 10) * S
        y = H * 0.80 + rnd.uniform(-6, 18) * S
        img.alpha_composite(glow(img.size, (x, y), 18 * S, FIRE, 160, 10 * S))
        dd = ImageDraw.Draw(img)
        sparkle(dd, x, y - 3 * S, 4 * S, (255, 220, 150, 255), 0.35)
        for p in range(rnd.choice([2, 3, 4])):
            px = x + (p - 1.5) * 7 * S + rnd.uniform(-2, 2) * S
            dd.ellipse((px - 2 * S, y - 13 * S, px + 2 * S, y - 9 * S), fill=(10, 9, 18, 255))
            dd.rectangle((px - 2 * S, y - 9 * S, px + 2 * S, y), fill=(10, 9, 18, 255))
    # the gold divider and labels
    d = ImageDraw.Draw(img)
    d.line([(W * 0.5, H * 0.12), (W * 0.5, H * 0.88)], fill=GOLD_DK + (200,), width=int(1.5 * S))
    r = 26 * S
    d.ellipse((W * 0.5 - r, H * 0.5 - r, W * 0.5 + r, H * 0.5 + r), fill=(20, 16, 40, 255), outline=GOLD + (255,), width=int(2 * S))
    d.text((W * 0.5, H * 0.5), "vs", font=font(22 * S), fill=GOLD_HI + (255,), anchor="mm")
    for x, label, sub in ((W * 0.25, "SOLO", "your PC, offline"), (W * 0.75, "REALM", "online, with everyone")):
        d.text((x, H * 0.12), label, font=font(30 * S), fill=GOLD_HI + (255,), anchor="mm")
        d.text((x, H * 0.21), sub, font=font(15 * S), fill=(203, 213, 225, 230), anchor="mm")
    return img


# -- hero card + social preview -------------------------------------------------------------
def solo_card():
    img = scene(480, 300, seed=17, fire=(0.56, 0.84), k=0.82, orion=(0.62, 0.10, 0.26), horizon=0.72)
    return img


def og_image():
    W, H = 1200, 630
    img = scene(W, H, seed=11, fire=(0.76, 0.84), k=0.92, orion=(0.76, 0.08, 0.18), horizon=0.72)
    # darken the left for the title
    shade = Image.new("L", img.size, 0)
    arr = np.linspace(230, 0, img.size[0] // 2).astype(np.uint8)
    full = np.zeros((img.size[1], img.size[0]), np.uint8)
    full[:, : img.size[0] // 2] = arr[None, :]
    shade = Image.fromarray(full, "L")
    lay = Image.new("RGBA", img.size, (4, 5, 12, 0))
    lay.putalpha(shade)
    img.alpha_composite(lay)
    logo_path = os.path.join(ROOT, "www", "assets", "openvanilla_logo_hero.png")
    if os.path.exists(logo_path):
        logo = Image.open(logo_path).convert("RGBA")
        lw = 300 * S
        logo = logo.resize((lw, int(logo.height * lw / logo.width)), Image.LANCZOS)
        img.alpha_composite(logo, (60 * S, 50 * S))
        ty = 50 * S + logo.height + 10 * S
    else:
        ty = 120 * S
    d = ImageDraw.Draw(img)
    d.text((70 * S, ty), "Play Solo", font=font(72 * S), fill=GOLD_HI + (255,))
    d.text((72 * S, ty + 92 * S), "The whole game, offline on your PC.", font=font(24 * S), fill=(226, 232, 240, 255))
    d.text((72 * S, ty + 130 * S), "Companions for groups and dungeons.", font=font(24 * S), fill=(203, 213, 225, 235))
    return img


def save(img, name, size=None, fmt="WEBP"):
    os.makedirs(OUT, exist_ok=True)
    out = img.convert("RGB")
    out = out.resize(size or (out.width // S, out.height // S), Image.LANCZOS)
    path = os.path.join(OUT, name)
    if fmt == "JPEG":
        out.save(path, "JPEG", quality=88, optimize=True, progressive=True)
    else:
        out.save(path, "WEBP", quality=86, method=6)
    print("wrote", path)


if __name__ == "__main__":
    save(scene(1200, 520), "solo_hero.webp")
    save(step_card(1, icon_download, 41, (60, 90, 210)), "step_download.webp")
    save(step_card(2, icon_unzip, 42, VIOLET), "step_unzip.webp")
    save(step_card(3, icon_play, 43, (200, 90, 70)), "step_play.webp")
    save(solo_vs_realm(), "solo_vs_realm.webp")
    save(solo_card(), "solo_card.webp")
    og = og_image()
    save(og, "solo_og.webp")
    save(og, "solo_og.jpg", fmt="JPEG")
