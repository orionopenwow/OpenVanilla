#!/usr/bin/env python3
"""Website art for Herald, Open Vanilla's self-learning test bot (www/herald.html).

    python tools/gen_herald_art.py [out_dir] [--stills-only | --frames-only]

--stills-only keeps the GIF (e.g. after a real capture replaced it, tools/herald_capture.md);
--frames-only writes a few GIF frames as _preview_NNN.png for checking, and nothing else.

Writes into www/assets/herald/ (or out_dir):
    herald_hero.webp      1200x520   Herald on a ridge at the edge of the forest, drawing his longbow under
                                     a gold moon, his hawk overhead, a learned route glowing on the ground
    herald_banner.webp    1600x400   the same world, wide, with the name (site / Discord banner)
    herald_banner.jpg     1600x400   the same, as JPEG (launcher card, Discord)
    herald_og.jpg         1200x630   social preview (og:image / twitter:image)
    herald_avatar.png      512x512   a gold medallion with Herald's hooded profile (also the Discord avatar)
    icon_learns.png        128x128   ability icons: learns, finds bugs, plays, reports
    icon_bugs.png
    icon_plays.png
    icon_reports.png
    herald_playing.gif     640x300   ~8 s loop: Herald pulls a boar, kites it, kills it, loots, completes
                                     the quest; a small HUD shows XP and a "learning" stat rising.
                                     An illustration, not a capture (tools/herald_capture.md).
    herald_playing.webp    640x300   the GIF's best frame, used as the <img> poster on slow connections

Herald is an original character: a human archer-ranger in a green hood with a dagged cowl, a leather
jerkin, a quiver of red-fletched arrows, a longbow with a gold grip, and a hawk. Everything is drawn
from shapes with PIL (no game art, no fonts beyond DejaVu). Drawn at 3x and downsampled.
Deterministic: same seeds, same pictures.
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
OUT = ARGS[0] if ARGS else os.path.join(ROOT, "www", "assets", "herald")
S = 3  # supersampling

# -- palette ---------------------------------------------------------------------------------
GOLD = (232, 188, 84)
GOLD_HI = (255, 230, 150)
GOLD_DK = (150, 108, 40)
INK = (8, 10, 16)
HOOD = (52, 104, 58)
HOOD_DK = (30, 66, 40)
HOOD_HI = (104, 160, 88)
SLEEVE = (60, 96, 56)
LEATHER = (118, 76, 42)
LEATHER_DK = (74, 46, 26)
LEATHER_HI = (168, 118, 66)
PANTS = (64, 60, 40)
BOOT = (58, 38, 24)
SKIN = (226, 178, 140)
SKIN_DK = (170, 118, 90)
WOOD = (128, 82, 40)
WOOD_DK = (84, 52, 26)
STRING = (236, 226, 196)
FLETCH = (196, 58, 46)
FLETCH2 = (238, 232, 214)
HAWK = (116, 78, 46)
HAWK_LT = (214, 184, 140)
BOAR = (78, 52, 40)
BOAR_DK = (46, 30, 24)
BLUE = (110, 190, 255)
GREEN = (94, 224, 138)
SERIF = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"
SERIF_C = "/usr/share/fonts/truetype/dejavu/DejaVuSerifCondensed-Bold.ttf"
SANS_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def font(path, px):
    try:
        return ImageFont.truetype(path, int(px))
    except OSError:
        return ImageFont.load_default()


def lerp(a, b, t):
    return a + (b - a) * t


def lerpc(c0, c1, t):
    return tuple(int(round(lerp(a, b, t))) for a, b in zip(c0, c1))


def clamp(x, a=0.0, b=1.0):
    return max(a, min(b, x))


def ease(t):  # smoothstep-ish ease in-out
    t = clamp(t)
    return t * t * (3 - 2 * t)


def ease_out(t):
    t = clamp(t)
    return 1 - (1 - t) ** 3


def seg(t, a, b):
    """0 before a, 1 after b, linear between."""
    return clamp((t - a) / (b - a)) if b > a else float(t >= a)


def rot(p, a):
    c, s = math.cos(a), math.sin(a)
    return (p[0] * c - p[1] * s, p[0] * s + p[1] * c)


def add(p, q):
    return (p[0] + q[0], p[1] + q[1])


def sub(p, q):
    return (p[0] - q[0], p[1] - q[1])


def mul(p, k):
    return (p[0] * k, p[1] * k)


def norm(p):
    n = math.hypot(*p) or 1.0
    return (p[0] / n, p[1] / n)


def ik(a, c, l1, l2, bend):
    """Two-bone IK from a to target c; bend=+1/-1 picks the elbow side. Returns (elbow, hand)."""
    dx, dy = sub(c, a)
    d = math.hypot(dx, dy)
    d = min(d, l1 + l2 - 1e-3)
    if d < 1e-6:
        return add(a, (0, l1)), c
    cos_a = clamp((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1, 1)
    ang = math.atan2(dy, dx) + bend * math.acos(cos_a)
    elbow = add(a, (l1 * math.cos(ang), l1 * math.sin(ang)))
    hand = add(a, mul(norm((dx, dy)), d))
    return elbow, hand


def glow(size, xy, r, color, alpha=255, blur=None):
    layer = Image.new("RGBA", size, color + (0,))
    m = Image.new("L", size, 0)
    x, y = xy
    ImageDraw.Draw(m).ellipse((x - r, y - r, x + r, y + r), fill=int(alpha))
    layer.putalpha(m.filter(ImageFilter.GaussianBlur(blur or r * 0.6)))
    return layer


def sparkle(d, x, y, r, col=(255, 255, 255, 255), waist=0.22):
    w = r * waist
    d.polygon([(x, y - r), (x + w, y - w), (x + r, y), (x + w, y + w), (x, y + r), (x - w, y + w),
               (x - r, y), (x - w, y - w)], fill=col)


def vgrad(w, h, stops):
    t = np.linspace(0, 1, h)[:, None]
    out = np.zeros((h, 1, 3))
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        sel = (t >= t0) & (t <= t1)
        k = np.where(sel, (t - t0) / max(t1 - t0, 1e-6), 0)
        for i in range(3):
            out[:, :, i] = np.where(sel, c0[i] + (c1[i] - c0[i]) * k, out[:, :, i])
    return Image.fromarray(np.repeat(out, w, axis=1).astype(np.uint8), "RGB").convert("RGBA")


# ==============================================================================================
# Herald: a posable side-view rig. Units: ~100 tall, feet at y=0, facing +x. Pen maps to pixels.
# ==============================================================================================
class Pen:
    def __init__(self, d, ox, oy, k, facing=1):
        self.d, self.ox, self.oy, self.k, self.f = d, ox, oy, k, facing

    def P(self, p):
        return (self.ox + self.f * p[0] * self.k, self.oy + p[1] * self.k)

    def poly(self, pts, fill, outline=None, width=0):
        self.d.polygon([self.P(p) for p in pts], fill=fill, outline=outline,
                       width=int(width * self.k) if width else 0)

    def limb(self, a, b, w, fill):
        A, B = self.P(a), self.P(b)
        r = w * self.k / 2
        self.d.line([A, B], fill=fill, width=max(1, int(round(w * self.k))))
        for x, y in (A, B):
            self.d.ellipse((x - r, y - r, x + r, y + r), fill=fill)

    def dot(self, p, r, fill):
        x, y = self.P(p)
        r *= self.k
        self.d.ellipse((x - r, y - r, x + r, y + r), fill=fill)

    def line(self, pts, fill, w):
        self.d.line([self.P(p) for p in pts], fill=fill, width=max(1, int(round(w * self.k))), joint="curve")


def herald_pose(t=0.0, draw=0.0, aim=1.0, run=0.0, phase=0.0, lean=0.0, look=0.0, wind=0.0):
    """A pose dict. draw: bowstring pulled (0..1); aim: bow raised (0..1); run: 0 stand .. 1 sprint;
    phase: stride phase (radians); wind: cloak flutter (0..1)."""
    return dict(t=t, draw=draw, aim=aim, run=run, phase=phase, lean=lean, look=look, wind=wind)


def _leg(hip, ang, bend, l1=24.0, l2=24.0):
    knee = add(hip, rot((0, l1), -ang))
    ankle = add(knee, rot((0, l2), -ang + bend))
    return knee, ankle


def herald_joints(p):
    r, ph = p["run"], p["phase"]
    bob = -r * 2.4 * abs(math.sin(ph)) + (1 - r) * 0.4 * math.sin(p["t"] * 2.2)
    lean = math.radians(p["lean"] + r * 9)
    hip = (0.0, -47.0 + bob)
    J = {"hip": hip, "lean": lean}

    def up(v):  # torso-local offset, rotated by lean (forward = +x)
        return add(hip, rot(v, lean))

    J["neck"] = up((1.0, -31.0))
    J["sh_f"] = up((3.0, -28.5))   # bow-arm shoulder (near side)
    J["sh_b"] = up((-1.5, -29.0))  # draw-arm shoulder (far side)
    J["head"] = up((3.0, -42.5))
    # legs: archer stance blended with a stride
    for name, off, stance, sbend in (("f", 0.0, 8.0, 4.0), ("b", math.pi, -11.0, 3.0)):
        q = ph + off
        ang = math.radians(lerp(stance, 30.0 * math.sin(q), r))
        bend = math.radians(lerp(sbend, 14 + 82.0 * max(0.0, math.cos(q + math.pi / 4)) ** 1.6, r))
        knee, ankle = _leg(hip, ang, bend)
        J["knee_" + name], J["ankle_" + name] = knee, ankle
        J["toe_" + name] = add(ankle, rot((6.5, 0.5), -ang * 0.3 * r))
    # bow arm: raised and straight when aiming, low and forward when not
    aim = ease(p["aim"])
    swing = r * 0.6 * math.sin(ph)
    hand_low = add(J["sh_f"], rot((8.0, 17.5), -swing))
    hand_aim = add(J["sh_f"], (24.5, -1.5 - 2.0 * p["look"]))
    hb = (lerp(hand_low[0], hand_aim[0], aim), lerp(hand_low[1], hand_aim[1], aim))
    J["elbow_f"], J["hand_f"] = ik(J["sh_f"], hb, 13.0, 13.0, 1)
    # bow: vertical (slightly canted) when aiming, slanted down-forward when lowered
    bow_ang = lerp(math.radians(26 + 8 * swing), math.radians(-6), aim)
    J["bow_u"] = rot((0, -1), bow_ang)          # along the bow, toward the top limb
    J["bow_n"] = rot((1, 0), bow_ang)           # the bow's belly side faces the target
    J["bow_draw"] = p["draw"] * aim
    half = 35.0
    dd = J["bow_draw"]
    tips = []
    for sgn in (1, -1):
        tip = add(add(J["hand_f"], mul(J["bow_u"], sgn * half * (1 - 0.05 * dd))), mul(J["bow_n"], -3.0 - 5.0 * dd))
        tips.append(tip)
    J["tip_top"], J["tip_bot"] = tips
    rest = add(J["hand_f"], mul(J["bow_n"], -3.0))
    cheek = add(J["head"], rot((3.0, 4.0), lean))
    if aim > 0.02:
        target = (lerp(rest[0], cheek[0], dd), lerp(rest[1], cheek[1], dd))
        hand_b = (lerp(add(J["sh_b"], (-3.0, 23.0))[0], target[0], aim), lerp(add(J["sh_b"], (-3.0, 23.0))[1], target[1], aim))
    else:
        hand_b = add(J["sh_b"], rot((-3.0, 23.0), swing))
    J["elbow_b"], J["hand_b"] = ik(J["sh_b"], hand_b, 13.0, 13.0, 1)
    J["string_mid"] = J["hand_b"] if (aim > 0.5 and dd > 0.01) else None
    return J


def bow_points(J, n=24):
    """The bow's centreline: a longbow arc with recurved tips, flexed by the draw."""
    dd = J["bow_draw"]
    pts = []
    for i in range(n + 1):
        s = -1 + 2 * i / n
        along = s * 35.0 * (1 - 0.05 * dd)
        belly = (6.0 + 4.0 * dd) * (1 - s * s) - 3.0 - 5.0 * dd * s * s + 1.6 * abs(s) ** 6
        pts.append(add(add(J["hand_f"], mul(J["bow_u"], along)), mul(J["bow_n"], belly)))
    return pts


def draw_herald(img, ox, oy, k, facing, pose, arrow=True, light=(-1.0, -0.6), rim=GOLD_HI,
                rim_alpha=220, shade=True, hood_feather=True, dim=0.0, halo=0.0):
    """Draw Herald into img (RGBA) with feet at (ox, oy), k pixels per unit.
    dim: darken toward the night (a backlit figure); halo: an all-round rim (the moon behind him)."""
    J = herald_joints(pose)
    pad = int(140 * k)
    box = (int(ox - pad), int(oy - pad), int(ox + pad), int(oy + pad * 0.25))
    box = (max(0, box[0]), max(0, box[1]), min(img.size[0], box[2]), min(img.size[1], box[3]))
    w, h = box[2] - box[0], box[3] - box[1]
    lay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    pen = Pen(d, ox - box[0], oy - box[1], k, facing)
    wind = pose["wind"]
    r = pose["run"]
    t = pose["t"]
    lean = J["lean"]

    def up(v):
        return add(J["hip"], rot(v, lean))

    # cloak, behind everything; dagged hem; streams back when running
    fl = 1.5 * math.sin(t * 5.0) * (0.3 + wind) + r * 10
    cloak = [up((-3, -30)), up((-9, -27)), up((-14 - fl * 0.4, -8)), up((-17 - fl * 0.8, 8 - r * 6))]
    hem = []
    n = 6
    a0, a1 = up((-17 - fl * 0.8, 8 - r * 6)), up((-4, 10 - r * 3))
    for i in range(n + 1):
        q = (lerp(a0[0], a1[0], i / n), lerp(a0[1], a1[1], i / n))
        hem.append(q)
        if i < n:
            q2 = (lerp(a0[0], a1[0], (i + 0.5) / n), lerp(a0[1], a1[1], (i + 0.5) / n) - 3.2)
            hem.append(q2)
    pen.poly(cloak + hem + [up((-1, -18))], HOOD_DK)

    # far leg
    pen.limb(J["hip"], J["knee_b"], 8.6, lerpc(PANTS, INK, 0.25))
    pen.limb(J["knee_b"], J["ankle_b"], 7.4, lerpc(PANTS, INK, 0.25))
    mid_b = (lerp(J["knee_b"][0], J["ankle_b"][0], 0.42), lerp(J["knee_b"][1], J["ankle_b"][1], 0.42))
    pen.limb(mid_b, J["ankle_b"], 8.0, lerpc(BOOT, INK, 0.3))
    pen.limb(J["ankle_b"], J["toe_b"], 5.4, lerpc(BOOT, INK, 0.3))

    # far (draw) arm
    pen.limb(J["sh_b"], J["elbow_b"], 6.6, lerpc(SLEEVE, INK, 0.3))
    pen.limb(J["elbow_b"], J["hand_b"], 5.6, lerpc(SLEEVE, INK, 0.3))
    fb = (lerp(J["elbow_b"][0], J["hand_b"][0], 0.45), lerp(J["elbow_b"][1], J["hand_b"][1], 0.45))
    pen.limb(fb, J["hand_b"], 6.2, lerpc(LEATHER_DK, INK, 0.2))

    # quiver on the back, arrows fletched red and white
    qa, qb = up((-1.5, -12)), up((-14.0, -37))
    qd = norm(sub(qb, qa))
    qn = (-qd[1], qd[0])
    for j, off in enumerate((-2.2, 0.0, 2.2)):
        base = add(qb, mul(qn, off))
        tip = add(base, mul(qd, 8.5 - abs(off)))
        pen.line([base, tip], WOOD_DK, 1.0)
        fl_pts = [add(tip, mul(qn, 0.0)), add(tip, add(mul(qd, -5.5), mul(qn, 1.9))),
                  add(tip, mul(qd, -6.5)), add(tip, add(mul(qd, -5.5), mul(qn, -1.9)))]
        pen.poly(fl_pts, FLETCH if j != 1 else FLETCH2)
    qw = 3.1
    pen.poly([add(qa, mul(qn, qw)), add(qb, mul(qn, qw * 1.15)), add(qb, mul(qn, -qw * 1.15)), add(qa, mul(qn, -qw))],
             LEATHER_DK)
    pen.poly([add(qb, mul(qn, qw * 1.2)), add(add(qb, mul(qd, -2.4)), mul(qn, qw * 1.2)),
              add(add(qb, mul(qd, -2.4)), mul(qn, -qw * 1.2)), add(qb, mul(qn, -qw * 1.2))], GOLD_DK)

    # torso: leather jerkin over a green tunic, belt with a gold buckle
    torso = [up((-1.5, -31)), up((6.0, -30)), up((9.0, -22)), up((8.0, -10)), up((6.0, -3)), up((9.5, 6.5)),
             up((-9.5, 6.5)), up((-7.0, -3)), up((-7.5, -12)), up((-8.0, -24))]
    pen.poly(torso, LEATHER)
    pen.poly([up((-7.0, -3)), up((6.0, -3)), up((6.5, 0)), up((-7.2, 0))], LEATHER_DK)
    pen.poly([up((-7.4, -3.2)), up((6.4, -3.2)), up((6.6, -0.2)), up((-7.6, -0.2))], lerpc(LEATHER_DK, INK, 0.3))
    pen.poly([up((3.2, -3.6)), up((6.6, -3.6)), up((6.6, 0.2)), up((3.2, 0.2))], GOLD)
    # lacing down the front
    for i in range(4):
        y = -26 + i * 5
        pen.line([up((5.5, y)), up((7.5, y + 2.5))], LEATHER_HI, 0.8)
    pen.line([up((-9.0, 6.0)), up((9.0, 6.0))], LEATHER_DK, 1.0)

    # near leg
    pen.limb(J["hip"], J["knee_f"], 9.0, PANTS)
    pen.limb(J["knee_f"], J["ankle_f"], 7.8, PANTS)
    mid_f = (lerp(J["knee_f"][0], J["ankle_f"][0], 0.42), lerp(J["knee_f"][1], J["ankle_f"][1], 0.42))
    pen.limb(mid_f, J["ankle_f"], 8.4, BOOT)
    pen.limb(J["ankle_f"], J["toe_f"], 5.8, BOOT)
    cuff = (lerp(mid_f[0], J["knee_f"][0], 0.12), lerp(mid_f[1], J["knee_f"][1], 0.12))
    pen.limb(cuff, mid_f, 8.6, lerpc(BOOT, LEATHER_HI, 0.3))  # boot cuff

    # head: face in profile, hood with a long tail (liripipe), feather, dagged cowl over the shoulders
    hd = J["head"]

    def hp(v):
        return add(hd, rot(v, lean * 0.6))

    pen.poly([hp((-2, 6.5)), hp((5.5, 6.0)), hp((4.5, 9.5)), hp((-3, 9.5))], SKIN_DK)  # neck
    face = [hp((-1.0, -6.5)), hp((5.0, -6.0)), hp((6.8, -3.0)), hp((7.4, -1.6)), hp((9.6, 1.4)), hp((7.4, 2.2)),
            hp((7.6, 3.2)), hp((6.6, 4.0)), hp((6.9, 5.4)), hp((5.2, 7.2)), hp((1.5, 7.4)), hp((-2.0, 4.0))]
    pen.poly(face, SKIN)
    pen.poly([hp((-2.0, -6.0)), hp((6.6, -5.6)), hp((7.2, -2.6)), hp((3.0, -2.4)), hp((-2.0, -1.0))],
             lerpc(SKIN_DK, INK, 0.25))  # hood shadow over the brow
    pen.dot(hp((5.2, -0.6)), 0.75, INK)  # eye
    pen.line([hp((3.9, -2.0)), hp((6.6, -2.4))], (88, 56, 34), 0.7)  # brow
    pen.line([hp((5.0, 5.2)), hp((2.0, 7.0)), hp((5.6, 7.4))], (120, 78, 46), 1.1)  # short beard line
    tail = 2.0 * math.sin(t * 4.3 + 1.0) * (0.3 + wind) + r * 2.5
    hood = [hp((7.8, -5.0)), hp((5.0, -9.2)), hp((-1.0, -10.6)), hp((-6.5, -8.0)), hp((-9.0, -3.0)),
            hp((-14.0 - tail, 1.5 + r * 2)), hp((-19.0 - tail * 1.4, 6.5 + r * 1)), hp((-13.5 - tail, 4.6 + r * 1.5)),
            hp((-8.5, 3.0)), hp((-6.0, 8.5)), hp((-1.0, 9.0)), hp((-2.6, 2.0)), hp((-1.6, -4.8)), hp((5.0, -5.8))]
    pen.poly(hood, HOOD)
    pen.poly([hp((7.8, -5.0)), hp((5.0, -9.2)), hp((-1.0, -10.6)), hp((0.0, -8.6)), hp((5.0, -7.0))], HOOD_HI)
    pen.line([hp((-1.6, -4.8)), hp((-2.6, 2.0)), hp((-1.0, 9.0))], HOOD_DK, 1.0)  # hood opening edge
    if hood_feather:
        fb0, fb1 = hp((-5.0, -8.0)), hp((-14.0, -17.5))
        fd = norm(sub(fb1, fb0))
        fn = (-fd[1], fd[0])
        mid = mul(add(fb0, fb1), 0.5)
        pen.poly([fb0, add(mid, mul(fn, 2.4)), fb1, add(mid, mul(fn, -1.2))], FLETCH)
        pen.line([fb0, fb1], GOLD_HI, 0.5)
    # cowl: a short cape over the shoulders with a dagged edge
    c0, c1 = up((-9.0, -26.0)), up((10.5, -22.5))
    cowl = [hp((-3.0, 6.0)), hp((6.0, 6.5)), up((9.5, -27.5))]
    nd = 5
    edge = []
    for i in range(nd + 1):
        q = (lerp(c1[0], c0[0], i / nd), lerp(c1[1], c0[1], i / nd))
        edge.append(q)
        if i < nd:
            qn2 = (lerp(c1[0], c0[0], (i + 0.5) / nd), lerp(c1[1], c0[1], (i + 0.5) / nd) + 3.0)
            edge.append(qn2)
    pen.poly(cowl + edge + [up((-8.0, -30.0)), hp((-5.0, 7.0))], HOOD)
    pen.line([hp((6.0, 6.5)), up((9.5, -27.5)), c1], HOOD_HI, 0.9)

    # near (bow) arm
    pen.limb(J["sh_f"], J["elbow_f"], 7.0, SLEEVE)
    pen.limb(J["elbow_f"], J["hand_f"], 6.0, SLEEVE)
    fa = (lerp(J["elbow_f"][0], J["hand_f"][0], 0.4), lerp(J["elbow_f"][1], J["hand_f"][1], 0.4))
    pen.limb(fa, J["hand_f"], 6.6, LEATHER)

    # bow, string, nocked arrow
    bp = bow_points(J)
    pen.line(bp, WOOD_DK, 2.6)
    pen.line(bp[2:-2], WOOD, 1.7)
    grip = bp[len(bp) // 2 - 2: len(bp) // 2 + 3]
    pen.line(grip, GOLD, 3.0)
    if J["string_mid"] is not None:
        pen.line([bp[0], J["string_mid"], bp[-1]], STRING, 0.55)
        if arrow:
            tail_p = J["string_mid"]
            dirv = norm(sub(add(J["hand_f"], mul(J["bow_n"], 6)), tail_p))
            head_p = add(J["hand_f"], mul(dirv, 7.0))
            pen.line([tail_p, head_p], WOOD, 0.9)
            nrm = (-dirv[1], dirv[0])
            pen.poly([add(head_p, mul(dirv, 3.0)), add(head_p, mul(nrm, 1.3)), add(head_p, mul(nrm, -1.3))], (210, 214, 220))
            for sgn in (1, -1):
                pen.poly([add(tail_p, mul(dirv, 1.0)), add(tail_p, add(mul(dirv, 5.5), mul(nrm, sgn * 0.3))),
                          add(tail_p, add(mul(dirv, 2.0), mul(nrm, sgn * 1.8)))], FLETCH)
    else:
        pen.line([bp[0], bp[-1]], STRING, 0.55)
    pen.dot(J["hand_f"], 2.6, LEATHER_DK)  # glove on the grip
    pen.dot(J["hand_b"], 2.4, LEATHER_DK)

    # light: a backlit rim on the side toward the light, a soft core shadow on the other side
    if shade:
        a = lay.getchannel("A")
        lx, ly = light
        lx *= facing
        dd = max(1, int(min(1.6 * k, 2.4 * S)))
        inside = ImageChops.offset(a, int(-lx * dd), int(-ly * dd))
        rim_m = ImageChops.subtract(a, inside).filter(ImageFilter.GaussianBlur(max(0.6, min(k * 0.35, 0.6 * S))))
        rim_m = ImageChops.multiply(rim_m, a)
        rim_l = Image.new("RGBA", lay.size, rim + (0,))
        rim_l.putalpha(rim_m.point(lambda v: int(v * rim_alpha / 255)))
        sd = max(2, int(min(5 * k, 9 * S)))
        shadow_m = ImageChops.subtract(a, ImageChops.offset(a, int(lx * sd), int(ly * sd)))
        shadow_m = ImageChops.multiply(shadow_m.filter(ImageFilter.GaussianBlur(min(k * 2.2, 5 * S))), a)
        sh_l = Image.new("RGBA", lay.size, INK + (0,))
        sh_l.putalpha(shadow_m.point(lambda v: int(v * 0.42)))
        lay.alpha_composite(sh_l)
        if dim > 0:
            dl = Image.new("RGBA", lay.size, (14, 18, 28, 0))
            dl.putalpha(a.point(lambda v: int(v * dim)))
            lay.alpha_composite(dl)
        if halo > 0:
            sz = int(halo * S) * 2 + 1
            inner = a.filter(ImageFilter.MinFilter(sz))
            hm = ImageChops.subtract(a, inner).filter(ImageFilter.GaussianBlur(0.5 * S))
            hm = ImageChops.multiply(hm, a)
            hl = Image.new("RGBA", lay.size, rim + (0,))
            hl.putalpha(hm.point(lambda v: int(v * 0.85)))
            lay.alpha_composite(hl)
        lay.alpha_composite(rim_l)
    img.alpha_composite(lay, (box[0], box[1]))
    return J


# -- the hawk ----------------------------------------------------------------------------------
def draw_hawk(img, x, y, k, flap, facing=1, glide=False):
    """A hawk in flight, side-on: two wings rising (flap=-1 .. up) or beating down (flap=+1), fingered
    primaries, a barred fan tail and a hooked gold beak."""
    d = ImageDraw.Draw(img)
    pen = Pen(d, x, y, k, facing)
    lift = -flap  # +1 wings up, -1 wings down

    def wing(sx, span, lift, col, edge):
        tip = (sx - 9.0, -span * lift)
        wrist = (sx - 2.5 + 1.5 * abs(lift), -span * lift * 0.55)
        pts = [(sx + 2.2, 0.0), wrist]
        # five primaries fanning at the tip
        for f in range(5):
            u = f / 4
            fx = tip[0] + lerp(1.5, -3.5, u)
            fy = tip[1] + lerp(-1.2, 2.2, u) * (1 if lift >= 0 else -1)
            pts += [(fx, fy), (fx - 0.9, fy + (1.4 if lift >= 0 else -1.4))]
        pts += [(sx - 12.5, -span * lift * 0.42 + 1.0), (sx - 9.0, 0.6)]
        pen.poly(pts, col)
        pen.line([(sx + 2.2, 0.0), wrist, tip], edge, 0.8)

    wing(1.0, 15.0, lift * 0.85 + 0.12, lerpc(HAWK, INK, 0.42), lerpc(HAWK, INK, 0.6))
    tail = [(-10, -1.6), (-19.5, -3.6), (-21, 0.2), (-19.5, 3.6), (-10, 1.8)]
    pen.poly(tail, HAWK)
    for bx in (-14, -17.5):
        pen.line([(bx, -2.4), (bx, 2.4)], lerpc(HAWK, INK, 0.45), 0.8)
    body = [(9.5, -2.2), (6, -3.4), (0, -3.2), (-7, -2.2), (-11, -1.2), (-11, 1.8), (-5, 3.2), (4, 2.9), (8, 1.0)]
    pen.poly(body, HAWK)
    pen.poly([(6, 1.6), (-3, 3.0), (-9, 1.6), (-2, 0.8)], HAWK_LT)
    pen.dot((8.4, -1.5), 3.1, lerpc(HAWK, INK, 0.15))
    pen.poly([(10.8, -2.5), (13.6, -1.0), (12.4, 0.6), (10.6, -0.4)], GOLD)
    pen.dot((9.5, -2.2), 0.65, INK)
    wing(-1.0, 17.0, lift, HAWK, lerpc(HAWK, HAWK_LT, 0.5))


# -- the boar ----------------------------------------------------------------------------------
def draw_boar(img, x, y, k, gallop=0.0, run=0.0, facing=-1, hp=1.0, dead=0.0, slowed=0.0, alpha=1.0):
    """A wild boar, side-on, feet at (x, y). facing -1 = toward the left. dead in [0,1] rolls it over."""
    pad = int(60 * k)
    lay = Image.new("RGBA", (pad * 2, pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    pen = Pen(d, pad, pad + 10 * k, k, facing)
    dd = ease(dead)
    drop = 13.0 * dd
    pen.oy += drop * k
    legs = []
    for i, (lx, ph) in enumerate(((10, 0.0), (7, math.pi), (-12, math.pi * 0.5), (-15, math.pi * 1.5))):
        sw = run * 0.75 * math.sin(gallop + ph) * (1 - dd)
        top = (lx, -16)
        ll = 7.5 * (1 - 0.8 * dd)
        fold = 1.3 * dd * (1 if i % 2 == 0 else -1)
        knee = add(top, rot((0, ll), -sw + fold))
        foot = add(knee, rot((0, ll), -sw * 0.4 + run * 0.5 * max(0, math.sin(gallop + ph + 1)) - fold * 1.6))
        legs.append((i, top, knee, foot))
    for i, top, knee, foot in legs:
        if i in (1, 3):
            pen.limb(top, knee, 4.4, BOAR_DK)
            pen.limb(knee, foot, 3.4, BOAR_DK)
    body = [(16, -27), (6, -32), (-8, -31), (-19, -27), (-23, -21), (-21, -14), (-12, -11), (2, -11), (14, -13), (19, -18)]
    pen.poly(body, BOAR)
    pen.poly([(-19, -27), (-8, -31), (6, -32), (16, -27), (8, -26), (-8, -27)], lerpc(BOAR, (140, 100, 70), 0.35))
    for i in range(9):  # bristly mane
        bx = 12 - i * 3.4
        pen.poly([(bx, -30.5 + abs(i - 3) * 0.3), (bx - 1.4, -35 + abs(i - 3) * 0.45), (bx - 2.8, -30.5)], BOAR_DK)
    head = [(15, -27), (22, -25), (31, -19), (33, -15), (31, -12.5), (24, -12), (16, -13)]
    pen.poly(head, BOAR)
    pen.poly([(30.5, -19), (34, -18), (34, -13), (31, -12.5)], (150, 100, 92))  # snout
    pen.poly([(17, -27), (20, -32), (22, -26)], BOAR_DK)  # ear
    if dead < 0.5:
        pen.dot((24.5, -20.5), 1.1, (255, 210, 120))
    else:
        pen.line([(23.5, -21.5), (25.5, -19.5)], INK, 0.7)
        pen.line([(23.5, -19.5), (25.5, -21.5)], INK, 0.7)
    pen.poly([(28, -13.5), (31, -17.5), (29.5, -13)], (238, 228, 200))  # tusk
    pen.poly([(-22, -22), (-26, -25), (-24, -20)], BOAR_DK)  # tail
    for i, top, knee, foot in legs:
        if i in (0, 2):
            pen.limb(top, knee, 4.8, BOAR)
            pen.limb(knee, foot, 3.6, BOAR)
            pen.dot(foot, 2.0, BOAR_DK)
    # rim light from the upper left
    a = lay.getchannel("A")
    off = max(1, int(1.4 * k))
    rim_m = ImageChops.multiply(ImageChops.subtract(a, ImageChops.offset(a, off, off)).filter(ImageFilter.GaussianBlur(k * 0.4)), a)
    rl = Image.new("RGBA", lay.size, (255, 214, 140, 0))
    rl.putalpha(rim_m.point(lambda v: int(v * 0.7)))
    lay.alpha_composite(rl)
    if slowed > 0:
        sl = Image.new("RGBA", lay.size, BLUE + (0,))
        sl.putalpha(a.point(lambda v: int(v * 0.14 * slowed)))
        lay.alpha_composite(sl)
    if dead > 0:
        lay = lay.rotate(-facing * 8 * ease(dead), resample=Image.BICUBIC, center=(pad, pad + 10 * k))
    if alpha < 1:
        lay.putalpha(lay.getchannel("A").point(lambda v: int(v * alpha)))
    img.alpha_composite(lay, (int(x - pad), int(y - pad - 10 * k)))


def draw_arrow(d, x0, y0, x1, y1, k, col=WOOD):
    ang = math.atan2(y1 - y0, x1 - x0)
    ux, uy = math.cos(ang), math.sin(ang)
    L = 26 * k
    tx, ty = x1 - ux * L, y1 - uy * L
    d.line([(tx, ty), (x1, y1)], fill=col, width=max(1, int(1.1 * k)))
    nx, ny = -uy, ux
    d.polygon([(x1 + ux * 3.4 * k, y1 + uy * 3.4 * k), (x1 + nx * 1.5 * k, y1 + ny * 1.5 * k),
               (x1 - nx * 1.5 * k, y1 - ny * 1.5 * k)], fill=(214, 218, 224))
    for sgn in (1, -1):
        d.polygon([(tx, ty), (tx + ux * 6 * k, ty + uy * 6 * k), (tx - ux * 0.5 * k + nx * sgn * 2.4 * k,
                                                                   ty - uy * 0.5 * k + ny * sgn * 2.4 * k)], fill=FLETCH)


# ==============================================================================================
# The forest
# ==============================================================================================
def tree(d, x, base, h, col, seed, lean=0.0, spread=1.0):
    """A stylised oak/ash: a trunk and a clump of overlapping round canopies."""
    rnd = random.Random(seed)
    tw = h * 0.05
    d.polygon([(x - tw, base), (x - tw * 0.55 + lean * h * 0.1, base - h * 0.62), (x + tw * 0.55 + lean * h * 0.1, base - h * 0.62),
               (x + tw, base)], fill=col)
    for _ in range(int(9 * spread)):
        cx = x + lean * h * 0.15 + rnd.uniform(-0.3, 0.3) * h * spread
        cy = base - h * rnd.uniform(0.55, 0.95)
        r = h * rnd.uniform(0.14, 0.24)
        d.ellipse((cx - r * 1.15, cy - r, cx + r * 1.15, cy + r), fill=col)


def pine(d, x, base, h, col):
    w = h * 0.30
    for i in range(4):
        y0 = base - h * (0.18 + i * 0.2)
        ww = w * (1 - i * 0.2)
        d.polygon([(x, y0 - h * 0.34), (x + ww, y0), (x - ww, y0)], fill=col)
    d.rectangle((x - h * 0.03, base - h * 0.2, x + h * 0.03, base), fill=col)


def forest_layers(img, w, h, horizon, seed, moon=None, layers=4, ground=True, density=1.0, cols=None, scale=1.0):
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    cols = cols or [(30, 44, 54), (22, 33, 40), (15, 23, 28), (9, 14, 17)]
    for li in range(layers):
        col = cols[li]
        base = horizon + li * h * 0.05
        hh = h * (0.22 + li * 0.1) * scale
        n = int((14 - li * 2.5) * density * w / 1200) + 3
        for i in range(n):
            x = (i + rnd.uniform(-0.35, 0.35)) * w / (n - 1)
            if rnd.random() < 0.35:
                pine(d, x, base + rnd.uniform(0, h * 0.03), hh * rnd.uniform(0.8, 1.15), col)
            else:
                tree(d, x, base + rnd.uniform(0, h * 0.03), hh * rnd.uniform(0.75, 1.1), col, rnd.randint(0, 99999),
                     lean=rnd.uniform(-0.3, 0.3))
        d.rectangle((0, base + h * 0.02, w, h), fill=col)
        if li == 0 and moon:  # haze between the first layers
            img.alpha_composite(glow(img.size, (moon[0], horizon), w * 0.35, (60, 72, 90), 70, blur=w * 0.12))
            d = ImageDraw.Draw(img)


def sky(w, h, seed, moon=None, stars=260):
    img = vgrad(w, h, [(0, (8, 11, 19)), (0.55, (18, 25, 40)), (1, (34, 40, 56))])
    rnd = random.Random(seed)
    d = ImageDraw.Draw(img)
    for _ in range(stars):
        x, y = rnd.uniform(0, w), rnd.uniform(0, h * 0.62) ** 1.0
        r = rnd.choice((0.6, 0.8, 1.0, 1.0, 1.4)) * S * 0.6
        a = rnd.randint(60, 200)
        d.ellipse((x - r, y - r, x + r, y + r), fill=(230, 232, 255, a))
    if moon:
        mx, my, mr = moon
        img.alpha_composite(glow(img.size, (mx, my), mr * 3.2, (232, 188, 84), 70, blur=mr * 2.2))
        img.alpha_composite(glow(img.size, (mx, my), mr * 1.5, (255, 220, 140), 120, blur=mr * 0.7))
        d = ImageDraw.Draw(img)
        d.ellipse((mx - mr, my - mr, mx + mr, my + mr), fill=(250, 226, 160))
        # soft craters
        for cx, cy, cr in ((-0.3, -0.2, 0.18), (0.25, 0.15, 0.13), (-0.05, 0.38, 0.1), (0.35, -0.35, 0.08)):
            d.ellipse((mx + cx * mr - cr * mr, my + cy * mr - cr * mr, mx + cx * mr + cr * mr, my + cy * mr + cr * mr),
                      fill=(236, 206, 140))
    return img


def route_line(img, pts, k, alpha=200, dash=10):
    """A learned route: gold dotted path with glowing waypoint nodes."""
    lay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        L = math.hypot(x1 - x0, y1 - y0)
        n = max(1, int(L / (dash * k)))
        for i in range(0, n, 2):
            a0, a1 = i / n, min(1, (i + 1) / n)
            d.line([(lerp(x0, x1, a0), lerp(y0, y1, a0)), (lerp(x0, x1, a1), lerp(y0, y1, a1))],
                   fill=GOLD + (alpha,), width=max(1, int(1.6 * k)))
    g = lay.filter(ImageFilter.GaussianBlur(3 * k))
    img.alpha_composite(g)
    img.alpha_composite(lay)
    d = ImageDraw.Draw(img)
    for x, y in pts:
        img.alpha_composite(glow(img.size, (x, y), 7 * k, GOLD, 160))
        d = ImageDraw.Draw(img)
        d.ellipse((x - 2.6 * k, y - 2.6 * k, x + 2.6 * k, y + 2.6 * k), fill=GOLD_HI + (255,))


def motes(img, w, h, seed, n, y0, y1, k):
    rnd = random.Random(seed)
    for _ in range(n):
        x, y = rnd.uniform(0, w), rnd.uniform(y0, y1)
        r = rnd.uniform(1.0, 2.4) * k
        img.alpha_composite(glow(img.size, (x, y), r * 3, (255, 214, 120), rnd.randint(60, 140)))
        ImageDraw.Draw(img).ellipse((x - r * 0.5, y - r * 0.5, x + r * 0.5, y + r * 0.5), fill=(255, 240, 190, 230))


def vignette(img, strength=0.55):
    w, h = img.size
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).ellipse((-w * 0.15, -h * 0.25, w * 1.15, h * 1.25), fill=255)
    m = m.filter(ImageFilter.GaussianBlur(min(w, h) * 0.18))
    dark = Image.new("RGBA", (w, h), (4, 5, 9, 255))
    dark.putalpha(ImageChops.invert(m).point(lambda v: int(v * strength)))
    img.alpha_composite(dark)


def ridge_rock(d, x0, x1, y, h, col, col_hi):
    """A rocky outcrop for Herald to stand on."""
    pts = [(x0, y + h * 2), (x0 + (x1 - x0) * 0.08, y + h * 0.4), (x0 + (x1 - x0) * 0.22, y + h * 0.08),
           (x0 + (x1 - x0) * 0.45, y), (x0 + (x1 - x0) * 0.7, y + h * 0.05), (x0 + (x1 - x0) * 0.86, y + h * 0.3),
           (x1, y + h * 2)]
    d.polygon(pts, fill=col)
    d.line(pts[1:-1], fill=col_hi, width=max(1, int(2 * S)))


# ==============================================================================================
# Hero, banner, OG, avatar
# ==============================================================================================
def hero_scene(w, h, hx_frac=0.66, fig=0.62, feet=0.86, seed=7, route=True, hawk_at=(0.36, 0.2), hawk_k=1.0):
    """Herald on a ridge, backlit by a big gold moon, drawing on a target off to the left."""
    W, H = w * S, h * S
    horizon = H * 0.72
    gx = W * hx_frac
    k = fig * H / 106.0
    fy = H * feet
    moon = (gx - 4 * k, fy - 84 * k, 31 * k)
    img = sky(W, H, seed, moon=moon)
    forest_layers(img, W, H, horizon, seed + 1, moon=moon, layers=3, scale=0.72)
    d = ImageDraw.Draw(img)
    d.rectangle((0, H * 0.90, W, H), fill=(8, 12, 14))
    ridge_rock(d, gx - 48 * k, gx + 52 * k, fy - 1.0 * k, 9 * k, (13, 17, 21), (84, 80, 66))
    if route:
        pts = [(W * 0.03, H * 0.975), (W * 0.13, H * 0.925), (W * 0.24, H * 0.95), (W * 0.36, H * 0.915),
               (gx - 50 * k, fy + 3 * k)]
        route_line(img, pts, S * 1.1 * h / 520)
    motes(img, W, H, seed + 3, int(30 * w / 1200), H * 0.30, H * 0.95, S)
    pose = herald_pose(t=0.7, draw=0.95, aim=1.0, look=0.3, wind=0.7)
    draw_herald(img, gx, fy, k, -1, pose, light=(1.0, -0.4), rim_alpha=255, dim=0.38, halo=1.0)
    draw_hawk(img, W * hawk_at[0], H * hawk_at[1], k * 0.55 * hawk_k, 0.6, facing=-1)
    vignette(img, 0.5)
    return img


def save(img, name, size=None, fmt="WEBP", **kw):
    os.makedirs(OUT, exist_ok=True)
    out = img
    if size and img.size != size:
        out = img.resize(size, Image.LANCZOS)
    path = os.path.join(OUT, name)
    if fmt == "JPEG":
        out.convert("RGB").save(path, "JPEG", quality=88, optimize=True, progressive=True)
    elif fmt == "PNG":
        out.save(path, "PNG", optimize=True)
    else:
        out.convert("RGB").save(path, "WEBP", quality=88, method=6)
    print("wrote", os.path.relpath(path, ROOT), out.size)
    return out


def title_block(img, x, y, scale, sub=True, align="left"):
    d = ImageDraw.Draw(img)
    f1 = font(SERIF, 64 * scale)
    f2 = font(SANS_B, 17 * scale)
    t1 = "HERALD"
    spacing = 10 * scale
    # letter-spaced title
    widths = [d.textlength(c, font=f1) for c in t1]
    tw = sum(widths) + spacing * (len(t1) - 1)
    x0 = x if align == "left" else x - tw / 2
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    cx = x0
    for c, cw in zip(t1, widths):
        sd.text((cx, y + 4 * scale), c, font=f1, fill=(0, 0, 0, 200))
        cx += cw + spacing
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(6 * scale)))
    d = ImageDraw.Draw(img)
    cx = x0
    for c, cw in zip(t1, widths):
        d.text((cx, y), c, font=f1, fill=GOLD_HI)
        cx += cw + spacing
    ly = y + 84 * scale
    d.line([(x0, ly), (x0 + tw, ly)], fill=GOLD_DK, width=max(1, int(2 * scale)))
    sparkle(d, x0 + tw / 2, ly, 7 * scale, GOLD_HI + (255,))
    if sub:
        s = "THE SELF-LEARNING RANGER OF OPEN VANILLA"
        sw = d.textlength(s, font=f2)
        sx = x0 if align == "left" else x - sw / 2
        d.text((sx, ly + 14 * scale), s, font=f2, fill=(214, 220, 232))
    return tw


def make_hero():
    img = hero_scene(1200, 520)
    save(img, "herald_hero.webp", (1200, 520))


def make_banner():
    img = hero_scene(1600, 400, hx_frac=0.76, fig=0.74, feet=0.88, seed=12, hawk_at=(0.60, 0.26))
    title_block(img, 110 * S, 110 * S, S * 1.15)
    save(img, "herald_banner.webp", (1600, 400))
    save(img, "herald_banner.jpg", (1600, 400), fmt="JPEG")


def make_og():
    img = hero_scene(1200, 630, hx_frac=0.76, fig=0.64, feet=0.87, seed=21, hawk_at=(0.55, 0.20))
    title_block(img, 90 * S, 210 * S, S * 1.0)
    d = ImageDraw.Draw(img)
    f = font(SANS, 22 * S)
    d.text((90 * S, 360 * S), "Learns. Plays. Finds bugs. Reports them.", font=f, fill=(200, 208, 222))
    save(img, "herald_og.jpg", (1200, 630), fmt="JPEG")


def make_avatar():
    """Head and shoulders in profile against the moon, inside a gold medallion (crops to a circle)."""
    N = 512 * S
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    c = N / 2
    k = N / 66.0
    hx, hy = c * 0.92, N * 0.40        # where the head centre lands
    pose = herald_pose(t=0.3, draw=0.0, aim=0.0, wind=0.5)
    J = herald_joints(pose)
    ox, oy = hx - J["head"][0] * k, hy - J["head"][1] * k
    disc = sky(N, N, 33, moon=(hx + 1.0 * k, hy - 0.5 * k, N * 0.24), stars=90)
    forest_layers(disc, N, N, N * 0.86, 34, layers=2, density=1.6, scale=0.8)
    draw_herald(disc, ox, oy, k, 1, pose, light=(1.0, -0.6), rim_alpha=255, dim=0.12, halo=1.2)
    draw_hawk(disc, N * 0.80, N * 0.22, N / 230, -0.35, facing=-1)
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).ellipse((N * 0.045, N * 0.045, N * 0.955, N * 0.955), fill=255)
    img.paste(disc, (0, 0), m)
    d = ImageDraw.Draw(img)
    for r, col, wd in ((0.475, GOLD_DK, 0.022), (0.468, GOLD, 0.012), (0.456, GOLD_HI, 0.003)):
        d.ellipse((c - N * r, c - N * r, c + N * r, c + N * r), outline=col, width=int(N * wd))
    for a in range(0, 360, 90):
        x, y = c + math.cos(math.radians(a + 45)) * N * 0.468, c + math.sin(math.radians(a + 45)) * N * 0.468
        sparkle(d, x, y, N * 0.026, GOLD_HI + (255,))
    save(img, "herald_avatar.png", (512, 512), fmt="PNG")


# -- ability icons -----------------------------------------------------------------------------
def icon_base(N):
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    c = N / 2
    disc = vgrad(N, N, [(0, (30, 36, 50)), (1, (10, 13, 20))])
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).ellipse((N * 0.05, N * 0.05, N * 0.95, N * 0.95), fill=255)
    img.paste(disc, (0, 0), m)
    img.alpha_composite(glow((N, N), (c, c * 0.8), N * 0.32, GOLD, 50))
    d = ImageDraw.Draw(img)
    d.ellipse((N * 0.05, N * 0.05, N * 0.95, N * 0.95), outline=GOLD_DK, width=int(N * 0.04))
    d.ellipse((N * 0.07, N * 0.07, N * 0.93, N * 0.93), outline=GOLD, width=int(N * 0.014))
    return img, d, c


def icon_learns(N):
    img, d, c = icon_base(N)
    pts = [(0.24, 0.70), (0.38, 0.58), (0.50, 0.64), (0.64, 0.42), (0.77, 0.30)]
    P = [(x * N, y * N) for x, y in pts]
    d.line([(0.22 * N, 0.76 * N), (0.80 * N, 0.76 * N)], fill=GOLD_DK + (255,), width=int(N * 0.025))
    d.line(P, fill=GOLD + (255,), width=int(N * 0.045), joint="curve")
    for x, y in P[:-1]:
        d.ellipse((x - N * 0.04, y - N * 0.04, x + N * 0.04, y + N * 0.04), fill=GOLD_HI + (255,))
    x, y = P[-1]
    d.polygon([(x + N * 0.06, y - N * 0.05), (x - N * 0.07, y - N * 0.02), (x + N * 0.01, y + N * 0.08)], fill=GOLD_HI)
    sparkle(d, 0.30 * N, 0.32 * N, N * 0.08, (255, 255, 255, 255))
    sparkle(d, 0.42 * N, 0.24 * N, N * 0.04, GOLD_HI + (255,))
    return img


def icon_bugs(N):
    img, d, c = icon_base(N)
    # a beetle under a magnifying glass
    bx, by = 0.44 * N, 0.44 * N
    for sgn in (-1, 1):
        for i, dy in enumerate((-0.06, 0.0, 0.06)):
            d.line([(bx + sgn * 0.05 * N, by + dy * N), (bx + sgn * 0.13 * N, by + (dy + 0.02 * (i - 1)) * N - 0.02 * N)],
                   fill=(220, 120, 100, 255), width=int(N * 0.022))
        d.line([(bx + sgn * 0.02 * N, by - 0.1 * N), (bx + sgn * 0.07 * N, by - 0.17 * N)], fill=(220, 120, 100, 255),
               width=int(N * 0.018))
    d.ellipse((bx - 0.075 * N, by - 0.09 * N, bx + 0.075 * N, by + 0.11 * N), fill=(214, 84, 70, 255))
    d.ellipse((bx - 0.05 * N, by - 0.13 * N, bx + 0.05 * N, by - 0.05 * N), fill=(120, 40, 34, 255))
    d.line([(bx, by - 0.05 * N), (bx, by + 0.11 * N)], fill=(120, 40, 34, 255), width=int(N * 0.014))
    r = 0.2 * N
    d.ellipse((bx - r, by - r, bx + r, by + r), outline=GOLD_HI, width=int(N * 0.045))
    a = math.radians(45)
    x0, y0 = bx + math.cos(a) * r, by + math.sin(a) * r
    d.line([(x0, y0), (x0 + 0.2 * N, y0 + 0.2 * N)], fill=GOLD, width=int(N * 0.075))
    return img


def icon_plays(N):
    img, d, c = icon_base(N)
    # a longbow with a nocked arrow, aimed up-right
    ang = math.radians(-40)
    u = (math.cos(ang - math.pi / 2), math.sin(ang - math.pi / 2))   # along the bow
    n = (math.cos(ang), math.sin(ang))                                 # toward the target
    cx, cy = 0.50 * N, 0.52 * N
    pts = []
    for i in range(25):
        s = -1 + i / 12
        b = 0.09 * N * (1 - s * s)
        pts.append((cx + u[0] * s * 0.33 * N + n[0] * b, cy + u[1] * s * 0.33 * N + n[1] * b))
    d.line(pts, fill=(150, 98, 50, 255), width=int(N * 0.05), joint="curve")
    d.line(pts[10:15], fill=GOLD + (255,), width=int(N * 0.06))
    tail = (cx - n[0] * 0.17 * N, cy - n[1] * 0.17 * N)
    d.line([pts[0], tail, pts[-1]], fill=STRING + (255,), width=int(N * 0.014))
    head = (cx + n[0] * 0.30 * N, cy + n[1] * 0.30 * N)
    d.line([tail, head], fill=GOLD_HI + (255,), width=int(N * 0.025))
    nx, ny = -n[1], n[0]
    d.polygon([(head[0] + n[0] * 0.06 * N, head[1] + n[1] * 0.06 * N), (head[0] + nx * 0.035 * N, head[1] + ny * 0.035 * N),
               (head[0] - nx * 0.035 * N, head[1] - ny * 0.035 * N)], fill=GOLD_HI)
    for sgn in (1, -1):
        d.polygon([tail, (tail[0] + n[0] * 0.08 * N, tail[1] + n[1] * 0.08 * N),
                   (tail[0] + nx * sgn * 0.045 * N, tail[1] + ny * sgn * 0.045 * N)], fill=FLETCH)
    return img


def icon_reports(N):
    img, d, c = icon_base(N)
    # a scroll with a gold check
    x0, x1, y0, y1 = 0.30 * N, 0.70 * N, 0.26 * N, 0.74 * N
    d.rounded_rectangle((x0, y0, x1, y1), radius=int(N * 0.03), fill=(232, 220, 190, 255))
    for yy in (y0, y1):
        d.rounded_rectangle((x0 - 0.04 * N, yy - 0.035 * N, x1 + 0.04 * N, yy + 0.035 * N), radius=int(N * 0.035),
                            fill=(196, 170, 120, 255))
    for i in range(3):
        yy = y0 + (0.10 + i * 0.075) * N
        d.line([(x0 + 0.05 * N, yy), (x1 - 0.06 * N - (i % 2) * 0.06 * N, yy)], fill=(120, 104, 80, 255), width=int(N * 0.018))
    d.line([(0.42 * N, 0.58 * N), (0.49 * N, 0.65 * N), (0.62 * N, 0.48 * N)], fill=(40, 150, 80, 255), width=int(N * 0.05),
           joint="curve")
    return img


def make_icons():
    N = 128 * S
    for name, fn in (("icon_learns.png", icon_learns), ("icon_bugs.png", icon_bugs), ("icon_plays.png", icon_plays),
                     ("icon_reports.png", icon_reports)):
        save(fn(N), name, (128, 128), fmt="PNG")


# ==============================================================================================
# The animated GIF: one pull, kite, kill, loot, quest complete
# ==============================================================================================
GW, GH = 640, 300
FPS = 20
DUR = 8.5
GROUND = 254  # feet line, final pixels
HK = 1.22     # Herald's pixels per unit (final)


def gif_background():
    W, H = GW * S, GH * S
    img = sky(W, H, 51, moon=(W * 0.60, H * 0.25, H * 0.07), stars=150)
    img.alpha_composite(glow(img.size, (W * 0.55, H * 0.62), W * 0.42, (70, 92, 110), 90, blur=W * 0.15))
    forest_layers(img, W, H, H * 0.58, 52, moon=(W * 0.60, 0, 0), layers=3, density=1.2,
                  cols=[(44, 62, 70), (30, 44, 50), (19, 29, 33)])
    d = ImageDraw.Draw(img)
    gy = GROUND * S
    d.rectangle((0, gy - 6 * S, W, H), fill=(16, 24, 20))
    # a worn path
    d.polygon([(0, gy - 2 * S), (W, gy - 4 * S), (W, gy + 10 * S), (0, gy + 12 * S)], fill=(40, 38, 32))
    rnd = random.Random(53)
    for _ in range(140):  # grass tufts and pebbles
        x = rnd.uniform(0, W)
        y = gy + rnd.uniform(-7, 40) * S
        if rnd.random() < 0.7:
            hh = rnd.uniform(3, 8) * S
            col = (26 + rnd.randint(0, 14), 46 + rnd.randint(0, 20), 30)
            for j in (-1, 0, 1):
                d.line([(x, y), (x + j * hh * 0.35, y - hh)], fill=col, width=int(S * 0.9))
        else:
            r = rnd.uniform(0.8, 1.8) * S
            d.ellipse((x - r * 1.4, y - r, x + r * 1.4, y + r), fill=(44, 46, 46))
    vignette(img, 0.35)
    return img.resize((GW, GH), Image.LANCZOS)


# timeline (seconds) ---------------------------------------------------------------------------
HX0 = 214.0          # Herald's start x
BX0 = 548.0          # boar's start x
SHOTS = [(1.00, 0.30, 38, False), (1.72, 0.22, 22, True), (3.30, 0.20, 28, False), (3.95, 0.16, 12, False)]
RUN_A, RUN_B, HX_RUN = 2.05, 2.75, 104.0   # kite back
WALK_A, WALK_B, HX_LOOT = 4.75, 5.50, 222.0
PULL = 1.30          # first hit: the boar charges
SLOW_AT = 2.00       # concussive shot lands
DEATH = 4.12
QUEST = 6.05
FADE_IN, FADE_OUT = 0.3, 8.1   # the loop dips through the dark between runs


def boar_x(t):
    if t < PULL:
        return BX0
    if t < SLOW_AT:
        return BX0 - 190 * (t - PULL) * ease_out(seg(t, PULL, PULL + 0.25)) ** 0.5
    x1 = BX0 - 190 * (SLOW_AT - PULL)
    t2 = min(t, DEATH)
    return x1 - 72 * (t2 - SLOW_AT)


def herald_state(t):
    """x, facing, pose for time t."""
    draw, aim, run, facing, x = 0.0, 1.0, 0.0, 1, HX0
    # draws and releases
    for rel, dur, dmg, slow in SHOTS:
        a = rel - (0.7 if rel < 1.2 else 0.42)
        if a <= t < rel:
            draw = ease(seg(t, a, rel))
        elif rel <= t < rel + 0.08:
            draw = 0.0
    if t < 0.25:
        aim = ease(seg(t, -0.2, 0.25)) * 0 + ease(seg(t, 0.0, 0.25))
    # kite back
    if RUN_A <= t < RUN_B + 0.05:
        facing = -1
        aim = 1 - ease(seg(t, RUN_A, RUN_A + 0.18))
        run = ease(seg(t, RUN_A, RUN_A + 0.15)) * (1 - ease(seg(t, RUN_B - 0.12, RUN_B)))
        x = lerp(HX0, HX_RUN, ease(seg(t, RUN_A, RUN_B)) * 0.15 + seg(t, RUN_A, RUN_B) * 0.85)
    elif t >= RUN_B + 0.05:
        x = HX_RUN
        aim = ease(seg(t, RUN_B + 0.05, RUN_B + 0.3))
    if t >= DEATH + 0.25:
        aim = 1 - ease(seg(t, DEATH + 0.25, DEATH + 0.55))
    if WALK_A <= t:
        k = seg(t, WALK_A, WALK_B)
        x = lerp(HX_RUN, HX_LOOT, ease(k) * 0.3 + k * 0.7)
        run = 0.42 * ease(seg(t, WALK_A, WALK_A + 0.15)) * (1 - ease(seg(t, WALK_B - 0.15, WALK_B)))
    if t >= WALK_B:  # bow lowered while looting and handing in; raised again for the next pull
        aim = ease(seg(t, QUEST + 1.5, QUEST + 1.9))
    # stride phase from distance travelled (so feet don't skate)
    phase = abs(x - HX0) / 8.8 + (x - HX_RUN) / 8.8
    pose = herald_pose(t=t, draw=draw, aim=aim, run=run, phase=phase, look=0.0, wind=0.25 + run * 0.6)
    return x, facing, pose


def shot_arrows(t, bx):
    """(x, y, x_end) positions for arrows in flight."""
    out = []
    for rel, dur, dmg, slow in SHOTS:
        if rel <= t < rel + dur:
            hx = HX0 if rel < RUN_A else HX_RUN
            x0, y0 = hx + 31 * HK, GROUND - 78 * HK
            x1, y1 = bx - 4, GROUND - 22
            k = seg(t, rel, rel + dur)
            arc = -math.sin(k * math.pi) * 10
            out.append((lerp(x0, x1, k), lerp(y0, y1, k) + arc, lerp(x0, x1, max(0, k - 0.06)),
                        lerp(y0, y1, max(0, k - 0.06)) - math.sin(max(0, k - 0.06) * math.pi) * 10, slow))
    return out


def boar_hp(t):
    hp = 1.0
    for rel, dur, dmg, slow in SHOTS:
        if t >= rel + dur:
            hp -= dmg / 100.0
    return max(0.0, hp)


def frame(t, bg, fonts):
    W, H = GW * S, GH * S
    img = bg.resize((W, H), Image.BICUBIC).convert("RGBA") if False else None
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    # hawk circling overhead (period = loop length, wings at 4 beats per loop)
    a = 2 * math.pi * t / DUR
    hxw, hyw = (330 + 170 * math.cos(a)) * S, (88 + 20 * math.sin(a)) * S
    flap = math.sin(2 * math.pi * t * 6 / DUR) * (0.7 if math.sin(a) > -0.2 else 0.15)
    draw_hawk(layer, hxw, hyw, S * 0.95, flap, facing=-1 if math.sin(a) > 0 else 1)
    # boar
    bx = boar_x(t)
    dead = ease(seg(t, DEATH, DEATH + 0.45))
    charging = t >= PULL and t < DEATH
    gallop = (BX0 - bx) / 7.0 + t * (0.6 if not charging else 0.0)
    graze = 0.0
    corpse_alpha = 1.0
    draw_boar(layer, bx * S, (GROUND + 2) * S, S * 1.05, gallop=gallop, run=1.0 if charging else 0.0,
              facing=-1, dead=dead, slowed=1.0 if (SLOW_AT <= t < DEATH) else 0.0, alpha=corpse_alpha)
    # Herald, with a soft contact shadow
    x, facing, pose = herald_state(t)
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).ellipse(((x - 22) * S, (GROUND - 3) * S, (x + 22) * S, (GROUND + 4) * S), fill=(0, 0, 0, 120))
    layer.alpha_composite(sh.filter(ImageFilter.GaussianBlur(3 * S)))
    ImageDraw.Draw(layer).ellipse(((bx - 26) * S, (GROUND - 2) * S, (bx + 26) * S, (GROUND + 4) * S), fill=(0, 0, 0, 70))
    draw_herald(layer, x * S, GROUND * S, HK * S, facing, pose, light=(1.0, -0.5), rim_alpha=200)
    d = ImageDraw.Draw(layer)
    # arrows in flight
    for ax, ay, tx, ty, slow in shot_arrows(t, bx):
        draw_arrow(d, tx * S, ty * S, ax * S, ay * S, S * 0.9)
        if slow:
            layer.alpha_composite(glow(layer.size, (ax * S, ay * S), 6 * S, BLUE, 200))
            d = ImageDraw.Draw(layer)
    small = layer.resize((GW, GH), Image.LANCZOS)
    out = bg.copy()
    out.alpha_composite(small)
    hud(out, t, bx, x, fonts)
    return out


def text_c(d, xy, s, f, fill, anchor="mm", stroke=2):
    sa = fill[3] if len(fill) > 3 else 255
    d.text(xy, s, font=f, fill=fill, anchor=anchor, stroke_width=stroke, stroke_fill=(6, 8, 12, sa))


def panel(d, box, alpha=200):
    d.rounded_rectangle(box, radius=4, fill=(10, 13, 20, alpha), outline=(109, 84, 38, 255), width=1)


def bar(d, box, frac, col, back=(30, 34, 44, 255)):
    x0, y0, x1, y1 = box
    d.rectangle(box, fill=back)
    if frac > 0:
        d.rectangle((x0, y0, x0 + (x1 - x0) * clamp(frac), y1), fill=col)
    d.rectangle(box, outline=(0, 0, 0, 255))


def hud(img, t, bx, hx, F):
    over = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    # floating combat text and the boar's health bar
    hp = boar_hp(t)
    alive = t < DEATH + 0.3
    if SLOW_AT <= t < DEATH:
        ph = (t * 1.6) % 1
        for j in range(2):
            q = (ph + j * 0.5) % 1
            d.ellipse((bx - 10 - 14 * q, GROUND - 2 - 3 * q, bx + 10 + 14 * q, GROUND + 3 + 3 * q),
                      outline=BLUE + (int(200 * (1 - q)),), width=1)
    if t >= 0.4 and alive:
        a = int(255 * (1 - seg(t, DEATH, DEATH + 0.3)))
        bw = 40
        y = GROUND - 46
        d.rectangle((bx - bw / 2, y, bx + bw / 2, y + 4), fill=(20, 8, 8, a))
        d.rectangle((bx - bw / 2, y, bx - bw / 2 + bw * hp, y + 4), fill=(214, 52, 44, a))
        text_c(d, (bx, y - 7), "Wild Boar", F["tiny"], (240, 120, 100, a), stroke=1)
    for rel, dur, dmg, slow in SHOTS:
        hit = rel + dur
        if hit <= t < hit + 0.6:
            k = seg(t, hit, hit + 0.6)
            a = int(255 * (1 - k ** 2))
            ox = 18 if slow else -2
            text_c(d, (bx + ox, GROUND - 60 - 24 * ease_out(k)), str(dmg), F["dmg"], (255, 236, 160, a))
            if slow:
                text_c(d, (bx + ox, GROUND - 78 - 24 * ease_out(k)), "Slowed", F["tiny"], (150, 210, 255, a), stroke=1)
    # Herald's name plate
    text_c(d, (hx, GROUND - 120 * HK), "Herald", F["tiny"], (120, 230, 150, 255), stroke=1)
    # loot: sparkles at the corpse, an item toast
    if DEATH + 0.4 <= t < WALK_B:
        k = (t * 3) % 1
        for i in range(3):
            ang = 2 * math.pi * (i / 3 + t * 0.4)
            sx, sy = bx + 8 + math.cos(ang) * 10, GROUND - 12 + math.sin(ang) * 5
            sparkle(d, sx, sy, 2.5 + 1.5 * math.sin(t * 9 + i), GOLD_HI + (230,))
    if WALK_B <= t:
        k = ease_out(seg(t, WALK_B, WALK_B + 0.25))
        fade = 1 - seg(t, WALK_B + 2.2, WALK_B + 2.5)
        a = int(255 * fade * k)
        if a > 0:
            y = 276 - 4 * k
            text_c(d, (GW / 2 + 70, y), "You receive loot: [Tough Boar Hide]", F["tiny"], (120, 230, 150, a), stroke=1)
            # a hide pops off the corpse into the bag
            if t < WALK_B + 0.5:
                q = seg(t, WALK_B, WALK_B + 0.5)
                ix, iy = lerp(bx + 6, hx, q), GROUND - 14 - math.sin(q * math.pi) * 40 - q * 40
                d.rectangle((ix - 5, iy - 5, ix + 5, iy + 5), fill=(150, 96, 52, 255), outline=(30, 200, 90, 255))
    # quest tracker (top right)
    have = 3 + (1 if t >= WALK_B + 0.1 else 0)
    done = have >= 4
    panel(d, (452, 10, 630, 58))
    d.text((462, 18), "Hides for the Farmer", font=F["small_b"], fill=(255, 210, 0, 255))
    col = (120, 230, 150, 255) if done else (220, 224, 232, 255)
    d.text((468, 36), "- Tough Boar Hide: %d/4" % have, font=F["tiny"], fill=col)
    if done:
        sparkle(d, 616, 41, 4, (120, 230, 150, 255))
    # Herald's frame (top left): level, XP bar
    xp = 0.58 + 0.06 * ease(seg(t, DEATH, DEATH + 0.4)) + 0.24 * ease(seg(t, QUEST + 0.2, QUEST + 0.9))
    panel(d, (10, 10, 200, 58))
    d.ellipse((16, 15, 52, 51), fill=(30, 44, 36, 255), outline=(232, 188, 84, 255), width=2)
    d.text((34, 33), "H", font=F["small_b"], fill=GOLD_HI, anchor="mm")
    d.text((60, 17), "Herald", font=F["small_b"], fill=(255, 255, 255, 255))
    d.text((192, 18), "Lv 4 Hunter", font=F["tiny"], fill=(180, 188, 204, 255), anchor="ra")
    bar(d, (60, 37, 192, 45), xp, (148, 92, 214, 255))
    d.text((60, 47), "XP %d%%" % round(xp * 100), font=F["micro"], fill=(180, 188, 204, 255))
    # learning stat (bottom left): kite timing confidence
    learn = 0.71 + 0.03 * ease(seg(t, 2.9, 3.2)) + 0.08 * ease(seg(t, QUEST + 0.5, QUEST + 1.2))
    panel(d, (10, 262, 236, 292))
    d.text((18, 268), "LEARNING", font=F["micro_b"], fill=GOLD, anchor="la")
    d.text((76, 268), "kite timing vs Wild Boar", font=F["micro"], fill=(200, 206, 220, 255), anchor="la")
    bar(d, (18, 280, 190, 286), learn, (94, 224, 138, 255))
    d.text((228, 283), "%d%%" % round(learn * 100), font=F["micro_b"], fill=(140, 240, 170, 255), anchor="rm")
    if QUEST + 0.5 <= t < QUEST + 1.8:
        k = seg(t, QUEST + 0.5, QUEST + 1.8)
        text_c(d, (205, 262 - 16 * ease_out(k)), "+8", F["small_b"], (140, 240, 170, int(255 * (1 - k ** 2))), stroke=1)
    # quest complete banner
    if QUEST <= t:
        k = ease_out(seg(t, QUEST, QUEST + 0.35))
        fade = 1 - seg(t, QUEST + 1.4, QUEST + 1.7)
        if fade > 0:
            a = int(255 * fade)
            cx, cy = GW / 2 + 52, 96
            w = 170 * (0.7 + 0.3 * k)
            d.rounded_rectangle((cx - w / 2, cy - 22, cx + w / 2, cy + 22), radius=6, fill=(14, 18, 26, int(225 * fade)),
                                outline=(232, 188, 84, a), width=2)
            text_c(d, (cx + 14, cy - 4), "Quest complete", F["title"], (255, 230, 150, a), stroke=0)
            text_c(d, (cx + 14, cy + 13), "+450 XP", F["tiny"], (200, 160, 255, a), stroke=0)
            # check mark
            d.line([(cx - w / 2 + 14, cy - 1), (cx - w / 2 + 20, cy + 6), (cx - w / 2 + 31, cy - 8)],
                   fill=(94, 224, 138, a), width=3, joint="curve")
    # label: an illustration
    d.text((GW - 8, GH - 8), "illustration", font=F["micro"], fill=(148, 163, 184, 200), anchor="rd")
    img.alpha_composite(over)


def make_gif(write=True, preview=()):
    bg = gif_background().convert("RGBA")
    F = {"tiny": font(SANS_B, 10), "micro": font(SANS, 9), "micro_b": font(SANS_B, 9), "small_b": font(SANS_B, 11),
         "dmg": font(SANS_B, 15), "title": font(SERIF, 15)}
    n = int(DUR * FPS)
    frames = []
    for i in range(n):
        t = i / FPS
        frames.append(frame(t, bg, F))
    # loop: fade in from, and out to, the dark slate between runs
    dark = Image.new("RGBA", (GW, GH), (8, 10, 16, 255))
    for i in range(n):
        t = i / FPS
        k = max(1 - seg(t, 0, FADE_IN), seg(t, FADE_OUT, DUR - 1.0 / FPS))
        if k > 0:
            frames[i] = Image.blend(frames[i], dark, ease(k) * 0.92)
    for i in preview:
        frames[i].save(os.path.join(OUT, "_preview_%03d.png" % i))
    if not write:
        return frames
    # one global palette tuned on a spread of frames
    sample = Image.new("RGB", (GW, GH * 7))
    for j, i in enumerate((20, 40, 56, 84, 116, 130)):
        sample.paste(frames[i].convert("RGB"), (0, GH * j))
    sample.paste(bg.convert("RGB"), (0, GH * 6))
    pal = sample.quantize(colors=255, method=Image.MEDIANCUT, dither=Image.NONE)
    # the static background is dithered once (no banding in the moon's glow); wherever a frame still
    # shows that background pixel, it reuses the dithered index, so unchanged areas stay identical
    # between frames and the GIF stays small. Moving parts and the HUD are quantized without dither.
    bg_rgb = np.asarray(bg.convert("RGB"))
    bg_q = np.asarray(bg.convert("RGB").quantize(palette=pal, dither=Image.FLOYDSTEINBERG))
    q = []
    for f in frames:
        rgb = f.convert("RGB")
        qi = rgb.quantize(palette=pal, dither=Image.NONE)
        arr = np.array(qi)
        same = (np.asarray(rgb) == bg_rgb).all(axis=2)
        arr[same] = bg_q[same]
        im = Image.fromarray(arr, "P")
        im.putpalette(qi.getpalette())
        q.append(im)
    path = os.path.join(OUT, "herald_playing.gif")
    q[0].save(path, save_all=True, append_images=q[1:], duration=int(1000 / FPS), loop=0, optimize=False, disposal=1)
    print("wrote", os.path.relpath(path, ROOT), "%d frames, %.2f MB" % (n, os.path.getsize(path) / 1048576))
    save(frames[int(QUEST * FPS) + 10], "herald_playing.webp")
    return frames


def main():
    os.makedirs(OUT, exist_ok=True)
    if "--frames-only" in sys.argv:
        make_gif(write=False, preview=[4, 18, 38, 50, 66, 82, 100, 116, 128, 150])
        return
    if "--stills-only" not in sys.argv:
        make_gif()
    make_hero()
    make_banner()
    make_og()
    make_avatar()
    make_icons()


if __name__ == "__main__":
    main()
