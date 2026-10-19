#!/usr/bin/env python3
"""Art for streamers & creators: the website pages and the in-game LIVE badge.

    python3 tools/gen_streams_art.py            writes everything below
    python3 tools/gen_streams_art.py --sheet X  also a contact sheet of the web pieces at X

Website (www/assets/streams/), procedural PIL art in the site's night-sky / gold style:
  banner_streamers.webp   1600x420  a scrying eye of gold rings with a red live ember, sparks
  banner_creators.webp    1600x420  a quill over an unrolled film strip, gold filigree arcs
  strip_live.webp          960x120  the "Live now" strip's backdrop (dark, red ember at the left)
  platform_twitch.png, platform_youtube.png, platform_tiktok.png, platform_kick.png
                           96x96 round seals in each platform's colour with a simple generic glyph
                           (speech tab, play triangle, note, K): ours, not the platforms' logos
  crown_1.png crown_2.png crown_3.png   96x80 leaderboard crowns (gold, silver, bronze)
  badge_partner.png badge_staff.png badge_founder.png badge_linked.png   64x64 creator seals
  live_dot.png              32x32 the glowing red dot
  og_streams.jpg           1200x630 link preview

In game (tools/artkit.save: WenillaCore/Media/*.tga + Interface/ClassicPlus/*.blp):
  Persona_Live          32x32  round badge for the target frame: red face, white broadcast waves
  Persona_LiveBadge     64x32  the "LIVE" plate on a profile page
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import artkit  # noqa: E402

OUT = os.path.join(ROOT, "www", "assets", "streams")
S = 2
GOLD = (232, 188, 84)
GOLD_HI = (255, 230, 150)
GOLD_DK = (150, 108, 40)
RED = (236, 52, 48)
RED_HI = (255, 140, 120)
INK = (9, 8, 16)
FONTS = [os.path.join(ROOT, "realm", "www", "Cinzel-SemiBold.ttf"), "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"]
SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
PLATFORMS = {  # colour, glyph
    "twitch": ((145, 70, 255), "tab"),
    "youtube": ((235, 40, 40), "play"),
    "tiktok": ((30, 30, 36), "note"),
    "kick": ((83, 252, 24), "k"),
}


def font(px, sans=False):
    for f in ([SANS] if sans else FONTS):
        try:
            return ImageFont.truetype(f, px)
        except OSError:
            continue
    return ImageFont.load_default()


def glow(size, xy, r, color, alpha=255, blur=None):
    layer = Image.new("RGBA", size, color + (0,))
    m = Image.new("L", size, 0)
    x, y = xy
    ImageDraw.Draw(m).ellipse((x - r, y - r, x + r, y + r), fill=alpha)
    layer.putalpha(m.filter(ImageFilter.GaussianBlur(blur or r * 0.6)))
    return layer


def sparkle(d, x, y, r, col=(255, 255, 255, 255), waist=0.22):
    w = r * waist
    d.polygon([(x, y - r), (x + w, y - w), (x + r, y), (x + w, y + w), (x, y + r), (x - w, y + w),
               (x - r, y), (x - w, y - w)], fill=col)


def sky(w, h, seed, nebula, stars=500):
    yy = np.linspace(0, 1, h)[:, None]
    xx = np.linspace(0, 1, w)[None, :]
    top, low = np.array([6, 6, 16], np.float32), np.array([30, 18, 44], np.float32)
    base = top + (low - top) * (yy ** 1.4)[..., None]
    vign = 1 - 0.45 * np.clip(np.hypot(xx - 0.5, (yy - 0.5) * 1.3) * 1.5, 0, 1)
    img = Image.fromarray((base * vign[..., None]).clip(0, 255).astype(np.uint8), "RGB").convert("RGBA")
    for x, y, r, col, a in nebula:
        img.alpha_composite(glow((w, h), (x * w, y * h), r * w, col, a))
    rnd = random.Random(seed)
    st = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(st)
    for _ in range(stars):
        x, y = rnd.randrange(w), rnd.randrange(h)
        b = rnd.choice([50, 90, 130, 180, 240])
        r = rnd.choice([1, 1, 1, 2]) * S * 0.6
        d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 246, 225, b))
    img.alpha_composite(st)
    return img


def ring(d, cx, cy, r, width, col):
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=col, width=int(width))


def ticks(d, cx, cy, r, n, ln, col, width):
    for i in range(n):
        a = 2 * math.pi * i / n
        x0, y0 = cx + math.cos(a) * r, cy + math.sin(a) * r
        x1, y1 = cx + math.cos(a) * (r + ln), cy + math.sin(a) * (r + ln)
        d.line((x0, y0, x1, y1), fill=col, width=int(width))


def finish(img, size):
    return img.resize(size, Image.LANCZOS)


# -- banners ---------------------------------------------------------------------------------------

def banner_streamers():
    W, H = 1600 * S, 420 * S
    img = sky(W, H, 11, [(0.5, 0.5, 0.32, (120, 30, 40), 120), (0.2, 0.3, 0.25, (70, 40, 140), 90),
                         (0.82, 0.62, 0.28, (40, 60, 150), 80)])
    cx, cy = W * 0.5, H * 0.5
    img.alpha_composite(glow((W, H), (cx, cy), 230 * S, (255, 120, 60), 120))
    lay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    # the scrying eye: almond outline, rings, iris, red ember
    for k, a in ((1.0, 255), (1.08, 90)):
        ew, eh = 300 * S * k, 120 * S * k
        pts = []
        for i in range(120):
            t = 2 * math.pi * i / 120
            pts.append((cx + math.cos(t) * ew, cy + math.sin(t) * eh * abs(math.sin(t)) ** 0.25 * (1 if math.sin(t) >= 0 else 1)))
        d.line(pts + [pts[0]], fill=GOLD + (a,), width=int(3 * S))
    for r, wdt, a in ((98, 4, 255), (112, 2, 180), (150, 2, 120), (190, 1.5, 80)):
        ring(d, cx, cy, r * S, wdt * S, GOLD_HI + (a,) if r < 100 else GOLD + (a,))
    ticks(d, cx, cy, 152 * S, 48, 8 * S, GOLD + (150,), 2 * S)
    ticks(d, cx, cy, 192 * S, 24, 14 * S, GOLD_DK + (140,), 2 * S)
    img.alpha_composite(lay.filter(ImageFilter.GaussianBlur(0.6 * S)))
    iris = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    di = ImageDraw.Draw(iris)
    di.ellipse((cx - 88 * S, cy - 88 * S, cx + 88 * S, cy + 88 * S), fill=(24, 12, 20, 255))
    for i in range(36):
        a = 2 * math.pi * i / 36
        di.line((cx + math.cos(a) * 30 * S, cy + math.sin(a) * 30 * S, cx + math.cos(a) * 86 * S, cy + math.sin(a) * 86 * S),
                fill=(120, 40, 36, 160), width=int(2 * S))
    img.alpha_composite(iris)
    img.alpha_composite(glow((W, H), (cx, cy), 60 * S, RED, 255, 26 * S))
    core = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(core).ellipse((cx - 30 * S, cy - 30 * S, cx + 30 * S, cy + 30 * S), fill=RED + (255,))
    img.alpha_composite(core)
    img.alpha_composite(glow((W, H), (cx - 9 * S, cy - 10 * S), 10 * S, RED_HI, 255, 6 * S))
    # broadcast arcs either side
    arcs = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    da = ImageDraw.Draw(arcs)
    for i, r in enumerate((250, 300, 350)):
        a = 200 - i * 55
        da.arc((cx - r * S, cy - r * S, cx + r * S, cy + r * S), 160, 200, fill=RED_HI + (a,), width=int(4 * S))
        da.arc((cx - r * S, cy - r * S, cx + r * S, cy + r * S), -20, 20, fill=RED_HI + (a,), width=int(4 * S))
    img.alpha_composite(arcs.filter(ImageFilter.GaussianBlur(1.2 * S)))
    sp = ImageDraw.Draw(img)
    rnd = random.Random(5)
    for _ in range(70):
        a = rnd.uniform(0, 2 * math.pi)
        r = rnd.uniform(220, 700) * S
        x, y = cx + math.cos(a) * r, cy + math.sin(a) * r * 0.45
        sparkle(sp, x, y, rnd.uniform(2, 7) * S, (255, 220, 170, rnd.randrange(80, 220)))
    return finish(img, (1600, 420))


def banner_creators():
    W, H = 1600 * S, 420 * S
    img = sky(W, H, 23, [(0.35, 0.55, 0.3, (40, 70, 150), 100), (0.75, 0.4, 0.3, (110, 40, 120), 100)])
    # film strip across, gently curved
    strip = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(strip)
    pts_top, pts_bot = [], []
    for i in range(0, 101):
        x = W * (0.08 + 0.84 * i / 100)
        y = H * 0.62 + math.sin(i / 100 * math.pi * 1.2 - 0.6) * 46 * S
        pts_top.append((x, y - 58 * S))
        pts_bot.append((x, y + 58 * S))
    d.polygon(pts_top + pts_bot[::-1], fill=(14, 14, 20, 235))
    d.line(pts_top, fill=GOLD_DK + (255,), width=int(3 * S))
    d.line(pts_bot, fill=GOLD_DK + (255,), width=int(3 * S))
    for i in range(2, 100, 4):
        (x0, y0), (x1, y1) = pts_top[i], pts_bot[i]
        for yy in (y0 + 10 * S, y1 - 22 * S):
            d.rounded_rectangle((x0 - 6 * S, yy, x0 + 6 * S, yy + 12 * S), radius=3 * S, fill=(70, 62, 50, 255))
    rnd = random.Random(9)
    for i in range(6, 96, 12):
        (x0, y0), (x1, y1) = pts_top[i], pts_bot[i + 8]
        col = rnd.choice([(60, 90, 160), (150, 70, 60), (70, 120, 80), (120, 80, 150)])
        frame = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        fd = ImageDraw.Draw(frame)
        fd.rectangle((x0 + 4 * S, y0 + 28 * S, x1 - 4 * S, y1 - 28 * S), fill=col + (200,), outline=GOLD + (160,), width=int(2 * S))
        fx, fy = (x0 + x1) / 2, (y0 + y1) / 2
        fd.polygon([(fx - 10 * S, fy - 14 * S), (fx - 10 * S, fy + 14 * S), (fx + 14 * S, fy)], fill=(255, 245, 220, 200))
        strip.alpha_composite(frame)
    img.alpha_composite(strip)
    # the quill
    q = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    dq = ImageDraw.Draw(q)
    bx, by, tx, ty = W * 0.62, H * 0.92, W * 0.43, H * 0.06
    dx, dy = tx - bx, ty - by
    ln = math.hypot(dx, dy)
    nx, ny = -dy / ln, dx / ln
    vane = []
    for i in range(41):
        t = i / 40
        wdt = math.sin(t * math.pi) ** 0.8 * 60 * S * (0.35 + 0.65 * t)
        vane.append((bx + dx * t + nx * wdt, by + dy * t + ny * wdt))
    for i in range(40, -1, -1):
        t = i / 40
        wdt = math.sin(t * math.pi) ** 0.8 * 34 * S * (0.35 + 0.65 * t)
        vane.append((bx + dx * t - nx * wdt, by + dy * t - ny * wdt))
    dq.polygon(vane, fill=(236, 226, 205, 245))
    for i in range(4, 40, 2):
        t = i / 40
        x, y = bx + dx * t, by + dy * t
        wdt = math.sin(t * math.pi) ** 0.8 * 60 * S * (0.35 + 0.65 * t)
        dq.line((x, y, x + nx * wdt + dx * 0.03, y + ny * wdt + dy * 0.03), fill=(180, 165, 140, 200), width=int(1.5 * S))
    dq.line((bx, by, tx, ty), fill=GOLD + (255,), width=int(4 * S))
    dq.line((bx, by, bx - dx * 0.08, by - dy * 0.08), fill=(40, 30, 20, 255), width=int(5 * S))
    img.alpha_composite(artkit.drop_shadow(q, (0, 6), 6, 170) if False else q)
    img.alpha_composite(glow((W, H), (bx - dx * 0.08, by - dy * 0.08), 26 * S, GOLD_HI, 200, 14 * S))
    # filigree arcs
    arc = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    da = ImageDraw.Draw(arc)
    for r, a in ((520, 120), (560, 70)):
        da.arc((W / 2 - r * S, H * 1.25 - r * S, W / 2 + r * S, H * 1.25 + r * S), 200, 340, fill=GOLD + (a,), width=int(2 * S))
    img.alpha_composite(arc)
    sp = ImageDraw.Draw(img)
    for _ in range(50):
        sparkle(sp, rnd.uniform(0, W), rnd.uniform(0, H * 0.5), rnd.uniform(2, 6) * S, (255, 230, 180, rnd.randrange(60, 200)))
    return finish(img, (1600, 420))


def strip_live():
    W, H = 960 * S, 120 * S
    img = sky(W, H, 3, [(0.06, 0.5, 0.16, (160, 30, 30), 150), (0.6, 0.5, 0.4, (40, 30, 80), 70)], stars=160)
    d = ImageDraw.Draw(img)
    d.line((0, 1 * S, W, 1 * S), fill=GOLD_DK + (200,), width=int(2 * S))
    d.line((0, H - 2 * S, W, H - 2 * S), fill=GOLD_DK + (200,), width=int(2 * S))
    return finish(img, (960, 120)).convert("RGB")


# -- seals -----------------------------------------------------------------------------------------

def seal(color, glyph, size=96):
    Z = size * 4
    img = Image.new("RGBA", (Z, Z), (0, 0, 0, 0))
    c = Z / 2
    sh = glow((Z, Z), (c, c + Z * 0.03), Z * 0.44, (0, 0, 0), 200, Z * 0.04)
    img.alpha_composite(sh)
    d = ImageDraw.Draw(img)
    r = Z * 0.44
    d.ellipse((c - r, c - r, c + r, c + r), fill=GOLD_DK + (255,))
    r2 = Z * 0.40
    face = artkit.vgrad((Z, Z), [(0, tuple(min(255, int(v * 1.25 + 20)) for v in color)), (1, tuple(int(v * 0.6) for v in color))])
    m = Image.new("L", (Z, Z), 0)
    ImageDraw.Draw(m).ellipse((c - r2, c - r2, c + r2, c + r2), fill=255)
    artkit.paste_masked(img, face, m)
    d = ImageDraw.Draw(img)
    d.ellipse((c - r, c - r, c + r, c + r), outline=GOLD_HI + (255,), width=Z // 40)
    w = (255, 255, 255, 255)
    g = Z * 0.17
    if glyph == "tab":        # a speech tab with two bars
        d.polygon([(c - g * 1.2, c - g * 1.1), (c + g * 1.2, c - g * 1.1), (c + g * 1.2, c + g * 0.5), (c + g * 0.4, c + g * 0.5),
                   (c - g * 0.2, c + g * 1.1), (c - g * 0.2, c + g * 0.5), (c - g * 1.2, c + g * 0.5)], fill=w)
        for x in (-0.35, 0.45):
            d.rectangle((c + g * x - g * 0.12, c - g * 0.6, c + g * x + g * 0.12, c + g * 0.05), fill=color + (255,))
    elif glyph == "play":
        d.rounded_rectangle((c - g * 1.4, c - g * 0.95, c + g * 1.4, c + g * 0.95), radius=g * 0.4, fill=w)
        d.polygon([(c - g * 0.4, c - g * 0.55), (c - g * 0.4, c + g * 0.55), (c + g * 0.6, c)], fill=color + (255,))
    elif glyph == "note":
        d.ellipse((c - g * 0.9, c + g * 0.2, c - g * 0.1, c + g * 1.0), fill=w)
        d.rectangle((c - g * 0.25, c - g * 1.2, c - g * 0.05, c + g * 0.6), fill=w)
        d.polygon([(c - g * 0.25, c - g * 1.2), (c + g * 0.8, c - g * 0.7), (c + g * 0.8, c - g * 0.35), (c - g * 0.05, c - g * 0.75)], fill=w)
        img.alpha_composite(glow((Z, Z), (c + g * 0.2, c), g * 1.2, (40, 220, 230), 70, g * 0.6))
    elif glyph == "k":
        f = font(int(g * 2.6), sans=True)
        d.text((c, c), "K", font=f, fill=(10, 10, 10, 255), anchor="mm")
    img.alpha_composite(artkit.sheen((Z, Z), m, 0.45, 70))
    return img.resize((size, size), Image.LANCZOS)


def crown(metal, size=(96, 80)):
    Wd, Hd = size[0] * 4, size[1] * 4
    img = Image.new("RGBA", (Wd, Hd), (0, 0, 0, 0))
    hi, mid, lo = metal
    m = Image.new("L", (Wd, Hd), 0)
    dm = ImageDraw.Draw(m)
    base_y, top_y = Hd * 0.82, Hd * 0.18
    pts = [(Wd * 0.12, base_y), (Wd * 0.12, Hd * 0.42), (Wd * 0.30, Hd * 0.58), (Wd * 0.5, top_y + Hd * 0.06),
           (Wd * 0.70, Hd * 0.58), (Wd * 0.88, Hd * 0.42), (Wd * 0.88, base_y)]
    dm.polygon(pts, fill=255)
    dm.rounded_rectangle((Wd * 0.10, base_y - Hd * 0.06, Wd * 0.90, base_y + Hd * 0.08), radius=Hd * 0.03, fill=255)
    img.alpha_composite(glow((Wd, Hd), (Wd / 2, Hd * 0.55), Wd * 0.4, mid, 90, Wd * 0.1))
    artkit.paste_masked(img, artkit.vgrad((Wd, Hd), [(0, hi), (0.55, mid), (1, lo)]), m)
    d = ImageDraw.Draw(img)
    d.polygon(pts, outline=lo + (255,), width=6)
    for x, y in ((0.12, 0.42), (0.5, 0.24), (0.88, 0.42)):
        r = Wd * 0.055
        d.ellipse((Wd * x - r, Hd * y - r - 6, Wd * x + r, Hd * y + r - 6), fill=hi + (255,), outline=lo + (255,), width=4)
    for x, col in ((0.3, (220, 40, 50)), (0.5, (60, 120, 230)), (0.7, (40, 170, 90))):
        r = Wd * 0.045
        d.ellipse((Wd * x - r, base_y - r * 0.2, Wd * x + r, base_y + r * 1.8 - r * 0.2), fill=col + (255,), outline=lo + (255,), width=3)
    img.alpha_composite(artkit.sheen((Wd, Hd), m, 0.5, 80))
    return img.resize(size, Image.LANCZOS)


def creator_badge(kind):
    colors = {"partner": (150, 90, 230), "staff": (40, 150, 220), "founder": (220, 170, 60), "linked": (70, 170, 110)}
    glyph = {"partner": "star", "staff": "shield", "founder": "crown", "linked": "link"}[kind]
    Z = 256
    img = Image.new("RGBA", (Z, Z), (0, 0, 0, 0))
    c = Z / 2
    col = colors[kind]
    d = ImageDraw.Draw(img)
    pts = [(c + math.cos(math.pi / 6 + i * math.pi / 3) * Z * 0.46, c + math.sin(math.pi / 6 + i * math.pi / 3) * Z * 0.46) for i in range(6)]
    d.polygon(pts, fill=GOLD_DK + (255,))
    inner = [(c + math.cos(math.pi / 6 + i * math.pi / 3) * Z * 0.40, c + math.sin(math.pi / 6 + i * math.pi / 3) * Z * 0.40) for i in range(6)]
    m = Image.new("L", (Z, Z), 0)
    ImageDraw.Draw(m).polygon(inner, fill=255)
    artkit.paste_masked(img, artkit.vgrad((Z, Z), [(0, tuple(min(255, v + 60) for v in col)), (1, tuple(v // 2 for v in col))]), m)
    d = ImageDraw.Draw(img)
    d.polygon(pts, outline=GOLD_HI + (255,), width=6)
    w = (255, 250, 235, 255)
    g = Z * 0.16
    if glyph == "star":
        sp = [(c + math.cos(-math.pi / 2 + i * math.pi / 5) * (g * 1.3 if i % 2 == 0 else g * 0.55),
               c + math.sin(-math.pi / 2 + i * math.pi / 5) * (g * 1.3 if i % 2 == 0 else g * 0.55)) for i in range(10)]
        d.polygon(sp, fill=w)
    elif glyph == "shield":
        d.polygon([(c - g, c - g), (c + g, c - g), (c + g, c + g * 0.2), (c, c + g * 1.3), (c - g, c + g * 0.2)], fill=w)
    elif glyph == "crown":
        d.polygon([(c - g * 1.2, c + g * 0.8), (c - g * 1.2, c - g * 0.6), (c - g * 0.5, c), (c, c - g * 1.1), (c + g * 0.5, c),
                   (c + g * 1.2, c - g * 0.6), (c + g * 1.2, c + g * 0.8)], fill=w)
    else:
        for dx in (-0.45, 0.45):
            d.rounded_rectangle((c + g * dx - g * 0.75, c - g * 0.4, c + g * dx + g * 0.75, c + g * 0.4), radius=g * 0.4, outline=w, width=int(g * 0.28))
    img.alpha_composite(artkit.sheen((Z, Z), m, 0.45, 60))
    return img.resize((64, 64), Image.LANCZOS)


def live_dot():
    Z = 128
    img = Image.new("RGBA", (Z, Z), (0, 0, 0, 0))
    img.alpha_composite(glow((Z, Z), (Z / 2, Z / 2), Z * 0.42, RED, 200, Z * 0.12))
    d = ImageDraw.Draw(img)
    r = Z * 0.22
    d.ellipse((Z / 2 - r, Z / 2 - r, Z / 2 + r, Z / 2 + r), fill=RED + (255,))
    img.alpha_composite(glow((Z, Z), (Z / 2 - r * 0.3, Z / 2 - r * 0.35), r * 0.35, RED_HI, 255, r * 0.25))
    return img.resize((32, 32), Image.LANCZOS)


def og(banner):
    img = Image.new("RGB", (1200, 630), INK)
    b = banner.resize((1200, 315), Image.LANCZOS).convert("RGB")
    img.paste(b, (0, 120))
    d = ImageDraw.Draw(img)
    d.text((600, 70), "Open Vanilla Streamers & Creators", font=font(54), fill=GOLD_HI, anchor="mm")
    d.text((600, 520), "Who's live now, the newest videos and the monthly leaderboard", font=font(28), fill=(200, 200, 210), anchor="mm")
    return img


# -- in game ---------------------------------------------------------------------------------------

def persona_live():
    img, face = _badge_base()
    W, H = img.size
    c = W / 2
    d = ImageDraw.Draw(img)
    r = W * 0.09
    d.ellipse((c - r, c - r, c + r, c + r), fill=(255, 255, 255, 255))
    for k in (0.2, 0.3):
        R = W * k
        d.arc((c - R, c - R, c + R, c + R), 140, 220, fill=(255, 255, 255, 255), width=int(W * 0.045))
        d.arc((c - R, c - R, c + R, c + R), -40, 40, fill=(255, 255, 255, 255), width=int(W * 0.045))
    img.alpha_composite(artkit.sheen((W, H), face, 0.5, 80))
    return img


def _badge_base():
    img = artkit.canvas(32, 32)
    W, H = img.size
    o = 1.5 * artkit.SS
    outer = Image.new("L", (W, H), 0)
    ImageDraw.Draw(outer).ellipse((o, o, W - o, H - o), fill=255)
    artkit.paste_masked(img, artkit.fill((W, H), (5, 6, 8)), outer)
    rim = Image.new("L", (W, H), 0)
    ImageDraw.Draw(rim).ellipse((o + artkit.SS, o + artkit.SS, W - o - artkit.SS, H - o - artkit.SS), fill=255)
    artkit.paste_masked(img, artkit.gold_band((W, H)), rim)
    f = o + 3 * artkit.SS
    face = Image.new("L", (W, H), 0)
    ImageDraw.Draw(face).ellipse((f, f, W - f, H - f), fill=255)
    artkit.paste_masked(img, artkit.vgrad((W, H), [(0, (255, 90, 80)), (1, (150, 18, 20))]), face)
    img.alpha_composite(artkit.inner_shadow((W, H), face, depth=2, strength=170))
    return img, face


def persona_live_plate():
    img = artkit.canvas(64, 32)
    W, H = img.size
    SS = artkit.SS
    outer = artkit.rr_mask((W, H), (2 * SS, 6 * SS, W - 2 * SS, H - 6 * SS), 5 * SS)
    artkit.paste_masked(img, artkit.fill((W, H), (8, 6, 6)), outer)
    inner = artkit.rr_mask((W, H), (3 * SS, 7 * SS, W - 3 * SS, H - 7 * SS), 4 * SS)
    artkit.paste_masked(img, artkit.vgrad((W, H), [(0, (240, 70, 60)), (1, (140, 16, 18))]), inner)
    d = ImageDraw.Draw(img)
    r = 3 * SS
    d.ellipse((10 * SS - r, H / 2 - r, 10 * SS + r, H / 2 + r), fill=(255, 255, 255, 255))
    d.text((36 * SS, H / 2 + 0.5 * SS), "LIVE", font=font(12 * SS, sans=True), fill=(255, 255, 255, 255), anchor="mm")
    img.alpha_composite(artkit.sheen((W, H), inner, 0.5, 70))
    return img


def main(argv):
    os.makedirs(OUT, exist_ok=True)
    pieces = []
    bs = banner_streamers()
    bs.convert("RGB").save(os.path.join(OUT, "banner_streamers.webp"), quality=86, method=6)
    bc = banner_creators()
    bc.convert("RGB").save(os.path.join(OUT, "banner_creators.webp"), quality=86, method=6)
    strip_live().save(os.path.join(OUT, "strip_live.webp"), quality=84, method=6)
    og(bs).save(os.path.join(OUT, "og_streams.jpg"), quality=86)
    for name, (col, glyph) in PLATFORMS.items():
        im = seal(col, glyph)
        im.save(os.path.join(OUT, f"platform_{name}.png"), optimize=True)
        pieces.append((name, im))
    for i, metal in enumerate((((255, 236, 150), (226, 172, 60), (120, 80, 20)),
                               ((240, 244, 250), (170, 178, 192), (80, 86, 100)),
                               ((246, 190, 140), (184, 112, 60), (96, 52, 22))), 1):
        im = crown(metal)
        im.save(os.path.join(OUT, f"crown_{i}.png"), optimize=True)
        pieces.append((f"crown{i}", im))
    for kind in ("partner", "staff", "founder", "linked"):
        im = creator_badge(kind)
        im.save(os.path.join(OUT, f"badge_{kind}.png"), optimize=True)
        pieces.append((kind, im))
    ld = live_dot()
    ld.save(os.path.join(OUT, "live_dot.png"), optimize=True)
    pieces.append(("dot", ld))
    pieces.append(("Persona_Live", artkit.save("Persona_Live", persona_live(), (32, 32))))
    pieces.append(("Persona_LiveBadge", artkit.save("Persona_LiveBadge", persona_live_plate(), (64, 32))))
    if "--sheet" in argv:
        artkit.sheet(pieces, argv[argv.index("--sheet") + 1])
    print("streams art ->", OUT, "and Persona_Live / Persona_LiveBadge (TGA + BLP)")


if __name__ == "__main__":
    main(sys.argv[1:])
