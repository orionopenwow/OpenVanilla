"""Open Vanilla's own logo: the portal "O" emblem from the UI kit beside Cinzel lettering in silver
and ice blue with a violet glow. Deliberately not the WoW look (no gold block letters, no frame)."""
import sys

# Retired 2026-10-17: the logo is now the Open Vanilla badge. Running this would put the old
# pre-rename lettering back into launcher/assets/launcher/logo_openvanilla.png.
# Use tools/make_openvanilla_logos.py instead. Pass --force to run the old generator anyway.
if __name__ == "__main__" and "--force" not in sys.argv:
    sys.exit("make_logo.py is retired: run tools/make_openvanilla_logos.py (or pass --force).")
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

FONTS = "/mnt/user-data/uploads/OpenVanilla/launcher/assets/launcher/fonts/"
EMBLEM = "/mnt/user-data/uploads/OpenVanilla/launcher/assets/launcher/kit/emblem.png"


def gradient(size, top, bottom):
    w, h = size
    g = Image.new("RGBA", size)
    px = g.load()
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(w):
            px[x, y] = c
    return g


def text_layer(size, xy, text, font):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).text(xy, text, font=font, fill=255)
    return m


def logo(W, H):
    S = 4  # supersample
    w, h = W * S, H * S
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    emb = Image.open(EMBLEM).convert("RGBA")
    es = round(h * 0.66)
    emb = emb.resize((es, es), Image.Resampling.LANCZOS)
    ex, ey = round(h * 0.03), (h - es) // 2

    big = ImageFont.truetype(FONTS + "Cinzel-Bold.ttf", round(h * 0.52))
    small = ImageFont.truetype(FONTS + "Cinzel-SemiBold.ttf", round(h * 0.13))
    word = "Open Vanilla"
    tx = ex + es + round(h * 0.03)
    bbox = big.getbbox(word)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    # Fit the word to the space right of the emblem.
    room = w - tx - round(h * 0.02)
    if tw > room:
        big = ImageFont.truetype(FONTS + "Cinzel-Bold.ttf", round(h * 0.52 * room / tw))
        bbox = big.getbbox(word)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    ty = round(h * 0.47) - th // 2 - bbox[1] - round(h * 0.05)
    mask = text_layer((w, h), (tx, ty), word, big)

    # violet glow, a dark stroke, then the silver-to-ice fill
    glow = Image.new("RGBA", (w, h), (123, 92, 255, 0))
    glow.putalpha(mask.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(h * 0.05)))
    out = Image.alpha_composite(out, glow)
    stroke = Image.new("RGBA", (w, h), (10, 8, 30, 0))
    stroke.putalpha(mask.filter(ImageFilter.MaxFilter(13)))
    out = Image.alpha_composite(out, stroke)
    fill = gradient((w, h), (246, 250, 255), (122, 170, 255))
    fill.putalpha(mask)
    out = Image.alpha_composite(out, fill)

    tag = "B R O W S E R   R P G"
    sb = small.getbbox(tag)
    if sb[2] - sb[0] > tw:  # never wider than the word above it
        small = ImageFont.truetype(FONTS + "Cinzel-SemiBold.ttf", round(h * 0.13 * tw / (sb[2] - sb[0])))
        sb = small.getbbox(tag)
    sx = tx + (tw - (sb[2] - sb[0])) // 2
    sy = ty + bbox[3] + round(h * 0.05)
    tmask = text_layer((w, h), (sx, sy), tag, small)
    tstroke = Image.new("RGBA", (w, h), (10, 8, 30, 0))
    tstroke.putalpha(tmask.filter(ImageFilter.MaxFilter(7)))
    out = Image.alpha_composite(out, tstroke)
    tfill = Image.new("RGBA", (w, h), (201, 184, 255, 0))
    tfill.putalpha(tmask)
    out = Image.alpha_composite(out, tfill)

    # emblem glow then the emblem
    eg = Image.new("RGBA", (w, h), (90, 120, 255, 0))
    em = Image.new("L", (w, h), 0)
    em.paste(emb.getchannel("A"), (ex, ey))
    eg.putalpha(em.filter(ImageFilter.GaussianBlur(h * 0.04)).point(lambda v: v * 0.7))
    out = Image.alpha_composite(out, eg)
    out.alpha_composite(emb, (ex, ey))
    return out.resize((W, H), Image.Resampling.LANCZOS)


def wordmark(W, H):
    """The lettering alone, centred, for places that already show the emblem (the launcher's
    rail): same fill, stroke and glow as the full logo."""
    S = 4
    w, h = W * S, H * S
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    word, tag = "OpenVanilla", "B R O W S E R   R P G"
    size = round(h * 0.42)
    big = ImageFont.truetype(FONTS + "Cinzel-Bold.ttf", size)
    bb = big.getbbox(word)
    room = w * 0.92
    if bb[2] - bb[0] > room:
        big = ImageFont.truetype(FONTS + "Cinzel-Bold.ttf", round(size * room / (bb[2] - bb[0])))
        bb = big.getbbox(word)
    tw = bb[2] - bb[0]
    small = ImageFont.truetype(FONTS + "Cinzel-SemiBold.ttf", round(h * 0.13))
    sb = small.getbbox(tag)
    if sb[2] - sb[0] > tw:
        small = ImageFont.truetype(FONTS + "Cinzel-SemiBold.ttf", round(h * 0.13 * tw / (sb[2] - sb[0])))
        sb = small.getbbox(tag)
    total = (bb[3] - bb[1]) + round(h * 0.06) + (sb[3] - sb[1])
    ty = (h - total) // 2 - bb[1]
    tx = (w - tw) // 2 - bb[0]
    mask = text_layer((w, h), (tx, ty), word, big)
    glow = Image.new("RGBA", (w, h), (123, 92, 255, 0))
    glow.putalpha(mask.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(h * 0.05)))
    out = Image.alpha_composite(out, glow)
    stroke = Image.new("RGBA", (w, h), (10, 8, 30, 0))
    stroke.putalpha(mask.filter(ImageFilter.MaxFilter(13)))
    out = Image.alpha_composite(out, stroke)
    fill = gradient((w, h), (246, 250, 255), (122, 170, 255))
    fill.putalpha(mask)
    out = Image.alpha_composite(out, fill)
    sx = (w - (sb[2] - sb[0])) // 2 - sb[0]
    sy = ty + bb[3] + round(h * 0.06) - sb[1]
    tmask = text_layer((w, h), (sx, sy), tag, small)
    tstroke = Image.new("RGBA", (w, h), (10, 8, 30, 0))
    tstroke.putalpha(tmask.filter(ImageFilter.MaxFilter(7)))
    out = Image.alpha_composite(out, tstroke)
    tfill = Image.new("RGBA", (w, h), (201, 184, 255, 0))
    tfill.putalpha(tmask)
    out = Image.alpha_composite(out, tfill)
    return out.resize((W, H), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    logo(512, 256).save(sys.argv[1])
    wordmark(360, 208).save(sys.argv[2])  # the launcher draws it 104 px tall
