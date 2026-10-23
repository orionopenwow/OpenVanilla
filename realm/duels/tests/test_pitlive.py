"""The website's pit numbers (tools/duels/pitlive.py, patch 0061): rows from the database as the world server
and duels_up.sh write them, into duels_live.json's "pit" section."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "duels"))
from pitlive import pit_section  # noqa: E402

CLASS = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}
RACE = {1: "Human", 2: "Orc", 5: "Undead"}
now = 1792800000
fails = 0


def check(ok, what):
    global fails
    print(("ok   " if ok else "FAIL ") + what)
    fails += 0 if ok else 1


env = {
    "PIT": "5\tKaelix\t2\t4\t12\t3\t4\t6\t15\t1\t0\tCup Champion\n6\tMorva\t5\t8\t9\t5\t0\t3\t9\t0\t0\tNULL\nbroken",
    "PIT_FEED": "%d\tline\tKaelix\t4\tMorva\t8\t40\t9000\t7000\t1\t0\n%d\tbrawl\tKaelix\t4\t\t0\t180\t3\t0\t1\t0\n"
                "%d\tpit\tAlt\t1\tKaelix\t4\t20\t100\t50\t0\t0\n%d\tpit\tOld\t1\tGone\t8\t20\t100\t50\t1\t0"
                % (now - 100, now - 200, now - 300, now - 8 * 86400),
    # the world server's row 4: pit;state;champion;fight sides;start;kind;line;names;brawl in;brawl left;here
    "PIT_NOW": "pit;fight;Kaelix:4:3;Kaelix:4:80:2000|Morva:8:55:1500;%d;line;2;Ash,Bree;3540;0;7\t%d" % (now - 20, now - 5),
    "CUP_NOW": "cup;run;2961;-300;4;;1;Kaelix:Morva:1,Ash:Bree:0;Kaelix::0\t%d" % now,
    "CUPS": "2960\tKaelix\t8\t1792000000",
}
stats, m = {}, {}
o = pit_section(env, now, CLASS, RACE, stats, m)
check(len(o["ladder"]) == 2, "two duelists (a broken row is skipped)")
check(o["ladder"][0]["title"] == "Cup Champion" and o["ladder"][1]["title"] == "", "titles, NULL as none")
check(o["ladder"][1]["race"] == "Undead" and o["ladder"][1]["class"] == "Mage", "race and class names")
check(o["today"] == 3 and o["week"] == 3, "fights today and this week")
check(m.get("Rogue", {}).get("Mage") == [1, 0] and m.get("Mage", {}).get("Rogue") == [0, 1], "a counted line fight is a matchup")
check("Warrior" not in m, "an uncounted fight and an old one are not")
check(stats["Rogue"]["wins"] == 1 and stats["Mage"]["losses"] == 1, "class records")
check(o["feed"][1]["loser"] is None and o["feed"][1]["kind"] == "brawl", "a brawl has no loser")
f = o["now"]["fight"]
check(f["sides"][0]["health"] == 80 and f["sides"][1]["name"] == "Morva" and f["kind"] == "line", "the fight now")
check(o["now"]["champion"]["streak"] == 3 and o["now"]["waiting"] == ["Ash", "Bree"] and o["now"]["here"] == 7, "champion, line, hangout")
check(o["cup"]["state"] == "run" and len(o["cup"]["rounds"]) == 2 and o["cup"]["rounds"][0][0]["winner"] == 1, "the cup's bracket")
check(o["cups"][0]["name"] == "Kaelix", "last cups")
old = dict(env, PIT_NOW="pit;idle;;;0;;0;;100;0;0\t%d" % (now - 500))
check(pit_section(old, now, CLASS, RACE, {}, {})["now"] is None, "a stale pit row is no pit now")
quiet = dict(env, PIT_NOW="pit;idle;;;0;;0;;100;0;3\t%d" % now)
q = pit_section(quiet, now, CLASS, RACE, {}, {})["now"]
check(q["fight"] is None and q["champion"] is None and q["waiting"] == [], "a quiet pit")
check(pit_section({}, now, CLASS, RACE, {}, {})["ladder"] == [], "no rows at all")
print("%d FAILED" % fails if fails else "all ok")
sys.exit(1 if fails else 0)
