#!/usr/bin/env python3
"""Open Vanilla GM console: the whole realm on one page, for the GM.

Run as root on the realm server. It listens on 127.0.0.1 only (never the internet): open it from your
PC with Server.bat option G, which starts it over SSH with a tunnel and opens your browser.

    OVGM_TOKEN=<random> python3 gm_console.py [port]      (default port 8090)

Environment: OVGM_TOKEN (the key in the link), OW_REALM_DIR (the realm's compose folder), OVGM_SH (ov_gm.sh,
for the restart countdown) and OVGM_NOTES (the GM's ticket notes, default /var/lib/ovgm/notes.sqlite).

What it shows, refreshed every 5 seconds: every player in the world (character, level, class, race, guild,
zone and position, health, gold, time played, honor, free bag slots, game account, Discord name, the
account's last IP and whether another online account shares it, GM level, muted, dead or ghost), where
they are on a parchment map of both continents (with corpses if you want), totals, the world server's
uptime and login queue, each container's CPU, memory and network with a CPU history, World chat (lines
that look like gold selling, slurs or GM impersonation are marked) and the newest bug reports as tickets
(Open / Investigating / Resolved / Duplicate, with the GM's notes kept next to this script).

On demand: a character's items (read-only), and a gold audit (the richest characters and big gold mails).

What it does, through the world server's console (the HELPDESK login in /etc/openvanilla-herald.env):
a message to one player, an announcement or on-screen notice to everyone, kick, mute and unmute, revive,
send a player to any teleport location, jail (GM Island and a mute), reset talents, repair gear, ban an
account or an IP (with a reason), game events, the restart countdown (and calling it off), maintenance
reloads and any GM command. "Go to them" copies .appear <name> for you to paste in game (the console has
no character to move).

Player text is shown as text, never as page markup. Nothing here is reachable without the token.
"""
import base64, collections, html, ipaddress, json, os, re, secrets, sqlite3, subprocess, sys, tempfile, threading, time
import codecs
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

REALM_DIR = os.environ.get("OW_REALM_DIR", "/opt/wenilla-realm")
HERALD_ENV = "/etc/openvanilla-herald.env"
GM_SH = os.environ.get("OVGM_SH", "/opt/openvanilla-classicplus/ov_gm.sh")
NOTES_DB = os.environ.get("OVGM_NOTES", "/var/lib/ovgm/notes.sqlite")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 8090
TOKEN = os.environ.get("OVGM_TOKEN") or secrets.token_urlsafe(18)

RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
HORDE_RACES = {2, 5, 6, 8}
CLASSES = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}
ZONES = {1: "Dun Morogh", 3: "Badlands", 4: "Blasted Lands", 8: "Swamp of Sorrows", 10: "Duskwood", 11: "Wetlands",
         12: "Elwynn Forest", 14: "Durotar", 15: "Dustwallow Marsh", 16: "Azshara", 17: "The Barrens", 25: "Blackrock Mountain",
         28: "Western Plaguelands", 33: "Stranglethorn Vale", 36: "Alterac Mountains", 38: "Loch Modan", 40: "Westfall",
         41: "Deadwind Pass", 44: "Redridge Mountains", 45: "Arathi Highlands", 46: "Burning Steppes", 47: "The Hinterlands",
         51: "Searing Gorge", 85: "Tirisfal Glades", 130: "Silverpine Forest", 139: "Eastern Plaguelands", 141: "Teldrassil",
         148: "Darkshore", 215: "Mulgore", 267: "Hillsbrad Foothills", 331: "Ashenvale", 357: "Feralas", 361: "Felwood",
         400: "Thousand Needles", 405: "Desolace", 406: "Stonetalon Mountains", 440: "Tanaris", 490: "Un'Goro Crater",
         491: "Razorfen Kraul", 493: "Moonglade", 618: "Winterspring", 717: "The Stockade", 718: "Wailing Caverns",
         719: "Blackfathom Deeps", 721: "Gnomeregan", 722: "Razorfen Downs", 796: "Scarlet Monastery", 1176: "Zul'Farrak",
         1337: "Uldaman", 1377: "Silithus", 1477: "Sunken Temple", 1497: "Undercity", 1519: "Stormwind City",
         1537: "Ironforge", 1581: "The Deadmines", 1583: "Blackrock Spire", 1584: "Blackrock Depths", 1637: "Orgrimmar",
         1638: "Thunder Bluff", 1657: "Darnassus", 1977: "Zul'Gurub", 2017: "Stratholme", 2057: "Scholomance",
         2100: "Maraudon", 2159: "Onyxia's Lair", 2257: "Deeprun Tram", 2557: "Dire Maul", 2597: "Alterac Valley",
         2677: "Blackwing Lair", 2717: "Molten Core", 3277: "Warsong Gulch", 3358: "Arathi Basin",
         3428: "Temple of Ahn'Qiraj", 3429: "Ruins of Ahn'Qiraj", 3456: "Naxxramas"}
# the teleport names used when classicmangos.game_tele can't be read (these exist in every cmangos-classic world)
PLACES = ["Stormwind", "Ironforge", "Darnassus", "Orgrimmar", "Undercity", "ThunderBluff", "Goldshire", "Razorhill", "GMIsland"]
# the quick-port list: whichever of these game_tele has (capitals, starting areas, GM Island)
QUICK = ["Stormwind", "Ironforge", "Darnassus", "Orgrimmar", "Undercity", "ThunderBluff", "GMIsland", "Goldshire",
         "Northshire", "NorthshireAbbey", "ColdridgeValley", "Coldridge", "Kharanos", "Shadowglen", "Dolanaar",
         "ValleyOfTrials", "Razorhill", "Deathknell", "Brill", "CampNarache", "Bloodhoof", "BootyBay", "Gadgetzan", "Ratchet"]
JAIL = "GMIsland"
MAINT = {"saveall": ("Save every character", ".saveall"),
         "reload_config": ("Reload the world config", ".reload config"),
         "reload_tele": ("Reload teleport locations", ".reload game_tele"),
         "events_active": ("List running events", ".event activelist")}
TICKET_STATUSES = ["Open", "Investigating", "Resolved", "Duplicate"]
NAME_RE = re.compile(r"^[^\W\d_]{2,12}$")
ACCOUNT_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
TELE_RE = re.compile(r"^[A-Za-z0-9_'-]{1,48}$")
BANTIME_RE = re.compile(r"^(?:-1|(?:\d{1,4}[dhms]){1,4})$")
PLAYER_FLAG_GHOST = 0x10


def conf(path, key):
    val = ""
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            if line.startswith(key + "="):
                val = line.split("=", 1)[1].strip()      # the last one wins, as in the shell scripts
    except OSError:
        pass
    return val


def db_password():
    return conf(os.path.join(REALM_DIR, ".env"), "DB_ROOT_PASSWORD").strip("'\"")


SQL_ERRORS = []


def sql(query):
    """Rows (lists of strings) from the realm's MariaDB, through the mariadb container."""
    env = dict(os.environ, MYSQL_PWD=db_password())
    try:
        out = subprocess.run(["docker", "compose", "exec", "-T", "-e", "MYSQL_PWD", "mariadb", "mariadb", "-uroot",
                              "-N", "-B", "classiccharacters", "-e", query],
                             cwd=REALM_DIR, env=env, capture_output=True, text=True, timeout=20)
    except Exception as e:
        SQL_ERRORS.append(f"database: {type(e).__name__}")
        return []
    if out.returncode != 0:
        SQL_ERRORS.append("database: " + (out.stderr.strip().splitlines() or ["no answer"])[-1][:200])
    return [l.split("\t") for l in out.stdout.splitlines() if l]


def console(command):
    """The world server's answer to a console command, and whether it took it."""
    user, pw = conf(HERALD_ENV, "SOAP_USER"), conf(HERALD_ENV, "SOAP_PASS")
    url = conf(HERALD_ENV, "SOAP_URL") or "http://127.0.0.1:17878/"
    if not user or not pw:
        return False, "No console login in /etc/openvanilla-herald.env (run herald_up.sh once)."
    body = ('<?xml version="1.0" encoding="utf-8"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/'
            'envelope/" xmlns:ns1="urn:MaNGOS"><SOAP-ENV:Body><ns1:executeCommand><command>' + html.escape(command, quote=False)
            + "</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>")
    req = urllib.request.Request(url, data=body.encode(), headers={
        "Content-Type": "text/xml", "Authorization": "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()})
    try:
        text = urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
    except Exception as e:
        return False, f"The world server didn't answer ({type(e).__name__}): is it running?"
    m = re.search(r"<faultstring>(.*?)</faultstring>", text, re.S)
    if m:
        return False, html.unescape(m.group(1)).strip()
    m = re.search(r"<result>(.*?)</result>", text, re.S)
    return True, html.unescape(m.group(1) if m else "").replace("\r", "").strip()


# ---- what the database has (columns differ between cmangos builds and Open Vanilla patches) ---------
SCHEMA = {"at": 0, "cols": set()}
SCHEMA_TABLES = ("characters", "account", "guild", "guild_member", "corpse", "mail", "character_inventory", "item_instance",
                 "item_template", "openvanilla_bug_report", "openvanilla_world_log", "game_event", "game_tele",
                 "openvanilla_herald_fight", "openvanilla_herald_stuck")


def schema(force=False):
    """{(schema, table, column)} for the tables this page reads, checked every 10 minutes."""
    if force or not SCHEMA["cols"] or time.time() - SCHEMA["at"] > 600:
        rows = sql("SELECT table_schema, table_name, column_name FROM information_schema.columns WHERE table_schema IN "
                   "('classiccharacters', 'classicrealmd', 'classicmangos') AND table_name IN ("
                   + ", ".join(f"'{t}'" for t in SCHEMA_TABLES) + ")")
        cols = {(r[0], r[1], r[2].lower()) for r in rows if len(r) >= 3}
        if cols:
            SCHEMA.update(at=time.time(), cols=cols)
    return SCHEMA["cols"]


def has(table, *columns, db="classiccharacters"):
    cols = schema()
    return all((db, table, c.lower()) in cols for c in columns)


def num(v, default=0, kind=int):
    try:
        return kind(float(v)) if kind is int else kind(v)
    except (TypeError, ValueError):
        return default


def money(copper):
    return round(num(copper) / 10000, 2)


def public_ip(ip):
    """True for an address worth comparing or banning: not empty, private, loopback or the docker network."""
    try:
        a = ipaddress.ip_address(str(ip).strip())
    except ValueError:
        return False
    return not (a.is_private or a.is_loopback or a.is_unspecified or a.is_link_local or a.is_reserved or a.is_multicast)


# ---- chat lines worth a second look --------------------------------------------------------------
RMT_RE = re.compile(r"(?:https?://|www\.|\.(?:com|net|org|ru|cn|gg|io|shop|store)\b|discord\.gg|\bwts\b.*\bgold\b|"
                    r"\b(?:cheap|buy|sell(?:ing)?)\b.{0,20}\b(?:gold|gp|power ?level(?:ing)?)\b|\b(?:usd|eur|paypal|venmo|"
                    r"\$\s?\d+|\d+\s?\$|\d+\s?(?:usd|eur))\b)", re.I)
GM_RE = re.compile(r"(?:\b(?:i am|i'm|im|this is)\s+(?:a\s+|the\s+)?(?:gm|game ?master|admin|blizzard)\b|\[gm\]|<gm>|"
                   r"\bblizzard (?:staff|support|employee)\b|\bopen vanilla (?:staff|support|team)\b|"
                   r"\b(?:your|ur) account (?:will be|is being|has been) (?:banned|suspended|closed)\b)", re.I)
# slurs, stored rot13 so the source reads cleanly; matched as whole words with simple letter swaps
_SLURS = [codecs.decode(w, "rot13") for w in ("avttre", "avttn", "snttbg", "snt", "ergneq", "xvxr", "fcvp", "puvax",
                                               "gena", "jrgonpx", "pbba", "tbbx", "qlxr")]
SLUR_RE = re.compile(r"\b(?:" + "|".join(re.escape(w).replace("i", "[i1!]").replace("a", "[a4@]").replace("o", "[o0]")
                                           .replace("e", "[e3]") for w in _SLURS) + r")(?:s|z|ed|ing)?\b", re.I)
GM_NAME_RE = re.compile(r"^(?:gm|gamemaster|admin|blizz|blizzard|support|staff|moderator)", re.I)


def chat_flags(name, text):
    flags = []
    if RMT_RE.search(text or ""):
        flags.append("gold selling / link")
    if SLUR_RE.search(text or ""):
        flags.append("slur")
    if GM_RE.search(text or "") or GM_NAME_RE.match(name or ""):
        flags.append("GM impersonation")
    return flags


# ---- the GM's ticket notes (bug report status), in a small sqlite file next to the script -------------
NOTES_LOCK = threading.Lock()


def notes_db():
    os.makedirs(os.path.dirname(NOTES_DB) or ".", exist_ok=True)
    con = sqlite3.connect(NOTES_DB, timeout=5)
    con.execute("CREATE TABLE IF NOT EXISTS tickets (id INTEGER PRIMARY KEY, status TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', "
                "updated INTEGER NOT NULL)")
    return con


def tickets_for(ids):
    if not ids:
        return {}
    try:
        with NOTES_LOCK:
            con = notes_db()
            q = "SELECT id, status, note, updated FROM tickets WHERE id IN (%s)" % ",".join("?" * len(ids))
            rows = con.execute(q, [int(i) for i in ids]).fetchall()
            con.close()
    except (sqlite3.Error, OSError):
        return {}
    return {r[0]: {"status": r[1], "note": r[2], "updated": r[3]} for r in rows}


def save_ticket(tid, status, note):
    with NOTES_LOCK:
        con = notes_db()
        con.execute("INSERT INTO tickets (id, status, note, updated) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
                    "status = excluded.status, note = excluded.note, updated = excluded.updated", (tid, status, note, int(time.time())))
        con.commit()
        con.close()


# ---- the realm's state, gathered in the background ------------------------------------------------
STATE = {"at": 0, "players": [], "totals": {}, "chat": [], "bugs": [], "server": "", "containers": [], "corpses": [],
         "errors": []}
DISCORD = {}           # game account (WR000123) -> Discord name
LOCK = threading.Lock()
CPU_HIST = {}          # container -> its last 60 CPU samples (5 minutes)
HP_SEEN = {}           # character guid -> the highest health / mana saved while this page ran (the bar's 100%)


def load_discord():
    """Game account -> Discord name, from the realm service's sign-in database (copied out read-only)."""
    tmp = tempfile.mkdtemp()
    try:
        st = subprocess.run(["docker", "compose", "exec", "-T", "realm", "printenv", "REALM_STATE_DIR"], cwd=REALM_DIR,
                            capture_output=True, text=True, timeout=10).stdout.strip() or "/state"
        for f in ("realm.sqlite", "realm.sqlite-wal", "realm.sqlite-shm"):
            subprocess.run(["docker", "compose", "cp", f"realm:{st}/{f}", os.path.join(tmp, f)], cwd=REALM_DIR,
                           capture_output=True, timeout=20)
        con = sqlite3.connect(os.path.join(tmp, "realm.sqlite"))
        rows = con.execute("SELECT g.game_username, COALESCE(i.display_name, u.display_name, u.username) FROM game_accounts g "
                           "JOIN users u ON u.id = g.user_id LEFT JOIN identities i ON i.user_id = u.id AND i.provider = 'discord'"
                           ).fetchall()
        con.close()
        return {str(a).upper(): str(n or "") for a, n in rows}
    except Exception:
        return None
    finally:
        subprocess.run(["rm", "-rf", tmp])


def container_status(cpu, mem):
    if cpu >= 90 or mem >= 90:
        return "BAD"
    if cpu >= 70 or mem >= 75:
        return "WARNING"
    return "GOOD"


def docker_stats():
    try:
        ds = subprocess.run(["docker", "stats", "--no-stream", "--format",
                             "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}"],
                            capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return []
    out = []
    for line in ds.splitlines():
        f = line.split("\t")
        if len(f) < 3:
            continue
        name = f[0]
        cpu = num(f[1].rstrip("%"), 0.0, float)
        mem = num((f[3] if len(f) > 3 else "").rstrip("%"), 0.0, float)
        hist = CPU_HIST.setdefault(name, collections.deque(maxlen=60))
        hist.append(round(cpu, 1))
        out.append({"name": name, "cpu": round(cpu, 1), "mem": f[2], "mem_pct": round(mem, 1),
                    "net": f[4] if len(f) > 4 else "", "hist": list(hist), "status": container_status(cpu, mem)})
    for gone in set(CPU_HIST) - {c["name"] for c in out}:
        CPU_HIST.pop(gone, None)
    return out


def gather():
    SQL_ERRORS.clear()
    errors = []
    schema()
    # the roster: the base columns every cmangos-classic has, then whatever else this database has
    base = ["c.guid", "c.name", "c.level", "c.race", "c.class", "c.gender", "c.zone", "c.map", "ROUND(c.position_x, 1)",
            "ROUND(c.position_y, 1)", "ROUND(c.position_z, 1)", "c.money", "c.totaltime", "c.health", "a.username", "a.gmlevel",
            "IF(a.mutetime > UNIX_TIMESTAMP(), a.mutetime - UNIX_TIMESTAMP(), 0)", "c.xp"]
    opt = []
    if has("characters", "power1"): opt.append(("mana", "c.power1"))
    if has("characters", "playerFlags"): opt.append(("flags", "c.playerFlags"))
    if has("characters", "stored_honorable_kills"): opt.append(("hks", "c.stored_honorable_kills"))
    if has("characters", "honor_highest_rank"): opt.append(("rank", "c.honor_highest_rank"))
    if has("account", "last_ip", db="classicrealmd"): opt.append(("ip", "a.last_ip"))
    guilds = has("guild_member", "guid", "guildid") and has("guild", "guildid", "name")
    if guilds: opt.append(("guild", "g.name"))
    q = ("SELECT " + ", ".join(base + [e for _, e in opt]) + " FROM characters c JOIN classicrealmd.account a ON a.id = c.account "
         + ("LEFT JOIN guild_member gm ON gm.guid = c.guid LEFT JOIN guild g ON g.guildid = gm.guildid " if guilds else "")
         + "WHERE c.online = 1 AND a.username NOT LIKE 'RNDBOT%' ORDER BY c.name")
    players = []
    for r in sql(q):
        if len(r) < len(base) + len(opt):
            continue
        (guid, name, lvl, race, cls, gender, zone, mp, x, y, z, copper, played, hp, acc, gm, muted, xp) = r[:len(base)]
        extra = {k: (None if v == "NULL" else v) for (k, _), v in zip(opt, r[len(base):])}
        guid = num(guid)
        hp = num(hp)
        mana = num(extra.get("mana")) if "mana" in extra else None
        seen = HP_SEEN.setdefault(guid, [0, 0])
        seen[0] = max(seen[0], hp)
        if mana is not None:
            seen[1] = max(seen[1], mana)
        flags = num(extra.get("flags"))
        state = "ghost" if flags & PLAYER_FLAG_GHOST else ("dead" if hp == 0 else "alive")
        players.append({
            "guid": guid, "name": name, "level": num(lvl), "race": RACES.get(num(race), race), "race_id": num(race),
            "class": CLASSES.get(num(cls), cls), "faction": "Horde" if num(race) in HORDE_RACES else "Alliance",
            "zone": ZONES.get(num(zone), f"zone {zone}"), "map": num(mp), "x": num(x, 0.0, float), "y": num(y, 0.0, float),
            "z": num(z, 0.0, float), "gold": money(copper), "played_h": round(num(played) / 3600, 1), "health": hp,
            "health_max": seen[0], "mana": mana, "mana_max": seen[1] if mana is not None else None, "state": state,
            "account": acc, "discord": DISCORD.get(acc.upper(), ""), "gm": num(gm), "muted_s": num(muted), "xp": num(xp),
            "guild": extra.get("guild") or "", "ip": extra.get("ip") or "",
            "hks": num(extra.get("hks")) if "hks" in extra else None,
            "rank": num(extra.get("rank")) if "rank" in extra else None, "same_ip": [], "bag_free": None})
    # the same public IP on two or more online accounts (the relay's own private address doesn't count)
    by_ip = collections.defaultdict(set)
    for p in players:
        if public_ip(p["ip"]):
            by_ip[p["ip"]].add(p["account"])
    for p in players:
        if len(by_ip.get(p["ip"], ())) >= 2:
            p["same_ip"] = sorted(a for a in by_ip[p["ip"]] if a != p["account"])
    # free bag slots: the backpack's 16 plus the equipped bags' sizes, less what's in them (as of the last save)
    if players and has("character_inventory", "guid", "bag", "slot", "item", "item_template") and \
            has("item_template", "entry", "ContainerSlots", db="classicmangos"):
        free = sql("SELECT ci.guid, 16 + COALESCE(SUM(CASE WHEN ci.bag = 0 AND ci.slot BETWEEN 19 AND 22 THEN it.ContainerSlots END), 0)"
                   " - SUM(CASE WHEN (ci.bag = 0 AND ci.slot BETWEEN 23 AND 38) OR ci.bag IN (SELECT b.item FROM "
                   "character_inventory b WHERE b.guid = ci.guid AND b.bag = 0 AND b.slot BETWEEN 19 AND 22) THEN 1 ELSE 0 END) "
                   "FROM character_inventory ci JOIN characters c ON c.guid = ci.guid AND c.online = 1 "
                   "JOIN classicrealmd.account a ON a.id = c.account AND a.username NOT LIKE 'RNDBOT%' "
                   "LEFT JOIN classicmangos.item_template it ON it.entry = ci.item_template GROUP BY ci.guid")
        bag = {num(r[0]): num(r[1]) for r in free if len(r) >= 2}
        for p in players:
            if p["guid"] in bag:
                p["bag_free"] = max(0, bag[p["guid"]])
    online_guids = {p["guid"] for p in players}
    for g in set(HP_SEEN) - online_guids:
        HP_SEEN.pop(g, None)

    t = sql("SELECT (SELECT COUNT(*) FROM characters c JOIN classicrealmd.account a ON a.id = c.account WHERE c.online = 1 "
            "AND a.username LIKE 'RNDBOT%'), (SELECT COUNT(*) FROM characters c JOIN classicrealmd.account a ON a.id = c.account "
            "WHERE a.username NOT LIKE 'RNDBOT%'), (SELECT COUNT(*) FROM classicrealmd.account WHERE username NOT LIKE 'RNDBOT%'), "
            "(SELECT COUNT(*) FROM characters c JOIN classicrealmd.account a ON a.id = c.account WHERE a.username NOT LIKE "
            "'RNDBOT%' AND c.logout_time > UNIX_TIMESTAMP() - 86400)")
    totals = {"online": len(players)}
    if t and len(t[0]) >= 4:
        totals.update(bots=num(t[0][0]), characters=num(t[0][1]), accounts=num(t[0][2]), seen_24h=num(t[0][3]))
    chat = []
    for r in sql("SELECT FROM_UNIXTIME(created, '%H:%i'), name, text FROM openvanilla_world_log WHERE guild = 0 "
                 "ORDER BY id DESC LIMIT 60"):
        if len(r) >= 3:
            chat.append({"when": r[0], "name": r[1], "text": r[2], "flags": chat_flags(r[1], r[2])})
    # bug reports: the columns patch 0014 / classicplus_bugs.sql define, each only if it's there
    bcols = [("id", "id"), ("when", "FROM_UNIXTIME(created, '%m-%d %H:%i')"), ("name", "name"), ("category", "category"),
             ("text", "text"), ("zone", "zone")]
    for k in ("level", "class", "race", "map", "x", "y", "z", "context"):
        if has("openvanilla_bug_report", k):
            bcols.append((k, k if k not in "xyz" else f"ROUND({k}, 1)"))
    bugs = []
    for r in sql("SELECT " + ", ".join(e for _, e in bcols) + " FROM openvanilla_bug_report ORDER BY id DESC LIMIT 40"):
        if len(r) < len(bcols):
            continue
        b = {k: (None if v == "NULL" else v) for (k, _), v in zip(bcols, r)}
        b["id"] = num(b["id"])
        b["zone"] = ZONES.get(num(b["zone"], -1), b["zone"] or "")
        if b.get("class") is not None: b["class"] = CLASSES.get(num(b["class"]), b["class"])
        if b.get("race") is not None: b["race"] = RACES.get(num(b["race"]), b["race"])
        if all(b.get(k) not in (None, "") for k in ("x", "y", "z", "map")):
            b["go"] = f".go xyz {b['x']} {b['y']} {b['z']} {num(b['map'])}"
        bugs.append(b)
    notes = tickets_for([b["id"] for b in bugs])
    for b in bugs:
        n = notes.get(b["id"], {})
        b["status"], b["note"] = n.get("status", "Open"), n.get("note", "")
    corpses = []
    if has("corpse", "player", "map", "position_x", "position_y"):
        for r in sql("SELECT ch.name, k.map, ROUND(k.position_x), ROUND(k.position_y)" +
                     (", FROM_UNIXTIME(k.time, '%m-%d %H:%i')" if has("corpse", "time") else ", ''") +
                     " FROM corpse k LEFT JOIN characters ch ON ch.guid = k.player WHERE k.map IN (0, 1) LIMIT 300"):
            if len(r) >= 5:
                corpses.append({"name": "" if r[0] == "NULL" else r[0], "map": num(r[1]), "x": num(r[2], 0.0, float),
                                "y": num(r[3], 0.0, float), "when": r[4]})
    # Herald's last 24 hours (realm/mangos/0020's fight and stuck logs), when the tables are there
    herald = {}
    if has("openvanilla_herald_fight", "outcome"):
        day = "created > UNIX_TIMESTAMP() - 86400"
        for r in sql(f"SELECT COUNT(*), COALESCE(SUM(outcome='death'),0), COALESCE(ROUND(AVG(hp_min)),0), "
                     f"COALESCE(SUM(hp_min<20),0), COALESCE(SUM(group_size>1),0) FROM openvanilla_herald_fight WHERE {day}"):
            if len(r) >= 5:
                herald.update(fights=num(r[0]), deaths=num(r[1]), low=num(r[2]), close=num(r[3]), grouped=num(r[4]))
        herald["classes"] = [{"class": CLASSES.get(num(r[0]), r[0]), "fights": num(r[1]), "deaths": num(r[2])}
                             for r in sql(f"SELECT class, COUNT(*), SUM(outcome='death') FROM openvanilla_herald_fight "
                                          f"WHERE {day} GROUP BY class ORDER BY 2 DESC") if len(r) >= 3]
        if has("openvanilla_herald_stuck", "tier"):
            herald["stuck"] = num((sql(f"SELECT COUNT(*) FROM openvanilla_herald_stuck WHERE {day}") or [["0"]])[0][0])
            herald["spots"] = [{"zone": ZONES.get(num(r[0]), r[0]), "n": num(r[4]),
                                "go": f".go xyz {r[1]} {r[2]} {r[3]} {num(r[5])}"}
                               for r in sql(f"SELECT zone, ROUND(AVG(x),1), ROUND(AVG(y),1), ROUND(AVG(z),1), COUNT(*), map "
                                            f"FROM openvanilla_herald_stuck WHERE {day} GROUP BY map, zone, ROUND(x/20), ROUND(y/20) "
                                            f"ORDER BY 5 DESC LIMIT 5") if len(r) >= 6]
    ok, info = console(".server info")
    if not ok:
        errors.append("World server console: " + info)
    else:
        m = re.search(r"[Qq]ueue[d]?[^0-9\n]{0,20}(\d+)", info)
        if m:
            totals["queued"] = num(m.group(1))
    containers = docker_stats()
    errors = sorted(set(SQL_ERRORS)) + errors
    with LOCK:
        STATE.update(at=int(time.time()), players=players, totals=totals, chat=chat, bugs=bugs, corpses=corpses, herald=herald,
                     server=info if ok else "", containers=containers, errors=errors)


def loop():
    n = 0
    while True:
        if n % 12 == 0:                 # Discord names every minute
            d = load_discord()
            if d is not None:
                DISCORD.clear(); DISCORD.update(d)
        try:
            gather()
        except Exception as e:          # keep going: one bad read mustn't stop the page
            with LOCK:
                STATE["errors"] = [f"{type(e).__name__}: {e}"]
        n += 1
        time.sleep(5)


# ---- slower lists, loaded when the page asks ------------------------------------------------------
META = {"at": 0, "data": None}


def meta(force=False):
    """Teleport names (game_tele) and game events, cached for 5 minutes."""
    if not force and META["data"] and time.time() - META["at"] < 300:
        return META["data"]
    tele = [r[0] for r in sql("SELECT name FROM classicmangos.game_tele ORDER BY name") if r and TELE_RE.match(r[0])]
    events = []
    for r in sql("SELECT entry, description FROM classicmangos.game_event WHERE entry > 0 ORDER BY entry"):
        if len(r) >= 2 and r[0].isdigit():
            events.append([int(r[0]), r[1][:80]])
    places = tele or list(PLACES)
    low = {p.lower(): p for p in places}
    quick = [low[q.lower()] for q in QUICK if q.lower() in low]
    data = {"places": places, "quick": quick, "events": events, "from_db": bool(tele),
            "maint": [[k, v[0], v[1]] for k, v in MAINT.items()], "statuses": TICKET_STATUSES}
    if tele or events:
        META.update(at=time.time(), data=data)
    return data


def place_ok(place):
    if not TELE_RE.match(place or ""):
        return None
    for p in meta()["places"]:
        if p.lower() == place.lower():
            return p
    return None


SLOT_NAMES = {0: "Head", 1: "Neck", 2: "Shoulders", 3: "Shirt", 4: "Chest", 5: "Waist", 6: "Legs", 7: "Feet", 8: "Wrists",
              9: "Hands", 10: "Finger", 11: "Finger", 12: "Trinket", 13: "Trinket", 14: "Back", 15: "Main hand", 16: "Off hand",
              17: "Ranged", 18: "Tabard"}


def slot_place(bag_slot):
    if bag_slot <= 18: return "Equipped", SLOT_NAMES.get(bag_slot, "")
    if bag_slot <= 22: return "Bags", "bag slot"
    if bag_slot <= 38: return "Backpack", ""
    if bag_slot <= 62: return "Bank", ""
    if bag_slot <= 68: return "Bank", "bank bag slot"
    if bag_slot <= 80: return "Buyback", ""
    return "Keyring", ""


def inventory(name):
    """A character's items, read-only, as of the last save."""
    if not NAME_RE.match(name or ""):
        return {"ok": False, "result": "That isn't a character name."}
    if not has("character_inventory", "guid", "bag", "slot", "item"):
        return {"ok": False, "result": "This database has no character_inventory table."}
    if has("character_inventory", "item_template"):
        entry, join = "ci.item_template", ""
    elif has("item_instance", "guid", "itemEntry"):
        entry, join = "ii.itemEntry", ""
    else:
        return {"ok": False, "result": "Can't tell which item is which in this database."}
    count = has("item_instance", "guid", "count")
    if count or entry.startswith("ii."):
        join = "LEFT JOIN item_instance ii ON ii.guid = ci.item "
    named = has("item_template", "entry", "name", db="classicmangos")
    quality = has("item_template", "Quality", db="classicmangos")
    q = ("SELECT ci.item, ci.bag, ci.slot, " + entry + ", " + ("ii.count" if count else "1") + ", "
         + ("it.name" if named else "''") + ", " + ("it.Quality" if named and quality else "1")
         + " FROM characters c JOIN character_inventory ci ON ci.guid = c.guid " + join
         + ("LEFT JOIN classicmangos.item_template it ON it.entry = " + entry + " " if named else "")
         + f"WHERE c.name = '{name}' ORDER BY ci.bag, ci.slot")
    rows = [r for r in sql(q) if len(r) >= 7]
    parents = {r[0]: num(r[2]) for r in rows if r[1] == "0"}
    items = []
    for item_guid, bag, slot, ent, cnt, iname, qual in rows:
        if bag == "0":
            where, detail = slot_place(num(slot))
        else:
            ps = parents.get(bag)
            where = "Bank" if ps is not None and ps >= 63 else "Bags"
            detail = f"in bag {ps - 18 if ps is not None and ps <= 22 else '?'}, slot {num(slot) + 1}"
        items.append({"where": where, "detail": detail, "entry": num(ent), "count": num(cnt, 1) or 1,
                      "name": "" if iname == "NULL" else iname, "quality": num(qual, 1)})
    return {"ok": True, "name": name, "items": items}


def audit():
    """The richest characters, and big gold mails still in the database."""
    rich = [{"name": r[0], "level": num(r[1]), "class": CLASSES.get(num(r[2]), r[2]), "gold": money(r[3]), "account": r[4],
             "online": r[5] == "1"} for r in sql(
        "SELECT c.name, c.level, c.class, c.money, a.username, c.online FROM characters c JOIN classicrealmd.account a "
        "ON a.id = c.account WHERE a.username NOT LIKE 'RNDBOT%' ORDER BY c.money DESC LIMIT 20") if len(r) >= 6]
    mails = None
    if has("mail", "sender", "receiver", "money", "deliver_time"):
        typ = "AND m.messageType = 0 " if has("mail", "messageType") else ""
        mails = [{"when": r[0], "from": "" if r[1] == "NULL" else r[1], "to": "" if r[2] == "NULL" else r[2], "gold": money(r[3])}
                 for r in sql("SELECT FROM_UNIXTIME(m.deliver_time, '%m-%d %H:%i'), s.name, t.name, m.money FROM mail m "
                              "LEFT JOIN characters s ON s.guid = m.sender LEFT JOIN characters t ON t.guid = m.receiver "
                              "WHERE m.money >= 1000000 " + typ + "ORDER BY m.deliver_time DESC LIMIT 25") if len(r) >= 4]
    return {"ok": True, "rich": rich, "mails": mails}


# ---- actions -----------------------------------------------------------------------------------
RESTART = {"proc": None, "log": ""}
NEEDS_NAME = ("whisper", "kick", "mute", "unmute", "revive", "tele", "pinfo", "reset_talents", "repair", "jail", "ban_account",
              "ban_ip")


def clean_text(t, limit=200):
    t = re.sub(r"[\x00-\x1f\x7f|]", " ", str(t or "")).strip()
    return t[:limit]


def clamp(v, lo, hi, default):
    try:
        return max(lo, min(int(float(v)), hi))
    except (TypeError, ValueError):
        return default


def account_of(name):
    """(game account, last IP) of a character, from the database (never from the page)."""
    ip = "a.last_ip" if has("account", "last_ip", db="classicrealmd") else "''"
    r = sql(f"SELECT a.username, {ip} FROM characters c JOIN classicrealmd.account a ON a.id = c.account WHERE c.name = '{name}'")
    if not r or len(r[0]) < 2:
        return None, None
    return r[0][0], r[0][1]


def ban_args(a):
    dur = str(a.get("duration") or "").strip().lower()
    if not BANTIME_RE.match(dur):
        return None, None, "The ban length is like 1d, 12h, 7d12h, or -1 for permanent."
    reason = clean_text(a.get("reason"), 100)
    if len(reason) < 3:
        return None, None, "A ban needs a reason (players see it)."
    return dur, reason, None


def act(a):
    if not isinstance(a, dict):
        return False, "Unknown action."
    kind = a.get("act")
    name = str(a.get("name") or "").strip()
    if kind in NEEDS_NAME and not NAME_RE.match(name):
        return False, "That isn't a character name."
    text = clean_text(a.get("text"))
    if kind == "whisper":
        if not text: return False, "Type a message first."
        return console(f".send message {name} {text}")
    if kind == "kick":
        return console(f".kick {name}")
    if kind == "mute":
        return console(f".mute {name} {clamp(a.get('minutes'), 1, 10080, 10)}")
    if kind == "unmute":
        return console(f".unmute {name}")
    if kind == "revive":
        return console(f".revive {name}")
    if kind == "pinfo":
        return console(f".pinfo {name}")
    if kind == "reset_talents":
        return console(f".reset talents {name}")
    if kind == "repair":
        return console(f".repairitems {name}")
    if kind == "tele":
        place = place_ok(str(a.get("place") or ""))
        if not place: return False, "Pick a teleport location from the list."
        return console(f".tele name {name} {place}")
    if kind == "jail":
        place = place_ok(JAIL)
        if not place: return False, "This world has no GMIsland teleport location."
        mins = clamp(a.get("minutes"), 1, 10080, 60)
        ok, res = console(f".tele name {name} {place}")
        if not ok: return False, res
        ok2, res2 = console(f".mute {name} {mins}")
        return ok2, f"Sent to GM Island. {res}\n" + (f"Muted {mins} min. {res2}" if ok2 else f"Mute refused: {res2}")
    if kind == "ban_account":
        dur, reason, err = ban_args(a)
        if err: return False, err
        acc, _ = account_of(name)
        if not acc or not ACCOUNT_RE.match(acc): return False, f"No game account found for {name}."
        return console(f".ban account {acc} {dur} {reason}")
    if kind == "ban_ip":
        dur, reason, err = ban_args(a)
        if err: return False, err
        _, ip = account_of(name)
        if not ip or not public_ip(ip):
            return False, "Their last IP is private or unknown (e.g. the web relay's), so an IP ban would hit everyone. Ban the account."
        return console(f".ban ip {ip} {dur} {reason}")
    if kind in ("announce", "notify"):
        if not text: return False, "Type a message first."
        return console(f".{kind} {text}")
    if kind == "cmd":
        cmd = clean_text(a.get("text"), 250)
        if not cmd.startswith("."): return False, "A GM command starts with a dot."
        return console(cmd)
    if kind == "maint":
        m = MAINT.get(str(a.get("which") or ""))
        if not m: return False, "Unknown maintenance job."
        return console(m[1])
    if kind in ("event_start", "event_stop"):
        try:
            eid = int(str(a.get("event") or ""))
        except ValueError:
            return False, "Pick an event."
        if not 1 <= eid <= 65535: return False, "Pick an event."
        known = meta()["events"]
        if known and eid not in {e[0] for e in known}: return False, "That event isn't in game_event."
        return console(f".event {'start' if kind == 'event_start' else 'stop'} {eid}")
    if kind == "ticket":
        try:
            tid = int(str(a.get("id") or ""))
        except ValueError:
            return False, "Which report?"
        if tid < 1: return False, "Which report?"
        status = str(a.get("status") or "")
        if status not in TICKET_STATUSES: return False, "Pick a status."
        note = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", " ", str(a.get("note") or "")).strip()[:1000]
        save_ticket(tid, status, note)
        with LOCK:
            for b in STATE["bugs"]:
                if b.get("id") == tid:
                    b["status"], b["note"] = status, note
        return True, f"Report #{tid}: {status}."
    if kind == "restart":
        if RESTART["proc"] and RESTART["proc"].poll() is None:
            return False, "A restart countdown is already running."
        mins = clamp(a.get("minutes"), 1, 30, 5)
        why = clean_text(a.get("text"), 60) or "a quick restart"
        log = open("/var/log/ovgm-restart.log", "w")
        RESTART["proc"] = subprocess.Popen(["bash", GM_SH, "restart", str(mins), why], stdout=log, stderr=subprocess.STDOUT,
                                           env=dict(os.environ, OW_REALM_DIR=REALM_DIR), start_new_session=True)
        return True, f"Countdown started: {mins} minute(s), then the realm restarts. 'Call it off' stops it."
    if kind == "cancel":
        subprocess.run(["bash", GM_SH, "cancel"], capture_output=True, timeout=10)
        return True, "Called off: players are told within a second."
    return False, "Unknown action."


# ---- the page ------------------------------------------------------------------------------------
ICONS = {
    "go": '<path d="M2 8h7M6.5 5L9.5 8l-3 3"/><circle cx="12.5" cy="4.5" r="1.7"/><path d="M12.5 7v6"/>',
    "bring": '<path d="M14 8H7M9.5 5L6.5 8l3 3"/><circle cx="3.5" cy="4.5" r="1.7"/><path d="M3.5 7v6"/>',
    "send": '<path d="M2 8.5l12-6-4.5 12-2-4.5z"/><path d="M7.5 10L14 2.5"/>',
    "pin": '<path d="M8 14.5s4.8-4.4 4.8-8.2a4.8 4.8 0 0 0-9.6 0c0 3.8 4.8 8.2 4.8 8.2z"/><circle cx="8" cy="6.3" r="1.7"/>',
    "revive": '<path d="M8 14S2 10.3 2 6.2a3 3 0 0 1 6-1 3 3 0 0 1 6 1C14 10.3 8 14 8 14z"/><path d="M8 6.5v4M6 8.5h4"/>',
    "info": '<circle cx="8" cy="8" r="6.3"/><path d="M8 7.3v4.2M8 4.8v.2"/>',
    "mute": '<path d="M2 6h2.8L8.5 3v10L4.8 10H2z"/><path d="M11 6.2l3.6 3.6M14.6 6.2L11 9.8"/>',
    "unmute": '<path d="M2 6h2.8L8.5 3v10L4.8 10H2z"/><path d="M11 5.6a3.4 3.4 0 0 1 0 4.8M12.9 3.7a6.1 6.1 0 0 1 0 8.6"/>',
    "kick": '<path d="M3 2.5h6.5v11H3zM9.5 8H15M12.8 5.8L15 8l-2.2 2.2"/>',
    "ban": '<circle cx="8" cy="8" r="6.3"/><path d="M3.6 3.6l8.8 8.8"/>',
    "jail": '<rect x="2" y="2.5" width="12" height="11" rx="1"/><path d="M5.3 2.5v11M8 2.5v11M10.7 2.5v11"/>',
    "talents": '<path d="M13.4 8.3A5.4 5.4 0 1 1 11.5 4"/><path d="M12 1.2v3.3H8.7"/>',
    "repair": '<path d="M10.6 2.3a3 3 0 0 0-3.7 3.8L2.5 10.5a1.4 1.4 0 0 0 2 2l4.4-4.4a3 3 0 0 0 3.8-3.7l-1.9 1.9-1.6-.4-.4-1.6z"/>',
    "bag": '<path d="M3 5.2h10l-1 8.8H4z"/><path d="M5.6 5.2V4.3a2.4 2.4 0 0 1 4.8 0v.9"/>',
    "coin": '<circle cx="8" cy="8" r="6.2"/><path d="M8 4.3v7.4M10.1 6H7.1a1 1 0 0 0 0 2h1.8a1 1 0 0 1 0 2H5.9"/>',
    "copy": '<rect x="5" y="5" width="9" height="9" rx="1.5"/><path d="M11 5V3a1 1 0 0 0-1-1H3a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1h2"/>',
    "chat": '<path d="M2 3h12v8H6.3L2 14z"/>',
    "screen": '<rect x="1.5" y="2.5" width="13" height="9" rx="1"/><path d="M5.5 14h5M8 11.5V14"/>',
    "clock": '<circle cx="8" cy="8" r="6.3"/><path d="M8 4.6V8l2.4 1.5"/>',
    "stop": '<rect x="3.2" y="3.2" width="9.6" height="9.6" rx="1.5"/>',
    "run": '<path d="M4.5 3l8.5 5-8.5 5z"/>',
    "bug": '<ellipse cx="8" cy="9.5" rx="3.4" ry="4.4"/><path d="M8 5.2v8.6M6.2 4.6L4.6 3M9.8 4.6L11.4 3M4.6 8H2M4.7 11.5l-2 1.5M11.4 8H14M11.3 11.5l2 1.5"/>',
    "gear": '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v2.2M8 12.3v2.2M1.5 8h2.2M12.3 8h2.2M3.4 3.4L5 5M11 11l1.6 1.6M3.4 12.6L5 11M11 5l1.6-1.6"/>',
    "flag": '<path d="M3.5 14.5v-13M3.5 2.5h9l-2 3 2 3h-9"/>',
    "eye": '<path d="M1.2 8S3.6 3.3 8 3.3 14.8 8 14.8 8 12.4 12.7 8 12.7 1.2 8 1.2 8z"/><circle cx="8" cy="8" r="2"/>',
    "target": '<circle cx="8" cy="8" r="4.8"/><path d="M8 1v3.5M8 11.5V15M1 8h3.5M11.5 8H15"/>',
    "filter": '<path d="M2 3h12L9.5 8.5V13l-3 1.5V8.5z"/>',
    "search": '<circle cx="7" cy="7" r="4.3"/><path d="M10.2 10.2L14 14"/>',
    "skull": '<path d="M8 2a5 5 0 0 0-5 5c0 1.8.9 3 2 3.7V13h6v-2.3c1.1-.7 2-1.9 2-3.7a5 5 0 0 0-5-5z"/><circle cx="6.2" cy="7.5" r="1"/><circle cx="9.8" cy="7.5" r="1"/>',
    "save": '<path d="M3 2.5h8l2 2v9H3z"/><path d="M5.5 2.5v3.5h5V2.5M5.5 13.5v-4h5v4"/>',
}


def icon(name):
    return ('<svg class="ic" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5" '
            'stroke-linecap="round" stroke-linejoin="round">' + ICONS[name] + "</svg>")


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Open Vanilla GM Console</title><style>
:root{--bg:#070d19;--bg2:#0a1222;--panel:#0e1729;--panel2:#121d33;--line:#1f2d47;--line2:#2a3b5c;--text:#dfe5f0;--muted:#8391ab;
--dim:#5b6884;--gold:#d8b25a;--gold2:#f0cf7c;--red:#e5534b;--green:#5bbf6a;--blue:#4c8dff;--orange:#e8963c;--purple:#a77ef0;--gray:#8e99ad;
--ally:#3f7fe0;--horde:#d23c3c}
*{box-sizing:border-box}[hidden]{display:none!important}html{background:var(--bg)}
body{margin:0;background:radial-gradient(1200px 500px at 15% -10%,#13213d 0%,transparent 60%),var(--bg);color:var(--text);
font:13px/1.45 system-ui,"Segoe UI",Roboto,sans-serif;min-height:100vh}
.ic{width:14px;height:14px;flex:none;vertical-align:-2px}
header{display:flex;gap:10px;align-items:center;padding:12px 18px;border-bottom:1px solid var(--line);flex-wrap:wrap;
background:linear-gradient(#0d1730,#0a1224)}
h1{font:600 21px/1.1 Georgia,"Palatino Linotype","Book Antiqua",Palatino,"Times New Roman",serif;margin:0 12px 0 0;color:var(--gold);
letter-spacing:.02em;text-shadow:0 1px 0 #000,0 0 18px rgba(216,178,90,.18)}
.pill{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:3px 11px 3px 9px;font-size:12px;border:1px solid;
background:rgba(255,255,255,.03);white-space:nowrap}.pill b{font-size:14px;font-variant-numeric:tabular-nums}
.pill::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.p-green{color:var(--green);border-color:rgba(91,191,106,.45);background:rgba(91,191,106,.1)}
.p-gray{color:var(--gray);border-color:rgba(142,153,173,.4);background:rgba(142,153,173,.08)}
.p-orange{color:var(--orange);border-color:rgba(232,150,60,.45);background:rgba(232,150,60,.1)}
.p-blue{color:#6aa5ff;border-color:rgba(76,141,255,.45);background:rgba(76,141,255,.1)}
.p-purple{color:var(--purple);border-color:rgba(167,126,240,.45);background:rgba(167,126,240,.1)}
.p-red{color:var(--red);border-color:rgba(229,83,75,.45);background:rgba(229,83,75,.1)}
#sAge{color:var(--dim);font-size:12px;margin-left:auto}
main{display:grid;grid-template-columns:minmax(0,1.62fr) minmax(330px,1fr);gap:14px;padding:14px 18px 22px}
.col{display:flex;flex-direction:column;gap:14px;min-width:0}
@media(max-width:1100px){main{grid-template-columns:1fr}}
section{background:linear-gradient(180deg,var(--panel2),var(--panel) 60px);border:1px solid var(--line);border-radius:6px;
padding:11px 13px 12px;min-width:0;box-shadow:0 1px 0 rgba(255,255,255,.02) inset,0 6px 18px rgba(0,0,0,.25)}
h2{font:700 11.5px/1 system-ui,"Segoe UI",sans-serif;text-transform:uppercase;letter-spacing:.14em;color:var(--gold);margin:0 0 10px;
display:flex;align-items:center;gap:8px}h2 .sub{margin-left:auto;text-transform:none;letter-spacing:0;font-weight:400;color:var(--dim);font-size:12px}
h2::before{content:"";width:3px;height:12px;background:var(--gold);border-radius:1px;opacity:.85}
table{width:100%;border-collapse:separate;border-spacing:0}
th,td{text-align:left;padding:5px 6px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--muted);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.06em;cursor:pointer;user-select:none;
position:sticky;top:0;background:var(--panel2);z-index:1}th.on{color:var(--gold2)}
tbody tr{cursor:pointer}tbody tr:hover td{background:#16233d}
tr.sel td{background:#13244a;border-top:1px solid var(--blue);border-bottom:1px solid var(--blue)}
tr.sel td:first-child{border-left:1px solid var(--blue)}tr.sel td:last-child{border-right:1px solid var(--blue)}
td.num{text-align:right;font-variant-numeric:tabular-nums}th.num{text-align:right}
.scroll{overflow:auto}#rosterWrap{max-height:430px;font-size:12.5px}
.nm{display:inline-flex;align-items:center;gap:6px;font-weight:600}.emb{width:16px;height:18px;flex:none}
.cls{display:inline-flex;align-items:center;gap:5px}.cls svg{width:14px;height:14px}
.tag{display:inline-block;font-size:10px;line-height:15px;padding:0 5px;border-radius:3px;font-weight:700;letter-spacing:.03em;margin-left:2px}
.t-gm{background:rgba(216,178,90,.18);color:var(--gold2)}.t-mute{background:rgba(229,83,75,.18);color:#ff8a83}
.t-ip{background:rgba(232,150,60,.2);color:#ffb366}.t-dead{background:rgba(142,153,173,.2);color:#c3cad8}
.hp{display:inline-flex;align-items:center;gap:6px}.bar{width:46px;height:7px;border-radius:4px;background:#0a101d;border:1px solid #273652;overflow:hidden}
.bar i{display:block;height:100%;background:var(--green)}.bar i.lo{background:var(--orange)}.bar i.vlo{background:var(--red)}.bar i.mana{background:#3d7be0}
.hp span{font-variant-numeric:tabular-nums;color:var(--muted);font-size:12px;min-width:34px}
.gold{color:#f0cf7c}.dim{color:var(--dim)}.muted{color:var(--muted)}
.filters{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin:0 0 8px}
.filters label{display:inline-flex;gap:4px;align-items:center;color:var(--muted);font-size:12px;cursor:pointer}
.ipc{font-family:ui-monospace,Consolas,monospace;font-size:12px;color:var(--muted)}
button,select,input,textarea{background:#0b1426;color:var(--text);border:1px solid var(--line2);border-radius:4px;padding:5px 9px;font:inherit}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--blue);box-shadow:0 0 0 2px rgba(76,141,255,.18)}
button{cursor:pointer;display:inline-flex;align-items:center;gap:6px;background:linear-gradient(#17233c,#111b30);white-space:nowrap}
button:hover{border-color:#4a6290;background:linear-gradient(#1c2a47,#14203a)}
button.blue{background:linear-gradient(#3b78e7,#2a62c9);border-color:#4c8dff;color:#fff}button.blue:hover{background:linear-gradient(#4a86f2,#3170dc)}
button.red{background:linear-gradient(#c8423a,#a8322b);border-color:#e5534b;color:#fff}button.red:hover{background:linear-gradient(#d84d45,#b83a33)}
button.warn{border-color:rgba(229,83,75,.55);color:#ff9a93}button.warn:hover{border-color:var(--red)}
button.small{padding:3px 7px;font-size:12px}button:disabled{opacity:.45;cursor:default}
input[type=checkbox]{padding:0;width:14px;height:14px;accent-color:var(--blue)}
.row{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin:7px 0}.grow{flex:1;min-width:150px}
.lbl{color:var(--muted);font-size:12px}
/* player actions */
.who{display:flex;gap:12px;align-items:center;margin-bottom:6px}
.portrait{width:58px;height:58px;border-radius:6px;display:grid;place-items:center;font:700 28px/1 Georgia,serif;color:#0b1220;flex:none;
border:2px solid rgba(255,255,255,.25);box-shadow:inset 0 -12px 18px rgba(0,0,0,.28),0 0 0 1px #000,0 4px 12px rgba(0,0,0,.4);position:relative}
.portrait small{position:absolute;bottom:2px;right:3px;font:700 10px/1 system-ui;color:#0b1220;opacity:.8}
#selTitle{font:700 15px/1.25 Georgia,"Palatino Linotype",serif;color:var(--gold);letter-spacing:.06em;text-transform:uppercase}
.facts{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:4px 14px;margin:8px 0 4px;font-size:12px}
.facts .w2{grid-column:span 2}.facts div{display:flex;gap:6px;align-items:center;min-width:0}.facts b{color:var(--muted);font-weight:500;flex:none}
.facts span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.split{border-top:1px dashed var(--line);margin-top:8px;padding-top:2px}
/* map */
#mapWrap{position:relative}#map{width:100%;display:block;border-radius:4px;border:1px solid #3a2d18;background:#2f4a4c}
#tip{position:absolute;pointer-events:none;background:rgba(10,16,30,.95);border:1px solid var(--line2);border-radius:4px;padding:5px 8px;
font-size:12px;display:none;z-index:5;white-space:nowrap;box-shadow:0 4px 12px rgba(0,0,0,.5)}
.pinp{cursor:pointer}.pinp:hover circle.pc{stroke:#fff;stroke-width:2}
/* right column */
#out{white-space:pre-wrap;color:#b9c4d8;font:12px/1.45 ui-monospace,Consolas,"Cascadia Mono",monospace;max-height:190px;overflow:auto;
background:#060b16;border:1px solid var(--line);border-radius:4px;padding:7px 9px;margin-top:6px;min-height:46px}
#out .c{color:#6aa5ff}#out .e{color:#ff8a83}#out .ok{color:#cfe6d2}#out .t{color:var(--dim)}
.srv{white-space:pre-wrap;color:#b9c4d8;font:12px/1.45 ui-monospace,Consolas,monospace;margin-bottom:8px}
.ct{display:grid;grid-template-columns:minmax(80px,1.1fr) minmax(110px,1.3fr) 92px 74px;gap:8px;align-items:center;padding:5px 0;
border-top:1px solid var(--line);font-size:12px}.ct .n{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ct .v{color:var(--muted);font-variant-numeric:tabular-nums;line-height:1.3}.ct .v small{color:var(--dim)}
.badge{font-size:10.5px;font-weight:800;letter-spacing:.07em;text-align:center;border-radius:3px;padding:2px 0;border:1px solid}
.b-GOOD{color:var(--green);border-color:rgba(91,191,106,.5);background:rgba(91,191,106,.12)}
.b-WARNING{color:var(--orange);border-color:rgba(232,150,60,.5);background:rgba(232,150,60,.12)}
.b-BAD{color:var(--red);border-color:rgba(229,83,75,.55);background:rgba(229,83,75,.14)}
.spark{width:92px;height:24px;display:block}
.chat>div{padding:3px 4px;border-bottom:1px solid #152038;word-break:break-word}
.chat .t{color:var(--dim);font-variant-numeric:tabular-nums;margin-right:6px}.chat .n{color:#6aa5ff;cursor:pointer;font-weight:600}
.chat .n:hover{text-decoration:underline}.chat .flag{background:rgba(229,83,75,.1);border-left:2px solid var(--red)}
.chat .why{font-size:10px;color:#ff8a83;background:rgba(229,83,75,.15);border-radius:3px;padding:0 4px;margin-left:6px}
.bug{padding:6px 4px;border-bottom:1px solid #152038}.bug .top{display:flex;gap:7px;align-items:flex-start;cursor:pointer}
.bug .top svg{color:#9ccf6a;margin-top:2px}.bug .bn{color:#6aa5ff;font-weight:600}.bug .meta{color:var(--dim);font-size:11.5px;margin:2px 0 0 21px}
.st{font-size:10px;font-weight:700;border-radius:3px;padding:0 5px;margin-left:6px;border:1px solid;letter-spacing:.03em}
.st-Open{color:var(--orange);border-color:rgba(232,150,60,.5)}.st-Investigating{color:#6aa5ff;border-color:rgba(76,141,255,.5)}
.st-Resolved{color:var(--green);border-color:rgba(91,191,106,.5)}.st-Duplicate{color:var(--gray);border-color:rgba(142,153,173,.5)}
.bug .edit{margin:6px 0 2px 21px}.bug textarea{width:100%;min-height:46px;resize:vertical}
.bug.done .top{opacity:.55}
.err{color:#ff8a83;font-size:12px;margin-top:6px}.okc{color:var(--green)}
dialog{background:var(--panel);color:var(--text);border:1px solid var(--line2);border-radius:8px;padding:16px 18px;max-width:min(760px,94vw);
width:100%;box-shadow:0 20px 60px rgba(0,0,0,.6)}dialog::backdrop{background:rgba(3,6,14,.7)}
dialog h3{margin:0 0 10px;font:700 15px Georgia,serif;color:var(--gold);letter-spacing:.05em;text-transform:uppercase}
dialog .scroll{max-height:60vh}.q0{color:#9d9d9d}.q1{color:#fff}.q2{color:#1eff00}.q3{color:#0070dd}.q4{color:#a335ee}.q5{color:#ff8000}
.flex{display:flex;gap:8px;align-items:center}.right{margin-left:auto}
@media(max-width:640px){header{padding:10px 16px}main{padding:12px 16px}h1{font-size:18px}.ct{grid-template-columns:1fr 1fr}.ct .spark{width:100%}}
</style></head><body>
<header><h1>Open Vanilla &ndash; GM Console</h1>
<span class="pill p-green" title="real players in the world">players <b id="sOnline">&ndash;</b></span>
<span class="pill p-gray" title="random bots in the world">random bots <b id="sBots">&ndash;</b></span>
<span class="pill p-orange" title="characters that logged out in the last 24 hours">seen today <b id="sSeen">&ndash;</b></span>
<span class="pill p-blue" title="characters, random bots not counted">characters <b id="sChars">&ndash;</b></span>
<span class="pill p-purple" title="game accounts, random bots not counted">accounts <b id="sAcc">&ndash;</b></span>
<span class="pill p-red" id="sQueueP" hidden title="the world server's login queue">queued <b id="sQueue">0</b></span>
<span id="sAge"></span></header>
<main><div class="col">
<section><h2>In the world now<span class="sub" id="rosterCount"></span></h2>
<div class="filters">__I_search__<input id="fText" class="grow" placeholder="Name, zone, guild, account, Discord" maxlength="40">
<select id="fClass"><option value="">Any class</option></select>
<input id="fMin" type="number" min="1" max="60" placeholder="Lvl" style="width:62px" title="lowest level">
<span class="dim">&ndash;</span><input id="fMax" type="number" min="1" max="60" placeholder="Lvl" style="width:62px" title="highest level">
<label><input type="checkbox" id="fGM"> GMs</label><label><input type="checkbox" id="fIP"> Same IP</label>
<button class="small" id="ipToggle" title="show the full IPs">__I_eye__<span>Reveal IPs</span></button></div>
<div class="scroll" id="rosterWrap"><table><thead><tr>
<th data-k="name">Name</th><th data-k="level" class="num">Lvl</th><th data-k="class">Class</th><th data-k="race">Race</th>
<th data-k="zone">Zone</th><th data-k="health">HP</th><th data-k="gold" class="num">Gold</th><th data-k="played_h" class="num">Played h</th>
<th data-k="discord">Discord</th><th data-k="account">Account</th><th data-k="ip">IP</th>
</tr></thead><tbody id="players"></tbody></table></div><div id="none" class="muted" style="padding:8px 2px"></div></section>

<section><h2>Player actions</h2>
<div class="who"><div class="portrait" id="portrait" style="background:#2a3550">?</div>
<div style="min-width:0"><div id="selTitle">Pick a player above</div><div class="muted" id="selSub" style="font-size:12px;margin-top:3px"></div></div></div>
<div class="facts" id="facts"></div>
<div class="row"><input id="msg" class="grow" maxlength="200" placeholder="Message to them (shows on their screen)"><button class="blue" data-a="whisper">__I_send__Send</button></div>
<div class="row"><button data-a="appear">__I_go__Go to them</button><button data-a="summon">__I_bring__Bring them to me</button>
<select id="place" title="teleport location (game_tele)"></select><input id="placeAny" list="placeList" placeholder="or any location" style="width:130px" maxlength="48">
<datalist id="placeList"></datalist><button data-a="tele">__I_pin__Send them there</button>
<button data-a="revive">__I_revive__Revive</button><button data-a="pinfo">__I_info__Info</button></div>
<div class="row"><input id="mins" type="number" min="1" max="10080" value="10" style="width:76px"><span class="lbl">min</span>
<button data-a="mute">__I_mute__Mute</button><button data-a="unmute">__I_unmute__Unmute</button><button class="warn" data-a="kick">__I_kick__Kick</button>
<button class="warn" data-a="jail" title="GM Island and a mute for the minutes on the left">__I_jail__Jail</button></div>
<div class="row split"><button data-a="reset_talents">__I_talents__Reset talents</button><button data-a="repair">__I_repair__Repair gear</button>
<button data-a="inventory">__I_bag__Show inventory</button><button data-a="goxyz" title="copies .go xyz with their last saved position">__I_target__Copy their position</button>
<span class="right"></span><button class="warn" data-a="ban_account">__I_ban__Ban account</button><button class="warn" data-a="ban_ip">__I_ban__Ban IP</button></div>
</section>

<section><h2>Where everyone is<span class="sub"><label class="flex" style="gap:5px;cursor:pointer"><input type="checkbox" id="showCorpses"> corpses</label></span></h2>
<div id="mapWrap"><svg id="map" viewBox="0 0 1000 620" role="img" aria-label="Map of Kalimdor and the Eastern Kingdoms with player positions"></svg><div id="tip"></div></div>
<div id="elsewhere" class="muted" style="margin-top:7px;font-size:12px"></div></section>
</div>

<div class="col">
<section><h2>Everyone</h2>
<div class="row"><input id="all" class="grow" maxlength="200" placeholder="Text for everyone"><button class="blue" data-a="announce">__I_chat__In chat</button>
<button class="warn" data-a="notify" title="big text in the middle of every screen">__I_screen__On screen</button></div>
<div class="row"><input id="rmins" type="number" min="1" max="30" value="5" style="width:60px"><span class="lbl">min</span>
<input id="rwhy" class="grow" maxlength="60" placeholder="why (players see it)"><button data-a="restart">__I_clock__Restart with countdown</button>
<button class="red" data-a="cancel">__I_stop__Call it off</button></div>
<div class="row"><input id="cmd" class="grow" maxlength="250" placeholder=".any GM command" list="cmdList" spellcheck="false" autocomplete="off">
<datalist id="cmdList"></datalist><button class="blue" data-a="cmd">__I_run__Run</button></div>
<div class="row"><select id="maint" title="maintenance"></select><button data-a="maint">__I_gear__Do it</button>
<select id="event" style="max-width:190px" title="game_event"></select><button data-a="event_start">__I_flag__Start</button><button data-a="event_stop">Stop</button>
<button data-a="audit" class="right">__I_coin__Gold audit</button></div>
<div id="out"><span class="t">Answers from the world server show here.</span></div></section>

<section><h2>Server status</h2><div id="server" class="srv"></div><div id="containers"></div><div id="errors" class="err"></div></section>
<section><h2>Herald, last 24 h</h2><div id="herald" class="srv"></div></section>
<section><h2>World chat<span class="sub" id="chatFlags"></span></h2><div id="chat" class="chat scroll" style="max-height:290px"></div></section>
<section><h2>Bug reports<span class="sub"><select id="bugFilter" class="small" style="padding:2px 6px"><option value="">All</option></select></span></h2>
<div id="bugs" class="scroll" style="max-height:330px"></div></section>
</div></main>

<dialog id="dlg"><h3 id="dlgTitle"></h3><div id="dlgBody"></div><div class="row" style="justify-content:flex-end;margin-top:12px">
<button id="dlgCancel">Close</button><button id="dlgOk" class="red" hidden>OK</button></div></dialog>
<script>
"use strict";
const T = new URLSearchParams(location.search).get("t") || "";
const NS = "http://www.w3.org/2000/svg";
const ICON = __ICONS__;
let data = null, meta = null, sel = null, sortK = "name", sortUp = true, revealIP = false, openBug = null;
const drafts = {}, outLog = [];
const $ = id => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const sv = (tag, attrs, text) => { const e = document.createElementNS(NS, tag); for (const k in attrs || {}) e.setAttribute(k, attrs[k]); if (text != null) e.textContent = text; return e; };
// our own constant SVG only (never player text)
const ico = (name, cls) => { const s = sv("svg", { viewBox: "0 0 16 16", fill: "none", stroke: "currentColor", "stroke-width": "1.5",
  "stroke-linecap": "round", "stroke-linejoin": "round", class: cls || "ic", "aria-hidden": "true" }); s.innerHTML = ICON[name]; return s; };
const CLS = { Warrior: "#C79C6E", Paladin: "#F58CBA", Hunter: "#ABD473", Rogue: "#FFF569", Priest: "#FFFFFF", Shaman: "#0070DE",
  Mage: "#69CCF0", Warlock: "#9482C9", Druid: "#FF7D0A" };
const CLS_ICON = {
  Warrior: '<path d="M13.5 2.5L6 10M13.5 2.5H10.5M13.5 2.5v3M4.2 8.2l3.6 3.6M2.5 13.5L5.5 10.5"/>',
  Paladin: '<path d="M2.5 13.5L9 7M8.2 2.2l5.6 5.6M10.2 1.8l4 4-2.2 2.2-4-4z"/>',
  Hunter: '<path d="M3 13C3 7.5 7.5 3 13 3"/><path d="M3 13L13 3M10 3h3v3"/>',
  Rogue: '<path d="M12.5 3.5L5 11M10.5 2.5l3 3M3.3 9.3l3.4 3.4M2.5 13.5L4 12"/>',
  Priest: '<ellipse cx="8" cy="4.6" rx="2.3" ry="2.6"/><path d="M8 7.3v7.2M4.4 9h7.2"/>',
  Shaman: '<path d="M9.3 1.5L4 9h3.6l-1.1 5.5L12 7H8.4z"/>',
  Mage: '<path d="M8 1.5l1.6 4.9 4.9 1.6-4.9 1.6L8 14.5l-1.6-4.9L1.5 8l4.9-1.6z"/>',
  Warlock: '<path d="M8 14.5c-2.9 0-4.5-2.1-4.5-4.4 0-3 3-4.6 3-8.1 2 1.5 2.5 3 2.3 4.5 1-.5 1.7-1.5 1.8-2.5 1.6 1.6 2.9 3.6 2.9 6 0 2.4-2 4.5-5.5 4.5z"/>',
  Druid: '<path d="M3 13C3 6.5 7 3 13 3c0 6.2-3.4 10-10 10z"/><path d="M3 13l6-6"/>' };
const RACE_AB = { "Human": "Hu", "Orc": "Or", "Dwarf": "Dw", "Night Elf": "NE", "Undead": "Ud", "Tauren": "Ta", "Gnome": "Gn", "Troll": "Tr" };
function clsIcon(c) { const s = sv("svg", { viewBox: "0 0 16 16", fill: "none", stroke: CLS[c] || "#aaa", "stroke-width": "1.6",
  "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true" }); s.innerHTML = CLS_ICON[c] || '<circle cx="8" cy="8" r="5"/>'; return s; }
function emblem(p) {
  const horde = p.faction === "Horde", s = sv("svg", { viewBox: "0 0 16 18", class: "emb", "aria-label": p.faction + " " + p.race });
  s.append(sv("path", { d: horde ? "M8 1l2 2.2L14.5 2 13.4 6.5 15 9l-2.2 1.4L12 15l-4 2-4-2-.8-4.6L1 9l1.6-2.5L1.5 2 6 3.2z"
    : "M8 1l6.5 2.2v5.2c0 4-2.8 6.9-6.5 8.4-3.7-1.5-6.5-4.4-6.5-8.4V3.2z",
    fill: horde ? "#8c1f1f" : "#1d4d9e", stroke: horde ? "#e2574e" : "#6fa3ff", "stroke-width": "1" }));
  s.append(sv("text", { x: 8, y: horde ? 11.6 : 11.4, "text-anchor": "middle", "font-size": "6.6", "font-weight": "700",
    fill: horde ? "#ffd7c2" : "#e4eeff", "font-family": "system-ui,sans-serif" }, RACE_AB[p.race] || "?"));
  return s;
}
function maskIP(ip) { if (!ip) return ""; if (revealIP) return ip; const p = ip.split("."); return p.length === 4 ? p[0] + "." + p[1] + ".x.x" : ip.replace(/[0-9a-f]+(:[0-9a-f]*){0,3}$/i, "x:x"); }
function hpBar(v, max, mana) {
  const w = el("span", "hp"), b = el("span", "bar"), i = el("i"); const pct = max > 0 ? Math.max(0, Math.min(1, v / max)) : (v > 0 ? 1 : 0);
  i.style.width = (pct * 100).toFixed(0) + "%"; if (mana) i.className = "mana"; else if (pct < .2) i.className = "vlo"; else if (pct < .45) i.className = "lo";
  b.append(i); w.append(b, el("span", null, v == null ? "" : String(v))); return w;
}
function out(text, ok, cmd) {
  outLog.push({ text, ok, cmd, at: new Date().toLocaleTimeString() }); while (outLog.length > 60) outLog.shift();
  const o = $("out"); o.replaceChildren();
  for (const e of outLog) { const d = el("div"); d.append(el("span", "t", e.at + " ")); if (e.cmd) d.append(el("span", "c", e.cmd + "\n"));
    d.append(el("span", e.ok ? "ok" : "e", e.text)); o.append(d); }
  o.scrollTop = o.scrollHeight;
}
async function api(path, body) {
  const r = await fetch(path + (path.includes("?") ? "&" : "?") + "t=" + encodeURIComponent(T), body ? { method: "POST",
    headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {});
  if (!r.ok) throw new Error("HTTP " + r.status); return r.json();
}
async function refresh() {
  try { data = await api("/api/state"); draw(); }
  catch (e) { $("sAge").textContent = "not connected (" + e.message + ")"; }
}
async function loadMeta() {
  try { meta = await api("/api/meta"); } catch (e) { return; }
  const pl = $("place"), keep = pl.value; pl.replaceChildren();
  for (const p of (meta.quick.length ? meta.quick : meta.places.slice(0, 20))) pl.append(new Option(p.replace(/([a-z])([A-Z])/g, "$1 $2"), p));
  if (keep) pl.value = keep;
  $("placeList").replaceChildren(...meta.places.map(p => new Option(p)));
  $("maint").replaceChildren(...meta.maint.map(m => new Option(m[1] + "  (" + m[2] + ")", m[0])));
  const ev = $("event"); ev.replaceChildren(new Option(meta.events.length ? "Game event…" : "No events in game_event", ""));
  for (const [id, d] of meta.events) ev.append(new Option(id + "  " + d, id));
}
const CMDS = [".lookup item ", ".lookup creature ", ".lookup spell ", ".lookup quest ", ".lookup tele ", ".lookup object ", ".lookup area ",
  ".additem ", ".additemset ", ".tele ", ".tele name ", ".tele list", ".gobject near", ".gobject add ", ".gobject delete ", ".npc info",
  ".npc add ", ".npc delete", ".go xyz ", ".go creature ", ".go object ", ".appear ", ".summon ", ".revive ", ".kick ", ".mute ", ".unmute ",
  ".pinfo ", ".ban account ", ".ban character ", ".ban ip ", ".unban account ", ".unban character ", ".unban ip ", ".baninfo account ",
  ".banlist account", ".account set gmlevel ", ".account onlinelist", ".reset talents ", ".reset stats ", ".reset spells ", ".repairitems ",
  ".modify money ", ".levelup ", ".learn ", ".unlearn ", ".server info", ".server motd", ".saveall", ".reload config", ".reload game_tele",
  ".reload all", ".event list", ".event activelist", ".event start ", ".event stop ", ".announce ", ".notify ", ".send message ",
  ".send mail ", ".send money ", ".send items ", ".gm on", ".gm off", ".gm visible off", ".gps", ".whispers off", ".honor show"];
$("cmdList").replaceChildren(...CMDS.map(c => new Option(c)));
for (const c of Object.keys(CLS)) $("fClass").append(new Option(c, c));
for (const s of ["Open", "Investigating", "Resolved", "Duplicate"]) $("bugFilter").append(new Option(s, s));

function selPlayer() { return data && sel ? data.players.find(p => p.name === sel) || null : null; }
function choose(name) { sel = name; draw(); }
function filtered() {
  const q = $("fText").value.trim().toLowerCase(), c = $("fClass").value, lo = +$("fMin").value || 0, hi = +$("fMax").value || 99;
  return data.players.filter(p => (!q || [p.name, p.zone, p.guild, p.account, p.discord, p.race].some(v => (v || "").toLowerCase().includes(q)))
    && (!c || p.class === c) && p.level >= lo && p.level <= hi && (!$("fGM").checked || p.gm > 0) && (!$("fIP").checked || p.same_ip.length));
}
function draw() {
  if (!data) return;
  const t = data.totals || {};
  $("sOnline").textContent = t.online ?? "–"; $("sBots").textContent = t.bots ?? "–"; $("sSeen").textContent = t.seen_24h ?? "–";
  $("sChars").textContent = t.characters ?? "–"; $("sAcc").textContent = t.accounts ?? "–";
  $("sQueueP").hidden = !t.queued; $("sQueue").textContent = t.queued || 0;
  $("sAge").textContent = data.at ? "updated " + new Date(data.at * 1000).toLocaleTimeString() : "waiting for the first read…";
  drawRoster(); drawSelected(); drawMap(); drawServer(); drawChat(); drawBugs(); drawHerald();
}
function drawRoster() {
  const ps = filtered().sort((a, b) => { let x = a[sortK], y = b[sortK]; if (typeof x === "string") { x = x.toLowerCase(); y = (y || "").toLowerCase(); }
    return (x > y ? 1 : x < y ? -1 : 0) * (sortUp ? 1 : -1); });
  document.querySelectorAll("th[data-k]").forEach(th => th.classList.toggle("on", th.dataset.k === sortK));
  const tb = $("players"); tb.replaceChildren();
  for (const p of ps) {
    const tr = el("tr", p.name === sel ? "sel" : "");
    const n = el("td"), nm = el("span", "nm"); nm.append(emblem(p), el("span", null, p.name));
    if (p.gm) nm.append(el("span", "tag t-gm", "GM" + p.gm)); if (p.muted_s) nm.append(el("span", "tag t-mute", "muted"));
    if (p.state !== "alive") nm.append(el("span", "tag t-dead", p.state)); if (p.same_ip.length) nm.append(el("span", "tag t-ip", "same IP"));
    n.append(nm); if (p.guild) n.title = "<" + p.guild + ">";
    const cl = el("td"), ci = el("span", "cls"); ci.style.color = CLS[p.class] || "#ccc"; ci.append(clsIcon(p.class), el("span", null, p.class)); cl.append(ci);
    const hp = el("td"); hp.append(hpBar(p.health, p.health_max)); hp.title = "health at the last save; the bar compares it to the highest seen this session";
    const ip = el("td", "ipc", maskIP(p.ip)); if (p.same_ip.length) ip.title = "also on this IP: " + p.same_ip.join(", ");
    tr.append(n, el("td", "num", p.level), cl, el("td", null, p.race), el("td", null, p.zone), hp, el("td", "num gold", p.gold.toFixed(2)),
      el("td", "num", p.played_h), el("td", "muted", p.discord), el("td", "muted", p.account), ip);
    tr.onclick = () => choose(p.name); tb.append(tr);
  }
  $("rosterCount").textContent = ps.length === data.players.length ? data.players.length + " online" : ps.length + " of " + data.players.length + " shown";
  $("none").textContent = data.players.length ? (ps.length ? "" : "Nobody matches the filter.") : "Nobody is in the world right now.";
}
function fact(k, v, node, wide) { const d = el("div", wide ? "w2" : null); d.append(el("b", null, k)); if (node) d.append(node); else d.append(el("span", null, v)); return d; }
function drawSelected() {
  const p = selPlayer(), f = $("facts"), po = $("portrait");
  if (!p) {
    $("selTitle").textContent = sel ? sel.toUpperCase() + " • NOT IN THE WORLD" : "Pick a player above"; $("selSub").textContent = sel ? "They logged out; actions by name still work." : "";
    po.textContent = sel ? sel[0] : "?"; po.style.background = "#2a3550"; f.replaceChildren(); return;
  }
  $("selTitle").textContent = `${p.name} • Level ${p.level} ${p.race} ${p.class} • ${p.zone}`;
  $("selSub").textContent = (p.guild ? "<" + p.guild + ">  " : "") + p.faction + (p.discord ? "  ·  Discord " + p.discord : "") + "  ·  account " + p.account;
  const c = CLS[p.class] || "#8899aa"; po.style.background = `linear-gradient(145deg, ${c}, ${c}99)`; po.replaceChildren(document.createTextNode(p.class[0] || "?"), el("small", null, p.level));
  const ipSpan = el("span", "ipc", maskIP(p.ip) || "unknown");
  const items = [fact("Health", null, hpBar(p.health, p.health_max))];
  if (p.mana != null && p.mana_max > 0) items.push(fact("Mana", null, hpBar(p.mana, p.mana_max, true)));
  items.push(fact("State", p.state === "alive" ? "Alive" : p.state === "dead" ? "Dead" : "Ghost (released)"),
    fact("Position", `map ${p.map} · ${p.x.toFixed(0)}, ${p.y.toFixed(0)}, ${p.z.toFixed(0)}`, null, true), fact("Gold", p.gold.toFixed(2)),
    fact("Played", p.played_h + " h"), fact("IP", null, ipSpan));
  if (p.same_ip.length) items.push(fact("Same IP", p.same_ip.join(", ")));
  if (p.hks != null) items.push(fact("Honor", p.hks + " HKs" + (p.rank ? " · rank " + p.rank : "")));
  if (p.bag_free != null) items.push(fact("Bag space", p.bag_free + " free"));
  if (p.gm) items.push(fact("GM level", String(p.gm))); if (p.muted_s) items.push(fact("Muted", Math.ceil(p.muted_s / 60) + " min left"));
  f.replaceChildren(...items);
}
// ---- the parchment map: our own drawing (rough outlines from world coordinates), no game art -------
const S = 0.029;
const MAPS = {
  1: { name: "Kalimdor", box: [11200, 3800], o: [56, 14],
    land: [[[7600,300],[8100,-800],[8300,-2600],[8000,-3900],[7400,-5300],[6400,-6000],[5200,-6900],[4100,-7200],[3200,-6800],[2700,-5800],
      [2000,-5150],[1200,-5150],[200,-5250],[-700,-4600],[-1100,-4000],[-1900,-3900],[-2700,-4300],[-3400,-4950],[-4300,-4850],[-5000,-4200],
      [-5800,-4400],[-6600,-5000],[-7700,-5300],[-8700,-4400],[-9000,-3000],[-8500,-1800],[-8400,-500],[-8300,900],[-7700,1900],[-6400,2500],
      [-5300,3000],[-4100,2800],[-3000,2600],[-1800,3000],[-500,3100],[600,2600],[1500,2200],[2500,2100],[3500,1300],[4600,1200],[5600,1000],
      [6600,850],[7200,700]],
      [[10900,1500],[10700,2600],[10000,2950],[9200,2550],[8900,1500],[9200,500],[9900,300],[10600,700]],
      [[-4100,3150],[-4300,3500],[-4700,3450],[-4650,3150]]],
    cities: [["Darnassus",9950,2300,1],["Orgrimmar",1600,-4400,1],["Thunder Bluff",-1200,30,1],["Gadgetzan",-7150,-3780,0],
      ["Theramore",-3750,-4440,0],["Ratchet",-950,-3770,0],["Auberdine",6400,470,0],["Everlook",6720,-4660,0]] },
  0: { name: "Eastern Kingdoms", box: [3600, 2600], o: [640, 40],
    land: [[[3000,1200],[3300,0],[3400,-1500],[3300,-3300],[2900,-5000],[2000,-5700],[900,-5600],[-200,-5000],[-1000,-4600],[-1800,-4400],
      [-2800,-4400],[-4000,-4100],[-5500,-3900],[-7000,-3700],[-8500,-3800],[-9700,-4300],[-10800,-4200],[-11900,-3800],[-12600,-3000],
      [-12800,-2200],[-13400,-1300],[-14300,-700],[-14800,200],[-14300,900],[-13200,700],[-12100,600],[-11300,1100],[-11000,2000],[-10300,2200],
      [-9500,1800],[-8500,1500],[-7400,1100],[-6300,1300],[-5300,700],[-4400,0],[-3700,-700],[-3000,-1500],[-2400,-2300],[-1800,-1500],
      [-1200,-700],[-700,200],[-200,1100],[300,1900],[1100,2400],[1900,2100],[2500,1700]]],
    cities: [["Stormwind",-8913,554,1],["Ironforge",-4918,-955,1],["Undercity",1586,240,1],["Booty Bay",-14297,518,0],
      ["Southshore",-840,-540,0],["Light's Hope",2280,-5300,0]] } };
function proj(m, x, y) { const M = MAPS[m]; return [M.o[0] + (M.box[1] - y) * S, M.o[1] + (M.box[0] - x) * S]; }
function smooth(pts) {   // closed Catmull-Rom through the points, for a hand-drawn line
  const n = pts.length; let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
  for (let i = 0; i < n; i++) { const p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
    d += `C${(p1[0] + (p2[0] - p0[0]) / 6).toFixed(1)},${(p1[1] + (p2[1] - p0[1]) / 6).toFixed(1)} ${(p2[0] - (p3[0] - p1[0]) / 6).toFixed(1)},${(p2[1] - (p3[1] - p1[1]) / 6).toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`; }
  return d + "Z";
}
let mapBase = null;
function mapDefs() {
  return `<defs>
<linearGradient id="sea" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="#557a78"/><stop offset=".55" stop-color="#3e6262"/><stop offset="1" stop-color="#2c4848"/></linearGradient>
<radialGradient id="land" cx=".45" cy=".4" r=".75"><stop offset="0" stop-color="#e6d3a3"/><stop offset=".6" stop-color="#d2b67f"/><stop offset="1" stop-color="#b48f58"/></radialGradient>
<radialGradient id="vig" cx=".5" cy=".5" r=".72"><stop offset=".6" stop-color="#1b1208" stop-opacity="0"/><stop offset="1" stop-color="#1b1208" stop-opacity=".62"/></radialGradient>
<filter id="rough" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency=".045" numOctaves="3" seed="4" result="n"/>
<feDisplacementMap in="SourceGraphic" in2="n" scale="11" xChannelSelector="R" yChannelSelector="G"/></filter>
<filter id="paint" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency=".045" numOctaves="3" seed="4" result="n"/>
<feDisplacementMap in="SourceGraphic" in2="n" scale="11" xChannelSelector="R" yChannelSelector="G" result="d"/>
<feTurbulence type="fractalNoise" baseFrequency=".011" numOctaves="3" seed="9" result="blot"/>
<feColorMatrix in="blot" type="matrix" values="0 0 0 0 .42 0 0 0 0 .3 0 0 0 0 .14 0 0 0 1.5 -.62" result="bc"/><feComposite in="bc" in2="d" operator="in" result="bin"/>
<feTurbulence type="fractalNoise" baseFrequency=".85" numOctaves="2" seed="2" result="g"/>
<feColorMatrix in="g" type="matrix" values="0 0 0 0 .3 0 0 0 0 .2 0 0 0 0 .09 0 0 0 .7 -.18" result="gc"/><feComposite in="gc" in2="d" operator="in" result="gin"/>
<feMerge><feMergeNode in="d"/><feMergeNode in="bin"/><feMergeNode in="gin"/></feMerge></filter>
<filter id="seaTex" x="0" y="0" width="100%" height="100%"><feTurbulence type="turbulence" baseFrequency=".008 .05" numOctaves="2" seed="5" result="w"/>
<feColorMatrix in="w" type="matrix" values="0 0 0 0 .78 0 0 0 0 .86 0 0 0 0 .8 0 0 0 .32 -.06" result="wc"/><feComposite in="wc" in2="SourceGraphic" operator="in" result="wi"/>
<feTurbulence type="fractalNoise" baseFrequency=".7" numOctaves="2" seed="8" result="g"/>
<feColorMatrix in="g" type="matrix" values="0 0 0 0 .1 0 0 0 0 .16 0 0 0 0 .15 0 0 0 .5 -.12" result="gc"/>
<feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="wi"/><feMergeNode in="gc"/></feMerge></filter>
<filter id="shadow" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="5"/></filter>
<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="2.4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>`;
}
function buildMap() {
  const svg = $("map"); svg.innerHTML = mapDefs();
  svg.append(sv("rect", { x: 0, y: 0, width: 1000, height: 620, fill: "url(#sea)", filter: "url(#seaTex)" }));
  const g = sv("g");
  for (const m of [1, 0]) {
    const paths = MAPS[m].land.map(poly => smooth(poly.map(([x, y]) => proj(m, x, y))));
    for (const d of paths) g.append(sv("path", { d, fill: "none", stroke: "#c8d8cf", "stroke-opacity": ".22", "stroke-width": "16", filter: "url(#rough)" }));
    for (const d of paths) g.append(sv("path", { d, fill: "none", stroke: "#dfe9e2", "stroke-opacity": ".25", "stroke-width": "5", filter: "url(#rough)" }));
    for (const d of paths) g.append(sv("path", { d, fill: "#1c1309", opacity: ".45", transform: "translate(3 5)", filter: "url(#shadow)" }));
    for (const d of paths) g.append(sv("path", { d, fill: "url(#land)", stroke: "#5d3f1d", "stroke-width": "2.2", filter: "url(#paint)" }));
  }
  svg.append(g);
  const lab = (x, y, t, size, rot) => { const e = sv("text", { x, y, "text-anchor": "middle", "font-family": "Georgia,'Palatino Linotype',serif",
    "font-size": size, "font-style": "italic", "letter-spacing": "3", fill: "#3a2810", "fill-opacity": ".78", transform: rot ? `rotate(${rot} ${x} ${y})` : "" }, t);
    return e; };
  svg.append(lab(192, 468, "KALIMDOR", 24, -4), lab(772, 130, "EASTERN", 15, 0), lab(772, 149, "KINGDOMS", 15, 0));
  svg.append(lab(500, 600, "The Great Sea", 15, 0));
  for (const m of [0, 1]) for (const [n, x, y, cap] of MAPS[m].cities) {
    const [a, b] = proj(m, x, y);
    svg.append(sv("rect", { x: a - (cap ? 3.5 : 2.5), y: b - (cap ? 3.5 : 2.5), width: cap ? 7 : 5, height: cap ? 7 : 5, fill: cap ? "#4b2f12" : "#6b4a24",
      stroke: "#f1e2bb", "stroke-width": ".8", transform: `rotate(45 ${a} ${b})` }));
    const t = sv("text", { x: a + 8, y: b + 4, "font-family": "Georgia,serif", "font-size": cap ? 12.5 : 10.5, "font-weight": cap ? "700" : "400",
      fill: "#2c1c0a", stroke: "#efe0b8", "stroke-width": "2.6", "paint-order": "stroke", "stroke-linejoin": "round" }, n);
    svg.append(t);
  }
  // compass and vignette
  const cmp = sv("g", { transform: "translate(500 72)", opacity: ".7" });
  cmp.append(sv("circle", { r: 22, fill: "none", stroke: "#e7d6ad", "stroke-width": "1" }), sv("path", { d: "M0-26L5 0 0 26-5 0z", fill: "#e7d6ad" }),
    sv("path", { d: "M-26 0L0 4 26 0 0-4z", fill: "#cbb78a" }), sv("text", { y: -30, "text-anchor": "middle", "font-family": "Georgia,serif", "font-size": 11, fill: "#efe2c0" }, "N"));
  svg.append(cmp, sv("rect", { x: 0, y: 0, width: 1000, height: 620, fill: "url(#vig)", "pointer-events": "none" }));
  mapBase = sv("g", { id: "pins" }); svg.append(mapBase);
}
function tip(e, lines) {
  const t = $("tip"), r = $("mapWrap").getBoundingClientRect(); t.replaceChildren(...lines.map((l, i) => { const d = el("div", i ? "muted" : null, l); if (!i) d.style.fontWeight = "600"; return d; }));
  t.style.display = "block"; let x = e.clientX - r.left + 14, y = e.clientY - r.top + 12; if (x + t.offsetWidth > r.width) x -= t.offsetWidth + 28;
  t.style.left = x + "px"; t.style.top = y + "px";
}
function drawMap() {
  if (!mapBase) buildMap();
  mapBase.replaceChildren();
  if ($("showCorpses").checked) for (const c of data.corpses || []) {
    const [a, b] = proj(c.map, c.x, c.y), g = sv("g", { class: "pinp", transform: `translate(${a} ${b})` });
    g.append(sv("path", { d: "M-3.5-3.5L3.5 3.5M3.5-3.5L-3.5 3.5", stroke: "#2a1a0b", "stroke-width": "2.6" }), sv("path", { d: "M-3.5-3.5L3.5 3.5M3.5-3.5L-3.5 3.5", stroke: "#e8e0cc", "stroke-width": "1.3" }));
    g.onmousemove = e => tip(e, ["Corpse" + (c.name ? " of " + c.name : ""), c.when ? "since " + c.when : ""]); g.onmouseleave = () => $("tip").style.display = "none";
    mapBase.append(g);
  }
  const shown = new Set(filtered().map(p => p.name));
  const ps = data.players.filter(p => p.map === 0 || p.map === 1).sort((a, b) => (a.name === sel) - (b.name === sel));
  for (const p of ps) {
    const [a, b] = proj(p.map, p.x, p.y), me = p.name === sel, g = sv("g", { class: "pinp", transform: `translate(${a.toFixed(1)} ${b.toFixed(1)})`, opacity: shown.has(p.name) ? 1 : .35 });
    const col = me ? "#f2c14e" : p.faction === "Horde" ? "#d23c3c" : "#3f7fe0";
    if (me) g.append(sv("circle", { r: 13, fill: "none", stroke: "#f2c14e", "stroke-width": "1.5", opacity: ".7" }));
    g.append(sv("path", { d: me ? "M0 2L-7-9a8.2 8.2 0 1 1 14 0z" : "M0 1L-5-7a5.8 5.8 0 1 1 10 0z", transform: me ? "translate(0 1)" : "", fill: col,
      stroke: me ? "#3a2606" : "#fff", "stroke-width": me ? "1.6" : "1.2", filter: me ? "url(#glow)" : "", class: "pc" }));
    g.append(sv("circle", { cx: 0, cy: me ? -11 : -8, r: me ? 3 : 2, fill: me ? "#3a2606" : "#fff" }));
    if (me) g.append(sv("text", { x: 12, y: -10, "font-family": "Georgia,serif", "font-size": "13", "font-weight": "700", fill: "#2a1904", stroke: "#f6e7bf",
      "stroke-width": "3", "paint-order": "stroke" }, p.name));
    g.onmousemove = e => tip(e, [p.name + " · " + p.level + " " + p.race + " " + p.class, p.zone + (p.guild ? "  <" + p.guild + ">" : ""), p.state === "alive" ? "" : p.state]);
    g.onmouseleave = () => $("tip").style.display = "none"; g.onclick = () => choose(p.name);
    mapBase.append(g);
  }
  const other = data.players.filter(p => p.map > 1);
  $("elsewhere").textContent = other.length ? "In dungeons and battlegrounds: " + other.map(p => p.name + " (" + p.zone + ")").join(", ") : "";
}
function spark(h) {
  const s = sv("svg", { viewBox: "0 0 92 24", class: "spark", preserveAspectRatio: "none" }); const n = h.length; if (!n) return s;
  const mx = Math.max(10, ...h); const pts = h.map((v, i) => [(n === 1 ? 92 : i * 92 / (n - 1)), 22 - (v / mx) * 20]);
  const line = pts.map(p => p[0].toFixed(1) + "," + p[1].toFixed(1)).join(" ");
  s.append(sv("polygon", { points: "0,24 " + line + " 92,24", fill: "rgba(76,141,255,.16)" }), sv("polyline", { points: line, fill: "none", stroke: "#6aa5ff", "stroke-width": "1.3" }));
  return s;
}
function drawServer() {
  $("server").textContent = data.server || "";
  $("containers").replaceChildren(...(data.containers || []).map(c => { const r = el("div", "ct"); const v = el("div", "v");
    v.append(document.createTextNode("CPU " + c.cpu.toFixed(1) + "%  ·  " + c.mem), el("br"), el("small", null, (c.net ? "net " + c.net : "") + (c.mem_pct ? "  ·  mem " + c.mem_pct + "%" : "")));
    r.append(el("div", "n", c.name), v, spark(c.hist || []), el("div", "badge b-" + c.status, c.status)); r.title = c.name + ": CPU history, last " + (c.hist || []).length + " samples"; return r; }));
  $("errors").textContent = (data.errors || []).join(" · ");
}
function drawChat() {
  const online = new Set(data.players.map(p => p.name)); let nf = 0;
  $("chat").replaceChildren(...data.chat.map(c => { const d = el("div", c.flags.length ? "flag" : null); const n = el("span", "n", c.name);
    n.onclick = () => { if (online.has(c.name)) choose(c.name); else { $("fText").value = c.name; sel = c.name; draw(); } };
    n.title = online.has(c.name) ? "select " + c.name : c.name + " isn't in the world now";
    d.append(el("span", "t", c.when), n, el("span", null, ": " + c.text)); for (const f of c.flags) { d.append(el("span", "why", f)); nf++; } return d; }));
  $("chatFlags").textContent = nf ? nf + " line(s) flagged" : "";
}
function drawHerald() {
  const h = data.herald || {}, box = $("herald");
  if (h.fights === undefined) { box.replaceChildren(el("div", "muted", "No fight log yet (world server patch 0020).")); return; }
  const rows = [
    el("div", null, `${h.fights} fights, ${h.deaths} deaths` + (h.fights ? ` (${(100 * h.deaths / h.fights).toFixed(1)} per 100)` : "")),
    el("div", "muted", `lowest health ${h.low}% on average, ${h.close} close calls under 20%, ${h.grouped} fights in a group`),
  ];
  if (h.classes && h.classes.length) rows.push(el("div", "muted", h.classes.map(c => `${c.class}: ${c.fights} fights, ${c.deaths} deaths`).join(" · ")));
  if (h.stuck !== undefined) rows.push(el("div", null, `${h.stuck} stuck steps`));
  for (const s of h.spots || []) {
    const d = el("div", "muted", `${s.zone}: ${s.n}× `);
    const b = el("button", "small", "copy .go"); b.onclick = () => { try { navigator.clipboard.writeText(s.go); } catch (e) {} };
    d.append(b); rows.push(d);
  }
  box.replaceChildren(...rows);
}

function drawBugs() {
  if ($("bugs").contains(document.activeElement)) return;   // don't redraw under the GM's typing
  const want = $("bugFilter").value, list = data.bugs.filter(b => !want || b.status === want);
  $("bugs").replaceChildren(...list.map(b => {
    const d = el("div", "bug" + (b.status === "Resolved" || b.status === "Duplicate" ? " done" : "")), top = el("div", "top");
    const txt = el("div"); txt.append(el("span", "bn", b.name + ": "), el("span", null, b.text), el("span", "st st-" + b.status, b.status));
    top.append(ico("bug"), txt); top.onclick = () => { openBug = openBug === b.id ? null : b.id; drawBugs(); };
    d.append(top, el("div", "meta", ["#" + b.id, b.when, b.category, b.zone, b.level ? "level " + b.level + (b.class ? " " + b.class : "") : ""].filter(Boolean).join("  ·  ")));
    if (openBug === b.id) {
      const ed = el("div", "edit"), st = el("select");
      for (const s of ["Open", "Investigating", "Resolved", "Duplicate"]) st.append(new Option(s, s));
      const dr = drafts[b.id] || { status: b.status, note: b.note }; st.value = dr.status;
      const note = el("textarea"); note.maxLength = 1000; note.placeholder = "GM notes (only GMs see these)"; note.value = dr.note;
      st.onchange = () => drafts[b.id] = { status: st.value, note: note.value }; note.oninput = st.onchange;
      if (b.context) ed.append(el("div", "dim", b.context));
      const save = el("button", "blue small"); save.append(ico("save"), document.createTextNode("Save"));
      save.onclick = async () => { const j = await api("/api/act", { act: "ticket", id: b.id, status: st.value, note: note.value }).catch(e => ({ ok: false, result: e.message }));
        out(j.result, j.ok); if (j.ok) { delete drafts[b.id]; b.status = st.value; b.note = note.value; save.blur(); drawBugs(); } };
      const row = el("div", "row"); row.append(st, save);
      if (b.go) { const go = el("button", "small"); go.append(ico("target"), document.createTextNode("Teleport to incident site")); go.title = b.go; go.onclick = () => copy(b.go); row.append(go); }
      ed.append(note, row); d.append(ed);
    }
    return d; }));
  if (!list.length) $("bugs").append(el("div", "muted", data.bugs.length ? "No reports with that status." : "No bug reports yet."));
}
async function copy(c) { try { await navigator.clipboard.writeText(c); out("Copied " + c + ": paste it in the game's chat (needs GM on).", true); }
  catch { out("Type in the game: " + c, true); } }
// ---- dialogs (confirm, ban, inventory, gold audit) ----
function dialog(title, body, okText, onOk) {
  $("dlgTitle").textContent = title; $("dlgBody").replaceChildren(...[].concat(body));
  const ok = $("dlgOk"); ok.hidden = !okText; ok.textContent = okText || ""; ok.onclick = async () => { if (await onOk() !== false) $("dlg").close(); };
  $("dlgCancel").onclick = () => $("dlg").close(); $("dlg").showModal();
}
function confirmBox(text, okText, fn) { dialog("Are you sure?", el("p", null, text), okText, fn); }
function banDialog(kind) {
  const p = selPlayer(), what = kind === "ban_ip" ? "the IP of " + sel + "'s account" : sel + "'s whole game account" + (p ? " (" + p.account + ")" : "");
  const dur = el("input"); dur.value = "7d"; dur.style.width = "90px"; dur.placeholder = "7d";
  const why = el("input"); why.className = "grow"; why.maxLength = 100; why.placeholder = "Reason (required, players see it)";
  const err = el("div", "err"), r1 = el("div", "row"), r2 = el("div", "row");
  r1.append(el("span", "lbl", "Length"), dur, el("span", "dim", "like 12h, 7d, 30d, or -1 for permanent")); r2.append(why);
  dialog(kind === "ban_ip" ? "Ban an IP" : "Ban an account", [el("p", null, "This bans " + what + "."), r1, r2, err], "Ban", async () => {
    if (why.value.trim().length < 3) { err.textContent = "Give a reason."; return false; }
    await send({ act: kind, name: sel, duration: dur.value.trim(), reason: why.value.trim() }); });
  setTimeout(() => why.focus(), 30);
}
async function showInventory() {
  const j = await api("/api/inventory?name=" + encodeURIComponent(sel)).catch(e => ({ ok: false, result: e.message }));
  if (!j.ok) return out(j.result, false);
  const groups = {}; for (const it of j.items) (groups[it.where] = groups[it.where] || []).push(it);
  const body = [el("p", "muted", j.items.length + " items, as of " + j.name + "'s last save. Read-only.")]; const sc = el("div", "scroll");
  for (const w of ["Equipped", "Bags", "Backpack", "Bank", "Keyring", "Buyback"]) { if (!groups[w]) continue;
    const t = el("table"), tb = el("tbody"); t.append(el("thead")); t.tHead.append(el("tr")); for (const h of [w, "Item", "Count", "Id"]) t.tHead.rows[0].append(el("th", null, h));
    for (const it of groups[w]) { const tr = el("tr"); tr.append(el("td", "muted", it.detail), el("td", "q" + Math.min(5, it.quality), it.name || "(unknown item)"), el("td", "num", it.count), el("td", "num dim", it.entry)); tb.append(tr); }
    t.append(tb); sc.append(t); }
  body.push(sc); dialog("Inventory of " + j.name, body);
}
async function showAudit() {
  const j = await api("/api/audit").catch(e => ({ ok: false, result: e.message })); if (!j.ok) return out(j.result, false);
  const sc = el("div", "scroll"), t = el("table"); t.innerHTML = "<thead><tr><th>Richest</th><th>Lvl</th><th>Class</th><th class=num>Gold</th><th>Account</th><th></th></tr></thead>";
  const tb = el("tbody"); for (const r of j.rich) { const tr = el("tr"); const c = el("td", null, r.class); c.style.color = CLS[r.class] || "";
    tr.append(el("td", null, r.name), el("td", "num", r.level), c, el("td", "num gold", r.gold.toFixed(2)), el("td", "muted", r.account), el("td", "okc", r.online ? "online" : "")); tb.append(tr); }
  t.append(tb); sc.append(t);
  if (j.mails === null) sc.append(el("p", "muted", "This database has no mail money columns, so gold mails can't be listed."));
  else { const m = el("table"); m.innerHTML = "<thead><tr><th>Gold mails (100g+)</th><th>From</th><th>To</th><th class=num>Gold</th></tr></thead>"; const mb = el("tbody");
    for (const r of j.mails) { const tr = el("tr"); tr.append(el("td", "muted", r.when), el("td", null, r.from || "?"), el("td", null, r.to || "?"), el("td", "num gold", r.gold.toFixed(2))); mb.append(tr); }
    m.append(mb); sc.append(el("div", null, ""), m); if (!j.mails.length) sc.append(el("p", "muted", "No mail of 100 gold or more is waiting in the database.")); }
  dialog("Gold audit", [el("p", "muted", "Real players only. Mail rows disappear once read and deleted, so this shows only what's still in mailboxes."), sc]);
}
async function send(body, label) {
  out("…", true, label);
  try { const j = await api("/api/act", body); outLog.pop(); out(j.result || (j.ok ? "Done." : "Refused."), j.ok, label); return j; }
  catch (e) { outLog.pop(); out("Not sent: " + e.message, false, label); }
}
document.querySelectorAll("th[data-k]").forEach(th => th.onclick = () => { const k = th.dataset.k; sortUp = sortK === k ? !sortUp : true; sortK = k; draw(); });
for (const id of ["fText", "fClass", "fMin", "fMax", "fGM", "fIP", "showCorpses", "bugFilter"]) $(id).addEventListener("input", () => data && draw());
$("ipToggle").onclick = () => { revealIP = !revealIP; $("ipToggle").lastChild.textContent = revealIP ? "Hide IPs" : "Reveal IPs"; draw(); };
$("cmd").addEventListener("keydown", e => { if (e.key === "Enter") document.querySelector('button[data-a="cmd"]').click(); });
$("msg").addEventListener("keydown", e => { if (e.key === "Enter") document.querySelector('button[data-a="whisper"]').click(); });
document.querySelectorAll("button[data-a]").forEach(b => b.onclick = async () => {
  const a = b.dataset.a;
  const needsSel = ["whisper", "appear", "summon", "tele", "revive", "pinfo", "mute", "unmute", "kick", "jail", "reset_talents", "repair",
    "inventory", "goxyz", "ban_account", "ban_ip"];
  if (needsSel.includes(a) && !sel) return out("Pick a player first.", false);
  if (a === "appear" || a === "summon") return copy("." + a + " " + sel);
  if (a === "goxyz") { const p = selPlayer(); return p ? copy(`.go xyz ${p.x} ${p.y} ${p.z} ${p.map}`) : out(sel + " isn't in the world.", false); }
  if (a === "inventory") return showInventory();
  if (a === "audit") return showAudit();
  if (a === "ban_account" || a === "ban_ip") return banDialog(a);
  const mins = $("mins").value, place = $("placeAny").value.trim() || $("place").value;
  const body = { act: a, name: sel, minutes: a === "restart" ? $("rmins").value : mins, place,
    text: a === "whisper" ? $("msg").value : a === "cmd" ? $("cmd").value : a === "restart" ? $("rwhy").value : $("all").value };
  const label = { whisper: "message to " + sel, tele: ".tele name " + sel + " " + place, cmd: $("cmd").value, announce: ".announce", notify: ".notify",
    maint: ($("maint").selectedOptions[0] || {}).text, event_start: ".event start " + $("event").value, event_stop: ".event stop " + $("event").value }[a] || "." + a + (sel && needsSel.includes(a) ? " " + sel : "");
  if (a === "maint") body.which = $("maint").value;
  if (a === "event_start" || a === "event_stop") { if (!$("event").value) return out("Pick an event.", false); body.event = $("event").value; }
  const go = async () => { const j = await send(body, label); if (j && j.ok && a === "whisper") $("msg").value = "";
    if (j && j.ok && a === "cmd") $("cmd").value = ""; if (j && j.ok && a === "tele") $("placeAny").value = ""; };
  if (a === "kick") return confirmBox("Kick " + sel + " out of the world?", "Kick", go);
  if (a === "jail") return confirmBox("Send " + sel + " to GM Island and mute them for " + mins + " minutes?", "Jail", go);
  if (a === "restart") return confirmBox("Start a " + $("rmins").value + "-minute restart countdown for everyone?", "Start countdown", go);
  if (a === "maint" || a === "event_start" || a === "event_stop") return confirmBox("Run " + label + " on the world server?", "Run", go);
  if (a === "notify" && $("all").value.trim()) return confirmBox("Show this in the middle of every player's screen?\n\n" + $("all").value, "Show it", go);
  go();
});
refresh(); loadMeta(); setInterval(refresh, 5000); setInterval(loadMeta, 300000);
</script></body></html>"""


def render_page():
    page = PAGE.replace("__ICONS__", json.dumps(ICONS))
    return re.sub(r"__I_(\w+)__", lambda m: icon(m.group(1)), page)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def authed(self):
        q = parse_qs(urlparse(self.path).query)
        return secrets.compare_digest((q.get("t") or [""])[0], TOKEN)

    def send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if not self.authed():
            return self.send(403, "Open this from Server.bat (option G): the link carries its key.", "text/plain")
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/":
            return self.send(200, render_page(), "text/html")
        if u.path == "/api/state":
            with LOCK:
                return self.send(200, json.dumps(STATE))
        if u.path == "/api/meta":
            return self.send(200, json.dumps(meta()))
        if u.path == "/api/inventory":
            return self.send(200, json.dumps(inventory((q.get("name") or [""])[0].strip())))
        if u.path == "/api/audit":
            return self.send(200, json.dumps(audit()))
        self.send(404, "{}")

    def do_POST(self):
        if not self.authed() or urlparse(self.path).path != "/api/act":
            return self.send(403, "{}")
        a = {}
        try:
            n = min(int(self.headers.get("Content-Length") or 0), 8192)
            a = json.loads(self.rfile.read(n) or b"{}")
            ok, result = act(a)
        except Exception as e:
            ok, result = False, f"{type(e).__name__}: {e}"
        print(time.strftime("%H:%M:%S"), "action", a.get("act") if isinstance(a, dict) else "?",
              (a.get("name") or "") if isinstance(a, dict) else "", "ok" if ok else "refused", flush=True)
        self.send(200, json.dumps({"ok": ok, "result": result}))


if __name__ == "__main__":
    threading.Thread(target=loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"Open Vanilla GM console on http://localhost:{PORT}/?t=<your key>  (this server only; Server.bat tunnels it). "
          "Ctrl+C stops it.", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
