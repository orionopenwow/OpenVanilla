#!/usr/bin/env python3
"""Chat window art: five themes (panel, tab, edge) plus the shared pieces.

    py -3 tools/gen_chat_art.py                     writes the TGA + BLP pairs (see tools/artkit.py)
    py -3 tools/gen_chat_art.py --preview out.png   also renders a contact sheet of the five themes
                                                   over grass and snow, laid out like the game does

Per theme (suffix "" for Slate, then _Parchment, _Midnight, _Wildwood, _Glass)
  Chat_Panel<s>   256x64   the panel face, stretched behind the chat text (alpha = opacity slider)
  Chat_Tab<s>     64x32    a flat tab joined to the panel's top edge
  Chat_Edge<s>    64x64    9-slice frame, 16 px corners (drawn at the theme's edge size in Lua)
Shared
  Chat_Shadow     64x64    9-slice soft shadow that falls under the panel
  Chat_Dot        16x16    unread dot (white, tinted in Lua)
  Chat_Arrow      32x32    "jump to latest" button
  Chat_Menu       32x32    tab bar menu (speech bubble), light grey, tinted in Lua
  Chat_Copy       32x32    tab bar copy button (two sheets)
  Chat_Grip       16x16    resize grip
  Chat_Discord    32x32    the World tab's mark for lines from the realm's Discord: a round seal in
                           Discord blue with a white two-voice speech glyph (ours, not Discord's logo)
                           `--only Chat_Discord` writes just this one

Wildwood reuses the minimap ring's materials (tools/gen_compass_ring.py, default CompassRing):
oak (96,78,50), leather strap (74,60,40), mossy rivets (110,140,100) and the green rune glow.
Parchment matches Persona's profile page (Parchment.tga) with dark ink text.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

from artkit import SS, canvas, fill, grain, paste_masked, rr_mask, save, sheen, vgrad  # noqa: F401

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
rng = np.random.default_rng(2604)

THEMES = {
    "slate": {"suffix": "", "face": (27, 29, 34), "face2": (21, 23, 28), "edge": (70, 75, 88), "top": (150, 156, 170),
              "tab": (22, 23, 27), "accent": (255, 209, 0), "text": (236, 236, 242), "muted": (150, 154, 168)},
    "parchment": {"suffix": "_Parchment", "face": (204, 176, 128), "face2": (186, 154, 106), "edge": (98, 64, 34),
                  "top": (240, 226, 190), "tab": (182, 150, 104), "accent": (158, 40, 26), "text": (52, 30, 14),
                  "muted": (92, 66, 40)},
    "midnight": {"suffix": "_Midnight", "face": (10, 14, 28), "face2": (5, 8, 18), "edge": (52, 70, 108),
                 "top": (118, 150, 220), "tab": (8, 11, 22), "accent": (140, 205, 255), "text": (230, 236, 255),
                 "muted": (130, 146, 180)},
    "wildwood": {"suffix": "_Wildwood", "face": (36, 33, 22), "face2": (25, 23, 15), "edge": (96, 78, 50),
                 "top": (160, 134, 88), "tab": (58, 44, 26), "accent": (150, 255, 170), "text": (242, 236, 218),
                 "muted": (174, 164, 136)},
    "glass": {"suffix": "_Glass", "face": (0, 0, 0), "face2": (0, 0, 0), "edge": (255, 255, 255), "top": (255, 255, 255),
              "tab": (0, 0, 0), "accent": (255, 209, 0), "text": (245, 245, 245), "muted": (196, 196, 204)},
}
ORDER = ["slate", "parchment", "midnight", "wildwood", "glass"]

# Lua's edge sizes / outsets (Core.lua C.THEMES) so the preview matches the game.
EDGE = {"slate": (8, 2), "parchment": (12, 3), "midnight": (8, 2), "wildwood": (14, 6), "glass": (6, 1)}
FLAGS_INK = {"parchment"}


def noise(w, h, scale, octaves=3, seed=None):
    r = np.random.default_rng(seed) if seed is not None else rng
    out = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        sx = max(2, int(w / (scale / 2 ** o)))
        sy = max(2, int(h / (scale / 2 ** o)))
        g = r.random((sy + 1, sx + 1)).astype(np.float32)
        im = Image.fromarray((g * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
        out += np.asarray(im, np.float32) / 255 * amp
        tot += amp
        amp *= 0.5
    return out / tot


def from_arrays(rgb, a):
    return Image.fromarray(np.dstack([np.clip(rgb, 0, 255), np.clip(a, 0, 255)]).astype(np.uint8), "RGBA")


# -- panels -----------------------------------------------------------------------------------

def panel(key):
    t = THEMES[key]
    W, H = 256 * SS, 64 * SS
    ys = np.linspace(0, 1, H)[:, None, None]
    face = np.array(t["face"], np.float32)
    face2 = np.array(t["face2"], np.float32)
    rgb = face * (1 - ys) + face2 * ys
    rgb = np.repeat(rgb, W, axis=1)
    a = np.full((H, W), 255.0, np.float32)
    if key == "slate":
        n = noise(W, H, 24 * SS)
        rgb = rgb * (0.96 + 0.08 * n[..., None])
    elif key == "parchment":
        mott = noise(W, H, 40 * SS) * 0.6 + noise(W, H, 8 * SS) * 0.4
        rgb = rgb * (0.90 + 0.18 * mott[..., None])
        # fibres
        fib = noise(W, H, 2 * SS, 2)
        rgb = rgb * (0.97 + 0.05 * fib[..., None])
        # warm vignette towards the edges
        xs = np.linspace(-1, 1, W)[None, :]
        yv = np.linspace(-1, 1, H)[:, None]
        v = np.clip(1 - (xs ** 8 + yv ** 8) * 0.9, 0, 1)
        rgb = rgb * (0.80 + 0.20 * v[..., None])
    elif key == "midnight":
        n = noise(W, H, 60 * SS)
        rgb = rgb * (0.85 + 0.3 * n[..., None]) + np.array([2, 4, 10], np.float32) * n[..., None]
    elif key == "wildwood":
        # faint planks of dark oak with a mossy cast
        grain_n = noise(W, H // 6, 30 * SS, 3)
        g = np.repeat(np.asarray(Image.fromarray((grain_n * 255).astype(np.uint8)).resize((W, H), Image.BICUBIC), np.float32) / 255, 1, 0)
        streak = np.sin(np.linspace(0, 1, H)[:, None] * 90 + g * 10) * 0.5 + 0.5
        rgb = rgb * (0.88 + 0.16 * streak[..., None]) + np.array([0, 3, 0], np.float32)
    elif key == "glass":
        rgb = np.zeros((H, W, 3), np.float32)
        a = (0.36 + 0.14 * (1 - ys[..., 0])) * 255 * np.ones((H, W), np.float32)
    img = from_arrays(rgb, a)
    if key == "midnight":
        img = constellation(img)
    return img


def constellation(img):
    """A small constellation in the top-right corner, plus a dusting of faint stars."""
    W, H = img.size
    stars = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(stars)
    r = np.random.default_rng(77)
    for _ in range(70):
        x, y = r.uniform(0, W), r.uniform(0, H)
        s = r.uniform(0.6, 1.4) * SS * 0.5
        al = int(r.uniform(40, 120))
        d.ellipse((x - s, y - s, x + s, y + s), fill=(190, 210, 255, al))
    # the figure (a little "lantern" shape), right side
    pts = [(0.80, 0.22), (0.86, 0.12), (0.92, 0.25), (0.89, 0.55), (0.83, 0.60), (0.80, 0.22), (0.74, 0.40), (0.83, 0.60)]
    pts = [(x * W, y * H) for x, y in pts]
    lines = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lines)
    for a, b in zip(pts, pts[1:]):
        ld.line((a, b), fill=(140, 180, 255, 70), width=int(0.6 * SS))
    lines = lines.filter(ImageFilter.GaussianBlur(0.3 * SS))
    stars.alpha_composite(lines)
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for (x, y) in set(pts):
        s = 2.6 * SS
        gd.ellipse((x - s, y - s, x + s, y + s), fill=(150, 200, 255, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(1.6 * SS))
    stars.alpha_composite(glow)
    cd = ImageDraw.Draw(stars)
    for (x, y) in set(pts):
        s = 0.9 * SS
        cd.ellipse((x - s, y - s, x + s, y + s), fill=(235, 245, 255, 235))
    out = img.copy()
    out.alpha_composite(stars)
    return out


# -- tabs -------------------------------------------------------------------------------------

def tab(key):
    t = THEMES[key]
    img = canvas(64, 32)
    W, H = img.size
    rad = 3 * SS
    m = rr_mask((W, H), (0, 0, W - 1, H + rad * 2), rad)       # rounded top, square (open) bottom
    if key == "glass":
        face = fill((W, H), (0, 0, 0), 120)
        paste_masked(img, face, m)
        d = ImageDraw.Draw(img)
        d.line((rad, SS // 2, W - rad, SS // 2), fill=(255, 255, 255, 46), width=SS)
        return img
    top = tuple(min(255, int(c * 1.25 + 6)) for c in t["tab"])
    face = vgrad((W, H), [(0, top), (0.35, t["tab"]), (1, t["tab"])])
    if key == "parchment":
        n = noise(W, H, 10 * SS)
        arr = np.asarray(face, np.float32)
        arr[..., :3] *= (0.92 + 0.14 * n[..., None])
        face = Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGBA")
    elif key == "wildwood":
        n = noise(W, H // 4, 20 * SS)
        g = np.asarray(Image.fromarray((n * 255).astype(np.uint8)).resize((W, H), Image.BICUBIC), np.float32) / 255
        streak = np.sin(np.linspace(0, 1, H)[:, None] * 28 + g * 8) * 0.5 + 0.5
        arr = np.asarray(face, np.float32)
        arr[..., :3] *= (0.78 + 0.34 * streak[..., None])
        face = Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGBA")
    else:
        face = grain(face, 3)
    paste_masked(img, face, m)
    # edge: side lines and a lighter top line
    edge_m = ImageChops.subtract(m, rr_mask((W, H), (SS, SS, W - 1 - SS, H + rad * 2), rad - SS))
    paste_masked(img, fill((W, H), t["edge"]), edge_m)
    d = ImageDraw.Draw(img)
    d.line((rad, SS + SS // 2, W - rad, SS + SS // 2), fill=t["top"] + (150,), width=SS)
    if key == "midnight":
        s = 1.0 * SS
        cx, cy = W - 7 * SS, 7 * SS
        d.ellipse((cx - s, cy - s, cx + s, cy + s), fill=(220, 236, 255, 200))
    if key == "wildwood":
        for cx in (4 * SS, W - 4 * SS):
            cy = 7 * SS
            s = 1.6 * SS
            d.ellipse((cx - s, cy - s, cx + s, cy + s), fill=(110, 140, 100, 255))
            d.ellipse((cx - s * 0.45 - SS * 0.3, cy - s * 0.45 - SS * 0.3, cx - SS * 0.1, cy - SS * 0.1), fill=(190, 210, 170, 255))
    return img


# -- edges (9-slice, 64x64, 16 px corners) ------------------------------------------------------
# The rect the edge surrounds sits `out` screen px inside the art's outer border, i.e. at
# out * 16 / size art px. Lines meant to be "1 px" on screen are 16/size art px wide.

def ring_mask(W, H, inset, width, radius):
    outer = rr_mask((W, H), (inset, inset, W - 1 - inset, H - 1 - inset), max(0, radius))
    inner = rr_mask((W, H), (inset + width, inset + width, W - 1 - inset - width, H - 1 - inset - width),
                    max(0, radius - width))
    return ImageChops.subtract(outer, inner)


def edge(key):
    t = THEMES[key]
    size, out = EDGE[key]
    img = canvas(64, 64)
    W, H = img.size
    px = 16.0 / size * SS                    # one screen pixel, in master pixels
    boundary = out * px                      # where the panel's own edge falls
    if key in ("slate", "midnight", "glass"):
        if key == "glass":
            paste_masked(img, fill((W, H), (255, 255, 255), 40), ring_mask(W, H, int(boundary), int(px), int(2 * px)))
            return img
        # a dark outline just outside, the edge colour on the panel's border
        paste_masked(img, fill((W, H), (6, 7, 10), 230), ring_mask(W, H, int(boundary - px), int(px), int(3 * px)))
        paste_masked(img, fill((W, H), t["edge"]), ring_mask(W, H, int(boundary), int(px), int(2 * px)))
        if key == "midnight":
            d = ImageDraw.Draw(img)
            for cx, cy in ((boundary + 3 * px, boundary + 3 * px), (W - boundary - 3 * px, boundary + 3 * px)):
                s = 0.9 * px
                d.line((cx - 2.6 * px, cy, cx + 2.6 * px, cy), fill=(170, 210, 255, 160), width=max(1, int(px * 0.5)))
                d.line((cx, cy - 2.6 * px, cx, cy + 2.6 * px), fill=(170, 210, 255, 160), width=max(1, int(px * 0.5)))
                d.ellipse((cx - s, cy - s, cx + s, cy + s), fill=(230, 242, 255, 230))
        return img
    if key == "parchment":
        # burnt, darkened paper edge fading inwards, and a thin ink rule just inside
        rim = ring_mask(W, H, 0, int(boundary + 3 * px), int(3 * px)).filter(ImageFilter.GaussianBlur(1.2 * px))
        layer = Image.new("RGBA", (W, H), (70, 40, 16, 0))
        layer.putalpha(rim.point(lambda v: v * 170 // 255))
        img.alpha_composite(layer)
        paste_masked(img, fill((W, H), (60, 34, 14), 235), ring_mask(W, H, int(boundary - px), int(px), int(2 * px)))
        paste_masked(img, fill((W, H), (110, 70, 34), 150), ring_mask(W, H, int(boundary + 3 * px), max(1, int(0.7 * px)), int(px)))
        return img
    # wildwood: a carved oak frame with a leather strap line, mossy rivets and rune glow
    band_w = boundary + 2 * px
    frame_m = ring_mask(W, H, 0, int(band_w), int(4 * px))
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    # grain runs along each side: horizontal on top/bottom, vertical on the sides
    d_side = np.minimum(np.minimum(xx, W - 1 - xx), np.minimum(yy, H - 1 - yy))
    along = np.where(np.minimum(xx, W - 1 - xx) < np.minimum(yy, H - 1 - yy), yy, xx)
    n = noise(W, H, 6 * SS)
    g = np.sin(d_side / px * 2.2 + n * 5 + along / (40 * px)) * 0.5 + 0.5
    wood = np.array([122, 96, 60], np.float32) * (0.66 + 0.46 * g[..., None])
    # bevel: lit from the top-left, rounded across the band
    across = np.clip(d_side / band_w, 0, 1)
    light = np.where((yy < xx) & (yy < H - 1 - xx), 1.18, np.where(xx < yy, 1.05, 0.78))
    wood = wood * (0.62 + 0.55 * np.clip(np.sin(across * math.pi), 0, 1) ** 0.7)[..., None] * light[..., None]
    rgb = wood
    alpha = np.asarray(frame_m, np.float32)
    woodimg = from_arrays(rgb, alpha)
    img.alpha_composite(woodimg)
    # strap/groove line in the middle of the band, and a dark inner lip onto the panel
    paste_masked(img, fill((W, H), (40, 30, 18), 230), ring_mask(W, H, int(band_w * 0.45), max(1, int(0.8 * px)), int(3 * px)))
    paste_masked(img, fill((W, H), (24, 16, 8), 255), ring_mask(W, H, int(band_w - px), int(px), int(2 * px)))
    paste_masked(img, fill((W, H), (190, 160, 110), 90), ring_mask(W, H, 0, max(1, int(0.6 * px)), int(4 * px)))
    d = ImageDraw.Draw(img)
    for cx, cy in ((band_w * 0.5, band_w * 0.5), (W - band_w * 0.5, band_w * 0.5),
                   (band_w * 0.5, H - band_w * 0.5), (W - band_w * 0.5, H - band_w * 0.5)):
        glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(glow).ellipse((cx - 3.2 * px, cy - 3.2 * px, cx + 3.2 * px, cy + 3.2 * px), fill=(150, 255, 170, 90))
        img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(1.2 * px)))
        s = 2.3 * px
        d.ellipse((cx - s, cy - s, cx + s, cy + s), fill=(52, 66, 46, 255))
        d.ellipse((cx - s * 0.8, cy - s * 0.8, cx + s * 0.6, cy + s * 0.6), fill=(110, 140, 100, 255))
        d.ellipse((cx - s * 0.55, cy - s * 0.55, cx - s * 0.05, cy - s * 0.05), fill=(196, 222, 180, 255))
    return img


# -- shared pieces ------------------------------------------------------------------------------

def shadow():
    """Soft shadow ring: strongest at the panel edge (12 px in), fading out; clear in the middle."""
    W, H = 64 * SS, 64 * SS
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32) / SS
    b = 12.0
    dx = np.maximum(np.maximum(b - xx, xx - (63 - b)), 0)
    dy = np.maximum(np.maximum(b - yy, yy - (63 - b)), 0)
    outside = np.hypot(dx, dy)                                    # distance outside the panel rect
    inside = np.minimum(np.minimum(xx - b, (63 - b) - xx), np.minimum(yy - b, (63 - b) - yy))
    a = np.where(outside > 0, np.exp(-(outside / 5.0) ** 2) * 0.85, np.exp(-(np.maximum(inside, 0) / 1.5) ** 2) * 0.85)
    a = a * 255
    return from_arrays(np.zeros((H, W, 3), np.float32), a)


def dot():
    img = canvas(16, 16)
    W, H = img.size
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).ellipse((3 * SS, 3 * SS, 13 * SS, 13 * SS), fill=255)
    halo = m.filter(ImageFilter.GaussianBlur(1.5 * SS)).point(lambda v: v * 120 // 255)
    h = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    h.putalpha(halo)
    img.alpha_composite(h)
    paste_masked(img, fill((W, H), (255, 255, 255)), m)
    return img


def arrow():
    img = canvas(32, 32)
    W, H = img.size
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).ellipse((3 * SS, 3 * SS, 29 * SS, 29 * SS), fill=255)
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh.putalpha(m.transform((W, H), Image.AFFINE, (1, 0, 0, 0, 1, -SS)).filter(ImageFilter.GaussianBlur(1.2 * SS)).point(lambda v: v * 170 // 255))
    img.alpha_composite(sh)
    paste_masked(img, fill((W, H), (8, 9, 11)), m)
    m2 = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m2).ellipse((4 * SS, 4 * SS, 28 * SS, 28 * SS), fill=255)
    paste_masked(img, vgrad((W, H), [(0, (48, 51, 60)), (1, (24, 26, 31))]), m2)
    ring = Image.new("L", (W, H), 0)
    ImageDraw.Draw(ring).ellipse((4 * SS, 4 * SS, 28 * SS, 28 * SS), outline=255, width=SS)
    paste_masked(img, fill((W, H), (110, 116, 130)), ring)
    d = ImageDraw.Draw(img)
    c = 16 * SS
    w = int(2.2 * SS)
    d.line((c - 6 * SS, c - 4 * SS, c, c + 2 * SS), fill=(255, 209, 0, 255), width=w)
    d.line((c, c + 2 * SS, c + 6 * SS, c - 4 * SS), fill=(255, 209, 0, 255), width=w)
    d.line((c - 6 * SS, c + 6 * SS, c + 6 * SS, c + 6 * SS), fill=(255, 209, 0, 255), width=w)
    img.alpha_composite(sheen((W, H), m2, 0.5, 40))
    return img


def menu_icon():
    img = canvas(32, 32)
    W, H = img.size
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle((4 * SS, 6 * SS, 28 * SS, 23 * SS), radius=6 * SS, fill=255)
    d.polygon([(9 * SS, 21 * SS), (8 * SS, 28 * SS), (15 * SS, 22 * SS)], fill=255)
    inner = Image.new("L", (W, H), 0)
    di = ImageDraw.Draw(inner)
    for x in (10, 16, 22):
        di.ellipse(((x - 2) * SS, 12.5 * SS, (x + 2) * SS, 16.5 * SS), fill=255)
    m = ImageChops.subtract(m, inner)
    paste_masked(img, fill((W, H), (235, 235, 240)), m)
    return img


def discord_icon():
    """A blue seal (114,137,218) with a soft rim and two overlapping white speech bubbles."""
    img = canvas(32, 32)
    W, H = img.size
    seal = Image.new("L", (W, H), 0)
    ImageDraw.Draw(seal).ellipse((1 * SS, 1 * SS, 31 * SS, 31 * SS), fill=255)
    face = vgrad((W, H), [(0, (138, 158, 232)), (1, (88, 106, 190))])
    paste_masked(img, face, seal)
    rim = ImageChops.subtract(seal, rr_mask((W, H), (2.5 * SS, 2.5 * SS, 29.5 * SS, 29.5 * SS), 14 * SS))
    paste_masked(img, fill((W, H), (52, 62, 120)), rim)
    glyph = Image.new("L", (W, H), 0)
    g = ImageDraw.Draw(glyph)
    g.rounded_rectangle((6 * SS, 8 * SS, 20 * SS, 18 * SS), radius=4 * SS, fill=255)        # the first voice
    g.polygon([(9 * SS, 17 * SS), (8 * SS, 22 * SS), (13 * SS, 17.5 * SS)], fill=255)
    back = Image.new("L", (W, H), 0)
    b = ImageDraw.Draw(back)
    b.rounded_rectangle((13 * SS, 13 * SS, 26 * SS, 22 * SS), radius=4 * SS, fill=255)      # the answer
    b.polygon([(22 * SS, 21 * SS), (24 * SS, 26 * SS), (19 * SS, 21.5 * SS)], fill=255)
    gap = back.filter(ImageFilter.MaxFilter(5))
    glyph = ImageChops.subtract(glyph, ImageChops.subtract(gap, back))                       # a thin gap between them
    paste_masked(img, fill((W, H), (250, 250, 255)), glyph)
    paste_masked(img, fill((W, H), (226, 230, 250)), back)
    dots = Image.new("L", (W, H), 0)
    dd = ImageDraw.Draw(dots)
    for x in (16.5, 19.5, 22.5):
        dd.ellipse(((x - 1) * SS, 16.5 * SS, (x + 1) * SS, 18.5 * SS), fill=255)
    paste_masked(img, fill((W, H), (88, 106, 190)), dots)
    return img


def copy_icon():
    img = canvas(32, 32)
    W, H = img.size
    back = rr_mask((W, H), (11 * SS, 4 * SS, 27 * SS, 22 * SS), 2 * SS)
    back_in = rr_mask((W, H), (13 * SS, 6 * SS, 25 * SS, 20 * SS), SS)
    paste_masked(img, fill((W, H), (235, 235, 240), 170), ImageChops.subtract(back, back_in))
    front = rr_mask((W, H), (5 * SS, 10 * SS, 21 * SS, 28 * SS), 2 * SS)
    front_in = rr_mask((W, H), (7 * SS, 12 * SS, 19 * SS, 26 * SS), SS)
    paste_masked(img, fill((W, H), (0, 0, 0), 255), front_in)
    paste_masked(img, fill((W, H), (235, 235, 240)), ImageChops.subtract(front, front_in))
    d = ImageDraw.Draw(img)
    for y in (16, 19, 22):
        d.line((9 * SS, y * SS, 17 * SS, y * SS), fill=(235, 235, 240, 255), width=SS)
    # the inside of the front sheet is clear again (only its lines show)
    a = np.asarray(img, np.uint8).copy()
    fi = np.asarray(front_in) > 128
    lines = (a[..., 0] > 200) & fi
    a[fi & ~lines, 3] = 0
    return Image.fromarray(a, "RGBA")


def grip():
    img = canvas(16, 16)
    W, H = img.size
    d = ImageDraw.Draw(img)
    for k in (0, 1, 2):
        off = (4 + k * 4) * SS
        d.line((W - SS, off, off, H - SS), fill=(220, 222, 230, 200 - k * 40), width=SS)
    return img


# -- preview ----------------------------------------------------------------------------------

def backdrop(kind, w, h):
    if kind == "grass":
        n = noise(w, h, 40, 4, seed=1)
        n2 = noise(w, h, 3, 2, seed=2)
        base = np.array([78, 118, 46], np.float32) * (0.75 + 0.45 * n[..., None]) * (0.85 + 0.3 * n2[..., None])
        base[..., 0] += 20 * n2
    else:
        n = noise(w, h, 50, 4, seed=3)
        n2 = noise(w, h, 4, 2, seed=4)
        base = np.array([226, 234, 246], np.float32) * (0.92 + 0.1 * n[..., None]) * (0.96 + 0.06 * n2[..., None])
    return from_arrays(base, np.full((h, w), 255.0))


def slice9(art, w, h, size):
    """Assemble a 9-slice from a 64x64 piece at corner size `size` into a w x h image."""
    c = 16
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    def piece(x0, y0, x1, y1, tw, th):
        return art.crop((x0, y0, x1, y1)).resize((max(1, tw), max(1, th)), Image.LANCZOS)
    mid_w, mid_h = w - 2 * size, h - 2 * size
    out.alpha_composite(piece(0, 0, c, c, size, size), (0, 0))
    out.alpha_composite(piece(64 - c, 0, 64, c, size, size), (w - size, 0))
    out.alpha_composite(piece(0, 64 - c, c, 64, size, size), (0, h - size))
    out.alpha_composite(piece(64 - c, 64 - c, 64, 64, size, size), (w - size, h - size))
    out.alpha_composite(piece(c, 0, 64 - c, c, mid_w, size), (size, 0))
    out.alpha_composite(piece(c, 64 - c, 64 - c, 64, mid_w, size), (size, h - size))
    out.alpha_composite(piece(0, c, c, 64 - c, size, mid_h), (0, size))
    out.alpha_composite(piece(64 - c, c, 64, 64 - c, size, mid_h), (w - size, size))
    return out


def font(size, bold=False):
    for p in ("/usr/share/fonts/truetype/liberation/LiberationSansNarrow-Bold.ttf" if bold else
              "/usr/share/fonts/truetype/liberation/LiberationSansNarrow-Regular.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def ink(c):
    """Core.lua's C.InkRGB: bright game colours as dark ink on paper."""
    r, g, b = [v / 255 for v in c]
    w = min(r, g, b)
    k, lift = 0.44, 0.24
    return (int(max(0.03, r * k - w * lift) * 255), int(max(0.02, (g * k - w * lift) * 0.84) * 255),
            int(max(0.01, (b * k - w * lift) * 0.62) * 255))


SAMPLE = [
    [("14:02 ", "stamp"), ("[G] ", (64, 255, 64)), ("[", (64, 255, 64)), ("Brakkus", (199, 156, 110)), ("]: inv to MC in 5, bring fire res", (64, 255, 64))],
    [("14:02 ", "stamp"), ("[T] ", (255, 192, 192)), ("[", (255, 192, 192)), ("Ilyndra", (255, 255, 255)), ("]: WTS ", (255, 192, 192)), ("[Runecloth]", (255, 255, 255)), (" x40", (255, 192, 192))],
    [("14:03 ", "stamp"), ("[P] ", (170, 170, 255)), ("[", (170, 170, 255)), ("Selwyn", (105, 204, 240)), ("]: ", (170, 170, 255)), ("Herald", (255, 158, 46)), (" ready?", (170, 170, 255))],
    [("14:03 ", "stamp"), ("[", (255, 128, 255)), ("Berra", (171, 212, 115)), ("] whispers: guide at ", (255, 128, 255)), ("[openvanilla.gg/guide]", (111, 182, 255))],
    [("14:04 ", "stamp"), ("[1] ", (255, 192, 192)), ("[", (255, 192, 192)), ("Tomas", (245, 140, 186)), ("]: anyone for Deadmines?", (255, 192, 192)), ("  ×3", (154, 160, 170))],
]


def draw_text(img, x, y, runs, key, f):
    d = ImageDraw.Draw(img)
    t = THEMES[key]
    for text, colour in runs:
        if colour == "stamp":
            colour = {"slate": (138, 144, 156), "parchment": (107, 82, 54), "midnight": (111, 130, 168),
                      "wildwood": (143, 138, 108), "glass": (160, 160, 168)}[key]
        if key in FLAGS_INK:
            colour = ink(colour)
            d.text((x, y), text, font=f, fill=colour + (255,))
        else:
            d.text((x, y), text, font=f, fill=colour + (255,), stroke_width=1, stroke_fill=(0, 0, 0, 255))
        x += d.textlength(text, font=f)


def mock(key, arts, bg_kind, opacity=0.85):
    """One chat window as the game lays it out (Skin.lua's PAD, TAB_H and edge sizes)."""
    t = THEMES[key]
    W, H = 460, 230
    img = backdrop(bg_kind, W, H)
    fx, fy, fw, fh = 26, 54, 400, 110                   # ChatFrame1
    pl, pr, pt, pb = 6, 8, 4, 28                         # C.PAD (docked frame: room for the input line)
    px0, py0, px1, py1 = fx - pl, fy - pt, fx + fw + pr, fy + fh + pb
    pw, ph = px1 - px0, py1 - py0
    size, out = EDGE[key]
    if key != "glass":
        sh = slice9(arts["Chat_Shadow"], pw + 2 * (10 + out), ph + 2 * (10 + out), 16)
        a = sh.getchannel("A").point(lambda v: int(v * (0.55 + 0.45 * opacity)))
        sh.putalpha(a)
        img.alpha_composite(sh, (px0 - 10 - out, py0 - 10 - out + 4))
    face = arts["Chat_Panel" + t["suffix"]].resize((pw, ph), Image.LANCZOS)
    face.putalpha(face.getchannel("A").point(lambda v: int(v * opacity)))
    img.alpha_composite(face, (px0, py0))
    # input well
    well = Image.new("RGBA", (pw - 8, 20), {"slate": (13, 14, 17), "parchment": (173, 143, 97), "midnight": (5, 8, 15),
                                             "wildwood": (14, 13, 9), "glass": (0, 0, 0)}[key] + (int(255 * min(1, opacity + 0.1) * (0.8 if key == "glass" else 1)),))
    img.alpha_composite(well, (px0 + 4, py1 - 24))
    d = ImageDraw.Draw(img)
    d.line((px0 + 4, py1 - 25, px1 - 5, py1 - 25), fill=t["edge"] + (200 if key != "glass" else 36,))
    edge = slice9(arts["Chat_Edge" + t["suffix"]], pw + 2 * out, ph + 2 * out, size)
    img.alpha_composite(edge, (px0 - out, py0 - out))
    if key in ("slate", "midnight", "glass"):
        d.line((px0 + 1, py0 + 1, px1 - 2, py0 + 1), fill=t["top"] + (140 if key != "glass" else 46,))
    # tabs (on top of a thick frame: Skin.lua's C:TabLift)
    tf = font(11, True)
    x = px0 + 2
    lift = max(0, out - 2)
    py0 -= lift
    for i, name in enumerate(["General", "Combat Log", "Guild"]):
        tw = int(d.textlength(name, font=tf)) + 20
        tabimg = arts["Chat_Tab" + t["suffix"]].resize((tw, 20), Image.LANCZOS)
        alpha = (1 if i == 0 else 0.72) * max(opacity, 0.55)
        tabimg.putalpha(tabimg.getchannel("A").point(lambda v, a=alpha: int(v * a)))
        img.alpha_composite(tabimg, (x, py0 - 20))
        col = t["text"] if i == 0 else t["muted"]
        if key in FLAGS_INK:
            d.text((x + 10, py0 - 17), name, font=tf, fill=col)
        else:
            d.text((x + 10, py0 - 17), name, font=tf, fill=col, stroke_width=1, stroke_fill=(0, 0, 0))
        if i == 0:
            d.rectangle((x + 3, py0 - 2, x + tw - 4, py0 - 1), fill=t["accent"])
        if i == 2:
            dotimg = arts["Chat_Dot"].resize((6, 6), Image.LANCZOS)
            tint = Image.new("RGBA", dotimg.size, t["accent"] + (255,))
            tint.putalpha(dotimg.getchannel("A"))
            img.alpha_composite(tint, (x + tw - 9, py0 - 17))
        x += tw + 1
    for j, nm in enumerate(["Chat_Menu", "Chat_Copy"]):
        ic = arts[nm].resize((18, 18), Image.LANCZOS)
        tint = Image.new("RGBA", ic.size, t["muted"] + (255,))
        tint.putalpha(ic.getchannel("A"))
        img.alpha_composite(tint, (px1 - 20 - j * 20, py0 - 19))
    py0 += lift
    # text
    f = font(13)
    for i, runs in enumerate(SAMPLE):
        draw_text(img, fx + 2, fy + 6 + i * 20, runs, key, f)
    hint_col = t["muted"]
    hf = font(10)
    if key in FLAGS_INK:
        d.text((px0 + 12, py1 - 20), "Press Enter to chat", font=hf, fill=hint_col)
    else:
        d.text((px0 + 12, py1 - 20), "Press Enter to chat", font=hf, fill=hint_col + (190,), stroke_width=1, stroke_fill=(0, 0, 0, 160))
    # jump arrow (as if scrolled up) and the scrollbar on hover, on the Slate one
    if key == "slate":
        img.alpha_composite(arts["Chat_Arrow"].resize((20, 20), Image.LANCZOS), (fx + fw - 18, fy + fh - 20))
        d.rectangle((fx + fw + 2, fy + 2, fx + fw + 4, fy + fh - 2), fill=t["edge"] + (90,))
        d.rectangle((fx + fw + 2, fy + 20, fx + fw + 4, fy + 60), fill=t["accent"] + (220,))
    label = font(12, True)
    d.text((8, H - 18), key.capitalize() + ("  (default, 85%)" if key == "slate" else ""), font=label, fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))
    return img


def preview(arts, path):
    tiles = []
    for key in ORDER:
        row = [mock(key, arts, "grass"), mock(key, arts, "snow")]
        tiles.append(row)
    W = 460 * 2 + 30
    H = 230 * len(ORDER) + 10 * (len(ORDER) + 1)
    sheet = Image.new("RGBA", (W, H), (24, 25, 29, 255))
    for r, row in enumerate(tiles):
        for c, im in enumerate(row):
            sheet.alpha_composite(im, (10 + c * 470, 10 + r * 240))
    sheet.save(path)
    print("preview:", path)


def main():
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
        makers = {"Chat_Discord": (discord_icon, (32, 32))}
        fn, size = makers[only]
        print("  +", only, save(only, fn(), size).size)
        return
    arts = {}
    for key in ORDER:
        t = THEMES[key]
        arts["Chat_Panel" + t["suffix"]] = save("Chat_Panel" + t["suffix"], panel(key), (256, 64))
        arts["Chat_Tab" + t["suffix"]] = save("Chat_Tab" + t["suffix"], tab(key), (64, 32))
        arts["Chat_Edge" + t["suffix"]] = save("Chat_Edge" + t["suffix"], edge(key), (64, 64))
    arts["Chat_Shadow"] = save("Chat_Shadow", shadow(), (64, 64))
    arts["Chat_Dot"] = save("Chat_Dot", dot(), (16, 16))
    arts["Chat_Arrow"] = save("Chat_Arrow", arrow(), (32, 32))
    arts["Chat_Menu"] = save("Chat_Menu", menu_icon(), (32, 32))
    arts["Chat_Copy"] = save("Chat_Copy", copy_icon(), (32, 32))
    arts["Chat_Grip"] = save("Chat_Grip", grip(), (16, 16))
    arts["Chat_Discord"] = save("Chat_Discord", discord_icon(), (32, 32))
    for name, im in arts.items():
        print("  +", name, im.size)
    if "--preview" in sys.argv:
        preview(arts, sys.argv[sys.argv.index("--preview") + 1])


if __name__ == "__main__":
    main()
