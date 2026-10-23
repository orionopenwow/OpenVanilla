"""The pit's part of the website's duels_live.json (patch 0061; hetzner/duels_up.sh write_live).

    pit_section(env, now, CLASS, RACE, stats, matchups) -> dict

env holds the database rows as tab-separated text (PIT, PIT_FEED, PIT_NOW, CUP_NOW, CUPS); stats and
matchups are the queue's class records and class-against-class counts, which counted pit fights add to.
The result:
  ladder  [{name, race, class, wins, losses, streak, best_streak, points, brawls, cups, title, rank}]
  feed    [{t, kind, winner:{name,class}, loser:{name,class}, seconds, dealt, taken, counted, stake}]
  now     {state, champion:{name,class,streak}, fight:{sides:[{name,class,health,dealt}], start, kind},
           line, waiting:[names], brawl_in, brawl_left, here} or None when the world server is quiet
  cup     {state, week, starts_in, entrants, champion, round, rounds:[[{a,b,winner}]]} or None
  cups    [{week, name, entrants, ended}]
  today, week   fights in the last 24 hours and 7 days
"""

STALE = 90


def num(x):
    try:
        return int(x)
    except Exception:
        return 0


def rows(text, width):
    for line in (text or "").splitlines():
        f = line.split("\t")
        if len(f) >= width:
            yield f


def fresh(text, now):
    f = (text or "").split("\t")
    if len(f) == 2 and now - num(f[1]) < STALE:
        return f[0]
    return None


def parse_now(body, CLASS):
    # pit;<state>;<champion>:<class>:<streak>;<a>:<class>:<health>:<dealt>|<b>:...;<start>;<kind>;<waiting>;<names,>;<brawl in>;<brawl left>;<here>
    p = body.split(";")
    if len(p) < 11 or p[0] != "pit":
        return None
    champ = (p[2].split(":") + ["", "0", "0"])[:3]
    out = {"state": p[1], "champion": {"name": champ[0], "class": CLASS.get(num(champ[1]), ""), "streak": num(champ[2])} if champ[0] else None,
           "fight": None, "line": num(p[6]), "waiting": [n for n in p[7].split(",") if n],
           "brawl_in": num(p[8]), "brawl_left": num(p[9]), "here": num(p[10])}
    if p[3]:
        sides = []
        for s in p[3].split("|"):
            x = (s.split(":") + ["", "0", "0", "0"])[:4]
            sides.append({"name": x[0], "class": CLASS.get(num(x[1]), ""), "health": num(x[2]), "dealt": num(x[3])})
        out["fight"] = {"sides": sides, "start": num(p[4]), "kind": p[5]}
    return out


def parse_cup(body):
    # cup;<state>;<week>;<starts in>;<entrants>;<champion>;<round>;<a:b:w,...>;<a:b:w,...>...
    p = body.split(";")
    if len(p) < 7 or p[0] != "cup":
        return None
    rounds = []
    for r in p[7:]:
        fights = []
        for f in r.split(","):
            x = (f.split(":") + ["", "", "0"])[:3]
            if x[0]:
                fights.append({"a": x[0], "b": x[1], "winner": num(x[2])})
        rounds.append(fights)
    return {"state": p[1], "week": num(p[2]), "starts_in": num(p[3]), "entrants": num(p[4]),
            "champion": p[5], "round": num(p[6]), "rounds": rounds}


def pit_section(env, now, CLASS, RACE, stats, matchups):
    out = {"ladder": [], "feed": [], "now": None, "cup": None, "cups": [], "today": 0, "week": 0}
    for i, f in enumerate(rows(env.get("PIT", ""), 12)):
        out["ladder"].append({"name": f[1], "race": RACE.get(num(f[2]), ""), "class": CLASS.get(num(f[3]), ""),
                              "wins": num(f[4]), "losses": num(f[5]), "streak": num(f[6]), "best_streak": num(f[7]),
                              "points": num(f[8]), "brawls": num(f[9]), "cups": num(f[10]),
                              "title": f[11] if f[11] != "NULL" else "", "rank": i + 1})
    for f in rows(env.get("PIT_FEED", ""), 11):
        ended, kind = num(f[0]), f[1]
        if now - ended < 86400:
            out["today"] += 1
        if now - ended < 7 * 86400:
            out["week"] += 1
        w = {"name": f[2], "class": CLASS.get(num(f[3]), "")}
        lo = {"name": f[4], "class": CLASS.get(num(f[5]), "")}
        counted = f[9] == "1"
        if counted and kind != "brawl" and now - ended < 7 * 86400 and w["class"] and lo["class"]:
            for who, key in ((w, "wins"), (lo, "losses")):
                stats.setdefault(who["class"], {"class": who["class"], "wins": 0, "losses": 0})[key] += 1
            matchups.setdefault(w["class"], {}).setdefault(lo["class"], [0, 0])[0] += 1
            matchups.setdefault(lo["class"], {}).setdefault(w["class"], [0, 0])[1] += 1
        if len(out["feed"]) < 25:
            out["feed"].append({"t": ended, "kind": kind, "winner": w, "loser": lo if kind != "brawl" else None,
                                "seconds": num(f[6]), "dealt": num(f[7]), "taken": num(f[8]), "counted": counted, "stake": num(f[10])})
    body = fresh(env.get("PIT_NOW", ""), now)
    if body:
        out["now"] = parse_now(body, CLASS)
    cupf = (env.get("CUP_NOW", "") or "").split("\t")
    if len(cupf) == 2 and cupf[0]:
        out["cup"] = parse_cup(cupf[0])
        if out["cup"]:
            out["cup"]["updated"] = num(cupf[1])
    for f in rows(env.get("CUPS", ""), 4):
        out["cups"].append({"week": num(f[0]), "name": f[1], "entrants": num(f[2]), "ended": num(f[3])})
    return out
