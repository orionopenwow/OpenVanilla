"""Write BLP2 (palette + 8-bit alpha + mipmaps), the format of Open Vanilla's Interface\\ClassicPlus art."""
import struct
from PIL import Image

def write_blp(img, path):
    img = img.convert("RGBA")
    w, h = img.size
    pal_img = img.convert("RGB").quantize(colors=256, method=Image.Quantize.MEDIANCUT)
    palette = pal_img.getpalette()[:768]
    palette += [0] * (768 - len(palette))
    levels = []
    cw, ch, cur = w, h, img
    while True:
        q = cur.convert("RGB").quantize(palette=pal_img, dither=Image.Dither.NONE)
        levels.append(bytes(q.getdata()) + bytes(cur.getchannel("A").getdata()))
        if cw == 1 and ch == 1 or len(levels) == 16:
            break
        cw, ch = max(1, cw // 2), max(1, ch // 2)
        cur = img.resize((cw, ch), Image.LANCZOS)
    head = b"BLP2" + struct.pack("<I4B2I", 1, 1, 8, 8, 1, w, h)
    offs, sizes, pos = [], [], 148 + 1024
    for lv in levels:
        offs.append(pos); sizes.append(len(lv)); pos += len(lv)
    offs += [0] * (16 - len(offs)); sizes += [0] * (16 - len(sizes))
    pal = b"".join(struct.pack("<4B", palette[i * 3 + 2], palette[i * 3 + 1], palette[i * 3], 0) for i in range(256))
    with open(path, "wb") as f:
        f.write(head + struct.pack("<16I", *offs) + struct.pack("<16I", *sizes) + pal + b"".join(levels))
