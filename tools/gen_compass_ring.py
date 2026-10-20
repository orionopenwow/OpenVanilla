#!/usr/bin/env python3
"""Compass minimap rings: five themes in the classic stone / wood / leather style.

    py -3 tools/gen_compass_ring.py      (all five; Wildwood is the default CompassRing)

Writes Data/Interface/AddOns/WenillaCore/Media/CompassRing.tga and
Data/Interface/ClassicPlus/CompassRing.blp (256x256, transparent centre), then rebuild the patch
with tools/sync_patchz.py. Geometry matches the old ring: the minimap's edge sits at radius 104 of
128, and the ring covers 101-128 with a soft shadow falling inward onto the map.

Bands, inside out: an oak inner rim with iron rivets, a stitched leather strap, and an outer ring
of weathered stone blocks with a keystone at north.
"""
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 4                     # supersampling
N = 256 * SS
rng = np.random.default_rng(1212)
import json
STYLE = {"stone": [80, 74, 64], "blocks": 12, "strap": [92, 54, 30], "stitch": [176, 142, 96],
         "wood": [70, 44, 24], "rivet": [70, 68, 66], "rivets": 8, "runes": None, "edge": [38, 32, 26]}
STYLE.update(json.loads(os.environ.get("RING_STYLE", "{}")))

y, x = np.mgrid[0:N, 0:N].astype(np.float32)
c = (N - 1) / 2
dx, dy = x - c, y - c
r = np.hypot(dx, dy) / SS                     # radius in 256-space
ang = np.arctan2(dy, dx)                      # 0 = east, +pi/2 = south (image coords)
north = -math.pi / 2


def noise(scale, octaves=4):
    """Smooth value noise in 0..1 at the given feature size (in 256-space pixels)."""
    out = np.zeros((N, N), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        s = max(2, int(256 / (scale / 2 ** o)))
        g = rng.random((s + 1, s + 1)).astype(np.float32)
        im = Image.fromarray((g * 255).astype(np.uint8)).resize((N, N), Image.BICUBIC)
        out += np.asarray(im, np.float32) / 255 * amp
        tot += amp
        amp *= .5
    return out / tot


def band(r0, r1, soft=.6):
    """1 inside [r0, r1] with anti-aliased edges."""
    return np.clip((r - r0) / soft + .5, 0, 1) * np.clip((r1 - r) / soft + .5, 0, 1)


light = np.cos(ang - (-3 * math.pi / 4))      # light from the top-left: +1 facing it, -1 away
rgb = np.zeros((N, N, 3), np.float32)
alpha = np.zeros((N, N), np.float32)


def paint(mask, color):
    global rgb, alpha
    m = mask[..., None]
    rgb = rgb * (1 - m) + color * m
    alpha = np.maximum(alpha, mask)


# -- stone: 12 weathered blocks, 114..127.5 --------------------------------------------------
R_IN, R_OUT = 114.0, 127.4
blocks = STYLE["blocks"]
seg = (ang - north) % (2 * math.pi) / (2 * math.pi) * blocks
idx = np.floor(seg)
frac = seg - idx
key = idx == 0                                     # keystone at north, a touch wider and taller
grain = noise(10) * .55 + noise(3) * .45
tint = rng.uniform(.88, 1.08, blocks)[idx.astype(int) % blocks]
base = np.stack([STYLE["stone"][0] * tint, STYLE["stone"][1] * tint, STYLE["stone"][2] * tint], -1) * (.6 + .75 * grain[..., None])
# bevel: blocks are rounded across their width, lit from the top-left
across = (r - R_IN) / (R_OUT - R_IN)
bevel = 1 + .55 * light[..., None] * np.sin(across[..., None] * math.pi) * .6 - .25 * (across[..., None] - .5)
edge_shade = np.minimum(frac, 1 - frac)            # darken near the joints
joint = np.clip(edge_shade * blocks * 2.2 / (2 * math.pi) * 6.0, 0, 1)
stone = base * bevel * (.62 + .38 * joint[..., None])
cracks = (noise(5, 3) > .74) & (noise(2, 2) > .55)
stone[cracks] *= .55
out_r = np.where(key, R_OUT + .6, R_OUT)
stone_mask = np.clip((r - R_IN) / .6 + .5, 0, 1) * np.clip((out_r - r) / .7 + .5, 0, 1)
# mortar grooves between blocks
groove = np.clip(1 - np.abs(frac - np.round(frac)) * blocks * r / (2 * math.pi) / 1.1, 0, 1) * (r > R_IN)
stone = stone * (1 - .75 * groove[..., None])
paint(stone_mask, stone)
# a lit top lip and a dark outer edge on every block
paint(band(R_OUT - 1.4, R_OUT - .4) * stone_mask * np.clip(light, 0, 1) * .45, np.array([210, 200, 180], np.float32))
paint(band(out_r - .9, out_r + .2), np.array(STYLE["edge"], np.float32) * (1 + .2 * grain[..., None]))

# keystone carving: a small chiselled "N"-ish rune notch
kx, ky = 0.0, -(R_IN + R_OUT) / 2
px, py = dx / SS - kx, dy / SS - ky
rune = ((np.abs(px + 2.2) < .75) | (np.abs(px - 2.2) < .75) | (np.abs(px + py * .9) < .8)) & (np.abs(py) < 3.4) & key
rgb[rune] *= .45
if STYLE["runes"]:
    # a glowing rune carved into the middle of every block
    mid = (R_IN + R_OUT) / 2
    ca = north + (idx + .5) * 2 * math.pi / blocks
    ux, uy = dx / SS - np.cos(ca) * mid, dy / SS - np.sin(ca) * mid
    tx, ty = -np.sin(ca), np.cos(ca)
    u, v = ux * tx + uy * ty, ux * np.cos(ca) + uy * np.sin(ca)
    glyph = ((np.abs(u) < .6) & (np.abs(v) < 3.6)) | ((np.abs(u - v * .55) < .55) & (v > -3.6) & (v < .2)) | ((np.abs(u + v * .55) < .55) & (v > -.2) & (v < 3.6))
    glyph &= ~key & (stone_mask > .5)
    g = np.array(STYLE["runes"], np.float32)
    from PIL import ImageFilter as _F
    halo = np.asarray(Image.fromarray((glyph * 255).astype(np.uint8)).filter(_F.GaussianBlur(SS * 1.6)), np.float32) / 255
    rgb = rgb * (1 - halo[..., None] * .6) + g * halo[..., None] * .6
    rgb[glyph] = g * 1.0 + 40

# -- leather strap, 105.6..114 -------------------------------------------------------------
L0, L1 = 105.6, 114.2
lgrain = noise(4) * .6 + noise(1.5, 2) * .4
leather = np.stack(STYLE["strap"], -1).astype(np.float32) * (.6 + .7 * lgrain[..., None])
lb = (r - L0) / (L1 - L0)
leather *= (1 + .18 * light[..., None] * (lb[..., None] - .5) * 2)[..., :]
leather *= (.8 + .2 * np.sin(lb * math.pi))[..., None]
paint(band(L0, L1), leather)
# stitches along both edges
dash = (np.sin((ang - north) * 120) > .45)
for sr in ((L0 + 1.5, L1 - 1.5) if STYLE["stitch"] else ()):
    paint(band(sr - .4, sr + .4) * dash * .8, np.array(STYLE["stitch"], np.float32))
# shadow where the strap tucks under the stone
paint(band(L1 - 1.2, L1) * .55, np.array([30, 18, 10], np.float32))

# -- oak inner rim, 101..105.6 ---------------------------------------------------------------
W0, W1 = 101.0, 105.8
wgrain = np.sin((ang * 40 + noise(8, 2) * 9)) * .5 + .5
wood = np.stack(STYLE["wood"], -1).astype(np.float32) * (.75 + .35 * wgrain[..., None]) * (1 + .22 * light[..., None])
wb = (r - W0) / (W1 - W0)
wood *= (.7 + .45 * np.sin(wb * math.pi))[..., None]
paint(band(W0, W1), wood)
paint(band(W0 - .2, W0 + .7), np.array([26, 16, 8], np.float32))

# iron rivets on the strap, 8 around
for k in range(STYLE["rivets"]):
    a = north + (k + .5) * 2 * math.pi / STYLE["rivets"]
    rr = (L0 + L1) / 2
    cx, cy = math.cos(a) * rr, math.sin(a) * rr
    d = np.hypot(dx / SS - cx, dy / SS - cy)
    head = np.clip(2.7 - d, 0, 1)
    shade = 1 + .5 * ((-(dx / SS - cx) - (dy / SS - cy)) / 2.3)
    paint(head, np.array(STYLE["rivet"], np.float32) * shade[..., None])
    paint(np.clip(.9 - np.hypot(dx / SS - cx + .6, dy / SS - cy + .6), 0, 1), np.array([190, 186, 176], np.float32))

# -- inner shadow on the map ---------------------------------------------------------------
sh = np.clip((r - 93.5) / 7.5, 0, 1) ** 1.6 * (r < W0 + .3)
shadow_a = sh * .78
rgb = np.where((alpha < .01)[..., None], np.array([0, 0, 0], np.float32), rgb)
alpha = np.maximum(alpha, shadow_a)
alpha *= (r < 128.2)

img = Image.fromarray(np.dstack([np.clip(rgb, 0, 255), np.clip(alpha * 255, 0, 255)]).astype(np.uint8), "RGBA")
img = img.resize((256, 256), Image.LANCZOS)

THEMES = {  # texture name -> style (Wildwood is the default ring, "CompassRing")
    "CompassRing": {"stone": [86, 96, 78], "blocks": 10, "strap": [74, 60, 40], "stitch": [150, 170, 120], "wood": [96, 78, 50], "rivet": [110, 140, 100], "rivets": 6, "runes": [150, 255, 170], "edge": [30, 36, 26]},
    "CompassRing_Stone": {},
    "CompassRing_IronOak": {"stone": [58, 58, 62], "strap": [64, 40, 24], "stitch": None, "wood": [50, 34, 20], "rivet": [120, 116, 110], "rivets": 12, "edge": [20, 20, 24]},
    "CompassRing_Runestone": {"stone": [52, 60, 72], "blocks": 16, "strap": [44, 48, 58], "stitch": None, "wood": [40, 40, 48], "rivet": [90, 96, 110], "rivets": 0, "runes": [120, 200, 255], "edge": [16, 20, 30]},
    "CompassRing_Bronze": {"stone": [96, 82, 64], "strap": [150, 104, 46], "stitch": None, "wood": [120, 80, 34], "rivet": [200, 150, 70], "rivets": 16, "edge": [46, 34, 20]},
}

if __name__ == "__main__" and os.environ.get("RING_ONLY"):
    img.save(os.environ["RING_ONLY"])
    sys.exit(0)

if __name__ == "__main__":
    # Each theme renders in its own process (the drawing above runs at import with RING_STYLE).
    import json, tempfile
    media = os.path.join(ROOT, "Data", "Interface", "AddOns", "WenillaCore", "Media")
    cpart = os.path.join(ROOT, "Data", "Interface", "ClassicPlus")
    tmp = tempfile.mkdtemp()
    for name, style in THEMES.items():
        png = os.path.join(tmp, name + ".png")
        env = dict(os.environ, RING_STYLE=json.dumps(style), RING_ONLY=png)
        subprocess.run([sys.executable, os.path.abspath(__file__)], env=env, check=True)
        Image.open(png).save(os.path.join(media, name + ".tga"))
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "png_to_blp.py"), png, os.path.join(cpart, name + ".blp")], check=True)
        print("wrote", name)
    print("now run tools/sync_patchz.py to pack them into patch-Z.MPQ")
