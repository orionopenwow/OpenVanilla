"""render.py - draws the windows dumped by shoot.lua as PNGs, the way the 1.12 client lays them out.

    python3 devkit/sim/render/render.py <repo> <dir of .json> [--scale 2] [--full]

Anchors are resolved like the client does (each point pins one edge or the centre on each axis;
the size fills in the rest). Drawn: backdrops (tiled background + 8-piece edge), textures with
tex coords / vertex colour / desaturation, colour fills, button states (Normal, Checked, Disabled,
locked Highlight), the stock templates the addons use (close button, check box), font strings with
|c colour codes, wrapping and justification, and placeholders for 3D models (the model can't be
drawn here: the items it wears are shown as icons instead). Textures come from <repo>/Data
(BLP or TGA, any case). Not drawn: animations, blend modes, item models, the 3D world.
Needs Pillow.
"""
import json
import math
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont, ImageOps

STRATA = ["BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP"]
LAYERS = {"BACKGROUND": 0, "BORDER": 1, "ARTWORK": 2, "OVERLAY": 3, "HIGHLIGHT": 4}
GOLD, WHITE, GREY = (1, 0.82, 0), (1, 1, 1), (0.5, 0.5, 0.5)
FONTS = {  # name: (size, colour, kind)
    "GameFontNormal": (12, GOLD, "b"), "GameFontNormalSmall": (10, GOLD, "b"),
    "GameFontNormalLarge": (16, GOLD, "b"), "GameFontHighlight": (12, WHITE, "b"),
    "GameFontHighlightSmall": (10, WHITE, "b"), "GameFontHighlightLarge": (16, WHITE, "b"),
    "GameFontDisable": (12, GREY, "b"), "GameFontDisableSmall": (10, GREY, "b"),
    "GameFontGreen": (12, (0.1, 1, 0.1), "b"), "GameFontRed": (12, (1, 0.1, 0.1), "b"),
    "GameFontWhite": (12, WHITE, "b"), "NumberFontNormal": (14, WHITE, "o"),
    "NumberFontNormalSmall": (12, WHITE, "o"), "ChatFontNormal": (14, WHITE, "r"),
    "SystemFont": (12, WHITE, "b"), "GameFontBlack": (12, (0, 0, 0), "b"),
}
FONT_FILES = {
    "b": ["/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed-Bold.ttf", "DejaVuSans-Bold.ttf"],
    "o": ["/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed-Bold.ttf", "DejaVuSans-Bold.ttf"],
    "r": ["/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed.ttf", "DejaVuSans.ttf"],
}
H_OF = {"TOPLEFT": "L", "LEFT": "L", "BOTTOMLEFT": "L", "TOP": "C", "CENTER": "C", "BOTTOM": "C",
        "TOPRIGHT": "R", "RIGHT": "R", "BOTTOMRIGHT": "R"}
V_OF = {"TOPLEFT": "T", "TOP": "T", "TOPRIGHT": "T", "LEFT": "C", "CENTER": "C", "RIGHT": "C",
        "BOTTOMLEFT": "B", "BOTTOM": "B", "BOTTOMRIGHT": "B"}


class Art:
    """Finds and caches textures under <repo>/Data, case-insensitively."""

    def __init__(self, repo):
        self.root = os.path.join(repo, "Data")
        self.index = {}
        for dirpath, _dirs, files in os.walk(self.root, followlinks=True):
            rel = os.path.relpath(dirpath, self.root).replace("\\", "/").lower()
            for f in files:
                self.index[(rel + "/" + f.lower()) if rel != "." else f.lower()] = os.path.join(dirpath, f)
        self.cache = {}
        self.missing = set()

    def get(self, path):
        if not path:
            return None
        key = path.replace("\\", "/").lower()
        if key in self.cache:
            return self.cache[key]
        img = None
        cands = [key] if re.search(r"\.(blp|tga|png)$", key) else [key + ".blp", key + ".tga", key + ".png"]
        for c in cands:
            f = self.index.get(c)
            if f:
                try:
                    img = Image.open(f).convert("RGBA")
                except Exception:
                    img = None
                break
        if img is None:
            self.missing.add(path)
        self.cache[key] = img
        return img


def ImageChops_mul(a, b):
    from PIL import ImageChops
    return ImageChops.multiply(a, b)


def font_for(kind, size):
    for f in FONT_FILES.get(kind, FONT_FILES["b"]):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            continue
    return ImageFont.load_default()


def parse_colored(text, base):
    """'|cffRRGGBBtext|r' -> [(text, (r,g,b))]; drops |T..|t textures and |H..|h link wrappers."""
    text = re.sub(r"\|T[^|]*\|t", "", text or "")
    text = re.sub(r"\|H[^|]*\|h", "", text).replace("|h", "")
    out, color, i = [], base, 0
    for m in re.finditer(r"\|c([0-9a-fA-F]{8})|\|r", text):
        if m.start() > i:
            out.append((text[i:m.start()], color))
        if m.group(1):
            h = m.group(1)
            color = (int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, int(h[6:8], 16) / 255)
        else:
            color = base
        i = m.end()
    if i < len(text):
        out.append((text[i:], color))
    return out


class Scene:
    def __init__(self, data, art, scale):
        self.art = art
        self.s = scale
        self.sw, self.sh = data["screen"]
        self.objs = {o["id"]: o for o in data["objects"]}
        self.items = data.get("items") or {}
        if isinstance(self.items, list):
            self.items = {}
        self.rects = {}
        self.order = {o["id"]: i for i, o in enumerate(data["objects"])}
        self.notes = []

    # ── layout ──
    def font_of(self, o):
        name = o.get("font") or "GameFontNormal"
        po = self.objs.get(o.get("parent")) or {}
        if not o.get("font") and po.get("fontString") == o["id"] and not po.get("enabled", True):
            name = "GameFontDisable"
        size, color, kind = FONTS.get(name, FONTS["GameFontNormal"])
        fp = o.get("fontPath")
        if fp and len(fp) > 1 and fp[1]:
            size = fp[1]
        return size, color, kind

    def text_size(self, o):
        size, _c, kind = self.font_of(o)
        f = font_for(kind, size)
        lines = re.sub(r"\|c[0-9a-fA-F]{8}|\|r|\|T[^|]*\|t|\|H[^|]*\|h|\|h", "", o.get("text") or "").split("\n")
        w = max((f.getlength(l) for l in lines), default=0)
        return w, len(lines) * (size + 2)

    def escale(self, oid):
        """A frame's effective scale (SetScale multiplies down the parent chain; regions take
        their frame's)."""
        e, o = 1.0, self.objs.get(oid)
        while o:
            if not o.get("region"):
                e *= o.get("scale") or 1
            o = self.objs.get(o.get("parent"))
        return e

    def rect(self, oid):
        """(left, right, bottom, top) in screen units, y up; None when it can't be placed."""
        if oid == "UIParent":
            return (0, self.sw, 0, self.sh)
        if oid in self.rects:
            return self.rects[oid]
        self.rects[oid] = None              # cycles
        o = self.objs[oid]
        pts = o.get("points") or []
        w, h = o.get("w") or 0, o.get("h") or 0
        parent = o.get("parent")
        if o["kind"] == "FontString" and (w == 0 or h == 0):
            tw, th = self.text_size(o)
            w = w or tw
            h = h or th
        es = self.escale(oid)              # sizes and point offsets are in the frame's own scale
        w, h = w * es, h * es
        if not pts:
            r = self.unanchored(o, parent, w, h)
            self.rects[oid] = r
            return r
        hz, vt = {}, {}
        for p, rel, rp, x, y in pts:
            rr = self.rect(parent if rel == "parent" else rel) if (rel != "parent" or parent) else self.rect("UIParent")
            if rr is None:
                continue
            l, r_, b, t = rr
            ax = {"L": l, "C": (l + r_) / 2, "R": r_}[H_OF.get(rp, "C")]
            ay = {"T": t, "C": (b + t) / 2, "B": b}[V_OF.get(rp, "C")]
            hz[H_OF.get(p, "C")] = ax + x * es
            vt[V_OF.get(p, "C")] = ay + y * es
        if not hz or not vt:
            return None
        if "L" in hz and "R" in hz:
            L, R = hz["L"], hz["R"]
        elif "L" in hz:
            L, R = hz["L"], hz["L"] + w
        elif "R" in hz:
            L, R = hz["R"] - w, hz["R"]
        else:
            L, R = hz["C"] - w / 2, hz["C"] + w / 2
        if "T" in vt and "B" in vt:
            B, T = vt["B"], vt["T"]
        elif "T" in vt:
            B, T = vt["T"] - h, vt["T"]
        elif "B" in vt:
            B, T = vt["B"], vt["B"] + h
        else:
            B, T = vt["C"] - h / 2, vt["C"] + h / 2
        r = (L, R, B, T)
        self.rects[oid] = r
        return r

    def unanchored(self, o, parent, w, h):
        """No points: button state textures and button text fill / centre in the button; a
        template check box's label sits to its right; anything else isn't drawn by the client."""
        if not parent:
            return None
        po = self.objs.get(parent)
        pr = self.rect(parent)
        if pr is None or po is None:
            return None
        if o["id"] == po.get("barTexture"):
            # a StatusBar's fill: as long as its value, from the left
            lo, hi, v = po.get("min") or 0, po.get("max") or 1, po.get("value") or 0
            frac = 0 if hi <= lo else max(0.0, min(1.0, (v - lo) / (hi - lo)))
            return (pr[0], pr[0] + (pr[1] - pr[0]) * frac, pr[2], pr[3])
        if o["id"] in (po.get("states") or {}).values():
            return pr
        if o["id"] == po.get("fontString"):
            cx, cy = (pr[0] + pr[1]) / 2, (pr[2] + pr[3]) / 2
            return (cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2)
        if po.get("template") == "UICheckButtonTemplate" and o["kind"] == "FontString":
            cy = (pr[2] + pr[3]) / 2
            return (pr[1] + 1, pr[1] + 1 + w, cy - h / 2, cy + h / 2)
        return None

    # ── visibility ──
    def visible(self, oid):
        o = self.objs.get(oid)
        while o:
            if not o.get("shown"):
                return False
            o = self.objs.get(o.get("parent"))
        return True

    def alpha(self, oid):
        a, o = 1.0, self.objs.get(oid)
        while o:
            a *= o.get("alpha", 1) if o.get("alpha") is not None else 1
            o = self.objs.get(o.get("parent"))
        return a

    def frame_of(self, o):
        return o if not o.get("region") else self.objs.get(o.get("parent"), o)

    # ── drawing ──
    def box(self, r):
        L, R, B, T = r
        s = self.s
        return (round(L * s), round((self.sh - T) * s), round(R * s), round((self.sh - B) * s))

    def paste(self, canvas, img, r, alpha=1.0, add=False):
        x0, y0, x1, y1 = self.box(r)
        if x1 <= x0 or y1 <= y0 or img is None:
            return
        im = img.resize((x1 - x0, y1 - y0), Image.BILINEAR)
        if alpha < 1:
            a = im.getchannel("A").point(lambda v: int(v * alpha))
            im.putalpha(a)
        # clip to the canvas
        cx0, cy0 = max(0, x0), max(0, y0)
        cx1, cy1 = min(canvas.width, x1), min(canvas.height, y1)
        if cx1 <= cx0 or cy1 <= cy0:
            return
        im = im.crop((cx0 - x0, cy0 - y0, cx1 - x0, cy1 - y0))
        if add:     # BlendMode ADD: dest + src * alpha (black adds nothing)
            from PIL import ImageChops
            a = im.getchannel("A")
            rgb = Image.composite(im.convert("RGB"), Image.new("RGB", im.size), a)
            base = canvas.crop((cx0, cy0, cx1, cy1))
            out = ImageChops.add(base.convert("RGB"), rgb)
            out.putalpha(base.getchannel("A"))
            canvas.paste(out, (cx0, cy0))
            return
        canvas.alpha_composite(im, (cx0, cy0))

    def tex_image(self, o):
        if o.get("color"):
            c = o["color"]
            return Image.new("RGBA", (4, 4), tuple(int(max(0, min(1, v)) * 255) for v in (c + [1])[:4])), False
        img = self.art.get(o.get("texture"))
        if img is None:
            return None, bool(o.get("texture"))
        tc = o.get("texcoord")
        if tc and (len(tc) == 4 or len(tc) == 8):
            if len(tc) == 4:
                l, r_, t, b = tc
                quad = [(l, t), (l, b), (r_, b), (r_, t)]
            else:   # ULx,ULy, LLx,LLy, URx,URy, LRx,LRy
                quad = [(tc[0], tc[1]), (tc[2], tc[3]), (tc[6], tc[7]), (tc[4], tc[5])]
            xs = [q[0] for q in quad]
            ys = [q[1] for q in quad]
            reps_x = max(1, math.ceil(max(xs + [1]) - min(xs + [0]) + 1e-6))
            reps_y = max(1, math.ceil(max(ys + [1]) - min(ys + [0]) + 1e-6))
            if reps_x > 1 or reps_y > 1:
                tiled = Image.new("RGBA", (img.width * reps_x, img.height * reps_y))
                for i in range(reps_x):
                    for j in range(reps_y):
                        tiled.paste(img, (i * img.width, j * img.height))
                img = tiled
                sx, sy = img.width / reps_x, img.height / reps_y
            else:
                sx, sy = img.width, img.height
            ox = -min(0, min(xs))
            oy = -min(0, min(ys))
            pts = []
            for qx, qy in quad:
                pts += [(qx + ox) * sx, (qy + oy) * sy]
            ow = max(1, int(abs(quad[3][0] - quad[0][0]) * sx + abs(quad[3][1] - quad[0][1]) * sy))
            oh = max(1, int(abs(quad[1][1] - quad[0][1]) * sy + abs(quad[1][0] - quad[0][0]) * sx))
            img = img.transform((max(ow, 1), max(oh, 1)), Image.QUAD, pts, Image.BILINEAR)
        if o.get("desat"):
            a = img.getchannel("A")
            img = ImageOps.grayscale(img.convert("RGB")).convert("RGBA")
            img.putalpha(a)
        v = o.get("vertex")
        if v:
            r, g, b, a = (v + [1, 1, 1, 1])[:4]
            ch = img.split()
            img = Image.merge("RGBA", (ch[0].point(lambda x: int(x * r)), ch[1].point(lambda x: int(x * g)),
                                       ch[2].point(lambda x: int(x * b)), ch[3].point(lambda x: int(x * a))))
        return img, False

    def tint(self, img, c):
        r, g, b, a = (list(c) + [1, 1, 1, 1])[:4]
        ch = img.split()
        return Image.merge("RGBA", (ch[0].point(lambda x: int(x * r)), ch[1].point(lambda x: int(x * g)),
                                    ch[2].point(lambda x: int(x * b)), ch[3].point(lambda x: int(x * a))))

    def panel_button(self, canvas, o, r, alpha):
        """UIPanelButtonTemplate: UI-Panel-Button-Up (or -Disabled) cut into a 12 px left cap, a
        stretched middle and a 12 px right cap, as FrameXML's UIPanelButtonTemplate does."""
        f = "Interface\\Buttons\\UI-Panel-Button-" + ("Up" if o.get("enabled", True) else "Disabled")
        img = self.art.get(f)
        if img is None:
            return
        W, H = img.size
        L, R, B, T = r
        cap = min(12, (R - L) / 2)
        def piece(l, rr):
            return img.crop((int(l * W), 0, int(rr * W), int(0.6875 * H)))
        self.paste(canvas, piece(0, 0.09375), (L, L + cap, B, T), alpha)
        self.paste(canvas, piece(0.09375, 0.53125), (L + cap, R - cap, B, T), alpha)
        self.paste(canvas, piece(0.53125, 0.625), (R - cap, R, B, T), alpha)

    def draw_backdrop(self, canvas, o, r, alpha):
        bd = o.get("backdrop")
        if not isinstance(bd, dict):
            return
        L, R, B, T = r
        ins = bd.get("insets") or {}
        bg = self.art.get(bd.get("bgFile"))
        col = o.get("backdropColor") or [1, 1, 1, 1]
        if bg is not None:
            ir = (L + ins.get("left", 0), R - ins.get("right", 0), B + ins.get("bottom", 0), T - ins.get("top", 0))
            x0, y0, x1, y1 = self.box(ir)
            if x1 > x0 and y1 > y0:
                if bd.get("tile"):
                    ts = max(1, int((bd.get("tileSize") or 16) * self.s))
                    t = bg.resize((ts, ts))
                    layer = Image.new("RGBA", (x1 - x0, y1 - y0))
                    for xx in range(0, x1 - x0, ts):
                        for yy in range(0, y1 - y0, ts):
                            layer.paste(t, (xx, yy))
                else:
                    layer = bg.resize((x1 - x0, y1 - y0))
                layer = self.tint(layer, [col[0], col[1], col[2], (col[3] if len(col) > 3 else 1) * alpha])
                canvas.alpha_composite(layer, (max(0, x0), max(0, y0)))
        edge = self.art.get(bd.get("edgeFile"))
        if edge is None:
            return
        es = bd.get("edgeSize") or 16
        bc = o.get("backdropBorder") or [1, 1, 1, 1]
        pw = edge.width // 8
        piece = [self.tint(edge.crop((i * pw, 0, (i + 1) * pw, edge.height)),
                           [bc[0], bc[1], bc[2], (bc[3] if len(bc) > 3 else 1) * alpha]) for i in range(8)]
        e = int(es * self.s)
        x0, y0, x1, y1 = self.box(r)
        if x1 - x0 < 2 * e or y1 - y0 < 2 * e:
            e = max(1, min((x1 - x0) // 2, (y1 - y0) // 2))

        def strip(img, w, h, vertical):
            out = Image.new("RGBA", (w, h))
            if vertical:
                t = img.resize((w, w))
                for yy in range(0, h, w):
                    out.paste(t, (0, yy))
            else:
                t = img.resize((h, h))
                for xx in range(0, w, h):
                    out.paste(t, (xx, 0))
            return out
        if y1 - y0 - 2 * e > 0:
            canvas.alpha_composite(strip(piece[0], e, y1 - y0 - 2 * e, True), (x0, y0 + e))
            canvas.alpha_composite(strip(piece[1], e, y1 - y0 - 2 * e, True), (x1 - e, y0 + e))
        if x1 - x0 - 2 * e > 0:
            canvas.alpha_composite(strip(piece[2].rotate(-90, expand=True), x1 - x0 - 2 * e, e, False), (x0 + e, y0))
            canvas.alpha_composite(strip(piece[3].rotate(-90, expand=True), x1 - x0 - 2 * e, e, False), (x0 + e, y1 - e))
        for i, (px, py) in zip(range(4, 8), [(x0, y0), (x1 - e, y0), (x0, y1 - e), (x1 - e, y1 - e)]):
            canvas.alpha_composite(piece[i].resize((e, e)), (px, py))

    def draw_text(self, canvas, o, r, alpha):
        text = o.get("text")
        if not text:
            return
        size, color, kind = self.font_of(o)
        tc = o.get("textColor")
        if tc:
            color = tuple(tc[:3])
        f = font_for(kind, int(size * self.s))
        x0, y0, x1, y1 = self.box(r)
        bounded = (o.get("w") or 0) > 0 or sum(1 for p in o.get("points") or [] if H_OF.get(p[0]) in ("L", "R")) >= 2
        maxw = (x1 - x0) if bounded else 10 ** 6
        lines = []
        for para in text.split("\n"):
            runs = parse_colored(para, color)
            words, cur, curw = [], [], 0
            for t, c in runs:
                for wd in re.split(r"(\s+)", t):
                    if wd:
                        words.append((wd, c))
            for wd, c in words:
                ww = f.getlength(wd)
                if cur and curw + ww > maxw and not wd.isspace():
                    lines.append(cur)
                    cur, curw = [], 0
                    if wd.isspace():
                        continue
                cur.append((wd, c))
                curw += ww
            lines.append(cur)
        lh = int((size + 2) * self.s)
        total = lh * len(lines)
        jv = (o.get("justifyV") or "MIDDLE").upper()
        y = y0 if jv == "TOP" else (y1 - total if jv == "BOTTOM" else (y0 + y1 - total) // 2)
        jh = (o.get("justifyH") or "CENTER").upper()
        # text goes on its own layer, then is blended: ImageDraw replaces pixels, alpha included
        pad = int(4 * self.s)
        lx0 = max(0, int(x0 - pad - (0 if bounded else 1500)))
        ly0 = max(0, int(y - pad))
        lx1 = min(canvas.width, int(x1 + pad + (0 if bounded else 1500)))
        ly1 = min(canvas.height, int(y + total + pad + lh))
        if lx1 <= lx0 or ly1 <= ly0:
            return
        layer = Image.new("RGBA", (lx1 - lx0, ly1 - ly0), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        y -= ly0
        for ln in lines:
            while ln and ln[-1][0].isspace():
                ln = ln[:-1]
            lw = sum(f.getlength(t) for t, _c in ln)
            x = (x0 if jh == "LEFT" else (x1 - lw if jh == "RIGHT" else (x0 + x1 - lw) / 2)) - lx0
            for t, c in ln:
                fill = tuple(int(max(0, min(1, v)) * 255) for v in c) + (int(255 * alpha),)
                sh = max(1, int(self.s))
                d.text((x + sh, y + sh), t, font=f, fill=(0, 0, 0, int(200 * alpha)))
                d.text((x, y), t, font=f, fill=fill)
                x += f.getlength(t)
            y += lh
        canvas.alpha_composite(layer, (lx0, ly0))

    # Where each kind of piece sits on the stand-in figure (fractions of the pane: x, y).
    BODY_SPOTS = {
        "INVTYPE_HEAD": [(0.5, 0.11)], "INVTYPE_SHOULDER": [(0.31, 0.22), (0.69, 0.22)],
        "INVTYPE_CLOAK": [(0.62, 0.30)], "INVTYPE_CHEST": [(0.5, 0.32)], "INVTYPE_ROBE": [(0.5, 0.32)],
        "INVTYPE_BODY": [(0.38, 0.38)], "INVTYPE_TABARD": [(0.5, 0.40)], "INVTYPE_WRIST": [(0.24, 0.43)],
        "INVTYPE_HAND": [(0.77, 0.50)], "INVTYPE_WAIST": [(0.5, 0.49)], "INVTYPE_LEGS": [(0.5, 0.66)],
        "INVTYPE_FEET": [(0.5, 0.91)], "INVTYPE_2HWEAPON": [(0.15, 0.62)], "INVTYPE_WEAPON": [(0.15, 0.62)],
        "INVTYPE_WEAPONMAINHAND": [(0.15, 0.62)], "INVTYPE_WEAPONOFFHAND": [(0.85, 0.62)],
        "INVTYPE_SHIELD": [(0.85, 0.62)], "INVTYPE_HOLDABLE": [(0.85, 0.62)],
        "INVTYPE_RANGED": [(0.86, 0.28)], "INVTYPE_RANGEDRIGHT": [(0.86, 0.28)], "INVTYPE_THROWN": [(0.86, 0.28)],
    }

    def figure(self, w, h):
        """A soft humanoid silhouette the size of the pane (the stand-in for the 3D body)."""
        from PIL import ImageFilter
        img = Image.new("RGBA", (w, h))
        d = ImageDraw.Draw(img)
        H = h * 0.92
        top = h * 0.04
        cx = w / 2
        col = (6, 5, 10, 150)
        def P(x, y):
            return (cx + x * H, top + y * H)
        d.ellipse([P(-0.065, 0.02), P(0.065, 0.17)], fill=col)                       # head
        d.polygon([P(-0.035, 0.15), P(0.035, 0.15), P(0.04, 0.2), P(-0.04, 0.2)], fill=col)
        d.polygon([P(-0.19, 0.2), P(0.19, 0.2), P(0.15, 0.5), P(-0.15, 0.5)], fill=col)  # torso
        d.polygon([P(-0.19, 0.2), P(-0.25, 0.22), P(-0.29, 0.52), P(-0.21, 0.53), P(-0.16, 0.3)], fill=col)
        d.polygon([P(0.19, 0.2), P(0.25, 0.22), P(0.29, 0.52), P(0.21, 0.53), P(0.16, 0.3)], fill=col)
        d.polygon([P(-0.15, 0.49), P(-0.01, 0.49), P(-0.035, 0.97), P(-0.12, 0.97)], fill=col)  # legs
        d.polygon([P(0.15, 0.49), P(0.01, 0.49), P(0.035, 0.97), P(0.12, 0.97)], fill=col)
        return img.filter(ImageFilter.GaussianBlur(max(1, int(h / 140))))

    def draw_model(self, canvas, o, r, alpha):
        x0, y0, x1, y1 = self.box(r)
        if x1 - x0 < 4 or y1 - y0 < 4:
            return
        items = [self.items.get(str(i), {}) for i in (o.get("model") or [])]
        big = (x1 - x0) > 160 * self.s
        if not big:
            icons = [it.get("icon") for it in items if it.get("icon")]
            if icons:
                img = self.art.get(icons[-1])
                if img is not None:
                    sz = int(min(x1 - x0, y1 - y0) * 0.55)
                    canvas.alpha_composite(img.resize((sz, sz)), (x0 + (x1 - x0 - sz) // 2, y0 + (y1 - y0 - sz) // 2))
            return
        w, h = x1 - x0, y1 - y0
        canvas.alpha_composite(self.figure(w, h), (x0, y0))
        sz = int(min(w, h) * 0.13)
        d = ImageDraw.Draw(canvas)
        used = {}
        for it in items:
            spots = self.BODY_SPOTS.get(it.get("equip") or "", [])
            img = self.art.get(it.get("icon")) if it.get("icon") else None
            if img is None:
                continue
            for fx, fy in spots:
                key = (fx, fy)
                n = used.get(key, 0)
                used[key] = n + 1
                px = int(x0 + fx * w - sz / 2 + n * sz * 0.35)
                py = int(y0 + fy * h - sz / 2 + n * sz * 0.35)
                d.rectangle((px - 2, py - 2, px + sz + 1, py + sz + 1), fill=(0, 0, 0, 200), outline=(200, 170, 90, 220))
                canvas.alpha_composite(img.resize((sz, sz)), (px, py))
        f = font_for("r", int(9 * self.s))
        d.text((x0 + w / 2 - f.getlength("3D model stand-in") / 2, y0 + 2 * self.s), "3D model stand-in", font=f, fill=(210, 200, 230, int(120 * alpha)))

    def drawables(self):
        out = []
        for oid, o in self.objs.items():
            if not self.visible(oid):
                continue
            fr = self.frame_of(o)
            strata = STRATA.index(fr.get("strata") or "MEDIUM") if (fr.get("strata") or "MEDIUM") in STRATA else 2
            lvl = fr.get("level") or 1
            if not o.get("region"):
                out.append(((strata, lvl, -1, 0, self.order[oid]), oid))
            else:
                layer = LAYERS.get(o.get("layer") or "ARTWORK", 2)
                po = self.objs.get(o.get("parent")) or {}
                st = po.get("states") or {}
                role = next((k for k, v in st.items() if v == oid), None)
                if role == "Pushed":
                    continue
                if role == "Highlight" and not po.get("lockedHighlight"):
                    continue
                if role == "Checked" and not po.get("checked"):
                    continue
                if role == "Disabled" and po.get("enabled", True):
                    continue
                if role == "Normal" and not po.get("enabled", True) and "Disabled" in st:
                    continue
                if role == "Highlight":
                    layer = 4
                elif role in ("Normal", "Disabled"):
                    layer = 1.5
                elif role == "Checked":
                    layer = 3
                if layer == 4 and role != "Highlight":
                    continue            # HIGHLIGHT layer: only while the mouse is over it
                # the client draws a layer's font strings over its textures
                text = 1 if o.get("kind") == "FontString" else 0
                out.append(((strata, lvl, layer, text, self.order[oid]), oid))
        out.sort()
        return [oid for _k, oid in out]

    def render(self):
        s = self.s
        canvas = Image.new("RGBA", (int(self.sw * s), int(self.sh * s)), (24, 22, 26, 255))
        for oid in self.drawables():
            o = self.objs[oid]
            r = self.rect(oid)
            if r is None or r[1] - r[0] <= 0 or r[3] - r[2] <= 0:
                continue
            a = self.alpha(oid)
            if a <= 0.01:
                continue
            if not o.get("region"):
                self.draw_backdrop(canvas, o, r, a)
                t = o.get("template")
                if t in ("UIPanelButtonTemplate", "UIPanelButtonTemplate2"):
                    self.panel_button(canvas, o, r, a)
                elif t == "UIPanelCloseButton":
                    self.paste(canvas, self.art.get("Interface\\Buttons\\UI-Panel-MinimizeButton-Up"), r, a)
                elif t == "UICheckButtonTemplate":
                    self.paste(canvas, self.art.get("Interface\\Buttons\\UI-CheckBox-Up"), r, a)
                    if o.get("checked"):
                        self.paste(canvas, self.art.get("Interface\\Buttons\\UI-CheckBox-Check"), r, a)
                if o["kind"] in ("DressUpModel", "PlayerModel", "Model", "TabardModel"):
                    self.draw_model(canvas, o, r, a)
                if o["kind"] == "EditBox" and o.get("text"):
                    fake = dict(o, font=o.get("font") or "ChatFontNormal", justifyH="LEFT")
                    self.draw_text(canvas, fake, (r[0] + 4, r[1] - 4, r[2], r[3]), a)
                continue
            if o["kind"] == "FontString":
                self.draw_text(canvas, o, r, a)
                continue
            img, missing = self.tex_image(o)
            po = self.objs.get(o.get("parent")) or {}
            if img is not None and po.get("barTexture") == o["id"] and po.get("barColor"):
                img = self.tint(img, po["barColor"])      # SetStatusBarColor
            if img is not None and o.get("circular"):     # SetPortraitToTexture
                mask = Image.new("L", img.size, 0)
                ImageDraw.Draw(mask).ellipse([0, 0, img.width - 1, img.height - 1], fill=255)
                ca = ImageChops_mul(img.getchannel("A"), mask)
                img = img.copy()
                img.putalpha(ca)
            if img is not None:
                self.paste(canvas, img, r, a, add=(o.get("blend") == "ADD"))
        return canvas

    def crop(self, canvas, oid, margin=24):
        r = self.rect(oid)
        if r is None:
            return canvas
        L, R, B, T = r
        # include visible descendants that hang outside (tabs under the frame)
        for xid in self.objs:
            if self.visible(xid) and self.is_under(xid, oid):
                rr = self.rect(xid)
                if rr and rr[1] - rr[0] > 0 and rr[3] - rr[2] > 0:
                    L, R, B, T = min(L, rr[0]), max(R, rr[1]), min(B, rr[2]), max(T, rr[3])
        x0, y0, x1, y1 = self.box((L - margin, R + margin, B - margin, T + margin))
        return canvas.crop((max(0, x0), max(0, y0), min(canvas.width, x1), min(canvas.height, y1)))

    def is_under(self, xid, root):
        o = self.objs.get(xid)
        while o:
            if o["id"] == root:
                return True
            o = self.objs.get(o.get("parent"))
        return False


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    scale = 2.0
    for i, a in enumerate(sys.argv):
        if a == "--scale" and i + 1 < len(sys.argv):
            scale = float(sys.argv[i + 1])
            args = [x for x in args if x != sys.argv[i + 1]]
    full = "--full" in sys.argv
    repo, folder = args[0], args[1]
    art = Art(repo)
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(folder, name), encoding="utf-8") as fh:
            data = json.load(fh)
        sc = Scene(data, art, scale)
        img = sc.render()
        if not full:
            img = sc.crop(img, data.get("root", 1))
        out = os.path.join(folder, name[:-5] + ".png")
        img.convert("RGB").save(out)
        print("wrote", out, img.size)
    if art.missing:
        print("textures not found:", ", ".join(sorted(art.missing)[:40]))


if __name__ == "__main__":
    main()
