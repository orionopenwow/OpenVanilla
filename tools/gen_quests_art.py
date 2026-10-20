#!/usr/bin/env python3
"""Quests art: service badges for the minimap, map pins, the waypoint arrow and small marks.

    py -3 tools/gen_quests_art.py        writes the TGA + BLP pairs (see tools/artkit.py)

Pieces (all transparent outside the shape, house palette: slate faces, thin gold rims)
  Quests_Anvil  Quests_CoinBag  Quests_Flight  Quests_Inn  Quests_Trainer  Quests_Bank
                                           32x32  round badges for service NPCs on the minimap
  Quests_Corpse                            32x32  badge with a headstone, for your corpse
  Quests_PinObjective / _PinGiver / _PinTurnin
                                           32x32  map pins: gold dot, green "!", red "?"
  Quests_Arrow                             64x64  the waypoint arrow, pointing up; the shape stays
                                                  inside the inscribed circle so it can be rotated
                                                  with SetTexCoord without clipping
  Quests_Upgrade                           16x16  green up arrow (reward is an upgrade)
"""
import os

from PIL import Image, ImageDraw, ImageFilter

from artkit import (SS, EDGE_HI, GOLD, GOLD_HI, GOLD_LO, GOLD_MID, GREEN, RED, canvas,
                    drop_shadow, fill, gold_band, grain, inner_shadow, paste_masked, save, sheen,
                    sheet, vgrad)

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.environ.get("ART_PREVIEW", os.path.join(HERE, "..", "art"))


def disc_mask(size, inset):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).ellipse((inset, inset, size[0] - inset - 1, size[1] - inset - 1), fill=255)
    return m


def badge(glyph):
    """A 32x32 round badge: dark rim, gold ring, slate face with soft light, then the glyph."""
    img = canvas(32, 32)
    W, H = img.size
    paste_masked(img, fill((W, H), (6, 7, 9)), disc_mask((W, H), 2 * SS))
    paste_masked(img, gold_band((W, H)), disc_mask((W, H), int(2.8 * SS)))
    face_m = disc_mask((W, H), int(4.4 * SS))
    face = vgrad((W, H), [(0, (44, 48, 58)), (0.6, (24, 26, 32)), (1, (14, 15, 19))])
    paste_masked(img, grain(face, 4), face_m)
    img.alpha_composite(inner_shadow((W, H), face_m, depth=1.5, strength=170))
    layer = canvas(32, 32)
    glyph(ImageDraw.Draw(layer), W, H)
    img.alpha_composite(drop_shadow(layer, offset=(0, 1), blur=1, alpha=200))
    img.alpha_composite(sheen((W, H), face_m, 0.45, 40))
    return img


def P(*pts):
    return [(x * SS, y * SS) for x, y in pts]


def g_anvil(d, W, H):
    steel, hi, lo = (190, 196, 206), (236, 240, 246), (96, 102, 116)
    d.polygon(P((7, 11.5), (24.5, 11.5), (24.5, 13), (21, 15.5), (19, 15.5), (19, 18), (13, 18), (13, 15.5), (11, 15.5), (7, 13.5)), fill=steel)
    d.polygon(P((7, 11.5), (24.5, 11.5), (24.5, 12.6), (7, 12.6)), fill=hi)
    d.polygon(P((11, 18), (21, 18), (23, 21.5), (9, 21.5)), fill=lo)
    d.polygon(P((9, 21.5), (23, 21.5), (23, 22.5), (9, 22.5)), fill=(70, 74, 86))


def g_coinbag(d, W, H):
    d.ellipse(P((8, 12), (22, 25)), fill=(150, 104, 58))
    d.polygon(P((12.5, 12.5), (17.5, 12.5), (19.5, 8), (10.5, 8)), fill=(132, 90, 48))
    d.rectangle(P((11.5, 11.5), (18.5, 13.2)), fill=GOLD_LO)
    d.ellipse(P((10, 15), (14, 19)), fill=(186, 138, 84))       # light on the bag
    d.ellipse(P((16.5, 17), (24.5, 25)), fill=GOLD_MID)
    d.ellipse(P((17.3, 17.8), (23.7, 24.2)), fill=GOLD)
    d.ellipse(P((19, 19.5), (22, 22.5)), fill=GOLD_HI)


def g_flight(d, W, H):
    feather = (236, 232, 218)
    d.polygon(P((8, 21), (12, 12), (17, 8.5), (24, 8), (21, 11), (25, 12), (20.5, 14.5), (23.5, 16), (18, 18), (20, 20), (13, 21.5)), fill=feather)
    d.line(P((9, 20.5), (20, 10)), fill=(150, 146, 136), width=SS)
    d.polygon(P((7, 21), (10, 19.5), (11, 23)), fill=GOLD)


def g_inn(d, W, H):
    d.rounded_rectangle(P((9, 11), (19.5, 24)), radius=1.5 * SS, fill=(196, 132, 44))
    d.rounded_rectangle(P((10.5, 12.5), (13, 22.5)), radius=SS, fill=(236, 180, 76))
    d.ellipse(P((8, 7.5), (21, 13.5)), fill=(246, 242, 230))      # foam
    d.ellipse(P((11, 6), (17, 11)), fill=(255, 252, 244))
    d.arc(P((17.5, 13), (24.5, 21)), start=-90, end=90, fill=(160, 104, 34), width=2 * SS)
    d.line(P((9, 18), (19.5, 18)), fill=(120, 80, 26), width=SS)


def g_trainer(d, W, H):
    page, edge = (240, 232, 208), (150, 132, 98)
    d.polygon(P((6.5, 11), (15.5, 12.5), (15.5, 23.5), (6.5, 22)), fill=page)
    d.polygon(P((25.5, 11), (16.5, 12.5), (16.5, 23.5), (25.5, 22)), fill=(226, 216, 190))
    d.line(P((16, 12.5), (16, 23.5)), fill=edge, width=SS)
    for y in (15, 17.5, 20):
        d.line(P((8.5, y - 1.2), (14, y)), fill=(140, 128, 106), width=max(1, SS // 2))
        d.line(P((18, y), (23.5, y - 1.2)), fill=(140, 128, 106), width=max(1, SS // 2))
    d.polygon(P((19, 10), (21.5, 10), (21.5, 16), (20.25, 14.8), (19, 16)), fill=RED)  # ribbon


def g_bank(d, W, H):
    d.rounded_rectangle(P((7.5, 12), (24.5, 23.5)), radius=SS, fill=(120, 78, 40))
    d.pieslice(P((7.5, 6.5), (24.5, 17.5)), start=180, end=360, fill=(140, 92, 48))
    for x in (10.5, 20):
        d.rectangle(P((x, 7.5), (x + 1.6, 23.5)), fill=GOLD_MID)
    d.rectangle(P((7.5, 12), (24.5, 13.4)), fill=GOLD_MID)
    d.rounded_rectangle(P((14, 13.5), (18, 18)), radius=0.6 * SS, fill=GOLD)
    d.rectangle(P((15.5, 15), (16.5, 17)), fill=(40, 26, 10))


def g_corpse(d, W, H):
    d.rounded_rectangle(P((10, 8), (22, 24)), radius=5 * SS, fill=(176, 180, 188))
    d.rectangle(P((10, 14), (22, 24)), fill=(176, 180, 188))
    d.rectangle(P((15.2, 11), (16.8, 19)), fill=(70, 74, 84))
    d.rectangle(P((12.8, 13.2), (19.2, 14.8)), fill=(70, 74, 84))
    d.rectangle(P((7, 23), (25, 25)), fill=(84, 112, 60))


def pin(color, mark):
    """A 32x32 teardrop map pin (tip at the bottom centre) with a glyph in its head."""
    img = canvas(32, 32)
    W, H = img.size
    shape = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(shape)
    d.ellipse(P((6, 2.5), (26, 22.5)), fill=255)
    d.polygon(P((8.5, 17), (23.5, 17), (16, 29.5)), fill=255)
    paste_masked(img, fill((W, H), (8, 8, 10)), shape)
    inner = shape.filter(ImageFilter.MinFilter(int(3 * SS) | 1))
    dark = tuple(int(c * 0.45) for c in color)
    light = tuple(min(255, int(c * 1.0 + 40)) for c in color)
    paste_masked(img, vgrad((W, H), [(0, light), (0.45, color), (1, dark)]), inner)
    img.alpha_composite(sheen((W, H), inner, 0.4, 70))
    g = ImageDraw.Draw(img)
    if mark == "dot":
        g.ellipse(P((12, 8.5), (20, 16.5)), fill=(30, 22, 6))
        g.ellipse(P((13.5, 10), (18.5, 15)), fill=(255, 246, 214))
    elif mark == "!":
        g.rounded_rectangle(P((14.6, 6), (17.4, 14.5)), radius=SS, fill=(255, 255, 255))
        g.ellipse(P((14.4, 15.6), (17.6, 18.8)), fill=(255, 255, 255))
    else:
        g.arc(P((11.5, 5.5), (20.5, 13.5)), start=180, end=60, fill=(255, 255, 255), width=int(2.6 * SS))
        g.line(P((18.6, 11.6), (16, 13.2), (16, 15)), fill=(255, 255, 255), width=int(2.6 * SS))
        g.ellipse(P((14.6, 16.2), (17.4, 19)), fill=(255, 255, 255))
    return drop_shadow(img, offset=(0, 1), blur=1, alpha=170)


def arrow():
    img = canvas(64, 64)
    W, H = img.size
    shape = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(shape)
    tip = P((32, 9), (52, 40), (39, 34), (39, 54), (25, 54), (25, 34), (12, 40))
    d.polygon(tip, fill=255)
    paste_masked(img, fill((W, H), (12, 9, 4)), shape.filter(ImageFilter.MaxFilter(int(2 * SS) | 1)))
    paste_masked(img, gold_band((W, H)), shape)
    # a darker right half so the arrow reads as bevelled
    right = Image.new("L", (W, H), 0)
    ImageDraw.Draw(right).polygon(P((32, 9), (52, 40), (39, 34), (39, 54), (32, 54)), fill=255)
    from PIL import ImageChops
    shade = Image.new("RGBA", (W, H), (60, 34, 4, 0))
    shade.putalpha(ImageChops.multiply(right, shape).point(lambda v: v * 90 // 255))
    img.alpha_composite(shade)
    img.alpha_composite(sheen((W, H), shape, 0.5, 80))
    return drop_shadow(img, offset=(0, 2), blur=2, alpha=150)


def upgrade():
    img = canvas(16, 16)
    W, H = img.size
    shape = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shape).polygon(P((8, 1.5), (14.5, 8.5), (10.5, 8.5), (10.5, 14.5), (5.5, 14.5), (5.5, 8.5), (1.5, 8.5)), fill=255)
    paste_masked(img, fill((W, H), (6, 24, 8)), shape.filter(ImageFilter.MaxFilter(int(1.2 * SS) | 1)))
    paste_masked(img, vgrad((W, H), [(0, (170, 255, 170)), (0.5, GREEN), (1, (28, 120, 52))]), shape)
    return img


def main():
    out = []
    for name, glyph in (("Quests_Anvil", g_anvil), ("Quests_CoinBag", g_coinbag), ("Quests_Flight", g_flight),
                        ("Quests_Inn", g_inn), ("Quests_Trainer", g_trainer), ("Quests_Bank", g_bank),
                        ("Quests_Corpse", g_corpse)):
        out.append((name, save(name, badge(glyph), (32, 32))))
    out.append(("Quests_PinObjective", save("Quests_PinObjective", pin((236, 182, 24), "dot"), (32, 32))))
    out.append(("Quests_PinGiver", save("Quests_PinGiver", pin((52, 190, 72), "!"), (32, 32))))
    out.append(("Quests_PinTurnin", save("Quests_PinTurnin", pin((214, 52, 44), "?"), (32, 32))))
    out.append(("Quests_Arrow", save("Quests_Arrow", arrow(), (64, 64))))
    out.append(("Quests_Upgrade", save("Quests_Upgrade", upgrade(), (16, 16))))
    preview = os.environ.get("ART_PREVIEW")
    if preview:
        sheet(out, preview, zoom=3)
        print("preview:", preview)
    print("wrote", len(out), "pieces")


if __name__ == "__main__":
    main()
