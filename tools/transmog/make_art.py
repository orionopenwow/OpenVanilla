"""make_art.py - draws the Transmog window's own art (original, procedural) as 1.12-ready TGAs.

    python3 tools/transmog/make_art.py [out dir = Data/Interface/AddOns/Transmog/Art]

Every piece is drawn here from shapes, so it is ours to ship in patch-Z (no game textures are
copied). TGAs are written as the 1.12 client reads them: uncompressed, 32-bit BGRA, bottom-up rows,
power-of-two sizes. Needs Pillow.

    Pedestal      512x128  the stone dais the character stands on (gold rim, carved rings)
    Vignette      256x256  dark edges for the model view
    Glow          128x128  warm light behind the character
    CellRim       64x64    a rounded square rim, white (tinted per item quality in Lua)
    CellSel       128x128  the selected cell: gold rim and outer glow
    SlotRim       64x64    the silver rim of a gear slot
    Badge         64x16    the rounded "Active" pill, white (tinted)
    Bar           256x32   the view toolbar's plate
    Btn           32x32    a toolbar button face
    IconMove, IconRotate, IconZoom, IconBrush  32x32 white glyphs
    Shield        32x32    the "puts itself on" (situations) badge
    Connector     64x16    the gold bracket from the chosen slot to the collection
    Ring          128x128  the portrait's gold ring (transparent inside and out)
"""
import math
import os
import struct
import sys

from PIL import Image, ImageDraw, ImageFilter

SS = 4  # supersampling


def save_tga(img, path):
    img = img.convert("RGBA")
    w, h = img.size
    assert w & (w - 1) == 0 and h & (h - 1) == 0, (path, img.size)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
    rows = []
    px = img.load()
    for y in range(h - 1, -1, -1):
        row = bytearray()
        for x in range(w):
            r, g, b, a = px[x, y]
            row += bytes((b, g, r, a))
        rows.append(bytes(row))
    with open(path, "wb") as f:
        f.write(header)
        f.write(b"".join(rows))


def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def down(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def pedestal():
    W, H = 512, 128
    im = canvas(W, H)
    d = ImageDraw.Draw(im)
    s = SS
    cx, top, rx, ry, depth = W / 2 * s, 14 * s, 236 * s, 44 * s, 26 * s
    # the side band (front face), dark stone with a lit top edge
    d.rectangle([cx - rx, top + ry, cx + rx, top + ry + depth], fill=(38, 34, 34, 255))
    d.ellipse([cx - rx, top + depth, cx + rx, top + 2 * ry + depth], fill=(26, 23, 24, 255))
    for i in range(0, 360, 12):                      # carved blocks on the face
        a = math.radians(i)
        x = cx + rx * math.cos(a)
        if math.sin(a) > 0.05:
            y = top + ry + ry * math.sin(a)
            d.line([x, y, x, y + depth], fill=(18, 16, 16, 255), width=2 * s)
    # the top: gold rim, stone, carved rings
    d.ellipse([cx - rx, top, cx + rx, top + 2 * ry], fill=(150, 112, 52, 255))
    d.ellipse([cx - rx + 6 * s, top + 3 * s, cx + rx - 6 * s, top + 2 * ry - 3 * s], fill=(66, 60, 58, 255))
    for k, col in ((0.86, (44, 40, 40, 255)), (0.84, (92, 84, 78, 255)), (0.62, (52, 47, 46, 255)),
                   (0.60, (104, 94, 86, 255)), (0.34, (58, 53, 51, 255))):
        d.ellipse([cx - rx * k, top + ry - ry * k, cx + rx * k, top + ry + ry * k], fill=col)
    # runes between the outer rings
    for i in range(0, 360, 15):
        a = math.radians(i)
        x1, y1 = cx + rx * 0.80 * math.cos(a), top + ry + ry * 0.80 * math.sin(a)
        x2, y2 = cx + rx * 0.66 * math.cos(a), top + ry + ry * 0.66 * math.sin(a)
        d.line([x1, y1, x2, y2], fill=(140, 110, 60, 200), width=2 * s)
    # light from above: a soft sheen across the top
    sheen = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(sheen).ellipse([cx - rx * 0.7, top + ry * 0.2, cx + rx * 0.7, top + ry * 1.2], fill=(255, 220, 160, 40))
    im = Image.alpha_composite(im, sheen.filter(ImageFilter.GaussianBlur(12 * s)))
    return down(im, W, H)


def vignette():
    W = 256
    im = Image.new("RGBA", (W, W))
    px = im.load()
    for y in range(W):
        for x in range(W):
            dx, dy = (x - W / 2) / (W / 2), (y - W / 2) / (W / 2)
            r = math.sqrt(dx * dx * 0.9 + dy * dy)
            a = max(0.0, min(1.0, (r - 0.45) / 0.65)) ** 1.6
            px[x, y] = (0, 0, 0, int(235 * a))
    return im


def glow():
    W = 128
    im = Image.new("RGBA", (W, W))
    px = im.load()
    for y in range(W):
        for x in range(W):
            r = math.hypot(x - W / 2, y - W / 2) / (W / 2)
            a = max(0.0, 1 - r) ** 2
            px[x, y] = (255, 190, 110, int(255 * a))
    return im


def rounded_rim(size, width, radius, color=(255, 255, 255, 255), fill=None):
    im = canvas(size, size)
    d = ImageDraw.Draw(im)
    s = SS
    box = [width * s / 2, width * s / 2, size * s - width * s / 2, size * s - width * s / 2]
    d.rounded_rectangle(box, radius=radius * s, outline=color, width=int(width * s), fill=fill)
    return down(im, size, size)


def cell_sel():
    W = 128
    im = Image.new("RGBA", (W, W))
    halo = canvas(W, W)
    d = ImageDraw.Draw(halo)
    s = SS
    d.rounded_rectangle([22 * s, 22 * s, 106 * s, 106 * s], radius=10 * s, outline=(255, 200, 60, 255), width=10 * s)
    halo = down(halo, W, W).filter(ImageFilter.GaussianBlur(7))
    im = Image.alpha_composite(im, halo)
    rim = canvas(W, W)
    ImageDraw.Draw(rim).rounded_rectangle([30 * s, 30 * s, 98 * s, 98 * s], radius=6 * s, outline=(255, 214, 90, 255), width=3 * s)
    return Image.alpha_composite(im, down(rim, W, W))


def slot_rim():
    W = 64
    im = canvas(W, W)
    d = ImageDraw.Draw(im)
    s = SS
    d.rounded_rectangle([2 * s, 2 * s, 62 * s, 62 * s], radius=6 * s, outline=(20, 20, 24, 255), width=3 * s)
    d.rounded_rectangle([4 * s, 4 * s, 60 * s, 60 * s], radius=5 * s, outline=(168, 168, 176, 255), width=3 * s)
    d.rounded_rectangle([7 * s, 7 * s, 57 * s, 57 * s], radius=4 * s, outline=(60, 60, 68, 255), width=2 * s)
    return down(im, W, W)


def badge():
    im = canvas(64, 16)
    ImageDraw.Draw(im).rounded_rectangle([1 * SS, 1 * SS, 63 * SS, 15 * SS], radius=4 * SS,
                                         fill=(255, 255, 255, 255))
    return down(im, 64, 16)


def bar():
    W, H = 256, 32
    im = canvas(W, H)
    d = ImageDraw.Draw(im)
    s = SS
    d.rounded_rectangle([2 * s, 3 * s, 254 * s, 29 * s], radius=6 * s, fill=(22, 20, 22, 235), outline=(120, 100, 64, 255), width=2 * s)
    for x0, sign in ((10, -1), (246, 1)):        # the end chevrons
        d.line([(x0 - 3 * sign) * s, 10 * s, (x0 + 3 * sign) * s, 16 * s, (x0 - 3 * sign) * s, 22 * s],
               fill=(190, 160, 100, 255), width=2 * s, joint="curve")
    return down(im, W, H)


def btn():
    im = canvas(32, 32)
    d = ImageDraw.Draw(im)
    s = SS
    d.rounded_rectangle([1 * s, 1 * s, 31 * s, 31 * s], radius=4 * s, fill=(46, 42, 40, 255), outline=(150, 124, 76, 255), width=2 * s)
    d.rounded_rectangle([4 * s, 4 * s, 28 * s, 14 * s], radius=3 * s, fill=(255, 255, 255, 18))
    return down(im, 32, 32)


def glyph(kind):
    im = canvas(32, 32)
    d = ImageDraw.Draw(im)
    s = SS
    c = (235, 225, 205, 255)
    w = int(2.4 * s)
    if kind == "move":
        d.line([16 * s, 6 * s, 16 * s, 26 * s], fill=c, width=w)
        d.line([6 * s, 16 * s, 26 * s, 16 * s], fill=c, width=w)
        for (x, y, dx, dy) in ((16, 5, 0, 1), (16, 27, 0, -1), (5, 16, 1, 0), (27, 16, -1, 0)):
            d.polygon([(x * s, y * s), ((x + 4 * dx + 4 * dy) * s, (y + 4 * dy + 4 * dx) * s),
                       ((x + 4 * dx - 4 * dy) * s, (y + 4 * dy - 4 * dx) * s)], fill=c)
    elif kind == "rotate":
        d.arc([7 * s, 7 * s, 25 * s, 25 * s], 200, 340, fill=c, width=w)
        d.arc([7 * s, 7 * s, 25 * s, 25 * s], 20, 160, fill=c, width=w)
        d.polygon([(25 * s, 11 * s), (27 * s, 18 * s), (20 * s, 15 * s)], fill=c)
        d.polygon([(7 * s, 21 * s), (5 * s, 14 * s), (12 * s, 17 * s)], fill=c)
    elif kind == "zoom":
        d.ellipse([6 * s, 6 * s, 20 * s, 20 * s], outline=c, width=w)
        d.line([18 * s, 18 * s, 26 * s, 26 * s], fill=c, width=int(3.2 * s))
        d.line([10 * s, 13 * s, 16 * s, 13 * s], fill=c, width=int(1.8 * s))
        d.line([13 * s, 10 * s, 13 * s, 16 * s], fill=c, width=int(1.8 * s))
    elif kind == "brush":
        d.line([23 * s, 6 * s, 13 * s, 18 * s], fill=c, width=int(3 * s))
        d.polygon([(10 * s, 17 * s), (15 * s, 21 * s), (11 * s, 27 * s), (5 * s, 27 * s), (7 * s, 21 * s)], fill=(214, 170, 90, 255))
    elif kind == "shield":
        d.polygon([(16 * s, 3 * s), (27 * s, 7 * s), (25 * s, 19 * s), (16 * s, 29 * s), (7 * s, 19 * s), (5 * s, 7 * s)],
                  fill=(150, 112, 46, 255), outline=(240, 200, 110, 255))
        d.polygon([(16 * s, 8 * s), (22 * s, 10 * s), (21 * s, 18 * s), (16 * s, 24 * s), (11 * s, 18 * s), (10 * s, 10 * s)],
                  fill=(220, 170, 70, 255))
    return down(im, 32, 32)


def connector():
    im = canvas(64, 16)
    d = ImageDraw.Draw(im)
    s = SS
    d.line([0, 8 * s, 52 * s, 8 * s], fill=(240, 196, 80, 255), width=2 * s)
    d.line([52 * s, 2 * s, 52 * s, 14 * s], fill=(240, 196, 80, 255), width=2 * s)
    return down(im, 64, 16)


def ring():
    W = 128
    im = canvas(W, W)
    d = ImageDraw.Draw(im)
    s = SS
    d.ellipse([2 * s, 2 * s, 126 * s, 126 * s], fill=(18, 14, 12, 255))
    d.ellipse([5 * s, 5 * s, 123 * s, 123 * s], fill=(176, 134, 60, 255))
    d.ellipse([9 * s, 9 * s, 119 * s, 119 * s], fill=(96, 70, 30, 255))
    d.ellipse([12 * s, 12 * s, 116 * s, 116 * s], fill=(214, 172, 90, 255))
    d.ellipse([16 * s, 16 * s, 112 * s, 112 * s], fill=(0, 0, 0, 0))
    return down(im, W, W)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Data/Interface/AddOns/Transmog/Art"
    os.makedirs(out, exist_ok=True)
    pieces = {
        "Pedestal": pedestal(), "Vignette": vignette(), "Glow": glow(),
        "CellRim": rounded_rim(64, 3, 6), "CellSel": cell_sel(), "SlotRim": slot_rim(), "Badge": badge(),
        "Bar": bar(), "Btn": btn(), "IconMove": glyph("move"), "IconRotate": glyph("rotate"),
        "IconZoom": glyph("zoom"), "IconBrush": glyph("brush"), "Shield": glyph("shield"), "Connector": connector(), "Ring": ring(),
    }
    for name, img in pieces.items():
        save_tga(img, os.path.join(out, name + ".tga"))
    print("wrote", len(pieces), "pieces to", out)


if __name__ == "__main__":
    main()


# ── second pass: the asset sheet's components (materials: grain, gradients, bevels) ──────────
import random


def grain(w, h, amount, seed=1):
    r = random.Random(seed)
    im = Image.new("L", (w, h))
    im.putdata([128 + int(r.gauss(0, amount)) for _ in range(w * h)])
    return im.filter(ImageFilter.GaussianBlur(0.6))


def vgrad(w, h, top, bottom):
    im = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([0, y, w, y], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)))
    return im


def textured(w, h, top, bottom, amount, seed):
    base = vgrad(w, h, top, bottom)
    g = grain(w, h, amount, seed)
    px, gp = base.load(), g.load()
    for y in range(h):
        for x in range(w):
            r, gg, b, a = px[x, y]
            k = (gp[x, y] - 128) / 255
            px[x, y] = (max(0, min(255, int(r * (1 + k)))), max(0, min(255, int(gg * (1 + k)))),
                        max(0, min(255, int(b * (1 + k)))), a)
    return base


def mask_round(img, radius):
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=radius, fill=255)
    a = img.getchannel("A")
    from PIL import ImageChops
    img.putalpha(ImageChops.multiply(a, m))
    return img


def gold_frame(d, box, s, radius, outer=(30, 22, 12, 255), mid=(210, 168, 82, 255), inner=(110, 80, 34, 255)):
    x0, y0, x1, y1 = box
    d.rounded_rectangle([x0, y0, x1, y1], radius=radius, outline=outer, width=2 * s)
    d.rounded_rectangle([x0 + 2 * s, y0 + 2 * s, x1 - 2 * s, y1 - 2 * s], radius=max(1, radius - 2 * s), outline=mid, width=2 * s)
    d.rounded_rectangle([x0 + 4 * s, y0 + 4 * s, x1 - 4 * s, y1 - 4 * s], radius=max(1, radius - 4 * s), outline=inner, width=1 * s)


def corner_brackets(d, box, s, size, color=(226, 182, 92, 255)):
    x0, y0, x1, y1 = box
    L = size * s
    for (cx, cy, dx, dy) in ((x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)):
        d.line([cx, cy + dy * L, cx, cy, cx + dx * L, cy], fill=color, width=2 * s)
        d.rectangle([cx + dx * 2 * s - s, cy + dy * 2 * s - s, cx + dx * 2 * s + s, cy + dy * 2 * s + s], fill=color)


def button(kind):
    W, H = 256, 64
    s = SS
    if kind == "red":
        face = textured(W * s, H * s, (150, 22, 18, 255), (70, 6, 6, 255), 22, 3)
    else:
        face = textured(W * s, H * s, (58, 54, 52, 255), (26, 24, 24, 255), 26, 4)
    face = mask_round(face, 8 * s)
    d = ImageDraw.Draw(face)
    sheen = Image.new("RGBA", face.size, (0, 0, 0, 0))
    ImageDraw.Draw(sheen).rounded_rectangle([6 * s, 5 * s, W * s - 6 * s, H * s * 0.45], radius=6 * s, fill=(255, 255, 255, 22))
    face = Image.alpha_composite(face, sheen)
    d = ImageDraw.Draw(face)
    if kind == "red":
        gold_frame(d, [1 * s, 1 * s, W * s - 2 * s, H * s - 2 * s], s, 8 * s)
        corner_brackets(d, [7 * s, 7 * s, W * s - 8 * s, H * s - 8 * s], s, 8, (240, 200, 110, 255))
    else:
        d.rounded_rectangle([1 * s, 1 * s, W * s - 2 * s, H * s - 2 * s], radius=8 * s, outline=(16, 14, 12, 255), width=2 * s)
        d.rounded_rectangle([3 * s, 3 * s, W * s - 4 * s, H * s - 4 * s], radius=6 * s, outline=(96, 84, 64, 255), width=2 * s)
        corner_brackets(d, [5 * s, 5 * s, W * s - 6 * s, H * s - 6 * s], s, 10)
    return down(face, W, H)


def button_glow():
    W, H = 256, 128
    im = canvas(W, H)
    ImageDraw.Draw(im).rounded_rectangle([40 * SS, 40 * SS, 216 * SS, 88 * SS], radius=10 * SS,
                                         outline=(255, 196, 70, 255), width=12 * SS)
    return down(im, W, H).filter(ImageFilter.GaussianBlur(9))


def tab(on):
    W, H = 128, 32
    s = SS
    face = textured(W * s, H * s, (44, 40, 36, 255) if not on else (70, 54, 30, 255),
                    (20, 18, 18, 255) if not on else (34, 26, 16, 255), 20, 5)
    face = mask_round(face, 4 * s)
    d = ImageDraw.Draw(face)
    if on:
        gold_frame(d, [0, 0, W * s - 1, H * s - 1], s, 4 * s)
    else:
        d.rounded_rectangle([0, 0, W * s - 1, H * s - 1], radius=4 * s, outline=(14, 12, 10, 255), width=2 * s)
        d.rounded_rectangle([2 * s, 2 * s, W * s - 3 * s, H * s - 3 * s], radius=3 * s, outline=(86, 76, 60, 255), width=1 * s)
    return down(face, W, H)


def field():
    W, H = 256, 32
    s = SS
    face = textured(W * s, H * s, (8, 8, 9, 255), (18, 17, 18, 255), 12, 6)
    face = mask_round(face, 4 * s)
    d = ImageDraw.Draw(face)
    d.rounded_rectangle([0, 0, W * s - 1, H * s - 1], radius=4 * s, outline=(90, 80, 62, 255), width=2 * s)
    d.line([3 * s, 3 * s, W * s - 3 * s, 3 * s], fill=(0, 0, 0, 255), width=2 * s)   # inset shadow
    return down(face, W, H)


def stone_slot():
    W = 64
    s = SS
    im = canvas(W, W)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([1 * s, 1 * s, 63 * s, 63 * s], radius=6 * s, fill=(16, 15, 16, 255))
    # bevel: light top/left, dark bottom/right
    d.rounded_rectangle([3 * s, 3 * s, 61 * s, 61 * s], radius=5 * s, outline=(190, 186, 178, 255), width=3 * s)
    d.line([7 * s, 61 * s, 61 * s, 61 * s, 61 * s, 7 * s], fill=(70, 66, 62, 255), width=3 * s)
    d.rounded_rectangle([7 * s, 7 * s, 57 * s, 57 * s], radius=3 * s, outline=(36, 34, 34, 255), width=2 * s)
    d.rectangle([9 * s, 9 * s, 55 * s, 55 * s], fill=(0, 0, 0, 0))
    return down(im, W, W)


def card(on):
    W, H = 256, 64
    s = SS
    face = textured(W * s, H * s, (32, 30, 30, 240) if not on else (62, 46, 22, 245),
                    (14, 13, 14, 240) if not on else (26, 20, 12, 245), 16, 7 if on else 8)
    face = mask_round(face, 5 * s)
    d = ImageDraw.Draw(face)
    if on:
        gold_frame(d, [0, 0, W * s - 1, H * s - 1], s, 5 * s)
    else:
        d.rounded_rectangle([0, 0, W * s - 1, H * s - 1], radius=5 * s, outline=(12, 11, 10, 255), width=2 * s)
        d.rounded_rectangle([2 * s, 2 * s, W * s - 3 * s, H * s - 3 * s], radius=4 * s, outline=(70, 64, 54, 255), width=1 * s)
    return down(face, W, H)


def pill():
    W, H = 64, 16
    s = SS
    face = vgrad(W * s, H * s, (60, 150, 60, 255), (22, 82, 24, 255))
    face = mask_round(face, 4 * s)
    ImageDraw.Draw(face).rounded_rectangle([0, 0, W * s - 1, H * s - 1], radius=4 * s, outline=(140, 220, 120, 255), width=1 * s)
    return down(face, W, H)


def edge(horizontal):
    L, T = 256, 32
    s = SS
    im = textured(L * s, T * s, (46, 42, 40, 255), (22, 20, 20, 255), 24, 9)
    d = ImageDraw.Draw(im)
    d.line([0, 2 * s, L * s, 2 * s], fill=(12, 10, 10, 255), width=3 * s)
    d.line([0, 8 * s, L * s, 8 * s], fill=(120, 110, 96, 255), width=2 * s)         # silver bevel
    d.line([0, 20 * s, L * s, 20 * s], fill=(176, 136, 64, 255), width=2 * s)        # gold inner line
    d.line([0, 29 * s, L * s, 29 * s], fill=(8, 7, 7, 255), width=3 * s)
    out = down(im, L, T)
    return out if horizontal else out.rotate(90, expand=True)


def frame_corner():
    W = 64
    s = SS
    im = canvas(W, W)
    d = ImageDraw.Draw(im)
    plate = textured(40 * s, 40 * s, (60, 56, 52, 255), (24, 22, 22, 255), 24, 10)
    m = Image.new("L", plate.size, 0)
    ImageDraw.Draw(m).polygon([(0, 0), (40 * s, 0), (40 * s, 12 * s), (12 * s, 40 * s), (0, 40 * s)], fill=255)
    im.paste(plate, (0, 0), m)
    d.line([2 * s, 38 * s, 2 * s, 2 * s, 38 * s, 2 * s], fill=(200, 160, 80, 255), width=3 * s)
    d.line([10 * s, 34 * s, 34 * s, 10 * s], fill=(200, 160, 80, 255), width=2 * s)
    d.polygon([(16 * s, 8 * s), (22 * s, 14 * s), (16 * s, 20 * s), (10 * s, 14 * s)], fill=(230, 196, 110, 255))
    for k in range(3):                      # scroll curls along both arms
        d.arc([(40 + k * 7) * s, 0, (48 + k * 7) * s, 8 * s], 180, 360, fill=(170, 130, 60, 255), width=2 * s)
        d.arc([0, (40 + k * 7) * s, 8 * s, (48 + k * 7) * s], 90, 270, fill=(170, 130, 60, 255), width=2 * s)
    return down(im, W, W)


def banner():
    W, H = 512, 64
    s = SS
    im = canvas(W, H)
    d = ImageDraw.Draw(im)
    for sx in (-1, 1):                      # filigree arms
        x0 = W * s / 2 + sx * 120 * s
        x1 = W * s / 2 + sx * 250 * s
        d.line([x0, 32 * s, x1, 32 * s], fill=(150, 116, 56, 255), width=2 * s)
        d.line([x0, 26 * s, x0 + sx * 70 * s, 26 * s], fill=(110, 84, 40, 255), width=1 * s)
        d.line([x0, 38 * s, x0 + sx * 70 * s, 38 * s], fill=(110, 84, 40, 255), width=1 * s)
        for k in range(4):
            cx = x0 + sx * (24 + k * 30) * s
            d.arc([cx - 7 * s, 22 * s, cx + 7 * s, 36 * s], 200 if sx > 0 else -20, 340 if sx > 0 else 160, fill=(190, 150, 70, 255), width=2 * s)
        d.polygon([(x1, 28 * s), (x1 + sx * 8 * s, 32 * s), (x1, 36 * s)], fill=(210, 170, 80, 255))
    plate = textured(244 * s, 48 * s, (52, 48, 46, 255), (20, 18, 18, 255), 22, 11)
    pm = Image.new("L", plate.size, 0)
    ImageDraw.Draw(pm).polygon([(14 * s, 0), (230 * s, 0), (244 * s, 24 * s), (230 * s, 48 * s), (14 * s, 48 * s), (0, 24 * s)], fill=255)
    im.paste(plate, (int(W * s / 2 - 122 * s), 8 * s), pm)
    ox = W * s / 2 - 122 * s
    pts = [(ox + 14 * s, 8 * s), (ox + 230 * s, 8 * s), (ox + 244 * s, 32 * s), (ox + 230 * s, 56 * s), (ox + 14 * s, 56 * s), (ox, 32 * s)]
    d.polygon(pts, outline=(210, 168, 82, 255), width=3 * s)
    inner = [(x + (6 * s if x < W * s / 2 else -6 * s), y + (5 * s if y < 32 * s else -5 * s if y > 32 * s else 0)) for x, y in pts]
    d.polygon(inner, outline=(96, 72, 32, 255), width=1 * s)
    return down(im, W, H)


def close_btn():
    W = 32
    s = SS
    face = textured(W * s, W * s, (70, 64, 60, 255), (26, 24, 24, 255), 20, 12)
    face = mask_round(face, 4 * s)
    d = ImageDraw.Draw(face)
    d.rounded_rectangle([0, 0, W * s - 1, W * s - 1], radius=4 * s, outline=(170, 150, 110, 255), width=2 * s)
    d.rounded_rectangle([5 * s, 5 * s, 27 * s, 27 * s], radius=3 * s, fill=(120, 16, 12, 255), outline=(30, 6, 6, 255), width=1 * s)
    d.line([10 * s, 10 * s, 22 * s, 22 * s], fill=(240, 220, 200, 255), width=3 * s)
    d.line([22 * s, 10 * s, 10 * s, 22 * s], fill=(240, 220, 200, 255), width=3 * s)
    return down(face, W, W)


def pedestal2():
    W, H = 512, 128
    s = SS
    im = canvas(W, H)
    d = ImageDraw.Draw(im)
    cx = W * s / 2

    def tier(top, rx, ry, depth, stone_top, stone_side, rim):
        d.rectangle([cx - rx, top + ry, cx + rx, top + ry + depth], fill=stone_side)
        d.ellipse([cx - rx, top + depth, cx + rx, top + 2 * ry + depth], fill=stone_side)
        for i in range(0, 180, 9):          # blocks on the face
            a = math.radians(i)
            x = cx + rx * math.cos(a)
            y = top + ry + ry * math.sin(a)
            d.line([x, y, x, y + depth], fill=(14, 12, 12, 255), width=2 * s)
        d.ellipse([cx - rx, top, cx + rx, top + 2 * ry], fill=rim)
        d.ellipse([cx - rx + 5 * s, top + 3 * s, cx + rx - 5 * s, top + 2 * ry - 3 * s], fill=stone_top)

    tier(30 * s, 248 * s, 40 * s, 22 * s, (54, 50, 48, 255), (30, 27, 27, 255), (150, 116, 56, 255))
    tier(14 * s, 196 * s, 32 * s, 16 * s, (72, 66, 62, 255), (36, 32, 32, 255), (176, 136, 64, 255))
    top, rx, ry = 14 * s, 196 * s, 32 * s
    for k, col in ((0.8, (46, 42, 41, 255)), (0.77, (110, 100, 90, 255)), (0.5, (60, 55, 53, 255)), (0.48, (120, 108, 96, 255)), (0.25, (64, 59, 57, 255))):
        d.ellipse([cx - rx * k, top + ry - ry * k, cx + rx * k, top + ry + ry * k], fill=col)
    for i in range(0, 360, 12):
        a = math.radians(i)
        x1, y1 = cx + rx * 0.74 * math.cos(a), top + ry + ry * 0.74 * math.sin(a)
        x2, y2 = cx + rx * 0.56 * math.cos(a), top + ry + ry * 0.56 * math.sin(a)
        d.line([x1, y1, x2, y2], fill=(200, 160, 80, 210), width=2 * s)
    sheen = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(sheen).ellipse([cx - rx * 0.6, top + ry * 0.1, cx + rx * 0.6, top + ry * 1.1], fill=(255, 210, 150, 46))
    im = Image.alpha_composite(im, sheen.filter(ImageFilter.GaussianBlur(10 * s)))
    return down(im, W, H)


def bar2():
    W, H = 256, 32
    s = SS
    face = textured(W * s, H * s, (60, 52, 42, 255), (26, 22, 18, 255), 22, 13)
    face = mask_round(face, 6 * s)
    d = ImageDraw.Draw(face)
    gold_frame(d, [0, 0, W * s - 1, H * s - 1], s, 6 * s)
    return down(face, W, H)


def btn2():
    W = 32
    s = SS
    face = textured(W * s, W * s, (84, 70, 50, 255), (34, 28, 22, 255), 22, 14)
    face = mask_round(face, 4 * s)
    d = ImageDraw.Draw(face)
    d.rounded_rectangle([0, 0, W * s - 1, W * s - 1], radius=4 * s, outline=(214, 172, 90, 255), width=2 * s)
    d.rounded_rectangle([3 * s, 3 * s, W * s - 4 * s, W * s - 4 * s], radius=3 * s, outline=(60, 44, 24, 255), width=1 * s)
    return down(face, W, W)


def main2(out):
    pieces = {
        "BtnRed": button("red"), "BtnStone": button("stone"), "BtnGlow": button_glow(),
        "TabOn": tab(True), "TabOff": tab(False), "Field": field(), "SlotRim": stone_slot(),
        "Card": card(False), "CardOn": card(True), "Badge": pill(), "EdgeH": edge(True), "EdgeV": edge(False),
        "Corner": frame_corner(), "Banner": banner(), "Close": close_btn(), "Pedestal": pedestal2(),
        "Bar": bar2(), "Btn": btn2(),
    }
    for name, img in pieces.items():
        save_tga(img, os.path.join(out, name + ".tga"))
    print("second pass:", len(pieces), "pieces")


if __name__ == "__main__":
    main2(sys.argv[1] if len(sys.argv) > 1 else "Data/Interface/AddOns/Transmog/Art")
