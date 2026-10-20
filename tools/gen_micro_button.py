#!/usr/bin/env python3
"""The Classic+ menu-bar button (up and pushed), sized like the stock micro buttons (32x64 texture,
the face in the lower 42 px).

    py -3 tools/gen_micro_button.py

Writes Data/Interface/ClassicPlus/MicroClassicPlus.blp and MicroClassicPlusDown.blp (+ TGA copies
in WenillaCore/Media); pack with tools/sync_patchz.py.
"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 8


def star(d, cx, cy, r, fill):
    w = r * .28
    d.polygon([(cx, cy - r), (cx + w, cy - w), (cx + r, cy), (cx + w, cy + w), (cx, cy + r), (cx - w, cy + w), (cx - r, cy), (cx - w, cy - w)], fill=fill)


def face(pushed):
    W, H = 32 * S, 64 * S
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = 2 * S, 22 * S, 30 * S, 62 * S
    off = 1 * S if pushed else 0
    # dark stone frame with a bevel, like the stock buttons
    d.rounded_rectangle((x0, y0, x1, y1), radius=3 * S, fill=(20, 18, 16, 255))
    d.rounded_rectangle((x0 + S, y0 + S, x1 - S, y1 - S), radius=2 * S, fill=(58, 52, 44, 255))
    d.rounded_rectangle((x0 + 2 * S, y0 + 2 * S, x1 - 2 * S, y1 - 2 * S), radius=2 * S, fill=(14, 16, 26, 255))
    # the emblem: a gold-rimmed violet gem with a green plus and a star
    cx, cy, r = 16 * S + off, 42 * S + off, 10.5 * S
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((cx - r * 1.3, cy - r * 1.3, cx + r * 1.3, cy + r * 1.3), fill=(120, 80, 220, 120))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(3 * S)))
    d = ImageDraw.Draw(img)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(214, 170, 74, 255))
    d.ellipse((cx - r * .82, cy - r * .82, cx + r * .82, cy + r * .82), fill=(52, 34, 110, 255))
    inner = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(inner).ellipse((cx - r * .6, cy - r * .75, cx + r * .4, cy + r * .2), fill=(140, 90, 230, 170))
    img.alpha_composite(inner.filter(ImageFilter.GaussianBlur(2 * S)))
    d = ImageDraw.Draw(img)
    t = r * .2
    d.rectangle((cx - t, cy - r * .55, cx + t, cy + r * .55), fill=(70, 230, 90, 255))
    d.rectangle((cx - r * .55, cy - t, cx + r * .55, cy + t), fill=(70, 230, 90, 255))
    star(d, cx + r * .58, cy - r * .58, r * .32, (255, 245, 210, 255))
    if pushed:
        shade = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(shade).rounded_rectangle((x0, y0, x1, y1), radius=3 * S, fill=(0, 0, 0, 70))
        img.alpha_composite(shade)
    return img.resize((32, 64), Image.LANCZOS)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else ROOT
    cpart = os.path.join(out, "Data", "Interface", "ClassicPlus")
    media = os.path.join(out, "Data", "Interface", "AddOns", "WenillaCore", "Media")
    os.makedirs(cpart, exist_ok=True)
    os.makedirs(media, exist_ok=True)
    for name, pushed in (("MicroClassicPlus", False), ("MicroClassicPlusDown", True)):
        im = face(pushed)
        png = os.path.join(media, name + ".png")
        im.save(png)
        im.save(os.path.join(media, name + ".tga"))
        os.remove(png) if False else None
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "png_to_blp.py"), png, os.path.join(cpart, name + ".blp")], check=True)
        os.remove(png)
        print("wrote", name)
