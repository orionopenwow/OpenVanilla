#!/usr/bin/env python3
"""Website art for the Starfall Giving (support) and Orion Network sections.

    py -3 tools/gen_orion_art.py

Writes www/assets/orion/{starfall_giving,orion_network}.webp (1200x520) and orion_node.webp
(128x128): night sky, violet nebula, gold rims.
Deterministic: the same seed draws the same picture.
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "www", "assets", "orion")
S = 2                      # supersampling
W, H = 1200 * S, 520 * S
GOLD = (232, 188, 84)
GOLD_DK = (150, 108, 40)
INDIGO = (36, 30, 104)
VIOLET = (126, 58, 196)
CYAN = (150, 220, 255)


def glow(size, xy, r, color, alpha=255, blur=None):
    """A soft radial light as an RGBA layer."""
    layer = Image.new("RGBA", size, color + (0,))
    m = Image.new("L", size, 0)
    x, y = xy
    ImageDraw.Draw(m).ellipse((x - r, y - r, x + r, y + r), fill=alpha)
    m = m.filter(ImageFilter.GaussianBlur(blur or r * 0.6))
    layer.putalpha(m)
    return layer


def sky(seed, nebula):
    """Navy-to-black night with stars and violet nebula clouds (list of (x, y, r, color, a))."""
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            t = min(1, math.hypot((x - W * .55) / W, (y - H * .45) / H) * 1.6)
            c = (int(14 - 9 * t), int(14 - 10 * t), int(34 - 24 * t))
            px[x, y] = c
            if x + 1 < W: px[x + 1, y] = c
            if y + 1 < H:
                px[x, y + 1] = c
                if x + 1 < W: px[x + 1, y + 1] = c
    img = img.convert("RGBA")
    for x, y, r, col, a in nebula:
        img.alpha_composite(glow((W, H), (x * S, y * S), r * S, col, a))
    rnd = random.Random(seed)
    st = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(st)
    for _ in range(520):
        x, y = rnd.randrange(W), rnd.randrange(H)
        b = rnd.choice([70, 110, 150, 200, 255])
        r = rnd.choice([1, 1, 1.5, 2, 2.5]) * S * (1.4 if b == 255 else 1)
        d.ellipse((x - r, y - r, x + r, y + r), fill=(235, 236, 255, b))
    img.alpha_composite(st.filter(ImageFilter.GaussianBlur(S * .4)))
    return img


def sparkle(d, x, y, r, col=(255, 255, 255, 255)):
    """Four-point star, like the coin's."""
    w = r * .22
    d.polygon([(x, y - r), (x + w, y - w), (x + r, y), (x + w, y + w), (x, y + r), (x - w, y + w), (x - r, y), (x - w, y - w)], fill=col)


def bezier(p0, p1, p2, n=60):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]) for t in (i / n for i in range(n + 1))]


def stream(img, pts, rnd, width):
    """A falling ribbon of starlight with sparks along it."""
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    d.line(pts, fill=(180, 210, 255, 150), width=int(width * 2.2), joint="curve")
    lay = lay.filter(ImageFilter.GaussianBlur(width * .9))
    img.alpha_composite(lay)
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    d.line(pts, fill=(235, 245, 255, 235), width=int(width * .7), joint="curve")
    for i, (x, y) in enumerate(pts):
        if rnd.random() < .45:
            o = (rnd.random() - .5) * width * 2.4
            r = rnd.choice([1.2, 1.6, 2.2]) * S
            d.ellipse((x + o - r, y - r, x + o + r, y + r), fill=(255, 245, 210, 255))
    img.alpha_composite(lay.filter(ImageFilter.GaussianBlur(S * .5)))


def basin(img, cx, cy, rx, fill_level=1.0):
    """A gold-rimmed bowl of starlight seen slightly from above."""
    ry = rx * .32
    d = ImageDraw.Draw(img)
    depth = rx * .55
    # bowl body
    body = [(cx - rx, cy)] + [(cx + rx * math.cos(a), cy + depth * math.sin(a)) for a in [i * math.pi / 40 for i in range(41)]] + [(cx + rx, cy)]
    d.polygon(body, fill=(24, 20, 58, 255))
    # gold band on the body
    d.line([(cx + rx * .96 * math.cos(a), cy + depth * .96 * math.sin(a)) for a in [i * math.pi / 40 for i in range(41)]], fill=GOLD_DK + (255,), width=int(3 * S))
    # liquid surface
    img.alpha_composite(glow(img.size, (cx, cy), rx * 1.05, (170, 120, 255), 120, rx * .5))
    d = ImageDraw.Draw(img)
    d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=(64, 46, 150, 255))
    inner = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(inner).ellipse((cx - rx * .8, cy - ry * .7, cx + rx * .8, cy + ry * .7), fill=(190, 170, 255, 170))
    img.alpha_composite(inner.filter(ImageFilter.GaussianBlur(rx * .18)))
    d = ImageDraw.Draw(img)
    # rim
    d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), outline=GOLD + (255,), width=int(4 * S))
    d.arc((cx - rx * .97, cy - ry * .9, cx + rx * .97, cy + ry * .9), 200, 340, fill=(255, 236, 170, 255), width=int(2 * S))
    sparkle(d, cx - rx * .25, cy - ry * .1, 7 * S)
    sparkle(d, cx + rx * .3, cy + ry * .15, 5 * S, (255, 255, 255, 220))


def heart_lantern(img, cx, cy, r):
    """The giving vessel: a gold-framed heart of warm light with rising embers."""
    img.alpha_composite(glow(img.size, (cx, cy), r * 2.2, (255, 150, 120), 150, r * 1.2))
    img.alpha_composite(glow(img.size, (cx, cy), r * 1.2, (255, 200, 150), 200, r * .5))
    pts = []
    for i in range(200):
        t = i / 200 * 2 * math.pi
        x = 16 * math.sin(t) ** 3
        y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
        pts.append((cx + x * r / 17, cy + y * r / 17))
    d = ImageDraw.Draw(img)
    d.polygon(pts, fill=(255, 170, 140, 255))
    inner = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(inner).polygon([(cx + (x - cx) * .62, cy - r * .08 + (y - cy) * .62) for x, y in pts], fill=(255, 245, 225, 255))
    img.alpha_composite(inner.filter(ImageFilter.GaussianBlur(r * .16)))
    d = ImageDraw.Draw(img)
    d.line(pts + [pts[0]], fill=GOLD + (255,), width=int(5 * S), joint="curve")
    sparkle(d, cx, cy - r * .15, r * .32)
    rnd = random.Random(9)
    for _ in range(24):
        a = rnd.uniform(-1.1, 1.1)
        dist = rnd.uniform(r * 1.0, r * 2.3)
        x, y = cx + math.sin(a) * dist * .55, cy - r * .6 - abs(math.cos(a)) * dist
        s = rnd.choice([1.5, 2, 3, 4]) * S
        sparkle(d, x, y, s * 1.8, (255, 220, 170, rnd.choice([150, 200, 255])))


def starfall():
    rnd = random.Random(42)
    img = sky(11, [(820, 250, 330, VIOLET, 150), (360, 330, 260, (60, 70, 190), 120), (1040, 300, 160, (255, 120, 120), 60)])
    # faint Orion, top right
    d = ImageDraw.Draw(img)
    orion = [(905, 60), (985, 48), (1030, 112), (968, 150), (985, 156), (1002, 162), (952, 230), (1070, 236)]
    for a, b in [(0, 1), (1, 2), (0, 3), (2, 5), (3, 4), (4, 5), (3, 6), (5, 7)]:
        d.line([(orion[a][0] * S, orion[a][1] * S), (orion[b][0] * S, orion[b][1] * S)], fill=(200, 200, 255, 70), width=S)
    for x, y in orion:
        d.ellipse(((x - 3) * S, (y - 3) * S, (x + 3) * S, (y + 3) * S), fill=(235, 235, 255, 230))
    # five basins down a staircase of the sky
    bowls = [(150, 120, 74), (300, 190, 70), (450, 258, 66), (600, 322, 62), (750, 384, 58)]
    for i, (x, y, r) in enumerate(bowls):
        if i + 1 < len(bowls):
            nx, ny, nr = bowls[i + 1]
            stream(img, bezier(((x + r * .9) * S, (y + 2) * S), ((x + r * 1.5) * S, (y - 6) * S), ((nx - nr * .2) * S, (ny - 4) * S)), rnd, 7 * S)
    lx, ly = 1000, 360
    stream(img, bezier(((750 + 52) * S, 386 * S), (880 * S, 340 * S), ((lx - 60) * S, (ly + 8) * S), 80), rnd, 9 * S)
    for x, y, r in bowls:
        basin(img, x * S, y * S, r * S)
    heart_lantern(img, lx * S, ly * S, 62 * S)
    return img


def hexagon(cx, cy, r, rot=0):
    return [(cx + r * math.cos(rot + i * math.pi / 3), cy + r * math.sin(rot + i * math.pi / 3)) for i in range(6)]


def node(img, x, y, r, core=(255, 255, 255), ring=CYAN, a=255):
    img.alpha_composite(glow(img.size, (x, y), r * 2.6, ring, int(a * .55), r * 1.4))
    d = ImageDraw.Draw(img)
    d.polygon(hexagon(x, y, r * 1.35, math.pi / 6), outline=ring + (a,), width=max(2, int(r * .18)))
    d.ellipse((x - r * .55, y - r * .55, x + r * .55, y + r * .55), fill=core + (a,))


def network():
    rnd = random.Random(7)
    img = sky(23, [(600, 250, 380, VIOLET, 140), (260, 320, 260, (50, 80, 200), 110), (950, 160, 220, (40, 120, 220), 90)])
    orion = {"betel": (430, 110), "bella": (770, 96), "alnitak": (560, 258), "alnilam": (620, 270), "mintaka": (680, 282),
             "saiph": (470, 430), "rigel": (820, 440), "meissa": (600, 46)}
    edges = [("betel", "meissa"), ("meissa", "bella"), ("betel", "alnitak"), ("bella", "mintaka"), ("alnitak", "alnilam"),
             ("alnilam", "mintaka"), ("alnitak", "saiph"), ("mintaka", "rigel")]
    # a wide mesh of small peer nodes
    peers = [(rnd.uniform(40, 1160), rnd.uniform(30, 480)) for _ in range(46)]
    allpts = list(orion.values()) + peers
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for i, p in enumerate(allpts):
        near = sorted(allpts, key=lambda q: math.dist(p, q))[1:4]
        for q in near:
            if math.dist(p, q) < 190:
                d.line([(p[0] * S, p[1] * S), (q[0] * S, q[1] * S)], fill=(120, 170, 255, 60), width=S)
    img.alpha_composite(lay)
    # the constellation itself, bright gold lines
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for a, b in edges:
        (x1, y1), (x2, y2) = orion[a], orion[b]
        d.line([(x1 * S, y1 * S), (x2 * S, y2 * S)], fill=GOLD + (200,), width=int(2.5 * S))
    img.alpha_composite(lay.filter(ImageFilter.GaussianBlur(S * 2)))
    img.alpha_composite(lay)
    # data packets travelling the gold lines
    d = ImageDraw.Draw(img)
    for a, b in edges:
        (x1, y1), (x2, y2) = orion[a], orion[b]
        for k in range(2):
            t = rnd.uniform(.15, .85)
            x, y = (x1 + (x2 - x1) * t) * S, (y1 + (y2 - y1) * t) * S
            for j in range(6):
                tt = t - j * .018
                xx, yy = (x1 + (x2 - x1) * tt) * S, (y1 + (y2 - y1) * tt) * S
                r = (3.2 - j * .45) * S
                d.ellipse((xx - r, yy - r, xx + r, yy + r), fill=(255, 240, 200, 230 - j * 35))
    for x, y in peers:
        node(img, x * S, y * S, rnd.choice([3, 3.5, 4]) * S, (210, 225, 255), (110, 160, 255), 190)
    for name, (x, y) in orion.items():
        warm = name in ("betel",)
        node(img, x * S, y * S, (9 if name not in ("alnitak", "alnilam", "mintaka") else 8) * S,
             (255, 214, 170) if warm else (240, 246, 255), (255, 170, 90) if warm else CYAN)
    # the main realm: a gold hex core on the belt
    cx, cy = 620 * S, 270 * S
    img.alpha_composite(glow(img.size, (cx, cy), 110 * S, (255, 200, 110), 170, 60 * S))
    d = ImageDraw.Draw(img)
    d.polygon(hexagon(cx, cy, 40 * S, math.pi / 6), fill=(30, 24, 70, 255), outline=GOLD + (255,), width=int(4 * S))
    d.polygon(hexagon(cx, cy, 30 * S, math.pi / 6), outline=(255, 236, 170, 200), width=int(1.5 * S))
    sparkle(d, cx, cy, 20 * S)
    # the checkpoint chain: linked blocks along the bottom
    blocks = []
    for i in range(11):
        t = i / 10
        x = 110 + t * 980
        y = 492 - math.sin(t * math.pi) * 34
        blocks.append((x, y))
    for (x1, y1), (x2, y2) in zip(blocks, blocks[1:]):
        d.line([(x1 * S, y1 * S), (x2 * S, y2 * S)], fill=GOLD_DK + (255,), width=int(3 * S))
    for i, (x, y) in enumerate(blocks):
        s = 15 * S
        x, y = x * S, y * S
        d.rounded_rectangle((x - s, y - s, x + s, y + s), radius=4 * S, fill=(26, 22, 58, 255), outline=GOLD + (255,), width=int(2.5 * S))
        for k in range(3):
            d.line((x - s * .55, y - s * .45 + k * s * .45, x + s * (.55 if k != 1 else .2), y - s * .45 + k * s * .45), fill=(150, 200, 255, 220), width=int(1.6 * S))
    return img


def orion_core(img, cx, cy, r):
    """Orion: a gold hexagon core with orbit rings and the three belt stars."""
    img.alpha_composite(glow(img.size, (cx, cy), r * 3.2, (255, 196, 110), 150, r * 1.6))
    img.alpha_composite(glow(img.size, (cx, cy), r * 1.6, (170, 120, 255), 170, r * .8))
    d = ImageDraw.Draw(img)
    for k, (rx, ry, a0, a1) in enumerate([(2.0, .62, 190, 350), (2.35, .74, 10, 170)]):
        d.arc((cx - r * rx, cy - r * ry * 1.4, cx + r * rx, cy + r * ry * 1.4), a0, a1, fill=(150, 200, 255, 200), width=int(2 * S))
    for ang in (.6, 2.4, 4.1):
        x, y = cx + r * 2.0 * math.cos(ang), cy + r * .87 * math.sin(ang)
        d.ellipse((x - 5 * S, y - 5 * S, x + 5 * S, y + 5 * S), fill=(200, 230, 255, 255))
    d.polygon(hexagon(cx, cy, r, math.pi / 6), fill=(30, 24, 74, 255), outline=GOLD + (255,), width=int(5 * S))
    d.polygon(hexagon(cx, cy, r * .76, math.pi / 6), outline=(255, 236, 170, 210), width=int(2 * S))
    inner = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(inner).ellipse((cx - r * .5, cy - r * .5, cx + r * .5, cy + r * .5), fill=(150, 90, 230, 200))
    img.alpha_composite(inner.filter(ImageFilter.GaussianBlur(r * .2)))
    d = ImageDraw.Draw(img)
    for dx, dy, rr in ((-.32, .18, .2), (0, 0, .26), (.32, -.18, .2)):
        sparkle(d, cx + dx * r, cy + dy * r, rr * r)


def orion_waterfall():
    """Orion at the top, pouring support down the five buckets in order."""
    rnd = random.Random(42)
    img = sky(11, [(560, 250, 360, VIOLET, 150), (220, 160, 220, (255, 170, 90), 70), (900, 330, 240, (60, 70, 190), 110)])
    d = ImageDraw.Draw(img)
    orion = [(905, 60), (985, 48), (1030, 112), (968, 150), (985, 156), (1002, 162), (952, 230), (1070, 236)]
    for a, b in [(0, 1), (1, 2), (0, 3), (2, 5), (3, 4), (4, 5), (3, 6), (5, 7)]:
        d.line([(orion[a][0] * S, orion[a][1] * S), (orion[b][0] * S, orion[b][1] * S)], fill=(200, 200, 255, 70), width=S)
    for x, y in orion:
        d.ellipse(((x - 3) * S, (y - 3) * S, (x + 3) * S, (y + 3) * S), fill=(235, 235, 255, 230))
    cx, cy = 200, 168
    bowls = [(400, 220, 68), (545, 280, 64), (690, 336, 60), (835, 390, 56), (980, 440, 52)]
    stream(img, bezier(((cx + 58) * S, (cy + 20) * S), ((cx + 130) * S, (cy + 10) * S), ((bowls[0][0] - 30) * S, (bowls[0][1] - 4) * S)), rnd, 8 * S)
    for i, (x, y, r) in enumerate(bowls[:-1]):
        nx, ny, nr = bowls[i + 1]
        stream(img, bezier(((x + r * .9) * S, (y + 2) * S), ((x + r * 1.5) * S, (y - 6) * S), ((nx - nr * .2) * S, (ny - 4) * S)), rnd, 7 * S)
    for x, y, r in bowls:
        basin(img, x * S, y * S, r * S)
    orion_core(img, cx * S, cy * S, 62 * S)
    return img


def node_badge():
    s = 128 * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    c = s / 2
    d = ImageDraw.Draw(img)
    d.polygon(hexagon(c, c, s * .47, math.pi / 6), fill=(196, 206, 228, 255))
    d.polygon(hexagon(c, c, s * .42, math.pi / 6), fill=(30, 34, 96, 255))
    lay = glow((s, s), (c, c), s * .3, VIOLET, 200, s * .16)
    img.alpha_composite(lay)
    d = ImageDraw.Draw(img)
    pts = [(c - s * .2, c + s * .1), (c, c), (c + s * .2, c - s * .1)]
    ring = [(c + s * .29 * math.cos(a), c + s * .29 * math.sin(a)) for a in [i * math.pi / 3 + .3 for i in range(6)]]
    for p in ring:
        d.line([p, pts[min(range(3), key=lambda i: math.dist(p, pts[i]))]], fill=(150, 200, 255, 200), width=5)
        d.ellipse((p[0] - 9, p[1] - 9, p[0] + 9, p[1] + 9), fill=(160, 210, 255, 255))
    for x, y in pts:
        sparkle(d, x, y, s * .08)
    d.arc((c - s * .36, c - s * .36, c + s * .36, c + s * .36), 200, 250, fill=(255, 255, 255, 110), width=8)
    return img.resize((128, 128), Image.LANCZOS)


def save(img, name, size):
    os.makedirs(OUT, exist_ok=True)
    out = img.convert("RGB").resize(size, Image.LANCZOS) if size else img
    out.save(os.path.join(OUT, name), quality=88, method=6)
    print("wrote", os.path.join(OUT, name))


if __name__ == "__main__":
    save(starfall(), "starfall_giving.webp", (1200, 520))
    save(network(), "orion_network.webp", (1200, 520))
    save(node_badge(), "orion_node.webp", None)
    save(orion_waterfall(), "orion_core.webp", (1200, 520))
