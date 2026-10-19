"""Open Vanilla Autopilot Phase 0 (tools/autopilot): combat-sim timing rules, XP formulas and planner
ordering on small hand-made fixtures. No database, no network.

    python3 -m unittest tests.test_autopilot -v
"""
import os
import random
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools", "autopilot"))
import combat_sim as cs  # noqa: E402
import common  # noqa: E402
import planner as pl  # noqa: E402

BX, BY = -9400.0, 0.0     # fixtures live inside the Elwynn box the planner accepts


def hunter(level=10, **kw):
    h = {"level": level, "hp": 10000, "mana": 1000, "base_mana": 200, "rap": 40, "map": 30,
         "bow": {"min": 10, "max": 10, "speed": 2.3}, "melee": {"min": 5, "max": 5, "speed": 2.0},
         "armor": 100, "crit": 0.0, "dodge": 0.0, "regen_hp": 2.0, "regen_mana": 5.0,
         "spells": {"raptor": (5, 15)}}
    h.update(kw)
    return h


def mob(speed=6.0, hp=1e6, **kw):
    m = {"level": 10, "hp": hp, "dmin": 1, "dmax": 1, "attack": 2.0, "armor": 0, "speed": speed, "elite": False,
         "humanoid": False, "caster": False}
    m.update(kw)
    return m


def shots(log):
    return [t for t, kind, _ in log if kind == "shot"]


class SimTiming(unittest.TestCase):
    def run_fight(self, tactic, params, m, max_t=12.0, h=None):
        return cs.Fight(h or hunter(), m, tactic, params, random.Random(1)).run(max_t=max_t)

    def test_stationary_auto_shot_cycle(self):
        # mob too slow to matter: first shot after the 0.5 s aim, then one per weapon speed
        r = self.run_fight("stand", {"spells": ()}, mob(speed=1e-4), max_t=10.0)
        s = shots(r["log"])
        self.assertAlmostEqual(s[0], 0.5, places=6)
        for a, b in zip(s, s[1:]):
            self.assertAlmostEqual(b - a, 2.3, places=6)

    def test_max_range_waits_for_mob(self):
        # opened at 40 yd: no shot until the mob (5 yd/s) is inside 35 yd (t = 1.0), then the aim
        r = self.run_fight("stand", {"spells": (), "open": 40.0}, mob(speed=5.0), max_t=3.0)
        self.assertAlmostEqual(shots(r["log"])[0], 1.5, places=6)

    def test_dead_zone_no_shots(self):
        # starting 7 yd away (inside the 8 yd minimum): never shoots, melees instead
        r = self.run_fight("stand", {"spells": ("raptor",), "open": 7.0}, mob(speed=6.0), max_t=8.0)
        self.assertEqual(shots(r["log"]), [])
        self.assertGreater(r["dmg"], 0)                     # it got hit in melee

    def test_stops_shooting_when_mob_reaches_min_range(self):
        r = self.run_fight("stand", {"spells": ()}, mob(speed=6.0), max_t=10.0)
        # mob covers 35 -> 8 yd in 4.5 s: shots only before that
        self.assertTrue(all(t <= 4.5 + 1e-6 for t in shots(r["log"])))
        self.assertEqual(len(shots(r["log"])), 2)       # 0.5 and 2.8

    def test_kite_run_during_reload_then_turn_and_aim(self):
        # after the first shot (0.5) the hunter runs through the reload (1.8 s) + 0.3 s turn,
        # stops at 2.6 and the 0.5 s aim fires at 3.1 (a stationary hunter would fire at 2.8)
        r = self.run_fight("kite", {"spells": (), "trigger": 40.0, "cycles": 1, "turn": 0.3}, mob(speed=6.0),
                           max_t=4.0)
        s = shots(r["log"])
        self.assertAlmostEqual(s[0], 0.5, places=6)
        self.assertAlmostEqual(s[1], 3.1, places=6)
        runs = [t for t, k, _ in r["log"] if k == "run"]
        self.assertEqual(runs, [0.5])

    def test_kite_keeps_distance_against_slower_mob(self):
        # 6 yd/s mob vs 7 yd/s hunter: the gap grows 1 yd/s while running
        r = self.run_fight("kite", {"spells": (), "trigger": 40.0, "cycles": 1, "turn": 0.0}, mob(speed=6.0),
                           max_t=3.0)
        stop = [(t, d) for t, k, d in r["log"] if k == "stop"][0]
        # 0..0.5 mob closes 3 yd (35 -> 32), 0.5..2.3 gap grows 1.8 yd
        self.assertAlmostEqual(stop[1], 33.8, places=1)

    def test_no_kite_when_mob_is_as_fast(self):
        # same speed and no slow: the kite rule never starts a run (no free distance)
        r = self.run_fight("kite", {"spells": (), "trigger": 40.0, "cycles": 3}, mob(speed=7.0), max_t=6.0)
        self.assertEqual([t for t, k, _ in r["log"] if k == "run"], [])

    def test_concussive_slow_lets_hunter_kite(self):
        h = hunter(level=8, spells={"raptor": (5, 15), "conc": True})
        r = self.run_fight("kite", {"spells": ("conc",), "trigger": 40.0, "cycles": 1}, mob(speed=7.0), h=h,
                           max_t=3.0)
        self.assertTrue([t for t, k, _ in r["log"] if k == "run"])

    def test_downtime_regen_covers_small_damage(self):
        h = cs.hunter_stats(fixture_kb(), 5)
        self.assertEqual(cs.downtime(h, 1.0, 0.0, search_s=12.0), 0.0)
        self.assertGreater(cs.downtime(h, 500.0, 0.0, search_s=0.0), 10.0)


class Formulas(unittest.TestCase):
    def test_kill_xp(self):
        self.assertEqual(common.kill_xp(1, 1), 50)            # 1*5+45
        self.assertEqual(common.kill_xp(1, 3), 55)            # +5 % per level above
        self.assertEqual(common.kill_xp(10, 4), 0)            # gray (gray level 10 = 4)
        self.assertEqual(common.kill_xp(10, 8), round(95 * (1 - 2 / 7)))

    def test_quest_xp(self):
        self.assertEqual(common.quest_xp(510, 10, 10), 850)   # RewMoneyMaxLevel / 0.6
        self.assertEqual(common.quest_xp(510, 10, 16), 680)   # 6 levels above: 80 %
        self.assertEqual(common.quest_xp(510, 10, 25), 85)    # 10+: 10 %

    def test_travel(self):
        self.assertAlmostEqual(common.travel_seconds((0, 0), (70, 0)), 70 * 1.35 / 7.0)


# ── planner fixture ──
def npc(entry, name, x, y):
    return {"type": "creature", "entry": entry, "name": name, "spawns": [[BX + x, BY + y, 0.0]]}


def quest(qid, title, giver, ender, objectives=(), prev=0, minlevel=1, money=60):
    return {"entry": qid, "Title": title, "MinLevel": minlevel, "QuestLevel": max(1, minlevel), "RewMoneyMaxLevel": money,
            "PrevQuestId": prev, "NextQuestId": 0, "ExclusiveGroup": 0, "objectives": list(objectives),
            "starters": [giver], "enders": [ender], "enders_in_region": True}


def creature(entry, name, level, pts, grind=False):
    return {"Name": name, "MinLevel": level, "MaxLevel": level, "Rank": 0, "ExperienceMultiplier": 1.0,
            "spawns": [[BX + x, BY + y, 0.0, 60, 60, i] for i, (x, y) in enumerate(pts)],
            "spawns_in_region": len(pts), "grind_candidate": grind}


def fixture_kb():
    g1 = npc(1, "Giver One", 10, 0)
    g2 = npc(2, "Giver Two", 1500, 0)
    kb = {
        "player": {"start": {"x": BX, "y": BY}, "xp_for_level": {str(l): 400 * l for l in range(1, 61)},
                   "levelstats": {str(l): {"str": 20, "agi": 25, "sta": 22, "inte": 20, "spi": 22} for l in range(1, 13)},
                   "classlevelstats": {str(l): {"basehp": 30 + 7 * l, "basemana": 60 + 10 * l} for l in range(1, 13)}},
        "services": {"vendors": []}, "item_sources": {}, "gameobjects": {},
        "creatures": {
            "100": creature(100, "Far Wolf", 1, [(300, 0), (310, 10), (320, 0), (300, 20)]),
            "200": creature(200, "Near Boar", 1, [(60, 0), (70, 10), (80, 0)]),
            "300": creature(300, "Grind Rat", 1, [(0, 100 + 5 * i) for i in range(8)], grind=True),
        },
        "quests": {
            "1": quest(1, "Far wolves", g1, g1, [{"kind": "kill", "creature": 100, "count": 2}]),
            "2": quest(2, "Near boars", g1, g1, [{"kind": "kill", "creature": 200, "count": 1}]),
            "3": quest(3, "Follow-up", g1, g1, [], prev=1),
            "4": quest(4, "Far away", g2, g2, [{"kind": "kill", "creature": 200, "count": 1}], minlevel=3),
        },
    }
    return kb


def fixture_costs():
    return {f"{e}:{l}": {"kill_s": 10.0, "downtime_s": 0.0, "death_risk": 0.0, "xp_per_min": 100.0,
                         "name": "x", "tactic": "stand", "params": {}} for e in (100, 200, 300) for l in range(1, 13)}


class PlannerOrdering(unittest.TestCase):
    def setUp(self):
        self.kb = fixture_kb()
        self.p = pl.Planner(self.kb, fixture_costs(), max_level=3)
        self.p.pos = (BX + 10, BY)

    def kinds(self, res):
        return [(s["kind"], s.get("quest"), s["desc"]) for s in res["steps"]]

    def test_hub_batch_then_nearest_objective_then_turn_in_together(self):
        res = self.p.run(max_minutes=120)
        st = self.kinds(res)
        accepts = [q for k, q, _ in st if k == "accept"]
        self.assertEqual(accepts[:2], [1, 2])                  # both taken at the hub before any kill
        kills = [d for k, _, d in st if k == "kill"]
        self.assertIn("Near Boar", kills[0])                   # nearer objective first
        self.assertIn("Far Wolf", kills[1])
        turnins = [q for k, q, _ in st if k == "turnin"]
        self.assertEqual(turnins[:2], [1, 2])                  # handed in together at the giver
        i1 = [i for i, (k, q, _) in enumerate(st) if k == "turnin" and q == 2][0]
        i3 = [i for i, (k, q, _) in enumerate(st) if k == "accept" and q == 3][0]
        self.assertGreater(i3, i1)                             # follow-up only after its prerequisite

    def test_kills_credit_every_quest_wanting_the_mob(self):
        self.kb["quests"]["5"] = quest(5, "More boars", npc(1, "Giver One", 10, 0), npc(1, "Giver One", 10, 0),
                                       [{"kind": "kill", "creature": 200, "count": 1}])
        p = pl.Planner(self.kb, fixture_costs(), max_level=3)
        p.pos = (BX + 10, BY)
        res = p.run(max_minutes=120)
        boar = [s for s in res["steps"] if s["kind"] == "kill" and "Near Boar" in s["desc"]]
        self.assertEqual(len(boar), 1)
        self.assertEqual(boar[0]["kills"], 1)

    def test_grind_filler_when_nothing_to_do(self):
        res = self.p.run(max_minutes=300)
        self.assertIn("grind", [s["kind"] for s in res["steps"]])
        self.assertGreaterEqual(res["final_level"], 3)
        times = [s["start_min"] for s in res["steps"]]
        self.assertEqual(times, sorted(times))                 # monotone clock

    def test_min_level_gate(self):
        self.assertFalse(self.p.available(4))
        self.p.level = 3
        self.assertTrue(self.p.available(4))


if __name__ == "__main__":
    unittest.main()
