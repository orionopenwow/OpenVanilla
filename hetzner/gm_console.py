#!/usr/bin/env python3
"""Open Vanilla GM console: the whole realm on one page, for the GM.

Run as root on the realm server. It listens on 127.0.0.1 only (never the internet): open it from your
PC with Server.bat option G, which starts it over SSH with a tunnel and opens your browser.

    OVGM_TOKEN=<random> python3 gm_console.py [port]      (default port 8090)

What it shows, refreshed every 5 seconds: every player in the world (character, level, class, race,
zone, gold, health, time played, game account, Discord name, GM level, muted), where they are on a
map of each continent, totals (players, random bots, characters, accounts), the world server's
uptime and the containers' CPU and memory, World chat as it happens, and the newest bug reports.

What it does, through the world server's console (the HELPDESK login in /etc/openvanilla-herald.env):
a message to one player, an announcement or on-screen notice to everyone, kick, mute and unmute,
revive, send a player to a city, the restart countdown (and calling it off), and any GM command.
"Go to them" copies .appear <name> for you to paste in game (the console has no character to move).

Player text is shown as text, never as page markup. Nothing here is reachable without the token.
"""
import base64, html, json, os, re, secrets, sqlite3, subprocess, sys, tempfile, threading, time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

REALM_DIR = os.environ.get("OW_REALM_DIR", "/opt/wenilla-realm")
HERALD_ENV = "/etc/openvanilla-herald.env"
GM_SH = os.environ.get("OVGM_SH", "/opt/openvanilla-classicplus/ov_gm.sh")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
TOKEN = os.environ.get("OVGM_TOKEN") or secrets.token_urlsafe(18)

RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
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
PLACES = ["Stormwind", "Ironforge", "Darnassus", "Orgrimmar", "Undercity", "ThunderBluff", "Goldshire", "Razorhill"]
NAME_RE = re.compile(r"^[^\W\d_]{2,12}$")


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


# ---- the realm's state, gathered in the background ------------------------------------------------
STATE = {"at": 0, "players": [], "totals": {}, "chat": [], "bugs": [], "server": "", "containers": [], "errors": []}
DISCORD = {}           # game account (WR000123) -> Discord name
LOCK = threading.Lock()


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


def gather():
    SQL_ERRORS.clear()
    errors = []
    rows = sql("SELECT c.name, c.level, c.race, c.class, c.gender, c.zone, c.map, ROUND(c.position_x), ROUND(c.position_y), "
               "c.money, c.totaltime, c.health, a.username, a.gmlevel, IF(a.mutetime > UNIX_TIMESTAMP(), a.mutetime - UNIX_TIMESTAMP(), 0), c.xp "
               "FROM characters c JOIN classicrealmd.account a ON a.id = c.account "
               "WHERE c.online = 1 AND a.username NOT LIKE 'RNDBOT%' ORDER BY c.name")
    players = []
    for r in rows:
        if len(r) < 16:
            continue
        name, lvl, race, cls, gender, zone, mp, x, y, money, played, hp, acc, gm, muted, xp = r[:16]
        players.append({"name": name, "level": int(lvl), "race": RACES.get(int(race), race), "class": CLASSES.get(int(cls), cls),
                        "zone": ZONES.get(int(zone), f"zone {zone}"), "map": int(mp), "x": float(x), "y": float(y),
                        "gold": round(int(money) / 10000, 2), "played_h": round(int(played) / 3600, 1), "health": int(hp),
                        "account": acc, "discord": DISCORD.get(acc.upper(), ""), "gm": int(gm), "muted_s": int(float(muted)),
                        "xp": int(xp)})
    t = sql("SELECT (SELECT COUNT(*) FROM characters c JOIN classicrealmd.account a ON a.id = c.account WHERE c.online = 1 "
            "AND a.username LIKE 'RNDBOT%'), (SELECT COUNT(*) FROM characters c JOIN classicrealmd.account a ON a.id = c.account "
            "WHERE a.username NOT LIKE 'RNDBOT%'), (SELECT COUNT(*) FROM classicrealmd.account WHERE username NOT LIKE 'RNDBOT%'), "
            "(SELECT COUNT(*) FROM characters c JOIN classicrealmd.account a ON a.id = c.account WHERE a.username NOT LIKE "
            "'RNDBOT%' AND c.logout_time > UNIX_TIMESTAMP() - 86400)")
    totals = {"online": len(players)}
    if t and len(t[0]) >= 4:
        totals.update(bots=int(t[0][0]), characters=int(t[0][1]), accounts=int(t[0][2]), seen_24h=int(t[0][3]))
    chat = [{"when": r[0], "name": r[1], "text": r[2]} for r in sql(
        "SELECT FROM_UNIXTIME(created, '%H:%i'), name, text FROM openvanilla_world_log WHERE guild = 0 ORDER BY id DESC LIMIT 60")
        if len(r) >= 3]
    bugs = [{"id": r[0], "when": r[1], "name": r[2], "category": r[3], "text": r[4], "zone": r[5]} for r in sql(
        "SELECT id, FROM_UNIXTIME(created, '%m-%d %H:%i'), name, category, text, zone FROM openvanilla_bug_report "
        "ORDER BY id DESC LIMIT 25") if len(r) >= 6]
    ok, info = console(".server info")
    if not ok:
        errors.append("World server console: " + info)
    try:
        ds = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"],
                            capture_output=True, text=True, timeout=20).stdout
        containers = [l.split("\t") for l in ds.splitlines() if l]
    except Exception:
        containers = []
    errors = sorted(set(SQL_ERRORS)) + errors
    with LOCK:
        STATE.update(at=int(time.time()), players=players, totals=totals, chat=chat, bugs=bugs,
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


# ---- actions -----------------------------------------------------------------------------------
RESTART = {"proc": None, "log": ""}


def clean_text(t, limit=200):
    t = re.sub(r"[\x00-\x1f\x7f|]", " ", str(t or "")).strip()
    return t[:limit]


def act(a):
    kind = a.get("act")
    name = str(a.get("name") or "").strip()
    if kind in ("whisper", "kick", "mute", "unmute", "revive", "tele", "pinfo") and not NAME_RE.match(name):
        return False, "That isn't a character name."
    text = clean_text(a.get("text"))
    if kind == "whisper":
        if not text: return False, "Type a message first."
        return console(f".send message {name} {text}")
    if kind == "kick":
        return console(f".kick {name}")
    if kind == "mute":
        mins = int(a.get("minutes") or 10)
        return console(f".mute {name} {max(1, min(mins, 10080))}")
    if kind == "unmute":
        return console(f".unmute {name}")
    if kind == "revive":
        return console(f".revive {name}")
    if kind == "pinfo":
        return console(f".pinfo {name}")
    if kind == "tele":
        place = str(a.get("place") or "")
        if place not in PLACES: return False, "Pick a city."
        return console(f".tele name {name} {place}")
    if kind in ("announce", "notify"):
        if not text: return False, "Type a message first."
        return console(f".{kind} {text}")
    if kind == "cmd":
        cmd = clean_text(a.get("text"), 250)
        if not cmd.startswith("."): return False, "A GM command starts with a dot."
        return console(cmd)
    if kind == "restart":
        if RESTART["proc"] and RESTART["proc"].poll() is None:
            return False, "A restart countdown is already running."
        mins = max(1, min(int(a.get("minutes") or 5), 30))
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
PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>GM Console</title><style>
:root{--bg:#0f1115;--panel:#171a21;--line:#262b36;--text:#e7e9ee;--muted:#8b93a7;--gold:#e6c35c;--red:#e5534b;--green:#57ab5a;--blue:#539bf5}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:13px/1.45 system-ui,Segoe UI,sans-serif}
header{display:flex;gap:16px;align-items:center;padding:10px 16px;border-bottom:1px solid var(--line);flex-wrap:wrap}
h1{font-size:15px;margin:0;color:var(--gold)}.stat{color:var(--muted)}.stat b{color:var(--text);font-size:15px}
main{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(320px,1fr);gap:12px;padding:12px 16px}
@media(max-width:1000px){main{grid-template-columns:1fr}}
section{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 12px;min-width:0}
h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 8px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:4px 6px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--muted);font-weight:500;cursor:pointer}tr.sel td{background:#22293a}tbody tr{cursor:pointer}tbody tr:hover td{background:#1d222c}
.scroll{overflow:auto;max-height:420px}.gm{color:var(--gold)}.mut{color:var(--red)}
button,select,input{background:#222733;color:var(--text);border:1px solid #333a48;border-radius:5px;padding:5px 9px;font:inherit}
button{cursor:pointer}button:hover{border-color:var(--blue)}button.danger:hover{border-color:var(--red)}
.row{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin:6px 0}input.wide{flex:1;min-width:160px}
#out{white-space:pre-wrap;color:var(--muted);font-family:ui-monospace,Consolas,monospace;font-size:12px;max-height:160px;overflow:auto}
.maps{display:grid;grid-template-columns:1fr 1fr;gap:8px}svg{width:100%;background:#12151b;border-radius:6px}
.chat div{padding:2px 0;border-bottom:1px solid #1d212a}.chat .t{color:var(--muted)}.chat .n{color:var(--blue)}
.err{color:var(--red)}.ok{color:var(--green)}.cards{display:flex;gap:6px;flex-wrap:wrap}.card{background:#1d222c;border-radius:6px;padding:4px 8px}
</style></head><body>
<header><h1>Open Vanilla · GM Console</h1>
<span class="stat">players <b id="sOnline">–</b></span><span class="stat">random bots <b id="sBots">–</b></span>
<span class="stat">seen today <b id="sSeen">–</b></span><span class="stat">characters <b id="sChars">–</b></span>
<span class="stat">accounts <b id="sAcc">–</b></span><span class="stat" id="sAge"></span></header>
<main><div>
<section><h2>In the world now</h2><div class="scroll"><table><thead><tr>
<th data-k="name">Name</th><th data-k="level">Lvl</th><th data-k="class">Class</th><th data-k="race">Race</th><th data-k="zone">Zone</th>
<th data-k="health">HP</th><th data-k="gold">Gold</th><th data-k="played_h">Played h</th><th data-k="discord">Discord</th><th data-k="account">Account</th>
</tr></thead><tbody id="players"></tbody></table></div><div id="none" class="stat"></div></section>
<section style="margin-top:12px"><h2 id="selTitle">Pick a player above</h2>
<div class="row"><input id="msg" class="wide" maxlength="200" placeholder="Message to them (shows on their screen)"><button data-a="whisper">Send</button></div>
<div class="row"><button data-a="appear">Go to them (copies .appear)</button><button data-a="summon">Bring them to me (copies .summon)</button>
<select id="place"></select><button data-a="tele">Send them there</button><button data-a="revive">Revive</button><button data-a="pinfo">Info</button></div>
<div class="row"><input id="mins" type="number" min="1" value="10" style="width:70px"> min <button data-a="mute">Mute</button><button data-a="unmute">Unmute</button><button class="danger" data-a="kick">Kick</button></div></section>
<section style="margin-top:12px"><h2>Where everyone is</h2><div class="maps"><div><div class="stat">Eastern Kingdoms</div><svg id="map0" viewBox="0 0 300 330"></svg></div>
<div><div class="stat">Kalimdor</div><svg id="map1" viewBox="0 0 300 330"></svg></div></div><div id="elsewhere" class="stat"></div></section>
</div><div>
<section><h2>Everyone</h2><div class="row"><input id="all" class="wide" maxlength="200" placeholder="Text for everyone"><button data-a="announce">In chat</button><button data-a="notify">On screen</button></div>
<div class="row"><input id="rmins" type="number" min="1" max="30" value="5" style="width:60px"> min <input id="rwhy" maxlength="60" placeholder="why (players see it)"><button class="danger" data-a="restart">Restart with countdown</button><button data-a="cancel">Call it off</button></div>
<div class="row"><input id="cmd" class="wide" maxlength="250" placeholder=".any GM command"><button data-a="cmd">Run</button></div><div id="out"></div></section>
<section style="margin-top:12px"><h2>Server</h2><div id="server" class="stat"></div><div id="containers" class="cards"></div><div id="errors" class="err"></div></section>
<section style="margin-top:12px"><h2>World chat</h2><div id="chat" class="chat scroll" style="max-height:300px"></div></section>
<section style="margin-top:12px"><h2>Bug reports</h2><div id="bugs" class="chat scroll" style="max-height:260px"></div></section>
</div></main>
<script>
const T = new URLSearchParams(location.search).get("t") || "";
let data = null, sel = null, sortK = "name", sortUp = true;
const $ = id => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
for (const p of __PLACES__) $("place").append(new Option(p, p));
function out(t, ok) { $("out").textContent = t; $("out").className = ok ? "ok" : "err"; }
async function refresh() {
  try { const r = await fetch("/api/state?t=" + encodeURIComponent(T)); if (!r.ok) throw new Error(r.status); data = await r.json(); draw(); }
  catch (e) { $("sAge").textContent = "not connected (" + e.message + ")"; }
}
function draw() {
  const t = data.totals || {};
  $("sOnline").textContent = t.online ?? "–"; $("sBots").textContent = t.bots ?? "–"; $("sSeen").textContent = t.seen_24h ?? "–";
  $("sChars").textContent = t.characters ?? "–"; $("sAcc").textContent = t.accounts ?? "–";
  $("sAge").textContent = "updated " + new Date(data.at * 1000).toLocaleTimeString();
  const ps = [...data.players].sort((a, b) => { const x = a[sortK], y = b[sortK]; return (x > y ? 1 : x < y ? -1 : 0) * (sortUp ? 1 : -1); });
  const tb = $("players"); tb.replaceChildren();
  for (const p of ps) {
    const tr = el("tr", p.name === sel ? "sel" : "");
    const cells = [p.name, p.level, p.class, p.race, p.zone, p.health, p.gold, p.played_h, p.discord, p.account];
    cells.forEach((c, i) => { const td = el("td", null, c); if (i === 0 && p.gm) td.className = "gm"; if (i === 0 && p.muted_s) td.className = "mut"; tr.append(td); });
    if (p.gm) tr.title = "GM level " + p.gm; if (p.muted_s) tr.title = "muted " + Math.ceil(p.muted_s / 60) + " min";
    tr.onclick = () => { sel = p.name; $("selTitle").textContent = p.name + " · level " + p.level + " " + p.race + " " + p.class + " · " + p.zone; draw(); };
    tb.append(tr);
  }
  $("none").textContent = ps.length ? "" : "Nobody is in the world right now.";
  drawMap(0, [-12000, 3600, -5200, 3700], [["Stormwind", -8900, 550], ["Ironforge", -4900, -950], ["Undercity", 1580, 240]]);
  drawMap(1, [-9000, 10400, -6400, 3600], [["Orgrimmar", 1600, -4400], ["Thunder Bluff", -1200, 30], ["Darnassus", 9950, 2300]]);
  const other = data.players.filter(p => p.map > 1);
  $("elsewhere").textContent = other.length ? "In dungeons and battlegrounds: " + other.map(p => p.name + " (" + p.zone + ")").join(", ") : "";
  $("server").textContent = data.server || "";
  $("containers").replaceChildren(...(data.containers || []).map(c => el("span", "card", c[0] + " · CPU " + c[1] + " · " + c[2])));
  $("errors").textContent = (data.errors || []).join(" · ");
  $("chat").replaceChildren(...data.chat.map(c => { const d = el("div"); d.append(el("span", "t", c.when + " "), el("span", "n", c.name + ": "), el("span", null, c.text)); return d; }));
  $("bugs").replaceChildren(...data.bugs.map(b => { const d = el("div"); d.append(el("span", "t", "#" + b.id + " " + b.when + " [" + b.category + "] "), el("span", "n", b.name + ": "), el("span", null, b.text)); return d; }));
}
function drawMap(m, [x0, x1, y0, y1], cities) {
  const svg = $("map" + m); svg.replaceChildren();
  const NS = "http://www.w3.org/2000/svg";
  const px = (x, y) => [((y1 - y) / (y1 - y0)) * 300, ((x1 - x) / (x1 - x0)) * 330];   // north up: x is north, y is west
  for (const [n, x, y] of cities) { const [a, b] = px(x, y); const t = document.createElementNS(NS, "text"); t.setAttribute("x", a + 4); t.setAttribute("y", b + 3);
    t.setAttribute("fill", "#5c6475"); t.setAttribute("font-size", "9"); t.textContent = n; const c = document.createElementNS(NS, "rect");
    c.setAttribute("x", a - 2); c.setAttribute("y", b - 2); c.setAttribute("width", 4); c.setAttribute("height", 4); c.setAttribute("fill", "#5c6475"); svg.append(c, t); }
  for (const p of data.players.filter(p => p.map === m)) {
    const [a, b] = px(p.x, p.y); const c = document.createElementNS(NS, "circle");
    c.setAttribute("cx", a); c.setAttribute("cy", b); c.setAttribute("r", p.name === sel ? 5 : 3.5);
    c.setAttribute("fill", p.name === sel ? "#e6c35c" : "#539bf5"); c.style.cursor = "pointer";
    const tt = document.createElementNS(NS, "title"); tt.textContent = p.name + " (" + p.level + ") · " + p.zone; c.append(tt);
    c.onclick = () => { sel = p.name; draw(); }; svg.append(c);
  }
}
document.querySelectorAll("th").forEach(th => th.onclick = () => { const k = th.dataset.k; sortUp = sortK === k ? !sortUp : true; sortK = k; draw(); });
document.querySelectorAll("button[data-a]").forEach(b => b.onclick = async () => {
  const a = b.dataset.a;
  const needsSel = ["whisper", "appear", "summon", "tele", "revive", "pinfo", "mute", "unmute", "kick"];
  if (needsSel.includes(a) && !sel) return out("Pick a player first.", false);
  if (a === "appear" || a === "summon") {
    const c = "." + a + " " + sel; try { await navigator.clipboard.writeText(c); out("Copied " + c + ": paste it in the game's chat (needs GM on).", true); }
    catch { out("Type in the game: " + c, true); } return;
  }
  if (a === "kick" && !confirm("Kick " + sel + "?")) return;
  if (a === "restart" && !confirm("Start a " + $("rmins").value + "-minute restart countdown for everyone?")) return;
  const body = { act: a, name: sel, minutes: a === "restart" ? $("rmins").value : $("mins").value, place: $("place").value,
    text: a === "whisper" ? $("msg").value : a === "cmd" ? $("cmd").value : a === "restart" ? $("rwhy").value : $("all").value };
  out("…", true);
  try { const r = await fetch("/api/act?t=" + encodeURIComponent(T), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const j = await r.json(); out(j.result || (j.ok ? "Done." : "Refused."), j.ok); if (j.ok && a === "whisper") $("msg").value = ""; }
  catch (e) { out("Not sent: " + e.message, false); }
});
refresh(); setInterval(refresh, 5000);
</script></body></html>"""


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
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if not self.authed():
            return self.send(403, "Open this from Server.bat (option G): the link carries its key.", "text/plain")
        path = urlparse(self.path).path
        if path == "/":
            return self.send(200, PAGE.replace("__PLACES__", json.dumps(PLACES)), "text/html")
        if path == "/api/state":
            with LOCK:
                return self.send(200, json.dumps(STATE))
        self.send(404, "{}")

    def do_POST(self):
        if not self.authed() or urlparse(self.path).path != "/api/act":
            return self.send(403, "{}")
        try:
            n = min(int(self.headers.get("Content-Length") or 0), 4096)
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
    print(f"GM console on http://localhost:{PORT}/?t=<your key>  (this server only; Server.bat tunnels it). Ctrl+C stops it.", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
