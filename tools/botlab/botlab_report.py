#!/usr/bin/env python3
"""Open Vanilla bot lab report: turns lab.db (botlab_logger.py) into a one-page summary plus CSV files.

  botlab_report.py --db /var/lib/botlab/lab.db --out /var/lib/botlab/report

Writes report.txt (short, meant to be read by a person or pasted to Claude), and CSVs with the detail:
levels.csv (minutes per level per bot), xp_rate.csv (XP/min by class and level), quests.csv (per-quest
completion counts and times), stuck.csv (long stretches with no movement and no XP), deaths.csv.
"""
import argparse, csv, os, sqlite3, statistics
from collections import defaultdict

RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "NightElf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
CLASSES = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage",
           9: "Warlock", 11: "Druid"}
HUNTER_CHAIN = range(90601, 90609)   # Classic+ taming chains (Human: Goldshire, Undead: Brill)
STUCK_MIN = 10                        # minutes online with no movement and no XP


def med(xs):
    return round(statistics.median(xs), 1) if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="/var/lib/botlab/lab.db")
    ap.add_argument("--out", default="/var/lib/botlab/report")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    db = sqlite3.connect(a.db)
    chars = {g: (n, r, c) for g, n, r, c in db.execute("SELECT guid, name, race, class FROM chars")}
    xpneed = dict(db.execute("SELECT level, xp FROM xp_for_level"))
    snaps = defaultdict(list)
    for row in db.execute("SELECT t, guid, level, xp, money, map, zone, x, y, z, online, dead "
                          "FROM snap ORDER BY guid, t"):
        snaps[row[1]].append(row)
    t_all = [s[0] for v in snaps.values() for s in v]
    if not t_all:
        print("no snapshots yet"); return
    hours = (max(t_all) - min(t_all)) / 3600 or 1e-9

    # per-bot walk through its snapshots
    level_times = []            # (guid, level, minutes)
    xp_rate = defaultdict(list)  # (class, level) -> xp/min samples over online intervals
    deaths, stuck, online_min = [], [], defaultdict(float)
    for g, ss in snaps.items():
        cls = chars.get(g, ("?", 0, 0))[2]
        lvl_start = None
        still = 0.0
        for p, q in zip(ss, ss[1:]):
            dt = (q[0] - p[0]) / 60
            if not (p[10] and q[10]) or dt <= 0 or dt > 5:
                still = 0.0; continue
            online_min[g] += dt
            if q[2] == p[2]:
                gain = q[3] - p[3]
            elif q[2] == p[2] + 1 and p[2] in xpneed:
                gain = (xpneed[p[2]] - p[3]) + q[3]
            else:
                gain = None
            if gain is not None and gain >= 0:
                xp_rate[(cls, p[2])].append(gain / dt)
            if q[2] > p[2]:
                if lvl_start is not None:
                    level_times.append((g, p[2], round((q[0] - lvl_start) / 60, 1)))
                lvl_start = q[0]
            if q[11] and not p[11]:
                deaths.append((g, q[0], q[2], q[5], q[7], q[8]))
            moved = abs(q[7] - p[7]) + abs(q[8] - p[8]) > 3 or q[5] != p[5]
            if not moved and (gain or 0) == 0 and not q[11]:
                still += dt
                if still >= STUCK_MIN and (not stuck or stuck[-1][0] != g or q[0] - stuck[-1][1] > 1800):
                    stuck.append((g, q[0], q[2], q[5], q[7], q[8]))
            else:
                still = 0.0

    # quests: first time seen taken (status 3 = incomplete) -> rewarded
    qrows = defaultdict(list)
    for t, g, quest, status, rewarded in db.execute("SELECT t, guid, quest, status, rewarded FROM quest ORDER BY t"):
        qrows[(g, quest)].append((t, status, rewarded))
    qstat = defaultdict(lambda: {"taken": 0, "done": 0, "mins": []})
    for (g, quest), ev in qrows.items():
        s = qstat[quest]
        s["taken"] += 1
        t_take = ev[0][0]
        t_done = next((t for t, st, rw in ev if rw), None)
        if t_done is not None:
            s["done"] += 1
            if t_done > t_take:
                s["mins"].append((t_done - t_take) / 60)

    # CSVs
    with open(os.path.join(a.out, "levels.csv"), "w", newline="") as f:
        w = csv.writer(f); w.writerow(["guid", "name", "race", "class", "level", "minutes"])
        for g, lvl, m in level_times:
            n, r, c = chars.get(g, ("?", 0, 0)); w.writerow([g, n, RACES.get(r, r), CLASSES.get(c, c), lvl, m])
    with open(os.path.join(a.out, "xp_rate.csv"), "w", newline="") as f:
        w = csv.writer(f); w.writerow(["class", "level", "samples", "median_xp_per_min"])
        for (c, lvl), xs in sorted(xp_rate.items()):
            w.writerow([CLASSES.get(c, c), lvl, len(xs), med(xs)])
    with open(os.path.join(a.out, "quests.csv"), "w", newline="") as f:
        w = csv.writer(f); w.writerow(["quest", "taken", "rewarded", "median_minutes"])
        for quest, s in sorted(qstat.items(), key=lambda kv: -kv[1]["taken"]):
            w.writerow([quest, s["taken"], s["done"], med(s["mins"])])
    for name, rows in (("stuck.csv", stuck), ("deaths.csv", deaths)):
        with open(os.path.join(a.out, name), "w", newline="") as f:
            w = csv.writer(f); w.writerow(["guid", "t", "level", "map", "x", "y"])
            w.writerows(rows)

    # one-page summary
    L = []
    n_bots = len(snaps)
    by_cls = defaultdict(int)
    for g in snaps:
        n, r, c = chars.get(g, ("?", 0, 0)); by_cls[f"{RACES.get(r, r)} {CLASSES.get(c, c)}"] += 1
    L.append(f"Open Vanilla bot lab: {n_bots} bots over {hours:.1f} h, {sum(online_min.values())/60:.0f} bot-hours online")
    L.append("Cohort: " + ", ".join(f"{k} {v}" for k, v in sorted(by_cls.items(), key=lambda kv: -kv[1])))
    gained = sum(max(s[2] for s in ss) - ss[0][2] for ss in snaps.values())
    L.append(f"Levels gained: {gained} ({gained / max(1e-9, sum(online_min.values())/60):.2f} per bot-hour)")
    L.append(f"Deaths: {len(deaths)} ({len(deaths) / max(1e-9, sum(online_min.values())/60):.2f} per bot-hour); "
             f"stuck spells (>= {STUCK_MIN} min still, no XP): {len(stuck)}")
    L.append("")
    L.append("Median minutes per level (all classes):")
    per_lvl = defaultdict(list)
    for g, lvl, m in level_times:
        per_lvl[lvl].append(m)
    L.append("  " + "  ".join(f"L{l}:{med(v)}({len(v)})" for l, v in sorted(per_lvl.items())))
    L.append("Median XP/min while online, by class and level band:")
    band = defaultdict(list)
    for (c, lvl), xs in xp_rate.items():
        band[(CLASSES.get(c, c), (lvl - 1) // 4 * 4 + 1)].extend(xs)
    for c in sorted({k[0] for k in band}, key=str):
        L.append(f"  {c:8} " + "  ".join(f"{b}-{b+3}:{med(band[(c, b)])}" for b in sorted(k[1] for k in band if k[0] == c)))
    L.append("")
    top = sorted(qstat.items(), key=lambda kv: -kv[1]["taken"])[:12]
    L.append("Most-taken quests (taken / rewarded / median min):")
    for quest, s in top:
        L.append(f"  {quest}: {s['taken']} / {s['done']} / {med(s['mins'])}")
    never = [q for q, s in qstat.items() if s["taken"] >= 3 and s["done"] == 0]
    L.append(f"Taken by 3+ bots, never finished ({len(never)}): " + ", ".join(map(str, sorted(never)[:30])))
    chain = [(q, qstat[q]["taken"], qstat[q]["done"]) for q in HUNTER_CHAIN if q in qstat]
    L.append("Hunter taming chains 90601-90608 (taken/rewarded): " +
             (", ".join(f"{q}:{t}/{d}" for q, t, d in chain) if chain else "not reached by any bot"))
    hot = defaultdict(int)
    for g, t, lvl, mp, x, y in stuck + deaths:
        hot[(mp, round(x, -1), round(y, -1))] += 1
    L.append("Trouble spots (map, x, y: stuck+deaths): " +
             ", ".join(f"{k[0]},{k[1]:.0f},{k[2]:.0f}:{v}" for k, v in sorted(hot.items(), key=lambda kv: -kv[1])[:10]))
    text = "\n".join(L) + "\n"
    open(os.path.join(a.out, "report.txt"), "w").write(text)
    print(text)


if __name__ == "__main__":
    main()
