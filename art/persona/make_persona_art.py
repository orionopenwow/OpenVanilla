#!/usr/bin/env python3
"""Persona (Classic+ roleplay profiles) in-game art.

    py -3 art/persona/make_persona_art.py

Writes each texture twice, like the rest of the Classic+ art (see W:Art in WenillaCore.lua):
  Data/Interface/AddOns/WenillaCore/Media/Persona_*.tga   (1.12 client, loose addon art)
  Data/Interface/ClassicPlus/Persona_*.blp                (web client, streamed from patch-Z)
and a contact sheet at art/persona/preview.png.
"""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "art"))
from blp import write_blp  # noqa: E402

TGA_DIR = os.path.join(ROOT, "Data", "Interface", "AddOns", "WenillaCore", "Media")
BLP_DIR = os.path.join(ROOT, "Data", "Interface", "ClassicPlus")
SS = 8  # supersampling

VIOLET = (216, 160, 255)
VIOLET_DK = (46, 20, 72)
GOLD = (236, 196, 104)
GOLD_DK = (120, 82, 30)
IVORY = (246, 238, 222)


def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def radial(size, inner, outer, cx=0.5, cy=0.5, power=1.0):
    w, h = size
    g = Image.new("RGBA", size)
    px = g.load()
    for y in range(h):
        for x in range(w):
            t = min(1.0, math.hypot(x / w - cx, y / h - cy) / 0.5) ** power
            px[x, y] = tuple(int(inner[i] + (outer[i] - inner[i]) * t) for i in range(3)) + (255,)
    return g


def masked(fill_img, mask):
    out = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    out.paste(fill_img, (0, 0), mask)
    return out


def circle_mask(size, r0, r1=None):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    c = size[0] / 2
    d.ellipse((c - r0, c - r0, c + r0, c + r0), fill=255)
    if r1:
        d.ellipse((c - r1, c - r1, c + r1, c + r1), fill=0)
    return m


def ring(img, r_out, r_in, light=GOLD, dark=GOLD_DK):
    S = img.size
    band = masked(radial(S, light, dark, 0.35, 0.3, 0.8), circle_mask(S, r_out, r_in))
    img.alpha_composite(band)
    d = ImageDraw.Draw(img)
    c = S[0] / 2
    d.ellipse((c - r_out, c - r_out, c + r_out, c + r_out), outline=(40, 24, 8, 255), width=max(1, SS))
    d.ellipse((c - r_in, c - r_in, c + r_in, c + r_in), outline=(40, 24, 8, 255), width=max(1, SS))


def star(d, cx, cy, r, fill, points=4, inner=0.32, rot=0.0):
    pts = []
    for i in range(points * 2):
        a = rot + math.pi * i / points - math.pi / 2
        rr = r if i % 2 == 0 else r * inner
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    d.polygon(pts, fill=fill)


def glow(img, color, radius):
    a = img.getchannel("A").filter(ImageFilter.GaussianBlur(radius))
    g = Image.new("RGBA", img.size, color + (0,))
    g.putalpha(a)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.alpha_composite(g)
    out.alpha_composite(img)
    return out


def down(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def mask_shape(S, cx, cy, w, h):
    """A half-face theatre mask: brow wide, cheeks tapering to a soft chin."""
    pts = []
    for i in range(64):
        t = 2 * math.pi * i / 64
        x = math.sin(t)
        y = -math.cos(t)
        if y > 0:   # lower half tapers
            x *= 1 - 0.38 * y ** 1.6
            y *= 1.08
        else:       # brow, slightly flattened
            y *= 0.82
        pts.append((cx + x * w / 2, cy + y * h / 2))
    return pts


def make_icon():
    n = 64
    img = canvas(n, n)
    S = img.size
    c = S[0] / 2
    disc = masked(radial(S, (92, 52, 140), (18, 8, 32), 0.42, 0.36, 0.9), circle_mask(S, c * 0.9))
    img.alpha_composite(disc)
    d = ImageDraw.Draw(img)
    for (x, y, r) in ((0.27, 0.27, 2.6), (0.74, 0.24, 1.8), (0.79, 0.72, 2.2), (0.22, 0.7, 1.4)):
        star(d, S[0] * x, S[1] * y, r * SS, (232, 214, 255, 230))
    # the mask
    face = Image.new("RGBA", S, (0, 0, 0, 0))
    fd = ImageDraw.Draw(face)
    fd.polygon(mask_shape(S, c, c * 1.04, S[0] * 0.5, S[1] * 0.54), fill=IVORY + (255,))
    shade = masked(radial(S, (255, 252, 244), (196, 176, 150), 0.38, 0.38, 1.1), face.getchannel("A"))
    face = shade
    fd = ImageDraw.Draw(face)
    for sx in (-1, 1):  # almond eye holes
        ex, ey = c + sx * S[0] * 0.105, c * 0.98
        fd.ellipse((ex - S[0] * 0.075, ey - S[1] * 0.04, ex + S[0] * 0.075, ey + S[1] * 0.04), fill=(26, 10, 40, 255))
        # brow stroke in violet
        fd.arc((ex - S[0] * 0.1, ey - S[1] * 0.1, ex + S[0] * 0.1, ey + S[1] * 0.04), 200, 340, fill=VIOLET + (255,), width=int(1.6 * SS))
    fd.arc((c - S[0] * 0.07, c * 1.22, c + S[0] * 0.07, c * 1.34), 20, 160, fill=(150, 90, 120, 255), width=int(1.4 * SS))
    # gold filigree on the forehead
    star(fd, c, c * 0.72, 3.2 * SS, GOLD + (255,), points=4, inner=0.35)
    img.alpha_composite(glow(face, VIOLET, 3 * SS))
    ring(img, c * 0.97, c * 0.86)
    return down(img, n, n)


STATUS = {
    "IC": ((70, 230, 90), (10, 70, 20)),
    "OOC": ((255, 150, 70), (90, 36, 8)),
    "LFRP": ((80, 200, 255), (10, 50, 90)),
    "ST": (VIOLET, (60, 20, 96)),
}


def make_status(key):
    n = 32
    img = canvas(n, n)
    S = img.size
    c = S[0] / 2
    hi, lo = STATUS[key]
    gem = masked(radial(S, tuple(min(255, v + 60) for v in hi), lo, 0.38, 0.32, 0.9), circle_mask(S, c * 0.74))
    img.alpha_composite(gem)
    d = ImageDraw.Draw(img)
    w = int(2.2 * SS)
    white = (255, 255, 255, 235)
    if key == "IC":          # a speech mark: in character, speaking as them
        d.ellipse((c - c * 0.36, c - c * 0.3, c + c * 0.36, c + c * 0.22), fill=white)
        d.polygon([(c - c * 0.14, c + c * 0.12), (c - c * 0.3, c + c * 0.42), (c + c * 0.06, c + c * 0.16)], fill=white)
    elif key == "OOC":       # brackets ( ): out of character
        d.arc((c - c * 0.42, c - c * 0.4, c - c * 0.02, c + c * 0.4), 110, 250, fill=white, width=w)
        d.arc((c + c * 0.02, c - c * 0.4, c + c * 0.42, c + c * 0.4), -70, 70, fill=white, width=w)
    elif key == "LFRP":      # a plus: looking for company
        d.rectangle((c - w / 2, c - c * 0.36, c + w / 2, c + c * 0.36), fill=white)
        d.rectangle((c - c * 0.36, c - w / 2, c + c * 0.36, c + w / 2), fill=white)
    else:                    # a star: storytelling, running a scene
        star(d, c, c, c * 0.42, white, points=5, inner=0.45)
    # top gloss
    gl = Image.new("L", S, 0)
    ImageDraw.Draw(gl).ellipse((c - c * 0.5, c - c * 0.66, c + c * 0.5, c - c * 0.02), fill=70)
    gl = ImageChops.multiply(gl.filter(ImageFilter.GaussianBlur(2 * SS)), circle_mask(S, c * 0.74))
    img.alpha_composite(Image.merge("RGBA", (Image.new("L", S, 255),) * 3 + (gl,)))
    ring(img, c * 0.96, c * 0.74)
    return down(img, n, n)


def make_ring():
    n = 64
    img = canvas(n, n)
    c = img.size[0] / 2
    halo = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse((c * 0.2, c * 0.2, c * 1.8, c * 1.8), outline=VIOLET + (200,), width=int(3 * SS))
    img.alpha_composite(halo.filter(ImageFilter.GaussianBlur(2 * SS)))
    ring(img, c * 0.95, c * 0.8)
    d = ImageDraw.Draw(img)
    for i in range(4):
        a = math.pi / 4 + i * math.pi / 2
        star(d, c + c * 0.875 * math.cos(a), c + c * 0.875 * math.sin(a), 3.4 * SS, (255, 236, 180, 255), points=4, inner=0.3)
    return down(img, n, n)


def make_divider():
    w, h = 256, 32
    img = canvas(w, h)
    S = img.size
    d = ImageDraw.Draw(img)
    cy = S[1] / 2
    for side in (-1, 1):
        for i in range(120):
            t = i / 119
            x0 = S[0] / 2 + side * (S[0] * 0.06 + t * S[0] * 0.42)
            a = int(255 * (1 - t) ** 1.2)
            d.ellipse((x0 - 0.9 * SS, cy - 0.9 * SS, x0 + 0.9 * SS, cy + 0.9 * SS), fill=GOLD + (a,))
        # curl
        cx = S[0] / 2 + side * S[0] * 0.09
        d.arc((cx - 7 * SS, cy - 9 * SS, cx + 7 * SS, cy + 1 * SS), 180, 360, fill=GOLD + (230,), width=int(1.4 * SS))
        d.arc((cx - 7 * SS, cy - 1 * SS, cx + 7 * SS, cy + 9 * SS), 0, 180, fill=GOLD + (230,), width=int(1.4 * SS))
        star(d, S[0] / 2 + side * S[0] * 0.2, cy, 2.4 * SS, VIOLET + (230,), points=4, inner=0.3)
    d.polygon([(S[0] / 2, cy - 7 * SS), (S[0] / 2 + 7 * SS, cy), (S[0] / 2, cy + 7 * SS), (S[0] / 2 - 7 * SS, cy)], fill=GOLD + (255,), outline=(60, 36, 10, 255))
    d.polygon([(S[0] / 2, cy - 3.5 * SS), (S[0] / 2 + 3.5 * SS, cy), (S[0] / 2, cy + 3.5 * SS), (S[0] / 2 - 3.5 * SS, cy)], fill=VIOLET + (255,))
    return glow(down(img, w, h), (40, 20, 60), 1)


def save(name, img):
    os.makedirs(TGA_DIR, exist_ok=True)
    os.makedirs(BLP_DIR, exist_ok=True)
    img.save(os.path.join(TGA_DIR, name + ".tga"))
    write_blp(img, os.path.join(BLP_DIR, name + ".blp"))
    return img


def main():
    out = {"Persona_Icon": make_icon(), "Persona_Ring": make_ring(), "Persona_Divider": make_divider()}
    for k in STATUS:
        out["Persona_" + k] = make_status(k)
    for name, img in out.items():
        save(name, img)
        print("  +", name, img.size)
    # contact sheet (4x zoom, on the window colour and on parchment-ish)
    sheet = Image.new("RGBA", (1100, 360), (18, 18, 20, 255))
    x = 20
    for name in ["Persona_Icon", "Persona_Ring", "Persona_IC", "Persona_OOC", "Persona_LFRP", "Persona_ST"]:
        im = out[name]
        z = im.resize((im.width * 4 if im.width == 32 else im.width * 3,) * 2, Image.NEAREST)
        sheet.alpha_composite(z, (x, 20))
        x += z.width + 20
    div = out["Persona_Divider"].resize((1024, 128), Image.LANCZOS)
    sheet.alpha_composite(div, (40, 220))
    sheet.save(os.path.join(HERE, "preview.png"))


if __name__ == "__main__":
    main()
