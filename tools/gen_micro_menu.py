#!/usr/bin/env python3
"""The emblems on the menu bar's new buttons.

    py -3 tools/gen_micro_menu.py [repo] [--preview out.png]

The button itself is the client's own empty micro button (Interface\\Buttons\\UI-MicroButtonCharacter
-Up/-Down, the frame the Character button draws its portrait in), so the new buttons match the stock
ones exactly and nothing of Blizzard's ships with us. On it MicroMenu.lua lays one of these:
Data/Interface/AddOns/WenillaCore/Media/Micro<Name>.tga, a 32x64 transparent texture with the
emblem in the button's face (x 5-27, y 28-58, the same place as the stock emblems), drawn here from
shapes, so it is ours to ship. Emblems are painted the way the stock ones are: solid, high
contrast, lit from the top left, with a dark rim so they read on the dark face.

Written for Professions, Achievements, GroupFinder, Collections and AdventureGuide (and, when
tools/png_to_blp.py is there, the same as BLP in Data/Interface/ClassicPlus).
"""
import math
import os
import struct
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 16                                     # supersampling
W, H = 32 * S, 64 * S
KINDS = ("Professions", "Achievements", "GroupFinder", "Collections", "AdventureGuide")


def save_tga(img, path):
    """32-bit BGRA, bottom-up rows: what the 1.12 client reads."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    rows = []
    for y in range(h - 1, -1, -1):
        rows.append(bytes(b for x in range(w) for b in (px[x, y][2], px[x, y][1], px[x, y][0], px[x, y][3])))
    with open(path, "wb") as f:
        f.write(struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8))
        f.write(b"".join(rows))


def P(x, y):
    """Button pixels (32x64 texture space) to canvas pixels."""
    return (x * S, y * S)


def pts(lst):
    return [P(x, y) for x, y in lst]


class Layer:
    """The emblem being painted: shapes filled with a top-lit ramp, then details on top."""

    def __init__(self):
        self.img = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    def shape(self, draw_fn, top, bottom, y0, y1):
        mask = Image.new("L", (W, H), 0)
        draw_fn(ImageDraw.Draw(mask))
        grad = Image.new("RGBA", (W, H))
        gd = ImageDraw.Draw(grad)
        a, b = y0 * S, y1 * S
        for y in range(H):
            t = 0 if y <= a else 1 if y >= b else (y - a) / (b - a)
            c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
            gd.line([(0, y), (W, y)], fill=c)
        self.img.paste(grad, (0, 0), mask)

    def detail(self, draw_fn):
        draw_fn(ImageDraw.Draw(self.img))


def finish(layer, rim=1.15):
    """A dark rim around the emblem (like the stock ones' painted edge), then down to 32x64."""
    a = layer.img.split()[3]
    grow = a.filter(ImageFilter.MaxFilter(int(rim * S) | 1))
    rimimg = Image.new("RGBA", (W, H), (6, 5, 4, 0))
    rimimg.putalpha(grow.point(lambda v: int(v * 0.92)))
    out = Image.alpha_composite(rimimg, layer.img)
    # leave the face a margin all round, as the stock emblems do: 88% about the face's centre
    k, cx, cy = 0.88, 16 * S, 43.5 * S
    shrunk = out.resize((int(W * k), int(H * k)), Image.LANCZOS)
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.alpha_composite(shrunk, (int(cx - cx * k), int(cy - cy * k)))
    small = out.resize((32, 64), Image.LANCZOS)
    return small.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=1))


# -- emblems: everything inside x 5..27, y 28..58 -------------------------------------------------

def professions():
    L = Layer()
    # anvil: horn left, face, waist, foot
    anvil = [(5.5, 41), (10, 40), (26.5, 40), (26.5, 44.5), (22, 45), (19.5, 48), (19.5, 51), (24, 53), (24, 56.5),
             (8, 56.5), (8, 53), (12.5, 51), (12.5, 48), (10, 45), (8, 44), (5.5, 42.5)]
    L.shape(lambda d: d.polygon(pts(anvil), fill=255), (200, 206, 214), (70, 74, 84), 40, 57)
    L.detail(lambda d: d.polygon(pts([(5.5, 41), (10, 40), (26.5, 40), (26.5, 41.6), (10, 41.6), (6, 42.2)]), fill=(236, 240, 246, 255)))
    L.detail(lambda d: d.line(pts([(12.6, 48.5), (19.4, 48.5)]), fill=(48, 50, 58, 255), width=S))
    # hammer: handle, then head, angled over the anvil
    L.shape(lambda d: d.line(pts([(10, 38.8), (20.5, 31.5)]), fill=255, width=int(2.4 * S)), (196, 140, 76), (110, 66, 30), 31, 39)
    head = [(17, 31.2), (21.6, 28.6), (25.6, 34.2), (21, 36.8)]
    L.shape(lambda d: d.polygon(pts(head), fill=255), (226, 230, 238), (96, 100, 112), 28.5, 36.8)
    L.detail(lambda d: d.line(pts([(17.5, 31.3), (21.5, 29.1)]), fill=(250, 252, 255, 255), width=int(0.8 * S)))
    # sparks off the strike
    for x, y, r in ((8, 36, 1.0), (6.5, 38.3, 0.75), (11, 34.3, 0.65)):
        L.detail(lambda d, x=x, y=y, r=r: d.ellipse((P(x - r, y - r), P(x + r, y + r)), fill=(255, 200, 80, 255)))
    return finish(L)


def achievements():
    L = Layer()
    shield = [(16, 28.5), (26.5, 32), (25.5, 45), (16, 57.5), (6.5, 45), (5.5, 32)]
    L.shape(lambda d: d.polygon(pts(shield), fill=255), (255, 226, 120), (170, 112, 30), 28, 57)
    inner = [(16, 31), (24, 33.8), (23.2, 44.4), (16, 54.2), (8.8, 44.4), (8, 33.8)]
    L.shape(lambda d: d.polygon(pts(inner), fill=255), (196, 46, 34), (96, 16, 12), 31, 54)
    L.detail(lambda d: d.line(pts([(16, 28.9), (26.1, 32.3)]), fill=(255, 246, 200, 255), width=int(0.8 * S)))
    cx, cy, R, r = 16, 42, 6.2, 2.6
    star = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = R if i % 2 == 0 else r
        star.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    L.shape(lambda d: d.polygon(pts(star), fill=255), (255, 248, 196), (236, 180, 60), 36, 48)
    return finish(L)


def group_finder():
    L = Layer()
    almond = []
    for i in range(41):
        t = math.pi * i / 40
        almond.append((16 - 11 * math.cos(t), 43 - 7.6 * math.sin(t)))
    for i in range(41):
        t = math.pi * i / 40
        almond.append((16 + 11 * math.cos(t), 43 + 7.6 * math.sin(t)))
    L.shape(lambda d: d.polygon(pts(almond), fill=255), (250, 252, 255), (178, 188, 204), 35, 51)
    L.shape(lambda d: d.ellipse((P(10.2, 37.2), P(21.8, 48.8)), fill=255), (110, 210, 255), (20, 90, 170), 37, 49)
    L.detail(lambda d: d.ellipse((P(13.2, 40.2), P(18.8, 45.8)), fill=(8, 12, 20, 255)))
    L.detail(lambda d: d.ellipse((P(16.4, 38.8), P(19.2, 41.6)), fill=(255, 255, 255, 240)))
    L.detail(lambda d: d.line(pts([(5, 43), (9, 38.4), (16, 35.4), (23, 38.4), (27, 43)]), fill=(30, 26, 22, 255),
                              width=int(1.2 * S), joint="curve"))
    return finish(L)


def collections():
    L = Layer()
    # a horse's head in profile, facing left, the neck going down off the face's foot
    head = [(17, 30.5), (14.5, 33), (11.5, 38), (8.5, 43), (6.2, 46.5), (6, 49), (7.5, 51), (10, 51.2), (12.5, 49.8),
            (14.5, 49.2), (17, 50.5), (19, 53), (19.5, 57), (27, 57), (26.5, 50), (25, 43), (22.5, 37), (20, 32.5)]
    # the far ear behind, then the head, then the near ear
    L.shape(lambda d: d.polygon(pts([(18.6, 31.8), (20.4, 28.4), (21.4, 32.8)]), fill=255), (150, 96, 50), (96, 56, 24), 28.4, 33)
    L.shape(lambda d: d.polygon(pts(head), fill=255), (220, 160, 98), (120, 70, 32), 30, 56)
    L.shape(lambda d: d.polygon(pts([(15.6, 31.6), (16.4, 28.2), (18.8, 31.4)]), fill=255), (226, 170, 108), (150, 96, 50), 28.2, 31.6)
    # mane along the crest of the neck, a forelock between the ears
    mane = [(20, 32.5), (22.5, 33.2), (25.6, 37.6), (28, 44), (28.4, 57), (27, 57), (26.5, 50), (25, 43), (22.5, 37)]
    L.shape(lambda d: d.polygon(pts(mane), fill=255), (84, 52, 28), (36, 22, 10), 32, 57)
    L.detail(lambda d: d.polygon(pts([(16.6, 31), (19.6, 31.6), (16.2, 35.4), (14.8, 34)]), fill=(70, 42, 22, 255)))
    # cheek and jaw, muzzle, nostril, eye with its glint, a white blaze
    L.detail(lambda d: d.arc((P(12.2, 41.6), P(19.8, 50.6)), 150, 330, fill=(110, 64, 30, 255), width=int(0.8 * S)))
    L.detail(lambda d: d.polygon(pts([(8.5, 43), (6.2, 46.5), (6, 49), (7.5, 51), (10, 51.2), (11, 47.5), (10.4, 44)]), fill=(150, 98, 60, 255)))
    L.detail(lambda d: d.ellipse((P(6.8, 46.8), P(8.4, 48.4)), fill=(28, 16, 8, 255)))
    L.detail(lambda d: d.ellipse((P(13, 36.4), P(15.4, 38.8)), fill=(16, 10, 6, 255)))
    L.detail(lambda d: d.ellipse((P(13.4, 36.8), P(14.2, 37.6)), fill=(255, 255, 255, 230)))
    L.detail(lambda d: d.polygon(pts([(13.8, 34.4), (14.8, 34.8), (9.8, 44.2), (8.8, 43.8)]), fill=(246, 236, 220, 255)))
    # a gold bridle: cheek piece and noseband, a stud where they meet
    gold = (236, 190, 72, 255)
    L.detail(lambda d: d.line(pts([(17.8, 33.2), (12.6, 45.4)]), fill=gold, width=int(1.1 * S)))
    L.detail(lambda d: d.line(pts([(8.8, 44.2), (13.4, 46.4)]), fill=gold, width=int(1.1 * S)))
    L.detail(lambda d: d.ellipse((P(11.8, 44.4), P(14, 46.6)), fill=(255, 230, 130, 255)))
    return finish(L)


def adventure_guide():
    L = Layer()
    cover = [(4.8, 33.5), (16, 36), (27.2, 33.5), (27.2, 53.5), (16, 56.5), (4.8, 53.5)]
    L.shape(lambda d: d.polygon(pts(cover), fill=255), (132, 74, 34), (66, 32, 12), 33, 56)
    left = [(6.2, 31.5), (15.6, 34), (15.6, 53.6), (6.2, 51.4)]
    right = [(16.4, 34), (25.8, 31.5), (25.8, 51.4), (16.4, 53.6)]
    L.shape(lambda d: d.polygon(pts(left), fill=255), (252, 244, 220), (206, 190, 150), 31, 54)
    L.shape(lambda d: d.polygon(pts(right), fill=255), (238, 226, 196), (184, 166, 124), 31, 54)
    for k in range(5):                     # lines of text
        y = 37 + k * 2.8
        L.detail(lambda d, y=y: d.line(pts([(8, y), (14, y + 1.5)]), fill=(118, 96, 70, 255), width=int(0.7 * S)))
        if k < 3:
            L.detail(lambda d, y=y: d.line(pts([(18, y + 1.5), (24, y)]), fill=(118, 96, 70, 255), width=int(0.7 * S)))
    L.detail(lambda d: d.line(pts([(16, 34), (16, 53.8)]), fill=(90, 60, 30, 255), width=int(0.9 * S)))
    L.shape(lambda d: d.polygon(pts([(20.5, 31), (23, 30.5), (23, 46), (21.75, 44.2), (20.5, 46)]), fill=255),
            (226, 52, 44), (130, 18, 16), 30, 46)
    return finish(L)


DRAW = {"Professions": professions, "Achievements": achievements, "GroupFinder": group_finder,
        "Collections": collections, "AdventureGuide": adventure_guide}


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--preview" in sys.argv:
        args = [a for a in args if a != sys.argv[sys.argv.index("--preview") + 1]]
    out = args[0] if args else ROOT
    media = os.path.join(out, "Data", "Interface", "AddOns", "WenillaCore", "Media")
    cpart = os.path.join(out, "Data", "Interface", "ClassicPlus")
    os.makedirs(media, exist_ok=True)
    blp = os.path.join(ROOT, "tools", "png_to_blp.py")
    imgs = {}
    for kind in KINDS:
        name = "Micro" + kind
        im = DRAW[kind]()
        imgs[kind] = im
        save_tga(im, os.path.join(media, name + ".tga"))
        old = os.path.join(media, name + "Down.tga")      # the pushed look is now the stock frame's
        if os.path.exists(old):
            os.remove(old)
        if os.path.exists(blp) and os.path.isdir(cpart):
            png = os.path.join(media, name + ".png")
            im.save(png)
            subprocess.run([sys.executable, blp, png, os.path.join(cpart, name + ".blp")], check=True)
            os.remove(png)
        print("wrote", name)
    if "--preview" in sys.argv:
        dst = sys.argv[sys.argv.index("--preview") + 1]
        frame = None
        for cand in ("Data/Interface/Buttons/UI-MicroButtonCharacter-Up.blp", "Data/Interface/buttons/ui-microbuttoncharacter-up.blp"):
            p = os.path.join(out, cand)
            if os.path.exists(p):
                frame = Image.open(p).convert("RGBA")
        sheet = Image.new("RGBA", (32 * len(KINDS), 64), (28, 28, 28, 255))
        for i, k in enumerate(KINDS):
            if frame:
                sheet.alpha_composite(frame, (32 * i, 0))
            sheet.alpha_composite(imgs[k], (32 * i, 0))
        sheet.resize((sheet.width * 8, sheet.height * 8), Image.NEAREST).save(dst)
