"""Shared formulas and helpers for Open Vanilla Autopilot (Phase 0).

Formulas follow the cmangos-classic core (src/game/Tools/Formulas.h, Quests/QuestDef.cpp,
Entities/Unit.cpp); see README.md for the exact references and the assumptions layered on top.
Python 3.10+ standard library only.
"""
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
KB_PATH = os.path.join(HERE, "kb", "elwynn_human_hunter.json")
OUT_DIR = os.path.join(HERE, "out")

RUN_SPEED = 7.0        # yd/s, player and (by assumption) chasing mobs
DETOUR = 1.35          # straight line -> walked path factor
MAX_LEVEL = 12


# ── XP (cmangos classic Formulas.h / QuestDef.cpp) ──
def gray_level(pl):
    if pl <= 5:
        return 0
    if pl <= 39:
        return pl - 5 - pl // 10
    if pl <= 59:
        return pl - 1 - pl // 5
    return pl - 9


def zero_difference(pl):
    for lim, zd in ((8, 5), (10, 6), (12, 7), (16, 8), (20, 9), (30, 11), (40, 12), (45, 13),
                    (50, 14), (55, 15), (60, 16)):
        if pl < lim:
            return zd
    return 17


def kill_xp(pl, mob_level, elite=False, xp_mult=1.0):
    """XP for a solo kill (no rested bonus, Rate.XP.Kill = 1)."""
    base = pl * 5 + 45
    if mob_level >= pl:
        diff = min(mob_level - pl, 4)
        xp = base * (1.0 + 0.05 * diff)
    elif mob_level > gray_level(pl):
        xp = base * (1.0 - (pl - mob_level) / zero_difference(pl))
    else:
        return 0
    if elite:
        xp *= 2.5   # open world counts as NoRaid in the core -> 2.5
    xp *= xp_mult
    return int(round(xp))


def quest_full_xp(rew_money_max_level, quest_level):
    """Full quest XP, cmangos Quest::XPValue (QuestLevel <= 60 -> RewMoneyMaxLevel / 0.6)."""
    if rew_money_max_level <= 0:
        return 0
    q = quest_level
    div = 0.6
    if q >= 65:
        div = 6.0
    elif q == 64:
        div = 4.8
    elif q == 63:
        div = 3.6
    elif q == 62:
        div = 2.4
    elif q == 61:
        div = 1.2
    elif q <= 0:
        div = 6.0   # QuestLevel -1/0 wraps to a huge uint in the core
    return rew_money_max_level / div


def quest_xp(rew_money_max_level, quest_level, pl):
    full = quest_full_xp(rew_money_max_level, quest_level)
    if full <= 0:
        return 0
    ql = quest_level if quest_level > 0 else pl
    if pl <= ql + 5:
        f = 1.0
    else:
        f = {6: 0.8, 7: 0.6, 8: 0.4, 9: 0.2}.get(pl - ql, 0.1)
    return int(math.ceil(full * f - 1e-6))


# ── geometry ──
def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def travel_seconds(a, b, speed=RUN_SPEED, detour=DETOUR):
    return dist(a, b) * detour / speed


def load_json(path):
    with open(path) as f:
        return json.load(f)


def save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")


def load_kb(path=KB_PATH):
    if not os.path.exists(path) and os.path.exists(path + ".gz"):
        import gzip
        with gzip.open(path + ".gz", "rt") as f:
            return json.load(f)
    return load_json(path)
