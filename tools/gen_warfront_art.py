#!/usr/bin/env python3
"""Website art for Warfront, the dedicated PvP realm: its two modes side by side.

    py -3 tools/gen_warfront_art.py

Left, Instant 60 Arena: a stone arena ring seen from above, two banners facing off, crossed blades
over a level-60 shield. Right, World PvP: a map of contested ground, towns under split flags,
objective markers, the roads between them and a bounty mark. Writes www/assets/pvp/warfront.webp
(1200x520). Our own art; deterministic.
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "www", "assets", "pvp")
S = 2
W, H = 1200 * S, 520 * S
GOLD = (226, 182, 82)
RED = (196, 52, 46)
BLUE = (52, 104, 206)
rnd = random.Random(60)


def glow(size, xy, r, color, alpha, blur=None):
    lay = Image.new("RGBA", size, color + (0,))
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).ellipse((xy[0] - r, xy[1] - r, xy[0] + r, xy[1] + r), fill=alpha)
    lay.putalpha(m.filter(ImageFilter.GaussianBlur(blur or r * .6)))
    return lay


def backdrop():
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            t = min(1, math.hypot((x - W * .5) / W, (y - H * .55) / H) * 1.7)
            c = (int(30 - 20 * t), int(14 - 9 * t), int(20 - 13 * t))
            for dx in (0, 1):
                for dy in (0, 1):
                    if x + dx < W and y + dy < H:
                        px[x + dx, y + dy] = c
    img = img.convert("RGBA")
    img.alpha_composite(glow((W, H), (W * .27, H * .55), 420 * S, (170, 50, 40), 110))
    img.alpha_composite(glow((W, H), (W * .75, H * .5), 380 * S, (60, 70, 140), 90))
    # embers
    d = ImageDraw.Draw(img)
    for _ in range(260):
        x, y = rnd.randrange(W), rnd.randrange(H)
        r = rnd.choice([1, 1.5, 2, 2.5]) * S
        d.ellipse((x - r, y - r, x + r, y + r), fill=(255, rnd.randint(120, 200), 90, rnd.choice([40, 70, 110, 160])))
    return img


def banner(img, x, y, color, flip=False):
    d = ImageDraw.Draw(img)
    d.rectangle((x - 3 * S, y - 150 * S, x + 3 * S, y + 40 * S), fill=(70, 56, 40, 255))
    d.ellipse((x - 8 * S, y - 160 * S, x + 8 * S, y - 144 * S), fill=GOLD + (255,))
    k = -1 if flip else 1
    cloth = [(x, y - 140 * S), (x + k * 70 * S, y - 140 * S), (x + k * 70 * S, y - 40 * S),
             (x + k * 35 * S, y - 60 * S), (x, y - 40 * S)]
    d.polygon(cloth, fill=color + (255,))
    d.line(cloth + [cloth[0]], fill=GOLD + (255,), width=3 * S)
    # emblem: a simple chevron
    cx = x + k * 35 * S
    d.polygon([(cx - 18 * S, y - 115 * S), (cx, y - 95 * S), (cx + 18 * S, y - 115 * S), (cx + 18 * S, y - 103 * S),
               (cx, y - 83 * S), (cx - 18 * S, y - 103 * S)], fill=(245, 230, 190, 255))


def blade(d, cx, cy, ang, length):
    ca, sa = math.cos(ang), math.sin(ang)
    def p(u, v):
        return (cx + ca * u - sa * v, cy + sa * u + ca * v)
    d.polygon([p(-length * .45, -6 * S), p(length * .5, -6 * S), p(length * .58, 0), p(length * .5, 6 * S), p(-length * .45, 6 * S)],
              fill=(214, 220, 230, 255), outline=(90, 96, 110, 255))
    d.line([p(-length * .45, 0), p(length * .5, 0)], fill=(255, 255, 255, 200), width=2 * S)
    d.polygon([p(-length * .45, -26 * S), p(-length * .41, -26 * S), p(-length * .41, 26 * S), p(-length * .45, 26 * S)], fill=GOLD + (255,))
    d.rectangle(tuple(map(int, (0, 0, 0, 0))))
    d.polygon([p(-length * .62, -5 * S), p(-length * .45, -5 * S), p(-length * .45, 5 * S), p(-length * .62, 5 * S)], fill=(92, 60, 36, 255))
    q = p(-length * .66, 0)
    d.ellipse((q[0] - 8 * S, q[1] - 8 * S, q[0] + 8 * S, q[1] + 8 * S), fill=GOLD + (255,))


def arena(img):
    cx, cy = 300 * S, 300 * S
    d = ImageDraw.Draw(img)
    rx, ry = 250 * S, 120 * S
    # outer stone wall with blocks
    d.ellipse((cx - rx - 26 * S, cy - ry - 18 * S, cx + rx + 26 * S, cy + ry + 30 * S), fill=(58, 50, 46, 255))
    for i in range(36):
        a = i / 36 * 2 * math.pi
        x1, y1 = cx + (rx + 26 * S) * math.cos(a), cy + 6 * S + (ry + 24 * S) * math.sin(a)
        x0, y0 = cx + rx * math.cos(a), cy + ry * math.sin(a)
        d.line([(x0, y0), (x1, y1)], fill=(36, 30, 28, 255), width=2 * S)
    # sand floor
    floor = Image.new("RGBA", img.size, (0, 0, 0, 0))
    fd = ImageDraw.Draw(floor)
    fd.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=(150, 112, 70, 255))
    for _ in range(900):
        a, r = rnd.uniform(0, 2 * math.pi), math.sqrt(rnd.random())
        x, y = cx + rx * r * math.cos(a), cy + ry * r * math.sin(a)
        c = rnd.randint(-26, 22)
        fd.point((x, y), fill=(150 + c, 112 + c, 70 + c, 255))
    img.alpha_composite(floor)
    d = ImageDraw.Draw(img)
    d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), outline=(30, 24, 20, 255), width=4 * S)
    d.ellipse((cx - rx * .55, cy - ry * .55, cx + rx * .55, cy + ry * .55), outline=(120, 86, 52, 255), width=3 * S)
    # glow at the centre and the crossed blades over a level-60 shield
    img.alpha_composite(glow(img.size, (cx, cy - 40 * S), 150 * S, (255, 160, 80), 120))
    d = ImageDraw.Draw(img)
    blade(d, cx, cy - 60 * S, math.radians(-38), 230 * S)
    blade(d, cx, cy - 60 * S, math.radians(-142), 230 * S)
    sx, sy = cx, cy - 46 * S
    shield = [(sx - 46 * S, sy - 56 * S), (sx + 46 * S, sy - 56 * S), (sx + 46 * S, sy + 4 * S), (sx, sy + 56 * S), (sx - 46 * S, sy + 4 * S)]
    d.polygon(shield, fill=(54, 20, 22, 255))
    d.line(shield + [shield[0]], fill=GOLD + (255,), width=5 * S)
    try:
        f = ImageFont.truetype("/home/claude/fonts/marcellus.ttf", 50 * S)
    except OSError:
        f = ImageFont.load_default()
    d.text((sx, sy - 10 * S), "60", font=f, fill=(255, 226, 150, 255), anchor="mm")
    banner(img, cx - 205 * S, cy + 20 * S, RED)
    banner(img, cx + 205 * S, cy + 20 * S, BLUE, flip=True)


def worldmap(img):
    x0, y0, x1, y1 = 650 * S, 70 * S, 1150 * S, 460 * S
    mp = Image.new("RGBA", img.size, (0, 0, 0, 0))
    md = ImageDraw.Draw(mp)
    md.rounded_rectangle((x0, y0, x1, y1), radius=10 * S, fill=(196, 170, 120, 255))
    for _ in range(1600):
        x, y = rnd.uniform(x0, x1), rnd.uniform(y0, y1)
        c = rnd.randint(-22, 14)
        md.point((x, y), fill=(196 + c, 170 + c, 120 + c, 255))
    # land masses: soft blobs
    for _ in range(9):
        cx, cy = rnd.uniform(x0 + 60 * S, x1 - 60 * S), rnd.uniform(y0 + 50 * S, y1 - 50 * S)
        r = rnd.uniform(40, 90) * S
        blob = Image.new("L", img.size, 0)
        ImageDraw.Draw(blob).ellipse((cx - r * 1.3, cy - r, cx + r * 1.3, cy + r), fill=60)
        mp.paste((120, 140, 80, 255), (0, 0), blob.filter(ImageFilter.GaussianBlur(20 * S)))
    md = ImageDraw.Draw(mp)
    # a river
    pts = [(x0 + 20 * S, y0 + 120 * S), (x0 + 140 * S, y0 + 170 * S), (x0 + 250 * S, y0 + 150 * S), (x0 + 380 * S, y0 + 230 * S), (x1 - 10 * S, y0 + 260 * S)]
    md.line(pts, fill=(80, 120, 160, 255), width=7 * S, joint="curve")
    img.alpha_composite(mp)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((x0, y0, x1, y1), radius=10 * S, outline=(90, 64, 34, 255), width=5 * S)
    d.rounded_rectangle((x0 + 8 * S, y0 + 8 * S, x1 - 8 * S, y1 - 8 * S), radius=8 * S, outline=(150, 112, 62, 255), width=2 * S)
    towns = [(x0 + 110 * S, y0 + 260 * S, RED), (x0 + 250 * S, y0 + 90 * S, None), (x0 + 330 * S, y0 + 300 * S, BLUE),
             (x0 + 420 * S, y0 + 130 * S, None)]
    # dotted roads
    order = [0, 1, 3, 2, 0]
    for a, b in zip(order, order[1:]):
        (ax, ay, _), (bx, by, _) = towns[a], towns[b]
        n = int(math.dist((ax, ay), (bx, by)) / (14 * S))
        for i in range(1, n):
            t = i / n
            px, py = ax + (bx - ax) * t, ay + (by - ay) * t
            if i % 2:
                d.ellipse((px - 3 * S, py - 3 * S, px + 3 * S, py + 3 * S), fill=(110, 70, 40, 255))
    for tx, ty, owner in towns:
        # a keep
        d.rectangle((tx - 22 * S, ty - 10 * S, tx + 22 * S, ty + 22 * S), fill=(96, 86, 76, 255), outline=(50, 40, 34, 255), width=2 * S)
        for k in (-22, -8, 6):
            d.rectangle((tx + k * S, ty - 18 * S, tx + (k + 10) * S, ty - 10 * S), fill=(96, 86, 76, 255), outline=(50, 40, 34, 255), width=2 * S)
        d.rectangle((tx - 6 * S, ty + 6 * S, tx + 6 * S, ty + 22 * S), fill=(40, 30, 24, 255))
        # flag: one side's colour, or split when contested
        d.line([(tx, ty - 18 * S), (tx, ty - 58 * S)], fill=(60, 44, 30, 255), width=3 * S)
        if owner:
            d.polygon([(tx, ty - 58 * S), (tx + 34 * S, ty - 50 * S), (tx, ty - 40 * S)], fill=owner + (255,))
        else:
            d.polygon([(tx, ty - 58 * S), (tx + 34 * S, ty - 50 * S), (tx, ty - 50 * S)], fill=RED + (255,))
            d.polygon([(tx, ty - 50 * S), (tx + 34 * S, ty - 50 * S), (tx, ty - 40 * S)], fill=BLUE + (255,))
            img.alpha_composite(glow(img.size, (tx, ty), 50 * S, (255, 200, 90), 110))
            d = ImageDraw.Draw(img)
            # crossed blades over contested towns
            d.line([(tx - 14 * S, ty - 30 * S), (tx + 14 * S, ty - 2 * S)], fill=(230, 230, 236, 255), width=4 * S)
            d.line([(tx + 14 * S, ty - 30 * S), (tx - 14 * S, ty - 2 * S)], fill=(230, 230, 236, 255), width=4 * S)
    # objective diamonds
    for ox, oy in ((x0 + 190 * S, y0 + 210 * S), (x0 + 380 * S, y0 + 220 * S)):
        d.polygon([(ox, oy - 14 * S), (ox + 12 * S, oy), (ox, oy + 14 * S), (ox - 12 * S, oy)], fill=GOLD + (255,), outline=(90, 60, 20, 255))
    # the bounty mark: a crosshair over a skull-ish token
    bx, by = x0 + 440 * S, y0 + 330 * S
    img.alpha_composite(glow(img.size, (bx, by), 46 * S, (255, 60, 50), 140))
    d = ImageDraw.Draw(img)
    d.ellipse((bx - 24 * S, by - 24 * S, bx + 24 * S, by + 24 * S), fill=(40, 16, 14, 255), outline=(255, 90, 70, 255), width=3 * S)
    d.ellipse((bx - 11 * S, by - 12 * S, bx + 11 * S, by + 6 * S), fill=(236, 228, 210, 255))
    d.rectangle((bx - 7 * S, by + 4 * S, bx + 7 * S, by + 12 * S), fill=(236, 228, 210, 255))
    d.ellipse((bx - 8 * S, by - 6 * S, bx - 2 * S, by), fill=(40, 16, 14, 255))
    d.ellipse((bx + 2 * S, by - 6 * S, bx + 8 * S, by), fill=(40, 16, 14, 255))
    for a in (0, 90, 180, 270):
        r = math.radians(a)
        d.line([(bx + math.cos(r) * 30 * S, by + math.sin(r) * 30 * S), (bx + math.cos(r) * 44 * S, by + math.sin(r) * 44 * S)],
               fill=(255, 90, 70, 255), width=3 * S)


def divider(img):
    d = ImageDraw.Draw(img)
    x = 610 * S
    d.line([(x, 60 * S), (x, H - 60 * S)], fill=GOLD + (120,), width=2 * S)
    d.polygon([(x, 250 * S), (x + 10 * S, 260 * S), (x, 270 * S), (x - 10 * S, 260 * S)], fill=GOLD + (255,))


if __name__ == "__main__":
    img = backdrop()
    arena(img)
    worldmap(img)
    divider(img)
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, "warfront.webp")
    img.convert("RGB").resize((1200, 520), Image.LANCZOS).save(out, quality=88, method=6)
    print("wrote", out)
