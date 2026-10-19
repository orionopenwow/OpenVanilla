"""Give an existing Open Vanilla account a GM level, without touching its password.

Usage (from the Open Vanilla folder, with the server's database running):
    python set_gmlevel.py --list              show every account that has a GM level
    python set_gmlevel.py ACCOUNT LEVEL       e.g.  python set_gmlevel.py BOB 2

Levels (CMaNGOS Classic):
    0  Player         normal account (use this to take GM away)
    1  Moderator      teleport, announce, mute, lookups
    2  Game Master    + spawn/delete NPCs and objects, kick, tickets, guilds
    3  Administrator  + bans, items, levels, server restart/shutdown, reloads

ACCOUNT is the login name, not a character name (in game, .pinfo CharName shows it).
The player must log out and back in for the new level to apply.
"""
import re
import sys

import server_control

NAMES = {0: "Player", 1: "Moderator", 2: "Game Master", 3: "Administrator"}


def query(sql):
    ret, out, err = server_control.run_mysql_query("USE classicrealmd; " + sql)
    if ret != 0:
        sys.exit(f"[ERROR] Database query failed (is the database running?): {err.strip()}")
    return out


def list_staff():
    out = query("SELECT username, gmlevel FROM account WHERE gmlevel > 0 ORDER BY gmlevel DESC, username;")
    rows = [line.split("\t") for line in out.strip().splitlines()[1:] if line.strip()]
    if not rows:
        print("No accounts have a GM level yet.")
    for name, lvl in rows:
        print(f"  {name:<20} {lvl}  {NAMES.get(int(lvl), '?')}")


def set_level(account, level):
    if not re.fullmatch(r"[A-Za-z0-9_]{1,32}", account):
        sys.exit("[ERROR] Account names are letters, digits and _ only.")
    if level not in NAMES:
        sys.exit("[ERROR] Level must be 0, 1, 2 or 3.")
    account = account.upper()
    out = query(f"SELECT gmlevel FROM account WHERE username='{account}';")
    lines = out.strip().splitlines()
    if len(lines) < 2:
        sys.exit(f"[ERROR] No account named {account}. (Use the login name, not a character name.)")
    before = int(lines[1])
    query(f"UPDATE account SET gmlevel={level} WHERE username='{account}';")
    print(f"[OK] {account}: {NAMES.get(before, before)} -> {NAMES[level]} (level {level}).")
    print("     They need to log out and back in for it to take effect.")


def show(account):
    if not re.fullmatch(r"[A-Za-z0-9_]{1,32}", account):
        sys.exit("[ERROR] Account names are letters, digits and _ only.")
    print(query(f"SELECT NOW() AS server_time; SELECT * FROM account WHERE username='{account.upper()}'\\G"))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--show":
        show(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] in ("--list", "-l"):
        list_staff()
    elif len(sys.argv) == 3 and sys.argv[2].isdigit():
        set_level(sys.argv[1], int(sys.argv[2]))
    else:
        print(__doc__)
