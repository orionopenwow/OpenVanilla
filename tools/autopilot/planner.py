#!/usr/bin/env python3
"""v0 route planner: Human Hunter, levels 1-12, Northshire + Elwynn Forest.

  planner.py [--kb ...] [--costs out/combat_costs.json] [--out out/] [--no-pet]

Greedy hub batching:
  * at a quest giver, accept every available quest of every giver within HUB_RADIUS;
  * then repeatedly go to the nearest thing to do (an objective camp of an accepted quest, or the
    ender of a completed quest; turn in everything that ends there and pick up what opens up);
  * kills credit every accepted quest that wants that mob (kill counts, expected item drops);
  * with nothing accepted, pick the next hub by quest XP per minute; grind instead when the best
    grind spot beats it (or when nothing is available), until the next level.
Travel = straight-line distance x 1.35 / 7.0 yd/s. Combat time per kill comes from combat_costs.json.
Outputs route_elwynn.json (ordered steps with predicted start/end minutes, XP, level) and
route_elwynn.txt.
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (KB_PATH, OUT_DIR, MAX_LEVEL, dist, kill_xp, load_json, load_kb, quest_xp,  # noqa: E402
                    save_json, travel_seconds)

HUB_RADIUS = 40.0          # yd: NPCs this close count as one hub
CAMP_RADIUS = 150.0        # yd: spawns this close to a camp centre are farmed from it
TALK_S = 5.0               # accept / turn in / read text
LOOT_S = 3.0               # per kill (loot + skin-free)
GO_USE_S = 5.0             # per object use
TAME_CHANNEL_S = 20.0      # taming rod channel (spell DurationIndex 18, assumed 20 s)
DEATH_PENALTY_S = 90.0     # corpse run + rez regen, used with combat_costs death_risk
PET_TAME_S = 60.0          # tame a pet once Tame Beast is known (walk to a beast, 20 s channel, back)
GRIND_STEP_LIMIT = 500
GRIND_MARGIN = 1.15        # grind only when it beats the best hub by 15 % (mob competition, adds, respawns)
PICKUP_RADIUS = 150.0      # yd: also walk to nearby givers of worthwhile quests while busy
CHAIN_LOOKAHEAD = 1        # count the XP/time of the follow-up quest(s) a quest unlocks


def region_pts(rel_list):
    out = []
    for rel in rel_list:
        for s in rel.get("spawns") or []:
            out.append((s[0], s[1]))
    return out


class Planner:
    def __init__(self, kb, costs, use_pet=True, start=None, max_level=MAX_LEVEL):
        self.kb, self.costs = kb, costs
        self.use_pet = use_pet
        self.max_level = max_level
        st = kb["player"]["start"]
        self.pos = start or (st["x"], st["y"])
        self.level, self.xp, self.t = 1, 0, 0.0
        self.xp_need = {int(k): v for k, v in kb["player"]["xp_for_level"].items()}
        self.done, self.active = set(), {}          # active: qid -> progress list
        self.taken_at, self.rewarded_at = {}, {}
        self.steps, self.level_times = [], {1: 0.0}
        self.pet = False
        self.skipped = {}
        self._camp_cache = {}
        self._grind_rate = {}
        self.quests = self._usable_quests()
        self.next_of = {}
        for qid, q in self.quests.items():
            if q.get("NextQuestId", 0) > 0:
                self.next_of.setdefault(q["NextQuestId"], []).append(qid)

    # ── data prep ──
    def _usable_quests(self):
        kb = self.kb
        out = {}
        vendor_items = {g["item"]: v["pos"] for v in kb["services"].get("vendors", []) for g in v.get("goods", [])}
        for k, q in kb["quests"].items():
            qid = int(k)
            why = None
            if not q.get("enders_in_region"):
                why = "ender outside Northshire/Elwynn"
            elif not any(s["type"] in ("creature", "gameobject") and s.get("spawns") for s in q["starters"]):
                why = "starts from an item drop (not planned in v0)"
            givers = [p for p in region_pts([s for s in q["starters"] if s["type"] != "item"])]
            enders = region_pts(q["enders"])
            if not why and not givers:
                why = "no spawned giver"
            tasks = []
            for o in q["objectives"]:
                if why:
                    break
                if o["kind"] == "kill":
                    c = kb["creatures"].get(str(o["creature"]))
                    if not c or not c["spawns_in_region"]:
                        why = f"objective mob {o['creature']} not spawned in region"
                    elif c.get("Rank", 0) in (1, 2):
                        why = f"elite objective {c['Name']}"
                    else:
                        tasks.append({"kind": "kill", "sources": [[o["creature"], 100.0]], "need": o["count"]})
                elif o["kind"] == "cast":
                    tasks.append({"kind": "cast", "entry": o["creature"], "need": o["count"]})
                elif o["kind"] == "explore":
                    tasks.append({"kind": "explore", "pos": o["pos"][:2], "need": 1})
                elif o["kind"] == "use_go":
                    tasks.append({"kind": "go", "entry": o["gameobject"], "need": o["count"], "chance": 100.0})
                elif o["kind"] == "item":
                    if o.get("provided"):
                        continue
                    srcs = [s for s in kb["item_sources"].get(str(o["item"]), [])]
                    csrc = [s for s in srcs if s["type"] == "creature" and kb["creatures"].get(str(s["entry"]), {})
                            .get("spawns_in_region") and kb["creatures"][str(s["entry"])].get("Rank", 0) not in (1, 2)
                            and s["chance"] > 0]
                    gsrc = [s for s in srcs if s["type"] == "gameobject" and any(
                        (-10120 <= sp[0] <= -8550 and -1650 <= sp[1] <= 950)
                        for sp in kb["gameobjects"].get(str(s["entry"]), {}).get("spawns", []))]
                    if o["item"] in vendor_items:
                        tasks.append({"kind": "buy", "pos": vendor_items[o["item"]][:2], "need": o["count"],
                                      "item": o["item"]})
                    elif csrc:
                        tasks.append({"kind": "kill", "sources": [[s["entry"], s["chance"]] for s in csrc],
                                      "need": o["count"], "item": o["item"]})
                    elif gsrc:
                        best = max(gsrc, key=lambda s: s["chance"])
                        tasks.append({"kind": "go", "entry": best["entry"], "need": o["count"],
                                      "chance": best["chance"] or 100.0, "item": o["item"]})
                    elif o["item"] in vendor_items:
                        tasks.append({"kind": "buy", "pos": vendor_items[o["item"]][:2], "need": o["count"],
                                      "item": o["item"]})
                    else:
                        why = f"no source for item {o['item']}"
            if why:
                self.skipped[qid] = why
                continue
            out[qid] = dict(q, qid=qid, givers=givers, enders_pts=enders, tasks=tasks)
        return out

    # ── helpers ──
    def spawns(self, kind, entry):
        src = self.kb["creatures"] if kind != "go" else self.kb["gameobjects"]
        rec = src.get(str(entry), {})
        return [s for s in rec.get("spawns", []) if -10120 <= s[0] <= -8550 and -1650 <= s[1] <= 950
                and not (s[0] > -9100 and s[1] > 280)]

    def camps(self, kind, entry):
        key = (kind, entry)
        if key not in self._camp_cache:
            sp = self.spawns(kind, entry)
            camps = []
            for s in sp:
                nb = [o for o in sp if dist(s, o) <= CAMP_RADIUS]
                cx = sum(o[0] for o in nb) / len(nb)
                cy = sum(o[1] for o in nb) / len(nb)
                resp = sum((o[3] + o[4]) / 2 for o in nb) / len(nb)
                camps.append({"pos": (cx, cy), "n": len(nb), "respawn": resp or 300})
            self._camp_cache[key] = camps
        return self._camp_cache[key]

    def search_s(self, n):
        """Walk between kills at a camp with n spawns within CAMP_RADIUS."""
        spacing = math.sqrt(math.pi) * CAMP_RADIUS / math.sqrt(max(1, n))   # mean spacing in the disc
        return travel_seconds((0, 0), (spacing, 0)) + LOOT_S

    def kill_cost(self, entry, level=None):
        """(seconds per kill excluding search, xp per kill, death_risk)."""
        level = level or self.level
        rec = self.costs.get(f"{entry}:{level}")
        c = self.kb["creatures"][str(entry)]
        if rec is None:
            # outside the simulated band: tiny gray mobs die in two shots, big ones are not attempted
            if c["MaxLevel"] < level:
                return 6.0, 0, 0.0
            return 120.0, 0, 0.5
        best = rec["kill_s"] + rec["downtime_s"] + rec["death_risk"] * DEATH_PENALTY_S
        if self.pet and rec.get("pet"):
            p = rec["pet"]
            best = min(best, p["kill_s"] + p["downtime_s"] + p["death_risk"] * DEATH_PENALTY_S)
        avg_lvl = (c["MinLevel"] + c["MaxLevel"]) / 2
        xp = (kill_xp(level, math.floor(avg_lvl)) + kill_xp(level, math.ceil(avg_lvl))) / 2
        xp *= c.get("ExperienceMultiplier") or 1.0
        return best, xp, rec["death_risk"]

    def best_camp(self, kind, entry, need):
        best = None
        for cp in self.camps(kind, entry):
            per = self.kill_cost(entry)[0] if kind == "kill" else GO_USE_S
            cycle = per + self.search_s(cp["n"])
            # beyond the camp's population, kills wait on respawns
            extra = max(0, need - cp["n"])
            total = travel_seconds(self.pos, cp["pos"]) + need * cycle + \
                extra * max(0.0, cp["respawn"] / cp["n"] - cycle)
            if best is None or total < best[0]:
                best = (total, cp)
        return best

    # ── xp/level bookkeeping ──
    def gain(self, xp):
        self.xp += xp
        while self.level < 60 and self.xp >= self.xp_need[self.level]:
            self.xp -= self.xp_need[self.level]
            self.level += 1
            self.level_times[self.level] = self.t

    def step(self, kind, desc, t0, xp=0, **kw):
        self.steps.append(dict(kind=kind, desc=desc, start_min=round(t0 / 60, 2), end_min=round(self.t / 60, 2),
                               xp=round(xp), level=self.level, xp_into_level=round(self.xp),
                               pos=[round(self.pos[0], 1), round(self.pos[1], 1)], **kw))

    def move(self, dest):
        self.t += travel_seconds(self.pos, dest)
        self.pos = (dest[0], dest[1])

    # ── quest state ──
    def available(self, qid):
        q = self.quests.get(qid)
        if not q or qid in self.done or qid in self.active:
            return False
        if q["MinLevel"] > self.level:
            return False
        pq = q.get("PrevQuestId", 0)
        if pq > 0 and pq not in self.done:
            return False
        if pq < 0 and -pq not in self.active:
            return False
        prereq = self.next_of.get(qid, [])
        if prereq:
            groups = {}
            for p in prereq:
                groups.setdefault(self.quests[p].get("ExclusiveGroup", 0), []).append(p)
            for g, ps in groups.items():
                if g > 0:
                    if not any(p in self.done for p in ps):
                        return False
                elif not all(p in self.done for p in ps):
                    return False
        eg = q.get("ExclusiveGroup", 0)
        if eg > 0 and any(o != qid and self.quests[o].get("ExclusiveGroup") == eg and
                          (o in self.done or o in self.active) for o in self.quests):
            return False
        return True

    def complete(self, qid):
        return all(p >= t["need"] - 1e-9 for p, t in zip(self.active[qid], self.quests[qid]["tasks"]))

    def accept_at(self, pos):
        got = []
        for qid in sorted(self.quests):
            q = self.quests[qid]
            if self.available(qid) and any(dist(pos, g) <= HUB_RADIUS for g in q["givers"]):
                t0 = self.t
                self.t += TALK_S
                self.active[qid] = [0.0] * len(q["tasks"])
                self.taken_at[qid] = t0
                got.append(qid)
                self.step("accept", f"accept {qid} {q['Title']}", t0, quest=qid)
        return got

    def turn_in_at(self, pos):
        got = []
        for qid in sorted(list(self.active)):
            q = self.quests[qid]
            if self.complete(qid) and any(dist(pos, e) <= HUB_RADIUS for e in q["enders_pts"]):
                t0 = self.t
                self.t += TALK_S
                xp = quest_xp(q["RewMoneyMaxLevel"], q["QuestLevel"], self.level)
                del self.active[qid]
                self.done.add(qid)
                self.rewarded_at[qid] = self.t
                self.gain(xp)
                got.append(qid)
                self.step("turnin", f"turn in {qid} {q['Title']}", t0, xp=xp, quest=qid)
                if q.get("RewSpellCast") == 1579 and self.use_pet:   # Tame Beast learned
                    self.t += PET_TAME_S
                    self.pet = True
                    self.step("pet", "tame a pet (Tame Beast learned)", self.t - PET_TAME_S)
        if got:
            self.accept_at(pos)
        return got

    def credit_kill(self, entry):
        for qid, prog in self.active.items():
            for i, t in enumerate(self.quests[qid]["tasks"]):
                if t["kind"] == "kill" and prog[i] < t["need"]:
                    for e, ch in t["sources"]:
                        if e == entry:
                            prog[i] = min(t["need"], prog[i] + ch / 100.0)
                            break

    # ── actions ──
    def do_kills(self, entry, label, camp, stop):
        """Kill `entry` at `camp` until stop() is true; returns kills."""
        self.move(camp["pos"])
        t0, xp0, kills = self.t, 0, 0
        cycle_floor = camp["respawn"] / max(1, camp["n"])
        start_t = self.t
        while not stop() and kills < GRIND_STEP_LIMIT:
            per, xp, _ = self.kill_cost(entry)
            cyc = per + self.search_s(camp["n"])
            if kills >= camp["n"]:
                cyc = max(cyc, cycle_floor)
            self.t += cyc
            kills += 1
            self.credit_kill(entry)
            self.gain(xp)
            xp0 += xp
        name = self.kb["creatures"][str(entry)]["Name"]
        self.step("kill" if label else "grind", f"{label or 'grind'}: {kills} x {name}", t0, xp=xp0,
                  entry=entry, kills=kills, seconds=round(self.t - start_t))
        return kills

    def next_task(self):
        """Nearest incomplete objective of an accepted quest; once none is left, the nearest ender of
        a completed one (the batch is handed in together)."""
        best = None
        turnin = None
        for qid, prog in self.active.items():
            q = self.quests[qid]
            if self.complete(qid):
                for e in q["enders_pts"]:
                    c = travel_seconds(self.pos, e)
                    if turnin is None or c < turnin[0]:
                        turnin = (c, "turnin", qid, e)
                continue
            for i, t in enumerate(q["tasks"]):
                if prog[i] >= t["need"] - 1e-9:
                    continue
                if t["kind"] in ("kill", "cast"):
                    srcs = t["sources"] if t["kind"] == "kill" else [[t["entry"], 100.0]]
                    pick = None
                    for e, ch in srcs:
                        c = self.kb["creatures"][str(e)]
                        if c["MinLevel"] > self.level + 2:
                            continue                  # too dangerous for now
                        bc = self.best_camp("kill", e, (t["need"] - prog[i]) / (ch / 100.0))
                        if bc and (pick is None or bc[0] < pick[0]):
                            pick = (bc[0], e, bc[1])
                    if pick:
                        cost = travel_seconds(self.pos, pick[2]["pos"])
                        if best is None or cost < best[0]:
                            best = (cost, t["kind"], qid, (i, pick[2], pick[1]))
                elif t["kind"] == "explore":
                    cost = travel_seconds(self.pos, t["pos"])
                    if best is None or cost < best[0]:
                        best = (cost, "explore", qid, (i, t["pos"]))
                elif t["kind"] == "go":
                    bc = self.best_camp("go", t["entry"], t["need"] - prog[i])
                    if bc:
                        cost = travel_seconds(self.pos, bc[1]["pos"])
                        if best is None or cost < best[0]:
                            best = (cost, "go", qid, (i, bc[1]))
                elif t["kind"] == "buy":
                    cost = travel_seconds(self.pos, t["pos"])
                    if best is None or cost < best[0]:
                        best = (cost, "buy", qid, (i, t["pos"]))
        if best is None:
            best = turnin
        for qid, q in self.quests.items():
            if not self.available(qid):
                continue
            g = min(q["givers"], key=lambda p: dist(self.pos, p))
            if dist(self.pos, g) > PICKUP_RADIUS:
                continue
            x, s_ = self.quest_rate(qid, g)
            if x / s_ * GRIND_MARGIN >= self.grind_rate():
                c = travel_seconds(self.pos, g)
                if best is None or c < best[0]:
                    best = (c, "pickup", qid, g)
        return best

    def grind_rate(self):
        """Best grind XP/s at this level, ignoring the walk to the camp (cached per level/pet)."""
        key = (self.level, self.pet)
        if key not in self._grind_rate:
            pos, xp = self.pos, self.xp
            self.pos, self.xp = (0.0, 0.0), 0
            g = self.grind_choice(ignore_travel=True)
            self.pos, self.xp = pos, xp
            self._grind_rate[key] = g[3] if g else 0.0
        return self._grind_rate[key]

    def quest_rate(self, qid, from_pos, depth=CHAIN_LOOKAHEAD):
        """(xp, seconds) for quest qid done from the hub at from_pos: objectives + walk to the ender
        (the walk to the hub itself is not included)."""
        q = self.quests[qid]
        g = min(q["givers"], key=lambda p: dist(from_pos, p))
        secs = 2 * TALK_S
        pos = g
        xp = quest_xp(q["RewMoneyMaxLevel"], q["QuestLevel"], self.level)
        for t in q["tasks"]:
            if t["kind"] in ("kill", "cast"):
                opts = []
                for e, ch in (t["sources"] if t["kind"] == "kill" else [[t["entry"], 100.0]]):
                    camps = self.camps("kill", e)
                    if not camps or self.kb["creatures"][str(e)]["MinLevel"] > self.level + 2:
                        continue
                    cp = min(camps, key=lambda c: dist(pos, c["pos"]))
                    per, kxp, _ = self.kill_cost(e)
                    n = t["need"] / (ch / 100.0) if t["kind"] == "kill" else 0
                    s_ = travel_seconds(pos, cp["pos"]) + n * (per + self.search_s(cp["n"]))
                    if t["kind"] == "cast":
                        s_ += TAME_CHANNEL_S + self.search_s(cp["n"])
                    opts.append((s_, n * kxp, cp["pos"]))
                if not opts:
                    return 0.0, 1e9
                s_, kx, pos = min(opts)
                secs += s_
                xp += kx
            elif t["kind"] == "explore":
                secs += travel_seconds(pos, t["pos"])
                pos = t["pos"]
            elif t["kind"] == "go":
                camps = self.camps("go", t["entry"])
                if not camps:
                    return 0.0, 1e9
                cp = min(camps, key=lambda c: dist(pos, c["pos"]))
                n = t["need"] / (t.get("chance", 100.0) / 100.0)
                secs += travel_seconds(pos, cp["pos"]) + n * (GO_USE_S + self.search_s(cp["n"]))
                pos = cp["pos"]
            elif t["kind"] == "buy":
                secs += travel_seconds(pos, t["pos"]) + TALK_S
                pos = t["pos"]
        end = min(q["enders_pts"], key=lambda p: dist(pos, p))
        secs += travel_seconds(pos, end)
        if depth > 0:   # follow-ups this quest unlocks (chains pay off at the end)
            for nq, nqd in self.quests.items():
                if nqd.get("PrevQuestId") == qid or qid in self.next_of.get(nq, []):
                    if nqd["MinLevel"] <= self.level + 1 and nqd["givers"]:
                        x2, s2 = self.quest_rate(nq, end, depth - 1)
                        g2 = min(nqd["givers"], key=lambda p: dist(end, p))
                        if s2 < 1e8:
                            xp += x2
                            secs += s2 + travel_seconds(end, g2)
        return xp, secs

    def grind_choice(self, ignore_travel=False):
        """Best (entry, camp, xp/s) to grind to the next level from here."""
        need = self.xp_need[self.level] - self.xp
        best = None
        for e, c in self.kb["creatures"].items():
            if not c.get("grind_candidate") or c.get("Rank", 0) or c["spawns_in_region"] < 4:
                continue
            per, xp, risk = self.kill_cost(int(e))
            if xp <= 0 or risk > 0.08:
                continue
            for cp in self.camps("kill", int(e)):
                if cp["n"] < 4:
                    continue
                cyc = max(per + self.search_s(cp["n"]), cp["respawn"] / cp["n"])
                rate = xp / cyc
                total = (0.0 if ignore_travel else travel_seconds(self.pos, cp["pos"])) + need / rate
                if best is None or total < best[0]:
                    best = (total, int(e), cp, need / total)
        return best

    def run(self, max_minutes=600):
        self.accept_at(self.pos)
        guard = 0
        while self.level < self.max_level and self.t < max_minutes * 60 and guard < 2000:
            guard += 1
            task = self.next_task()
            if task:
                _, kind, qid, arg = task
                q = self.quests[qid]
                if kind == "turnin":
                    t0 = self.t
                    self.move(arg)
                    if self.t > t0:
                        self.step("travel", f"to {q['enders'][0].get('name')} ({qid})", t0)
                    self.turn_in_at(arg)
                elif kind == "pickup":
                    t0 = self.t
                    self.move(arg)
                    self.step("travel", f"to {q['starters'][0].get('name')} ({qid})", t0)
                elif kind == "explore":
                    i, pos = arg
                    t0 = self.t
                    self.move(pos)
                    self.active[qid][i] = 1
                    self.step("explore", f"quest {qid}: explore {q['Title']}", t0, quest=qid)
                elif kind == "kill":
                    i, camp, entry = arg
                    wants = [(qq, j) for qq, pr in self.active.items() for j, tt in enumerate(self.quests[qq]["tasks"])
                             if tt["kind"] == "kill" and any(e == entry for e, _ in tt["sources"])
                             and pr[j] < tt["need"]]
                    self.do_kills(entry, "quest " + ",".join(str(w[0]) for w in wants), camp,
                                  lambda: all(self.active[qq][j] >= self.quests[qq]["tasks"][j]["need"] - 1e-9
                                              for qq, j in wants if qq in self.active))
                elif kind == "cast":
                    i, camp, entry = arg
                    t0 = self.t
                    self.move(camp["pos"])
                    per, _, _ = self.kill_cost(entry)
                    self.t += TAME_CHANNEL_S + max(0.0, per - 10.0) * 0.5 + self.search_s(camp["n"])
                    self.active[qid][i] = q["tasks"][i]["need"]
                    self.step("tame", f"quest {qid}: taming rod on {self.kb['creatures'][str(entry)]['Name']}", t0,
                              quest=qid)
                elif kind == "go":
                    i, camp = arg
                    t0 = self.t
                    self.move(camp["pos"])
                    tsk = q["tasks"][i]
                    left = tsk["need"] - self.active[qid][i]
                    n = math.ceil(left / (tsk.get("chance", 100.0) / 100.0))
                    cyc = GO_USE_S + self.search_s(camp["n"])
                    if n > camp["n"]:
                        cyc = max(cyc, camp["respawn"] / camp["n"])
                    self.t += n * cyc
                    self.active[qid][i] = tsk["need"]
                    name = self.kb["gameobjects"].get(str(tsk["entry"]), {}).get("name")
                    self.step("objects", f"quest {qid}: use {n} x {name}", t0, quest=qid)
                elif kind == "buy":
                    i, pos = arg
                    t0 = self.t
                    self.move(pos)
                    self.t += TALK_S
                    self.active[qid][i] = q["tasks"][i]["need"]
                    self.step("buy", f"quest {qid}: buy item {q['tasks'][i]['item']}", t0, quest=qid)
                # hand in / pick up whatever is right here
                self.turn_in_at(self.pos)
                self.accept_at(self.pos)
                continue
            # nothing accepted to work on: next hub or grind
            hubs = {}
            for qid in self.quests:
                if self.available(qid):
                    g = min(self.quests[qid]["givers"], key=lambda p: dist(self.pos, p))
                    key = (round(g[0] / HUB_RADIUS), round(g[1] / HUB_RADIUS))
                    hubs.setdefault(key, (g, []))[1].append(qid)
            best_hub = None
            for key, (g, qids) in hubs.items():
                xs = [self.quest_rate(qid, g) for qid in qids]
                rate = sum(x for x, _ in xs) / (travel_seconds(self.pos, g) + sum(s_ for _, s_ in xs))
                if best_hub is None or rate > best_hub[0]:
                    best_hub = (rate, g, qids)
            grind = self.grind_choice()
            active_blocked = bool(self.active)
            if best_hub and (grind is None or best_hub[0] * GRIND_MARGIN >= grind[3]):
                t0 = self.t
                self.move(best_hub[1])
                self.step("travel", f"to quest hub ({len(best_hub[2])} quests)", t0)
                if not self.accept_at(best_hub[1]):
                    break
                continue
            if grind is None:
                break
            _, entry, camp, _ = grind
            lvl = self.level
            self.do_kills(entry, None, camp, lambda: self.level > lvl or (
                active_blocked and self.next_task() is not None))
        self.level_times.setdefault(self.level, self.t)
        return self.result()

    def result(self):
        lv = sorted(self.level_times.items())
        per_level = {l: round((t2 - t1) / 60, 2) for (l, t1), (_, t2) in zip(lv, lv[1:])}
        quest_minutes = {q: round((self.rewarded_at[q] - self.taken_at[q]) / 60, 2)
                         for q in self.rewarded_at if q in self.taken_at}
        return {"steps": self.steps, "level_reached_min": {l: round(t / 60, 2) for l, t in lv},
                "minutes_per_level": per_level, "quest_minutes": quest_minutes,
                "quests_done": sorted(self.done), "quests_open": sorted(self.active),
                "skipped": {str(k): v for k, v in sorted(self.skipped.items())},
                "total_min": round(self.t / 60, 2), "final_level": self.level, "pet": self.pet}


def write_txt(res, kb, path):
    L = ["Open Vanilla Autopilot v0 route: Human Hunter 1-%d, Northshire -> Elwynn" % res["final_level"], ""]
    for i, s in enumerate(res["steps"], 1):
        L.append(f"{i:3d} {s['start_min']:7.1f}-{s['end_min']:7.1f} min  L{s['level']:<2d} {s['kind']:7s} "
                 f"{s['desc']}" + (f"  (+{s['xp']} xp)" if s["xp"] else ""))
    L.append("")
    L.append("Level reached at minute: " + "  ".join(f"L{l}:{m}" for l, m in res["level_reached_min"].items()))
    L.append("Skipped quests: " + "; ".join(f"{k} ({v})" for k, v in res["skipped"].items()))
    with open(path, "w") as f:
        f.write("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kb", default=KB_PATH)
    ap.add_argument("--costs", default=os.path.join(OUT_DIR, "combat_costs.json"))
    ap.add_argument("--out", default=OUT_DIR)
    ap.add_argument("--no-pet", action="store_true", help="never use a pet (no taming after the chain)")
    ap.add_argument("--max-level", type=int, default=MAX_LEVEL)
    a = ap.parse_args()
    kb = load_kb(a.kb)
    costs = load_json(a.costs)["costs"]
    res = Planner(kb, costs, use_pet=not a.no_pet, max_level=a.max_level).run()
    save_json(os.path.join(a.out, "route_elwynn.json"), res)
    write_txt(res, kb, os.path.join(a.out, "route_elwynn.txt"))
    print(f"{len(res['steps'])} steps, level {res['final_level']} at {res['total_min']} min -> {a.out}")


if __name__ == "__main__":
    main()
