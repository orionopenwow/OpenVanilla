#!/usr/bin/env python3
"""Add what Herald Autopilot needs to know to the planner's route, from the knowledge base.

  route_enrich.py [--kb kb/elwynn_human_hunter.json] [--route out/route_elwynn.json] [--out <same>]

planner.py names quests and positions but not NPCs. This adds, per step (all optional for the bot,
which falls back to "the nearest quest giver to pos" and similar guesses without them):

- accept / turnin: "npc" = the creature entry of the starter / ender whose spawn is nearest to pos
- kill: "quests" = every quest the planner credited ("quest 47,60: ..." -> [47, 60])
- objects: "go_entry" = the game object that drops the quest item (item_sources)
- explore: "trigger" = the quest's AreaTrigger id from areatrigger_involvedrelation (the bot sends
  CMSG_AREATRIGGER with it when it arrives)

Run it after planner.py / predict.py (they rewrite the route). Standard library only.
"""
import argparse
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import KB_PATH, OUT_DIR, load_kb  # noqa: E402


def nearest_entry(people, pos):
    best = None
    for p in people:
        if p.get("type", "creature") != "creature":
            continue
        for s in p.get("spawns") or []:
            d = math.hypot(s[0] - pos[0], s[1] - pos[1])
            if best is None or d < best[0]:
                best = (d, p["entry"])
    return best[1] if best else None


def enrich(route, kb):
    quests = kb["quests"]
    sources = kb.get("item_sources", {})
    stats = {"npc": 0, "quests": 0, "go_entry": 0, "trigger": 0}
    for s in route["steps"]:
        q = quests.get(str(s.get("quest"))) if s.get("quest") is not None else None
        if s["kind"] in ("accept", "turnin") and q:
            e = nearest_entry(q["starters"] if s["kind"] == "accept" else q["enders"], s["pos"])
            if e:
                s["npc"] = e
                stats["npc"] += 1
        elif s["kind"] == "kill":
            m = re.match(r"quest ([\d,]+):", s.get("desc", ""))
            if m:
                s["quests"] = [int(x) for x in m.group(1).split(",") if x]
                stats["quests"] += 1
        elif s["kind"] == "objects" and q:
            for o in q.get("objectives", []):
                for src in sources.get(str(o.get("item")), []):
                    if src.get("type") == "gameobject":
                        s["go_entry"] = src["entry"]
                        stats["go_entry"] += 1
                        break
                if "go_entry" in s:
                    break
        elif s["kind"] == "explore" and q:
            for o in q.get("objectives", []):
                if o.get("kind") == "explore" and o.get("trigger"):
                    s["trigger"] = o["trigger"]
                    stats["trigger"] += 1
                    break
    return stats


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kb", default=KB_PATH)
    ap.add_argument("--route", default=os.path.join(OUT_DIR, "route_elwynn.json"))
    ap.add_argument("--out", default=None, help="default: overwrite --route")
    a = ap.parse_args()
    kb = load_kb(a.kb)
    with open(a.route) as f:
        route = json.load(f)
    stats = enrich(route, kb)
    with open(a.out or a.route, "w") as f:
        json.dump(route, f, indent=1, sort_keys=True)
    print(f"enriched {len(route['steps'])} steps: {stats}")


if __name__ == "__main__":
    main()
