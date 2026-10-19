"""Generates the tip-jar art in the same night-sky style as starfall_giving / orion_caretaker.
Outputs (webp): support_jar.webp (920x340), support_sigil.webp (160x160, alpha), support_strip.webp (1600x220)."""
import math, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
SS = 2
rng = np.random.default_rng(11)
GOLD, GOLD_HI, GOLD_LO = (233, 196, 106), (255, 236, 176), (150, 111, 44)
ORION = [(0.00, 0.00), (0.42, -0.06), (0.52, 0.30), (0.30, 0.52), (0.40, 0.56), (0.50, 0.58), (0.20, 0.95), (0.70, 0.95)]
ORION_E = [(0, 1), (1, 2), (2, 5), (0, 3), (3, 4), (4, 5), (3, 6), (5, 7)]


def sky(w, h, left=(40, 22, 70), right=(18, 20, 60), glow=None):
    x = np.linspace(0, 1, w)[None, :, None]
    y = np.linspace(0, 1, h)[:, None, None]
    a, b = np.array(left, float), np.array(right, float)
    img = a * (1 - x) + b * x
    img = img * (1.05 - 0.35 * y)
    if glow:
        gx, gy, gr, gc = glow
        d = np.sqrt((x * w - gx) ** 2 + (y * h - gy) ** 2) / gr
        img += np.array(gc, float) * np.exp(-d ** 2)[..., None] if d.ndim == 2 else np.array(gc, float) * np.exp(-d ** 2)
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(im, "RGBA")
    for _ in range(int(w * h / 900)):
        sx, sy = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.choice([0.6, 0.9, 1.3, 2.0], p=[.5, .3, .15, .05]) * SS
        al = int(rng.uniform(90, 255))
        d.ellipse((sx - r, sy - r, sx + r, sy + r), fill=(255, 255, 255, al))
    return im


def soft(im, shape_fn, blur, color, alpha=255):
    lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
    shape_fn(ImageDraw.Draw(lay), color + (alpha,))
    lay = lay.filter(ImageFilter.GaussianBlur(blur))
    im.alpha_composite(lay) if im.mode == "RGBA" else im.paste(lay, (0, 0), lay)


def sparkle(d, x, y, r, col=(255, 255, 255, 255)):
    pts = []
    for i in range(8):
        a = i * math.pi / 4
        rr = r if i % 2 == 0 else r * 0.22
        pts.append((x + rr * math.sin(a), y - rr * math.cos(a)))
    d.polygon(pts, fill=col)


def constellation(im, x0, y0, s, alpha=170):
    d = ImageDraw.Draw(im, "RGBA")
    P = [(x0 + px * s, y0 + py * s) for px, py in ORION]
    for a, b in ORION_E:
        d.line((P[a], P[b]), fill=(230, 230, 255, alpha), width=max(1, SS))
    for x, y in P:
        r = 3.2 * SS
        d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 255))


def trail(im, pts, width=3):
    lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    d.line(pts, fill=(255, 245, 225, 200), width=width * SS, joint="curve")
    glow = lay.filter(ImageFilter.GaussianBlur(5 * SS))
    im.paste(glow, (0, 0), glow)
    im.paste(lay, (0, 0), lay)
    d2 = ImageDraw.Draw(im, "RGBA")
    for i in range(0, len(pts), 3):
        x, y = pts[i]
        d2.ellipse((x - 1.6 * SS, y - 1.6 * SS, x + 1.6 * SS, y + 1.6 * SS), fill=(255, 250, 230, 255))


def curve(a, b, lift, n=60):
    (x0, y0), (x1, y1) = a, b
    cx, cy = (x0 + x1) / 2, min(y0, y1) - lift
    return [((1 - t) ** 2 * x0 + 2 * (1 - t) * t * cx + t * t * x1, (1 - t) ** 2 * y0 + 2 * (1 - t) * t * cy + t * t * y1)
            for t in np.linspace(0, 1, n)]


def hexagon(cx, cy, r):
    return [(cx + r * math.cos(math.pi / 6 + i * math.pi / 3), cy + r * math.sin(math.pi / 6 + i * math.pi / 3)) for i in range(6)]


def gem(im, cx, cy, r, col, lit=True):
    soft(im, lambda d, c: d.ellipse((cx - r * 1.8, cy - r * 1.8, cx + r * 1.8, cy + r * 1.8), fill=c), 10 * SS, col, 150 if lit else 60)
    d = ImageDraw.Draw(im, "RGBA")
    d.polygon(hexagon(cx, cy, r), fill=(20, 16, 40, 255), outline=col + (255,), width=3 * SS)
    d.polygon(hexagon(cx, cy, r * 0.62), outline=col + (200,), width=2 * SS)
    d.ellipse((cx - r * .28, cy - r * .28, cx + r * .28, cy + r * .28), fill=(255, 255, 255, 255 if lit else 120))


def jar(im, cx, by, w, h):
    """A gold-rimmed glass jar full of starlight, sitting at baseline by."""
    top = by - h
    lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    body = (cx - w / 2, top + h * .16, cx + w / 2, by)
    # starlight fill (gradient inside the body)
    fill = Image.new("RGBA", im.size, (0, 0, 0, 0))
    fd = ImageDraw.Draw(fill)
    level = top + h * .38
    for yy in range(int(level), int(by)):
        k = (yy - level) / (by - level)
        fd.line((cx - w / 2, yy, cx + w / 2, yy), fill=(int(255 - 40 * k), int(214 - 70 * k), int(140 - 60 * k), int(210 - 40 * k)))
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(body, radius=w * .2, fill=255)
    halo = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse((cx - w * 1.3, by - h * 1.1, cx + w * 1.3, by + h * .25), fill=(255, 190, 100, 120))
    halo = halo.filter(ImageFilter.GaussianBlur(40 * SS))
    im.paste(halo, (0, 0), halo)
    im.paste(fill, (0, 0), Image.composite(fill.getchannel("A"), Image.new("L", im.size, 0), mask))
    # glass
    d.rounded_rectangle(body, radius=w * .2, fill=(170, 160, 255, 34), outline=(225, 225, 255, 190), width=3 * SS)
    d.line((cx - w * .36, top + h * .3, cx - w * .36, by - h * .12), fill=(255, 255, 255, 110), width=6 * SS)
    # neck + gold lid
    d.rounded_rectangle((cx - w * .34, top + h * .04, cx + w * .34, top + h * .2), radius=8 * SS, fill=(160, 150, 240, 40),
                        outline=(225, 225, 255, 170), width=2 * SS)
    d.rounded_rectangle((cx - w * .4, top - h * .04, cx + w * .4, top + h * .08), radius=10 * SS, fill=GOLD_LO + (255,),
                        outline=GOLD + (255,), width=3 * SS)
    d.line((cx - w * .32, top + h * .005, cx + w * .32, top + h * .005), fill=GOLD_HI + (255,), width=2 * SS)
    im.paste(lay, (0, 0), lay)
    d = ImageDraw.Draw(im, "RGBA")
    for _ in range(26):  # stars inside the light
        x = rng.uniform(cx - w * .38, cx + w * .38)
        y = rng.uniform(level + 8 * SS, by - 10 * SS)
        sparkle(d, x, y, rng.uniform(3, 8) * SS, (255, 255, 255, int(rng.uniform(150, 255))))
    for _ in range(18):  # motes rising out of the jar
        x = cx + rng.normal(0, w * .25)
        y = top - rng.uniform(10, h * .9)
        sparkle(d, x, y, rng.uniform(3, 9) * SS, (255, 220, 150, int(rng.uniform(120, 240))))


def save(im, path, size):
    im.convert("RGBA" if path.endswith("sigil.webp") else "RGB").resize(size, Image.LANCZOS).save(path, quality=88, method=6)


# 1. Tip jar header: jar at right of centre, five level gems climbing to it, Orion overhead.
W, H = 920 * SS, 340 * SS
im = sky(W, H, (46, 24, 78), (16, 20, 58), (W * .66, H * .62, W * .3, (110, 60, 40))).convert("RGBA")
constellation(im, W * .80, H * .10, 150 * SS, 150)
cols = [(96, 165, 250), (167, 139, 250), (233, 196, 106), (240, 138, 106), (110, 231, 183)]
gx = [W * .08, W * .19, W * .30, W * .41, W * .52]
gy = [H * .80, H * .70, H * .60, H * .50, H * .40]
for i in range(4):
    trail(im, curve((gx[i], gy[i]), (gx[i + 1], gy[i + 1]), 26 * SS), 2)
trail(im, curve((gx[4], gy[4]), (W * .64, H * .30), 40 * SS), 2)
for i in range(5):
    gem(im, gx[i], gy[i], 18 * SS, cols[i], lit=i < 1)
jar(im, W * .70, H * .90, 150 * SS, 220 * SS)
save(im, f"{OUT}/support_jar.webp", (920, 340))

# 2. Orion sigil for the gentle prompt: gold hexagon with sparkles, on transparent.
S = 160 * SS
im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
soft(im, lambda d, c: d.ellipse((S * .1, S * .1, S * .9, S * .9), fill=c), 14 * SS, (150, 90, 230), 170)
d = ImageDraw.Draw(im, "RGBA")
d.ellipse((S * .06, S * .34, S * .94, S * .66), outline=(150, 190, 255, 200), width=2 * SS)
d.polygon(hexagon(S / 2, S / 2, S * .34), fill=(28, 20, 62, 255), outline=GOLD + (255,), width=5 * SS)
d.polygon(hexagon(S / 2, S / 2, S * .27), outline=GOLD_LO + (255,), width=2 * SS)
sparkle(d, S * .5, S * .48, S * .14)
sparkle(d, S * .36, S * .58, S * .07)
sparkle(d, S * .63, S * .38, S * .06)
for a in (0.3, 3.5):
    d.ellipse((S / 2 + S * .44 * math.cos(a) - 5 * SS, S / 2 + S * .16 * math.sin(a) - 5 * SS,
               S / 2 + S * .44 * math.cos(a) + 5 * SS, S / 2 + S * .16 * math.sin(a) + 5 * SS), fill=(190, 215, 255, 255))
save(im, f"{OUT}/support_sigil.webp", (160, 160))

# 3. Community strip: a faint constellation of contributor stars linked by light, fading at the edges.
W, H = 1600 * SS, 220 * SS
im = sky(W, H, (14, 16, 30), (12, 14, 28), (W * .5, H * .5, W * .35, (40, 26, 70))).convert("RGBA")
nodes = [(W * x, H * (0.5 + 0.28 * math.sin(x * 11))) for x in np.linspace(0.06, 0.94, 13)]
for a, b in zip(nodes, nodes[1:]):
    trail(im, curve(a, b, 14 * SS, 30), 1)
d = ImageDraw.Draw(im, "RGBA")
for i, (x, y) in enumerate(nodes):
    soft(im, lambda dd, c: dd.ellipse((x - 26 * SS, y - 26 * SS, x + 26 * SS, y + 26 * SS), fill=c), 10 * SS, GOLD, 90)
    sparkle(ImageDraw.Draw(im, "RGBA"), x, y, (11 if i % 3 == 0 else 7) * SS)
fade = np.ones((H, W), np.float32)
xs = np.linspace(0, 1, W)
fade *= np.clip(np.minimum(xs, 1 - xs) / 0.18, 0, 1)[None, :]
arr = np.asarray(im).astype(np.float32)
bg = np.array([11, 15, 23], np.float32)
arr[..., :3] = arr[..., :3] * fade[..., None] + bg * (1 - fade[..., None])
save(Image.fromarray(arr.astype(np.uint8)), f"{OUT}/support_strip.webp", (1600, 220))
print("ok")
