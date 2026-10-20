#!/usr/bin/env python3
"""Open Vanilla realm telemetry report: what realm.db (realm_telemetry.py) says needs fixing.

  report.py --db /var/lib/openvanilla-telemetry/realm.db [--days 7] [--out DIR]

Prints a short summary meant for a person or for pasting to Claude, and writes CSVs with the detail:
  stuck.csv    places where players stood 10+ minutes online, alive, with no XP (terrain, pathing, a
               broken NPC or object)
  deaths.csv   places where players die most (a tuning or pathing problem when it's one spot)
  quests.csv   per quest: taken, objectives done, turned in, dropped; low finish rates first
  pace.csv     minutes per level, by level, against the realm's XP table
  zones.csv    player minutes per zone
"""
import argparse, csv, os, sqlite3, statistics, time
from collections import defaultdict

STUCK_MIN = 10
CELL = 10   # yards


def med(xs):
    return round(statistics.median(xs), 1) if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="/var/lib/openvanilla-telemetry/realm.db")
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    db = sqlite3.connect(a.db)
    since = int(time.time() - a.days * 86400)
    out = a.out or os.path.join(os.path.dirname(a.db), "report")
    os.makedirs(out, exist_ok=True)

    snaps = defaultdict(list)
    for row in db.execute("SELECT pid, t, level, xp, map, zone, x, y, dead FROM snap WHERE t >= ? ORDER BY pid, t", (since,)):
        snaps[row[0]].append(row[1:])
    players = len(snaps)
    minutes = sum(len(v) for v in snaps.values())

    # stuck: a run of samples at one spot, alive, same XP, for STUCK_MIN minutes or more
    stuck = defaultdict(lambda: {"players": set(), "minutes": 0, "zone": 0})
    deaths = defaultdict(lambda: {"players": set(), "deaths": 0, "zone": 0})
    zones = defaultdict(int)
    pace = defaultdict(list)
    def flush(run, pid, zone):
        if len(run) >= STUCK_MIN:
            m0, x0, y0 = run[0][1][0], run[0][1][1], run[0][1][2]
            c = (m0, zone, x0 // CELL * CELL, y0 // CELL * CELL)
            stuck[c]["players"].add(pid); stuck[c]["minutes"] += len(run); stuck[c]["zone"] = zone

    for pid, rows in snaps.items():
        run = []
        was_dead = False
        level_start = {}
        for t, level, xp, m, zone, x, y, dead in rows:
            zones[zone] += 1
            level_start.setdefault(level, t)
            if dead and not was_dead:
                c = (m, zone, x // CELL * CELL, y // CELL * CELL)
                deaths[c]["players"].add(pid); deaths[c]["deaths"] += 1; deaths[c]["zone"] = zone
            was_dead = bool(dead)
            key = (m, x, y, xp, level)
            if run and run[-1][1] == key and not dead and t - run[-1][0] <= 180:
                run.append((t, key))
            else:
                flush(run, pid, zone)
                run = [(t, key)] if not dead else []
        flush(run, pid, rows[-1][4] if rows else 0)
        levels = sorted(level_start)
        for lv, nxt in zip(levels, levels[1:]):
            if nxt == lv + 1:
                pace[lv].append((level_start[nxt] - level_start[lv]) / 60)

    # quests: transitions between looks
    q = defaultdict(lambda: {"taken": set(), "done": set(), "turned_in": set(), "dropped": set()})
    last = {}
    for t, pid, quest, status, rewarded in db.execute(
            "SELECT t, pid, quest, status, rewarded FROM quest WHERE t >= ? ORDER BY t", (since,)):
        prev = last.get((pid, quest))
        if status == 3 and (prev is None or prev[0] == 0):
            q[quest]["taken"].add(pid)
        if status == 1 and rewarded == 0:
            q[quest]["done"].add(pid)
        if rewarded == 1 and prev is not None and prev[1] == 0:
            q[quest]["turned_in"].add(pid)
        if status == 0 and rewarded == 0 and prev is not None and prev[0] in (1, 3):
            q[quest]["dropped"].add(pid)
        last[(pid, quest)] = (status, rewarded)

    def write(name, header, rows):
        with open(os.path.join(out, name), "w", newline="") as f:
            w = csv.writer(f); w.writerow(header); w.writerows(rows)

    stuck_rows = sorted(([k[0], k[1], k[2], k[3], len(v["players"]), v["minutes"]] for k, v in stuck.items()),
                        key=lambda r: (-r[4], -r[5]))
    write("stuck.csv", ["map", "zone", "x", "y", "players", "minutes"], stuck_rows)
    death_rows = sorted(([k[0], k[1], k[2], k[3], len(v["players"]), v["deaths"]] for k, v in deaths.items()),
                        key=lambda r: (-r[4], -r[5]))
    write("deaths.csv", ["map", "zone", "x", "y", "players", "deaths"], death_rows)
    quest_rows = []
    for quest, v in q.items():
        taken = len(v["taken"])
        fin = len(v["turned_in"])
        quest_rows.append([quest, taken, len(v["done"]), fin, len(v["dropped"]),
                           round(fin / taken, 2) if taken else None])
    quest_rows.sort(key=lambda r: (r[5] if r[5] is not None else 9, -r[1]))
    write("quests.csv", ["quest", "taken", "objectives_done", "turned_in", "dropped", "finish_rate"], quest_rows)
    xp_table = dict(db.execute("SELECT level, xp FROM xp_for_level"))
    pace_rows = [[lv, len(v), med(v), xp_table.get(lv)] for lv, v in sorted(pace.items())]
    write("pace.csv", ["level", "samples", "median_minutes", "xp_to_next"], pace_rows)
    write("zones.csv", ["zone", "player_minutes"], sorted(([z, n] for z, n in zones.items()), key=lambda r: -r[1]))

    print(f"Open Vanilla realm telemetry, last {a.days:g} days: {players} players, {minutes} player-minutes online.")
    print("Stuck spots (players, minutes):", ", ".join(f"map {r[0]} zone {r[1]} ({r[2]},{r[3]}) {r[4]}p/{r[5]}m" for r in stuck_rows[:5]) or "none")
    print("Death spots (players, deaths):", ", ".join(f"zone {r[1]} ({r[2]},{r[3]}) {r[4]}p/{r[5]}" for r in death_rows[:5]) or "none")
    weak = [r for r in quest_rows if r[1] >= 3 and r[5] is not None and r[5] < 0.5][:8]
    print("Quests taken 3+ times and finished by under half:", ", ".join(f"{r[0]} ({r[3]}/{r[1]})" for r in weak) or "none")
    print("Median minutes per level:", ", ".join(f"{r[0]}:{r[2]}" for r in pace_rows if r[1] >= 2) or "not enough data yet")
    print("CSV detail in", out)


if __name__ == "__main__":
    main()
