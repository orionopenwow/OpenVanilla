"""Herald's Sim: a 1.12 damage simulator for comparing two sets of gear, or stats, on one class.

A fight against a level 63 raid boss, simulated many times over:
  * melee and ranged use 1.12's attack table: miss (9%, 28% when dual-wielding), dodge 6.5%,
    glancing blows 40% of white swings at 65% damage, crits at 2x, 3% crit suppressed by the
    level gap; armour 3731, or 336 with Sunder, Faerie Fire and Curse of Recklessness up;
  * spells: 17% miss before hit (capped at 99% to land), crits at 1.5x or 2x with the class's
    usual talent, spell power at each spell's 1.12 coefficient.
Each class is reduced to its core rotation (what a levelling or raiding player actually presses
most), so the answer is a comparison — "set B does 4.1% more" and what each stat is worth — not
a log-perfect replay. No mana, no procs from items, no buffs beyond the armour debuffs toggle.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field, replace

BOSS_LEVEL = 63
BOSS_ARMOR = 3731
DEBUFFED_ARMOR = 336
FIGHT = 180.0


@dataclass(frozen=True)
class Stats:
    weapon_min: float = 0
    weapon_max: float = 0
    speed: float = 2.6
    ap: float = 0
    crit: float = 5.0          # %
    hit: float = 0.0           # %
    spell_power: float = 0
    spell_crit: float = 5.0    # %
    spell_hit: float = 0.0     # %
    dual_wield: bool = False


PRESETS = {  # roughly "fresh 60 in dungeon blues"
    "Warrior": Stats(110, 205, 3.6, 1250, 22, 6),
    "Rogue": Stats(72, 134, 2.6, 1150, 25, 7, dual_wield=True),
    "Paladin": Stats(110, 205, 3.6, 1000, 18, 5),
    "Hunter": Stats(85, 125, 3.0, 1600, 20, 6),
    "Mage": Stats(spell_power=420, spell_crit=12, spell_hit=6),
    "Warlock": Stats(spell_power=480, spell_crit=9, spell_hit=6),
    "Shaman": Stats(spell_power=400, spell_crit=11, spell_hit=4),
    "Priest": Stats(spell_power=430, spell_crit=6, spell_hit=6),
    "Druid": Stats(spell_power=420, spell_crit=10, spell_hit=5),
}
MELEE = {"Warrior", "Rogue", "Paladin"}
RANGED = {"Hunter"}
SPELL = {"Mage", "Warlock", "Shaman", "Priest", "Druid"}
SIMMABLE = tuple(PRESETS)

# name, min, max, cast seconds (cooldown between casts), coefficient, crit multiplier, can crit
SPELLS = {
    "Mage": [("Frostbolt", 515, 555, 2.5, 0.814, 2.0, True)],
    "Warlock": [("Shadow Bolt", 455, 507, 2.5, 0.857, 2.0, True)],
    "Shaman": [("Lightning Bolt", 428, 477, 2.0, 0.857, 2.0, True)],
    "Priest": [("Mind Blast", 503, 531, 1.5, 0.429, 1.5, True, 8.0), ("Mind Flay", 426, 426, 3.0, 0.45, 1.0, False)],
    "Druid": [("Starfire", 496, 585, 3.0, 1.0, 1.5, True)],
}


@dataclass
class Result:
    dps: float
    by_ability: dict = field(default_factory=dict)   # name -> dps
    low: float = 0.0
    high: float = 0.0


def _mitigation(armor):
    return armor / (armor + 400 + 85 * 60)


def _swing(rng, s, white, dw_penalty):
    """One melee/ranged attack's outcome multiplier on the attack table (1.12, +3 levels)."""
    miss = max(0.0, (28.0 if dw_penalty else 9.0) - s.hit) / 100
    dodge = 0.065 if white != "ranged" else 0.0
    glance = 0.40 if white == "white" else 0.0
    crit = max(0.0, s.crit - 3.0) / 100
    r = rng.random()
    if r < miss:
        return 0.0, False
    r -= miss
    if r < dodge:
        return 0.0, False
    r -= dodge
    if r < glance:
        return 0.65, False
    r -= glance
    if r < crit:
        return 2.0, True
    return 1.0, False


def _weapon(rng, s, normalized=None):
    base = rng.uniform(s.weapon_min, s.weapon_max)
    return base + s.ap / 14 * (normalized if normalized else s.speed)


def _fight_physical(cls, s, rng, armor):
    dmg = {}
    mit = 1 - _mitigation(armor)
    add = lambda k, v: dmg.__setitem__(k, dmg.get(k, 0.0) + v)  # noqa: E731
    t_main, t_off, t_special, t_special2 = 0.0, s.speed / 2 if s.dual_wield else 1e9, 0.5, 1.5
    ranged = cls in RANGED
    speed = s.speed / 1.15 if ranged else s.speed   # a hunter's quiver
    while True:
        t = min(t_main, t_off, t_special, t_special2)
        if t > FIGHT:
            break
        if t == t_main:
            m, _ = _swing(rng, s, "ranged" if ranged else "white", s.dual_wield)
            v = _weapon(rng, s) + (20 * s.speed if ranged else 0)   # ammo
            add("Auto Shot" if ranged else "Melee", v * m * mit)
            if cls == "Paladin" and m and rng.random() < 7 * s.speed / 60:
                m2, _ = _swing(rng, s, "special", False)
                add("Seal of Command", _weapon(rng, s) * 0.70 * m2)   # holy: no armour
            t_main += speed
        elif t == t_off:
            m, _ = _swing(rng, s, "white", True)
            add("Off-hand", _weapon(rng, s) * 0.5 * m * mit)
            t_off += s.speed
        elif t == t_special:
            m, _ = _swing(rng, s, "special", False)
            if cls == "Warrior":
                add("Bloodthirst", 0.45 * s.ap * m * mit)
                t_special += 6.0
            elif cls == "Rogue":
                add("Sinister Strike", (_weapon(rng, s, 2.4) + 68) * m * mit)
                t_special += 4.0
            elif cls == "Hunter":
                add("Multi-Shot", (_weapon(rng, s, 2.8) + 150) * m * mit)
                t_special += 10.0
            else:  # Paladin: Judgement of Command, roughly
                add("Judgement", 90 + 0.43 * s.ap / 2 * m if m else 0)
                t_special += 10.0
        else:
            if cls == "Warrior":
                m, _ = _swing(rng, s, "special", False)
                add("Whirlwind", _weapon(rng, s, 3.3) * m * mit)
            t_special2 += 10.0
    return dmg


def _fight_spell(cls, s, rng):
    dmg = {}
    miss = max(0.01, 0.17 - s.spell_hit / 100)
    crit = s.spell_crit / 100
    spells = SPELLS[cls]
    ready = {sp[0]: 0.0 for sp in spells}
    t = 0.0
    while t < FIGHT:
        for sp in spells:
            name, lo, hi, cast, coef, crit_mult, can_crit = sp[:7]
            cd = sp[7] if len(sp) > 7 else 0.0
            if ready[name] <= t:
                break
        else:
            t = min(ready.values())
            continue
        t += cast
        if t > FIGHT:
            break
        ready[name] = t + cd - cast if cd else t
        if rng.random() < miss:
            continue
        v = rng.uniform(lo, hi) + s.spell_power * coef
        if can_crit and rng.random() < crit:
            v *= crit_mult
        dmg[name] = dmg.get(name, 0.0) + v
    return dmg


def simulate(cls, stats, iterations=400, seed=1, debuffs=True):
    if cls not in PRESETS:
        raise ValueError(f"No sim for {cls} yet.")
    rng = random.Random(seed)
    armor = DEBUFFED_ARMOR if debuffs else BOSS_ARMOR
    totals, runs = {}, []
    for _ in range(iterations):
        d = _fight_spell(cls, stats, rng) if cls in SPELL else _fight_physical(cls, stats, rng, armor)
        for k, v in d.items():
            totals[k] = totals.get(k, 0.0) + v
        runs.append(sum(d.values()) / FIGHT)
    runs.sort()
    mean = sum(runs) / len(runs)
    return Result(mean, {k: v / iterations / FIGHT for k, v in sorted(totals.items(), key=lambda kv: -kv[1])},
                  runs[int(len(runs) * 0.05)], runs[int(len(runs) * 0.95) - 1])


def stat_weights(cls, stats, iterations=600, seed=7, debuffs=True):
    """What 1 point / 1% of each stat is worth, in DPS (same random rolls for each, so the
    differences aren't noise)."""
    base = simulate(cls, stats, iterations, seed, debuffs).dps
    if cls in SPELL:
        steps = {"Spell power (+10)": replace(stats, spell_power=stats.spell_power + 10),
                 "Spell crit (+1%)": replace(stats, spell_crit=stats.spell_crit + 1),
                 "Spell hit (+1%)": replace(stats, spell_hit=stats.spell_hit + 1)}
    else:
        steps = {"Attack power (+10)": replace(stats, ap=stats.ap + 10),
                 "Crit (+1%)": replace(stats, crit=stats.crit + 1),
                 "Hit (+1%)": replace(stats, hit=stats.hit + 1)}
    return {k: simulate(cls, v, iterations, seed, debuffs).dps - base for k, v in steps.items()}


def compare(cls, a, b, iterations=500, seed=3, debuffs=True):
    ra, rb = simulate(cls, a, iterations, seed, debuffs), simulate(cls, b, iterations, seed, debuffs)
    pct = (rb.dps - ra.dps) / ra.dps * 100 if ra.dps else 0.0
    return ra, rb, pct


FIELDS_PHYSICAL = (("weapon_min", "Weapon damage, low"), ("weapon_max", "Weapon damage, high"),
                   ("speed", "Weapon speed"), ("ap", "Attack power"), ("crit", "Crit %"), ("hit", "Hit %"))
FIELDS_SPELL = (("spell_power", "Spell power"), ("spell_crit", "Spell crit %"), ("spell_hit", "Spell hit %"))


def fields_for(cls):
    return FIELDS_SPELL if cls in SPELL else FIELDS_PHYSICAL


def stats_from(cls, values):
    """Stats from the Sim page's fields ({field: text}); bad numbers fall back to the preset."""
    base = PRESETS[cls]
    kw = {}
    for key, _ in fields_for(cls):
        try:
            v = float(str(values.get(key, "")).strip())
            if v >= 0:
                kw[key] = v
        except ValueError:
            pass
    s = replace(base, **kw)
    if s.weapon_max < s.weapon_min:
        s = replace(s, weapon_max=s.weapon_min)
    if s.speed <= 0.5:
        s = replace(s, speed=base.speed or 2.6)
    return s
