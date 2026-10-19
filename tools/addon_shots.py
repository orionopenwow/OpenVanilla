#!/usr/bin/env python3
"""Website pictures of the Classic+ addons: real in-game captures on one designed background.

    py -3 tools/addon_shots.py

Reads art/addon-shots/raw/<Addon>.png (a tight crop of one addon window, e.g. from Win+Shift+S
after /wnl demo in game) and writes www/assets/addons/<addon>.webp (960x600) for the website's
"Classic+ Addons, Built In" section. Missing captures are listed and skipped.
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "art", "addon-shots", "raw")
OUT = os.path.join(ROOT, "www", "assets", "addons")
ADDONS = ["Vault", "Chronicle", "Compass", "Vanguard", "Castline",
          "Visage", "Ledger", "Concord", "Rally", "Scrapper", "Persona"]
W, H = 960, 600
GOLD = (212, 167, 66)
GOLD_DIM = (109, 84, 38)


def background(seed):
    """Deep navy to black, faint stars, a warm glow where the window sits."""
    bg = Image.new("RGB", (W, H))
    px = bg.load()
    cx, cy = W / 2, H / 2
    rmax = math.hypot(cx, cy)
    for y in range(H):
        for x in range(W):
            t = min(1.0, math.hypot((x - cx) * 0.85, y - cy) / rmax)
            t = t ** 1.4
            px[x, y] = (int(22 - 17 * t), int(30 - 23 * t), int(52 - 40 * t))
    stars = Image.new("L", (W, H))
    d = ImageDraw.Draw(stars)
    rnd = random.Random(seed)
    for _ in range(170):
        x, y = rnd.randrange(W), rnd.randrange(H)
        b = rnd.choice([40, 60, 90, 140, 200])
        r = 1 if b < 150 else rnd.choice([1, 1, 2])
        d.ellipse((x - r / 2, y - r / 2, x + r / 2, y + r / 2), fill=b)
    stars = stars.filter(ImageFilter.GaussianBlur(0.6))
    bg.paste((235, 228, 205), (0, 0), stars)
    glow = Image.new("L", (W, H))
    ImageDraw.Draw(glow).ellipse((W * 0.22, H * 0.2, W * 0.78, H * 0.8), fill=95)
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    bg.paste((240, 192, 88), (0, 0), glow)
    return bg


def frame(img):
    """Thin gold rule inset from the edge, with small corner ticks."""
    d = ImageDraw.Draw(img)
    m = 12
    d.rectangle((m, m, W - 1 - m, H - 1 - m), outline=GOLD_DIM, width=1)
    t = 22
    for (x, y, sx, sy) in ((m, m, 1, 1), (W - 1 - m, m, -1, 1), (m, H - 1 - m, 1, -1), (W - 1 - m, H - 1 - m, -1, -1)):
        d.line((x, y, x + sx * t, y), fill=GOLD, width=2)
        d.line((x, y, x, y + sy * t), fill=GOLD, width=2)
    return img


def compose(shot, seed):
    img = background(seed)
    shot = shot.convert("RGBA")
    # Fit inside 88% x 84% of the card; enlarge small windows at most 2.5x so text stays crisp.
    scale = min(W * 0.88 / shot.width, H * 0.84 / shot.height, 2.5)
    size = (max(1, round(shot.width * scale)), max(1, round(shot.height * scale)))
    shot = shot.resize(size, Image.LANCZOS)
    x, y = (W - size[0]) // 2, (H - size[1]) // 2
    shadow = Image.new("L", (W, H))
    ImageDraw.Draw(shadow).rectangle((x + 6, y + 12, x + size[0] + 6, y + size[1] + 12), fill=200)
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    img.paste((0, 0, 0), (0, 0), shadow)
    img.paste(shot, (x, y), shot)
    return frame(img)


def main():
    os.makedirs(OUT, exist_ok=True)
    missing = []
    for i, name in enumerate(ADDONS):
        src = os.path.join(RAW, name + ".png")
        if not os.path.isfile(src):
            missing.append(name)
            continue
        out = os.path.join(OUT, name.lower() + ".webp")
        compose(Image.open(src), seed=i + 7).save(out, "WEBP", quality=86, method=6)
        print(f"  {name:10} -> www/assets/addons/{name.lower()}.webp ({os.path.getsize(out) // 1024} KB)")
    if missing:
        print("Missing captures (save them in art\\addon-shots\\raw\\ as <Name>.png): " + ", ".join(missing))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
