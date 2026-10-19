#!/usr/bin/env python3
"""Art for the armory pages (www/armory.html, www/armory/character.html): procedural PIL art in the
site's night-sky / gold style. Ours: no game textures.

    python3 tools/gen_armory_art.py               writes everything below into www/assets/armory/
    python3 tools/gen_armory_art.py --sheet X     also a contact sheet at X

  hero.webp            1600x360  the armory banner: an open ledger under a gold arch, starfield, sparks
  paperdoll.webp        480x600  the paper doll's centre: a stone niche with a gold-rimmed arch, a rune
                                 circle at the feet and a faint standing figure (the gear goes around it)
  slot.png               64x64   an item slot frame: bevelled gold rim, dark inset (quality glow is CSS)
  slot_empty.png         64x64   the same frame, emptier and dimmer, with a faint diamond
  banner_<class>.png    160x240  one swallow-tailed banner per class in the game's class colour with a
                                 simple original emblem (crossed blades, hammer, bow, dagger, star, bolt,
                                 rune star, flame, leaf): WARRIOR PALADIN HUNTER ROGUE PRIEST SHAMAN MAGE
                                 WARLOCK DRUID
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "www", "assets", "armory")
S = 4                                    # supersampling
GOLD = (232, 188, 84)
GOLD_HI = (255, 232, 160)
GOLD_DK = (128, 90, 34)
INK = (7, 9, 14)
CLASSES = {  # the game's class colours
    "WARRIOR": (199, 156, 110), "PALADIN": (245, 140, 186), "HUNTER": (171, 212, 115), "ROGUE": (255, 245, 105),
    "PRIEST": (240, 240, 240), "SHAMAN": (0, 112, 222), "MAGE": (105, 204, 240), "WARLOCK": (148, 130, 201),
    "DRUID": (255, 125, 10),
}


def U(v):
    return int(round(v * S))


def P(pts):
    return [(U(x), U(y)) for x, y in pts]


def vgrad(w, h, top, bottom):
    g = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    return g.resize((w, h))


def radial(w, h, cx, cy, r, rgb, alpha):
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    steps = 40
    for i in range(steps, 0, -1):
        rr = r * i / steps
        d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=int(alpha * (1 - i / steps) ** 1.4))
    layer = Image.new("RGBA", (w, h), rgb + (0,))
    layer.putalpha(m)
    return layer


def stars(img, n, seed, area=None):
    rnd = random.Random(seed)
    d = ImageDraw.Draw(img)
    w, h = img.size
    x0, y0, x1, y1 = area or (0, 0, w, h)
    for _ in range(n):
        x, y = rnd.uniform(x0, x1), rnd.uniform(y0, y1)
        r = rnd.choice([0.6, 0.8, 1.0, 1.4]) * S
        a = rnd.randint(70, 220)
        d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 246, 220, a))


def gold_stroke(img, draw_fn, width):
    """Draw a shape twice: a dark under-stroke and a gold top stroke with a lighter inner line."""
    for col, wd in ((GOLD_DK + (255,), width + 2), (GOLD + (255,), width), (GOLD_HI + (200,), max(1, width // 3))):
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        draw_fn(ImageDraw.Draw(layer), col, U(wd))
        img.alpha_composite(layer)


def down(img, size):
    return img.resize(size, Image.LANCZOS)


def save(img, name, size, **kw):
    os.makedirs(OUT, exist_ok=True)
    out = down(img, size)
    path = os.path.join(OUT, name)
    if name.endswith(".webp"):
        out.convert("RGB").save(path, "WEBP", quality=82, method=6)
    else:
        out.save(path, optimize=True)
    return out


# ---- pieces ------------------------------------------------------------------------------------

def hero():
    w, h = 1600, 360
    img = vgrad(U(w), U(h), (10, 13, 26), (4, 6, 10))
    img.alpha_composite(radial(U(w), U(h), U(800), U(330), U(620), (240, 192, 88), 70))
    stars(img, 380, 11)
    d = ImageDraw.Draw(img)
    # the arch
    gold_stroke(img, lambda dd, c, wd: dd.arc((U(560), U(40), U(1040), U(520)), 180, 360, fill=c, width=wd), 5)
    gold_stroke(img, lambda dd, c, wd: dd.arc((U(590), U(70), U(1010), U(490)), 180, 360, fill=c, width=wd), 2)
    for x in (560, 1040):
        gold_stroke(img, lambda dd, c, wd, x=x: dd.line((U(x), U(280), U(x), U(360)), fill=c, width=wd), 5)
    # an open ledger
    page = (226, 214, 184, 255)
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon(P([(640, 300), (800, 318), (960, 300), (960, 330), (800, 348), (640, 330)]), fill=(0, 0, 0, 160))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(U(6))))
    d.polygon(P([(650, 220), (796, 236), (796, 330), (650, 314)]), fill=page)
    d.polygon(P([(804, 236), (950, 220), (950, 314), (804, 330)]), fill=page)
    d.polygon(P([(796, 236), (804, 236), (804, 330), (796, 330)]), fill=(150, 120, 80, 255))
    for i in range(7):
        y = 248 + i * 10
        d.line(P([(666, y - 1 + i * 0.4), (780, y + 12 + i * 0.4)]), fill=(120, 104, 80, 200), width=U(1.4))
        d.line(P([(820, y + 12 + i * 0.4), (934, y - 1 + i * 0.4)]), fill=(120, 104, 80, 200), width=U(1.4))
    # a quill
    d.polygon(P([(900, 150), (940, 120), (884, 236), (878, 232)]), fill=(240, 236, 226, 255))
    d.line(P([(938, 122), (876, 240)]), fill=(150, 140, 120, 255), width=U(1.5))
    # sparks rising
    rnd = random.Random(5)
    for _ in range(70):
        x = rnd.gauss(800, 160)
        y = rnd.uniform(40, 230)
        r = rnd.uniform(0.8, 2.4)
        img.alpha_composite(radial(U(w), U(h), U(x), U(y), U(r * 4), (255, 214, 120), rnd.randint(120, 230)))
    return save(img, "hero.webp", (w, h))


def figure_mask(w, h):
    m = Image.new("L", (U(w), U(h)), 0)
    d = ImageDraw.Draw(m)
    cx = w / 2
    d.ellipse((U(cx - 30), U(120), U(cx + 30), U(186)), fill=255)                                  # head
    d.polygon(P([(cx - 70, 200), (cx + 70, 200), (cx + 58, 330), (cx + 40, 340), (cx - 40, 340), (cx - 58, 330)]), fill=255)
    d.polygon(P([(cx - 70, 202), (cx - 98, 330), (cx - 80, 336), (cx - 54, 230)]), fill=255)       # arms
    d.polygon(P([(cx + 70, 202), (cx + 98, 330), (cx + 80, 336), (cx + 54, 230)]), fill=255)
    d.polygon(P([(cx - 40, 336), (cx - 6, 336), (cx - 14, 500), (cx - 38, 500)]), fill=255)         # legs
    d.polygon(P([(cx + 6, 336), (cx + 40, 336), (cx + 38, 500), (cx + 14, 500)]), fill=255)
    return m.filter(ImageFilter.GaussianBlur(U(2)))


def paperdoll():
    w, h = 480, 600
    img = vgrad(U(w), U(h), (20, 24, 36), (8, 10, 16))
    # stone niche
    niche = Image.new("L", img.size, 0)
    ImageDraw.Draw(niche).rounded_rectangle((U(40), U(40), U(w - 40), U(h - 30)), radius=U(200), fill=255)
    inner = vgrad(U(w), U(h), (30, 34, 50), (12, 14, 22))
    img.paste(inner, (0, 0), niche)
    img.alpha_composite(radial(U(w), U(h), U(w / 2), U(250), U(230), (240, 192, 88), 46))
    stars(img, 60, 23, (U(60), U(60), U(w - 60), U(300)))
    gold_stroke(img, lambda dd, c, wd: dd.rounded_rectangle((U(40), U(40), U(w - 40), U(h - 30)), radius=U(200), outline=c, width=wd), 3)
    gold_stroke(img, lambda dd, c, wd: dd.rounded_rectangle((U(52), U(52), U(w - 52), U(h - 42)), radius=U(190), outline=c, width=wd), 1)
    # rune circle at the feet
    cx, cy = w / 2, 512
    gold_stroke(img, lambda dd, c, wd: dd.ellipse((U(cx - 130), U(cy - 26), U(cx + 130), U(cy + 26)), outline=c, width=wd), 2)
    gold_stroke(img, lambda dd, c, wd: dd.ellipse((U(cx - 108), U(cy - 18), U(cx + 108), U(cy + 18)), outline=c, width=wd), 1)
    d = ImageDraw.Draw(img)
    for i in range(16):
        a = 2 * math.pi * i / 16
        x, y = cx + math.cos(a) * 119, cy + math.sin(a) * 22
        d.line(P([(x, y - 3), (x + 2, y + 3)]), fill=GOLD_HI + (220,), width=U(1.2))
    img.alpha_composite(radial(U(w), U(h), U(cx), U(cy), U(150), (255, 210, 120), 60))
    # faint figure
    fig = Image.new("RGBA", img.size, (140, 160, 200, 0))
    fig.putalpha(figure_mask(w, h).point(lambda v: v * 46 // 255))
    img.alpha_composite(fig)
    edge = figure_mask(w, h).filter(ImageFilter.FIND_EDGES).filter(ImageFilter.GaussianBlur(U(0.8)))
    glow = Image.new("RGBA", img.size, (200, 220, 255, 0))
    glow.putalpha(edge.point(lambda v: min(255, v * 2)))
    img.alpha_composite(glow)
    return save(img, "paperdoll.webp", (w, h))


def slot(empty=False):
    n = 64
    img = Image.new("RGBA", (U(n), U(n)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((U(1), U(1), U(n - 1), U(n - 1)), radius=U(7), fill=GOLD_DK + (255,))
    rim = vgrad(U(n), U(n), GOLD_HI, (150, 104, 36))
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((U(2), U(2), U(n - 2), U(n - 2)), radius=U(6), fill=255)
    ImageDraw.Draw(m).rounded_rectangle((U(6), U(6), U(n - 6), U(n - 6)), radius=U(4), fill=0)
    img.paste(rim, (0, 0), m)
    well = vgrad(U(n), U(n), (26, 30, 44) if not empty else (16, 18, 26), (8, 10, 16))
    m2 = Image.new("L", img.size, 0)
    ImageDraw.Draw(m2).rounded_rectangle((U(6), U(6), U(n - 6), U(n - 6)), radius=U(4), fill=255)
    img.paste(well, (0, 0), m2)
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((U(6), U(6), U(n - 6), U(16)), radius=U(4), fill=(0, 0, 0, 120))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(U(2))))
    for x, y in ((4, 4), (n - 4, 4), (4, n - 4), (n - 4, n - 4)):      # corner studs
        d.ellipse((U(x - 2.2), U(y - 2.2), U(x + 2.2), U(y + 2.2)), fill=GOLD_HI + (255,))
    if empty:
        dd = ImageDraw.Draw(img)
        c = n / 2
        dd.polygon(P([(c, c - 10), (c + 10, c), (c, c + 10), (c - 10, c)]), outline=(120, 110, 90, 130), width=U(1.5))
    return save(img, "slot_empty.png" if empty else "slot.png", (n, n))


def emblem(d, cls, cx, cy, col):
    """Simple original emblems, drawn in `col` around (cx, cy) in 1x units."""
    w = U(5)
    if cls == "WARRIOR":       # crossed blades
        for s in (1, -1):
            d.line(P([(cx - 34 * s, cy - 40), (cx + 30 * s, cy + 34)]), fill=col, width=w)
            d.line(P([(cx + 18 * s, cy + 16), (cx + 34 * s, cy + 6)]), fill=col, width=w)
    elif cls == "PALADIN":     # hammer
        d.rectangle(P([(cx - 30, cy - 40), (cx + 30, cy - 12)]), fill=col)
        d.line(P([(cx, cy - 12), (cx, cy + 42)]), fill=col, width=U(7))
    elif cls == "HUNTER":      # bow and arrow
        d.arc(P([(cx - 46, cy - 46), (cx + 10, cy + 46)])[0] + P([(cx + 10, cy + 46)])[0], 285, 75, fill=col, width=w)
        d.line(P([(cx - 8, cy - 44), (cx - 8, cy + 44)]), fill=col, width=U(2))
        d.line(P([(cx - 30, cy), (cx + 40, cy)]), fill=col, width=U(4))
        d.polygon(P([(cx + 46, cy), (cx + 32, cy - 9), (cx + 32, cy + 9)]), fill=col)
    elif cls == "ROGUE":       # dagger
        d.polygon(P([(cx, cy - 46), (cx + 9, cy + 8), (cx - 9, cy + 8)]), fill=col)
        d.rectangle(P([(cx - 24, cy + 8), (cx + 24, cy + 16)]), fill=col)
        d.rectangle(P([(cx - 5, cy + 16), (cx + 5, cy + 42)]), fill=col)
    elif cls == "PRIEST":      # eight-rayed star in a ring
        d.ellipse(P([(cx - 40, cy - 40), (cx + 40, cy + 40)]), outline=col, width=U(4))
        for i in range(8):
            a = math.pi * i / 4
            d.line(P([(cx, cy), (cx + math.cos(a) * (30 if i % 2 else 22), cy + math.sin(a) * (30 if i % 2 else 22))]), fill=col, width=U(5))
    elif cls == "SHAMAN":      # lightning bolt
        d.polygon(P([(cx + 8, cy - 48), (cx - 26, cy + 4), (cx - 2, cy + 4), (cx - 12, cy + 48), (cx + 26, cy - 8), (cx + 2, cy - 8)]), fill=col)
    elif cls == "MAGE":        # rune star
        pts = []
        for i in range(16):
            a = math.pi * i / 8 - math.pi / 2
            r = 44 if i % 2 == 0 else 16
            pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
        d.polygon(P(pts), fill=col)
    elif cls == "WARLOCK":     # flame with an eye
        d.polygon(P([(cx, cy - 48), (cx + 30, cy + 4), (cx + 22, cy + 40), (cx - 22, cy + 40), (cx - 30, cy + 4)]), fill=col)
        d.ellipse(P([(cx - 12, cy + 4), (cx + 12, cy + 22)]), fill=(20, 12, 30, 255))
    elif cls == "DRUID":       # leaf
        d.chord(P([(cx - 46, cy - 40), (cx + 34, cy + 40)])[0] + P([(cx + 34, cy + 40)])[0], 300, 120, fill=col)
        d.chord(P([(cx - 34, cy - 40), (cx + 46, cy + 40)])[0] + P([(cx + 46, cy + 40)])[0], 120, 300, fill=col)
        d.line(P([(cx - 30, cy + 40), (cx + 28, cy - 36)]), fill=(30, 40, 20, 255), width=U(3))


def banner(cls, rgb):
    w, h = 160, 240
    img = Image.new("RGBA", (U(w), U(h)), (0, 0, 0, 0))
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).polygon(P([(20, 14), (140, 14), (140, 226), (80, 192), (20, 226)]), fill=255)
    dark = tuple(int(c * 0.35) for c in rgb)
    mid = tuple(int(c * 0.62) for c in rgb)
    cloth = vgrad(U(w), U(h), mid, dark)
    # folds
    fold = Image.new("RGBA", img.size, (0, 0, 0, 0))
    fd = ImageDraw.Draw(fold)
    for x in (52, 108):
        fd.line(P([(x, 18), (x, 210)]), fill=(255, 255, 255, 26), width=U(10))
        fd.line(P([(x + 8, 18), (x + 8, 210)]), fill=(0, 0, 0, 40), width=U(8))
    cloth.alpha_composite(fold.filter(ImageFilter.GaussianBlur(U(5))))
    img.paste(cloth, (0, 0), m)
    gold_stroke(img, lambda dd, c, wd: dd.polygon(P([(24, 18), (136, 18), (136, 220), (80, 188), (24, 220)]), outline=c, width=wd), 2)
    gold_stroke(img, lambda dd, c, wd: dd.line(P([(8, 12), (152, 12)]), fill=c, width=wd), 4)   # the pole
    d = ImageDraw.Draw(img)
    for x in (8, 152):
        d.ellipse(P([(x - 6, 6), (x + 6, 18)]), fill=GOLD_HI + (255,))
    # emblem in a gold roundel
    cx, cy = 80, 98
    d.ellipse(P([(cx - 54, cy - 54), (cx + 54, cy + 54)]), fill=(10, 12, 18, 200))
    gold_stroke(img, lambda dd, c, wd: dd.ellipse(P([(cx - 54, cy - 54), (cx + 54, cy + 54)]), outline=c, width=wd), 2)
    em = Image.new("RGBA", img.size, (0, 0, 0, 0))
    emblem(ImageDraw.Draw(em), cls, cx, cy, tuple(min(255, int(c * 0.6 + 110)) for c in rgb) + (255,))
    img.alpha_composite(em.filter(ImageFilter.GaussianBlur(U(0.3))))
    return save(img, f"banner_{cls.lower()}.png", (w, h))


def main(argv):
    pieces = [("hero", hero()), ("paperdoll", paperdoll()), ("slot", slot()), ("slot_empty", slot(True))]
    for cls, rgb in CLASSES.items():
        pieces.append((cls, banner(cls, rgb)))
    if "--sheet" in argv:
        path = argv[argv.index("--sheet") + 1]
        thumbs = [im if im.width <= 480 else im.resize((480, im.height * 480 // im.width)) for _, im in pieces]
        wsum = sum(t.width for t in thumbs) + 10 * (len(thumbs) + 1)
        sheet = Image.new("RGBA", (wsum, max(t.height for t in thumbs) + 20), (30, 31, 36, 255))
        x = 10
        for t in thumbs:
            sheet.alpha_composite(t.convert("RGBA"), (x, 10))
            x += t.width + 10
        sheet.save(path)
    print(f"armory art written to {OUT}")


if __name__ == "__main__":
    main(sys.argv[1:])
