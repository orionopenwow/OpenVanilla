"""Pieces cut from the Herald UI kit sheet (assets/kit/herald_kit_sheet.png, Open Vanilla's own art):
the corner flourish, window buttons, nav bars, the big green button, plaques, divider, toggle,
checkboxes and radio gems. ap_art.build_all() calls build() and saves them in assets/ui/.

The sheet is a picture on a white page, so every piece is keyed: the white connected to the page's
edge becomes transparent and the light halo along those edges is faded out. Text printed on the
sheet's buttons ("Overview", "STOP BOT") is painted out row by row with that row's own colour,
so the window can write its own labels in Cinzel.
"""
from __future__ import annotations

import colorsys
import os
from collections import deque
from functools import lru_cache

from PIL import Image, ImageChops, ImageFilter, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
SHEET = os.path.join(HERE, "assets", "kit", "herald_kit_sheet.png")

# exact boxes on the 1026x576 sheet (x0, y0, x1, y1)
BOX = {
    "corner": (0, 0, 104, 104),
    "win_min": (938, 9, 960, 31),
    "win_max": (964, 9, 986, 31),
    "win_close": (990, 9, 1012, 31),
    "nav_house": (51, 298, 259, 352),
    "nav_gears": (51, 358, 259, 412),
    "nav_bug": (287, 357, 500, 412),
    "nav_notes": (287, 415, 500, 470),
    "nav_chart": (287, 474, 500, 531),
    "big_green": (768, 180, 974, 255),
    "plaque_small": (274, 290, 514, 353),
    "plaque_wide": (271, 164, 751, 264),
    "plaque_title": (292, 17, 732, 145),
    "divider": (527, 304, 741, 328),
    "toggle_on": (905, 261, 940, 277),
    "power": (943, 257, 966, 282),
    "check_on": (943, 337, 970, 362),
    "radio_on": (527, 461, 547, 481),
    "radio_off": (527, 487, 547, 506),
    "map_frame": (772, 395, 969, 533),
    "gauge": (527, 378, 590, 443),
}
# where the printed text sits inside a piece (piece coordinates), to be painted out
TEXT = {
    "nav_house": (56, 11, 203, 43), "nav_gears": (56, 11, 203, 43), "nav_bug": (56, 11, 208, 44),
    "nav_notes": (56, 11, 208, 44), "nav_chart": (56, 11, 208, 46),
    "big_green": (24, 12, 182, 63), "plaque_small": (30, 22, 210, 46), "plaque_title": (64, 52, 380, 92),
    "map_frame": (6, 6, 191, 20),
}


@lru_cache(maxsize=1)
def keyed_sheet():
    im = Image.open(SHEET).convert("RGBA")
    w, h = im.size
    px = im.load()

    def white(x, y):
        r, g, b, _ = px[x, y]
        lo, hi = min(r, g, b), max(r, g, b)
        return lo > 200 and hi - lo < 30

    bg = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if white(x, y) and not bg[y * w + x]:
                bg[y * w + x] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if white(x, y) and not bg[y * w + x]:
                bg[y * w + x] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not bg[ny * w + nx] and white(nx, ny):
                bg[ny * w + nx] = 1
                q.append((nx, ny))
    mask = Image.frombytes("L", (w, h), bytes(255 - v * 255 for v in bg))
    # the sheet's grey drop shadows and pale halos (within 5 px of the page) are cut away entirely,
    # then the edge is eased by one pixel, so each piece ends cleanly on the dark window
    near = ImageOps.invert(mask).filter(ImageFilter.MaxFilter(11))
    npx = near.load()
    mpx = mask.load()
    for y in range(h):
        for x in range(w):
            if mpx[x, y] and npx[x, y]:
                r, g, b, _ = px[x, y]
                lo, hi = min(r, g, b), max(r, g, b)
                lum = 0.3 * r + 0.59 * g + 0.11 * b
                if hi - lo < 34 and lum > 62:
                    mpx[x, y] = 0
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))   # drop stray specks
    mask = mask.filter(ImageFilter.GaussianBlur(0.6))
    im.putalpha(mask)
    return im


def piece(name):
    img = keyed_sheet().crop(BOX[name]).copy()
    if name in TEXT:
        img = paint_out(img, TEXT[name])
    if name.startswith("nav_"):
        img = clean_nav(img)
    return img


def paint_out(img, box):
    """Paint printed text out of a button face: inside box, each row's bright (or dark-outlined)
    letter pixels take that row's typical colour."""
    img = img.copy()
    px = img.load()
    x0, y0, x1, y1 = box
    for y in range(y0, y1):
        row = [px[x, y] for x in range(x0, x1)]
        lum = sorted(0.3 * p[0] + 0.59 * p[1] + 0.11 * p[2] for p in row)
        med = lum[len(lum) // 3]
        base = [p for p in row if abs((0.3 * p[0] + 0.59 * p[1] + 0.11 * p[2]) - med) < 14] or row
        n = len(base)
        avg = tuple(sum(p[i] for p in base) // n for i in range(3)) + (255,)
        for x in range(x0, x1):
            px[x, y] = avg
    # soften the seam
    region = img.crop(box).filter(ImageFilter.GaussianBlur(1.2))
    img.paste(region, box[:2])
    return img


def scale(img, factor):
    return img.resize((round(img.width * factor), round(img.height * factor)), Image.Resampling.LANCZOS)


def tint(img, hue_shift=0.0, sat=1.0, val=1.0):
    """Shift hue / scale saturation and value of every opaque pixel (green button -> red, grey)."""
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            if not a:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if s > 0.25 and 0.18 < h < 0.5:          # only the green face, not the gold frame
                h = (h + hue_shift) % 1.0
                s = min(1.0, s * sat)
                v = min(1.0, v * val)
                r, g, b = (int(c * 255) for c in colorsys.hsv_to_rgb(h, s, v))
            px[x, y] = (r, g, b, a)
    return out


def brighten(img, amount=1.18):
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            px[x, y] = (min(255, int(r * amount)), min(255, int(g * amount)), min(255, int(b * amount)), a)
    return out


def glow(img, color=(240, 200, 110), radius=6, strength=150):
    """img with a soft coloured glow behind it (active nav item, hover)."""
    pad = radius * 2
    out = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    a = img.split()[3]
    halo = Image.new("RGBA", out.size, (0, 0, 0, 0))
    m = Image.new("L", out.size, 0)
    m.paste(a, (pad, pad))
    m = m.filter(ImageFilter.GaussianBlur(radius)).point(lambda v: min(255, int(v * strength / 255 * 1.6)))
    halo.paste(color + (255,), (0, 0), m)
    out.alpha_composite(halo)
    out.alpha_composite(img, (pad, pad))
    return out, pad


def clean_nav(img):
    """Trim a nav bar to its true shape (the round medallion plus the bar) so none of the sheet's
    ragged shadow shows: the extents are measured from the piece itself."""
    from PIL import ImageDraw
    w, h = img.size
    a = img.split()[3].load()

    def run(points):
        hits = [i for i, (x, y) in enumerate(points) if a[x, y] > 200]
        return (hits[0], hits[-1]) if hits else (0, len(points) - 1)
    bx = int(w * 0.7)
    top, bottom = run([(bx, y) for y in range(h)])
    mid = (top + bottom) // 2
    _, right = run([(x, mid) for x in range(w)])
    cx0 = h // 2
    ct, cb = run([(cx0, y) for y in range(h)])
    r = (cb - ct) / 2
    cy = (ct + cb) / 2
    left, _ = run([(x, int(cy)) for x in range(w)])
    cx = left + r
    S = 4
    m = Image.new("L", (w * S, h * S), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([(cx - r) * S, (cy - r) * S, (cx + r + 1) * S, (cy + r + 1) * S], fill=255)
    d.rounded_rectangle([cx * S, (top + 2) * S, (right + 1) * S, bottom * S], radius=3 * S, fill=255)   # without the black outline rows
    m = m.resize((w, h), Image.Resampling.LANCZOS)
    out = img.copy()
    out.putalpha(ImageChops.multiply(img.split()[3], m))
    return out


def blank_medallion(nav):
    """The round medallion on the left of a nav bar, with its icon painted out (for our own glyphs)."""
    from PIL import ImageDraw
    m = nav.crop((0, 0, nav.height, nav.height)).copy()
    d = ImageDraw.Draw(m)
    c = m.width / 2
    r = m.width * 0.30
    inner = m.getpixel((int(c), int(c - r * 0.95)))
    d.ellipse([c - r, c - r, c + r, c + r], fill=(26, 28, 34, 255))
    return m


def unchecked(check):
    """The checkbox with its tick painted out."""
    from PIL import ImageDraw
    out = check.copy()
    d = ImageDraw.Draw(out)
    w, h = out.size
    d.rectangle([5, 5, w - 6, h - 6], fill=(30, 26, 22, 255))
    return out


def toggle_off(on):
    out = ImageOps.mirror(on)
    return tint(out, 0.0, 0.15, 0.7)


def build(save):
    """Every kit asset, handed to save(name, image)."""
    nav = {k: piece(k) for k in ("nav_house", "nav_gears", "nav_bug", "nav_notes", "nav_chart")}
    for k, img in nav.items():
        save(f"kit_{k}.png", img)
        g, _ = glow(img, radius=5, strength=170)
        save(f"kit_{k}_on.png", g)
        save(f"kit_{k}_hover.png", brighten(img, 1.15))
    save("kit_medallion_blank.png", blank_medallion(nav["nav_house"]))
    green = piece("big_green")
    save("kit_start.png", green)
    save("kit_start_hover.png", brighten(green, 1.12))
    red = tint(green, -0.33, 1.05, 0.92)
    save("kit_stop.png", red)
    save("kit_stop_hover.png", brighten(red, 1.12))
    save("kit_off.png", tint(green, 0.0, 0.08, 0.6))
    for k in ("win_min", "win_close"):
        img = scale(piece(k), 1.2)
        save(f"kit_{k}.png", img)
        save(f"kit_{k}_hover.png", brighten(img, 1.3))
    corner = piece("corner")
    from PIL import ImageDraw
    ImageDraw.Draw(corner).rectangle([58, 86, 104, 104], fill=(0, 0, 0, 0))   # bits of the next ornament
    ImageDraw.Draw(corner).rectangle([86, 58, 104, 86], fill=(0, 0, 0, 0))
    a = corner.split()[3].load()
    for y in range(corner.height):           # the thick band fades into the window's thin gold edge
        for x in range(corner.width):
            f = min(1.0, max(0.0, (104 - x) / 26) if x > 78 else 1.0) * min(1.0, max(0.0, (104 - y) / 26) if y > 78 else 1.0)
            a[x, y] = int(a[x, y] * f)
    save("kit_corner_tl.png", corner)
    save("kit_corner_tr.png", ImageOps.mirror(corner))
    save("kit_corner_bl.png", ImageOps.flip(corner))
    save("kit_corner_br.png", ImageOps.flip(ImageOps.mirror(corner)))
    save("kit_plaque.png", piece("plaque_small"))
    save("kit_divider.png", piece("divider"))
    on = piece("toggle_on")
    save("kit_toggle_on.png", scale(on, 1.25))
    save("kit_toggle_off.png", scale(toggle_off(on), 1.25))
    chk = piece("check_on")
    save("kit_check_on.png", scale(chk, 0.8))
    save("kit_check_off.png", scale(unchecked(chk), 0.8))
    save("kit_radio_on.png", piece("radio_on"))
    save("kit_radio_off.png", piece("radio_off"))
    save("kit_power.png", piece("power"))
    save("kit_gauge.png", piece("gauge"))
