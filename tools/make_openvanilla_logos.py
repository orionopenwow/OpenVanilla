#!/usr/bin/env python3
"""Write the Open Vanilla badge into every file that held the Open Vanilla logo.

Source: assets/branding/openvanilla_badge.png (the badge cut out of its background).
File names stay the same so pages, the launcher and the realm keep pointing at them
while the rename is in progress.

  tight  the badge alone at the old file's height (places that size the logo by height)
  fit    the old canvas size kept, the badge centred at full height on transparency
         (places that size the logo by width or squash it into a fixed box)
"""
import pathlib
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "assets/branding/openvanilla_badge.png"

TIGHT = [  # path, height
    ("www/assets/openvanilla_logo_nav.png", 194),
    ("realm/www/ow-corner-logo.webp", 158),
    ("realm/www/ow-corner-logo@2x.webp", 317),
    ("docs/queue/a/ow-corner-logo@2x.webp", 317),
    ("launcher/assets/launcher/logo_hero.png", 227),
]
FIT = [  # path, (w, h)
    ("www/assets/openvanilla_logo_hero.png", (705, 399)),
    ("assets/openvanilla_logo_hero.png", (705, 399)),
    ("www/assets/openvanilla_logo.png", (980, 555)),
    ("assets/openvanilla_logo_proportional.png", (185, 105)),
    ("launcher/assets/launcher/logo.png", (185, 105)),
    ("launcher/assets/launcher/logo_openvanilla.png", (360, 208)),
    ("assets/crop_logo.png", (380, 73)),
]
LOADING = ("www/assets/loading/openvanilla_logo.jpg", (1024, 572))
FAVICON = "www/favicon.ico"


def scaled(badge, h):
    return badge.resize((round(badge.width * h / badge.height), h), Image.Resampling.LANCZOS)


def save(im, rel):
    p = ROOT / rel
    if p.suffix == ".webp":
        im.save(p, "WEBP", quality=90, method=6)
    elif p.suffix == ".jpg":
        im.convert("RGB").save(p, "JPEG", quality=90, optimize=True)
    else:
        im.save(p, "PNG", optimize=True)


def main():
    badge = Image.open(SRC).convert("RGBA")
    for rel, h in TIGHT:
        save(scaled(badge, h), rel)
    for rel, (w, h) in FIT:
        b = scaled(badge, h)
        if b.width > w:
            b = b.resize((w, round(b.height * w / b.width)), Image.Resampling.LANCZOS)
        c = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        c.alpha_composite(b, ((w - b.width) // 2, (h - b.height) // 2))
        save(c, rel)
    rel, (w, h) = LOADING
    c = Image.new("RGBA", (w, h), (11, 13, 19, 255))
    b = scaled(badge, round(h * 0.86))
    c.alpha_composite(b, ((w - b.width) // 2, (h - b.height) // 2))
    save(c, rel)
    sq = Image.new("RGBA", (max(badge.size),) * 2, (0, 0, 0, 0))
    sq.alpha_composite(badge, ((sq.width - badge.width) // 2, (sq.height - badge.height) // 2))
    sq.resize((256, 256), Image.Resampling.LANCZOS).save(ROOT / FAVICON, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64)])
    print("wrote", len(TIGHT) + len(FIT) + 2, "files")


if __name__ == "__main__":
    main()
