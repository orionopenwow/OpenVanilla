"""Procedural art for the Open Vanilla launcher.

Icons, glass panels, the PLAY plate and its glow, the progress bar, particles and buttons are
all drawn with Pillow (supersampled, then downsampled), so the launcher ships no third-party
icon set and no game's branding. Each function returns a PIL RGBA image; the launcher wraps it
in a Tk PhotoImage. The display face is Cinzel (SIL OFL 1.1, bundled in assets/launcher/fonts).
"""
import math
import os
from functools import lru_cache

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SS = 4  # supersampling factor for icons
FONT_DIRS = []  # the launcher prepends assets/launcher/fonts


def _canvas(size):
    return Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))


def _finish(img, size):
    return img.resize((size, size), Image.Resampling.LANCZOS)


def _hex(color, alpha=255):
    color = color.lstrip("#")
    return tuple(int(color[i:i + 2], 16) for i in (0, 2, 4)) + (alpha,)


def _mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


@lru_cache(maxsize=64)
def font(kind="display", size=16):
    """kind: display (Cinzel Bold), display-semi, display-regular, ui, ui-bold, rounded (Arial Rounded MT
    Bold when installed, else the bundled Nunito ExtraBold, SIL OFL 1.1)."""
    files = {
        "rounded": ["ARLRDBD.TTF", "arlrdbd.ttf", "Nunito.ttf", "DejaVuSans-Bold.ttf"],
        "display": ["Cinzel-Bold.ttf", "georgiab.ttf", "DejaVuSerif-Bold.ttf"],
        "display-semi": ["Cinzel-SemiBold.ttf", "georgiab.ttf", "DejaVuSerif-Bold.ttf"],
        "display-regular": ["Cinzel-Regular.ttf", "georgia.ttf", "DejaVuSerif.ttf"],
        "ui": ["segoeui.ttf", "DejaVuSans.ttf"],
        "ui-bold": ["segoeuib.ttf", "DejaVuSans-Bold.ttf"],
    }[kind]
    dirs = list(FONT_DIRS) + [os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts"),
                              "/usr/share/fonts/truetype/dejavu"]
    for f in files:
        for d in dirs:
            p = os.path.join(d, f)
            if os.path.isfile(p):
                f_ = ImageFont.truetype(p, size)
                if f.startswith("Nunito"):
                    try:
                        f_.set_variation_by_axes([800])   # ExtraBold: the weight of Arial Rounded MT Bold
                    except Exception:
                        pass
                return f_
    return ImageFont.load_default(size)


def _gradient(w, h, top, bot):
    g = Image.new("RGBA", (w, h))
    gd = ImageDraw.Draw(g)
    for y in range(h):
        gd.line([(0, y), (w, y)], fill=_mix(top, bot, y / max(1, h - 1)))
    return g


def _rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return m


def icon(name, size=28, color="#d9b25f"):
    """Line icons in one consistent weight. Names: play, mods, community, realms, news,
    settings, help, folder, link, discord, github, … and for the realm browser and hosting:
    swords, scroll, star, star_on, flag, sparkle, crown, seed, megaphone, box, ban, signal."""
    im = _canvas(size)
    d = ImageDraw.Draw(im)
    c = _hex(color)
    s = size * SS
    w = max(2, round(s * 0.075))  # stroke
    m = s * 0.12  # margin

    if name == "play":
        d.ellipse([m, m, s - m, s - m], outline=c, width=w)
        cx, cy, r = s / 2 + s * 0.03, s / 2, s * 0.17
        d.polygon([(cx - r * 0.8, cy - r * 1.15), (cx - r * 0.8, cy + r * 1.15), (cx + r * 1.2, cy)], fill=c)

    elif name == "mods":
        # three stacked tiles: the addon layers that sit on top of the game
        cx = s / 2
        hw, hh = s * 0.36, s * 0.16
        for i, y in enumerate((s * 0.30, s * 0.48, s * 0.66)):
            pts = [(cx, y - hh), (cx + hw, y), (cx, y + hh), (cx - hw, y)]
            if i == 0:
                d.polygon(pts, fill=c)
            else:
                d.line(pts[1:] + [pts[3]], fill=c, width=w, joint="curve")
                d.line([pts[3], pts[2], pts[1]], fill=c, width=w, joint="curve")

    elif name == "community":
        # two figures, the nearer one larger
        for (cx, cy, r, sh) in ((s * 0.36, s * 0.34, s * 0.12, s * 0.20), (s * 0.64, s * 0.38, s * 0.10, s * 0.17)):
            d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=c, width=w)
            d.arc([cx - sh, cy + r * 1.3, cx + sh, cy + r * 1.3 + sh * 2], 180, 360, fill=c, width=w)

    elif name == "realms":
        d.ellipse([m, m, s - m, s - m], outline=c, width=w)
        d.ellipse([s * 0.34, m, s * 0.66, s - m], outline=c, width=w)
        d.line([(m, s / 2), (s - m, s / 2)], fill=c, width=w)
        d.arc([m, s * 0.18, s - m, s * 0.48], 200, 340, fill=c, width=w)
        d.arc([m, s * 0.52, s - m, s * 0.82], 20, 160, fill=c, width=w)

    elif name == "news":
        d.rounded_rectangle([s * 0.2, m, s * 0.8, s - m], radius=s * 0.06, outline=c, width=w)
        for y in (0.32, 0.46, 0.60, 0.74):
            x2 = 0.68 if y < 0.7 else 0.52
            d.line([(s * 0.32, s * y), (s * x2, s * y)], fill=c, width=w)

    elif name == "settings":
        cx = cy = s / 2
        ro, ri, teeth = s * 0.40, s * 0.30, 8
        pts = []
        for i in range(teeth * 4):
            a = (i / (teeth * 4)) * 2 * math.pi
            r = ro if (i % 4) in (1, 2) else ri
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        d.polygon(pts, outline=c, width=w)
        d.ellipse([cx - s * 0.12, cy - s * 0.12, cx + s * 0.12, cy + s * 0.12], outline=c, width=w)

    elif name == "help":
        d.ellipse([m, m, s - m, s - m], outline=c, width=w)
        d.arc([s * 0.36, s * 0.24, s * 0.64, s * 0.50], 180, 90, fill=c, width=w)
        d.line([(s / 2, s * 0.50), (s / 2, s * 0.60)], fill=c, width=w)
        r = w * 0.8
        d.ellipse([s / 2 - r, s * 0.70 - r, s / 2 + r, s * 0.70 + r], fill=c)

    elif name == "folder":
        d.polygon([(m, s * 0.28), (s * 0.40, s * 0.28), (s * 0.48, s * 0.36), (s - m, s * 0.36),
                   (s - m, s * 0.78), (m, s * 0.78)], outline=c, width=w)

    elif name == "link":
        d.rounded_rectangle([m, s * 0.38, s * 0.56, s * 0.62], radius=s * 0.12, outline=c, width=w)
        d.rounded_rectangle([s * 0.44, s * 0.38, s - m, s * 0.62], radius=s * 0.12, outline=c, width=w)

    elif name == "chat":
        d.rounded_rectangle([m, s * 0.2, s - m, s * 0.68], radius=s * 0.12, outline=c, width=w)
        d.polygon([(s * 0.30, s * 0.66), (s * 0.30, s * 0.84), (s * 0.48, s * 0.66)], fill=c)

    elif name == "code":
        d.line([(s * 0.36, s * 0.28), (s * 0.16, s / 2), (s * 0.36, s * 0.72)], fill=c, width=w, joint="curve")
        d.line([(s * 0.64, s * 0.28), (s * 0.84, s / 2), (s * 0.64, s * 0.72)], fill=c, width=w, joint="curve")
        d.line([(s * 0.56, s * 0.22), (s * 0.44, s * 0.78)], fill=c, width=w)

    elif name == "bug":
        d.ellipse([s * 0.30, s * 0.30, s * 0.70, s * 0.82], outline=c, width=w)
        d.ellipse([s * 0.38, s * 0.16, s * 0.62, s * 0.36], outline=c, width=w)
        for y in (0.44, 0.58, 0.72):
            d.line([(s * 0.14, s * y), (s * 0.30, s * y)], fill=c, width=w)
            d.line([(s * 0.70, s * y), (s * 0.86, s * y)], fill=c, width=w)

    elif name == "account":
        d.ellipse([m, m, s - m, s - m], outline=c, width=w)
        r = s * 0.13
        d.ellipse([s / 2 - r, s * 0.27, s / 2 + r, s * 0.27 + 2 * r], outline=c, width=w)
        d.arc([s * 0.26, s * 0.56, s * 0.74, s * 0.98], 200, 340, fill=c, width=w)

    elif name == "web":
        d.rounded_rectangle([m, s * 0.18, s - m, s * 0.70], radius=s * 0.06, outline=c, width=w)
        d.line([(s * 0.40, s * 0.84), (s * 0.60, s * 0.84)], fill=c, width=w)
        d.line([(s / 2, s * 0.70), (s / 2, s * 0.84)], fill=c, width=w)
        cx, cy, r = s / 2 + s * 0.02, s * 0.44, s * 0.11
        d.polygon([(cx - r * 0.8, cy - r * 1.1), (cx - r * 0.8, cy + r * 1.1), (cx + r * 1.1, cy)], fill=c)

    elif name == "download":
        d.line([(s / 2, m), (s / 2, s * 0.62)], fill=c, width=w)
        d.line([(s * 0.30, s * 0.44), (s / 2, s * 0.64), (s * 0.70, s * 0.44)], fill=c, width=w, joint="curve")
        d.line([(m, s * 0.70), (m, s * 0.84), (s - m, s * 0.84), (s - m, s * 0.70)], fill=c, width=w, joint="curve")

    elif name == "logout":
        d.line([(s * 0.52, m), (m, m), (m, s - m), (s * 0.52, s - m)], fill=c, width=w, joint="curve")
        d.line([(s * 0.40, s / 2), (s - m, s / 2)], fill=c, width=w)
        d.line([(s * 0.70, s * 0.32), (s - m, s / 2), (s * 0.70, s * 0.68)], fill=c, width=w, joint="curve")

    elif name == "key":
        r = s * 0.17
        d.ellipse([m, s / 2 - r, m + 2 * r, s / 2 + r], outline=c, width=w)
        d.line([(m + 2 * r, s / 2), (s - m, s / 2)], fill=c, width=w)
        d.line([(s * 0.72, s / 2), (s * 0.72, s * 0.66)], fill=c, width=w)
        d.line([(s * 0.86, s / 2), (s * 0.86, s * 0.62)], fill=c, width=w)

    elif name == "shield":
        d.polygon([(s / 2, m), (s - m, s * 0.24), (s * 0.80, s * 0.70), (s / 2, s - m), (s * 0.20, s * 0.70), (m, s * 0.24)],
                  outline=c, width=w)
        d.line([(s * 0.36, s * 0.50), (s * 0.47, s * 0.62), (s * 0.66, s * 0.38)], fill=c, width=w, joint="curve")

    elif name == "server":
        for i, y in enumerate((0.16, 0.42, 0.68)):
            d.rounded_rectangle([m, s * y, s - m, s * (y + 0.2)], radius=s * 0.04, outline=c, width=w)
            r = w * 0.7
            d.ellipse([s * 0.72 - r, s * (y + 0.1) - r, s * 0.72 + r, s * (y + 0.1) + r], fill=c)
            d.line([(s * 0.24, s * (y + 0.1)), (s * 0.50, s * (y + 0.1))], fill=c, width=w)

    elif name == "heart":
        cx = s / 2
        pts = []
        for i in range(64):
            t = i / 64 * 2 * math.pi
            x = 16 * math.sin(t) ** 3
            y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
            pts.append((cx + x * s * 0.024, s * 0.50 + y * s * 0.024))
        d.polygon(pts, outline=c, width=w)

    elif name == "plus":
        d.ellipse([m, m, s - m, s - m], outline=c, width=w)
        d.line([(s / 2, s * 0.30), (s / 2, s * 0.70)], fill=c, width=w)
        d.line([(s * 0.30, s / 2), (s * 0.70, s / 2)], fill=c, width=w)

    elif name == "close":
        d.ellipse([m, m, s - m, s - m], outline=c, width=w)
        d.line([(s * 0.35, s * 0.35), (s * 0.65, s * 0.65)], fill=c, width=w)
        d.line([(s * 0.65, s * 0.35), (s * 0.35, s * 0.65)], fill=c, width=w)

    elif name == "refresh":
        d.arc([m, m, s - m, s - m], 30, 320, fill=c, width=w)
        d.polygon([(s * 0.80, s * 0.10), (s * 0.90, s * 0.40), (s * 0.60, s * 0.34)], fill=c)

    # ---- realm browser / hosting (P2P)
    elif name == "swords":  # PvP: two crossed blades with guards
        for (x0, y0, x1, y1) in ((m, m, s - m * 1.6, s - m * 1.6), (s - m, m, m * 1.6, s - m * 1.6)):
            d.line([(x0, y0), (x1, y1)], fill=c, width=w)
        d.line([(s * 0.56, s * 0.80), (s * 0.80, s * 0.56)], fill=c, width=w)
        d.line([(s * 0.20, s * 0.56), (s * 0.44, s * 0.80)], fill=c, width=w)
        r = w * 0.9
        for (cx, cy) in ((s * 0.84, s * 0.84), (s * 0.16, s * 0.84)):
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)

    elif name == "scroll":  # RP: a scroll with rolled ends and lines of text
        d.rounded_rectangle([s * 0.24, s * 0.18, s * 0.80, s * 0.82], radius=s * 0.04, outline=c, width=w)
        d.ellipse([s * 0.14, s * 0.12, s * 0.30, s * 0.26], outline=c, width=w)
        d.ellipse([s * 0.70, s * 0.74, s * 0.86, s * 0.88], outline=c, width=w)
        for y in (0.36, 0.50, 0.64):
            d.line([(s * 0.36, s * y), (s * 0.68, s * y)], fill=c, width=w)

    elif name in ("star", "star_on"):  # favourite (outline) / favourited (filled)
        cx, cy = s / 2, s * 0.53
        pts = []
        for i in range(10):
            a = -math.pi / 2 + i * math.pi / 5
            r = s * 0.40 if i % 2 == 0 else s * 0.17
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        if name == "star_on":
            d.polygon(pts, fill=c)
        else:
            d.line(pts + pts[:2], fill=c, width=w, joint="curve")

    elif name == "flag":  # report
        d.line([(s * 0.24, m), (s * 0.24, s - m)], fill=c, width=w)
        d.polygon([(s * 0.24, s * 0.16), (s * 0.80, s * 0.16), (s * 0.66, s * 0.32), (s * 0.80, s * 0.48),
                   (s * 0.24, s * 0.48)], outline=c, width=w)

    elif name == "sparkle":  # a four-point star with a small companion
        for (cx, cy, R) in ((s * 0.44, s * 0.54, s * 0.34), (s * 0.78, s * 0.22, s * 0.13)):
            r = R * 0.26
            d.polygon([(cx, cy - R), (cx + r, cy - r), (cx + R, cy), (cx + r, cy + r), (cx, cy + R),
                       (cx - r, cy + r), (cx - R, cy), (cx - r, cy - r)], fill=c)

    elif name == "crown":  # official realm
        d.polygon([(m, s * 0.30), (s * 0.32, s * 0.52), (s / 2, s * 0.22), (s * 0.68, s * 0.52), (s - m, s * 0.30),
                   (s * 0.80, s * 0.74), (s * 0.20, s * 0.74)], outline=c, width=w)
        d.line([(s * 0.20, s * 0.86), (s * 0.80, s * 0.86)], fill=c, width=w)

    elif name == "seed":  # seeding: a sprout rising from a line of soil
        d.line([(s / 2, s * 0.84), (s / 2, s * 0.40)], fill=c, width=w)
        d.polygon([(s / 2, s * 0.56), (s * 0.30, s * 0.54), (s * 0.16, s * 0.36), (s * 0.36, s * 0.38)], fill=c)
        d.polygon([(s / 2, s * 0.44), (s * 0.66, s * 0.22), (s * 0.86, s * 0.16), (s * 0.78, s * 0.36)], fill=c)
        d.line([(m, s * 0.84), (s - m, s * 0.84)], fill=c, width=w)

    elif name == "megaphone":  # announce
        d.polygon([(m, s * 0.40), (s * 0.34, s * 0.40), (s * 0.80, s * 0.16), (s * 0.80, s * 0.84), (s * 0.34, s * 0.60),
                   (m, s * 0.60)], outline=c, width=w)
        d.line([(s * 0.30, s * 0.60), (s * 0.38, s * 0.84)], fill=c, width=w)

    elif name == "box":  # backup: an archive box with a slot
        d.rectangle([m, s * 0.20, s - m, s * 0.38], outline=c, width=w)
        d.rectangle([s * 0.18, s * 0.38, s * 0.82, s * 0.84], outline=c, width=w)
        d.line([(s * 0.40, s * 0.52), (s * 0.60, s * 0.52)], fill=c, width=w)

    elif name == "ban":  # ban / kick: a circle with a slash
        d.ellipse([m, m, s - m, s - m], outline=c, width=w)
        d.line([(s * 0.28, s * 0.28), (s * 0.72, s * 0.72)], fill=c, width=w)

    elif name == "signal":  # ping / reachability: three rising bars
        for i, hgt in enumerate((0.26, 0.46, 0.66)):
            x0 = s * (0.18 + i * 0.24)
            d.rectangle([x0, s * (0.82 - hgt), x0 + s * 0.14, s * 0.82], fill=c)

    return _finish(im, size)


def emblem(size=52):
    """The sidebar medallion: a gold ring around a violet vortex eye."""
    im = _canvas(size)
    d = ImageDraw.Draw(im)
    s = size * SS
    d.ellipse([0, 0, s - 1, s - 1], fill=_hex("#3a2a12"))
    d.ellipse([s * 0.04, s * 0.04, s * 0.96, s * 0.96], fill=_hex("#c99a3f"))
    d.ellipse([s * 0.12, s * 0.12, s * 0.88, s * 0.88], fill=_hex("#2a1c0b"))
    d.ellipse([s * 0.18, s * 0.18, s * 0.82, s * 0.82], fill=_hex("#1a1236"))
    for i in range(5):  # spiral arms
        a0 = i * 72
        d.arc([s * 0.22, s * 0.22, s * 0.78, s * 0.78], a0, a0 + 50, fill=_hex("#8b6cf0"), width=round(s * 0.05))
    d.ellipse([s * 0.38, s * 0.38, s * 0.62, s * 0.62], fill=_hex("#05030b"))
    d.ellipse([s * 0.44, s * 0.40, s * 0.52, s * 0.48], fill=_hex("#b9a6ff", 160))
    return _finish(im, size)


def emblem_spin(size, angle):
    """The emblem with its spiral arms turned by `angle` degrees (for the animated medallion)."""
    im = _canvas(size)
    d = ImageDraw.Draw(im)
    s = size * SS
    d.ellipse([0, 0, s - 1, s - 1], fill=_hex("#3a2a12"))
    d.ellipse([s * 0.04, s * 0.04, s * 0.96, s * 0.96], fill=_hex("#c99a3f"))
    d.ellipse([s * 0.12, s * 0.12, s * 0.88, s * 0.88], fill=_hex("#2a1c0b"))
    d.ellipse([s * 0.18, s * 0.18, s * 0.82, s * 0.82], fill=_hex("#1a1236"))
    for i in range(5):
        a0 = i * 72 + angle
        d.arc([s * 0.22, s * 0.22, s * 0.78, s * 0.78], a0, a0 + 50, fill=_hex("#8b6cf0"), width=round(s * 0.05))
        d.arc([s * 0.30, s * 0.30, s * 0.70, s * 0.70], -a0 * 1.4, -a0 * 1.4 + 40, fill=_hex("#5b43b8"), width=round(s * 0.03))
    d.ellipse([s * 0.38, s * 0.38, s * 0.62, s * 0.62], fill=_hex("#05030b"))
    d.ellipse([s * 0.44, s * 0.40, s * 0.52, s * 0.48], fill=_hex("#b9a6ff", 160))
    return _finish(im, size)


# ---------------------------------------------------------------- panels

def panel(w, h, radius=14, hover=False, accent="#c99a3f", alpha=222, header=0):
    """A dark glass card with a soft drop shadow and a gold hairline border.

    Returns (image, margin): the image is w+2*margin wide; place it at (x - margin, y - margin).
    `header` > 0 draws a faint band across the top `header` pixels for a title row.
    """
    m = 14
    W, H = w + 2 * m, h + 2 * m
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([m - 2, m + 4, m + w + 2, m + h + 6], radius=radius + 2, fill=(0, 0, 0, 150))
    out = Image.alpha_composite(out, sh.filter(ImageFilter.GaussianBlur(8)))

    body = _gradient(w, h, (24, 18, 38, alpha), (11, 8, 19, min(255, alpha + 14)))
    if header:
        band = _gradient(w, header, (60, 44, 22, 70), (30, 22, 12, 0))
        body.alpha_composite(band, (0, 0))
    mask = _rounded_mask(w, h, radius)
    card = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    card.paste(body, (0, 0), mask)
    out.alpha_composite(card, (m, m))

    # border: gold hairline, brighter at the top; inner light line
    S = 3
    bw, bh = w * S, h * S
    b = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    bd = ImageDraw.Draw(b)
    acc = _hex(accent)
    top_a = 255 if hover else 190
    bot_a = 170 if hover else 70
    grad = _gradient(bw, bh, acc[:3] + (top_a,), acc[:3] + (bot_a,))
    ring = Image.new("L", (bw, bh), 0)
    rd = ImageDraw.Draw(ring)
    rd.rounded_rectangle([0, 0, bw - 1, bh - 1], radius=radius * S, fill=255)
    rd.rounded_rectangle([S * 1.2, S * 1.2, bw - 1 - S * 1.2, bh - 1 - S * 1.2], radius=(radius - 1.2) * S, fill=0)
    b.paste(grad, (0, 0), ring)
    bd.rounded_rectangle([S * 2.4, S * 2.4, bw - 1 - S * 2.4, bh - 1 - S * 2.4], radius=(radius - 2.4) * S,
                         outline=(255, 255, 255, 18 if not hover else 34), width=S)
    b = b.resize((w, h), Image.Resampling.LANCZOS)
    out.alpha_composite(b, (m, m))
    if hover:
        glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(glow).rounded_rectangle([m, m, m + w, m + h], radius=radius, outline=acc[:3] + (110,), width=3)
        out = Image.alpha_composite(glow.filter(ImageFilter.GaussianBlur(5)), out)
    return out, m


def strip(w, h):
    """The bottom bar backdrop: transparent at the top, near-opaque at the bottom, gold hairline."""
    im = _gradient(w, h, (6, 4, 12, 0), (6, 4, 12, 236))
    top = _gradient(w, h, (6, 4, 12, 0), (6, 4, 12, 0))
    d = ImageDraw.Draw(im)
    y = int(h * 0.30)
    for x in range(w):  # hairline fading out at both ends
        t = 1 - abs((x / w) * 2 - 1)
        d.point((x, y), fill=(201, 154, 63, int(130 * t ** 0.6)))
    return Image.alpha_composite(top, im)


def topbar(w, h):
    return _gradient(w, h, (6, 4, 12, 200), (6, 4, 12, 0))


# ---------------------------------------------------------------- PLAY

def plate(width, height, hover=False, disabled=False, label="PLAY", sub=""):
    """The PLAY plate: beveled gold, darker rim, engraved Cinzel label, optional sub-label."""
    S = 3
    W, H = width * S, height * S
    r = 12 * S
    if disabled:
        top, mid, bot = (110, 98, 80), (84, 74, 60), (56, 48, 38)
    elif hover:
        top, mid, bot = (255, 226, 140), (242, 180, 64), (182, 108, 22)
    else:
        top, mid, bot = (246, 204, 110), (222, 158, 52), (160, 94, 18)
    g = Image.new("RGBA", (W, H))
    gd = ImageDraw.Draw(g)
    for y in range(H):
        t = y / (H - 1)
        col = _mix(top, mid, t / 0.5) if t < 0.5 else _mix(mid, bot, (t - 0.5) / 0.5)
        gd.line([(0, y), (W, y)], fill=col + (255,))
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    im.paste(g, (0, 0), _rounded_mask(W, H, r))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=r, outline=(70, 40, 8, 255), width=3 * S)
    d.rounded_rectangle([4 * S, 4 * S, W - 4 * S, H - 4 * S], radius=r - 3 * S,
                        outline=(255, 240, 190, 60 if disabled else 170), width=S)
    sheen = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).rounded_rectangle([10 * S, 7 * S, W - 10 * S, int(H * 0.44)], radius=r,
                                            fill=(255, 255, 255, 14 if disabled else 52))
    im = Image.alpha_composite(im, sheen.filter(ImageFilter.GaussianBlur(3 * S)))
    # engraved label
    f = font("display", int(height * 0.42 * S) if not sub else int(height * 0.38 * S))
    tw = d.textlength(label, font=f)
    ty = H * (0.50 if not sub else 0.42)
    d = ImageDraw.Draw(im)
    d.text((W / 2, ty + S * 1.5), label, font=f, anchor="mm", fill=(255, 236, 180, 90 if not disabled else 30))
    d.text((W / 2, ty), label, font=f, anchor="mm", fill=(52, 26, 4, 255) if not disabled else (40, 34, 28, 255))
    if sub:
        fs = font("display-semi", int(height * 0.15 * S))
        d.text((W / 2, H * 0.76), sub, font=fs, anchor="mm", fill=(70, 38, 6, 230) if not disabled else (40, 34, 28, 200))
    return im.resize((width, height), Image.Resampling.LANCZOS)


def glow(width, height, intensity=1.0, color="#f0b44c", spread=18):
    """A soft halo the size of a button plus `spread` on each side."""
    W, H = width + spread * 2, height + spread * 2
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    c = _hex(color)[:3]
    ImageDraw.Draw(im).rounded_rectangle([spread, spread, spread + width, spread + height], radius=14,
                                         fill=c + (int(150 * intensity),))
    return im.filter(ImageFilter.GaussianBlur(spread * 0.55))


def square_button(size, icon_name, label, hover=False, active=False):
    """A dark violet square plate with an icon and a small engraved label (the WEB play button)."""
    S = 3
    W = size * S
    top, bot = ((92, 70, 170), (40, 28, 86)) if (hover or active) else ((62, 46, 120), (26, 18, 56))
    im = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    im.paste(_gradient(W, W, top + (255,), bot + (255,)), (0, 0), _rounded_mask(W, W, 12 * S))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, W - 1, W - 1], radius=12 * S, outline=(201, 154, 63, 255 if hover else 200), width=2 * S)
    d.rounded_rectangle([4 * S, 4 * S, W - 4 * S, W - 4 * S], radius=9 * S, outline=(190, 170, 255, 70), width=S)
    im = im.resize((size, size), Image.Resampling.LANCZOS)
    ic = icon(icon_name, int(size * 0.44), "#f3d179" if hover else "#e6d6a8")
    im.alpha_composite(ic, ((size - ic.width) // 2, int(size * 0.14)))
    d = ImageDraw.Draw(im)
    d.text((size / 2, size * 0.80), label, font=font("display", max(8, int(size * 0.15))), anchor="mm",
           fill=(243, 209, 121, 255) if hover else (220, 200, 150, 255))
    return im


@lru_cache(maxsize=64)
def gold_plate(w, h, hover=False):
    """The PLAY plate (kit/plate_gold.png) at button size: bevelled gold face, bronze rim, gem end caps."""
    plate = kit("plate_gold")
    scaled = plate.resize((max(1, round(plate.width * h / plate.height)), h), Image.Resampling.LANCZOS)
    cap = max(2, round(58 * h / plate.height))
    im = _three_slice(scaled, w, cap, cap)
    if hover:
        r, g, b, a = im.split()
        im = Image.merge("RGBA", (r.point(lambda v: min(255, int(v * 1.12 + 8))), g.point(lambda v: min(255, int(v * 1.1 + 6))),
                                  b.point(lambda v: min(255, int(v * 1.04))), a))
    return im


def pill(w, h, style="ghost", hover=False):
    """A button backdrop (kept under its old name: every button, chip and pill in the launcher uses it)."""
    return button_bg(w, h, style, hover)


def _grad_stops(w, h, stops):
    """Vertical gradient through (pos, rgb) stops."""
    g = Image.new("RGBA", (w, h)); d = ImageDraw.Draw(g)
    for y in range(h):
        t = y / max(1, h - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                k = (t - p0) / max(1e-6, p1 - p0)
                d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * k) for a, b in zip(c0, c1)) + (255,))
                break
    return g

BUTTON_STYLES = {  # body stops, rim (top, bottom), inner highlight alpha
    "gold":    ([(0, (255, 226, 140)), (0.48, (232, 172, 62)), (0.52, (214, 148, 44)), (1, (160, 96, 22))], ((255, 236, 170), (122, 74, 18))),
    "ghost":   ([(0, (44, 34, 52)), (0.5, (28, 21, 34)), (1, (16, 12, 20))], ((236, 196, 110), (120, 88, 40))),
    "discord": ([(0, (128, 140, 255)), (0.48, (96, 108, 246)), (0.52, (84, 96, 232)), (1, (58, 66, 180))], ((236, 196, 110), (120, 88, 40))),
    "danger":  ([(0, (170, 60, 52)), (0.5, (128, 38, 34)), (1, (84, 20, 18))], ((236, 196, 110), (120, 88, 40))),
    "violet":  ([(0, (118, 94, 210)), (0.5, (82, 62, 170)), (1, (48, 34, 112))], ((236, 196, 110), (120, 88, 40))),
}

def button_bg(w, h, style="ghost", hover=False):
    """Every launcher button: dark outline, metallic gold rim, gradient body with a bevel line and soft gloss."""
    S = 4
    W, H = w * S, h * S
    r = min(H // 2, 7 * S)
    body_stops, (rim_t, rim_b) = BUTTON_STYLES.get(style, BUTTON_STYLES["ghost"])
    if hover:
        body_stops = [(p, tuple(min(255, int(c * 1.12 + 10)) for c in col)) for p, col in body_stops]
        rim_t = tuple(min(255, c + 25) for c in rim_t)
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    def rr(box, rad):
        m = Image.new("L", (W, H), 0); ImageDraw.Draw(m).rounded_rectangle(box, radius=rad, fill=255); return m
    outer = rr([0, 0, W - 1, H - 1], r)
    im.paste((10, 7, 5, 255), (0, 0), outer)                                      # dark outline
    rim = rr([S, S, W - 1 - S, H - 1 - S], r - S)
    im.paste(_grad_stops(W, H, [(0, rim_t), (1, rim_b)]), (0, 0), rim)                  # metallic gold rim
    inset = int(2.5 * S)
    body = rr([inset, inset, W - 1 - inset, H - 1 - inset], max(1, r - inset))
    im.paste(_grad_stops(W, H, body_stops), (0, 0), body)                               # body
    hl = Image.new("RGBA", (W, H), (0, 0, 0, 0))                                  # bevel highlight + gloss
    hd = ImageDraw.Draw(hl)
    hd.rounded_rectangle([inset, inset, W - 1 - inset, H - 1 - inset], radius=max(1, r - inset), outline=(255, 255, 255, 70), width=S)
    gl = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(gl).rounded_rectangle([inset + S, inset + S, W - 1 - inset - S, H // 2], radius=max(1, r - inset - S), fill=(255, 255, 255, 34))
    hl.alpha_composite(gl)
    clip = Image.new("RGBA", (W, H), (0, 0, 0, 0)); clip.paste(hl, (0, 0), body)
    im.alpha_composite(clip)
    return im.resize((w, h), Image.Resampling.LANCZOS)

def button_label(text, px, color, dark_text=False, face="display"):
    """Button lettering drawn at 4x and reduced: a crisp 1px drop shadow (or a pale lip under dark text)."""
    S = 4
    f = font(face, px * S)
    l, t, r, b = ImageDraw.Draw(Image.new("RGBA", (1, 1))).textbbox((0, 0), text, font=f)
    pad = 3 * S
    W, H = r - l + 2 * pad, b - t + 2 * pad
    o = (pad - l, pad - t)
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    if dark_text:
        d.text((o[0], o[1] + S), text, font=f, fill=(255, 240, 190, 140))       # light lip below: cut into gold
    else:
        d.text((o[0], o[1] + S), text, font=f, fill=(0, 0, 0, 200))             # crisp 1px drop shadow
    d.text(o, text, font=f, fill=color)
    return im.resize((max(1, W // S), max(1, H // S)), Image.Resampling.LANCZOS)


def discord_logo(size, fallback_color="#ffffff"):
    """Discord's official logo from kit/discord.png (download it from discord.com/branding);
    a plain chat icon until that file is there."""
    if kit("discord") is not None:
        return kit_image("discord", height=size)
    return icon("chat", size, fallback_color)


def github_logo(size, fallback_color="#c99a3f"):
    """GitHub's official mark from kit/github.png (download it from github.com/logos); the </> icon until then."""
    if kit("github") is not None:
        return kit_image("github", height=size)
    return icon("code", size, fallback_color)


def avatar(size, letter, ring="#c99a3f"):
    """A round account badge with the account's initial."""
    S = 4
    W = size * S
    im = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse([0, 0, W - 1, W - 1], fill=_hex(ring))
    inner = _gradient(W, W, (74, 54, 150, 255), (26, 18, 56, 255))
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).ellipse([W * 0.08, W * 0.08, W * 0.92, W * 0.92], fill=255)
    im.paste(inner, (0, 0), m)
    d = ImageDraw.Draw(im)
    d.text((W / 2, W * 0.53), (letter or "?")[:1].upper(), font=font("display", int(W * 0.48)), anchor="mm",
           fill=(243, 209, 121, 255))
    return im.resize((size, size), Image.Resampling.LANCZOS)


def text_image(text, kind="display", size=16, color="#f3d179", shadow=True, tracking=0):
    """Text rendered with the bundled display face (Tk cannot load a font file on its own)."""
    f = font(kind, size * 2)
    if tracking:
        text = (" " * 0).join(text)
    d0 = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    l, t, r, b = d0.textbbox((0, 0), text, font=f)
    pad = 8
    im = Image.new("RGBA", (r - l + pad * 2, b - t + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if shadow:
        sh = Image.new("RGBA", im.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).text((pad - l, pad - t + 3), text, font=f, fill=(0, 0, 0, 200))
        im = Image.alpha_composite(im, sh.filter(ImageFilter.GaussianBlur(3)))
        d = ImageDraw.Draw(im)
    d.text((pad - l, pad - t), text, font=f, fill=_hex(color))
    return im.resize((im.width // 2, im.height // 2), Image.Resampling.LANCZOS)


# ---------------------------------------------------------------- progress bar

BAR_STYLES = {
    "gold": ((255, 214, 120), (226, 160, 52), (150, 88, 14)),
    "green": ((150, 232, 150), (72, 180, 98), (30, 104, 52)),
    "violet": ((196, 176, 255), (128, 98, 236), (66, 42, 160)),
    "amber": ((255, 216, 120), (232, 160, 40), (150, 92, 10)),
    "red": ((255, 150, 140), (214, 72, 62), (120, 26, 22)),
}


def progress(width, height, fraction, style="gold", shimmer=None, indeterminate=None):
    """An inset progress track with ornamental end caps.

    fraction: 0..1 fill. shimmer: 0..1 position of a light band sweeping the fill (None = off).
    indeterminate: 0..1 phase of a sliding segment (overrides fraction) for "working…" states.
    The image is width x (height + 8); the caps sit inside the width.
    """
    S = 2
    cap = 9
    W, H = width * S, (height + 8) * S
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    tx0, tx1 = (cap + 4) * S, W - (cap + 4) * S
    ty0, ty1 = 4 * S, H - 4 * S
    r = (ty1 - ty0) // 2
    # track: inset, dark, faint inner shadow
    d.rounded_rectangle([tx0 - S, ty0 - S, tx1 + S, ty1 + S], radius=r + S, fill=(70, 52, 22, 255))
    d.rounded_rectangle([tx0, ty0, tx1, ty1], radius=r, fill=(8, 6, 14, 255))
    inner = _gradient(tx1 - tx0, (ty1 - ty0) // 2, (0, 0, 0, 160), (0, 0, 0, 0))
    m = _rounded_mask(tx1 - tx0, ty1 - ty0, r).crop((0, 0, tx1 - tx0, (ty1 - ty0) // 2))
    im.paste(inner, (tx0, ty0), Image.composite(m, Image.new("L", m.size, 0), m))
    # caps: small gold diamonds with a dark core
    for cx in (cap * S // 2 + 2 * S, W - cap * S // 2 - 2 * S):
        cy, rr = H / 2, cap * S / 2
        d.polygon([(cx, cy - rr), (cx + rr, cy), (cx, cy + rr), (cx - rr, cy)], fill=(201, 154, 63, 255))
        d.polygon([(cx, cy - rr * 0.45), (cx + rr * 0.45, cy), (cx, cy + rr * 0.45), (cx - rr * 0.45, cy)], fill=(40, 26, 8, 255))

    top, mid, bot = BAR_STYLES.get(style, BAR_STYLES["gold"])
    fw_total = tx1 - tx0 - 2 * S
    fh = ty1 - ty0 - 2 * S
    if indeterminate is not None:
        seg = int(fw_total * 0.28)
        p = 0.5 - 0.5 * math.cos(indeterminate * 2 * math.pi)
        x0 = int((fw_total - seg) * p)
        span = (x0, x0 + seg)
    else:
        f = max(0.0, min(1.0, fraction or 0))
        span = (0, int(fw_total * f)) if f > 0 else None
    if span and span[1] - span[0] >= 2:
        sw = max(fh, span[1] - span[0])
        bar = Image.new("RGBA", (sw, fh))
        bd = ImageDraw.Draw(bar)
        for y in range(fh):
            t = y / max(1, fh - 1)
            col = _mix(top, mid, t / 0.45) if t < 0.45 else _mix(mid, bot, (t - 0.45) / 0.55)
            bd.line([(0, y), (sw, y)], fill=col + (255,))
        bd.line([(fh // 2, S), (sw - fh // 2, S)], fill=(255, 255, 255, 120), width=S)  # gloss
        if shimmer is not None:
            band = Image.new("RGBA", (sw, fh), (0, 0, 0, 0))
            bx = int((sw + fh * 6) * shimmer) - fh * 3
            ImageDraw.Draw(band).polygon([(bx, 0), (bx + fh * 2, 0), (bx + fh, fh), (bx - fh, fh)], fill=(255, 255, 255, 90))
            bar = Image.alpha_composite(bar, band.filter(ImageFilter.GaussianBlur(S * 2)))
        mask = _rounded_mask(sw, fh, fh // 2)
        im.paste(bar, (tx0 + S + span[0], ty0 + S), mask)
        # leading-edge spark
        if indeterminate is None and 0 < (fraction or 0) < 1:
            ex = tx0 + S + span[1]
            spark = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            ImageDraw.Draw(spark).ellipse([ex - fh, H / 2 - fh, ex + fh * 0.6, H / 2 + fh], fill=top + (200,))
            im = Image.alpha_composite(im, spark.filter(ImageFilter.GaussianBlur(S * 3)))
    return im.resize((width, height + 8), Image.Resampling.LANCZOS)


# legacy name, used by older call sites
def track(width, height, fraction, color="#c99a3f"):
    return progress(width, max(8, height // 3), fraction or 0)


# ---------------------------------------------------------------- particles

@lru_cache(maxsize=16)
def mote(size, hue="gold"):
    """A soft glowing mote for the floating-ember layer."""
    W = size * 4
    im = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    c = {"gold": (255, 200, 110), "violet": (180, 150, 255), "white": (235, 230, 255)}[hue]
    d = ImageDraw.Draw(im)
    d.ellipse([W * 0.2, W * 0.2, W * 0.8, W * 0.8], fill=c + (120,))
    im = im.filter(ImageFilter.GaussianBlur(W * 0.12))
    ImageDraw.Draw(im).ellipse([W * 0.42, W * 0.42, W * 0.58, W * 0.58], fill=(255, 250, 235, 255))
    return im.resize((size, size), Image.Resampling.LANCZOS)


def dot(size, color):
    S = 4
    im = Image.new("RGBA", (size * S, size * S), (0, 0, 0, 0))
    ImageDraw.Draw(im).ellipse([0, 0, size * S - 1, size * S - 1], fill=_hex(color))
    return im.resize((size, size), Image.Resampling.LANCZOS)


def halo(size, color, alpha=120):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(im).ellipse([size * 0.25, size * 0.25, size * 0.75, size * 0.75], fill=_hex(color, alpha))
    return im.filter(ImageFilter.GaussianBlur(size * 0.12))


# ================================================================ UI kit (assets/launcher/kit)
#
# Hand-painted pieces cut from the Open Vanilla UI kit sheet: plates, frames, the energy bar and the
# dragon heads. They are resized/sliced here so the launcher can lay them out at any size.

KIT_DIRS = []  # the launcher prepends assets/launcher/kit


@lru_cache(maxsize=32)
def kit(name):
    for d in KIT_DIRS:
        p = os.path.join(d, name + ".png")
        if os.path.isfile(p):
            return Image.open(p).convert("RGBA")
    return None


def _fit_h(im, h):
    return im.resize((max(1, round(im.width * h / im.height)), h), Image.Resampling.LANCZOS)


def kit_image(name, height=None, width=None):
    im = kit(name)
    if im is None:
        return Image.new("RGBA", (width or height or 1, height or width or 1), (0, 0, 0, 0))
    if height:
        return _fit_h(im, height)
    if width:
        return im.resize((width, max(1, round(im.height * width / im.width))), Image.Resampling.LANCZOS)
    return im.copy()


def _three_slice(im, w, cap_l, cap_r):
    """Stretch the middle of `im` horizontally to width w, keeping the end caps."""
    if w <= cap_l + cap_r:
        return im.resize((w, im.height), Image.Resampling.LANCZOS)
    out = Image.new("RGBA", (w, im.height), (0, 0, 0, 0))
    out.paste(im.crop((0, 0, cap_l, im.height)), (0, 0))
    mid = im.crop((cap_l, 0, im.width - cap_r, im.height)).resize((w - cap_l - cap_r, im.height), Image.Resampling.LANCZOS)
    out.paste(mid, (cap_l, 0))
    out.paste(im.crop((im.width - cap_r, 0, im.width, im.height)), (w - cap_r, 0))
    return out


def kit_panel(w, h, fill=(13, 10, 18, 214), hover=False, corner=40, flat=False):
    """A framed card: the kit's bronze frame 9-sliced around a translucent dark fill."""
    src = kit("panel")
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    body = Image.new("RGBA", (w, h), fill) if flat else _gradient(w, h, tuple(min(255, c + 8) for c in fill[:3]) + (fill[3],), fill)
    m = _rounded_mask(w, h, 6)
    out.paste(body, (0, 0), m)
    if src is None:
        ImageDraw.Draw(out).rounded_rectangle([0, 0, w - 1, h - 1], radius=6, outline=(150, 116, 52, 255), width=2)
        return out
    c = min(corner, w // 2, h // 2)
    sw, sh = src.size
    pieces = []
    # corners
    pieces.append((src.crop((0, 0, c, c)), (0, 0)))
    pieces.append((src.crop((sw - c, 0, sw, c)), (w - c, 0)))
    pieces.append((src.crop((0, sh - c, c, sh)), (0, h - c)))
    pieces.append((src.crop((sw - c, sh - c, sw, sh)), (w - c, h - c)))
    # edges
    if w > 2 * c:
        pieces.append((src.crop((c, 0, sw - c, c)).resize((w - 2 * c, c)), (c, 0)))
        pieces.append((src.crop((c, sh - c, sw - c, sh)).resize((w - 2 * c, c)), (c, h - c)))
    if h > 2 * c:
        pieces.append((src.crop((0, c, c, sh - c)).resize((c, h - 2 * c)), (0, c)))
        pieces.append((src.crop((sw - c, c, sw, sh - c)).resize((c, h - 2 * c)), (w - c, c)))
    frame = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for im, pos in pieces:
        frame.alpha_composite(im, pos)
    if hover:
        frame = Image.eval(frame, lambda v: v)  # copy
        r, g, b, a = frame.split()
        frame = Image.merge("RGBA", (r.point(lambda v: min(255, int(v * 1.35))), g.point(lambda v: min(255, int(v * 1.3))),
                                     b.point(lambda v: min(255, int(v * 1.1))), a))
    out.alpha_composite(frame)
    return out


def kit_play(width, state="normal", name="play"):
    """A plate from the kit (PLAY, or play_web for PLAY IN BROWSER). state: normal, hover, pressed, disabled."""
    im = kit_image(name, width=width)
    r, g, b, a = im.split()
    if state == "hover":
        im = Image.merge("RGBA", (r.point(lambda v: min(255, int(v * 1.14 + 8))), g.point(lambda v: min(255, int(v * 1.12 + 6))),
                                  b.point(lambda v: min(255, int(v * 1.05))), a))
    elif state == "pressed":
        im = Image.merge("RGBA", (r.point(lambda v: int(v * 0.86)), g.point(lambda v: int(v * 0.84)), b.point(lambda v: int(v * 0.84)), a))
    elif state == "disabled":
        gray = im.convert("L").point(lambda v: int(v * 0.62))
        im = Image.merge("RGBA", (gray, gray, gray.point(lambda v: int(v * 0.95)), a))
    return im


def kit_glow(width, height, intensity, color=(255, 170, 60), spread=22):
    W, H = width + spread * 2, height + spread * 2
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle([spread + 6, spread + 4, spread + width - 6, spread + height - 4], radius=10,
                                         fill=color + (int(170 * intensity),))
    return im.filter(ImageFilter.GaussianBlur(spread * 0.5))


# energy bar ------------------------------------------------------------------

_BAR_INTERIOR = (28, 19, 713, 41)   # inside the kit's bar frame (x0, y0, x1, y1)
_BAR_TINTS = {
    "blue": None,  # the kit's own colours
    "gold": ((38, 20, 2), (214, 140, 34), (255, 236, 160)),
    "green": ((4, 28, 12), (52, 176, 88), (200, 255, 200)),
    "red": ((30, 4, 4), (196, 52, 44), (255, 190, 170)),
    "violet": ((14, 6, 40), (124, 92, 232), (226, 214, 255)),
    "amber": ((36, 18, 0), (226, 150, 30), (255, 230, 150)),
}


@lru_cache(maxsize=8)
def _bar_frame(native_w):
    return _three_slice(kit("bar_frame"), native_w, 64, 64)


@lru_cache(maxsize=12)
def _energy(style, length, height):
    tex = kit("bar_energy")
    tex = tex.resize((max(8, round(tex.width * height / tex.height)), height), Image.Resampling.LANCZOS)
    # mirror-tile so the scrolling texture wraps without a seam
    tile = Image.new("RGBA", (tex.width * 2, height))
    tile.paste(tex, (0, 0))
    tile.paste(tex.transpose(Image.Transpose.FLIP_LEFT_RIGHT), (tex.width, 0))
    reps = length // tile.width + 2
    strip_ = Image.new("RGBA", (tile.width * reps, height))
    for i in range(reps):
        strip_.paste(tile, (i * tile.width, 0))
    tint = _BAR_TINTS.get(style)
    if tint:
        lum = strip_.convert("L")
        lo, mid, hi = tint
        lut = []
        for ch in range(3):
            for v in range(256):
                t = v / 255
                lut.append(round(lo[ch] + (mid[ch] - lo[ch]) * (t / 0.55)) if t < 0.55 else
                           round(mid[ch] + (hi[ch] - mid[ch]) * ((t - 0.55) / 0.45)))
        rgb = Image.merge("RGB", (lum, lum, lum)).point(lut)
        strip_ = Image.merge("RGBA", (*rgb.split(), strip_.split()[3]))
    return strip_, tile.width


def kit_bar(width, height, fraction, style="blue", phase=0.0, indeterminate=None):
    """The ornate energy bar. phase (0..1) scrolls the energy; indeterminate (0..1) slides a segment."""
    frame_src = kit("bar_frame")
    if frame_src is None:
        return progress(width, max(8, height - 8), fraction or 0, "violet" if style == "blue" else style)
    scale = height / frame_src.height
    nw = max(200, round(width / scale))
    frame = _bar_frame(nw).copy()
    x0, y0 = _BAR_INTERIOR[0], _BAR_INTERIOR[1]
    x1, y1 = nw - (frame_src.width - _BAR_INTERIOR[2]), _BAR_INTERIOR[3]
    iw, ih = x1 - x0, y1 - y0
    if indeterminate is not None:
        seg = int(iw * 0.30)
        p = 0.5 - 0.5 * math.cos(indeterminate * 2 * math.pi)
        span = (int((iw - seg) * p), int((iw - seg) * p) + seg)
    else:
        f = max(0.0, min(1.0, fraction or 0))
        span = (0, int(iw * f)) if f > 0.004 else None
    if span:
        tex, period = _energy(style, iw + 400, ih)
        off = int(phase * period) % period
        seg_w = span[1] - span[0]
        fill = tex.crop((off, 0, off + seg_w, ih))
        mask = _rounded_mask(seg_w, ih, ih // 2)
        frame.paste(fill, (x0 + span[0], y0), mask)
        if indeterminate is None and 0 < (fraction or 0) < 1:
            tip = kit("bar_tip")
            if tip is not None:
                tip = _fit_h(tip, ih + 8)
                frame.alpha_composite(tip, (max(x0, x0 + span[1] - tip.width + 4), y0 - 4))
    return frame.resize((width, height), Image.Resampling.LANCZOS)


# tabs, emblem, dropdown ----------------------------------------------------------

def emboss_text(text, px, color="#f3d179", kind="display", engraved=False):
    """Lettering with depth: a soft drop shadow, a dark rim and a top-lit fill. engraved=True is for dark
    letters on gold plates: a pale lip under each letter instead of the shadow, so it reads as cut in."""
    S = 3
    f = font(kind, px * S)
    l, t, r, b = ImageDraw.Draw(Image.new("RGBA", (1, 1))).textbbox((0, 0), text, font=f)
    pad = 4 * S
    W, H = r - l + pad * 2, b - t + pad * 2
    org = (pad - l, pad - t)
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    base = _hex(color)[:3]
    if engraved:
        lip = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(lip).text((org[0], org[1] + S), text, font=f, fill=(255, 238, 180, 150))
        im.alpha_composite(lip)
    else:
        sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(sh).text((org[0], org[1] + 2 * S), text, font=f, fill=(0, 0, 0, 220), stroke_width=S, stroke_fill=(0, 0, 0, 220))
        im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(1.6 * S)))
        rim = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(rim).text(org, text, font=f, fill=(18, 11, 5, 255), stroke_width=S, stroke_fill=(18, 11, 5, 255))
        im.alpha_composite(rim)
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).text(org, text, font=f, fill=255)
    top = tuple(min(255, int(c + (255 - c) * (0.15 if engraved else 0.45))) for c in base) + (255,)
    bot = tuple(int(c * (0.9 if engraved else 0.78)) for c in base) + (255,)
    fill = _gradient(W, H, top, bot)
    im.paste(fill, (0, 0), mask)
    return im.resize((max(1, W // S), max(1, H // S)), Image.Resampling.LANCZOS)


def tab(label, icon_name, active=False, hover=False, height=40, px=15):
    """A top-bar tab: the kit's dark plate (kit/plate_dark.png), embossed Cinzel label and icon;
    the active tab gets a gold rim and a warm inner glow."""
    col = "#ffe08a" if active else ("#fff0c8" if hover else "#e9d8ad")
    txt = emboss_text(label, px, col)
    ic = icon(icon_name, 18, col)
    W = 14 + ic.width + 7 + txt.width + 12
    plate = kit("plate_dark")
    if plate is not None:
        scaled = plate.resize((max(1, round(plate.width * height / plate.height)), height), Image.Resampling.LANCZOS)
        cap = max(4, round(30 * height / plate.height))
        im = _three_slice(scaled, W, cap, cap)
    else:
        im = Image.new("RGBA", (W, height), (0, 0, 0, 0))
        im.paste(_gradient(W, height, (48, 46, 43, 255), (32, 30, 28, 255)), (0, 0), _rounded_mask(W, height, 5))
    d = ImageDraw.Draw(im)
    if active or hover:
        glow = Image.new("RGBA", (W, height), (0, 0, 0, 0))
        ImageDraw.Draw(glow).rounded_rectangle([5, 5, W - 6, height - 6], radius=4,
                                               fill=(255, 190, 80, 46 if active else 22))
        im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(3)))
    if active:
        d.rounded_rectangle([1, 1, W - 2, height - 2], radius=6, outline=(240, 196, 98, 255), width=2)
    sh = Image.new("RGBA", (W, height), (0, 0, 0, 0))
    sh.alpha_composite(icon(icon_name, 18, "#000000"), (14, (height - ic.height) // 2 + 2))
    im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(1.2)))
    im.alpha_composite(ic, (14, (height - ic.height) // 2))
    im.alpha_composite(txt, (14 + ic.width + 7, (height - txt.height) // 2))
    return im


def button_face(base, label, px, color, engraved=False, icon_img=None, max_w=None, face="display"):
    """A button image: `base` (pill/plate art) with an optional icon and an embossed label centred on it."""
    im = base.copy()
    w, h = im.size
    txt = button_label(label, px, color, dark_text=engraved, face=face)
    room = (max_w or w - 22) - (icon_img.width + 6 if icon_img else 0)
    while txt.width > room and px > 8:  # long labels shrink to fit instead of spilling over the edge
        px -= 1
        txt = button_label(label, px, color, dark_text=engraved, face=face)
    inner = txt.width + (icon_img.width + 6 if icon_img else 0)
    x = (w - inner) // 2
    if icon_img is not None:
        im.alpha_composite(icon_img, (x, (h - icon_img.height) // 2))
        x += icon_img.width + 6
    im.alpha_composite(txt, (x, (h - txt.height) // 2 + 1))
    return im


def emblem_frames(size, count=48):
    """The kit emblem with its vortex turning: `count` frames for one revolution."""
    src = kit_image("emblem", height=size)
    w, h = src.size
    cx, cy, r = w * 0.488, h * 0.495, w * 0.215
    frames = []
    box = (int(cx - r), int(cy - r), int(cx + r), int(cy + r))
    core = src.crop(box)
    mask = Image.new("L", core.size, 0)
    ImageDraw.Draw(mask).ellipse([1, 1, core.width - 2, core.height - 2], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(1.2))
    for i in range(count):
        im = src.copy()
        rot = core.rotate(-i * 360 / count, resample=Image.Resampling.BICUBIC)
        im.paste(rot, box[:2], mask)
        frames.append(im)
    return frames


def dropdown(width, height):
    src = kit("dropdown")
    if src is None:
        return pill(width, height)
    s = height / src.height
    nw = max(80, round(width / s))
    return _three_slice(src, nw, 16, 64).resize((width, height), Image.Resampling.LANCZOS)


def wordmark(text="OPENVANILLA", size=30):
    """Gold-gradient Cinzel wordmark with a dark rim, like the kit's title lettering."""
    f = font("display", size * 2)
    d0 = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    l, t, r, b = d0.textbbox((0, 0), text, font=f)
    pad = 10
    W, H = r - l + pad * 2, b - t + pad * 2
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).text((pad - l, pad - t), text, font=f, fill=255)
    rim = mask.filter(ImageFilter.MaxFilter(5))
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh.paste((0, 0, 0, 200), (0, 0), rim)
    out = Image.alpha_composite(out, sh.filter(ImageFilter.GaussianBlur(3)))
    out.paste((40, 24, 6, 255), (0, 0), rim)
    grad = _gradient(W, H, (255, 236, 170, 255), (190, 120, 30, 255))
    out.paste(grad, (0, 0), mask)
    return out.resize((W // 2, H // 2), Image.Resampling.LANCZOS)


def medallion(size, icon_name=None, letter=None, active=False, hover=False):
    """A round rail button: bronze ring, dark violet face, an icon or a letter."""
    S = 4
    W = size * S
    im = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    ring = (226, 178, 84) if active else ((190, 150, 76) if hover else (140, 108, 56))
    d.ellipse([0, 0, W - 1, W - 1], fill=(20, 14, 6, 255))
    d.ellipse([S, S, W - 1 - S, W - 1 - S], fill=ring + (255,))
    face = _gradient(W, W, (54, 40, 104, 255) if (active or hover) else (36, 28, 64, 255), (12, 8, 26, 255))
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).ellipse([W * 0.11, W * 0.11, W * 0.89, W * 0.89], fill=255)
    im.paste(face, (0, 0), m)
    d = ImageDraw.Draw(im)
    d.ellipse([W * 0.11, W * 0.11, W * 0.89, W * 0.89], outline=(0, 0, 0, 180), width=S)
    out = im.resize((size, size), Image.Resampling.LANCZOS)
    col = "#f3d179" if active else ("#eadbb4" if hover else "#bda876")
    if icon_name:
        ic = icon(icon_name, int(size * 0.48), col)
        out.alpha_composite(ic, ((size - ic.width) // 2, (size - ic.height) // 2))
    elif letter:
        dd = ImageDraw.Draw(out)
        dd.text((size / 2, size / 2 + 1), letter[:1].upper(), font=font("display", int(size * 0.44)), anchor="mm", fill=_hex(col))
    return out


def thumb(src_path, w, h, focus=(0.5, 0.5)):
    """A framed thumbnail cut from one of the background frames, for the news cards."""
    try:
        im = Image.open(src_path).convert("RGBA")
    except OSError:
        return Image.new("RGBA", (w, h), (20, 14, 30, 255))
    scale = max(w / im.width, h / im.height) * 2.2
    im = im.resize((round(im.width * scale), round(im.height * scale)), Image.Resampling.LANCZOS)
    cx, cy = int(im.width * focus[0]), int(im.height * focus[1])
    x0 = max(0, min(im.width - w, cx - w // 2))
    y0 = max(0, min(im.height - h, cy - h // 2))
    im = im.crop((x0, y0, x0 + w, y0 + h))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w - 1, h - 1], outline=(150, 116, 52, 255), width=2)
    d.rectangle([2, 2, w - 3, h - 3], outline=(0, 0, 0, 160), width=1)
    return im
