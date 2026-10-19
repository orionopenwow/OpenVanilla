"""Herald Autopilot's art, drawn with Pillow: the window, its gold frames, plaques, buttons, icons,
item icons and the zone map. Nothing is copied from a game; the portrait is Open Vanilla's own Herald.

    python ap_art.py            writes every asset to autopilot/assets/ui/ (the app does this too,
                                on first run or when ART_VERSION changes)

Everything is supersampled (drawn at 3x, then downsampled) so edges stay clean.
"""
from __future__ import annotations

import json
import math
import os
import random
from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ART_VERSION = 18
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
UI = os.path.join(ASSETS, "ui")
FONTS = os.path.join(ASSETS, "fonts")
SS = 3

W, H = 1100, 650
RADIUS = 18          # the window's rounded corners
MAP_SIZE = (272, 194)

# The layout every page shares (x0, y0, x1, y1). The app reads these too.
L = {
    "header": (0, 0, W, 100),
    "portrait": (22, 10, 106, 94),
    "nav": (22, 112, 262, 404),
    "control": (22, 430, 262, 628),
    "center_top": (282, 122, 770, 334),
    "center_bottom": (282, 352, 770, 628),
    "center_wide": (282, 122, 1078, 628),
    "map": (788, 122, 1078, 346),
    "bags": (788, 364, 1078, 500),
    "realm": (788, 518, 1078, 628),
}
NAV = ("play", "rules", "sim", "session", "settings")
NAV_LABELS = {"play": "Play", "rules": "Rules", "sim": "Sim", "session": "Session", "settings": "Settings"}

# palette
NAVY = (12, 17, 32)
NAVY2 = (18, 25, 44)
PANEL_TOP = (20, 27, 46)
PANEL_BOT = (11, 15, 27)
GOLD_DARK = (92, 64, 22)
GOLD = (196, 150, 64)
GOLD_LIGHT = (246, 214, 138)
GOLD_TEXT = (233, 196, 106)
PARCHMENT = (226, 214, 186)
GREEN = (74, 200, 96)
RED = (206, 64, 52)


# ------------------------------------------------------------------------------------- basics
@lru_cache(maxsize=64)
def font(kind="display", size=16):
    files = {"display": ["arialbd.ttf", "LiberationSans-Bold.ttf", "Cinzel-Bold.ttf"],
             "display-semi": ["arialbd.ttf", "LiberationSans-Bold.ttf", "Cinzel-SemiBold.ttf"],
             "display-regular": ["arial.ttf", "LiberationSans-Regular.ttf", "Cinzel-Regular.ttf"], "ui": ["segoeui.ttf", "DejaVuSans.ttf"],
             "ui-bold": ["segoeuib.ttf", "DejaVuSans-Bold.ttf"]}[kind]
    dirs = [FONTS, os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts"), "/usr/share/fonts/truetype/liberation",
            "/usr/share/fonts/truetype/dejavu", "/Library/Fonts", "/System/Library/Fonts/Supplemental"]
    for f in files:
        for d in dirs:
            p = os.path.join(d, f)
            if os.path.isfile(p):
                return ImageFont.truetype(p, size)
    return ImageFont.load_default(size)


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(min(len(a), len(b))))


def vgrad(w, h, top, bot):
    g = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(g)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=mix(top, bot, y / max(1, h - 1)) + (255,))
    return g


def radial(size, inner, outer, cx=0.5, cy=0.5, power=1.0):
    w, h = size
    img = Image.new("RGBA", size)
    px = img.load()
    rmax = math.hypot(max(cx, 1 - cx) * w, max(cy, 1 - cy) * h)
    for y in range(h):
        for x in range(w):
            t = min(1.0, math.hypot(x - cx * w, y - cy * h) / rmax) ** power
            px[x, y] = mix(inner, outer, t) + (255,)
    return img


def shrink(img, w, h):
    return img.resize((w, h), Image.Resampling.LANCZOS)


def text_image(text, size=16, color=GOLD_TEXT, kind="display", shadow=True, spacing=0):
    f = font(kind, size)
    bbox = f.getbbox(text)
    tw = bbox[2] - bbox[0] + spacing * max(0, len(text) - 1) + 4
    th = size + 8
    img = Image.new("RGBA", (tw + 4, th), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = 2 - bbox[0]
    y = (th - size) // 2 - 2
    if spacing:
        cx = x
        for ch in text:
            if shadow:
                d.text((cx + 1, y + 2), ch, font=f, fill=(0, 0, 0, 200))
            d.text((cx, y), ch, font=f, fill=color)
            cx += f.getlength(ch) + spacing
    else:
        if shadow:
            d.text((x + 1, y + 2), text, font=f, fill=(0, 0, 0, 200))
        d.text((x, y), text, font=f, fill=color)
    return img


def emboss_text(text, px, color, kind="display"):
    """Crisp embossed label: a soft drop shadow, a dark edge below, a faint light edge above, then the
    letters. One image, so the layers never smear the way stacked canvas text can."""
    f = font(kind, px)
    l, t, r, b = f.getbbox(text)
    pad = 4
    w, h = (r - l) + pad * 2, (b - t) + pad * 2
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).text((pad - l, pad - t), text, font=f, fill=255)
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    def layer(rgb, alpha, dx, dy, blur=0.0):
        m = ImageChops.offset(mask, dx, dy)
        if blur:
            m = m.filter(ImageFilter.GaussianBlur(blur))
        lay = Image.new("RGBA", (w, h), rgb + (0,))
        lay.putalpha(m.point(lambda v: v * alpha // 255))
        out.alpha_composite(lay)
    rgb = tuple(int(color.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)) if isinstance(color, str) else color
    layer((0, 0, 0), 170, 1, 2, 1.3)          # slight drop shadow
    layer((0, 0, 0), 235, 0, 1)               # the embossed dark edge
    layer(mix(rgb, (255, 255, 255), 0.6), 120, 0, -1)   # and its light edge
    layer(rgb, 255, 0, 0)
    return out


def gold_text(text, size, kind="display", spacing=0):
    """Text filled with a vertical gold gradient and a dark outline: the title look."""
    f = font(kind, size)
    bbox = f.getbbox(text)
    tw = int(f.getlength(text) + spacing * max(0, len(text) - 1)) + 10
    th = size + 14
    mask = Image.new("L", (tw, th), 0)
    d = ImageDraw.Draw(mask)
    x, y = 5 - bbox[0], 6 - bbox[1] // 2
    cx = x
    for ch in text:
        d.text((cx, y), ch, font=f, fill=255)
        cx += f.getlength(ch) + spacing
    fill = vgrad(tw, th, (255, 236, 170), (178, 122, 40))
    out = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    outline = mask.filter(ImageFilter.MaxFilter(3))
    shadow = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    shadow.paste((10, 6, 2, 230), (0, 0), outline)
    shadow = ImageChops.offset(shadow, 1, 2)
    out.alpha_composite(shadow)
    ol = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    ol.paste((40, 24, 6, 255), (0, 0), outline)
    out.alpha_composite(ol)
    hl = Image.new("RGBA", (tw, th), (0, 0, 0, 0))        # emboss: a light edge above-left
    hl.paste((255, 246, 210, 255), (0, 0), mask)
    out.alpha_composite(ImageChops.offset(hl, -1, -1))
    body = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    body.paste(fill, (0, 0), mask)
    out.alpha_composite(body)
    return out


# ------------------------------------------------------------------------------------- frames
def _bevel_rect(d, box, width, light=GOLD_LIGHT, mid=GOLD, dark=GOLD_DARK):
    x0, y0, x1, y1 = box
    for i in range(width):
        t = i / max(1, width - 1)
        c = mix(dark, light, 1 - abs(t - 0.4) * 1.6) if t < 0.8 else mix(mid, dark, (t - 0.8) * 5)
        d.rectangle([x0 + i, y0 + i, x1 - i, y1 - i], outline=c + (255,))


def _corner(d, x, y, sx, sy, s):
    """A small gold flourish in a panel corner (sx, sy = +1/-1 direction)."""
    pts = [(x, y + sy * 14 * s), (x, y), (x + sx * 14 * s, y)]
    d.line(pts, fill=GOLD_LIGHT + (255,), width=2 * s)
    d.ellipse([x + sx * 4 * s - 3 * s, y + sy * 4 * s - 3 * s, x + sx * 4 * s + 3 * s, y + sy * 4 * s + 3 * s],
              fill=GOLD + (255,), outline=GOLD_DARK + (255,))
    d.arc([x + (sx * 6 - 6) * s if sx > 0 else x - 18 * s, y + (sy * 6 - 6) * s if sy > 0 else y - 18 * s,
           x + (sx * 6 + 12) * s if sx > 0 else x + 0 * s, y + (sy * 6 + 12) * s if sy > 0 else y],
          0, 360, fill=GOLD_DARK + (255,), width=s)


def panel(w, h, plaque=True, inner=True):
    """A dark panel in a double gold frame with corner pieces; plaque = the ornate title slot on top."""
    s = SS
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    body = vgrad(w * s, h * s, PANEL_TOP, PANEL_BOT)
    # faint diagonal sheen
    sheen = Image.new("L", (w * s, h * s), 0)
    sd = ImageDraw.Draw(sheen)
    sd.polygon([(0, 0), (w * s * 0.55, 0), (w * s * 0.25, h * s), (0, h * s)], fill=10)
    body.paste((255, 255, 255), (0, 0), sheen.filter(ImageFilter.GaussianBlur(30)))
    img.paste(body, (0, 0))
    d = ImageDraw.Draw(img)
    _bevel_rect(d, (0, 0, w * s - 1, h * s - 1), 4 * s)
    d.rectangle([6 * s, 6 * s, w * s - 6 * s - 1, h * s - 6 * s - 1], outline=GOLD_DARK + (255,), width=s)
    if inner:
        d.rectangle([8 * s, 8 * s, w * s - 8 * s - 1, h * s - 8 * s - 1], outline=(40, 48, 70, 255), width=s)
    for (x, y, sx, sy) in ((3 * s, 3 * s, 1, 1), (w * s - 3 * s, 3 * s, -1, 1), (3 * s, h * s - 3 * s, 1, -1),
                           (w * s - 3 * s, h * s - 3 * s, -1, -1)):
        d.polygon([(x, y), (x + sx * 16 * s, y), (x, y + sy * 16 * s)], fill=GOLD + (255,))
        d.polygon([(x + sx * 2 * s, y + sy * 2 * s), (x + sx * 11 * s, y + sy * 2 * s), (x + sx * 2 * s, y + sy * 11 * s)],
                  fill=GOLD_LIGHT + (255,))
    out = shrink(img, w, h)
    if plaque:
        p = title_plaque(min(w - 60, 300))
        out.alpha_composite(p, ((w - p.width) // 2, 0))
    return out


def title_plaque(w):
    """The ornate slot a panel's title sits in (dark centre, gold rims, pointed ends)."""
    h = 30
    s = SS
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pts = [(0, h * s // 2), (16 * s, 2 * s), (w * s - 16 * s, 2 * s), (w * s, h * s // 2), (w * s - 16 * s, h * s - 2 * s),
           (16 * s, h * s - 2 * s)]
    d.polygon(pts, fill=GOLD_DARK + (255,))
    inner = [(5 * s, h * s // 2), (19 * s, 5 * s), (w * s - 19 * s, 5 * s), (w * s - 5 * s, h * s // 2),
             (w * s - 19 * s, h * s - 5 * s), (19 * s, h * s - 5 * s)]
    g = vgrad(w * s, h * s, (34, 40, 62), (14, 18, 32))
    m = Image.new("L", (w * s, h * s), 0)
    ImageDraw.Draw(m).polygon(inner, fill=255)
    img.paste(g, (0, 0), m)
    d.line(pts + [pts[0]], fill=GOLD_LIGHT + (255,), width=2 * s)
    d.line(inner + [inner[0]], fill=GOLD + (255,), width=s)
    # little scrolls on the ends
    for cx in (9 * s, w * s - 9 * s):
        d.ellipse([cx - 3 * s, h * s // 2 - 3 * s, cx + 3 * s, h * s // 2 + 3 * s], fill=GOLD_LIGHT + (255,))
    return shrink(img, w, h)


def starfield(w, h, seed=11):
    rng = random.Random(seed)
    bg = radial((w // 4, h // 4), (28, 36, 66), (6, 9, 18), 0.55, 0.35, 0.9).resize((w, h), Image.Resampling.BICUBIC)
    neb = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    nd = ImageDraw.Draw(neb)
    for _ in range(14):
        x, y, r = rng.randint(0, w), rng.randint(0, h), rng.randint(60, 200)
        c = rng.choice([(60, 70, 140), (90, 60, 130), (40, 90, 130)])
        nd.ellipse([x - r, y - r, x + r, y + r], fill=c + (rng.randint(10, 22),))
    bg.alpha_composite(neb.filter(ImageFilter.GaussianBlur(60)))
    d = ImageDraw.Draw(bg)
    for _ in range(420):
        x, y = rng.randint(0, w - 1), rng.randint(0, h - 1)
        a = rng.randint(60, 220)
        c = rng.choice([(255, 255, 255), (200, 210, 255), (255, 236, 200)])
        if rng.random() < 0.06:
            d.ellipse([x - 1, y - 1, x + 1, y + 1], fill=c + (a,))
        else:
            d.point((x, y), fill=c + (a,))
    return bg


def window_background(page_kind="play"):
    """The whole window behind the widgets: stars, the outer frame, the header band, every panel."""
    img = starfield(W, H)
    # header band
    hb = vgrad(W, 98, (16, 22, 40), (10, 14, 26))
    hb.putalpha(235)
    img.alpha_composite(hb, (0, 0))
    d = ImageDraw.Draw(img)
    d.line([(0, 97), (W, 97)], fill=GOLD_DARK + (255,), width=1)
    d.line([(0, 98), (W, 98)], fill=GOLD + (200,), width=1)
    # panels
    def put(name, plaque=True):
        x0, y0, x1, y1 = L[name]
        img.alpha_composite(panel(x1 - x0, y1 - y0, False), (x0, y0))
        if plaque:  # the title plaque sits across the panel's top edge
            p = title_plaque(min(x1 - x0 - 70, 270))
            img.alpha_composite(p, (x0 + (x1 - x0 - p.width) // 2, y0 - 12))
    put("nav", plaque=False)
    put("control")
    if page_kind == "play":
        put("center_top")
        put("center_bottom")
        put("map")
        put("bags")
        put("realm")
    else:
        put("center_wide")
    # outer window frame
    f = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
    fd = ImageDraw.Draw(f)
    _bevel_rect(fd, (0, 0, W * SS - 1, H * SS - 1), 5 * SS)
    fd.rectangle([7 * SS, 7 * SS, W * SS - 7 * SS - 1, H * SS - 7 * SS - 1], outline=GOLD_DARK + (255,), width=SS)
    img.alpha_composite(shrink(f, W, H))
    return img


# ------------------------------------------------------------------------------------- sleek window (kit)
def glass_panel(w, h, radius=12):
    """A rounded, dark glass panel with a thin gold rim and a faint top highlight."""
    s = SS
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    body = vgrad(w * s, h * s, (18, 24, 42), (8, 11, 20))
    m = Image.new("L", (w * s, h * s), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w * s - 1, h * s - 1], radius=radius * s, fill=228)
    img.paste(body, (0, 0), m)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, w * s - 1, h * s - 1], radius=radius * s, outline=GOLD + (210,), width=s)
    d.rounded_rectangle([3 * s, 3 * s, w * s - 3 * s - 1, h * s - 3 * s - 1], radius=(radius - 3) * s,
                        outline=(255, 255, 255, 16), width=s)
    return shrink(img, w, h)


def kit_plaque(width=176):
    from ap_kit import piece
    p = piece("plaque_small")
    return p.resize((width, round(p.height * width / p.width)), Image.Resampling.LANCZOS)


def kit_corner(size=78):
    from ap_kit import piece
    c = piece("corner")
    d = ImageDraw.Draw(c)
    d.rectangle([50, 80, 104, 104], fill=(0, 0, 0, 0))
    d.rectangle([80, 50, 104, 80], fill=(0, 0, 0, 0))
    a = c.split()[3].load()
    for y in range(c.height):
        for x in range(c.width):
            f = (min(1.0, (104 - x) / 26) if x > 78 else 1.0) * (min(1.0, (104 - y) / 26) if y > 78 else 1.0)
            a[x, y] = int(a[x, y] * max(0.0, f))
    return c.resize((size, size), Image.Resampling.LANCZOS)


def rounded_mask(w, h, r):
    m = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w * SS - 1, h * SS - 1], radius=r * SS, fill=255)
    return m.resize((w, h), Image.Resampling.LANCZOS)


def sleek_background(page_kind="play"):
    """The whole window: rounded, a starfield, a thin gold edge with the kit's corner flourishes,
    and glass panels with the kit's title plaques across their top edges."""
    from PIL import ImageOps
    img = starfield(W, H)
    shade = vgrad(W, 100, (14, 20, 38), (10, 14, 26))
    shade.putalpha(150)
    img.alpha_composite(shade, (0, 0))
    d = ImageDraw.Draw(img)
    d.line([(40, 100), (W - 40, 100)], fill=GOLD_DARK + (180,), width=1)
    names = ["center_top", "center_bottom", "map", "bags", "realm"] if page_kind == "play" else ["center_wide"]
    for n in names:
        x0, y0, x1, y1 = L[n]
        img.alpha_composite(glass_panel(x1 - x0, y1 - y0), (x0, y0))
        p = kit_plaque(236 if x1 - x0 > 400 else 170)
        img.alpha_composite(p, (x0 + (x1 - x0 - p.width) // 2, y0 - p.height // 2 + 1))
    # nav / control column backing
    x0, y0, _, _ = L["nav"]
    _, _, x1, y1 = L["control"]
    col = glass_panel(x1 - x0, y1 - y0 + 8, 14)
    col.putalpha(col.split()[3].point(lambda v: int(v * 0.55)))
    img.alpha_composite(col, (x0, y0 - 8))
    from ap_kit import piece
    div = piece("divider").resize((200, 22), Image.Resampling.LANCZOS)
    img.alpha_composite(div, ((x0 + x1 - 200) // 2, L["control"][1] - 14))
    # the window edge: thin gold, rounded, with the flourish in each corner
    edge = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    ed.rounded_rectangle([SS, SS, W * SS - SS - 1, H * SS - SS - 1], radius=RADIUS * SS, outline=GOLD_DARK + (255,), width=4 * SS)
    ed.rounded_rectangle([2 * SS, 2 * SS, W * SS - 2 * SS - 1, H * SS - 2 * SS - 1], radius=(RADIUS - 1) * SS,
                         outline=GOLD + (255,), width=2 * SS)
    img.alpha_composite(shrink(edge, W, H))
    c = kit_corner(56)
    img.alpha_composite(c, (0, 0))
    img.alpha_composite(ImageOps.mirror(c), (W - c.width, 0))
    img.alpha_composite(ImageOps.flip(c), (0, H - c.height))
    img.alpha_composite(ImageOps.flip(ImageOps.mirror(c)), (W - c.width, H - c.height))
    # round it: outside the rounded rect is fully transparent (the app keys it out on Windows)
    img.putalpha(ImageChops.multiply(img.split()[3], rounded_mask(W, H, RADIUS)))
    return img


def kit_nav(base, glyph=None, medallion_from=None):
    """A kit nav bar. Every bar is built on the same base (the sheet's Overview bar) so they all have
    one length and shape; medallion_from = another sheet bar whose round icon is moved onto it,
    glyph = one of GLYPHS drawn on a blank medallion instead."""
    if medallion_from is not None:
        out = base.copy()
        h = base.height
        src = medallion_from.crop((0, 0, medallion_from.height, medallion_from.height))
        src = src.resize((h, h), Image.Resampling.LANCZOS)
        m = Image.new("L", (h * 4, h * 4), 0)
        ImageDraw.Draw(m).ellipse([2, 2, h * 4 - 3, h * 4 - 3], fill=255)
        m = m.resize((h, h), Image.Resampling.LANCZOS)
        src.putalpha(ImageChops.multiply(src.split()[3], m))
        clear = Image.new("RGBA", (h, h), (0, 0, 0, 0))
        out.paste(clear, (0, 0), m)             # lift the old medallion out
        out.alpha_composite(src, (0, 0))
        return out
    if glyph is None:
        return base
    from ap_kit import blank_medallion
    out = base.copy()
    med = blank_medallion(base)
    s = 4
    g = Image.new("RGBA", (med.width * s, med.height * s), (0, 0, 0, 0))
    glyph(ImageDraw.Draw(g), med.width * s, s)
    g = g.resize(med.size, Image.Resampling.LANCZOS)
    med.alpha_composite(g)
    out.alpha_composite(med, (0, 0))
    return out


NAV_KIT = {"play": ("nav_house", None), "rules": ("nav_notes", None), "sim": ("nav_house", "sim"),
           "session": ("nav_chart", None), "settings": ("nav_gears", None)}


def kit_medallion(glyph, size=56, shadow=True):
    """The kit's round medallion with one of our glyphs: cut to a perfect circle (the sheet's nav bar
    joins it on the right) with a slight drop shadow. The image is size + 8 px square, the medallion
    centred in it."""
    from ap_kit import blank_medallion, piece
    med = blank_medallion(piece("nav_house"))
    med = med.crop((0, 0, med.height, med.height))
    s = 4
    g = Image.new("RGBA", (med.width * s, med.height * s), (0, 0, 0, 0))
    GLYPHS[glyph](ImageDraw.Draw(g), med.width * s, s)
    med.alpha_composite(g.resize(med.size, Image.Resampling.LANCZOS))
    big = med.resize((size * SS, size * SS), Image.Resampling.LANCZOS)
    m = Image.new("L", big.size, 0)
    ImageDraw.Draw(m).ellipse([SS, SS, big.width - SS - 1, big.height - SS - 1], fill=255)
    big.putalpha(ImageChops.multiply(big.split()[3], m))
    # a thin gold ring on the cut so the edge is clean all the way round
    ImageDraw.Draw(big).ellipse([SS, SS, big.width - SS - 1, big.height - SS - 1], outline=GOLD_DARK + (255,), width=SS)
    circle = big.resize((size, size), Image.Resampling.LANCZOS)
    pad = 4
    out = Image.new("RGBA", (size + pad * 2, size + pad * 2), (0, 0, 0, 0))
    if shadow:
        sh = Image.new("L", out.size, 0)
        ImageDraw.Draw(sh).ellipse([pad + 1, pad + 3, pad + size + 1, pad + size + 3], fill=150)
        dark = Image.new("RGBA", out.size, (0, 0, 0, 0))
        dark.putalpha(sh.filter(ImageFilter.GaussianBlur(2.5)))
        out.alpha_composite(dark)
    out.alpha_composite(circle, (pad, pad))
    return out


# ------------------------------------------------------------------------------------- portrait
def portrait(size=108):
    src = os.path.join(ASSETS, "herald_portrait_src.jpg")
    s = SS
    big = size * s
    face = Image.open(src).convert("RGBA")
    # the source has its own green ring; crop inside it
    fw = face.width
    m = int(fw * 0.075)
    face = face.crop((m, m, fw - m, fw - m)).resize((big, big), Image.Resampling.LANCZOS)
    out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).ellipse([6 * s, 6 * s, big - 6 * s, big - 6 * s], fill=255)
    out.paste(face, (0, 0), mask)
    d = ImageDraw.Draw(out)
    # gold ring: outer dark, bright bevel, inner dark
    for i, c in enumerate([GOLD_DARK, GOLD, GOLD_LIGHT, GOLD_LIGHT, GOLD, GOLD_DARK]):
        d.ellipse([i * s, i * s, big - i * s - 1, big - i * s - 1], outline=c + (255,), width=s)
    d.ellipse([6 * s, 6 * s, big - 6 * s, big - 6 * s], outline=(30, 20, 6, 255), width=s)
    # four studs
    for a in (45, 135, 225, 315):
        cx = big / 2 + math.cos(math.radians(a)) * (big / 2 - 3 * s)
        cy = big / 2 + math.sin(math.radians(a)) * (big / 2 - 3 * s)
        d.ellipse([cx - 4 * s, cy - 4 * s, cx + 4 * s, cy + 4 * s], fill=GOLD_LIGHT + (255,), outline=GOLD_DARK + (255,))
    shadow = Image.new("RGBA", (big + 12 * s, big + 12 * s), (0, 0, 0, 0))
    sm = Image.new("L", shadow.size, 0)
    ImageDraw.Draw(sm).ellipse([6 * s, 9 * s, big + 6 * s, big + 9 * s], fill=170)
    shadow.paste((0, 0, 0), (0, 0), sm.filter(ImageFilter.GaussianBlur(5 * s)))
    shadow.alpha_composite(out, (6 * s, 6 * s))
    return shrink(shadow, size + 12, size + 12)


def wordmark():
    a = gold_text("OPEN VANILLA", 26, spacing=1)
    b = text_image("NETWORK", 12, (196, 176, 130), "display-semi", spacing=4)
    w = max(a.width, b.width + 70)
    img = Image.new("RGBA", (w, a.height + b.height - 4), (0, 0, 0, 0))
    img.alpha_composite(a, ((w - a.width) // 2, 0))
    y = a.height - 6
    img.alpha_composite(b, ((w - b.width) // 2, y))
    d = ImageDraw.Draw(img)
    mid = y + b.height // 2
    d.line([(4, mid), ((w - b.width) // 2 - 6, mid)], fill=GOLD + (220,), width=1)
    d.line([((w + b.width) // 2 + 6, mid), (w - 4, mid)], fill=GOLD + (220,), width=1)
    return img


# ------------------------------------------------------------------------------------- icons
def _medallion(size, glyph, active=False):
    s = SS
    big = size * s
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    body = radial((big, big), (52, 62, 92) if active else (40, 46, 66), (12, 15, 26), 0.4, 0.35)
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).ellipse([3 * s, 3 * s, big - 3 * s, big - 3 * s], fill=255)
    img.paste(body, (0, 0), m)
    for i, c in enumerate([GOLD_DARK, GOLD_LIGHT if active else GOLD, GOLD, GOLD_DARK]):
        d.ellipse([i * s, i * s, big - i * s - 1, big - i * s - 1], outline=c + (255,), width=s)
    g = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    glyph(ImageDraw.Draw(g), big, s)
    sh = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    sh.paste((0, 0, 0, 180), (0, 0), g.split()[3])
    img.alpha_composite(ImageChops.offset(sh, s, 2 * s))
    img.alpha_composite(g)
    return shrink(img, size, size)


def _gold_fill(d):
    return GOLD_LIGHT + (255,)


def g_play(d, b, s):   # a drawn bow with an arrow: "go play"
    c = GOLD_LIGHT + (255,)
    d.arc([b * 0.22, b * 0.2, b * 0.62, b * 0.8], 270, 90, fill=c, width=3 * s)
    d.line([(b * 0.42, b * 0.2), (b * 0.42, b * 0.8)], fill=c, width=s)
    d.line([(b * 0.3, b * 0.5), (b * 0.78, b * 0.5)], fill=c, width=2 * s)
    d.polygon([(b * 0.82, b * 0.5), (b * 0.72, b * 0.43), (b * 0.72, b * 0.57)], fill=c)


def g_rules(d, b, s):  # a scroll with lines
    c = GOLD_LIGHT + (255,)
    d.rounded_rectangle([b * 0.28, b * 0.24, b * 0.72, b * 0.76], radius=3 * s, outline=c, width=2 * s)
    for i in range(4):
        y = b * (0.36 + i * 0.1)
        d.line([(b * 0.36, y), (b * (0.64 if i % 2 == 0 else 0.56), y)], fill=c, width=2 * s)
    d.ellipse([b * 0.22, b * 0.2, b * 0.34, b * 0.32], outline=c, width=2 * s)


def g_sim(d, b, s):    # balance scales
    c = GOLD_LIGHT + (255,)
    d.line([(b * 0.5, b * 0.22), (b * 0.5, b * 0.74)], fill=c, width=2 * s)
    d.line([(b * 0.26, b * 0.32), (b * 0.74, b * 0.32)], fill=c, width=2 * s)
    d.line([(b * 0.38, b * 0.74), (b * 0.62, b * 0.74)], fill=c, width=3 * s)
    for x in (0.3, 0.7):
        d.line([(b * x, b * 0.32), (b * (x - 0.08), b * 0.52)], fill=c, width=s)
        d.line([(b * x, b * 0.32), (b * (x + 0.08), b * 0.52)], fill=c, width=s)
        d.chord([b * (x - 0.1), b * 0.44, b * (x + 0.1), b * 0.6], 0, 180, fill=c)


def g_session(d, b, s):  # an hourglass
    c = GOLD_LIGHT + (255,)
    d.line([(b * 0.32, b * 0.24), (b * 0.68, b * 0.24)], fill=c, width=3 * s)
    d.line([(b * 0.32, b * 0.76), (b * 0.68, b * 0.76)], fill=c, width=3 * s)
    d.polygon([(b * 0.36, b * 0.27), (b * 0.64, b * 0.27), (b * 0.5, b * 0.5)], outline=c, width=2 * s)
    d.polygon([(b * 0.5, b * 0.5), (b * 0.64, b * 0.73), (b * 0.36, b * 0.73)], fill=c)


def g_settings(d, b, s):  # a cog
    c = GOLD_LIGHT + (255,)
    cx = cy = b / 2
    for i in range(8):
        a = math.radians(i * 45)
        x, y = cx + math.cos(a) * b * 0.24, cy + math.sin(a) * b * 0.24
        d.ellipse([x - b * 0.06, y - b * 0.06, x + b * 0.06, y + b * 0.06], fill=c)
    d.ellipse([cx - b * 0.2, cy - b * 0.2, cx + b * 0.2, cy + b * 0.2], fill=c)
    d.ellipse([cx - b * 0.08, cy - b * 0.08, cx + b * 0.08, cy + b * 0.08], fill=(20, 24, 40, 255))


def g_level(d, b, s):  # chevrons up
    c = GOLD_LIGHT + (255,)
    for i, y in enumerate((0.58, 0.42, 0.26)):
        d.line([(b * 0.3, b * (y + 0.14)), (b * 0.5, b * y), (b * 0.7, b * (y + 0.14))], fill=c, width=(3 if i else 2) * s)


def g_quest(d, b, s):  # the quest "!"
    c = (255, 214, 60, 255)
    d.polygon([(b * 0.42, b * 0.2), (b * 0.58, b * 0.2), (b * 0.54, b * 0.62), (b * 0.46, b * 0.62)], fill=c)
    d.ellipse([b * 0.43, b * 0.68, b * 0.57, b * 0.82], fill=c)


def g_gather(d, b, s):  # a leaf and a pick
    c = GOLD_LIGHT + (255,)
    d.line([(b * 0.28, b * 0.74), (b * 0.6, b * 0.34)], fill=c, width=3 * s)
    d.arc([b * 0.42, b * 0.18, b * 0.86, b * 0.5], 190, 330, fill=c, width=3 * s)
    d.chord([b * 0.18, b * 0.36, b * 0.46, b * 0.64], 0, 360, fill=(110, 190, 90, 255))
    d.line([(b * 0.22, b * 0.6), (b * 0.42, b * 0.4)], fill=(30, 70, 30, 255), width=s)


def g_follow(d, b, s):  # two footprints
    c = GOLD_LIGHT + (255,)
    for (x, y) in ((0.36, 0.56), (0.6, 0.32)):
        d.ellipse([b * (x - 0.07), b * (y - 0.1), b * (x + 0.07), b * (y + 0.1)], fill=c)
        for k in range(3):
            d.ellipse([b * (x - 0.07 + k * 0.05), b * (y - 0.18), b * (x - 0.03 + k * 0.05), b * (y - 0.13)], fill=c)


def g_dungeon(d, b, s):  # a gate arch with bars
    c = GOLD_LIGHT + (255,)
    d.rectangle([b * 0.26, b * 0.44, b * 0.74, b * 0.78], outline=c, width=2 * s)
    d.pieslice([b * 0.26, b * 0.2, b * 0.74, b * 0.68], 180, 360, outline=c, width=2 * s)
    for x in (0.38, 0.5, 0.62):
        d.line([(b * x, b * 0.32 if x == 0.5 else b * 0.36), (b * x, b * 0.78)], fill=c, width=s)


GLYPHS = {"play": g_play, "rules": g_rules, "sim": g_sim, "session": g_session, "settings": g_settings,
          "level": g_level, "quest": g_quest, "gather": g_gather, "follow": g_follow, "dungeon": g_dungeon}


def nav_row(w, h, active):
    """The nav item's backing: a soft glow bar when it's the current page, with the gold pointer."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    if not active:
        return img
    g = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(g)
    d.rounded_rectangle([2, 4, w - 12, h - 4], radius=8, fill=(70, 86, 140, 70), outline=GOLD + (120,))
    img.alpha_composite(g)
    d = ImageDraw.Draw(img)
    d.polygon([(w - 2, h // 2), (w - 12, h // 2 - 8), (w - 12, h // 2 + 8)], fill=GOLD_LIGHT + (255,))
    return img


def big_button(kind, hover=False):
    """START (green), STOP (red) and the disabled grey: an oval gem button in a gold frame."""
    w, h = 214, 70
    s = SS
    cols = {"start": ((150, 236, 120), (36, 140, 52), (12, 70, 24)), "stop": ((255, 150, 120), (186, 52, 36), (90, 16, 12)),
            "off": ((150, 150, 150), (80, 84, 90), (40, 42, 48))}[kind]
    hi, mid, lo = cols
    if hover:
        hi, mid = mix(hi, (255, 255, 255), 0.18), mix(mid, (255, 255, 255), 0.12)
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # glow
    if kind != "off":
        glow = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
        ImageDraw.Draw(glow).rounded_rectangle([6 * s, 6 * s, w * s - 6 * s, h * s - 6 * s], radius=h * s // 2,
                                               fill=mid + (150 if hover else 100,))
        img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(6 * s)))
    r = (h - 12) * s // 2
    d.rounded_rectangle([6 * s, 6 * s, w * s - 6 * s, h * s - 6 * s], radius=r, fill=GOLD_DARK + (255,))
    d.rounded_rectangle([8 * s, 8 * s, w * s - 8 * s, h * s - 8 * s], radius=r - 2 * s, fill=GOLD + (255,))
    d.rounded_rectangle([10 * s, 10 * s, w * s - 10 * s, h * s - 10 * s], radius=r - 4 * s, fill=GOLD_LIGHT + (255,))
    face = vgrad(w * s, h * s, hi, lo)
    m = Image.new("L", (w * s, h * s), 0)
    ImageDraw.Draw(m).rounded_rectangle([13 * s, 13 * s, w * s - 13 * s, h * s - 13 * s], radius=r - 7 * s, fill=255)
    img.paste(face, (0, 0), m)
    # gloss on the top half
    gl = Image.new("L", (w * s, h * s), 0)
    ImageDraw.Draw(gl).rounded_rectangle([20 * s, 15 * s, w * s - 20 * s, h * s // 2], radius=r - 10 * s, fill=70)
    img.paste((255, 255, 255), (0, 0), gl.filter(ImageFilter.GaussianBlur(2 * s)))
    # round "jewel" at the left like the mockup's power light
    cx, cy = 34 * s, h * s // 2
    d.ellipse([cx - 13 * s, cy - 13 * s, cx + 13 * s, cy + 13 * s], fill=GOLD_DARK + (255,))
    jewel = radial((26 * s, 26 * s), mix(hi, (255, 255, 255), 0.4), lo, 0.35, 0.3)
    jm = Image.new("L", (26 * s, 26 * s), 0)
    ImageDraw.Draw(jm).ellipse([0, 0, 26 * s - 1, 26 * s - 1], fill=255)
    img.paste(jewel, (cx - 13 * s, cy - 13 * s), jm)
    return shrink(img, w, h)


def small_button(w, h, hover=False, pressed=False, tone="gold"):
    s = SS
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    top, bot = ((58, 66, 96), (24, 28, 44)) if tone == "gold" else ((36, 96, 52), (14, 50, 24))
    if hover:
        top, bot = mix(top, (255, 255, 255), 0.1), mix(bot, (255, 255, 255), 0.06)
    if pressed:
        top, bot = bot, top
    d.rounded_rectangle([0, 0, w * s - 1, h * s - 1], radius=6 * s, fill=GOLD_DARK + (255,))
    d.rounded_rectangle([s, s, w * s - s - 1, h * s - s - 1], radius=5 * s, fill=(GOLD_LIGHT if hover else GOLD) + (255,))
    face = vgrad(w * s, h * s, top, bot)
    m = Image.new("L", (w * s, h * s), 0)
    ImageDraw.Draw(m).rounded_rectangle([3 * s, 3 * s, w * s - 3 * s - 1, h * s - 3 * s - 1], radius=4 * s, fill=255)
    img.paste(face, (0, 0), m)
    return shrink(img, w, h)


def goal_card(selected=False, hover=False):
    w, h = 86, 92
    s = SS
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    top, bot = ((44, 56, 92), (16, 20, 36)) if selected else ((28, 34, 54), (14, 17, 30))
    if hover and not selected:
        top = mix(top, (255, 255, 255), 0.06)
    if selected:
        glow = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
        ImageDraw.Draw(glow).rounded_rectangle([2 * s, 2 * s, w * s - 2 * s, h * s - 2 * s], radius=10 * s, fill=(240, 200, 100, 90))
        img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(3 * s)))
    d.rounded_rectangle([3 * s, 3 * s, w * s - 3 * s, h * s - 3 * s], radius=9 * s,
                        fill=(GOLD_LIGHT if selected else GOLD_DARK) + (255,))
    face = vgrad(w * s, h * s, top, bot)
    m = Image.new("L", (w * s, h * s), 0)
    ImageDraw.Draw(m).rounded_rectangle([5 * s, 5 * s, w * s - 5 * s, h * s - 5 * s], radius=7 * s, fill=255)
    img.paste(face, (0, 0), m)
    return shrink(img, w, h)


def window_button(kind, hover=False):
    size = 26
    s = SS
    img = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    face_top, face_bot = ((180, 60, 50), (90, 20, 16)) if (kind == "close" and hover) else ((56, 64, 90), (22, 26, 42))
    if hover and kind != "close":
        face_top, face_bot = (80, 90, 126), (34, 40, 62)
    d.rounded_rectangle([0, 0, size * s - 1, size * s - 1], radius=4 * s, fill=GOLD_DARK + (255,))
    d.rounded_rectangle([s, s, size * s - s - 1, size * s - s - 1], radius=4 * s, fill=GOLD + (255,))
    face = vgrad(size * s, size * s, face_top, face_bot)
    m = Image.new("L", (size * s, size * s), 0)
    ImageDraw.Draw(m).rounded_rectangle([3 * s, 3 * s, size * s - 3 * s - 1, size * s - 3 * s - 1], radius=3 * s, fill=255)
    img.paste(face, (0, 0), m)
    c = GOLD_LIGHT + (255,)
    if kind == "close":
        d.line([(8 * s, 8 * s), (18 * s, 18 * s)], fill=c, width=2 * s)
        d.line([(18 * s, 8 * s), (8 * s, 18 * s)], fill=c, width=2 * s)
    else:
        d.line([(8 * s, 17 * s), (18 * s, 17 * s)], fill=c, width=2 * s)
    return shrink(img, size, size)


def check_icon(kind):
    size = 20
    s = SS
    img = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    col = {"on": (70, 190, 90), "off": (90, 96, 110), "warn": (220, 170, 60), "no": (200, 70, 60)}[kind]
    d.rounded_rectangle([s, s, size * s - s, size * s - s], radius=4 * s, fill=mix(col, (0, 0, 0), 0.55) + (255,),
                        outline=col + (255,), width=s)
    c = (235, 255, 230, 255) if kind == "on" else (255, 255, 255, 230)
    if kind == "on":
        d.line([(5 * s, 10 * s), (9 * s, 14 * s), (15 * s, 6 * s)], fill=c, width=2 * s, joint="curve")
    elif kind == "warn":
        d.line([(10 * s, 5 * s), (10 * s, 11 * s)], fill=c, width=2 * s)
        d.ellipse([9 * s, 13 * s, 11 * s, 15 * s], fill=c)
    elif kind == "no":
        d.line([(6 * s, 6 * s), (14 * s, 14 * s)], fill=c, width=2 * s)
        d.line([(14 * s, 6 * s), (6 * s, 14 * s)], fill=c, width=2 * s)
    else:
        d.line([(6 * s, 10 * s), (14 * s, 10 * s)], fill=c, width=2 * s)
    return shrink(img, size, size)


# ------------------------------------------------------------------------------------- items
QUALITY = {0: (157, 157, 157), 1: (255, 255, 255), 2: (30, 255, 0), 3: (0, 112, 221)}


def slot(size=38, quality=None):
    s = SS
    img = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size * s - 1, size * s - 1], radius=4 * s, fill=(8, 10, 16, 255), outline=GOLD_DARK + (255,), width=s)
    if quality is not None and quality >= 2:
        d.rounded_rectangle([s, s, size * s - s - 1, size * s - s - 1], radius=4 * s, outline=QUALITY[quality] + (255,), width=s)
    return shrink(img, size, size)


def item_icon(kind, size=34):
    s = SS * 2
    b = size * s
    rng = random.Random(kind)
    bgc = {"pelt": (70, 46, 28), "meat": (90, 34, 30), "cloth": (64, 64, 76), "junk": (52, 50, 46), "potion": (36, 30, 58),
           "mask": (80, 20, 20), "herb": (26, 58, 30), "ore": (52, 44, 38), "coin": (60, 48, 16)}.get(kind, (40, 40, 40))
    img = radial((b, b), mix(bgc, (255, 255, 255), 0.2), mix(bgc, (0, 0, 0), 0.5), 0.35, 0.3)
    d = ImageDraw.Draw(img)
    if kind == "pelt":
        pts = [(b * 0.2, b * 0.3), (b * 0.4, b * 0.18), (b * 0.6, b * 0.2), (b * 0.82, b * 0.32), (b * 0.74, b * 0.6),
               (b * 0.84, b * 0.82), (b * 0.5, b * 0.74), (b * 0.18, b * 0.84), (b * 0.26, b * 0.56)]
        d.polygon(pts, fill=(168, 112, 62), outline=(70, 40, 18))
        for _ in range(30):
            x, y = rng.uniform(0.3, 0.7) * b, rng.uniform(0.3, 0.7) * b
            d.line([(x, y), (x + 2 * s, y + 3 * s)], fill=(120, 76, 40), width=s)
    elif kind == "meat":
        d.ellipse([b * 0.18, b * 0.26, b * 0.78, b * 0.74], fill=(196, 70, 64), outline=(90, 20, 20), width=s)
        d.ellipse([b * 0.3, b * 0.36, b * 0.6, b * 0.6], fill=(236, 150, 140))
        d.rounded_rectangle([b * 0.66, b * 0.44, b * 0.88, b * 0.54], radius=3 * s, fill=(240, 232, 214))
    elif kind == "cloth":
        for i, c in enumerate([(210, 200, 176), (190, 180, 156), (230, 222, 200)]):
            d.rounded_rectangle([b * (0.18 + i * 0.04), b * (0.26 + i * 0.14), b * (0.82 - i * 0.04), b * (0.42 + i * 0.14)],
                                radius=4 * s, fill=c, outline=(120, 110, 90))
    elif kind == "junk":
        d.polygon([(b * 0.3, b * 0.2), (b * 0.7, b * 0.24), (b * 0.78, b * 0.7), (b * 0.24, b * 0.8)], fill=(130, 126, 116),
                  outline=(60, 58, 52))
        d.line([(b * 0.4, b * 0.4), (b * 0.6, b * 0.6)], fill=(80, 76, 70), width=2 * s)
    elif kind == "potion":
        d.rectangle([b * 0.42, b * 0.14, b * 0.58, b * 0.32], fill=(200, 200, 210))
        d.ellipse([b * 0.22, b * 0.3, b * 0.78, b * 0.86], fill=(220, 40, 50), outline=(120, 20, 30), width=s)
        d.ellipse([b * 0.32, b * 0.4, b * 0.46, b * 0.54], fill=(255, 170, 170))
    elif kind == "mask":
        d.chord([b * 0.14, b * 0.22, b * 0.86, b * 0.84], 180, 360, fill=(190, 30, 30))
        d.rectangle([b * 0.14, b * 0.52, b * 0.86, b * 0.62], fill=(160, 20, 20))
        for x in (0.32, 0.6):
            d.ellipse([b * x, b * 0.38, b * (x + 0.1), b * 0.48], fill=(10, 10, 10))
    elif kind == "herb":
        for a in range(5):
            ang = math.radians(-90 + (a - 2) * 30)
            x, y = b * 0.5 + math.cos(ang) * b * 0.28, b * 0.62 + math.sin(ang) * b * 0.36
            d.line([(b * 0.5, b * 0.8), (x, y)], fill=(60, 120, 50), width=2 * s)
            d.ellipse([x - 6 * s, y - 9 * s, x + 6 * s, y + 9 * s], fill=(120, 200, 90))
        d.ellipse([b * 0.42, b * 0.2, b * 0.58, b * 0.36], fill=(250, 210, 90))
    elif kind == "ore":
        d.polygon([(b * 0.2, b * 0.7), (b * 0.3, b * 0.32), (b * 0.6, b * 0.2), (b * 0.82, b * 0.46), (b * 0.7, b * 0.8)],
                  fill=(110, 92, 80), outline=(50, 40, 34))
        for _ in range(6):
            x, y = rng.uniform(0.32, 0.68) * b, rng.uniform(0.34, 0.66) * b
            d.ellipse([x - 4 * s, y - 3 * s, x + 4 * s, y + 3 * s], fill=(222, 130, 60))
    elif kind == "coin":
        for i in range(3):
            y = b * (0.62 - i * 0.12)
            d.ellipse([b * 0.24, y - b * 0.12, b * 0.76, y + b * 0.12], fill=(240, 196, 70), outline=(130, 90, 20), width=s)
    # bevel
    d.rectangle([0, 0, b - 1, b - 1], outline=(0, 0, 0), width=2 * s)
    hl = Image.new("L", (b, b), 0)
    ImageDraw.Draw(hl).polygon([(0, 0), (b, 0), (0, b)], fill=24)
    img.paste((255, 255, 255), (0, 0), hl)
    return shrink(img, size, size)


ITEM_KINDS = ("pelt", "meat", "cloth", "junk", "potion", "mask", "herb", "ore", "coin")


# ------------------------------------------------------------------------------------- map
def zone_map(w=284, h=196, seed=5):
    """A painted, top-down Elwynn-like forest: meadows, woods, a lake, the road, Goldshire."""
    from ap_link import ROUTE, TOWN  # the demo's path, so the map and the dot agree
    rng = random.Random(seed)
    s = 2
    bw, bh = w * s, h * s
    img = Image.new("RGBA", (bw, bh), (76, 104, 52, 255))
    d = ImageDraw.Draw(img)
    # meadow noise
    for _ in range(260):
        x, y, r = rng.uniform(0, bw), rng.uniform(0, bh), rng.uniform(8, 40) * s
        c = rng.choice([(86, 116, 58), (66, 92, 44), (96, 124, 64), (80, 98, 48)])
        d.ellipse([x - r, y - r, x + r, y + r], fill=c + (255,))
    img = img.filter(ImageFilter.GaussianBlur(6))
    d = ImageDraw.Draw(img)
    # forests
    for _ in range(140):
        x, y = rng.uniform(0, bw), rng.uniform(0, bh)
        if math.hypot(x / bw - TOWN[0], y / bh - TOWN[1]) < 0.12:
            continue
        r = rng.uniform(5, 10) * s
        d.ellipse([x - r, y - r, x + r, y + r], fill=(38, 64, 30, 255))
        d.ellipse([x - r * 0.6, y - r * 0.7, x + r * 0.4, y + r * 0.2], fill=(56, 88, 40, 255))
    # lake
    d.ellipse([bw * 0.72, bh * 0.08, bw * 0.96, bh * 0.3], fill=(56, 96, 120, 255), outline=(150, 140, 100, 255), width=2 * s)
    d.ellipse([bw * 0.76, bh * 0.11, bw * 0.86, bh * 0.17], fill=(110, 160, 180, 255))
    # the river along the bottom
    d.line([(0, bh * 0.92), (bw * 0.3, bh * 0.86), (bw * 0.6, bh * 0.95), (bw, bh * 0.88)], fill=(56, 96, 120, 255), width=10 * s)
    # the road
    road = [(0, bh * 0.54), (bw * 0.3, bh * 0.56), (bw * TOWN[0], bh * TOWN[1]), (bw * 0.7, bh * 0.44), (bw, bh * 0.4)]
    d.line(road, fill=(150, 128, 86, 255), width=6 * s, joint="curve")
    d.line(road, fill=(176, 154, 104, 255), width=3 * s, joint="curve")
    # Goldshire
    tx, ty = TOWN[0] * bw, TOWN[1] * bh
    for dx, dy in ((-14, -8), (6, -12), (12, 6), (-6, 10), (-18, 6)):
        x, y = tx + dx * s, ty + dy * s
        d.rectangle([x - 5 * s, y - 4 * s, x + 5 * s, y + 4 * s], fill=(190, 170, 140, 255), outline=(70, 50, 30, 255))
        d.polygon([(x - 6 * s, y - 4 * s), (x, y - 9 * s), (x + 6 * s, y - 4 * s)], fill=(140, 60, 40, 255))
    img = img.filter(ImageFilter.SMOOTH)
    d = ImageDraw.Draw(img)
    f = font("display-semi", 11 * s)
    d.text((tx - 24 * s, ty + 16 * s), "Goldshire", font=f, fill=(250, 236, 200, 255), stroke_width=2 * s, stroke_fill=(30, 20, 8, 255))
    d.text((8 * s, 6 * s), "Elwynn Forest", font=font("display", 12 * s), fill=(250, 230, 170, 255), stroke_width=2 * s,
           stroke_fill=(30, 20, 8, 255))
    # vignette + parchment edge
    vig = Image.new("L", (bw, bh), 0)
    ImageDraw.Draw(vig).rectangle([0, 0, bw, bh], outline=150, width=14 * s)
    img.paste((20, 14, 6), (0, 0), vig.filter(ImageFilter.GaussianBlur(10 * s)))
    out = shrink(img, w, h)
    d = ImageDraw.Draw(out)
    d.rectangle([0, 0, w - 1, h - 1], outline=GOLD_DARK + (255,), width=2)
    d.rectangle([2, 2, w - 3, h - 3], outline=GOLD + (255,), width=1)
    return out


def map_dot(color=(80, 230, 110), size=18):
    s = SS
    b = size * s
    img = Image.new("RGBA", (b, b), (0, 0, 0, 0))
    g = Image.new("RGBA", (b, b), (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse([0, 0, b, b], fill=color + (110,))
    img.alpha_composite(g.filter(ImageFilter.GaussianBlur(2 * s)))
    d = ImageDraw.Draw(img)
    d.ellipse([b * 0.28, b * 0.28, b * 0.72, b * 0.72], fill=(255, 255, 255, 255))
    d.ellipse([b * 0.34, b * 0.34, b * 0.66, b * 0.66], fill=color + (255,))
    return shrink(img, size, size)


def bar(w, h, fill, frac=1.0):
    """A thin gold-rimmed bar (XP, health) — drawn at runtime for each value."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=h // 2, fill=(8, 10, 18, 255), outline=GOLD_DARK + (255,))
    fw = int((w - 4) * max(0.0, min(1.0, frac)))
    if fw > 2:
        g = vgrad(fw, h - 4, mix(fill, (255, 255, 255), 0.35), mix(fill, (0, 0, 0), 0.35))
        m = Image.new("L", (fw, h - 4), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, fw - 1, h - 5], radius=(h - 4) // 2, fill=255)
        img.paste(g, (2, 2), m)
    return img


def choice_pill(w, h=26, hover=False):
    s = SS
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, w * s - 1, h * s - 1], radius=5 * s, fill=(GOLD if hover else GOLD_DARK) + (255,))
    face = vgrad(w * s, h * s, (40, 48, 74) if hover else (30, 36, 58), (14, 18, 30))
    m = Image.new("L", (w * s, h * s), 0)
    ImageDraw.Draw(m).rounded_rectangle([s, s, w * s - s - 1, h * s - s - 1], radius=4 * s, fill=255)
    img.paste(face, (0, 0), m)
    cx, cy = w * s - 12 * s, h * s // 2
    d.polygon([(cx - 5 * s, cy - 2 * s), (cx + 5 * s, cy - 2 * s), (cx, cy + 4 * s)], fill=GOLD_LIGHT + (255,))
    return shrink(img, w, h)


def toggle(on, hover=False):
    w, h = 44, 22
    s = SS
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, w * s - 1, h * s - 1], radius=h * s // 2, fill=(GOLD if hover else GOLD_DARK) + (255,))
    d.rounded_rectangle([2 * s, 2 * s, w * s - 2 * s - 1, h * s - 2 * s - 1], radius=h * s // 2 - 2 * s,
                        fill=((40, 140, 60) if on else (30, 34, 50)) + (255,))
    x = (w - h // 2 - 1) * s if on else (h // 2) * s
    d.ellipse([x - 8 * s, h * s // 2 - 8 * s, x + 8 * s, h * s // 2 + 8 * s], fill=GOLD_LIGHT + (255,), outline=GOLD_DARK + (255,))
    return shrink(img, w, h)


def coin(kind, size=12):
    """A small gold / silver / copper coin, like the game's money display."""
    base = {"gold": (236, 190, 52), "silver": (196, 202, 214), "copper": (196, 110, 56)}[kind]
    s = SS * 2
    b = size * s
    img = Image.new("RGBA", (b, b), (0, 0, 0, 0))
    face = radial((b, b), mix(base, (255, 255, 255), 0.55), mix(base, (0, 0, 0), 0.35), 0.35, 0.3)
    m = Image.new("L", (b, b), 0)
    ImageDraw.Draw(m).ellipse([s, s, b - s - 1, b - s - 1], fill=255)
    img.paste(face, (0, 0), m)
    d = ImageDraw.Draw(img)
    d.ellipse([s, s, b - s - 1, b - s - 1], outline=mix(base, (0, 0, 0), 0.6) + (255,), width=s)
    d.ellipse([b * 0.3, b * 0.3, b * 0.7, b * 0.7], outline=mix(base, (255, 255, 255), 0.3) + (200,), width=s)
    return shrink(img, size, size)


def app_icon(size=256):
    p = portrait(size - 12)
    return p.resize((size, size), Image.Resampling.LANCZOS)


# ------------------------------------------------------------------------------------- build
def build_all(out=UI, log=None):
    os.makedirs(out, exist_ok=True)
    import ap_kit
    from ap_kit import brighten, glow, piece
    ap_kit.build(lambda name, im: im.save(os.path.join(out, name), optimize=True))
    for name, (base, glyph) in NAV_KIT.items():
        if glyph:
            bar = kit_nav(piece("nav_house"), GLYPHS[glyph])
        elif base == "nav_house":
            bar = piece("nav_house")
        else:
            bar = kit_nav(piece("nav_house"), medallion_from=piece(base))
        bar.save(os.path.join(out, f"knav_{name}.png"))
        brighten(bar, 1.15).save(os.path.join(out, f"knav_{name}_hover.png"))
        glow(bar, radius=5, strength=170)[0].save(os.path.join(out, f"knav_{name}_on.png"))
    for name in ("level", "quest", "gather", "follow", "dungeon"):
        med = kit_medallion(name, 56)
        med.save(os.path.join(out, f"kgoal_{name}.png"))
        glow(med, radius=6, strength=200)[0].save(os.path.join(out, f"kgoal_{name}_on.png"))
        brighten(med, 1.15).save(os.path.join(out, f"kgoal_{name}_hover.png"))
    jobs = {
        "bg_play.png": lambda: sleek_background("play"),
        "bg_wide.png": lambda: sleek_background("wide"),
        "portrait.png": lambda: portrait(84),
        "wordmark.png": wordmark,
        "map_elwynn.png": lambda: zone_map(*MAP_SIZE),
        "dot_herald.png": map_dot,
        "dot_town.png": lambda: map_dot((250, 210, 90), 14),
        "start.png": lambda: big_button("start"), "start_hover.png": lambda: big_button("start", True),
        "stop.png": lambda: big_button("stop"), "stop_hover.png": lambda: big_button("stop", True),
        "off.png": lambda: big_button("off"),
        "win_min.png": lambda: window_button("min"), "win_min_hover.png": lambda: window_button("min", True),
        "win_close.png": lambda: window_button("close"), "win_close_hover.png": lambda: window_button("close", True),
        "goal_card.png": goal_card, "goal_card_hover.png": lambda: goal_card(hover=True),
        "goal_card_on.png": lambda: goal_card(True),
        "nav_on.png": lambda: nav_row(248, 60, True),
        "slot.png": slot, "slot_green.png": lambda: slot(quality=2),
        "toggle_on.png": lambda: toggle(True), "toggle_off.png": lambda: toggle(False),
        "icon.png": lambda: app_icon(256),
        "coin_gold.png": lambda: coin("gold"), "coin_silver.png": lambda: coin("silver"),
        "coin_copper.png": lambda: coin("copper"),
        "coin_gold_l.png": lambda: coin("gold", 16), "coin_silver_l.png": lambda: coin("silver", 16),
        "coin_copper_l.png": lambda: coin("copper", 16),
    }
    for k in ("on", "off", "warn", "no"):
        jobs[f"check_{k}.png"] = lambda k=k: check_icon(k)
    for name in NAV:
        jobs[f"nav_{name}.png"] = lambda name=name: _medallion(46, GLYPHS[name])
        jobs[f"nav_{name}_on.png"] = lambda name=name: _medallion(46, GLYPHS[name], True)
    for name in ("level", "quest", "gather", "follow", "dungeon"):
        jobs[f"goal_{name}.png"] = lambda name=name: _medallion(44, GLYPHS[name], True)
    for kind in ITEM_KINDS:
        jobs[f"item_{kind}.png"] = lambda kind=kind: item_icon(kind)
    for name, make in jobs.items():
        make().save(os.path.join(out, name), optimize=True)
        if log:
            log(name)
    # the Windows icon, for the window and the taskbar
    app_icon(256).save(os.path.join(out, "icon.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    with open(os.path.join(out, "version.json"), "w") as f:
        json.dump({"art": ART_VERSION}, f)
    return sorted(jobs) + ["icon.ico"]


def ensure(out=UI):
    """Build the assets if they're missing or from an older ART_VERSION."""
    try:
        with open(os.path.join(out, "version.json")) as f:
            if json.load(f).get("art") == ART_VERSION:
                return False
    except (OSError, ValueError):
        pass
    build_all(out)
    return True


if __name__ == "__main__":
    import sys
    sys.path.insert(0, HERE)
    names = build_all(log=lambda n: print("  " + n))
    print(f"{len(names)} assets in {UI}")
