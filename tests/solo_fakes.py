"""Test doubles for Play Solo: fake processes, a Range-capable HTTP server, fake server programs and a
fake game client written as small Python scripts, and a stub server build / MariaDB / DB dumps for
tools/build_solo_pack.py. Nothing here is game data: every 'DBC' is synthetic."""
import hashlib
import http.server
import json
import os
import socket
import stat
import struct
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def write(path, data, mode=None):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    if mode:
        os.chmod(path, mode)
    return path


def script(path, body):
    """An executable Python script (it may be called WoW.exe: Linux doesn't care)."""
    return write(path, "#!" + sys.executable + "\n" + body.lstrip(), 0o755)


# ------------------------------------------------------------------ fake processes (orchestration tests)

class FakeProc:
    _next = 1000

    def __init__(self, argv, exits_after=None, ignore_terminate=False, on_start=None):
        FakeProc._next += 1
        self.pid = FakeProc._next
        self.argv = list(argv)
        self.returncode = None
        self.exits_after = exits_after       # polls until it exits by itself (None: never)
        self.ignore_terminate = ignore_terminate
        self.polls = 0
        self.terminated = self.killed = False
        if on_start:
            on_start(self)

    def poll(self):
        self.polls += 1
        if self.returncode is None and self.exits_after is not None and self.polls >= self.exits_after:
            self.returncode = 1
        return self.returncode

    def terminate(self):
        self.terminated = True
        if not self.ignore_terminate:
            self.returncode = 0

    def kill(self):
        self.killed = True
        self.returncode = -9

    def wait(self, timeout=None):
        return self.returncode


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


# ------------------------------------------------------------------ HTTP server with Range support

class FileServer:
    """Serves {path: bytes}. Options per test: ignore_range, drop_after (bytes sent before the
    connection is cut, first request only), fail_first (status of the first request)."""

    def __init__(self, files):
        self.files = dict(files)
        self.requests = []
        self.ignore_range = False
        self.drop_after = None
        self.fail_first = None
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                outer.requests.append((self.path, self.headers.get("Range")))
                if outer.fail_first:
                    code, outer.fail_first = outer.fail_first, None
                    self.send_response(code)
                    self.end_headers()
                    return
                data = outer.files.get(self.path.split("?")[0])
                if data is None:
                    self.send_response(404)
                    self.end_headers()
                    return
                start = 0
                rng = self.headers.get("Range")
                if rng and not outer.ignore_range:
                    start = int(rng.split("=")[1].split("-")[0])
                    if start >= len(data):
                        self.send_response(416)
                        self.send_header("Content-Range", f"bytes */{len(data)}")
                        self.end_headers()
                        return
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
                else:
                    self.send_response(200)
                body = data[start:]
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if outer.drop_after is not None:
                    cut, outer.drop_after = outer.drop_after, None
                    self.wfile.write(body[:cut])
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                self.wfile.write(body)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


# ------------------------------------------------------------------ fake server programs

FAKE_MANGOSD = r'''
import base64, http.server, json, os, re, socket, subprocess, sys, threading, time
args = sys.argv[1:]
opt = {args[i]: args[i + 1] for i in range(0, len(args) - 1, 2)}
conf = {}
for line in open(opt["-c"], encoding="utf-8"):
    m = re.match(r"^\s*([A-Za-z][\w.]*)\s*=\s*(.*?)\s*$", line)
    if m and m.group(1) not in conf:
        conf[m.group(1)] = m.group(2).strip('"')
logs = conf.get("LogsDir") or "."
report = {"argv": args, "conf": {k: conf.get(k) for k in ("DataDir", "BindIP", "WorldServerPort", "SOAP.Port",
          "SOAP.Enabled", "Console.Enable", "mmap.enabled", "Motd")}, "commands": []}
# The world server's own first step: log in to the world database with the credentials it was given.
host, port, user, pw, db = conf["WorldDatabaseInfo"].split(";")
r = subprocess.run(["mariadb", "--no-defaults", "--protocol=TCP", "-h", host, "-P", port, "-u", user, "-N", "-B", db,
                    "-e", "SELECT COUNT(*) FROM creature_template"], env=dict(os.environ, MYSQL_PWD=pw),
                   capture_output=True, text=True)
report["world_db"] = r.stdout.strip() if r.returncode == 0 else "ERROR " + r.stderr.strip()
if "-p" in opt:
    report["bots"] = [l.strip() for l in open(opt["-p"]) if l.startswith("AiPlayerbot.Enabled")]
def save():
    json.dump(report, open(os.path.join(logs, "fake_mangosd.json"), "w"), indent=1)
save()
with open(os.path.join(logs, "Server.log"), "a") as f:
    f.write("World initialized\n")
delay = float(os.environ.get("FAKE_WORLD_DELAY", "0.5"))
time.sleep(delay)
world = socket.socket(); world.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
world.bind((conf["BindIP"], int(conf["WorldServerPort"]))); world.listen(5)
threading.Thread(target=lambda: [world.accept()[0].close() for _ in iter(int, 1)], daemon=True).start()
class Soap(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        cmd = re.search(r"<command>(.*?)</command>", body).group(1)
        who = base64.b64decode(self.headers["Authorization"].split()[1]).decode().split(":")[0]
        report["commands"].append([who, cmd]); save()
        out = ('<?xml version="1.0"?><SOAP-ENV:Envelope><SOAP-ENV:Body><ns1:executeCommandResponse>'
               '<result>ok</result></ns1:executeCommandResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>').encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
        if cmd.startswith("server shutdown"):
            threading.Timer(0.3, lambda: os._exit(0)).start()
http.server.HTTPServer((conf["SOAP.IP"], int(conf["SOAP.Port"])), Soap).serve_forever()
'''

FAKE_REALMD = r'''
import re, socket, sys, time
conf = {}
for line in open(sys.argv[sys.argv.index("-c") + 1], encoding="utf-8"):
    m = re.match(r"^\s*([A-Za-z][\w.]*)\s*=\s*(.*?)\s*$", line)
    if m and m.group(1) not in conf:
        conf[m.group(1)] = m.group(2).strip('"')
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((conf["BindIP"], int(conf["RealmServerPort"]))); s.listen(5)
while True:
    c, _ = s.accept(); c.close()
'''

REAL_REALMD_WRAPPER = '''
import os, sys
os.execv({realmd!r}, [{realmd!r}] + sys.argv[1:])
'''

FAKE_AD = r'''
import os, sys, time
out = sys.argv[sys.argv.index("-o") + 1]
print("Read Map.dbc file... Done! (3 maps loaded)", flush=True)
os.makedirs(os.path.join(out, "dbc"), exist_ok=True); os.makedirs(os.path.join(out, "maps"), exist_ok=True)
for i, name in enumerate(["Azeroth", "Kalimdor", "Test"], 1):
    print(f"Extract {name} ({i}/3)                  ", flush=True)
    print("Processing........................50%\r", end="", flush=True)
    open(os.path.join(out, "maps", f"00{i}3232.map"), "wb").write(b"fake")
import shutil
for f in os.listdir(os.environ["FAKE_DBC_SRC"]):
    shutil.copy(os.path.join(os.environ["FAKE_DBC_SRC"], f), os.path.join(out, "dbc", f))
print("Extracted 2 DBC files")
'''

FAKE_VMAP_EXTRACTOR = r'''
import os, sys
out = sys.argv[sys.argv.index("-o") + 1]
os.makedirs(os.path.join(out, "Buildings"), exist_ok=True)
for m in (0, 1, 13):
    print(f"Processing Map {m}\n[####]", flush=True)
open(os.path.join(out, "Buildings", "dir_bin"), "wb").write(b"x")
'''

FAKE_VMAP_ASSEMBLER = r'''
import os, sys
src, dst = sys.argv[1], sys.argv[2]
assert os.path.isdir(src), src
os.makedirs(dst, exist_ok=True)
open(os.path.join(dst, "000.vmtree"), "wb").write(b"x")
print("Ok, all done")
'''

FAKE_MOVEMAPGEN = r'''
import os, sys
work = sys.argv[sys.argv.index("--workdir") + 1]
for i in range(3):
    print(f"[Map 000] Building tile [32,{30+i}]", flush=True)
open(os.path.join(work, "mmaps", "000.mmap"), "wb").write(b"x")
'''

# The game: reads what Play Solo set up, logs in with the 1.12.1 SRP6 handshake when a real realmd
# is there (that proves the account, its verifier and the realm list), writes what it saw, quits.
FAKE_GAME = r'''
import hashlib, json, os, re, socket, struct, sys
here = os.path.dirname(os.path.abspath(__file__))
out = {"argv": sys.argv[1:], "env": {k: os.environ.get(k) for k in ("WOW_HOST", "WOW_USER", "WOW_PASS", "WOW_REALM", "WOW_DATA")}}
rl = os.path.join(here, "realmlist.wtf")
out["realmlist"] = open(rl).read() if os.path.isfile(rl) else None
cfg = os.path.join(here, "WTF", "Config.wtf")
out["config"] = open(cfg).read() if os.path.isfile(cfg) else None
host = out["env"]["WOW_HOST"] or re.search(r"set realmlist (\S+)", out["realmlist"] or "").group(1)
user = (out["env"]["WOW_USER"] or "SOLO").upper().encode(); pwd = (out["env"]["WOW_PASS"] or "SOLO").upper().encode()
h, _, p = host.partition(":"); p = int(p or 3724)
def sha(*a):
    x = hashlib.sha1()
    for b in a: x.update(b)
    return x.digest()
def rx(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise ConnectionError("closed")
        b += c
    return b
if os.environ.get("FAKE_GAME_LOGIN") == "1":
    N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16); G = 7
    le = lambda n, k=32: n.to_bytes(k, "little")
    s = socket.create_connection((h, p), timeout=10)
    body = (b"WoW\x00" + bytes([1, 12, 1]) + struct.pack("<H", 5875) + b"68x\x00" + b"niW\x00" + b"SUne" +
            struct.pack("<I", 0) + socket.inet_aton("127.0.0.1") + bytes([len(user)]) + user)
    s.sendall(bytes([0, 3]) + struct.pack("<H", len(body)) + body)
    cmd, _, res = rx(s, 3)
    out["challenge"] = res
    if res == 0:
        B = int.from_bytes(rx(s, 32), "little"); rx(s, rx(s, 1)[0]); rx(s, rx(s, 1)[0])
        salt = rx(s, 32); rx(s, 16); rx(s, 1)
        a = int.from_bytes(os.urandom(32), "little") % N; A = pow(G, a, N); Ab, Bb = le(A), le(B)
        x = int.from_bytes(sha(salt, sha(user + b":" + pwd)), "little"); u = int.from_bytes(sha(Ab, Bb), "little")
        S = le(pow((B - 3 * pow(G, x, N)) % N, a + u * x, N)); e, o = sha(S[0::2]), sha(S[1::2])
        K = bytes(b for pr in zip(e, o) for b in pr)
        M1 = sha(bytes(i ^ j for i, j in zip(sha(le(N)), sha(le(G, 1)))), sha(user), salt, Ab, Bb, K)
        s.sendall(bytes([1]) + Ab + M1 + bytes(20) + bytes([0, 0]))
        cmd, res = rx(s, 2)
        out["proof"] = res
        if res == 0:
            rx(s, 20 + 4)
            s.sendall(bytes([0x10, 0, 0, 0, 0]))
            hdr = rx(s, 3); out["realms"] = rx(s, struct.unpack("<H", hdr[1:3])[0]).decode("latin-1")
    s.close()
json.dump(out, open(os.environ["FAKE_GAME_OUT"], "w"), indent=1)
'''


def char_start_outfit_dbc():
    """Synthetic CharStartOutfit.dbc: one Human Warrior male record (id, race, class, gender, pad)."""
    rec = struct.pack("<I4B", 1, 1, 1, 0, 0)
    return b"WDBC" + struct.pack("<4I", 1, 2, len(rec), 1) + rec + b"\x00"


def skill_race_class_dbc():
    """Synthetic SkillRaceClassInfo.dbc: Swords (43) for Human (1) Warriors (1)."""
    rec = struct.pack("<8I", 1, 43, 1, 1, 0, 0, 0, 0)
    return b"WDBC" + struct.pack("<4I", 1, 8, 32, 1) + rec + b"\x00"


# ------------------------------------------------------------------ stub inputs for build_solo_pack.py

MANGOSD_DIST = """[MangosdConf]
ConfVersion=2023010101
RealmID = 1
DataDir = "."
LogsDir = ""
LoginDatabaseInfo     = "127.0.0.1;3306;mangos;mangos;classicrealmd"
WorldDatabaseInfo     = "127.0.0.1;3306;mangos;mangos;classicmangos"
CharacterDatabaseInfo = "127.0.0.1;3306;mangos;mangos;classiccharacters"
LogsDatabaseInfo      = "127.0.0.1;3306;mangos;mangos;classiclogs"
WorldServerPort = 8085
BindIP = "0.0.0.0"
PlayerLimit = 100
mmap.enabled = 1
GameType = 1
SkipCinematics = 0
Motd = "Welcome to the Continued Massive Network Game Object Server."
Console.Enable = 1
Ra.Enable = 0
SOAP.Enabled = 0
SOAP.IP = 127.0.0.1
SOAP.Port = 7878
"""

REALMD_DIST = """[RealmdConf]
ConfVersion=2021031501
LoginDatabaseInfo = "127.0.0.1;3306;mangos;mangos;classicrealmd"
LogsDir = ""
MaxPingTime = 30
RealmServerPort = 3724
BindIP = "0.0.0.0"
PidFile = ""
LogLevel = 0
LogFile = "Realmd.log"
WrongPass.MaxCount = 0
"""

AIPLAYERBOT_DIST = """[AiPlayerbotConf]
ConfVersion=2020072501
AiPlayerbot.Enabled = 1
AiPlayerbot.MinRandomBots = 1000
AiPlayerbot.MaxRandomBots = 1000
# AiPlayerbot.SyncLevelWithPlayers = 0
"""

REALMD_MIN_SQL = """
CREATE TABLE account (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, username VARCHAR(32) NOT NULL DEFAULT '',
  gmlevel TINYINT UNSIGNED NOT NULL DEFAULT 0, v LONGTEXT, s LONGTEXT, UNIQUE KEY idx_username (username));
CREATE TABLE realmlist (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, name VARCHAR(32) NOT NULL DEFAULT '',
  address VARCHAR(32) NOT NULL DEFAULT '127.0.0.1', port INT NOT NULL DEFAULT 8085, icon TINYINT UNSIGNED NOT NULL DEFAULT 0,
  realmflags TINYINT UNSIGNED NOT NULL DEFAULT 2, timezone TINYINT UNSIGNED NOT NULL DEFAULT 0,
  allowedSecurityLevel TINYINT UNSIGNED NOT NULL DEFAULT 0, population FLOAT UNSIGNED NOT NULL DEFAULT 0,
  realmbuilds VARCHAR(64) NOT NULL DEFAULT '', UNIQUE KEY idx_name (name));
INSERT INTO realmlist (id, name) VALUES (1, 'MaNGOS');
"""


def stub_inputs(base, realmd=None, realmd_sql=None):
    """A server build folder, a MariaDB 'zip' folder and DB dumps, as packaging/workflows/solo-pack.yml.off would hand
    them to build_solo_pack.py. The programs are scripts; MariaDB wraps the system one."""
    srv = os.path.join(base, "server-build", "install")
    script(os.path.join(srv, "mangosd.exe"), FAKE_MANGOSD)
    if realmd:
        script(os.path.join(srv, "realmd.exe"), REAL_REALMD_WRAPPER.format(realmd=realmd))
    else:
        script(os.path.join(srv, "realmd.exe"), FAKE_REALMD)
    write(os.path.join(srv, "libmariadb.dll"), b"MZ fake dll")
    write(os.path.join(srv, "mangosd.pdb"), b"debug symbols that must not ship")
    write(os.path.join(srv, "mangosd.conf.dist"), MANGOSD_DIST)
    write(os.path.join(srv, "realmd.conf.dist"), REALMD_DIST)
    write(os.path.join(srv, "aiplayerbot.conf.dist"), AIPLAYERBOT_DIST)
    write(os.path.join(srv, "ahbot.conf.dist"), "AuctionHouseBot.Chance.Sell = 10\nAuctionHouseBot.Chance.Buy  = 10\n")
    write(os.path.join(srv, "anticheat.conf.dist"), "[AnticheatConf]\nEnable = 1\n[Other]\nEnable = 1\n")
    script(os.path.join(srv, "tools", "ad.exe"), FAKE_AD)
    script(os.path.join(srv, "tools", "vmap_extractor.exe"), FAKE_VMAP_EXTRACTOR)
    script(os.path.join(srv, "tools", "vmap_assembler.exe"), FAKE_VMAP_ASSEMBLER)
    script(os.path.join(srv, "tools", "MoveMapGen.exe"), FAKE_MOVEMAPGEN)
    write(os.path.join(srv, "tools", "offmesh.txt"), "# none\n")
    write(os.path.join(srv, "warden_modules", "x.bin"), b"skip me")

    mdb = os.path.join(base, "mariadb-11.4.5-winx64")
    for exe, target in (("mariadbd.exe", "mariadbd"), ("mariadb.exe", "mariadb"), ("mariadb-admin.exe", "mariadb-admin"),
                        ("mariadb-install-db.exe", "mariadb-install-db"), ("mariadb-dump.exe", "mariadb-dump")):
        real = next((os.path.join(d, target) for d in ("/usr/sbin", "/usr/bin") if os.path.isfile(os.path.join(d, target))), target)
        write(os.path.join(mdb, "bin", exe), f'#!/bin/sh\nexec {real} "$@"\n', 0o755)
    write(os.path.join(mdb, "bin", "server.dll"), b"MZ")
    write(os.path.join(mdb, "bin", "mariadbd.pdb"), b"no")
    write(os.path.join(mdb, "mysql-test", "t.test"), b"no")
    write(os.path.join(mdb, "include", "mysql.h"), b"no")
    write(os.path.join(mdb, "lib", "plugin", "auth_x.dll"), b"MZ")

    dumps = os.path.join(base, "dumps")
    with open(os.path.join(ROOT, "devkit", "db", "fixtures", "classicmangos.sql"), "rb") as f:
        write(os.path.join(dumps, "classicmangos.sql"), f.read())
    with open(os.path.join(ROOT, "devkit", "db", "fixtures", "classiccharacters.sql"), "rb") as f:
        write(os.path.join(dumps, "classiccharacters.sql"), f.read())
    if realmd_sql:
        with open(realmd_sql, "rb") as f:
            write(os.path.join(dumps, "classicrealmd.sql"), f.read())
    else:
        write(os.path.join(dumps, "classicrealmd.sql"), "-- MariaDB dump\n" + REALMD_MIN_SQL)
    write(os.path.join(dumps, "classiclogs.sql"), "-- MariaDB dump\nCREATE TABLE logs_x (id INT);\n")
    return srv, mdb, dumps


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def read_json(p):
    with open(p) as f:
        return json.load(f)


def make_executable(p):
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
