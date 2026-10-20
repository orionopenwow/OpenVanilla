#!/usr/bin/env python3
"""Guild Hub art: the window portrait and the six tab crests.

    python3 tools/gen_guildhub_art.py                 writes the TGA + BLP pairs (see tools/artkit.py)
    python3 tools/gen_guildhub_art.py --preview DIR   also writes a contact sheet into DIR

Pieces (all have stock-icon fallbacks in the addon)
  GuildHub_Portrait      64x64  round portrait under the Classic frame's ring: a hanging guild
                                standard (royal blue, gold fringe) with a gold keep on it, on a
                                night-blue field
  GuildHub_Tab_Roster    64x64  tab crests, the Guilds addon's iron-and-gold medallion (shared
  GuildHub_Tab_Recruit          helpers from gen_guilds_art.py) with the tab's symbol: three
  GuildHub_Tab_Events           busts, a sealed letter, a calendar page, a coin chest, balance
  GuildHub_Tab_Bank             scales, a banner; drawn to read at 22 px in the page headers
  GuildHub_Tab_DKP
  GuildHub_Tab_Guild
Website (www/guilds.html, www/guild.html)
  www/assets/guilds/banner.png    128x128 the portrait, for the page headers
"""
import math
import os

from PIL import Image, ImageDraw

from artkit import INK, canvas, fill, inner_shadow, paste_masked, save, sheen, sheet, vgrad, grain
from gen_guilds_art import (P, bone_fill, disc, emblem, finish, gold_fill, mask_from, medallion, radial_face,
                            steel_fill, u, wi, wood_fill)


def cloth(hi, lo):
    return vgrad((u(64), u(64)), [(0.0, hi), (1.0, lo)])


# -- symbols ---------------------------------------------------------------------------------------

def sym_roster(img):
    """Three busts: the guild's people (the middle one in front, gold)."""
    W = img.width
    for cx, top, f in ((20, 21, steel_fill), (44, 21, steel_fill), (32, 17, gold_fill)):
        def bust(d, cx=cx, top=top):
            d.ellipse(P([(cx - 6, top), (cx + 6, top + 12)]), fill=255)
            d.pieslice(P([(cx - 11, top + 12), (cx + 11, top + 36)]), 180, 360, fill=255)
        emblem(img, mask_from(bust), f((W, W)), outline=1.6)


def sym_recruit(img):
    """A folded letter with a red wax seal."""
    W = img.width
    paper = vgrad((W, W), [(0, (255, 248, 226)), (1, (196, 178, 140))])
    emblem(img, mask_from(lambda d: d.rectangle(P([(14, 20), (50, 46)]), fill=255)), paper, outline=1.8)
    d = ImageDraw.Draw(img)
    d.line(P([(14, 20), (32, 35), (50, 20)]), fill=(120, 98, 64, 255), width=wi(1.4))
    seal = vgrad((W, W), [(0, (236, 74, 58)), (1, (120, 16, 12))])
    emblem(img, mask_from(lambda d: d.ellipse(P([(27, 30), (37, 40)]), fill=255)), seal, outline=1.0)


def sym_events(img):
    """A calendar page with two rings and a marked day."""
    W = img.width
    paper = vgrad((W, W), [(0, (250, 246, 236)), (1, (190, 182, 166))])
    emblem(img, mask_from(lambda d: d.rounded_rectangle(P([(16, 18), (48, 48)]), radius=u(3), fill=255)), paper, outline=1.8)
    head = vgrad((W, W), [(0, (226, 70, 56)), (1, (128, 22, 16))])
    emblem(img, mask_from(lambda d: d.rectangle(P([(16, 18), (48, 26)]), fill=255)), head, outline=0.6)
    for x in (23, 41):
        emblem(img, mask_from(lambda d, x=x: d.rounded_rectangle(P([(x - 1.6, 14), (x + 1.6, 22)]), radius=u(1.4), fill=255)),
               steel_fill((W, W)), outline=0.8)
    d = ImageDraw.Draw(img)
    for row in range(3):
        for col in range(4):
            x, y = 20 + col * 7, 30 + row * 6
            d.rectangle(P([(x, y), (x + 4, y + 3)]), fill=(120, 116, 108, 255))
    d.ellipse(P([(32.5, 34.5), (40.5, 42.5)]), outline=(214, 40, 30, 255), width=wi(1.6))


def sym_bank(img):
    """A small strongbox with gold coins spilling over the lid."""
    W = img.width
    emblem(img, mask_from(lambda d: d.rectangle(P([(14, 30), (50, 49)]), fill=255)), wood_fill((W, W)), outline=1.8)
    emblem(img, mask_from(lambda d: d.rectangle(P([(14, 30), (50, 33.5)]), fill=255)), steel_fill((W, W)), outline=0.6)
    emblem(img, mask_from(lambda d: d.rectangle(P([(29, 36), (35, 43)]), fill=255)), gold_fill((W, W)), outline=0.8)
    for cx, cy in ((22, 25), (31, 22), (40, 25), (27, 17), (36, 17)):
        emblem(img, mask_from(lambda d, cx=cx, cy=cy: d.ellipse(P([(cx - 5.5, cy - 4), (cx + 5.5, cy + 4)]), fill=255)),
               gold_fill((W, W)), outline=1.0)


def sym_dkp(img):
    """Balance scales: points given and spent."""
    W = img.width

    def frame(d):
        d.line(P([(32, 14), (32, 48)]), fill=255, width=wi(3))
        d.line(P([(14, 21), (50, 21)]), fill=255, width=wi(2.6))
        d.rectangle(P([(23, 46), (41, 50)]), fill=255)
        for x in (16, 48):
            d.line(P([(x, 21), (x - 6, 35)]), fill=255, width=wi(1.1))
            d.line(P([(x, 21), (x + 6, 35)]), fill=255, width=wi(1.1))
    emblem(img, mask_from(frame), gold_fill((W, W)), outline=1.2)
    for x in (16, 48):
        emblem(img, mask_from(lambda d, x=x: d.chord(P([(x - 9, 28), (x + 9, 42)]), 0, 180, fill=255)),
               steel_fill((W, W)), outline=1.2)
    emblem(img, mask_from(lambda d: d.ellipse(P([(29, 10), (35, 16)]), fill=255)), gold_fill((W, W)), outline=0.8)


def sym_guild(img):
    """A swallow-tailed banner on a pole."""
    W = img.width
    emblem(img, mask_from(lambda d: d.line(P([(20, 12), (20, 52)]), fill=255, width=wi(3))), gold_fill((W, W)), outline=1.2)
    flag = [(22, 14), (48, 14), (48, 40), (41, 34), (35, 40), (35, 34), (22, 34)]
    emblem(img, mask_from(lambda d: d.polygon(P(flag), fill=255)), cloth((80, 128, 236), (20, 38, 118)), outline=1.6)
    star = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = 5 if i % 2 == 0 else 2.1
        star.append((34 + r * math.cos(a), 23 + r * math.sin(a)))
    emblem(img, mask_from(lambda d: d.polygon(P(star), fill=255)), gold_fill((W, W)), outline=0.8)


TABS = [
    ("Roster", sym_roster, (74, 80, 96), (18, 20, 28)),
    ("Recruit", sym_recruit, (126, 92, 44), (38, 24, 10)),
    ("Events", sym_events, (44, 66, 116), (10, 16, 36)),
    ("Bank", sym_bank, (52, 96, 64), (12, 30, 18)),
    ("DKP", sym_dkp, (96, 56, 122), (26, 10, 38)),
    ("Guild", sym_guild, (122, 44, 40), (34, 8, 10)),
]


def crest(symbol, hi, lo):
    img, face_m = medallion(hi, lo)
    symbol(img)
    return finish(img, face_m)


# -- portrait ----------------------------------------------------------------------------------------
# Fills the whole 64x64 disc: the Classic frame's ring covers the outer few pixels.

def portrait():
    img = canvas(64, 64)
    W = img.width
    field = radial_face(W, (64, 78, 128), (6, 8, 20), reach=40)
    paste_masked(img, grain(field, 4), disc(W, 32))
    # the crossbar and its finials
    emblem(img, mask_from(lambda d: d.line(P([(12, 13), (52, 13)]), fill=255, width=wi(2.6))), gold_fill((W, W)), outline=1.0)
    for x in (11, 53):
        emblem(img, mask_from(lambda d, x=x: d.ellipse(P([(x - 2.6, 10.4), (x + 2.6, 15.6)]), fill=255)), gold_fill((W, W)), outline=0.8)
    # the standard: royal blue with a pointed foot and a gold fringe
    banner = [(17, 14), (47, 14), (47, 48), (32, 57), (17, 48)]
    bm = mask_from(lambda d: d.polygon(P(banner), fill=255))
    emblem(img, bm, cloth((70, 112, 226), (16, 30, 96)), outline=1.6)
    edge = mask_from(lambda d: d.line(P([(17, 47), (32, 56), (47, 47)]), fill=255, width=wi(2.2)))
    emblem(img, edge, gold_fill((W, W)), outline=0.4)
    # a gold keep: two towers and a gate
    def keep(d):
        d.rectangle(P([(23, 28), (41, 44)]), fill=255)
        for x0 in (21, 37):
            d.rectangle(P([(x0, 22), (x0 + 6, 44)]), fill=255)
            for k in range(3):
                d.rectangle(P([(x0 + k * 2.4, 19.5), (x0 + k * 2.4 + 1.4, 22)]), fill=255)
        for k in range(4):
            d.rectangle(P([(27.5 + k * 2.4, 25.5), (28.9 + k * 2.4, 28)]), fill=255)
    emblem(img, mask_from(keep), gold_fill((W, W)), outline=1.1)
    d = ImageDraw.Draw(img)
    d.pieslice(P([(28.5, 35), (35.5, 46)]), 180, 360, fill=INK + (255,))
    d.rectangle(P([(28.5, 40.5), (35.5, 44)]), fill=INK + (255,))
    img.alpha_composite(inner_shadow((W, W), disc(W, 32), depth=2, strength=150))
    img.alpha_composite(sheen((W, W), bm, 0.4, 44))
    return img


def main(preview=None):
    pieces = [("GuildHub_Portrait", portrait())]
    pieces += [("GuildHub_Tab_" + key, crest(fn, hi, lo)) for key, fn, hi, lo in TABS]
    www = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "www", "assets", "guilds")
    os.makedirs(www, exist_ok=True)
    pieces[0][1].resize((128, 128), Image.LANCZOS).save(os.path.join(www, "banner.png"))
    print("  + www/assets/guilds/banner.png")
    out = []
    for name, img in pieces:
        out.append((name, save(name, img, (64, 64))))
        print("  +", name, out[-1][1].size)
    if preview:
        os.makedirs(preview, exist_ok=True)
        sheet(out, os.path.join(preview, "guildhub_art.png"), zoom=2)
        s22 = [(n, im.resize((22, 22), Image.LANCZOS)) for n, im in out]
        sheet(s22, os.path.join(preview, "guildhub_art_small.png"), bg=(24, 25, 30, 255), zoom=4)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="write contact sheets into this folder")
    main(ap.parse_args().preview)
