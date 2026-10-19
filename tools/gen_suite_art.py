#!/usr/bin/env python3
"""Shared suite art: toggle switches, nameplate level cap, window pieces.

    py -3 tools/gen_suite_art.py          writes the TGA + BLP pairs (see tools/artkit.py)

Pieces
  Switch_Track_On / Switch_Track_Off   64x32  pill track (the visible pill is 56x26, centred)
  Switch_Knob                          32x32  gold knob (the visible disc is 22 px)
  Switch_Glow                          64x32  soft green halo behind an "on" track
  Plate_Cap                            32x16  grey bevelled cap that ends a nameplate health bar
  Gear                                 32x32  settings cog (steel teeth, gold hub)
"""
import os

from PIL import Image, ImageDraw, ImageFilter

from artkit import (SS, EDGE, EDGE_HI, GOLD_LO, GREEN, SLATE, canvas, fill, gold_band, grain,
                    inner_shadow, paste_masked, rr_mask, save, sheen, sheet, vgrad)

HERE = os.path.dirname(os.path.abspath(__file__))


def track(on):
    img = canvas(64, 32)
    W, H = img.size
    x0, y0, x1, y1 = 4 * SS, 3 * SS, W - 4 * SS - 1, H - 3 * SS - 1
    r = (y1 - y0) // 2
    # outer rim: dark outline, then a thin metal edge (gold when on, steel when off)
    paste_masked(img, fill((W, H), (6, 7, 9)), rr_mask((W, H), (x0, y0, x1, y1), r))
    rim = gold_band((W, H)) if on else vgrad((W, H), [(0, EDGE_HI), (1, (58, 62, 72))])
    paste_masked(img, rim, rr_mask((W, H), (x0 + SS, y0 + SS, x1 - SS, y1 - SS), r - SS))
    face_m = rr_mask((W, H), (x0 + 2.5 * SS, y0 + 2.5 * SS, x1 - 2.5 * SS, y1 - 2.5 * SS), r - 2.5 * SS)
    if on:
        face = vgrad((W, H), [(0, (64, 120, 52)), (0.55, (40, 92, 36)), (1, (22, 58, 22))])
    else:
        face = vgrad((W, H), [(0, (22, 24, 29)), (1, (36, 39, 46))])
    paste_masked(img, grain(face, 4), face_m)
    img.alpha_composite(inner_shadow((W, H), face_m, depth=2, strength=200))
    if on:
        g = face_m.filter(ImageFilter.MinFilter(9)).filter(ImageFilter.GaussianBlur(3 * SS))
        glow = Image.new("RGBA", (W, H), (150, 235, 120, 0))
        glow.putalpha(g.point(lambda v: v * 60 // 255))
        img.alpha_composite(glow)
    img.alpha_composite(sheen((W, H), face_m, 0.45, 35))
    return img


def knob():
    img = canvas(32, 32)
    W, H = img.size
    d = 22 * SS
    o = (W - d) // 2
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).ellipse((o, o + 2 * SS, o + d, o + d + 2 * SS), fill=160)
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh.putalpha(shadow.filter(ImageFilter.GaussianBlur(1.5 * SS)))
    img.alpha_composite(sh)
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).ellipse((o, o, o + d, o + d), fill=255)
    paste_masked(img, fill((W, H), (8, 6, 3)), m)
    m2 = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m2).ellipse((o + SS, o + SS, o + d - SS, o + d - SS), fill=255)
    paste_masked(img, gold_band((W, H)), m2)
    ring = Image.new("L", (W, H), 0)
    ImageDraw.Draw(ring).ellipse((o + 5 * SS, o + 5 * SS, o + d - 5 * SS, o + d - 5 * SS), outline=255, width=SS)
    paste_masked(img, fill((W, H), GOLD_LO), ring)
    img.alpha_composite(sheen((W, H), m2, 0.55, 95))
    return img


def glow():
    img = canvas(64, 32)
    W, H = img.size
    m = rr_mask((W, H), (6 * SS, 6 * SS, W - 6 * SS, H - 6 * SS), 10 * SS).filter(ImageFilter.GaussianBlur(4 * SS))
    g = Image.new("RGBA", (W, H), GREEN + (0,))
    g.putalpha(m.point(lambda v: v * 150 // 255))
    img.alpha_composite(g)
    return img


def plate_cap():
    """Grey bevelled cap: dark grey face, 1 px light top edge, dark bottom edge, slight left fade
    so it sits flush against the end of the health bar casing."""
    img = canvas(32, 16)
    W, H = img.size
    paste_masked(img, fill((W, H), (4, 4, 5)), rr_mask((W, H), (0, 0, W - 1, H - 1), 2 * SS))
    face_m = rr_mask((W, H), (SS, SS, W - 1 - SS, H - 1 - SS), int(1.5 * SS))
    paste_masked(img, grain(vgrad((W, H), [(0, (78, 80, 86)), (0.5, (52, 54, 60)), (1, (34, 35, 40))]), 3), face_m)
    d = ImageDraw.Draw(img)
    d.rectangle((2 * SS, SS, W - 1 - 2 * SS, 2 * SS - 1), fill=(150, 154, 162, 255))          # top highlight
    d.rectangle((2 * SS, H - 2 * SS, W - 1 - 2 * SS, H - 1 - SS), fill=(16, 16, 19, 255))      # bottom shade
    d.rectangle((SS, 2 * SS, 2 * SS - 1, H - 1 - 2 * SS), fill=(110, 113, 120, 255))          # left bevel
    d.rectangle((W - 2 * SS, 2 * SS, W - 1 - SS, H - 1 - 2 * SS), fill=(24, 25, 29, 255))     # right shade
    return img


def plate_frame():
    """The nameplate frame: a fully rounded pill like the 1.12 nameplate (round ends, a rim round
    the bar, a round-ended light-brown box for the level at the right end) in WoW slate grey.
    128x16; the addon slices it into a fixed left end, a stretched middle and a fixed right end
    (see Plates.lua FRAME_OURS).
      rim 3 px, bar well x 3..96 y 3..13 (round ends), level box x 99..125 y 2..14."""
    img = canvas(128, 16)
    W, H = img.size
    S = SS
    # outline and rim: a capsule (radius = half the height)
    paste_masked(img, fill((W, H), (10, 10, 12)), rr_mask((W, H), (0, 0, W - 1, H - 1), H // 2))
    rim = grain(vgrad((W, H), [(0, (140, 143, 151)), (0.25, (108, 110, 118)), (0.6, (80, 82, 89)),
                               (1, (46, 47, 53))]), 3)
    paste_masked(img, rim, rr_mask((W, H), (S, S, W - 1 - S, H - 1 - S), H // 2 - S))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((5 * S, S, W - 1 - 5 * S, int(1.6 * S)), radius=S, fill=(172, 175, 183, 255))  # top light
    # the bar well: a dark lip, then see-through, its ends as round as the frame's
    d.rounded_rectangle((int(2.4 * S), int(2.4 * S), int(96.6 * S) - 1, int(13.6 * S) - 1), radius=int(5.6 * S),
                        fill=(16, 16, 19, 255))
    hole = rr_mask((W, H), (3 * S, 3 * S, 96 * S - 1, 13 * S - 1), 5 * S)
    img.putalpha(Image.composite(Image.new("L", (W, H), 0), img.getchannel("A"), hole))
    # the level box: a round-ended grey well behind the number
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((98 * S, int(1.6 * S), int(125.4 * S) - 1, int(14.4 * S) - 1), radius=int(6.4 * S),
                        fill=(14, 14, 16, 255))
    box = grain(vgrad((W, H), [(0, (108, 110, 116)), (0.45, (84, 86, 92)), (1, (58, 59, 65))]), 3)
    paste_masked(img, box, rr_mask((W, H), (99 * S, int(2.4 * S), int(124.6 * S) - 1, int(13.6 * S) - 1), int(5.6 * S)))
    d.rounded_rectangle((102 * S, int(2.6 * S), 122 * S - 1, int(3.4 * S)), radius=S // 2, fill=(140, 142, 150, 255))
    return img


def gear():
    import math
    img = canvas(32, 32)
    W, H = img.size
    c = W / 2
    teeth, r_out, r_in = 8, 14.5 * SS, 11 * SS
    pts = []
    for i in range(teeth * 4):
        a = (i / (teeth * 4)) * 2 * math.pi - math.pi / 2
        r = r_out if (i % 4) in (1, 2) else r_in
        pts.append((c + r * math.cos(a), c + r * math.sin(a)))
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(0.4 * SS))
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.putalpha(m.transform((W, H), Image.AFFINE, (1, 0, 0, 0, 1, -SS)).filter(ImageFilter.GaussianBlur(SS)).point(lambda v: v * 150 // 255))
    img.alpha_composite(shadow)
    paste_masked(img, vgrad((W, H), [(0, (196, 200, 210)), (0.5, (120, 124, 134)), (1, (70, 72, 80))]), m)
    edge = m.filter(ImageFilter.MaxFilter(3))
    hole = Image.new("L", (W, H), 0)
    ImageDraw.Draw(hole).ellipse((c - 6.5 * SS, c - 6.5 * SS, c + 6.5 * SS, c + 6.5 * SS), fill=255)
    paste_masked(img, gold_band((W, H)), hole)
    inner = Image.new("L", (W, H), 0)
    ImageDraw.Draw(inner).ellipse((c - 3 * SS, c - 3 * SS, c + 3 * SS, c + 3 * SS), fill=255)
    paste_masked(img, fill((W, H), (24, 20, 14)), inner)
    img.alpha_composite(sheen((W, H), m, 0.5, 60))
    return img


def main():
    pieces = [
        ("Switch_Track_On", track(True)),
        ("Switch_Track_Off", track(False)),
        ("Switch_Knob", knob()),
        ("Switch_Glow", glow()),
        ("Plate_Cap", plate_cap()),
        ("Plate_Frame", plate_frame()),
        ("Gear", gear()),
    ]
    out = []
    for name, img in pieces:
        out.append((name, save(name, img)))
        print("  +", name, out[-1][1].size)
    # preview: an on and an off switch assembled, on the window colour
    prev = Image.new("RGBA", (200, 48), SLATE + (255,))
    for i, on in enumerate((False, True)):
        t = out[0][1] if on else out[1][1]
        x = 12 + i * 90
        prev.alpha_composite(t, (x, 8))
        prev.alpha_composite(out[2][1], (x + (34 if on else -2), 8))
    sheet([(n, i) for n, i in out] + [("preview", prev)],
          os.path.join(HERE, "..", "art", "ui-kit", "suite_preview.png"), zoom=3)


if __name__ == "__main__":
    main()
