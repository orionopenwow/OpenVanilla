#!/usr/bin/env python3
"""PNG → BLP2 (palettized, 8-bit alpha, full mip chain): the texture format the 1.12 client reads.

    python3 png_to_blp.py in.png out.blp

Width and height must be powers of two. Our own art only — never convert Blizzard's files.
"""
import struct, sys
from PIL import Image


def mips(im):
    out = [im]
    while im.width > 1 or im.height > 1:
        im = im.resize((max(1, im.width // 2), max(1, im.height // 2)), Image.Resampling.LANCZOS)
        out.append(im)
    return out[:16]


def encode(im):
    im = im.convert("RGBA")
    w, h = im.size
    if w & (w - 1) or h & (h - 1):
        raise SystemExit(f"{w}x{h}: BLP needs power-of-two sides")
    # One palette for the whole chain, from the top level's colours.
    pal_img = im.convert("RGB").quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    palette = pal_img.getpalette()[: 256 * 3]
    palette += [0] * (256 * 3 - len(palette))
    levels = []
    for m in mips(im):
        idx = m.convert("RGB").quantize(palette=pal_img, dither=Image.Dither.NONE).tobytes()
        alpha = m.getchannel("A").tobytes()
        levels.append(idx + alpha)
    header_size = 4 + 4 + 4 + 4 + 4 + 64 + 64 + 1024  # magic, type, flags(4 bytes), w, h, offsets, sizes, palette
    offsets, sizes, at = [], [], header_size
    for lv in levels:
        offsets.append(at)
        sizes.append(len(lv))
        at += len(lv)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    head = b"BLP2" + struct.pack("<I", 1)                     # type 1: not JPEG
    head += struct.pack("<BBBB", 1, 8, 8, 1)                  # palette, alpha depth 8, alpha type, mips
    head += struct.pack("<II", w, h)
    head += struct.pack("<16I", *offsets) + struct.pack("<16I", *sizes)
    head += b"".join(struct.pack("<BBBB", palette[i * 3 + 2], palette[i * 3 + 1], palette[i * 3], 255) for i in range(256))
    assert len(head) == header_size
    return head + b"".join(levels)


if __name__ == "__main__":
    data = encode(Image.open(sys.argv[1]))
    open(sys.argv[2], "wb").write(data)
    print(sys.argv[2], len(data), "bytes")
