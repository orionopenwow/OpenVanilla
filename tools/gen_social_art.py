#!/usr/bin/env python3
"""Art for the Dungeons and Social addons.

    py -3 tools/gen_social_art.py         writes the TGA + BLP pairs (see tools/artkit.py)

Pieces (all 32x32, drawn at 4x)
  Dungeons_Tank / Dungeons_Healer / Dungeons_Damage   round role badges: a slate disc with a
                                                      metal rim and the role's symbol (blue
                                                      shield, green cross, red sword)
  Dungeons_Star                                       gold endorsement star
  Social_Icon                                         title-bar icon: two figures on a slate tile
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

from artkit import (SS, EDGE_HI, GOLD_LO, canvas, fill, gold_band, grain, inner_shadow, paste_masked,
                    rr_mask, save, sheen, sheet, vgrad)

HERE = os.path.dirname(os.path.abspath(__file__))


def mask_from(draw_fn, size):
    m = Image.new("L", size, 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def soft_shadow(img, m, offset=1.5, blur=1.4, alpha=170):
    W, H = img.size
    sh = m.transform((W, H), Image.AFFINE, (1, 0, 0, 0, 1, -offset * SS)).filter(ImageFilter.GaussianBlur(blur * SS))
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    layer.putalpha(sh.point(lambda v: v * alpha // 255))
    img.alpha_composite(layer)


def badge(rim_stops, face_stops):
    """A round badge: dark outline, metal rim, recessed slate face."""
    img = canvas(32, 32)
    W, H = img.size
    o = 1.5 * SS
    outer = mask_from(lambda d: d.ellipse((o, o, W - o, H - o), fill=255), (W, H))
    soft_shadow(img, outer, 1, 1.2, 140)
    paste_masked(img, fill((W, H), (5, 6, 8)), outer)
    rim = mask_from(lambda d: d.ellipse((o + SS, o + SS, W - o - SS, H - o - SS), fill=255), (W, H))
    paste_masked(img, vgrad((W, H), rim_stops), rim)
    f = o + 3 * SS
    face = mask_from(lambda d: d.ellipse((f, f, W - f, H - f), fill=255), (W, H))
    paste_masked(img, grain(vgrad((W, H), face_stops), 4), face)
    img.alpha_composite(inner_shadow((W, H), face, depth=2, strength=190))
    return img, face


def symbol(img, m, stops, outline=(6, 8, 10)):
    W, H = img.size
    grow = m.filter(ImageFilter.MaxFilter(5))
    paste_masked(img, fill((W, H), outline), grow)
    paste_masked(img, vgrad((W, H), stops), m)
    img.alpha_composite(sheen((W, H), m, 0.55, 90))


STEEL = [(0, (196, 204, 220)), (0.5, (120, 128, 146)), (1, (70, 76, 90))]


def tank():
    img, _ = badge([(0, (150, 190, 255)), (0.5, (70, 110, 190)), (1, (30, 50, 100))],
                   [(0, (20, 30, 52)), (1, (10, 14, 26))])
    W, H = img.size
    cx = W / 2

    def shield(d):
        top, bot, half = 8.5 * SS, 24 * SS, 7 * SS
        pts = [(cx - half, top), (cx + half, top), (cx + half, top + 7 * SS)]
        for i in range(0, 13):
            a = i / 12
            x = cx + half * (1 - a)
            y = top + 7 * SS + (bot - top - 7 * SS) * math.sin(a * math.pi / 2)
            pts.append((x, y))
        for i in range(12, -1, -1):
            a = i / 12
            x = cx - half * (1 - a)
            y = top + 7 * SS + (bot - top - 7 * SS) * math.sin(a * math.pi / 2)
            pts.append((x, y))
        d.polygon(pts, fill=255)
    m = mask_from(shield, (W, H))
    symbol(img, m, [(0, (170, 205, 255)), (0.5, (80, 130, 220)), (1, (36, 70, 150))])
    # a steel boss down the middle
    bar = mask_from(lambda d: d.rectangle((cx - 1 * SS, 10 * SS, cx + 1 * SS, 21 * SS), fill=255), (W, H))
    paste_masked(img, vgrad((W, H), STEEL), bar)
    return img


def healer():
    img, _ = badge([(0, (150, 255, 170)), (0.5, (60, 170, 90)), (1, (20, 80, 40))],
                   [(0, (18, 40, 26)), (1, (8, 18, 12))])
    W, H = img.size
    c, a, b = W / 2, 2.6 * SS, 7.5 * SS

    def cross(d):
        d.rounded_rectangle((c - a, c - b, c + a, c + b), radius=SS, fill=255)
        d.rounded_rectangle((c - b, c - a, c + b, c + a), radius=SS, fill=255)
    m = mask_from(cross, (W, H))
    symbol(img, m, [(0, (190, 255, 190)), (0.5, (80, 220, 110)), (1, (30, 140, 60))])
    return img


def damage():
    img, _ = badge([(0, (255, 160, 140)), (0.5, (190, 70, 56)), (1, (90, 24, 18))],
                   [(0, (48, 18, 16)), (1, (22, 8, 8))])
    W, H = img.size

    def blade(d):
        # a sword pointing up-right: blade, guard, grip
        d.polygon([(22.5 * SS, 8.5 * SS), (23.5 * SS, 9.5 * SS), (13.5 * SS, 19.5 * SS), (12.5 * SS, 18.5 * SS)], fill=255)
        d.polygon([(23.6 * SS, 7.6 * SS), (21.2 * SS, 8.4 * SS), (22.8 * SS, 10.0 * SS)], fill=255)
    m = mask_from(blade, (W, H))
    m = m.filter(ImageFilter.MaxFilter(3))
    symbol(img, m, [(0, (250, 250, 255)), (0.6, (180, 186, 200)), (1, (110, 116, 130))])

    def hilt(d):
        d.line((10 * SS, 16 * SS, 16 * SS, 22 * SS), fill=255, width=int(2.2 * SS))
        d.line((9 * SS, 23 * SS, 12.5 * SS, 19.5 * SS), fill=255, width=int(2.4 * SS))
    h = mask_from(hilt, (W, H))
    symbol(img, h, [(0, (255, 226, 140)), (0.5, (214, 160, 60)), (1, GOLD_LO)])
    return img


def star():
    img = canvas(32, 32)
    W, H = img.size
    cx, cy, ro, ri = W / 2, H / 2 + 0.6 * SS, 13.5 * SS, 5.6 * SS
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = ro if i % 2 == 0 else ri
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    m = mask_from(lambda d: d.polygon(pts, fill=255), (W, H))
    soft_shadow(img, m, 1.2, 1.2, 160)
    paste_masked(img, fill((W, H), (40, 24, 4)), m.filter(ImageFilter.MaxFilter(5)))
    paste_masked(img, gold_band((W, H)), m)
    inner = [(cx + (p[0] - cx) * 0.55, cy + (p[1] - cy) * 0.55) for p in pts]
    mi = mask_from(lambda d: d.polygon(inner, fill=255), (W, H))
    paste_masked(img, vgrad((W, H), [(0, (255, 246, 200)), (1, (255, 200, 60))]), mi)
    img.alpha_composite(sheen((W, H), m, 0.5, 80))
    return img


def social_icon():
    img = canvas(32, 32)
    W, H = img.size
    tile = rr_mask((W, H), (1 * SS, 1 * SS, W - 1 * SS, H - 1 * SS), 5 * SS)
    paste_masked(img, fill((W, H), (6, 7, 9)), tile)
    rim = rr_mask((W, H), (2 * SS, 2 * SS, W - 2 * SS, H - 2 * SS), 4 * SS)
    paste_masked(img, vgrad((W, H), [(0, EDGE_HI), (1, (58, 62, 72))]), rim)
    face = rr_mask((W, H), (3.5 * SS, 3.5 * SS, W - 3.5 * SS, H - 3.5 * SS), 3 * SS)
    paste_masked(img, grain(vgrad((W, H), [(0, (36, 40, 50)), (1, (14, 16, 20))]), 4), face)
    img.alpha_composite(inner_shadow((W, H), face, depth=2, strength=170))

    def person(d, x, y, s):
        d.ellipse((x - 3.2 * s, y - 9 * s, x + 3.2 * s, y - 2.6 * s), fill=255)
        d.chord((x - 6.4 * s, y - 1.5 * s, x + 6.4 * s, y + 11 * s), 180, 360, fill=255)
    back = mask_from(lambda d: person(d, 20.5 * SS, 16 * SS, SS * 0.9), (W, H))
    back = Image.composite(back, Image.new("L", (W, H), 0), face)
    symbol(img, back, STEEL)
    front = mask_from(lambda d: person(d, 13 * SS, 19 * SS, SS), (W, H))
    front = Image.composite(front, Image.new("L", (W, H), 0), face)
    symbol(img, front, [(0, (255, 236, 168)), (0.5, (226, 172, 74)), (1, GOLD_LO)])
    return img


def main():
    pieces = [
        ("Dungeons_Tank", tank()), ("Dungeons_Healer", healer()), ("Dungeons_Damage", damage()),
        ("Dungeons_Star", star()), ("Social_Icon", social_icon()),
    ]
    outs = []
    for name, img in pieces:
        outs.append((name, save(name, img, (32, 32))))
    preview = os.environ.get("SOCIAL_ART_PREVIEW")
    if preview:
        sheet(outs, preview, zoom=4)
    print("wrote " + ", ".join(n for n, _ in pieces))


if __name__ == "__main__":
    main()
