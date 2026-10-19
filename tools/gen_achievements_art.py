#!/usr/bin/env python3
"""Achievements art: points shields, window frame bits, category tabs, rows, the toast banner.

    python3 tools/gen_achievements_art.py      writes the TGA + BLP pairs (see tools/artkit.py)
    python3 tools/gen_achievements_art.py --preview DIR   also writes contact sheets into DIR

Pieces (all have flat fallbacks in the addon)
  Ach_Shield            64x64   gold points shield beside the total (number drawn by the addon)
  Ach_ShieldSmall       32x32   gold shield on an earned row / the banner
  Ach_ShieldSmallGrey   32x32   steel shield on a row not earned yet
  Ach_Tab / Ach_TabSel  256x32  category button, normal and selected
  Ach_Row / Ach_RowEarned 512x64  achievement row, not earned and earned
  Ach_Toast             512x128 "Achievement Earned" banner (shown 320x80)
  Ach_Shine             128x128 soft light streak that sweeps across the banner (ADD blend)
  Ach_TitleCrest        256x32  gold crest behind the window title
  Ach_Corner            32x32   gold corner bracket (top-left; the addon mirrors it)
  Ach_BarFrame          512x32  gold frame around the overall progress bar
  Ach_Cat_<Key>         64x64   category crests: a gold-rimmed medallion with the category's symbol
                                (General, Quests, Exploration, Dungeons, Raids, Professions,
                                Reputation, PvP, Feats); drawn to read at 20 px on the buttons
  Ach_Tile              256x64  "Progress by category" tile (slate face, thin gold inner rim)
  Ach_Empty             128x128 empty "Recent achievements": an unlit shield on a stone pedestal
"""
import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

from artkit import (SS, EDGE, EDGE_HI, GOLD, GOLD_HI, GOLD_LO, GOLD_MID, INK, SLATE, SLATE_HI, SLATE_LO, canvas,
                    drop_shadow, fill, gold_band, grain, inner_shadow, paste_masked, rr_mask, save, sheen, sheet,
                    vgrad)

HERE = os.path.dirname(os.path.abspath(__file__))

STEEL_HI = (196, 200, 210)
STEEL = (120, 124, 134)
STEEL_LO = (58, 60, 68)


def steel_band(size):
    return vgrad(size, [(0.0, STEEL_HI), (0.25, (160, 164, 174)), (0.6, STEEL), (0.9, STEEL_LO), (1.0, STEEL)])


def shield_points(x0, y0, x1, y1):
    """A heater shield: flat top with two shallow notches, straight sides, curved to a point."""
    w, h = x1 - x0, y1 - y0
    pts = [(x0, y0 + h * 0.06), (x0 + w * 0.22, y0), (x0 + w * 0.5, y0 + h * 0.07), (x0 + w * 0.78, y0),
           (x1, y0 + h * 0.06), (x1, y0 + h * 0.45)]
    # right curve down to the point
    for i in range(1, 13):
        t = i / 12
        a = t * math.pi / 2
        pts.append((x1 - w * 0.5 * (1 - math.cos(a)), y0 + h * 0.45 + h * 0.55 * math.sin(a)))
    for i in range(1, 13):
        t = i / 12
        a = (1 - t) * math.pi / 2
        pts.append((x0 + w * 0.5 * (1 - math.cos(a)), y0 + h * 0.45 + h * 0.55 * math.sin(a)))
    pts.append((x0, y0 + h * 0.45))
    return pts


def poly_mask(size, pts):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.filter(ImageFilter.GaussianBlur(0.35 * SS))


def shrink(pts, cx, cy, k):
    return [(cx + (x - cx) * k, cy + (y - cy) * k) for x, y in pts]


def shield(size, metal="gold"):
    img = canvas(size, size)
    W, H = img.size
    m = 3 * SS if size >= 64 else 1.5 * SS
    pts = shield_points(m, m, W - m, H - m * 1.4)
    cx, cy = W / 2, H * 0.47
    outer = poly_mask((W, H), pts)
    band = gold_band((W, H)) if metal == "gold" else steel_band((W, H))
    paste_masked(img, fill((W, H), (6, 5, 3)), outer.filter(ImageFilter.MaxFilter(5)))
    paste_masked(img, band, outer)
    inner = poly_mask((W, H), shrink(pts, cx, cy, 0.80))
    if metal == "gold":
        face = vgrad((W, H), [(0, (64, 42, 14)), (0.5, (40, 26, 9)), (1, (22, 14, 5))])
    else:
        face = vgrad((W, H), [(0, (44, 47, 54)), (0.5, (30, 32, 38)), (1, (18, 19, 23))])
    paste_masked(img, grain(face, 4), inner)
    img.alpha_composite(inner_shadow((W, H), inner, depth=2 if size >= 64 else 1, strength=200))
    rim = poly_mask((W, H), shrink(pts, cx, cy, 0.86))
    ring = Image.new("L", (W, H), 0)
    ring.paste(rim)
    ring = Image.composite(ring, Image.new("L", (W, H), 0), Image.eval(inner, lambda v: 255 - v))
    paste_masked(img, fill((W, H), GOLD_LO if metal == "gold" else STEEL_LO), ring.point(lambda v: v // 2))
    img.alpha_composite(sheen((W, H), outer, 0.5, 90))
    return drop_shadow(img, (0, 1), 1.5, 140)


def tab(selected):
    img = canvas(256, 32)
    W, H = img.size
    box = (SS, SS, W - SS - 1, H - SS - 1)
    paste_masked(img, fill((W, H), (6, 7, 9)), rr_mask((W, H), box, 3 * SS))
    edge = gold_band((W, H)) if selected else vgrad((W, H), [(0, EDGE_HI), (1, (54, 58, 68))])
    paste_masked(img, edge, rr_mask((W, H), (2 * SS, 2 * SS, W - 2 * SS - 1, H - 2 * SS - 1), 3 * SS))
    fm = rr_mask((W, H), (3 * SS, 3 * SS, W - 3 * SS - 1, H - 3 * SS - 1), 2 * SS)
    if selected:
        face = vgrad((W, H), [(0, (74, 56, 22)), (0.5, (48, 36, 14)), (1, (30, 22, 9))])
    else:
        face = vgrad((W, H), [(0, (36, 38, 45)), (0.5, (24, 26, 31)), (1, (15, 16, 19))])
    paste_masked(img, grain(face, 4), fm)
    img.alpha_composite(sheen((W, H), fm, 0.5, 40 if selected else 22))
    if selected:
        # a gold notch on the left edge
        d = ImageDraw.Draw(img)
        d.rectangle((3 * SS, 6 * SS, 5 * SS, H - 6 * SS), fill=GOLD + (255,))
        glow = Image.new("RGBA", (W, H), (255, 210, 90, 0))
        gm = Image.new("L", (W, H), 0)
        ImageDraw.Draw(gm).rectangle((3 * SS, 4 * SS, 40 * SS, H - 4 * SS), fill=70)
        glow.putalpha(gm.filter(ImageFilter.GaussianBlur(8 * SS)))
        img.alpha_composite(glow)
    return img


def row(earned):
    img = canvas(512, 64)
    W, H = img.size
    paste_masked(img, fill((W, H), (6, 7, 9)), rr_mask((W, H), (0, 0, W - 1, H - 1), 3 * SS))
    edge = vgrad((W, H), [(0, (150, 120, 60)), (1, (70, 54, 24))]) if earned else vgrad((W, H), [(0, (84, 90, 104)), (1, (40, 43, 50))])
    paste_masked(img, edge, rr_mask((W, H), (SS, SS, W - SS - 1, H - SS - 1), 3 * SS))
    fm = rr_mask((W, H), (2 * SS, 2 * SS, W - 2 * SS - 1, H - 2 * SS - 1), 2 * SS)
    if earned:
        face = vgrad((W, H), [(0, (58, 46, 22)), (0.5, (40, 32, 15)), (1, (26, 21, 10))])
    else:
        face = vgrad((W, H), [(0, (30, 32, 38)), (0.5, (21, 22, 27)), (1, (14, 15, 18))])
    paste_masked(img, grain(face, 5), fm)
    img.alpha_composite(inner_shadow((W, H), fm, depth=2, strength=120))
    img.alpha_composite(sheen((W, H), fm, 0.45, 26 if earned else 16))
    if earned:
        # warm light from the left where the icon sits
        glow = Image.new("RGBA", (W, H), (255, 200, 90, 0))
        gm = Image.new("L", (W, H), 0)
        ImageDraw.Draw(gm).ellipse((-160 * SS, -60 * SS, 150 * SS, H + 60 * SS), fill=55)
        glow.putalpha(Image.composite(gm.filter(ImageFilter.GaussianBlur(40 * SS)), Image.new("L", (W, H), 0), fm))
        img.alpha_composite(glow)
    return img


def toast():
    img = canvas(512, 128)
    W, H = img.size
    cy = H / 2
    # plaque with pointed ends (the banner shape of the mockup's crest)
    pts = [(34 * SS, 16 * SS), (W - 34 * SS, 16 * SS), (W - 6 * SS, cy), (W - 34 * SS, H - 16 * SS),
           (34 * SS, H - 16 * SS), (6 * SS, cy)]
    outer = poly_mask((W, H), pts)
    paste_masked(img, fill((W, H), (5, 4, 2)), outer.filter(ImageFilter.MaxFilter(9)))
    paste_masked(img, gold_band((W, H)), outer)
    inner_pts = [(40 * SS, 21 * SS), (W - 40 * SS, 21 * SS), (W - 14 * SS, cy), (W - 40 * SS, H - 21 * SS),
                 (40 * SS, H - 21 * SS), (14 * SS, cy)]
    inner = poly_mask((W, H), inner_pts)
    face = vgrad((W, H), [(0, (40, 34, 22)), (0.45, (22, 20, 16)), (1, (12, 11, 10))])
    paste_masked(img, grain(face, 5), inner)
    img.alpha_composite(inner_shadow((W, H), inner, depth=3, strength=200))
    # thin inner gold line
    line_pts = [(46 * SS, 26 * SS), (W - 46 * SS, 26 * SS), (W - 21 * SS, cy), (W - 46 * SS, H - 26 * SS),
                (46 * SS, H - 26 * SS), (21 * SS, cy)]
    lm = Image.new("L", (W, H), 0)
    ImageDraw.Draw(lm).polygon(line_pts, outline=200, width=SS)
    paste_masked(img, fill((W, H), GOLD_MID), lm.filter(ImageFilter.GaussianBlur(0.3 * SS)))
    # icon socket on the left, a darker well
    sock = Image.new("L", (W, H), 0)
    ImageDraw.Draw(sock).rounded_rectangle((36 * SS, cy - 36 * SS, 108 * SS, cy + 36 * SS), radius=6 * SS, fill=255)
    paste_masked(img, fill((W, H), (8, 7, 6)), sock.filter(ImageFilter.GaussianBlur(6 * SS)).point(lambda v: v * 120 // 255))
    # a soft gold glow at the top centre behind the "Achievement Earned" header
    glow = Image.new("RGBA", (W, H), (255, 214, 110, 0))
    gm = Image.new("L", (W, H), 0)
    ImageDraw.Draw(gm).ellipse((W / 2 - 170 * SS, -10 * SS, W / 2 + 170 * SS, 62 * SS), fill=80)
    glow.putalpha(Image.composite(gm.filter(ImageFilter.GaussianBlur(22 * SS)), Image.new("L", (W, H), 0), inner))
    img.alpha_composite(glow)
    img.alpha_composite(sheen((W, H), outer, 0.4, 70))
    # little wings at both points
    d = ImageDraw.Draw(img)
    for side in (-1, 1):
        x = W / 2 + side * (W / 2 - 8 * SS)
        for k in range(3):
            o = (k + 1) * 5 * SS
            d.line([(x - side * o, cy - 10 * SS - k * 3 * SS), (x - side * (o + 10 * SS), cy - 2 * SS)], fill=GOLD_HI + (200,), width=SS)
            d.line([(x - side * o, cy + 10 * SS + k * 3 * SS), (x - side * (o + 10 * SS), cy + 2 * SS)], fill=GOLD_HI + (200,), width=SS)
    return drop_shadow(img, (0, 3), 4, 170)


def shine():
    img = canvas(128, 128)
    W, H = img.size
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    # a slanted band of light with a brighter core
    d.polygon([(W * 0.42, 0), (W * 0.62, 0), (W * 0.58, H), (W * 0.38, H)], fill=110)
    d.polygon([(W * 0.49, 0), (W * 0.55, 0), (W * 0.51, H), (W * 0.45, H)], fill=230)
    m = m.filter(ImageFilter.GaussianBlur(7 * SS))
    # fade the ends
    fade = vgrad((W, H), [(0, (0, 0, 0)), (0.3, (255, 255, 255)), (0.7, (255, 255, 255)), (1, (0, 0, 0))]).convert("L")
    m = Image.composite(m, Image.new("L", (W, H), 0), fade)
    out = Image.new("RGBA", (W, H), (255, 236, 190, 0))
    out.putalpha(m)
    return out


def title_crest():
    img = canvas(256, 32)
    W, H = img.size
    cy = H / 2
    pts = [(22 * SS, 3 * SS), (W - 22 * SS, 3 * SS), (W - 3 * SS, cy), (W - 22 * SS, H - 3 * SS), (22 * SS, H - 3 * SS), (3 * SS, cy)]
    outer = poly_mask((W, H), pts)
    paste_masked(img, fill((W, H), (5, 4, 2)), outer.filter(ImageFilter.MaxFilter(5)))
    paste_masked(img, gold_band((W, H)), outer)
    ip = [(25 * SS, 6 * SS), (W - 25 * SS, 6 * SS), (W - 9 * SS, cy), (W - 25 * SS, H - 6 * SS), (25 * SS, H - 6 * SS), (9 * SS, cy)]
    inner = poly_mask((W, H), ip)
    paste_masked(img, grain(vgrad((W, H), [(0, (44, 36, 22)), (1, (16, 14, 11))]), 4), inner)
    img.alpha_composite(inner_shadow((W, H), inner, depth=1.5, strength=200))
    img.alpha_composite(sheen((W, H), outer, 0.5, 60))
    return img


def corner():
    img = canvas(32, 32)
    W, H = img.size
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    t = 3 * SS
    d.rectangle((3 * SS, 3 * SS, W - 3 * SS, 3 * SS + t), fill=255)        # top arm
    d.rectangle((3 * SS, 3 * SS, 3 * SS + t, H - 3 * SS), fill=255)        # left arm
    d.polygon([(W - 3 * SS, 3 * SS), (W, 4.5 * SS), (W - 3 * SS, 3 * SS + t)], fill=255)   # arrow tips
    d.polygon([(3 * SS, H - 3 * SS), (4.5 * SS, H), (3 * SS + t, H - 3 * SS)], fill=255)
    c = 4.5 * SS
    d.polygon([(c, c - 5 * SS), (c + 5 * SS, c), (c, c + 5 * SS), (c - 5 * SS, c)], fill=255)  # diamond on the corner
    m = m.filter(ImageFilter.GaussianBlur(0.4 * SS))
    paste_masked(img, fill((W, H), (6, 5, 3)), m.filter(ImageFilter.MaxFilter(5)))
    paste_masked(img, gold_band((W, H)), m)
    img.alpha_composite(sheen((W, H), m, 0.6, 80))
    return img


def bar_frame():
    img = canvas(512, 32)
    W, H = img.size
    outer = rr_mask((W, H), (SS, 4 * SS, W - SS - 1, H - 4 * SS - 1), 4 * SS)
    inner = rr_mask((W, H), (5 * SS, 7 * SS, W - 5 * SS - 1, H - 7 * SS - 1), 2 * SS)
    ring = Image.composite(outer, Image.new("L", (W, H), 0), Image.eval(inner, lambda v: 255 - v))
    paste_masked(img, fill((W, H), (6, 5, 3)), ring.filter(ImageFilter.MaxFilter(3)))
    paste_masked(img, gold_band((W, H)), ring)
    # end caps
    d = ImageDraw.Draw(img)
    for x in (SS, W - 9 * SS):
        d.rounded_rectangle((x, 2 * SS, x + 8 * SS, H - 2 * SS), radius=2 * SS, fill=GOLD_MID + (255,), outline=(6, 5, 3, 255), width=SS)
    img.alpha_composite(sheen((W, H), ring, 0.5, 70))
    return img


# -- category crests ------------------------------------------------------------------------
# A round medallion: dark rim, gold band, a thin steel ring, a tinted face lit from the top, and a
# bold symbol in gold or parchment with a dark outline, so it still reads when drawn at 20 px.

PARCH_HI = (252, 240, 206)
PARCH = (224, 200, 150)
PARCH_LO = (150, 116, 70)


def gold_fill(size):
    return vgrad(size, [(0.0, GOLD_HI), (0.35, (250, 206, 90)), (0.7, (214, 156, 48)), (1.0, (150, 98, 28))])


def parch_fill(size):
    return vgrad(size, [(0.0, PARCH_HI), (0.6, PARCH), (1.0, PARCH_LO)])


def steel_fill(size):
    return vgrad(size, [(0.0, (236, 240, 248)), (0.45, (188, 194, 206)), (1.0, (112, 118, 132))])


def u(v):
    return v * SS


def wi(v):
    return int(round(v * SS))


def P(pts):
    return [(u(x), u(y)) for x, y in pts]


def mask_from(draw_fn, size=64):
    m = Image.new("L", (u(size), u(size)), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def rotate_mask(m, deg, center=(32, 32)):
    return m.rotate(deg, resample=Image.BICUBIC, center=(u(center[0]), u(center[1])))


def emblem(img, m, fillimg, outline=2.2, shade=None, shade_alpha=95):
    """Composite one symbol part: soft shadow, dark outline, metal/parchment fill, top sheen."""
    W, H = img.size
    m = m.filter(ImageFilter.GaussianBlur(0.3 * SS))
    k = int(outline * SS) * 2 + 1
    ol = m.filter(ImageFilter.MaxFilter(k))
    sh = ol.transform((W, H), Image.AFFINE, (1, 0, 0, 0, 1, -1.2 * SS)).filter(ImageFilter.GaussianBlur(1.6 * SS))
    paste_masked(img, fill((W, H), (0, 0, 0)), sh.point(lambda v: v * 150 // 255))
    paste_masked(img, fill((W, H), INK), ol)
    paste_masked(img, fillimg, m)
    if shade is not None:   # darker facet / side of the symbol
        paste_masked(img, fill((W, H), (0, 0, 0)), ImageChops.multiply(shade, m).point(lambda v: v * shade_alpha // 255))
    img.alpha_composite(sheen((W, H), m, 0.45, 70))


def medallion(face_hi, face_lo):
    img = canvas(64, 64)
    W, H = img.size
    c = W / 2

    def disc(r):
        m = Image.new("L", (W, H), 0)
        ImageDraw.Draw(m).ellipse((c - u(r), c - u(r), c + u(r), c + u(r)), fill=255)
        return m.filter(ImageFilter.GaussianBlur(0.3 * SS))

    outer, band_in, steel_in = disc(30), disc(25.6), disc(24.2)
    paste_masked(img, fill((W, H), (5, 4, 2)), disc(31.4))
    paste_masked(img, gold_band((W, H)), outer)
    # small studs around the gold band
    d = ImageDraw.Draw(img)
    for i in range(8):
        a = i * math.pi / 4 + math.pi / 8
        x, y = c + u(27.8) * math.cos(a), c + u(27.8) * math.sin(a)
        d.ellipse((x - u(1.1), y - u(1.1), x + u(1.1), y + u(1.1)), fill=GOLD_LO + (255,))
        d.ellipse((x - u(0.6), y - u(0.9), x + u(0.4), y + u(0.1)), fill=GOLD_HI + (220,))
    paste_masked(img, fill((W, H), (6, 5, 4)), band_in)
    paste_masked(img, steel_band((W, H)), steel_in)
    face_m = disc(23.0)
    # face: radial, lighter towards the top-left
    yy, xx = np.mgrid[0:H, 0:W]
    r = np.sqrt((xx - c * 0.85) ** 2 + (yy - c * 0.72) ** 2) / (u(27))
    r = np.clip(r, 0, 1)[:, :, None]
    face = (np.array(face_hi) * (1 - r) + np.array(face_lo) * r).astype(np.uint8)
    face = Image.fromarray(face, "RGB").convert("RGBA")
    paste_masked(img, grain(face, 4), face_m)
    img.alpha_composite(inner_shadow((W, H), face_m, depth=2, strength=210))
    return img, face_m


def finish_crest(img, face_m):
    W, H = img.size
    # glassy highlight across the top of the face, and a sheen on the whole medal
    hl = Image.new("L", (W, H), 0)
    ImageDraw.Draw(hl).ellipse((u(12), u(7), u(52), u(30)), fill=38)
    hl = ImageChops.multiply(hl.filter(ImageFilter.GaussianBlur(3 * SS)), face_m)
    layer = Image.new("RGBA", (W, H), (255, 250, 235, 0))
    layer.putalpha(hl)
    img.alpha_composite(layer)
    img.alpha_composite(sheen((W, H), img.getchannel("A"), 0.42, 50))
    return img


def sym_scroll(img):
    W, H = img.size
    body = mask_from(lambda d: d.rectangle(P([(20, 22), (44, 43)]), fill=255))
    emblem(img, body, parch_fill((W, H)))
    d = ImageDraw.Draw(img)
    for y in (27, 31, 35, 39):   # writing
        d.line(P([(24, y), (40 - (6 if y == 39 else 0), y)]), fill=(92, 64, 30, 230), width=wi(1.4))
    for y0 in (16, 41):          # the two rolls
        roll = mask_from(lambda d2: d2.rounded_rectangle(P([(16, y0), (48, y0 + 7)]), radius=u(3.5), fill=255))
        emblem(img, roll, vgrad((W, H), [(0, PARCH_HI), (0.5, PARCH), (1, PARCH_LO)]), outline=1.8)
        d.ellipse(P([(15.5, y0 + 1), (19.5, y0 + 6)]), fill=(120, 88, 48, 255))
        d.ellipse(P([(44.5, y0 + 1), (48.5, y0 + 6)]), fill=(120, 88, 48, 255))
    # a red wax seal
    d.ellipse(P([(35, 36), (43, 44)]), fill=(18, 6, 4, 255))
    d.ellipse(P([(35.8, 36.8), (42.2, 43.2)]), fill=(186, 36, 28, 255))
    d.ellipse(P([(37, 38), (39.5, 40)]), fill=(240, 120, 100, 200))


def sym_quests(img):
    W, H = img.size
    bar = mask_from(lambda d: d.polygon(P([(26.5, 13), (37.5, 13), (35, 39), (29, 39)]), fill=255))
    dot = mask_from(lambda d: d.ellipse(P([(27.5, 42), (36.5, 51)]), fill=255))
    emblem(img, ImageChops.lighter(bar, dot), gold_fill((W, H)), outline=2.4)


def sym_exploration(img):
    W, H = img.size
    ring = mask_from(lambda d: d.ellipse(P([(21, 21), (43, 43)]), outline=255, width=wi(1.6)))
    emblem(img, ring, steel_fill((W, H)), outline=1.0)
    c = 32
    long_pts, short_pts = [], []
    for i in range(8):
        a = -math.pi / 2 + i * math.pi / 4
        R = 22 if i % 2 == 0 else 10.5
        long_pts.append((c + R * math.cos(a), c + R * math.sin(a)))
        a2 = a + math.pi / 8
        long_pts.append((c + 7 * math.cos(a2), c + 7 * math.sin(a2)))
    star = mask_from(lambda d: d.polygon(P(long_pts), fill=255))
    # shade the right half of every point (the classic two-tone compass rose)
    shade = Image.new("L", star.size, 0)
    sd = ImageDraw.Draw(shade)
    for i in range(8):
        a = -math.pi / 2 + i * math.pi / 4
        R = 22 if i % 2 == 0 else 10.5
        tip = (c + R * math.cos(a), c + R * math.sin(a))
        a2 = a + math.pi / 8
        side = (c + 7 * math.cos(a2), c + 7 * math.sin(a2))
        sd.polygon(P([(c, c), tip, side]), fill=255)
    emblem(img, star, gold_fill((W, H)), outline=1.6, shade=shade, shade_alpha=60)
    # north point in red
    d = ImageDraw.Draw(img)
    d.polygon(P([(32, 11.6), (29.3, 26), (32, 26)]), fill=(226, 58, 44, 255))
    d.polygon(P([(32, 11.6), (34.7, 26), (32, 26)]), fill=(150, 28, 22, 255))
    d.ellipse(P([(30.3, 30.3), (33.7, 33.7)]), fill=INK + (255,))
    d.ellipse(P([(31, 31), (33, 33)]), fill=GOLD_HI + (255,))


def sym_dungeons(img):
    W, H = img.size

    def key(d):
        d.ellipse(P([(24, 9), (40, 25)]), fill=255)
        d.rectangle(P([(29.8, 23), (34.2, 52)]), fill=255)
        d.rectangle(P([(34, 42), (41, 45.5)]), fill=255)
        d.rectangle(P([(34, 47.5), (39, 51)]), fill=255)
        d.ellipse(P([(28.4, 13.4), (35.6, 20.6)]), fill=0)
    m = rotate_mask(mask_from(key), -38)
    emblem(img, m, gold_fill((W, H)), outline=2.0)


def sym_raids(img):
    W, H = img.size
    # a dragon's head in profile, facing left: long snout, open jaw, swept-back horns, a spiked frill
    head = [(9, 33), (12, 30.5), (23, 28), (29, 24), (35, 21.5), (54, 11), (43, 26), (55, 28), (47, 33),
            (56, 39), (47.5, 41), (52, 53), (37, 54), (35.5, 45), (29, 42.5), (14, 44), (10, 41.5),
            (23, 38.5), (9, 36.5)]
    horn2 = [(31, 23), (41, 7.5), (39, 23.5)]
    emblem(img, mask_from(lambda d: d.polygon(P(horn2), fill=255)),
           vgrad((W, H), [(0, (226, 176, 74)), (1, (126, 80, 26))]), outline=1.6)
    emblem(img, mask_from(lambda d: d.polygon(P(head), fill=255)), gold_fill((W, H)), outline=2.0)
    d = ImageDraw.Draw(img)
    # glowing eye under a brow ridge
    glow = Image.new("L", img.size, 0)
    ImageDraw.Draw(glow).ellipse(P([(24, 24.5), (34, 32)]), fill=210)
    layer = Image.new("RGBA", img.size, (255, 80, 30, 0))
    layer.putalpha(glow.filter(ImageFilter.GaussianBlur(1.5 * SS)))
    img.alpha_composite(layer)
    d.polygon(P([(25.5, 29.4), (32.5, 26), (31, 29.8)]), fill=(255, 238, 150, 255))
    d.line(P([(24, 26.4), (34, 23.4)]), fill=(110, 68, 20, 255), width=wi(1.2))
    d.ellipse(P([(12.5, 31), (15, 32.8)]), fill=INK + (255,))
    for x in (13, 17, 21):  # teeth
        d.polygon(P([(x, 36.6), (x + 2.2, 36.6 - (x - 9) * 0.12), (x + 1, 39.2)]), fill=(250, 244, 222, 255))
    # jaw line and neck plates
    d.line(P([(29, 42.5), (36, 34)]), fill=(120, 76, 24, 255), width=wi(1.1))
    for y in (46, 50):
        d.line(P([(38, y), (49, y - 1)]), fill=(120, 76, 24, 255), width=wi(1.1))


def sym_professions(img):
    W, H = img.size
    anvil = [(10, 31), (46, 31), (46, 36.5), (40, 38.5), (37.5, 43), (43, 48), (43, 51), (21, 51), (21, 48),
             (26.5, 43), (24, 38.5), (19, 37), (10, 33.5)]
    emblem(img, mask_from(lambda d: d.polygon(P(anvil), fill=255)), steel_fill((W, H)), outline=2.0)

    def hammer(d):
        d.rectangle(P([(30.6, 16), (33.4, 40)]), fill=255)
        d.rounded_rectangle(P([(23.5, 9), (40.5, 17.5)]), radius=u(1.2), fill=255)
    hm = rotate_mask(mask_from(hammer), 40, center=(32, 24))
    hm = hm.transform(hm.size, Image.AFFINE, (1, 0, -u(4), 0, 1, u(3)))
    emblem(img, hm, gold_fill((W, H)), outline=1.8)


def sym_reputation(img):
    W, H = img.size
    pole = mask_from(lambda d: (d.rectangle(P([(17.5, 13), (21, 54)]), fill=255),
                                d.ellipse(P([(15.5, 8), (23, 15.5)]), fill=255)))
    emblem(img, pole, gold_fill((W, H)), outline=1.6)
    flag = [(21, 14), (48, 14), (48, 44), (34.5, 36), (21, 44)]
    cloth = vgrad((W, H), [(0, (226, 70, 56)), (0.6, (170, 34, 28)), (1, (110, 20, 16))])
    emblem(img, mask_from(lambda d: d.polygon(P(flag), fill=255)), cloth, outline=1.8)
    d = ImageDraw.Draw(img)
    d.line(P([(21, 16.5), (48, 16.5)]), fill=GOLD + (255,), width=wi(1.6))
    # a gold diamond on the cloth
    d.polygon(P([(34.5, 19.5), (40, 25.5), (34.5, 31.5), (29, 25.5)]), fill=INK + (255,))
    d.polygon(P([(34.5, 21), (38.6, 25.5), (34.5, 30), (30.4, 25.5)]), fill=GOLD + (255,))
    d.polygon(P([(34.5, 21), (38.6, 25.5), (34.5, 25.5)]), fill=GOLD_HI + (255,))


def sym_pvp(img):
    W, H = img.size

    def sword(d):
        d.polygon(P([(32, 6), (34.6, 11), (34.6, 40), (29.4, 40), (29.4, 11)]), fill=255)
    def hilt(d):
        d.rounded_rectangle(P([(23, 39.5), (41, 43.5)]), radius=u(1.5), fill=255)
        d.rectangle(P([(30.4, 43), (33.6, 51)]), fill=255)
        d.ellipse(P([(28.8, 50), (35.2, 56.4)]), fill=255)
    for deg in (45, -45):
        blade = rotate_mask(mask_from(sword), deg)
        grip = rotate_mask(mask_from(hilt), deg)
        emblem(img, blade, steel_fill((W, H)), outline=1.8)
        emblem(img, grip, gold_fill((W, H)), outline=1.8)


def sym_feats(img):
    W, H = img.size
    gem = [(17, 25), (24, 16), (40, 16), (47, 25), (32, 50)]
    gm = mask_from(lambda d: d.polygon(P(gem), fill=255))
    crystal = vgrad((W, H), [(0, (246, 220, 255)), (0.4, (196, 120, 250)), (1, (96, 36, 160))])
    emblem(img, gm, crystal, outline=2.0)
    d = ImageDraw.Draw(img)
    facet = (70, 20, 120, 150)
    for poly, col in (([(24, 16), (40, 16), (36, 25), (28, 25)], (255, 255, 255, 70)),   # table
                      ([(36, 25), (47, 25), (32, 50)], (40, 6, 80, 110)),                 # shaded right
                      ([(28, 25), (36, 25), (32, 50)], (255, 240, 255, 60))):
        d.polygon(P(poly), fill=col)
    for a, b in (((17, 25), (47, 25)), ((28, 25), (32, 50)), ((36, 25), (32, 50)), ((24, 16), (28, 25)),
                 ((40, 16), (36, 25))):
        d.line(P([a, b]), fill=facet, width=wi(0.8))
    # sparkle
    sp = mask_from(lambda d2: d2.polygon(P([(46, 8), (47.4, 12.6), (52, 14), (47.4, 15.4), (46, 20), (44.6, 15.4),
                                             (40, 14), (44.6, 12.6)]), fill=255))
    paste_masked(img, fill((W, H), (255, 252, 230)), sp.filter(ImageFilter.GaussianBlur(0.3 * SS)))


CRESTS = [
    ("General", sym_scroll, (70, 82, 104), (20, 24, 34)),
    ("Quests", sym_quests, (104, 74, 34), (34, 22, 10)),
    ("Exploration", sym_exploration, (40, 96, 102), (10, 30, 34)),
    ("Dungeons", sym_dungeons, (78, 60, 112), (22, 16, 38)),
    ("Raids", sym_raids, (120, 40, 34), (38, 10, 10)),
    ("Professions", sym_professions, (100, 76, 52), (32, 22, 14)),
    ("Reputation", sym_reputation, (46, 92, 60), (12, 30, 18)),
    ("PvP", sym_pvp, (64, 70, 84), (20, 22, 28)),
    ("Feats", sym_feats, (58, 40, 96), (18, 10, 34)),
]


def crest(symbol, face_hi, face_lo):
    img, face_m = medallion(face_hi, face_lo)
    symbol(img)
    return finish_crest(img, face_m)


# -- summary tile ------------------------------------------------------------------------------

def tile():
    img = canvas(256, 64)
    W, H = img.size
    # shown at about 142x52, so the side rims are drawn a little wider than the top and bottom
    paste_masked(img, fill((W, H), (5, 6, 8)), rr_mask((W, H), (0, 0, W - 1, H - 1), u(4)))
    paste_masked(img, vgrad((W, H), [(0, (96, 102, 116)), (1, (44, 47, 55))]),
                 rr_mask((W, H), (u(1.5), u(1), W - u(1.5) - 1, H - u(1) - 1), u(4)))
    face_box = (u(3), u(2.2), W - u(3) - 1, H - u(2.2) - 1)
    fm = rr_mask((W, H), face_box, u(3))
    face = vgrad((W, H), [(0, (34, 36, 43)), (0.5, (23, 24, 29)), (1, (14, 15, 18))])
    paste_masked(img, grain(face, 4), fm)
    img.alpha_composite(inner_shadow((W, H), fm, depth=2, strength=140))
    # thin gold inner rim
    ring_o = rr_mask((W, H), (u(5), u(3.6), W - u(5) - 1, H - u(3.6) - 1), u(2.5))
    ring_i = rr_mask((W, H), (u(6.6), u(4.6), W - u(6.6) - 1, H - u(4.6) - 1), u(2))
    ring = ImageChops.subtract(ring_o, ring_i)
    paste_masked(img, fill((W, H), GOLD_MID), ring.point(lambda v: v * 200 // 255))
    hi = ImageChops.multiply(ring, vgrad((W, H), [(0, (255, 255, 255)), (0.5, (0, 0, 0)), (1, (0, 0, 0))]).convert("L"))
    paste_masked(img, fill((W, H), GOLD_HI), hi.point(lambda v: v * 160 // 255))
    # a soft well of light on the left where the crest sits
    glow = Image.new("RGBA", (W, H), (255, 214, 120, 0))
    gm = Image.new("L", (W, H), 0)
    ImageDraw.Draw(gm).ellipse((-u(40), -u(20), u(80), H + u(20)), fill=46)
    glow.putalpha(ImageChops.multiply(gm.filter(ImageFilter.GaussianBlur(u(18))), fm))
    img.alpha_composite(glow)
    img.alpha_composite(sheen((W, H), fm, 0.45, 22))
    return img


# -- empty "Recent achievements" illustration --------------------------------------------------

def empty_art():
    img = canvas(128, 128)
    W, H = img.size
    # faint gold glow behind the shield
    glow = Image.new("RGBA", (W, H), (255, 206, 110, 0))
    gm = Image.new("L", (W, H), 0)
    ImageDraw.Draw(gm).ellipse((u(22), u(10), u(106), u(98)), fill=96)
    glow.putalpha(gm.filter(ImageFilter.GaussianBlur(u(14))))
    img.alpha_composite(glow)
    # pedestal: two stone tiers
    for box, top, bot in (((u(28), u(98), u(100), u(110)), (82, 86, 98), (38, 40, 47)),
                          ((u(18), u(108), u(110), u(122)), (70, 74, 86), (28, 30, 36))):
        m = rr_mask((W, H), box, u(2.5))
        paste_masked(img, fill((W, H), (6, 7, 9)), m.filter(ImageFilter.MaxFilter(7)))
        paste_masked(img, grain(vgrad((W, H), [(box[1] / H, top), (box[3] / H, bot)]), 6), m)
        d = ImageDraw.Draw(img)
        d.line((box[0] + u(2), box[1] + u(0.8), box[2] - u(2), box[1] + u(0.8)), fill=(150, 156, 170, 200), width=wi(1))
    # the unlit steel shield standing on it
    pts = shield_points(u(38), u(18), u(90), u(99))
    cx, cy = u(64), u(54)
    outer = poly_mask((W, H), pts)
    paste_masked(img, fill((W, H), (6, 6, 8)), outer.filter(ImageFilter.MaxFilter(9)))
    paste_masked(img, steel_band((W, H)), outer)
    inner = poly_mask((W, H), shrink(pts, cx, cy, 0.80))
    paste_masked(img, grain(vgrad((W, H), [(0, (44, 47, 54)), (0.5, (28, 30, 36)), (1, (16, 17, 21))]), 4), inner)
    img.alpha_composite(inner_shadow((W, H), inner, depth=3, strength=200))
    # an empty socket in the middle, waiting for its first star
    star = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = 13 if i % 2 == 0 else 5.4
        star.append((64 + r * math.cos(a), 54 + r * math.sin(a)))
    sm = mask_from(lambda d2: d2.polygon(P(star), fill=255), 128)
    paste_masked(img, fill((W, H), (8, 9, 11)), sm.filter(ImageFilter.MaxFilter(5)))
    paste_masked(img, fill((W, H), (62, 58, 48)), sm.filter(ImageFilter.GaussianBlur(0.4 * SS)))
    hl = sm.transform((W, H), Image.AFFINE, (1, 0, 0, 0, 1, u(1.2)))
    paste_masked(img, fill((W, H), (8, 9, 11)), ImageChops.subtract(sm, hl).point(lambda v: v * 160 // 255))
    img.alpha_composite(sheen((W, H), outer, 0.5, 60))
    return drop_shadow(img, (0, 2), 3, 150)


def main(preview=None):
    pieces = [
        ("Ach_Shield", shield(64, "gold")),
        ("Ach_ShieldSmall", shield(32, "gold")),
        ("Ach_ShieldSmallGrey", shield(32, "steel")),
        ("Ach_Tab", tab(False)),
        ("Ach_TabSel", tab(True)),
        ("Ach_Row", row(False)),
        ("Ach_RowEarned", row(True)),
        ("Ach_Toast", toast()),
        ("Ach_Shine", shine()),
        ("Ach_TitleCrest", title_crest()),
        ("Ach_Corner", corner()),
        ("Ach_BarFrame", bar_frame()),
    ]
    # new pieces go after the originals so those keep drawing the same grain
    pieces += [("Ach_Cat_" + key, crest(fn, hi, lo)) for key, fn, hi, lo in CRESTS]
    pieces += [("Ach_Tile", tile()), ("Ach_Empty", empty_art())]
    out = []
    for name, img in pieces:
        out.append((name, save(name, img)))
        print("  +", name, out[-1][1].size)
    if preview:
        os.makedirs(preview, exist_ok=True)
        sheet(out[:3] + out[10:11], os.path.join(preview, "ach_small.png"), zoom=3)
        sheet(out[3:5] + out[9:10], os.path.join(preview, "ach_tabs.png"), zoom=1)
        sheet(out[5:7], os.path.join(preview, "ach_rows.png"), zoom=1)
        sheet(out[7:9] + out[11:12], os.path.join(preview, "ach_banner.png"), zoom=1)
        crests = out[12:21]
        sheet(crests, os.path.join(preview, "ach_crests.png"), zoom=2)
        # as the category buttons show them (20 px), then blown up to judge readability
        small = [(n, im.resize((20, 20), Image.LANCZOS).resize((60, 60), Image.NEAREST)) for n, im in crests]
        sheet(small, os.path.join(preview, "ach_crests_20px.png"), bg=(24, 25, 30, 255), zoom=1)
        sheet(out[21:23], os.path.join(preview, "ach_tile_empty.png"), zoom=2)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="write contact sheets into this folder")
    main(ap.parse_args().preview)
