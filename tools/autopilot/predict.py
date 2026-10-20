#!/usr/bin/env python3
"""Turn the planned route into predictions shaped like tools/botlab/botlab_report.py's report.

  predict.py [--kb ...] [--costs out/combat_costs.json] [--out out/] [--no-sensitivity]

Writes predictions.json and predictions.txt: minutes per level (level-up to level-up, like
levels.csv), XP/min by level band 1-4 / 5-8 / 9-12 for the Hunter (like the report's band line),
per-quest minutes taken -> rewarded (like quests.csv), the best combat tactic per band, and a
small sensitivity section (mob chase speed forced to 7.0 yd/s, no pet).
Botlab's numbers are medians over bots and 1-5 min snapshot intervals; ours is one planned
character, so read XP/min here as "XP gained in the band / minutes spent in the band".
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import KB_PATH, OUT_DIR, load_json, load_kb, save_json  # noqa: E402
from planner import Planner, write_txt as write_route_txt  # noqa: E402

BANDS = [(1, 4), (5, 8), (9, 12)]


def summarize(kb, costs, res):
    need = {int(k): v for k, v in kb["player"]["xp_for_level"].items()}
    mpl = {int(k): v for k, v in res["minutes_per_level"].items()}
    reached = {int(k): v for k, v in res["level_reached_min"].items()}
    xpm_level = {l: round(need[l] / m, 1) for l, m in mpl.items() if m > 0}
    bands = {}
    for lo, hi in BANDS:
        ls = [l for l in range(lo, hi + 1) if l in mpl]
        mins = sum(mpl[l] for l in ls)
        bands[f"{lo}-{hi}"] = round(sum(need[l] for l in ls) / mins, 1) if mins else None
    quests = {}
    for s in res["steps"]:
        if s["kind"] == "accept":
            quests.setdefault(s["quest"], {"title": s["desc"].split(" ", 2)[2], "taken_min": s["start_min"],
                                           "level_taken": s["level"]})
        if s["kind"] == "turnin":
            quests.setdefault(s["quest"], {"title": s["desc"].split(" ", 3)[3]})
            quests[s["quest"]]["rewarded_min"] = s["end_min"]
    for q, v in quests.items():
        if "taken_min" in v and "rewarded_min" in v:
            v["minutes"] = round(v["rewarded_min"] - v["taken_min"], 1)
    return {"minutes_per_level": mpl, "level_reached_min": reached, "xp_per_min_by_level": xpm_level,
            "xp_per_min_by_band": bands, "quests": quests}


def tactics_by_band(kb, costs, use_pet=True):
    out = {}
    for lo, hi in BANDS:
        rows = []
        for lvl in range(lo, hi + 1):
            p = Planner(kb, costs, use_pet=use_pet)
            p.level, p.pet = lvl, use_pet and lvl >= 11
            g = p.grind_choice(ignore_travel=True)
            if not g:
                continue
            rec = costs.get(f"{g[1]}:{lvl}")
            rows.append({"level": lvl, "mob": rec["name"], "tactic": rec["tactic"], "params": rec["params"],
                         "kill_s": rec["kill_s"], "combat_xp_per_min": rec["xp_per_min"],
                         "pet_xp_per_min": (rec.get("pet") or {}).get("xp_per_min"),
                         "grind_xp_per_min": round(g[3] * 60, 1)})
        tc = {}
        for r in rows:
            tc[r["tactic"]] = tc.get(r["tactic"], 0) + 1
        out[f"{lo}-{hi}"] = {"levels": rows, "best_tactic": max(tc, key=tc.get) if tc else None,
                             "mean_combat_xp_per_min": round(sum(r["combat_xp_per_min"] for r in rows) / len(rows), 1)
                             if rows else None}
    return out


def write_txt(pred, path):
    L = ["Open Vanilla Autopilot v0 PREDICTIONS: Human Hunter 1-12, Northshire + Elwynn (one planned character)", ""]
    L.append("Predicted minutes per level (level-up to level-up):")
    L.append("  " + "  ".join(f"L{l}:{m}" for l, m in sorted(pred["minutes_per_level"].items())))
    L.append("Reached at minute: " + "  ".join(f"L{l}:{m}" for l, m in sorted(pred["level_reached_min"].items())))
    L.append("Predicted XP/min by class and level band:")
    L.append("  Hunter   " + "  ".join(f"{b}:{v}" for b, v in pred["xp_per_min_by_band"].items()))
    L.append("")
    L.append("Best solo tactic by band (grind mob, combat XP/min incl. search 12 s, rest, death risk):")
    for b, v in pred["tactics_by_band"].items():
        L.append(f"  {b}: {v['best_tactic']} (mean {v['mean_combat_xp_per_min']} XP/min) - " + "; ".join(
            f"L{r['level']} {r['mob']} {r['tactic']} {r['combat_xp_per_min']}"
            + (f" / pet {r['pet_xp_per_min']}" if r.get("pet_xp_per_min") else "") for r in v["levels"]))
    L.append("")
    L.append("Quests (taken min / rewarded min / predicted minutes taken->rewarded):")
    for q, v in sorted(pred["quests"].items(), key=lambda kv: kv[1].get("taken_min", 1e9)):
        L.append(f"  {q} {v['title'][:34]:34s} {v.get('taken_min', '-')!s:>6} / {v.get('rewarded_min', '-')!s:>6} / "
                 f"{v.get('minutes', '-')}")
    chain = [(q, pred["quests"].get(q, {})) for q in range(90601, 90605)]
    L.append("Hunter taming chain 90601-90604 predicted minutes: " + ", ".join(
        f"{q}:{v.get('minutes', 'not reached')}" for q, v in chain))
    L.append("Not planned: " + "; ".join(f"{k} ({v})" for k, v in pred["skipped"].items()))
    if pred.get("sensitivity"):
        L.append("")
        L.append("Sensitivity (minutes to reach L10 / L12):")
        for k, v in pred["sensitivity"].items():
            L.append(f"  {k}: {v}")
    with open(path, "w") as f:
        f.write("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kb", default=KB_PATH)
    ap.add_argument("--costs", default=os.path.join(OUT_DIR, "combat_costs.json"))
    ap.add_argument("--out", default=OUT_DIR)
    ap.add_argument("--no-sensitivity", action="store_true")
    a = ap.parse_args()
    kb = load_kb(a.kb)
    costs = load_json(a.costs)["costs"]
    res = Planner(kb, costs).run()
    save_json(os.path.join(a.out, "route_elwynn.json"), res)
    write_route_txt(res, kb, os.path.join(a.out, "route_elwynn.txt"))
    pred = summarize(kb, costs, res)
    pred["tactics_by_band"] = tactics_by_band(kb, costs)
    pred["skipped"] = res["skipped"]
    pred["meta"] = {"kb": os.path.relpath(a.kb, os.path.dirname(os.path.abspath(__file__))),
                    "route_steps": len(res["steps"]), "total_min": res["total_min"],
                    "shape": "botlab_report: minutes per level, XP/min by class+band, per-quest minutes"}
    if not a.no_sensitivity:
        import combat_sim
        sens = {"baseline (template mob speed, pet after 90603)":
                f"L10 {pred['level_reached_min'].get(10)} / L12 {pred['level_reached_min'].get(12)}"}
        r2 = Planner(kb, costs, use_pet=False).run()
        sens["no pet"] = f"L10 {r2['level_reached_min'].get(10)} / L12 {r2['level_reached_min'].get(12)}"
        c7 = combat_sim.build_costs(kb, runs=20, speed_override=7.0)["costs"]
        r3 = Planner(kb, c7).run()
        sens["mob chase speed forced to 7.0 yd/s"] = \
            f"L10 {r3['level_reached_min'].get(10)} / L12 {r3['level_reached_min'].get(12)}"
        pred["sensitivity"] = sens
    save_json(os.path.join(a.out, "predictions.json"), pred)
    write_txt(pred, os.path.join(a.out, "predictions.txt"))
    print(open(os.path.join(a.out, "predictions.txt")).read())


if __name__ == "__main__":
    main()
