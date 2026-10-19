#!/usr/bin/env python3
"""Event-driven v0 Hunter combat simulator (levels 1-12) against the Elwynn mobs in the KB.

  combat_sim.py [--kb kb/elwynn_human_hunter.json] [--runs 40] [--out out/combat_costs.json]

One fight = one hunter vs one mob on a line (distance d). The simulator jumps from event to event
(reload done, aim done, swings, GCD, cooldowns, DoT ticks, slow expiry, the mob crossing 35/8/5 yd,
kite runs ending). Movement between events is linear, so crossing times are exact.

Timing rules (tested in tests/test_autopilot_sim.py):
  * Auto Shot: reload (weapon speed - 0.5 s) runs while moving; then a 0.5 s aim that needs the
    hunter to stand still: moving cancels the aim, and it restarts on stopping. A shot needs 8-35 yd.
  * Instants (Serpent Sting, Arcane Shot, Concussive Shot, Hunter's Mark) are usable while moving,
    1.5 s GCD, 8-35 yd; Raptor Strike replaces the next melee swing (6 s CD); Wing Clip 5 yd, GCD.
  * The mob chases at 7.0 x SpeedRun (template) yd/s, halved by Concussive (4 s) / Wing Clip (10 s),
    and swings while within 5 yd (also at a hunter running away).
See README.md for every number this uses.
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import KB_PATH, OUT_DIR, RUN_SPEED, kill_xp, load_kb, save_json  # noqa: E402

MELEE_RANGE, MIN_RANGE, MAX_RANGE = 5.0, 8.0, 35.0
AIM = 0.5
GCD = 1.5
INF = float("inf")
EPS = 1e-9

# Gear assumption (no bow is sold or rewarded in Northshire/Elwynn; see README)
BOW = {"min": 2, "max": 5, "speed": 2.3, "name": "Worn Shortbow"}
AMMO_DPS = 1.5                       # Rough Arrow
MELEE_BY_LEVEL = [                   # (from level, min, max, speed, name)
    (1, 1, 3, 2.0, "Worn Axe"),
    (4, 6, 9, 2.8, "Militia Quarterstaff (quest 18)"),
    (8, 6, 12, 2.1, "Well-used Sword (quest 46)"),
]
GEAR_ARMOR = lambda lvl: 20 + 8 * lvl          # noqa: E731 starter cloth/leather + quest greens
SEARCH_S = 12.0                      # default time between kills (find + walk to the next mob)
DEATH_RUN_S = 60.0                   # release + corpse run (Northshire/Goldshire graveyards are close)
CASTER_CASTS, CASTER_RANGE, CASTER_CAST_S, CASTER_BOLT = 3, 30.0, 3.0, 1.4   # mage-class mobs: 3 bolts
HUMANOID_FLEE_S = 2.0                # humanoids flee at 15 % HP: flat extra seconds


def spell_ranks(level):
    """Spells known at a level (our realm auto-learns every rank at level-up). Values from spell_template."""
    s = {"raptor": (5, 15) if level < 8 else (11, 25)}           # (bonus dmg, mana)
    if level >= 4:
        s["sting"] = (20, 15) if level < 10 else (40, 30)          # (total dmg over 15 s, mana)
        s["monkey"] = True
    if level >= 6:
        s["arcane"] = (13, 25) if level < 12 else (21, 35)
        s["mark"] = (20, 15)                                       # (+RAP vs target, mana)
    if level >= 8:
        s["conc"] = True
    if level >= 10:
        s["hawk"] = 20
    if level >= 12:
        s["wingclip"] = (5, 40)
    return s


def hunter_stats(kb, level):
    P = kb["player"]
    ls = P["levelstats"][str(level)]
    cl = P["classlevelstats"][str(level)]
    sta, inte, agi, stra = ls["sta"], ls["inte"], ls["agi"], ls["str"]
    spi = ls["spi"] * 1.05                                         # The Human Spirit
    hp = cl["basehp"] + min(sta, 20) + max(sta - 20, 0) * 10
    mana = cl["basemana"] + min(inte, 20) + max(inte - 20, 0) * 15
    sp = spell_ranks(level)
    rap = level * 2 + agi * 2 - 10 + sp.get("hawk", 0)
    map_ = level * 2 + stra + agi - 20
    mw = [m for m in MELEE_BY_LEVEL if m[0] <= level][-1]
    return {
        "level": level, "hp": hp, "mana": mana, "base_mana": cl["basemana"], "rap": rap, "map": map_,
        "bow": dict(BOW), "melee": {"min": mw[1], "max": mw[2], "speed": mw[3], "name": mw[4]},
        "armor": agi * 2 + GEAR_ARMOR(level), "crit": 0.05, "dodge": 0.05 + (0.08 if "monkey" in sp else 0.0),
        "regen_hp": max(0.0, spi * 0.43 - 5.5), "regen_mana": (spi / 5 + 15) / 2.0, "spells": sp,
    }


def mob_stats(c, level, speed_override=None):
    ls = c.get("levelstats", {}).get(str(level))
    if ls:
        hp = ls["hp"]
        var = c.get("DamageVariance") or 1.0
        attack = (c.get("MeleeBaseAttackTime") or 2000) / 1000.0
        base = ls["base_dmg"]
        mult = c.get("DamageMultiplier") or 1.0
        dmin = (base * (1 - var / 2) + ls["melee_ap"] / 14 * attack) * mult
        dmax = (base * (1 + var / 2) + ls["melee_ap"] / 14 * attack) * mult
        armor = round(ls["armor"] * (c.get("ArmorMultiplier") or 1.0))
        src = "classlevelstats"
    else:   # template min/max fields, else a level-based guess
        lo, hi = c.get("MinLevel", level), c.get("MaxLevel", level)
        rel = 0 if hi == lo else (level - lo) / (hi - lo)
        hp = (c.get("MinLevelHealth") or 0) + rel * ((c.get("MaxLevelHealth") or 0) - (c.get("MinLevelHealth") or 0))
        attack = (c.get("MeleeBaseAttackTime") or 2000) / 1000.0
        mult = c.get("DamageMultiplier") or 1.0
        dmin, dmax = (c.get("MinMeleeDmg") or 0) * mult, (c.get("MaxMeleeDmg") or 0) * mult
        armor = c.get("Armor") or 0
        src = "template"
        if hp <= 0 or dmax <= 0:
            hp, dmin, dmax, armor, src = 20 + 15 * level, 1 + 0.8 * level, 2 + 1.2 * level, 20 * level, "guess"
    elite = (c.get("Rank") or 0) in (1, 2)
    return {"level": level, "hp": max(1.0, hp), "dmin": dmin, "dmax": dmax, "attack": attack, "armor": armor,
            "speed": speed_override or RUN_SPEED * (c.get("SpeedRun") or 1.0), "elite": elite,
            "humanoid": c.get("CreatureType") == 7, "stats_from": src, "beast": c.get("CreatureType") == 1,
            "caster": c.get("UnitClass") == 8}


def mitigation(armor, attacker_level):
    return armor / (armor + 400.0 + 85.0 * attacker_level)


def pet_stats(kb, level):
    ps = kb["player"].get("pet_levelstats", {}).get(str(level))
    hp = ps["hp"] if ps else 20 * level
    armor = ps["armor"] if ps else 50 * level
    return {"hp": hp, "armor": armor, "dps": 0.6 * level + 1.0, "attack": 2.0}


class Fight:
    """One hunter vs one mob. tactic: 'stand', 'kite', 'melee', 'pet'. Deterministic for a given rng."""

    def __init__(self, h, m, tactic, params, rng, pet=None):
        self.h, self.m, self.tactic, self.p, self.rng = h, m, tactic, params, rng
        self.pet = pet

    # ── damage helpers ──
    def _roll_hit(self, miss, dodge=0.0, crit=0.05, crit_mult=2.0):
        r = self.rng.random()
        if r < miss + dodge:
            return 0.0
        return crit_mult if r < miss + dodge + crit else 1.0

    def _ranged_dmg(self, bonus_rap=0.0):
        h, m = self.h, self.m
        miss = 0.05 + 0.01 * max(0, m["level"] - h["level"])
        k = self._roll_hit(miss, 0.0, h["crit"])
        if not k:
            return 0.0
        b = h["bow"]
        raw = self.rng.uniform(b["min"], b["max"]) + AMMO_DPS * b["speed"] + (h["rap"] + bonus_rap) / 14 * b["speed"]
        return raw * k * (1 - mitigation(m["armor"], h["level"]))

    def _melee_dmg(self, bonus=0.0):
        h, m = self.h, self.m
        miss = 0.05 + 0.01 * max(0, m["level"] - h["level"])
        k = self._roll_hit(miss, 0.05, h["crit"])
        if not k:
            return 0.0
        w = h["melee"]
        raw = self.rng.uniform(w["min"], w["max"]) + h["map"] / 14 * w["speed"] + bonus
        return raw * k * (1 - mitigation(m["armor"], h["level"]))

    def _mob_hit(self, target_armor, target_level, dodge):
        m = self.m
        miss = max(0.0, 0.05 + 0.01 * (target_level - m["level"]))
        k = self._roll_hit(miss, dodge, 0.05)
        if not k:
            return 0.0
        return self.rng.uniform(m["dmin"], m["dmax"]) * k * (1 - mitigation(target_armor, m["level"]))

    def run(self, max_t=180.0):
        h, m, p, sp = self.h, self.m, self.p, self.h["spells"]
        t = 0.0
        hp, mana, mhp = h["hp"], h["mana"], m["hp"]
        mana0 = mana
        pre = 0.0
        bonus_rap = 0.0
        use = p.get("spells", ())
        if "mark" in sp and "mark" in use and mana >= sp["mark"][1]:
            mana -= sp["mark"][1]
            bonus_rap = sp["mark"][0]
            pre += GCD                                  # cast before the pull
        d = p.get("open", MAX_RANGE)
        pet = None
        if self.tactic == "pet" and self.pet:
            pet = dict(self.pet)
            pet["hp_now"] = pet["hp"]
            pet["next"] = 0.0
            d = p.get("open", 30.0)
        moving = False                                   # hunter running away
        state = "ranged" if d >= MIN_RANGE else "melee"
        reload_end = 0.0                                 # first shot needs no reload
        aim_end = None
        gcd_end = 0.0
        cds = {"arcane": 0.0, "conc": 0.0, "raptor": 0.0}
        slow_end = -1.0
        dot_ticks, dot_next, dot_amt = 0, INF, 0.0
        mob_swing = None                                 # next mob swing time while in reach
        casts_left = CASTER_CASTS if m.get("caster") else 0
        cast_end = None
        h_swing = None
        run_end = None
        cycles = 0
        log = []
        pet_holds = pet is not None
        mob_target_pet = pet is not None
        died = False

        def mob_speed(now):
            return m["speed"] * (0.5 if now < slow_end else 1.0)

        while True:
            if mhp <= 0 or hp <= 0 or t > max_t:
                break
            # the mob chases while out of reach or while the hunter runs; a pet-tanked mob stands still
            casting = casts_left > 0 and not mob_target_pet and MELEE_RANGE + EPS < d <= CASTER_RANGE + EPS
            chasing = (not mob_target_pet) and (d > MELEE_RANGE + EPS or moving) and not casting
            vm = mob_speed(t) if chasing else 0.0
            vh = RUN_SPEED if moving else 0.0
            closing = vm - vh
            ev = []
            # distance crossings
            if closing > EPS:
                for thr in (MAX_RANGE, CASTER_RANGE, MIN_RANGE, MELEE_RANGE):
                    if d > thr + EPS:
                        ev.append((t + (d - thr) / closing, "cross"))
            elif closing < -EPS:
                for thr in (MELEE_RANGE, MIN_RANGE, MAX_RANGE):
                    if d < thr - EPS:
                        ev.append((t + (thr - d) / -closing, "cross"))
            # auto shot
            if state == "ranged" and not moving and MIN_RANGE <= d + EPS and d <= MAX_RANGE + EPS:
                if aim_end is None:
                    aim_start = max(t, reload_end)
                    if aim_start > t + EPS:
                        ev.append((aim_start, "reload"))
                    else:
                        aim_end = t + AIM
                if aim_end is not None:
                    ev.append((aim_end, "shot"))
            # instants
            if state == "ranged" and MIN_RANGE <= d + EPS and d <= MAX_RANGE + EPS:
                ev.append((max(t, gcd_end), "gcd"))
            if state == "melee" and d <= MELEE_RANGE + EPS and not moving:
                if h_swing is None:
                    h_swing = t
                ev.append((h_swing, "hswing"))
                if "wingclip" in sp and "wingclip" in use and t >= slow_end:
                    ev.append((max(t, gcd_end), "gcd"))
            if casting:
                if cast_end is None:
                    cast_end = t + CASTER_CAST_S
                ev.append((cast_end, "mcast"))
            elif cast_end is not None and not casting:
                cast_end = None                          # moved out of range / into melee: cast lost
            if not mob_target_pet and d <= MELEE_RANGE + EPS:
                if mob_swing is None:
                    mob_swing = t
                ev.append((mob_swing, "mswing"))
            if pet is not None and pet_holds:
                ev.append((pet["next"], "pswing"))
                if mob_swing is None:
                    mob_swing = t
                ev.append((mob_swing, "mswing"))
            if dot_ticks > 0:
                ev.append((dot_next, "dot"))
            if t < slow_end:
                ev.append((slow_end, "slowend"))
            if run_end is not None:
                ev.append((run_end, "runend"))
            ev = [e for e in ev if t - EPS <= e[0] < INF]
            if not ev:
                # nothing can happen (e.g. hunter stuck in the dead zone while the mob is slowed): melee it
                state = "melee"
                moving = False
                run_end = None
                ev.append((t + 0.1, "noop"))
            nt, kind = min(ev, key=lambda e: e[0])
            nt = max(nt, t)
            # advance positions
            dt = nt - t
            d_old = d
            d = d - closing * dt
            if closing > 0 and d_old >= MELEE_RANGE - EPS:
                d = max(d, MELEE_RANGE)
            t = nt
            # handle all events at time t
            if kind == "reload":
                aim_end = t + AIM
            elif kind == "shot":
                aim_end = None
                if MIN_RANGE - EPS <= d <= MAX_RANGE + EPS and state == "ranged" and not moving:
                    mhp -= self._ranged_dmg(bonus_rap)
                    reload_end = t + h["bow"]["speed"] - AIM
                    log.append((round(t, 3), "shot", round(d, 2)))
                    # kite decision right after a shot
                    if self.tactic == "kite" and cycles < p.get("cycles", 2) and d < p.get("trigger", 20.0) \
                            and (t < slow_end or p.get("unslowed", False) or m["speed"] < RUN_SPEED - EPS):
                        moving = True
                        cycles += 1
                        run_end = reload_end + p.get("turn", 0.3)
                        log.append((round(t, 3), "run", round(d, 2)))
            elif kind == "runend":
                moving = False
                run_end = None
                if d < MIN_RANGE - EPS:
                    state = "melee"
                log.append((round(t, 3), "stop", round(d, 2)))
            elif kind == "cross":
                if not moving and d <= MIN_RANGE + EPS and state == "ranged" and not mob_target_pet:
                    if d < MIN_RANGE - EPS or closing > 0:
                        state = "melee"
                        aim_end = None
                if d <= MELEE_RANGE + EPS and mob_swing is None and not mob_target_pet:
                    mob_swing = t
                if d > MELEE_RANGE + EPS and not mob_target_pet:
                    mob_swing = None
            elif kind == "gcd":
                if state == "ranged":
                    if "sting" in sp and "sting" in use and dot_ticks == 0 and mana >= sp["sting"][1] \
                            and mhp > sp["sting"][0] * 0.6:
                        mana -= sp["sting"][1]
                        dot_ticks, dot_next, dot_amt = 5, t + 3.0, sp["sting"][0] / 5.0
                        gcd_end = t + GCD
                    elif "conc" in sp and "conc" in use and t >= cds["conc"] and mana >= 0.08 * h["base_mana"] \
                            and not mob_target_pet:
                        mana -= 0.08 * h["base_mana"]
                        if self._roll_hit(0.05, 0, 0) > 0:
                            slow_end = t + 4.0
                        cds["conc"] = t + 12.0
                        gcd_end = t + GCD
                    elif "arcane" in sp and "arcane" in use and t >= cds["arcane"] and mana >= sp["arcane"][1] \
                            + p.get("reserve", 0):
                        mana -= sp["arcane"][1]
                        k = self._roll_hit(0.05 + 0.01 * max(0, m["level"] - h["level"]), 0, h["crit"], 1.5)
                        mhp -= sp["arcane"][0] * k
                        cds["arcane"] = t + 6.0
                        gcd_end = t + GCD
                    else:
                        # nothing to cast: wait for the next cooldown instead of spinning
                        nxt = [cds[c] for c in ("arcane", "conc") if c in sp and c in use and cds[c] > t]
                        gcd_end = min(nxt) if nxt else INF
                elif state == "melee" and "wingclip" in sp and mana >= sp["wingclip"][1]:
                    mana -= sp["wingclip"][1]
                    mhp -= self._melee_dmg(sp["wingclip"][0])
                    slow_end = t + 10.0
                    gcd_end = t + GCD
                    if self.tactic == "kite" and cycles < p.get("cycles", 2):
                        moving, state = True, "ranged"
                        cycles += 1
                        run_end = t + p.get("clip_run", 2.5)
                        aim_end = None
                elif state == "melee":
                    gcd_end = INF                        # out of mana for Wing Clip
            elif kind == "hswing":
                bonus = 0.0
                if t >= cds["raptor"] and mana >= sp["raptor"][1] and "raptor" in use:
                    mana -= sp["raptor"][1]
                    bonus = sp["raptor"][0]
                    cds["raptor"] = t + 6.0
                mhp -= self._melee_dmg(bonus)
                h_swing = t + h["melee"]["speed"]
            elif kind == "mswing":
                if mob_target_pet and pet is not None:
                    pet["hp_now"] -= self._mob_hit(pet["armor"], h["level"], 0.05)
                    if pet["hp_now"] <= 0:
                        pet_holds = False
                        mob_target_pet = False
                        d = 30.0                       # mob turns on the hunter from the pet's spot
                        mob_swing = None
                        state = "ranged"
                        log.append((round(t, 3), "pet_died", 0))
                        continue
                else:
                    hp -= self._mob_hit(h["armor"], h["level"], h["dodge"])
                mob_swing = t + m["attack"]
            elif kind == "pswing":
                mhp -= pet["dps"] * pet["attack"] * (1 - mitigation(m["armor"], h["level"])) * \
                    (0 if self.rng.random() < 0.08 else 1)
                pet["next"] = t + pet["attack"]
            elif kind == "dot":
                mhp -= dot_amt
                dot_ticks -= 1
                dot_next = t + 3.0 if dot_ticks else INF
                if not dot_ticks:
                    gcd_end = min(gcd_end, t)        # Serpent Sting can go up again
            elif kind == "mcast":
                cast_end = None
                casts_left -= 1
                if self.rng.random() >= 0.05:
                    hp -= CASTER_BOLT * (m["dmin"] + m["dmax"]) / 2
            elif kind == "slowend":
                pass
            if hp <= 0:
                died = True
        dur = t + pre + (HUMANOID_FLEE_S if m["humanoid"] and self.tactic in ("melee", "stand") else 0.0)
        return {"time": dur, "dmg": h["hp"] - max(hp, 0), "mana": mana0 - mana, "died": died or t > max_t,
                "pet_dmg": (pet["hp"] - max(0, pet["hp_now"])) if pet else 0.0, "log": log}


TACTICS = [
    ("stand", {"spells": ("sting", "arcane", "mark", "raptor")}),
    ("stand", {"spells": ("sting", "arcane", "mark", "conc", "raptor")}),
    ("stand", {"spells": ("raptor",)}),
    ("kite", {"spells": ("sting", "arcane", "mark", "conc", "raptor", "wingclip"), "trigger": 15.0, "cycles": 1}),
    ("kite", {"spells": ("sting", "arcane", "mark", "conc", "raptor", "wingclip"), "trigger": 15.0, "cycles": 2}),
    ("kite", {"spells": ("sting", "arcane", "mark", "conc", "raptor", "wingclip"), "trigger": 20.0, "cycles": 3}),
    ("kite", {"spells": ("arcane", "conc", "raptor", "wingclip"), "trigger": 12.0, "cycles": 2}),
    ("melee", {"spells": ("raptor",), "open": 10.0}),
    ("melee", {"spells": ("sting", "raptor"), "open": 10.0}),
    ("melee", {"spells": ("raptor",), "open": 5.0}),
    ("pet", {"spells": ("sting", "arcane", "mark"), "open": 30.0}),
]


def downtime(h, dmg, mana_used, search_s, food_level_ok=True):
    """Steady-state rest seconds per kill: regen while searching, then eat/drink (sitting) for the rest."""
    lvl = h["level"]
    food = 11.6 if lvl >= 5 else 3.4           # Haunch of Meat / Tough Jerky (KB vendor goods)
    drink = 20.8 if lvl >= 5 else 8.4          # Ice Cold Milk / Refreshing Spring Water
    if not food_level_ok:
        food = drink = 0.0
    need_hp = max(0.0, dmg - h["regen_hp"] * search_s)
    need_mana = max(0.0, mana_used - h["regen_mana"] * search_s)
    t_hp = need_hp / (food + 1.5 * h["regen_hp"]) if need_hp else 0.0
    t_mana = need_mana / (drink + h["regen_mana"]) if need_mana else 0.0
    t = max(t_hp, t_mana)
    return t + (1.5 if t > 0 else 0.0)          # sit / stand / open bags


def evaluate(kb, entry, plevel, tactic, params, runs, seed=1, speed_override=None, search_s=SEARCH_S):
    c = kb["creatures"][str(entry)]
    h = hunter_stats(kb, plevel)
    rng = random.Random(f"{entry}-{plevel}-{tactic}-{sorted(params.items())}-{seed}")
    pet = pet_stats(kb, plevel) if tactic == "pet" else None
    times, dmgs, manas, deaths, xps, petd = [], [], [], 0, [], []
    for lvl in range(c["MinLevel"], c["MaxLevel"] + 1):
        m = mob_stats(c, lvl, speed_override)
        for _ in range(runs):
            r = Fight(h, m, tactic, params, rng, pet).run()
            times.append(r["time"])
            dmgs.append(r["dmg"])
            manas.append(r["mana"])
            petd.append(r["pet_dmg"])
            deaths += r["died"]
            xps.append(kill_xp(plevel, lvl, m["elite"], c.get("ExperienceMultiplier") or 1.0))
    n = len(times)
    kt, dm, mn = sum(times) / n, sum(dmgs) / n, sum(manas) / n
    p_death = deaths / n
    dt = downtime(h, dm, mn, search_s)
    if pet:   # pet regenerates while the hunter rests; the slower of the two sets the downtime
        dt = max(dt, max(0.0, sum(petd) / n - 0.03 * pet["hp"] * search_s) / (0.03 * pet["hp"]))
    xp = sum(xps) / n
    cycle = kt + dt + search_s + p_death * (DEATH_RUN_S + h["hp"] * 0.5 / max(1.0, h["regen_hp"] * 1.5 + 11.6))
    xpm = 60.0 * xp * (1 - p_death) / cycle
    return {"kill_s": round(kt, 2), "dmg_taken": round(dm, 1), "mana_used": round(mn, 1),
            "downtime_s": round(dt, 2), "death_risk": round(p_death, 4), "xp": round(xp, 1),
            "xp_per_min": round(xpm, 1), "tactic": tactic, "params": params,
            "hunter_hp": h["hp"], "stats_from": mob_stats(c, c["MinLevel"])["stats_from"]}


def relevant_mobs(kb):
    """Objective mobs + grind candidates (spawned in the region, level 1-15)."""
    out = set()
    for q in kb["quests"].values():
        for o in q["objectives"]:
            if o.get("creature"):
                out.add(str(o["creature"]))
    for src in kb["item_sources"].values():
        for s in src:
            if s["type"] == "creature":
                out.add(str(s["entry"]))
    for e, c in kb["creatures"].items():
        if c.get("grind_candidate"):
            out.add(e)
    return sorted((e for e in out if e in kb["creatures"] and kb["creatures"][e]["spawns_in_region"] > 0
                   and kb["creatures"][e]["MaxLevel"] <= 16), key=int)


def build_costs(kb, runs=40, levels=range(1, 13), speed_override=None, pet_from=10, mobs=None):
    out = {"meta": {"runs_per_mob_level": runs, "search_s": SEARCH_S, "bow": BOW, "ammo_dps": AMMO_DPS,
                    "mob_speed": speed_override or "7.0 x creature_template.SpeedRun",
                    "pet_from_level": pet_from, "note": "xp_per_min includes search, rest and death penalty"},
           "costs": {}}
    for e in (mobs or relevant_mobs(kb)):
        c = kb["creatures"][e]
        for pl in levels:
            if c["MinLevel"] > pl + 5 or (kill_xp(pl, c["MaxLevel"]) == 0 and c["MaxLevel"] < pl - 6):
                continue
            best, alts = None, {}
            for tactic, params in TACTICS:
                if tactic == "pet" and (pet_from is None or pl < pet_from):
                    continue
                r = evaluate(kb, e, pl, tactic, params, runs, speed_override=speed_override)
                key = tactic + ":" + ",".join(f"{k}={v if not isinstance(v, tuple) else '+'.join(v)}"
                                              for k, v in sorted(params.items()))
                alts[key] = {k: r[k] for k in ("kill_s", "dmg_taken", "downtime_s", "death_risk", "xp_per_min")}
                if tactic != "pet" and (best is None or r["xp_per_min"] > best["xp_per_min"]):
                    best = r
            rec = dict(best)
            rec["name"] = c["Name"]
            rec["mob_levels"] = [c["MinLevel"], c["MaxLevel"]]
            rec["tactics"] = alts
            petk = [k for k in alts if k.startswith("pet")]
            if petk:
                rec["pet"] = alts[petk[0]]
            out["costs"][f"{e}:{pl}"] = rec
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kb", default=KB_PATH)
    ap.add_argument("--runs", type=int, default=40)
    ap.add_argument("--mob-speed", type=float, default=None, help="force every mob's chase speed (yd/s)")
    ap.add_argument("--out", default=os.path.join(OUT_DIR, "combat_costs.json"))
    a = ap.parse_args()
    kb = load_kb(a.kb)
    res = build_costs(kb, a.runs, speed_override=a.mob_speed)
    save_json(a.out, res)
    print(f"{len(res['costs'])} mob x level rows -> {a.out}")


if __name__ == "__main__":
    main()
