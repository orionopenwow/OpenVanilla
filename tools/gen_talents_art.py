#!/usr/bin/env python3
"""Art for Talents and the Bags gear sets.

    py -3 tools/gen_talents_art.py        writes the TGA + BLP pairs (see tools/artkit.py)

Pieces
  Talents_Icon     32x32  a gold talent tree (trunk, three branches, rank nodes) on a slate disc;
                          the Talents panel and the planner's title strip
  Bags_GearSets    32x32  a steel breastplate with a gold swap loop; the Gear Sets button on the
                          Bags and character windows and the sets panel's title
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

from artkit import (SS, EDGE, EDGE_HI, GOLD, GOLD_HI, GOLD_LO, GOLD_MID, SLATE, SLATE_HI, canvas, drop_shadow,
                    fill, gold_band, grain, inner_shadow, paste_masked, save, sheen, sheet, vgrad)

HERE = os.path.dirname(os.path.abspath(__file__))


def disc(img, inset=1.0):
    """Dark slate disc with a thin steel rim; returns the face mask."""
    W, H = img.size
    o = inset * SS
    rim = Image.new("L", (W, H), 0)
    ImageDraw.Draw(rim).ellipse((o, o, W - 1 - o, H - 1 - o), fill=255)
    paste_masked(img, vgrad((W, H), [(0, EDGE_HI), (1, (48, 52, 60))]), rim)
    face = Image.new("L", (W, H), 0)
    ImageDraw.Draw(face).ellipse((o + 1.5 * SS, o + 1.5 * SS, W - 1 - o - 1.5 * SS, H - 1 - o - 1.5 * SS), fill=255)
    paste_masked(img, grain(vgrad((W, H), [(0, SLATE_HI), (1, (12, 13, 16))]), 4), face)
    img.alpha_composite(inner_shadow((W, H), face, depth=2, strength=190))
    return face


def talents_icon():
    img = canvas(32, 32)
    W, H = img.size
    face = disc(img)
    # the tree: a trunk from the bottom, three branches, a node at each tip
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    cx = W / 2
    base, fork = H - 7.5 * SS, H - 15 * SS
    lw = int(2.2 * SS)
    d.line((cx, base, cx, fork), fill=255, width=lw)
    tips = [(cx - 7 * SS, 9.5 * SS), (cx, 7 * SS), (cx + 7 * SS, 9.5 * SS)]
    for tx, ty in tips:
        d.line((cx, fork, tx, ty + 2 * SS), fill=255, width=lw)
    d.line((cx - 5 * SS, base, cx + 5 * SS, base), fill=255, width=lw)        # the ground
    nodes = Image.new("L", (W, H), 0)
    dn = ImageDraw.Draw(nodes)
    r = 2.6 * SS
    for tx, ty in tips:
        dn.ellipse((tx - r, ty - r, tx + r, ty + r), fill=255)
    dn.ellipse((cx - 2 * SS, fork - 2 * SS, cx + 2 * SS, fork + 2 * SS), fill=255)
    shape = Image.composite(Image.new("L", (W, H), 255), m, nodes)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.putalpha(shape.transform((W, H), Image.AFFINE, (1, 0, 0, 0, 1, -SS)).filter(ImageFilter.GaussianBlur(SS)).point(lambda v: v * 170 // 255))
    img.alpha_composite(shadow)
    paste_masked(img, gold_band((W, H)), shape)
    # node centres glow a little brighter
    hot = Image.new("L", (W, H), 0)
    dh = ImageDraw.Draw(hot)
    for tx, ty in tips:
        dh.ellipse((tx - SS, ty - SS, tx + SS, ty + SS), fill=255)
    paste_masked(img, fill((W, H), GOLD_HI), hot.filter(ImageFilter.GaussianBlur(0.5 * SS)))
    img.alpha_composite(sheen((W, H), face, 0.5, 40))
    return img


def gear_sets():
    img = canvas(32, 32)
    W, H = img.size
    face = disc(img)
    # breastplate: shoulders, a waist, a centre ridge
    plate = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(plate)
    cx = W / 2
    pts = [(cx - 10.5 * SS, 10 * SS), (cx - 6.5 * SS, 7 * SS), (cx - 3 * SS, 7.5 * SS), (cx, 11.5 * SS),
           (cx + 3 * SS, 7.5 * SS), (cx + 6.5 * SS, 7 * SS), (cx + 10.5 * SS, 10 * SS), (cx + 7.5 * SS, 13.5 * SS),
           (cx + 6.5 * SS, 21.5 * SS), (cx, 25 * SS), (cx - 6.5 * SS, 21.5 * SS), (cx - 7.5 * SS, 13.5 * SS)]
    d.polygon(pts, fill=255)
    plate = plate.filter(ImageFilter.GaussianBlur(0.4 * SS))
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh.putalpha(plate.transform((W, H), Image.AFFINE, (1, 0, 0, 0, 1, -SS)).filter(ImageFilter.GaussianBlur(SS)).point(lambda v: v * 170 // 255))
    img.alpha_composite(sh)
    paste_masked(img, vgrad((W, H), [(0, (214, 218, 228)), (0.45, (132, 138, 150)), (1, (64, 68, 78))]), plate)
    lines = Image.new("L", (W, H), 0)
    dr = ImageDraw.Draw(lines)
    dr.line((cx, 12 * SS, cx, 24 * SS), fill=255, width=SS)                          # centre ridge
    dr.arc((cx - 7 * SS, 10 * SS, cx + 1 * SS, 18 * SS), start=20, end=160, fill=255, width=SS)   # chest plates
    dr.arc((cx - 1 * SS, 10 * SS, cx + 7 * SS, 18 * SS), start=20, end=160, fill=255, width=SS)
    paste_masked(img, fill((W, H), (44, 46, 54)), lines)
    # a gold swap loop in a dark well at the lower right
    well = Image.new("L", (W, H), 0)
    wx, wy, wr = cx + 7.5 * SS, 21.5 * SS, 6 * SS
    ImageDraw.Draw(well).ellipse((wx - wr, wy - wr, wx + wr, wy + wr), fill=255)
    paste_masked(img, fill((W, H), (14, 15, 18)), well)
    loop = Image.new("L", (W, H), 0)
    dl = ImageDraw.Draw(loop)
    r = 3.6 * SS
    dl.arc((wx - r, wy - r, wx + r, wy + r), start=-60, end=200, fill=255, width=int(1.6 * SS))
    ax, ay = wx + r * math.cos(math.radians(-60)), wy + r * math.sin(math.radians(-60))
    dl.polygon([(ax - 2.2 * SS, ay - 1.6 * SS), (ax + 2.4 * SS, ay - 1.2 * SS), (ax + 0.2 * SS, ay + 2.4 * SS)], fill=255)
    paste_masked(img, gold_band((W, H)), loop)
    img.alpha_composite(sheen((W, H), face, 0.5, 40))
    return img


def main():
    pieces = [("Talents_Icon", talents_icon()), ("Bags_GearSets", gear_sets())]
    out = []
    for name, img in pieces:
        out.append((name, save(name, img)))
        print("  +", name, out[-1][1].size)
    scratch = os.environ.get("ART_PREVIEW")
    if scratch:
        sheet(out, scratch, zoom=6)
        print("  preview", scratch)


if __name__ == "__main__":
    main()
