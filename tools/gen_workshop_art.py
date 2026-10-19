#!/usr/bin/env python3
"""Art for the Workshop pages (www/workshop.html, www/workshop/*.html).

    python3 tools/gen_workshop_art.py            writes everything below
    python3 tools/gen_workshop_art.py --sheet X  also a contact sheet at X

www/assets/workshop/, procedural PIL art in the site's night-sky / gold style (helpers shared
with tools/gen_streams_art.py):
  hero_workshop.webp        1600x460  a craftsman's bench of glowing addon tiles orbiting an
                                      open rune book, gold filigree arcs, sparks
  cat_<category>.webp        640x240  one banner per category (also the card thumbnail when an
                                      addon has no screenshot): a tinted sky + a gold glyph
  badge_works / partly / needs / unknown / ours .webp   64x64 compat seals
  star_full.png star_half.png star_empty.png            32x32 rating stars
  collection_raiders.webp, collection_roleplay.webp     960x300 pack banners
  creator_banner.webp      1600x300  the profile banner behind a creator page
  og_workshop.jpg          1200x630  link preview
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import artkit  # noqa: E402
from gen_streams_art import GOLD, GOLD_DK, GOLD_HI, S, font, glow, ring, sky, sparkle, ticks  # noqa: E402

OUT = os.path.join(ROOT, "www", "assets", "workshop")

CATS = {  # id: (nebula colour, glyph)
    "interface": ((60, 80, 170), "window"),
    "unitframes": ((60, 130, 110), "frames"),
    "combat": ((160, 50, 40), "swords"),
    "raid": ((120, 40, 110), "skull"),
    "quests": ((170, 130, 40), "quest"),
    "bags": ((120, 80, 40), "bag"),
    "maps": ((40, 110, 140), "compass"),
    "social": ((70, 70, 160), "bubbles"),
    "economy": ((160, 120, 30), "coins"),
    "professions": ((90, 110, 60), "hammer"),
    "macros": ((90, 60, 170), "bolt"),
    "tooltips": ((110, 90, 70), "scroll"),
    "utility": ((80, 90, 110), "gear"),
    "classicplus": ((170, 120, 40), "plus"),
}


def lay(size):
    im = Image.new("RGBA", size, (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def glyph(d, kind, cx, cy, r, col=GOLD + (255,), w=None):
    """A simple line glyph centred at (cx, cy), radius r."""
    w = int(w or max(2, r * 0.09))
    hi = GOLD_HI + (255,)
    if kind == "window":
        d.rounded_rectangle((cx - r, cy - r * 0.75, cx + r, cy + r * 0.75), radius=r * 0.12, outline=col, width=w)
        d.line((cx - r, cy - r * 0.45, cx + r, cy - r * 0.45), fill=col, width=w)
        d.rectangle((cx - r * 0.8, cy - r * 0.25, cx - r * 0.1, cy + r * 0.55), outline=col, width=w)
        for i in range(3):
            y = cy - r * 0.2 + i * r * 0.25
            d.line((cx + r * 0.05, y, cx + r * 0.8, y), fill=col, width=w)
        for i in range(3):
            d.ellipse((cx + r * (0.55 + i * 0.13) - w, cy - r * 0.62 - w, cx + r * (0.55 + i * 0.13) + w, cy - r * 0.62 + w), fill=hi)
    elif kind == "frames":
        d.ellipse((cx - r, cy - r * 0.55, cx - r * 0.1, cy + r * 0.35), outline=col, width=w)
        for i, fill in enumerate(((60, 200, 90), (70, 120, 220))):
            y = cy - r * 0.35 + i * r * 0.42
            d.rounded_rectangle((cx - r * 0.02, y, cx + r, y + r * 0.3), radius=r * 0.06, outline=col, width=w)
            d.rectangle((cx + r * 0.05, y + w * 1.5, cx + r * (0.3 + 0.55 * (1 - i * 0.4)), y + r * 0.3 - w * 1.5), fill=fill + (230,))
    elif kind == "swords":
        for s in (1, -1):
            d.line((cx - r * s, cy + r, cx + r * 0.7 * s, cy - r * 0.7), fill=col, width=w * 2)
            d.line((cx - r * 0.75 * s, cy + r * 0.45, cx - r * 0.45 * s, cy + r * 0.75), fill=hi, width=w * 2)
            d.polygon([(cx + r * 0.7 * s, cy - r * 0.7), (cx + r * s, cy - r), (cx + r * 0.62 * s, cy - r * 0.9)], fill=hi)
    elif kind == "skull":
        d.ellipse((cx - r * 0.8, cy - r * 0.9, cx + r * 0.8, cy + r * 0.5), outline=col, width=w)
        d.rounded_rectangle((cx - r * 0.45, cy + r * 0.3, cx + r * 0.45, cy + r * 0.85), radius=r * 0.1, outline=col, width=w)
        for s in (-1, 1):
            d.ellipse((cx + s * r * 0.35 - r * 0.2, cy - r * 0.3, cx + s * r * 0.35 + r * 0.2, cy + r * 0.05), fill=hi)
        for i in range(-1, 2):
            d.line((cx + i * r * 0.18, cy + r * 0.5, cx + i * r * 0.18, cy + r * 0.85), fill=col, width=w)
    elif kind == "quest":
        d.polygon([(cx - r * 0.22, cy - r), (cx + r * 0.22, cy - r), (cx + r * 0.1, cy + r * 0.4), (cx - r * 0.1, cy + r * 0.4)], fill=hi)
        d.ellipse((cx - r * 0.16, cy + r * 0.6, cx + r * 0.16, cy + r * 0.92), fill=hi)
    elif kind == "bag":
        d.ellipse((cx - r * 0.85, cy - r * 0.4, cx + r * 0.85, cy + r), outline=col, width=w)
        d.polygon([(cx - r * 0.35, cy - r * 0.42), (cx + r * 0.35, cy - r * 0.42), (cx + r * 0.2, cy - r * 0.8), (cx - r * 0.2, cy - r * 0.8)],
                  outline=col)
        d.line((cx - r * 0.45, cy - r * 0.45, cx + r * 0.45, cy - r * 0.45), fill=hi, width=w * 2)
        d.ellipse((cx - r * 0.15, cy + r * 0.2, cx + r * 0.15, cy + r * 0.5), fill=hi)
    elif kind == "compass":
        ring(d, cx, cy, r, w, col)
        ticks(d, cx, cy, r * 0.82, 16, r * 0.12, col, max(1, w // 2))
        d.polygon([(cx, cy - r * 0.75), (cx + r * 0.16, cy), (cx, cy + r * 0.75), (cx - r * 0.16, cy)], outline=col)
        d.polygon([(cx, cy - r * 0.75), (cx + r * 0.16, cy), (cx - r * 0.16, cy)], fill=(220, 70, 50, 255))
    elif kind == "bubbles":
        d.rounded_rectangle((cx - r, cy - r * 0.8, cx + r * 0.35, cy + r * 0.15), radius=r * 0.25, outline=col, width=w)
        d.polygon([(cx - r * 0.6, cy + r * 0.12), (cx - r * 0.75, cy + r * 0.45), (cx - r * 0.35, cy + r * 0.12)], fill=col)
        d.rounded_rectangle((cx - r * 0.25, cy - r * 0.1, cx + r, cy + r * 0.75), radius=r * 0.25, outline=hi, width=w)
    elif kind == "coins":
        for i, (dx, dy) in enumerate(((-0.35, 0.25), (0.3, 0.3), (0, -0.25))):
            x, y = cx + dx * r, cy + dy * r
            d.ellipse((x - r * 0.5, y - r * 0.5, x + r * 0.5, y + r * 0.5), fill=(70, 50, 20, 255), outline=hi if i == 2 else col, width=w)
            ring(d, x, y, r * 0.34, max(1, w // 2), col)
    elif kind == "hammer":
        d.line((cx - r * 0.7, cy + r * 0.9, cx + r * 0.4, cy - r * 0.3), fill=col, width=w * 2)
        d.polygon([(cx + r * 0.05, cy - r * 0.65), (cx + r * 0.65, cy - r * 0.05), (cx + r * 0.95, cy - r * 0.35), (cx + r * 0.35, cy - r * 0.95)], fill=hi)
    elif kind == "bolt":
        d.polygon([(cx + r * 0.15, cy - r), (cx - r * 0.55, cy + r * 0.1), (cx - r * 0.05, cy + r * 0.1),
                   (cx - r * 0.2, cy + r), (cx + r * 0.6, cy - r * 0.15), (cx + r * 0.05, cy - r * 0.15)], fill=hi)
    elif kind == "scroll":
        d.rounded_rectangle((cx - r * 0.7, cy - r * 0.85, cx + r * 0.7, cy + r * 0.85), radius=r * 0.12, outline=col, width=w)
        for i in range(5):
            y = cy - r * 0.55 + i * r * 0.27
            d.line((cx - r * 0.45, y, cx + r * (0.45 if i % 2 == 0 else 0.15), y), fill=hi if i == 0 else col, width=w)
    elif kind == "gear":
        for i in range(8):
            a = 2 * math.pi * i / 8
            x, y = cx + math.cos(a) * r * 0.8, cy + math.sin(a) * r * 0.8
            d.rectangle((x - r * 0.14, y - r * 0.14, x + r * 0.14, y + r * 0.14), fill=col)
        d.ellipse((cx - r * 0.72, cy - r * 0.72, cx + r * 0.72, cy + r * 0.72), fill=(40, 34, 30, 255), outline=col, width=w)
        d.ellipse((cx - r * 0.28, cy - r * 0.28, cx + r * 0.28, cy + r * 0.28), outline=hi, width=w)
    elif kind == "plus":
        sparkle(d, cx, cy, r, hi, 0.18)
        d.rectangle((cx - r * 0.1, cy - r * 0.45, cx + r * 0.1, cy + r * 0.45), fill=(40, 26, 10, 255))
        d.rectangle((cx - r * 0.45, cy - r * 0.1, cx + r * 0.45, cy + r * 0.1), fill=(40, 26, 10, 255))


def category_banner(cid):
    col, kind = CATS[cid]
    W, H = 640 * S, 240 * S
    rnd = random.Random(sum(map(ord, cid)))
    img = sky(W, H, rnd.randrange(1000), [(0.7, 0.5, 0.4, col, 150), (0.2, 0.3, 0.3, (40, 30, 80), 90)], stars=220)
    cx, cy, r = W * 0.72, H * 0.5, 72 * S
    img.alpha_composite(glow((W, H), (cx, cy), r * 1.6, tuple(min(255, c + 60) for c in col), 120))
    rings, d = lay((W, H))
    ring(d, cx, cy, r * 1.45, 2 * S, GOLD_DK + (170,))
    ticks(d, cx, cy, r * 1.47, 36, 6 * S, GOLD_DK + (140,), 1.5 * S)
    img.alpha_composite(rings.filter(ImageFilter.GaussianBlur(0.5 * S)))
    g, d = lay((W, H))
    glyph(d, kind, cx, cy, r)
    shadow = g.copy().filter(ImageFilter.GaussianBlur(6 * S))
    img.alpha_composite(Image.eval(shadow, lambda v: v // 2))
    img.alpha_composite(g)
    return img.resize((640, 240), Image.LANCZOS)


def hero():
    W, H = 1600 * S, 460 * S
    img = sky(W, H, 41, [(0.5, 0.55, 0.34, (150, 100, 40), 110), (0.18, 0.35, 0.3, (60, 50, 150), 100),
                         (0.85, 0.6, 0.3, (40, 90, 140), 90)])
    cx, cy = W * 0.5, H * 0.62
    img.alpha_composite(glow((W, H), (cx, cy - 40 * S), 260 * S, (255, 190, 90), 110))
    a, d = lay((W, H))
    for r, wdt, al in ((150, 3, 220), (210, 2, 150), (280, 1.5, 100)):
        d.arc((cx - r * S * 1.6, cy - r * S * 0.55 - 60 * S, cx + r * S * 1.6, cy + r * S * 0.55 - 60 * S), 180, 360,
              fill=GOLD + (al,), width=int(wdt * S))
    img.alpha_composite(a.filter(ImageFilter.GaussianBlur(0.6 * S)))
    # the open book
    b, d = lay((W, H))
    for s in (-1, 1):
        pts = [(cx, cy + 40 * S), (cx + s * 230 * S, cy + 10 * S), (cx + s * 240 * S, cy + 110 * S), (cx, cy + 140 * S)]
        d.polygon(pts, fill=(36, 28, 22, 255), outline=GOLD + (255,))
        for i in range(5):
            y0 = cy + (45 + i * 17) * S
            d.line((cx + s * 30 * S, y0, cx + s * 200 * S, y0 - 14 * S + i * 2 * S), fill=GOLD_DK + (200,), width=int(2 * S))
    d.line((cx, cy + 40 * S, cx, cy + 140 * S), fill=GOLD_HI + (255,), width=int(3 * S))
    img.alpha_composite(b)
    img.alpha_composite(glow((W, H), (cx, cy + 40 * S), 70 * S, (255, 220, 140), 200))
    # orbiting addon tiles
    kinds = ["window", "swords", "quest", "bag", "compass", "bubbles", "coins", "hammer", "bolt", "gear", "skull", "scroll"]
    for i, kind in enumerate(kinds):
        t = math.pi * (1.06 + 0.88 * i / (len(kinds) - 1))
        rx, ry = 560 * S, 165 * S
        x, y = cx + math.cos(t) * rx, cy - 40 * S + math.sin(t) * ry
        size = (44 + 10 * math.sin(i * 1.7)) * S
        tile, d = lay((W, H))
        d.rounded_rectangle((x - size, y - size, x + size, y + size), radius=size * 0.22, fill=(18, 16, 26, 235),
                            outline=GOLD + (230,), width=int(2.5 * S))
        glyph(d, kind, x, y, size * 0.62)
        img.alpha_composite(glow((W, H), (x, y), size * 1.5, CATS["interface"][0] if i % 2 else (180, 130, 60), 90))
        img.alpha_composite(tile)
        dd = ImageDraw.Draw(img)
        dd.line((x, y + size, cx + (x - cx) * 0.25, cy + 40 * S), fill=GOLD_DK + (60,), width=int(1 * S))
    sp = ImageDraw.Draw(img)
    rnd = random.Random(7)
    for _ in range(90):
        x, y = rnd.uniform(0, W), rnd.uniform(0, H)
        sparkle(sp, x, y, rnd.uniform(2, 6) * S, (255, 226, 170, rnd.randrange(60, 200)))
    return img.resize((1600, 460), Image.LANCZOS)


SEALS = {
    "works": ((44, 150, 80), "check"),
    "partly": ((200, 140, 30), "half"),
    "needs": ((190, 50, 44), "bang"),
    "unknown": ((90, 92, 110), "q"),
    "ours": ((170, 120, 40), "plus"),
}


def seal(kind):
    col, g = SEALS[kind]
    W = 64 * 4
    im, d = lay((W, W))
    c = W / 2
    d.ellipse((6, 6, W - 6, W - 6), fill=GOLD_DK + (255,))
    d.ellipse((16, 16, W - 16, W - 16), fill=col + (255,))
    d.ellipse((16, 16, W - 16, W / 2), fill=tuple(min(255, v + 40) for v in col) + (90,))
    white = (255, 250, 236, 255)
    if g == "check":
        d.line([(c - 50, c + 2), (c - 14, c + 38), (c + 52, c - 40)], fill=white, width=26, joint="curve")
    elif g == "half":
        d.ellipse((c - 54, c - 54, c + 54, c + 54), outline=white, width=16)
        d.pieslice((c - 54, c - 54, c + 54, c + 54), 90, 270, fill=white)
    elif g == "bang":
        d.rounded_rectangle((c - 13, c - 70, c + 13, c + 18), radius=10, fill=white)
        d.ellipse((c - 15, c + 34, c + 15, c + 64), fill=white)
    elif g == "q":
        f = font(150, sans=True)
        d.text((c, c + 6), "?", font=f, fill=white, anchor="mm")
    elif g == "plus":
        sparkle(d, c, c, 80, white, 0.2)
    return im.resize((64, 64), Image.LANCZOS)


def star(fill):
    W = 32 * 4
    im, d = lay((W, W))
    c, R, r = W / 2, W * 0.46, W * 0.19
    pts = []
    for i in range(10):
        a = -math.pi / 2 + math.pi * i / 5
        rr = R if i % 2 == 0 else r
        pts.append((c + math.cos(a) * rr, c + 6 + math.sin(a) * rr))
    d.polygon(pts, fill=(40, 34, 28, 255), outline=GOLD_DK + (255,))
    if fill:
        mask, md = Image.new("L", (W, W), 0), None
        md = ImageDraw.Draw(mask)
        md.polygon(pts, fill=255)
        if fill == "half":
            md.rectangle((c, 0, W, W), fill=0)
        gold = Image.new("RGBA", (W, W), GOLD_HI + (255,))
        shade, sd = lay((W, W))
        sd.rectangle((0, c + 6, W, W), fill=GOLD_DK + (140,))
        gold.alpha_composite(shade)
        im.paste(gold, (0, 0), mask)
    ImageDraw.Draw(im).polygon(pts, outline=GOLD_DK + (255,))
    return im.resize((32, 32), Image.LANCZOS)


def collection(kind):
    W, H = 960 * S, 300 * S
    col = (120, 40, 110) if kind == "raiders" else (60, 70, 160)
    img = sky(W, H, 61 if kind == "raiders" else 62, [(0.5, 0.5, 0.4, col, 140), (0.15, 0.4, 0.3, (150, 100, 40), 80)])
    glyphs = ["skull", "swords", "coins", "scroll"] if kind == "raiders" else ["bubbles", "quest", "plus", "compass"]
    for i, g in enumerate(glyphs):
        x, y, r = W * (0.2 + 0.2 * i), H * 0.52, 58 * S
        img.alpha_composite(glow((W, H), (x, y), r * 1.5, (255, 190, 100), 70))
        t, d = lay((W, H))
        ring(d, x, y, r * 1.25, 2 * S, GOLD_DK + (200,))
        glyph(d, g, x, y, r * 0.8)
        img.alpha_composite(t)
    return img.resize((960, 300), Image.LANCZOS)


def creator_banner():
    W, H = 1600 * S, 300 * S
    img = sky(W, H, 77, [(0.3, 0.5, 0.35, (70, 60, 150), 110), (0.75, 0.45, 0.3, (150, 100, 40), 100)])
    a, d = lay((W, H))
    for i in range(7):
        x = W * (0.1 + i * 0.135)
        glyph(d, ["gear", "hammer", "scroll", "bolt", "window", "compass", "plus"][i], x, H * 0.55, 36 * S, GOLD_DK + (150,))
    img.alpha_composite(a.filter(ImageFilter.GaussianBlur(0.8 * S)))
    return img.resize((1600, 300), Image.LANCZOS)


def og(hero_img):
    im = Image.new("RGB", (1200, 630), (8, 8, 14))
    h = hero_img.resize((1200, 345), Image.LANCZOS)
    im.paste(h.convert("RGB"), (0, 60))
    d = ImageDraw.Draw(im)
    d.text((600, 470), "Open Vanilla Workshop", font=font(64), fill=GOLD, anchor="mm")
    d.text((600, 540), "Addons for vanilla 1.12, checked in the simulator", font=font(28, sans=True), fill=(220, 210, 190), anchor="mm")
    return im


def main(argv):
    os.makedirs(OUT, exist_ok=True)
    pieces = []
    h = hero()
    h.save(os.path.join(OUT, "hero_workshop.webp"), quality=86, method=6)
    pieces.append(("hero", h))
    for cid in CATS:
        im = category_banner(cid)
        im.save(os.path.join(OUT, f"cat_{cid}.webp"), quality=84, method=6)
        pieces.append((cid, im))
    for k in SEALS:
        im = seal(k)
        im.save(os.path.join(OUT, f"badge_{k}.webp"), lossless=True)
        pieces.append((k, im))
    for k in ("full", "half", "empty"):
        im = star(k if k != "empty" else None)
        im.save(os.path.join(OUT, f"star_{k}.png"), optimize=True)
        pieces.append(("star_" + k, im))
    for k in ("raiders", "roleplay"):
        im = collection(k)
        im.save(os.path.join(OUT, f"collection_{k}.webp"), quality=84, method=6)
        pieces.append((k, im))
    cb = creator_banner()
    cb.save(os.path.join(OUT, "creator_banner.webp"), quality=84, method=6)
    pieces.append(("creator", cb))
    og(h).save(os.path.join(OUT, "og_workshop.jpg"), quality=86)
    if "--sheet" in argv:
        artkit.sheet(pieces, argv[argv.index("--sheet") + 1])
    print("workshop art ->", OUT)


if __name__ == "__main__":
    main(sys.argv[1:])
