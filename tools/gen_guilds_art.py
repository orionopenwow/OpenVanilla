#!/usr/bin/env python3
"""Guild Finder (Guilds addon, "Concord") art: the window portrait and the five focus crests.

    python3 tools/gen_guilds_art.py                 writes the TGA + BLP pairs (see tools/artkit.py)
    python3 tools/gen_guilds_art.py --preview DIR   also writes a contact sheet into DIR

Pieces (all have stock-icon fallbacks in the addon)
  Guilds_Portrait        64x64  round portrait under the Classic frame's ring: a heraldic shield
                                (crimson and royal blue, gold chevron) over a hanging banner
  Guilds_Focus_Raiding   64x64  focus crests: a steel-rimmed medallion with a gold inner ring and
  Guilds_Focus_Leveling         the focus' symbol (horned skull, open book, sword and buckler,
  Guilds_Focus_PvP              ale mug, campfire) on its own colour; drawn to read at 32 px on
  Guilds_Focus_Social           the listing cards and 20 px in chips
  Guilds_Focus_Casual
"""
import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

from artkit import (SS, GOLD, GOLD_HI, GOLD_LO, GOLD_MID, INK, canvas, fill, gold_band, grain, inner_shadow,
                    paste_masked, save, sheen, sheet, vgrad)


def u(v):
    return v * SS


def wi(v):
    return max(1, int(round(v * SS)))


def P(pts):
    return [(u(x), u(y)) for x, y in pts]


def mask_from(draw_fn, size=64):
    m = Image.new("L", (u(size), u(size)), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def rotate_mask(m, deg, center=(32, 32)):
    return m.rotate(deg, resample=Image.BICUBIC, center=(u(center[0]), u(center[1])))


def gold_fill(size):
    return vgrad(size, [(0.0, GOLD_HI), (0.35, (250, 206, 90)), (0.7, (214, 156, 48)), (1.0, (150, 98, 28))])


def steel_fill(size):
    return vgrad(size, [(0.0, (236, 240, 248)), (0.45, (188, 194, 206)), (1.0, (112, 118, 132))])


def bone_fill(size):
    return vgrad(size, [(0.0, (255, 250, 232)), (0.5, (226, 214, 184)), (1.0, (150, 136, 108))])


def wood_fill(size):
    return vgrad(size, [(0.0, (196, 136, 78)), (0.5, (140, 88, 44)), (1.0, (80, 46, 20))])


def emblem(img, m, fillimg, outline=2.2, shade=None, shade_alpha=95):
    """One symbol part: soft shadow, dark outline, fill, top sheen."""
    W, H = img.size
    m = m.filter(ImageFilter.GaussianBlur(0.3 * SS))
    k = int(outline * SS) * 2 + 1
    ol = m.filter(ImageFilter.MaxFilter(k))
    sh = ol.transform((W, H), Image.AFFINE, (1, 0, 0, 0, 1, -1.2 * SS)).filter(ImageFilter.GaussianBlur(1.6 * SS))
    paste_masked(img, fill((W, H), (0, 0, 0)), sh.point(lambda v: v * 150 // 255))
    paste_masked(img, fill((W, H), INK), ol)
    paste_masked(img, fillimg, m)
    if shade is not None:
        paste_masked(img, fill((W, H), (0, 0, 0)), ImageChops.multiply(shade, m).point(lambda v: v * shade_alpha // 255))
    img.alpha_composite(sheen((W, H), m, 0.45, 70))


def disc(W, r, cx=None, cy=None):
    cx = W / 2 if cx is None else cx
    cy = W / 2 if cy is None else cy
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).ellipse((cx - u(r), cy - u(r), cx + u(r), cy + u(r)), fill=255)
    return m.filter(ImageFilter.GaussianBlur(0.3 * SS))


def radial_face(W, hi, lo, reach=27):
    c = W / 2
    yy, xx = np.mgrid[0:W, 0:W]
    r = np.sqrt((xx - c * 0.85) ** 2 + (yy - c * 0.72) ** 2) / u(reach)
    r = np.clip(r, 0, 1)[:, :, None]
    face = (np.array(hi) * (1 - r) + np.array(lo) * r).astype(np.uint8)
    return Image.fromarray(face, "RGB").convert("RGBA")


# -- focus crests --------------------------------------------------------------------------------
# Steel outer band with rivets, a thin gold ring inside it, a coloured face: the guild set reads
# as "iron and gold" next to the Achievements crests' gold band.

def medallion(face_hi, face_lo):
    img = canvas(64, 64)
    W = img.width
    paste_masked(img, fill((W, W), (4, 4, 6)), disc(W, 31.4))
    steel = vgrad((W, W), [(0.0, (214, 220, 232)), (0.3, (160, 166, 180)), (0.65, (96, 102, 116)),
                           (0.9, (52, 56, 66)), (1.0, (96, 102, 116))])
    paste_masked(img, steel, disc(W, 30))
    d = ImageDraw.Draw(img)
    c = W / 2
    for i in range(12):   # rivets
        a = i * math.pi / 6
        x, y = c + u(27.6) * math.cos(a), c + u(27.6) * math.sin(a)
        d.ellipse((x - u(1.15), y - u(1.15), x + u(1.15), y + u(1.15)), fill=(30, 32, 38, 255))
        d.ellipse((x - u(0.8), y - u(0.95), x + u(0.5), y + u(0.2)), fill=(236, 240, 250, 230))
    paste_masked(img, fill((W, W), (6, 5, 3)), disc(W, 25.4))
    paste_masked(img, gold_band((W, W)), disc(W, 24.6))
    face_m = disc(W, 22.6)
    paste_masked(img, grain(radial_face(W, face_hi, face_lo), 4), face_m)
    img.alpha_composite(inner_shadow((W, W), face_m, depth=2, strength=210))
    return img, face_m


def finish(img, face_m):
    W = img.width
    hl = Image.new("L", (W, W), 0)
    ImageDraw.Draw(hl).ellipse((u(13), u(8), u(51), u(29)), fill=34)
    hl = ImageChops.multiply(hl.filter(ImageFilter.GaussianBlur(3 * SS)), face_m)
    layer = Image.new("RGBA", (W, W), (255, 250, 235, 0))
    layer.putalpha(hl)
    img.alpha_composite(layer)
    img.alpha_composite(sheen((W, W), img.getchannel("A"), 0.42, 46))
    return img


def sym_raiding(img):
    """A horned skull: the raid boss."""
    W = img.width
    lh = [(21, 25), (9, 17), (6, 6), (14, 13), (24, 20)]
    rh = [(64 - x, y) for x, y in lh]
    horn = vgrad((W, W), [(0, (240, 226, 190)), (0.5, (170, 140, 96)), (1, (90, 64, 34))])
    emblem(img, mask_from(lambda d: (d.polygon(P(lh), fill=255), d.polygon(P(rh), fill=255))), horn, outline=1.8)

    def skull(d):
        d.ellipse(P([(17, 14), (47, 42)]), fill=255)
        d.rounded_rectangle(P([(23, 34), (41, 50)]), radius=u(4), fill=255)
    emblem(img, mask_from(skull), bone_fill((W, W)), outline=2.2)
    d = ImageDraw.Draw(img)
    # eye sockets glowing ember-red
    for x0 in (21.5, 34.5):
        d.ellipse(P([(x0, 26), (x0 + 8, 34)]), fill=(16, 6, 6, 255))
    glow = Image.new("L", img.size, 0)
    gd = ImageDraw.Draw(glow)
    for x0 in (23.5, 36.5):
        gd.ellipse(P([(x0, 28), (x0 + 4, 32)]), fill=255)
    layer = Image.new("RGBA", img.size, (255, 96, 30, 0))
    layer.putalpha(glow.filter(ImageFilter.GaussianBlur(0.9 * SS)))
    img.alpha_composite(layer)
    for x0 in (24.6, 37.6):
        d.ellipse(P([(x0, 29.2), (x0 + 1.8, 31)]), fill=(255, 230, 150, 255))
    d.polygon(P([(32, 35), (29.8, 39.5), (34.2, 39.5)]), fill=(30, 20, 14, 255))   # nose
    for x in (26, 30, 34, 38):                                                    # teeth gaps
        d.line(P([(x, 43), (x, 49.5)]), fill=(60, 44, 30, 255), width=wi(1.1))
    d.line(P([(23.5, 43), (40.5, 43)]), fill=(60, 44, 30, 255), width=wi(1.0))


def sym_leveling(img):
    """An open book with a gold arrow rising out of it."""
    W = img.width

    def pages(d):
        d.polygon(P([(9, 30), (31, 34), (31, 53), (9, 48)]), fill=255)
        d.polygon(P([(55, 30), (33, 34), (33, 53), (55, 48)]), fill=255)
    cover = mask_from(lambda d: d.polygon(P([(7, 31), (32, 36), (57, 31), (57, 51), (32, 56), (7, 51)]), fill=255))
    emblem(img, cover, vgrad((W, W), [(0, (110, 60, 30)), (1, (60, 28, 12))]), outline=1.8)
    paper = vgrad((W, W), [(0, (255, 250, 232)), (0.6, (236, 222, 186)), (1, (190, 168, 124))])
    shade = mask_from(lambda d: d.polygon(P([(55, 30), (33, 34), (33, 53), (55, 48)]), fill=255))
    emblem(img, mask_from(pages), paper, outline=0.8, shade=shade, shade_alpha=40)
    d = ImageDraw.Draw(img)
    for i in range(3):  # lines of text
        y = 38 + i * 4
        d.line(P([(12, y - 1.6 + i * 0.1), (28, y + 1.2)]), fill=(120, 96, 64, 200), width=wi(1.0))
        d.line(P([(36, y + 1.2), (52, y - 1.6 + i * 0.1)]), fill=(120, 96, 64, 200), width=wi(1.0))
    arrow = mask_from(lambda d2: d2.polygon(P([(32, 7), (43, 19), (36.5, 19), (36.5, 31), (27.5, 31), (27.5, 19),
                                               (21, 19)]), fill=255))
    emblem(img, arrow, vgrad((W, W), [(0, (200, 255, 170)), (0.5, (90, 210, 90)), (1, (30, 120, 40))]), outline=2.0)


def sym_pvp(img):
    """Two crossed swords behind a round buckler."""
    W = img.width

    def sword(d):
        d.polygon(P([(32, 4), (34.6, 9), (34.6, 38), (29.4, 38), (29.4, 9)]), fill=255)

    def hilt(d):
        d.rounded_rectangle(P([(24, 37.5), (40, 41.5)]), radius=u(1.5), fill=255)
        d.rectangle(P([(30.4, 41), (33.6, 50)]), fill=255)
        d.ellipse(P([(28.8, 49), (35.2, 55.4)]), fill=255)
    for deg in (40, -40):
        emblem(img, rotate_mask(mask_from(sword), deg), steel_fill((W, W)), outline=1.7)
        emblem(img, rotate_mask(mask_from(hilt), deg), gold_fill((W, W)), outline=1.7)
    buck = mask_from(lambda d: d.ellipse(P([(25, 25), (39, 39)]), fill=255))
    emblem(img, buck, vgrad((W, W), [(0, (236, 90, 70)), (0.6, (170, 36, 28)), (1, (100, 18, 14))]), outline=1.8)
    ring = mask_from(lambda d: d.ellipse(P([(26.2, 26.2), (37.8, 37.8)]), outline=255, width=wi(1.4)))
    paste_masked(img, gold_fill((W, W)), ring)
    boss = mask_from(lambda d: d.ellipse(P([(29.8, 29.8), (34.2, 34.2)]), fill=255))
    emblem(img, boss, gold_fill((W, W)), outline=0.8)


def sym_social(img):
    """A foaming tankard of ale."""
    W = img.width
    handle = mask_from(lambda d: d.rounded_rectangle(P([(36, 24), (52, 44)]), radius=u(6), outline=255, width=wi(4.2)))
    emblem(img, handle, wood_fill((W, W)), outline=1.6)
    body = mask_from(lambda d: d.rounded_rectangle(P([(15, 20), (41, 53)]), radius=u(3), fill=255))
    emblem(img, body, wood_fill((W, W)), outline=2.0)
    d = ImageDraw.Draw(img)
    for y in (27, 46):   # iron hoops
        d.rectangle(P([(15, y), (41, y + 3)]), fill=(40, 42, 48, 255))
        d.line(P([(15, y + 0.6), (41, y + 0.6)]), fill=(170, 176, 190, 255), width=wi(0.8))
    for x in (22, 28, 34):   # staves
        d.line(P([(x, 30.5), (x, 45.5)]), fill=(70, 38, 14, 200), width=wi(0.9))

    def foam(d2):
        for cx, cy, r in ((17, 19, 5), (24, 15.5, 6.2), (32, 16, 6), (38.5, 19.5, 4.6), (28, 21, 6)):
            d2.ellipse(P([(cx - r, cy - r), (cx + r, cy + r)]), fill=255)
        d2.ellipse(P([(36.5, 21), (42, 30)]), fill=255)   # a drip down the side
    emblem(img, mask_from(foam), vgrad((W, W), [(0, (255, 255, 250)), (0.7, (244, 236, 214)), (1, (210, 196, 160))]),
           outline=1.4)


def sym_casual(img):
    """A campfire: crossed logs under a flame."""
    W = img.width
    for deg in (18, -18):
        log = mask_from(lambda d: d.rounded_rectangle(P([(12, 45), (52, 52)]), radius=u(3.5), fill=255))
        emblem(img, rotate_mask(log, deg, center=(32, 48.5)), wood_fill((W, W)), outline=1.6)
    d = ImageDraw.Draw(img)
    for x, y in ((14.5, 54.5), (49.5, 54.5)):   # log ends
        d.ellipse(P([(x - 3, y - 3), (x + 3, y + 3)]), fill=(232, 190, 130, 255))
        d.ellipse(P([(x - 1.4, y - 1.4), (x + 1.4, y + 1.4)]), fill=(150, 96, 50, 255))
    # glow behind the flame
    glow = Image.new("L", img.size, 0)
    ImageDraw.Draw(glow).ellipse(P([(16, 14), (48, 50)]), fill=150)
    layer = Image.new("RGBA", img.size, (255, 150, 40, 0))
    layer.putalpha(glow.filter(ImageFilter.GaussianBlur(4 * SS)))
    img.alpha_composite(layer)

    def flame(pts):
        return mask_from(lambda d2: d2.polygon(P(pts), fill=255))
    outer = [(32, 7), (38, 18), (44, 22), (45, 33), (41, 43), (32, 47), (23, 43), (19, 33), (22, 24), (26, 27),
             (27, 17)]
    emblem(img, flame(outer), vgrad((W, W), [(0, (255, 200, 80)), (0.5, (250, 110, 30)), (1, (200, 40, 16))]),
           outline=1.6)
    inner = [(33, 20), (37, 29), (39, 36), (36, 43), (32, 45), (27, 42), (26, 35), (29, 29), (30, 33)]
    m = flame(inner).filter(ImageFilter.GaussianBlur(0.4 * SS))
    paste_masked(img, vgrad((W, W), [(0, (255, 255, 220)), (1, (255, 216, 90))]), m)


FOCUS = [
    ("Raiding", sym_raiding, (122, 44, 40), (34, 8, 10)),
    ("Leveling", sym_leveling, (52, 96, 64), (12, 30, 18)),
    ("PvP", sym_pvp, (74, 80, 96), (18, 20, 28)),
    ("Social", sym_social, (126, 92, 44), (38, 24, 10)),
    ("Casual", sym_casual, (44, 66, 116), (10, 16, 36)),
]


def crest(symbol, hi, lo):
    img, face_m = medallion(hi, lo)
    symbol(img)
    return finish(img, face_m)


# -- portrait ------------------------------------------------------------------------------------
# Fills the whole 64x64 disc: the Classic frame's ring covers the outer few pixels.

def heater(x0, y0, x1, y1):
    w, h = x1 - x0, y1 - y0
    pts = [(x0, y0), (x1, y0), (x1, y0 + h * 0.42)]
    for i in range(1, 13):
        a = i / 12 * math.pi / 2
        pts.append((x1 - w * 0.5 * (1 - math.cos(a)), y0 + h * 0.42 + h * 0.58 * math.sin(a)))
    for i in range(1, 13):
        a = (1 - i / 12) * math.pi / 2
        pts.append((x0 + w * 0.5 * (1 - math.cos(a)), y0 + h * 0.42 + h * 0.58 * math.sin(a)))
    return pts


def portrait():
    img = canvas(64, 64)
    W = img.width
    # night-blue field with warm light from the top
    field = radial_face(W, (70, 80, 120), (8, 10, 22), reach=40)
    paste_masked(img, grain(field, 4), disc(W, 32))
    # two crossed banner poles with pennants behind the shield
    for side in (-1, 1):
        def pole(d, s=side):
            d.line(P([(32 + s * 4, 56), (32 + s * 19, 9)]), fill=255, width=wi(2.4))
        emblem(img, mask_from(pole), gold_fill((W, W)), outline=1.2)

        def pennant(d, s=side):
            d.polygon(P([(32 + s * 19, 10), (32 + s * 18, 22), (32 + s * 6, 22), (32 + s * 9.5, 16),
                         (32 + s * 6, 10)]), fill=255)
        cloth = (vgrad((W, W), [(0, (230, 70, 56)), (1, (120, 18, 14))]) if side < 0 else
                 vgrad((W, W), [(0, (90, 140, 240)), (1, (24, 44, 120))]))
        emblem(img, mask_from(pennant), cloth, outline=1.2)
    # the shield: per pale crimson | royal blue, a gold chevron, a gold star in chief
    sp = heater(17, 17, 47, 56)
    sm = mask_from(lambda d: d.polygon(P(sp), fill=255))
    emblem(img, sm, gold_fill((W, W)), outline=1.8)
    inner = heater(19.5, 19.5, 44.5, 53)
    left = mask_from(lambda d: (d.polygon(P(inner), fill=255), d.rectangle(P([(32, 0), (64, 64)]), fill=0)))
    right = mask_from(lambda d: (d.polygon(P(inner), fill=255), d.rectangle(P([(0, 0), (32, 64)]), fill=0)))
    paste_masked(img, vgrad((W, W), [(0, (214, 52, 42)), (1, (110, 14, 12))]), left)
    paste_masked(img, vgrad((W, W), [(0, (60, 104, 214)), (1, (16, 30, 100))]), right)
    im = mask_from(lambda d: d.polygon(P(inner), fill=255))
    chev = mask_from(lambda d: d.line(P([(18, 46), (32, 33), (46, 46)]), fill=255, width=wi(5), joint="curve"))
    chev = ImageChops.multiply(chev, im)
    emblem(img, chev, gold_fill((W, W)), outline=0.8)
    cx, cy, ro, ri = 32, 26.5, 5.2, 2.2
    star = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = ro if i % 2 == 0 else ri
        star.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    emblem(img, mask_from(lambda d: d.polygon(P(star), fill=255)), gold_fill((W, W)), outline=0.9)
    img.alpha_composite(inner_shadow((W, W), disc(W, 32), depth=2, strength=150))
    img.alpha_composite(sheen((W, W), sm, 0.4, 50))
    return img


def main(preview=None):
    pieces = [("Guilds_Portrait", portrait())]
    pieces += [("Guilds_Focus_" + key, crest(fn, hi, lo)) for key, fn, hi, lo in FOCUS]
    out = []
    for name, img in pieces:
        out.append((name, save(name, img, (64, 64))))
        print("  +", name, out[-1][1].size)
    if preview:
        os.makedirs(preview, exist_ok=True)
        sheet(out, os.path.join(preview, "guilds_art.png"), zoom=2)
        # as the listing cards show them (32 px) and the chips / picker (20 px), blown up to judge
        s32 = [(n, im.resize((32, 32), Image.LANCZOS)) for n, im in out]
        s20 = [(n, im.resize((20, 20), Image.LANCZOS)) for n, im in out]
        sheet(s32 + s20, os.path.join(preview, "guilds_art_small.png"), bg=(24, 25, 30, 255), zoom=3)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="write contact sheets into this folder")
    main(ap.parse_args().preview)
