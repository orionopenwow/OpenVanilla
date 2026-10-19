#!/usr/bin/env python3
"""Website art for the Orion section: Orion as the realm's caretaker.

    python tools/gen_orion_caretaker_art.py [out_dir]

Writes www/assets/orion/orion_caretaker.webp (1200x520): Orion's gold hexagon core keeping watch
over a realm keep, with the patch pipeline along the bottom (three gates: staging, Herald Lite,
live) and a patch travelling through them. Same sky, nebula and gold as gen_orion_art.py, whose
helpers it reuses. Deterministic.
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
_argv, sys.argv = sys.argv, sys.argv[:1]          # gen_orion_art reads argv[1] as its out dir
import gen_orion_art as oa                        # noqa: E402
sys.argv = _argv

ROOT = os.path.dirname(HERE)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "www", "assets", "orion")
S, W, H = oa.S, oa.W, oa.H
GOLD, GOLD_DK, CYAN = oa.GOLD, oa.GOLD_DK, oa.CYAN


def keep(img, cx, base, k):
    """A small realm keep with lit windows."""
    m = Image.new("L", img.size, 0)
    d = ImageDraw.Draw(m)
    d.polygon([(cx - 120 * k, base), (cx - 80 * k, base - 40 * k), (cx + 80 * k, base - 40 * k), (cx + 120 * k, base)], fill=255)
    towers = ((-52, 100), (0, 140), (52, 100))
    for tx, th in towers:
        d.rectangle((cx + (tx - 16) * k, base - (40 + th) * k, cx + (tx + 16) * k, base - 38 * k), fill=255)
        for b in range(3):
            d.rectangle((cx + (tx - 16 + b * 12.5) * k, base - (50 + th) * k, cx + (tx - 9 + b * 12.5) * k, base - (40 + th) * k), fill=255)
    lay = Image.new("RGBA", img.size, (14, 12, 30, 0))
    lay.putalpha(m)
    img.alpha_composite(lay)
    d = ImageDraw.Draw(img)
    rnd = random.Random(4)
    for tx, th in towers:
        for _ in range(3):
            wx, wy = cx + (tx + rnd.uniform(-8, 8)) * k, base - (40 + rnd.uniform(18, th - 14)) * k
            d.rectangle((wx - 2.5 * k, wy - 5 * k, wx + 2.5 * k, wy + 5 * k), fill=(255, 205, 130, 255))


def status_rings(img, cx, cy, r):
    """Healthy-realm pulse: soft green rings."""
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for i, a in enumerate((130, 70)):
        rr = r * (1 + i * 0.32)
        d.ellipse((cx - rr, cy - rr * 0.42, cx + rr, cy + rr * 0.42), outline=(74, 222, 128, a), width=int(2 * S))
    img.alpha_composite(lay.filter(ImageFilter.GaussianBlur(S * 0.8)))
    img.alpha_composite(lay)


def gate(img, x, y, r, ring, core):
    oa.node(img, x, y, r, core, ring)
    d = ImageDraw.Draw(img)
    d.polygon(oa.hexagon(x, y, r * 1.9, math.pi / 6), outline=ring + (120,), width=int(1.5 * S))


def caretaker():
    rnd = random.Random(19)
    img = oa.sky(29, [(420, 200, 340, oa.VIOLET, 150), (900, 300, 260, (50, 80, 200), 120), (160, 380, 200, (255, 150, 90), 50)])
    d = ImageDraw.Draw(img)
    orion = [(905, 50), (985, 40), (1030, 100), (968, 136), (985, 142), (1002, 148), (952, 210), (1070, 216)]
    for a, b in [(0, 1), (1, 2), (0, 3), (2, 5), (3, 4), (4, 5), (3, 6), (5, 7)]:
        d.line([(orion[a][0] * S, orion[a][1] * S), (orion[b][0] * S, orion[b][1] * S)], fill=(200, 200, 255, 70), width=S)
    for x, y in orion:
        d.ellipse(((x - 3) * S, (y - 3) * S, (x + 3) * S, (y + 3) * S), fill=(235, 235, 255, 230))
    # ground
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(lay)
    pts = [(x * S, (430 + 12 * math.sin(x / 140) + 6 * math.sin(x / 47)) * S) for x in range(0, 1201, 8)]
    ld.polygon(pts + [(W, H), (0, H)], fill=(10, 9, 22, 255))
    img.alpha_composite(lay)
    # the live realm on the right, healthy
    kx, kb = 960 * S, 432 * S
    status_rings(img, kx, kb - 4 * S, 105 * S)
    keep(img, kx, kb, 0.9 * S)
    # Orion, keeping watch
    cx, cy = 330 * S, 170 * S
    # watch beam from Orion to the keep
    oa.stream(img, oa.bezier((cx + 60 * S, cy + 10 * S), (650 * S, 120 * S), (kx - 10 * S, kb - 190 * S), 90), rnd, 4 * S)
    # the patch pipeline: staging -> Herald Lite -> live
    gates = [(250, 470, (110, 170, 255), (220, 232, 255)), (470, 470, (190, 130, 255), (240, 228, 255)), (690, 470, GOLD, (255, 240, 200))]
    for (x1, y1, _, _), (x2, y2, _, _) in zip(gates, gates[1:]):
        oa.stream(img, oa.bezier(((x1 + 26) * S, y1 * S), ((x1 + x2) / 2 * S, (y1 - 26) * S), ((x2 - 26) * S, y2 * S), 50), rnd, 4 * S)
    oa.stream(img, oa.bezier(((690 + 26) * S, 470 * S), (800 * S, 450 * S), (kx - 120 * S, kb - 6 * S), 60), rnd, 4 * S)
    for x, y, ring, core in gates:
        gate(img, x * S, y * S, 11 * S, ring, core)
    # a check mark of light above each gate the patch has passed
    d = ImageDraw.Draw(img)
    for x, y, ring, _ in gates[:2]:
        d.line([((x - 8) * S, (y - 46) * S), ((x - 2) * S, (y - 40) * S), ((x + 10) * S, (y - 54) * S)], fill=(74, 222, 128, 255), width=int(3 * S), joint="curve")
    oa.sparkle(d, 690 * S, 422 * S, 9 * S, (255, 236, 170, 255))
    # the dotted watch line from Orion down to the pipeline
    for i in range(14):
        t = i / 13
        x, y = (cx + (470 * S - cx) * t), (cy + 70 * S + (440 * S - cy - 70 * S) * t)
        r = 2.2 * S
        d.ellipse((x - r, y - r, x + r, y + r), fill=(220, 210, 255, 150))
    oa.orion_core(img, cx, cy, 58 * S)
    return img


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    out = caretaker().convert("RGB").resize((1200, 520), Image.LANCZOS)
    path = os.path.join(OUT, "orion_caretaker.webp")
    out.save(path, quality=88, method=6)
    print("wrote", path)
