"""Host a realm from this PC: the Solo pack's servers in their own host folder, plus the agent
(openvanilla-node) that lists the realm, lets players in through the relay or a mapped port, signs
them in with Open Vanilla identity tokens and keeps backups.

    cfg = HostConfig(name="Stormwind Nights", type="rp", template="classicplus", max_players=20,
                     bots=40, visibility="private")
    s = HostSession(cfg, progress_cb=lambda stage, text, frac: ...)
    s.start()                       # blocks until the realm is up (run it on a worker thread)
    link = s.invite(uses=5, hours=48)
    s.status()                      # see status() for the keys
    s.kick("Name"); s.ban("Name"); s.announce("Restart in 5 minutes"); s.backup()
    s.stop()

What listens where:
  gate       0.0.0.0:3724 (127.0.0.1 when relay-only): Open Vanilla sign-in frames, else piped to realmd
  realmd     127.0.0.1:<internal port>
  mangosd    0.0.0.0:8085 (127.0.0.1 when relay-only)
  MariaDB    127.0.0.1 only, SOAP 127.0.0.1 only: never mapped, never in a firewall rule.
"""
import dataclasses
import datetime
import glob
import gzip
import hashlib
import os
import re
import socket
import subprocess
import sys
import threading
import time

import ed25519

from . import (CENTRAL_URL, HOST_ID_RE, RELAY_URL, REALM_TYPES, REGION, TEMPLATES, P2PError, b32, e2e, firewall,
               invites, paseto, play_local, read_json, realmproto, soap, upnp, write_json, ws)

CONNECTIONS = ("relay", "direct", "lan")
HOST_PORTS = {"db": 3312, "realm": 3725, "world": 8085, "soap": 7880, "gate": 3724}
NAME_RE = re.compile(r"^[A-Za-z0-9 .:()_+-]{3,40}$")
HEARTBEAT_EVERY = 60
BACKUP_EVERY = 30 * 60
BACKUP_KEEP_DAYS = 7
REVOKED_EVERY = 300
RELAY_PING_EVERY = 25
UPNP_RENEW_EVERY = 30 * 60
BOT_PREFIX = "RNDBOT"
LOGINS_PER_MINUTE = 20


@dataclasses.dataclass
class HostConfig:
    name: str
    type: str = "pve"                 # pve | pvp | rp | rppvp
    template: str = "classicplus"     # classicplus | vanilla
    max_players: int = 20
    bots: int = 40
    visibility: str = "private"       # private (unlisted, invite links) | public (listed)
    data_dir: str = None              # default: <Open Vanilla>\host, beside solo\
    description: str = ""
    tags: list = dataclasses.field(default_factory=list)
    upnp_consent: bool = False        # map 3724/8085 on the router (asked in the UI first)
    use_relay: bool = True
    connection: str = "relay"         # relay (outbound only) | direct (home connection, 0.0.0.0) | lan (LAN only)
    public_host: str = ""             # a DNS name / IP the host forwarded the ports to themselves
    firewall: bool = True             # Windows Firewall rules for the two ports (when they are opened)
    solo_root: str = None             # where the Solo pack lives (default: the Solo folder)
    client: str = None                # game client (only for making maps the first time)
    central: str = CENTRAL_URL
    relay: str = RELAY_URL
    armory: bool = False              # export + upload this realm to the Open Vanilla armory hourly (p2p/armory.py)
    node_network: bool = False        # live.json flags.nodes: advertise e2e + host key, accept a volunteer node
    allow_nodes: bool = True          # let the directory put this realm on a verified volunteer node

    def validate(self):
        self.name = (self.name or "").strip()
        if not NAME_RE.match(self.name):
            raise P2PError("Realm names are 3-40 letters, numbers, spaces or . : ( ) _ + -")
        if self.type not in REALM_TYPES:
            raise P2PError("Pick a realm type: PvE, PvP, RP or RP-PvP.")
        if self.template not in TEMPLATES:
            raise P2PError("Pick Classic+ or Vanilla.")
        if self.connection not in CONNECTIONS:
            raise P2PError("Connection is relay, direct or lan.")
        if self.connection == "lan":
            self.upnp_consent = False
        if self.visibility not in ("public", "private"):
            raise P2PError("A realm is public (listed) or private (invite only).")
        self.max_players = max(1, min(int(self.max_players), 500))
        self.bots = max(0, min(int(self.bots), 2000))
        self.description = "".join(ch for ch in self.description if ch.isprintable())[:200]
        self.tags = [t for t in (str(x)[:24] for x in self.tags) if t][:4]
        return self


def relay_available(central=CENTRAL_URL, get=None, timeout=4):
    """True when Open Vanilla's directory (which hands out relay tokens) answers. Any error -> False."""
    import urllib.request
    url = central.rstrip("/") + "/api/directory"
    try:
        if get is not None:
            status = get(url, timeout)
        else:
            req = urllib.request.Request(url, headers={"User-Agent": "OpenVanilla-Node/1"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                status = r.status
        return 200 <= int(status) < 300
    except Exception:
        return False


def plan_connection(requested, relay_enabled, probe):
    """(connection to use, fell_back). "Through Open Vanilla" needs the relay switched on (live.json
    flags.relay) and the directory answering; otherwise hosting goes Direct (the launcher shows the
    IP/privacy explainer first) instead of failing. Direct and LAN are used as asked."""
    if requested not in CONNECTIONS:
        requested = "direct"
    if requested != "relay":
        return requested, False
    if relay_enabled and probe():
        return "relay", False
    return "direct", True


def _lan_ip():
    try:
        ip = upnp.local_ip_for()
        return None if ip.startswith("127.") else ip
    except OSError:
        return None


def key_fingerprint(pub):
    """16 lowercase base32 characters of SHA-256(host public key)."""
    return b32(hashlib.sha256(pub).digest()[:10])


def reply_message(nonce, reply):
    return ("OWLR1|" + nonce + "|" + str(reply.get("ok")) + "|" + str(reply.get("user", "")) + "|"
            + str(reply.get("password", "")) + "|" + str(reply.get("realm", ""))).encode("utf-8")


def default_host_root():
    env = os.environ.get("OPENVANILLA_HOST_DIR")   # the launcher sets Realms\Hosted (launcher/layout.py)
    if env:
        return os.path.abspath(env)
    P = play_local()
    return os.path.join(os.path.dirname(P.default_solo_root()), "host")


def account_for(sub):
    """Open Vanilla account id -> local realmd account: OW + base32 of the id (16 characters at most)."""
    s = str(sub)
    if s.isdigit() and int(s) < 1 << 64:
        n = int(s)
        raw = n.to_bytes(max(1, (n.bit_length() + 7) // 8), "big")
    else:
        raw = hashlib.sha256(s.encode("utf-8")).digest()[:8]
    return ("OW" + b32(raw).upper())[:16]


def bot_cap_for_ram(total_mb):
    """Playerbots cost roughly 3-5 MB each in mangosd; leave the rest of the PC alone."""
    if not total_mb:
        return 200
    return max(0, min(2000, int((total_mb - 4096) / 8)))


def total_ram_mb():
    try:
        if sys.platform == "win32":
            import ctypes

            class MS(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            m = MS()
            m.dwLength = ctypes.sizeof(MS)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
            return m.ullTotalPhys // 1048576
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") // 1048576
    except (OSError, ValueError, AttributeError):
        return 0


class ProcMeter:
    """CPU % (of one core x cores) and RAM MB of our server processes."""

    def __init__(self):
        self.last = {}

    def _times(self, pid):
        """(cpu seconds, rss MB) or None."""
        try:
            import psutil  # optional
            p = psutil.Process(pid)
            t = p.cpu_times()
            return t.user + t.system, p.memory_info().rss / 1048576
        except ImportError:
            pass
        except Exception:
            return None
        if sys.platform.startswith("linux"):
            try:
                with open(f"/proc/{pid}/stat") as f:
                    parts = f.read().rsplit(")", 1)[1].split()
                tick = os.sysconf("SC_CLK_TCK")
                rss = int(parts[21]) * os.sysconf("SC_PAGE_SIZE") / 1048576
                return (int(parts[11]) + int(parts[12])) / tick, rss
            except (OSError, ValueError, IndexError):
                return None
        if sys.platform == "win32":
            try:
                import ctypes
                from ctypes import wintypes
                k32 = ctypes.windll.kernel32
                h = k32.OpenProcess(0x1000 | 0x0010, False, pid)   # QUERY_LIMITED_INFORMATION | VM_READ
                if not h:
                    return None
                try:
                    ft = [wintypes.FILETIME() for _ in range(4)]
                    k32.GetProcessTimes(h, *[ctypes.byref(x) for x in ft])
                    cpu = sum((x.dwHighDateTime << 32 | x.dwLowDateTime) for x in ft[2:]) / 1e7

                    class PMC(ctypes.Structure):
                        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
                            (n, ctypes.c_size_t) for n in ("PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                                                           "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                                                           "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage")]
                    pmc = PMC()
                    pmc.cb = ctypes.sizeof(PMC)
                    ctypes.windll.psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb)
                    return cpu, pmc.WorkingSetSize / 1048576
                finally:
                    k32.CloseHandle(h)
            except (OSError, AttributeError):
                return None
        return None

    def sample(self, pids, now=None):
        now = now or time.monotonic()
        cpu, ram = 0.0, 0.0
        for pid in pids:
            t = self._times(pid)
            if not t:
                continue
            ram += t[1]
            prev = self.last.get(pid)
            if prev and now > prev[0]:
                cpu += max(0.0, (t[0] - prev[1]) / (now - prev[0]) * 100)
            self.last[pid] = (now, t[0])
        return round(cpu, 1), round(ram)


class RateMeter:
    def __init__(self):
        self.up = self.down = 0
        self.lock = threading.Lock()
        self._mark = (time.monotonic(), 0, 0)

    def __call__(self, direction, n):
        with self.lock:
            if direction == "up":
                self.up += n
            else:
                self.down += n

    def rates(self):
        """(up KB/s, down KB/s) since the last call. 'up' = bytes the host sent to players."""
        now = time.monotonic()
        t0, u0, d0 = self._mark
        self._mark = (now, self.up, self.down)
        dt = max(now - t0, 1e-3)
        return round((self.up - u0) / 1024 / dt, 1), round((self.down - d0) / 1024 / dt, 1)


def tcp_pipe(a, b, meter=None, first=b""):
    """a = player side, b = server side. Copies both ways until one closes."""
    def one(src, dst, direction):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
                if meter:
                    meter(direction, len(data))
        except OSError:
            pass
        finally:
            for s in (src, dst):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    if first:
        b.sendall(first)
        if meter:
            meter("down", len(first))
    t = threading.Thread(target=one, args=(b, a, "up"), daemon=True)
    t.start()
    one(a, b, "down")
    t.join(timeout=5)
    a.close()
    b.close()


class Gate:
    """The realm's front door on the auth port: Open Vanilla sign-in frames, everything else to realmd."""

    def __init__(self, bind, port, realmd_port, login, meter=None):
        self.bind, self.port, self.realmd_port, self.login, self.meter = bind, port, realmd_port, login, meter
        self.sock = None
        self.stopped = threading.Event()

    def start(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if sys.platform != "win32":
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.bind, self.port))
        s.listen(64)
        self.sock = s
        self.port = s.getsockname()[1]
        threading.Thread(target=self._loop, daemon=True, name="gate").start()
        return self.port

    def _loop(self):
        while not self.stopped.is_set():
            try:
                conn, peer = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn, peer[0]), daemon=True).start()

    def _serve(self, conn, peer):
        try:
            conn.settimeout(15)
            first = conn.recv(1)
            if not first:
                conn.close()
                return
            if first == realmproto.LOGIN_MAGIC[:1]:
                head = first + realmproto.recv_exact(conn, 5)
                if head[:4] != realmproto.LOGIN_MAGIC:
                    conn.close()
                    return
                n = int.from_bytes(head[4:6], "big")
                if n > realmproto.MAX_FRAME:
                    conn.close()
                    return
                try:
                    req = realmproto.decode_frame_body(realmproto.recv_exact(conn, n))
                    reply = self.login(req, peer)
                except (ValueError, UnicodeDecodeError):
                    reply = {"ok": False, "error": "bad request"}
                conn.sendall(realmproto.encode_frame(realmproto.REPLY_MAGIC, reply))
                conn.close()
                return
            conn.settimeout(None)
            up = socket.create_connection(("127.0.0.1", self.realmd_port), timeout=10)
            up.settimeout(None)
            tcp_pipe(conn, up, self.meter, first)
        except OSError:
            try:
                conn.close()
            except OSError:
                pass

    def stop(self):
        self.stopped.set()
        if self.sock:
            try:
                self.sock.shutdown(socket.SHUT_RDWR)   # wakes a blocked accept() on Linux
            except OSError:
                pass
            try:
                self.sock.close()
            except OSError:
                pass


class RelayAgent:
    """One long-lived control WebSocket to the relay; a data WebSocket per player connection."""

    def __init__(self, relay_url, host_id, token, ports, invite_check, connect=ws.connect, meter=None,
                 on_state=None, ping_every=RELAY_PING_EVERY, host_key=None, node_id=None):
        self.relay_url, self.host_id, self.token = relay_url.rstrip("/"), host_id, token
        self.host_key = host_key            # Ed25519 seed: answers end-to-end encrypted streams (p2p.e2e)
        self.node_id = node_id              # set when this is a volunteer node, not Open Vanilla's relay
        self.failures = 0                   # consecutive failed connects (the host falls back after a few)
        self.ports = ports                  # {3724: local gate port, 8085: local world port}
        self.invite_check, self._connect, self.meter = invite_check, connect, meter
        self.on_state = on_state or (lambda connected: None)
        self.ping_every = ping_every
        self.stopped = threading.Event()
        self.control = None
        self.connected = False
        self.limits = {}
        self.streams = {}
        self.lock = threading.Lock()
        self.last_error = None

    def headers(self):
        return {"Authorization": "Bearer " + self.token, "X-Host-Id": self.host_id}

    def start(self):
        threading.Thread(target=self._run, daemon=True, name="relay-agent").start()

    def _set(self, connected):
        if connected != self.connected:
            self.connected = connected
            self.on_state(connected)

    def _run(self):
        backoff = 2
        while not self.stopped.is_set():
            try:
                c = self._connect(self.relay_url + "/agent", headers=self.headers())
            except (OSError, ValueError) as e:
                self.last_error = str(e)
                self.failures += 1
                self._set(False)
                if self.stopped.wait(backoff):
                    return
                backoff = min(backoff * 2, 60)
                continue
            backoff = 2
            self.failures = 0
            self.control = c
            self._set(True)
            pinger = threading.Thread(target=self._pinger, args=(c,), daemon=True)
            pinger.start()
            try:
                while not self.stopped.is_set():
                    msg = c.recv()
                    if msg is None:
                        break
                    if isinstance(msg, bytes):
                        continue
                    self._handle(c, msg)
            finally:
                c.close()
                self.control = None
                self._set(False)
            if self.stopped.wait(1):
                return

    def _pinger(self, c):
        n = 0
        while not self.stopped.wait(self.ping_every) and not c.closed:
            n += 1
            try:
                c.send(_json({"ping": n}))
            except OSError:
                return

    def _handle(self, c, text):
        import json
        try:
            msg = json.loads(text)
        except ValueError:
            return
        if not isinstance(msg, dict):
            return
        if "ping" in msg:
            c.send(_json({"pong": msg["ping"]}))
        elif "open" in msg:
            sid, port = msg.get("open"), msg.get("port")
            if port in self.ports and isinstance(sid, (int, str)) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", str(sid)):
                threading.Thread(target=self._stream, args=(str(sid), int(port), bool(msg.get("e2e"))),
                                 daemon=True).start()
            else:
                c.send(_json({"close": sid}))
        elif "close" in msg:
            with self.lock:
                s = self.streams.pop(str(msg["close"]), None)
            if s:
                s.close()
        elif "invite_check" in msg:
            ok = bool(self.invite_check(str(msg.get("invite_check") or "")))
            c.send(_json({("invite_ok" if ok else "invite_no"): msg.get("stream")}))
        elif "limits" in msg and isinstance(msg["limits"], dict):
            self.limits = msg["limits"]

    def _stream(self, sid, port, sealed=False):
        if sealed and not self.host_key:
            self._close_ctrl(sid)
            return
        try:
            local = socket.create_connection(("127.0.0.1", self.ports[port]), timeout=10)
            local.settimeout(None)
        except OSError:
            if self.control:
                try:
                    self.control.send(_json({"close": sid}))
                except OSError:
                    pass
            return
        try:
            data = self._connect(f"{self.relay_url}/agent/stream/{sid}", headers=self.headers())
        except (OSError, ValueError):
            local.close()
            return
        if sealed:
            try:   # the relay/node in between now sees only ciphertext
                data = e2e.server_handshake(data, self.host_id, self.host_key)
            except (P2PError, OSError, ValueError):
                data.close()
                local.close()
                return
        with self.lock:
            self.streams[sid] = data
        try:
            # 'up' in ws.pipe = local -> relay = bytes the host sends to the player
            ws.pipe(data, local, meter=self.meter)
        finally:
            with self.lock:
                self.streams.pop(sid, None)

    def _close_ctrl(self, sid):
        if self.control:
            try:
                self.control.send(_json({"close": sid}))
            except OSError:
                pass

    def update_ticket(self, token):
        """A volunteer node needs a fresh directory ticket every few minutes (they live 10 minutes)."""
        self.token = token
        c = self.control
        if c and self.node_id:
            try:
                c.send(_json({"ticket": token}))
            except OSError:
                pass

    def stop(self):
        self.stopped.set()
        c = self.control
        if c:
            c.close()
        with self.lock:
            for s in list(self.streams.values()):
                s.close()
            self.streams.clear()


def _json(obj):
    import json
    return json.dumps(obj, separators=(",", ":"))


class _Reporter:
    """play_local's Reporter -> progress_cb(stage, text, fraction or None)."""

    def __init__(self, cb):
        self.cb = cb or (lambda *a: None)
        self.stage_key = "start"

    def stage(self, key, text):
        self.stage_key = key
        self.cb(key, text, None)

    def progress(self, done, total=None, text=None):
        self.cb(self.stage_key, text or "", (done / total) if total else None)

    def info(self, text):
        self.cb("info", text, None)

    def warn(self, text):
        self.cb("warn", text, None)


def host_paths(host_root, solo_root, template="classicplus"):
    """SoloPaths for the host folder: its own data/etc/logs/state, the Solo pack's programs and maps."""
    P = play_local()
    hp = P.SoloPaths(host_root)
    sp = P.SoloPaths(solo_root)
    for attr in ("bin", "tools", "mariadb", "mariadb_bin", "db_seed", "conf", "sql", "sql_live", "pytools",
                 "gamedata", "pack_json", "download"):
        setattr(hp, attr, getattr(sp, attr))
    if template == "vanilla":
        hp.db_seed = os.path.join(sp.db_seed, "vanilla")
        hp.sql = hp.sql_live = os.path.join(host_root, "no-sql")
    hp.solo_root = sp.root
    hp.templates_dir = sp.templates_dir
    hp.pack_installed = sp.pack_installed
    hp.backups = os.path.join(host_root, "backups")
    hp.p2p_file = os.path.join(host_root, "p2p.json")
    hp.accounts_file = os.path.join(host_root, "accounts.json")
    hp.invites_file = os.path.join(host_root, "invites.json")
    return hp


def host_conf_overrides(cfg, bind, state):
    """bind: the address mangosd listens on (True/False = 0.0.0.0/127.0.0.1)."""
    bind = {True: "0.0.0.0", False: "127.0.0.1"}.get(bind, bind)
    motd = f"Welcome to {cfg.name}, an Open Vanilla community realm."
    mangosd = [("BindIP", f'"{bind}"'), ("GameType", str(REALM_TYPES[cfg.type])), ("PlayerLimit", str(cfg.max_players)),
               ("Motd", f'"{motd}"'), ("RealmID", "1"), ("SOAP.IP", "127.0.0.1")]
    bots = [("AiPlayerbot.Enabled", "1" if cfg.bots else "0"), ("AiPlayerbot.MinRandomBots", str(cfg.bots)),
            ("AiPlayerbot.MaxRandomBots", str(cfg.bots)), ("AiPlayerbot.RandomBotAccountPrefix", BOT_PREFIX),
            ("AiPlayerbot.RandomBotRandomPassword", "1")]
    realmd = [("BindIP", '"127.0.0.1"'), ("RealmServerPort", str(state["ports"]["realm"])), ("WrongPass.MaxCount", "5"),
              ("WrongPass.BanTime", "600")]
    return {"mangosd.conf": mangosd, "aiplayerbot.conf": bots, "realmd.conf": realmd}


def apply_host_overrides(configs, overrides):
    P = play_local()
    for name, pairs in overrides.items():
        path = configs.get(name)
        if not path:
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(P.apply_overrides(text, pairs))


def realmlist_host_sql(cfg, state, address):
    P = play_local()
    p = state["ports"]
    return ("INSERT INTO realmlist (id,name,address,port,icon,realmflags,timezone,allowedSecurityLevel,population,realmbuilds) "
            f"VALUES (1,'{P.sql_text(cfg.name)}','{P.sql_text(address)}',{int(p['world'])},{REALM_TYPES[cfg.type]},0,1,0,0,'5875') "
            f"ON DUPLICATE KEY UPDATE name=VALUES(name), address=VALUES(address), port=VALUES(port), icon=VALUES(icon), "
            "realmflags=0, realmbuilds='5875'; DELETE FROM realmlist WHERE id<>1;")


class HostSession:
    def __init__(self, cfg, progress_cb=None, *, popen=subprocess.Popen, connect=ws.connect, mapper=None,
                 http_post=None, keys=None, clock=time.time, firewall_run=None, settings=None, start_servers=True):
        self.cfg = cfg.validate()
        self.progress_cb = progress_cb or (lambda *a: None)
        self.reporter = _Reporter(self.progress_cb)
        self.popen, self.connect, self.clock = popen, connect, clock
        self._http_post = http_post            # (url, payload, headers) -> (status, json); tests
        self.settings = settings
        self.start_servers = start_servers     # False: the servers are already running (tests)
        P = play_local()
        self.host_root = os.path.abspath(cfg.data_dir or default_host_root())
        self.solo_root = os.path.abspath(cfg.solo_root or P.default_solo_root())
        self.paths = host_paths(self.host_root, self.solo_root, cfg.template)
        self.mapper = mapper or upnp.PortMapper(consent=cfg.upnp_consent)
        self.firewall_run = firewall_run
        self.keys = keys or paseto.KeyCache(cfg.central + "/.well-known/openvanilla-keys.json")
        self.revoked = paseto.RevocationList(cfg.central + "/api/identity/revoked", self.keys)
        self.meter = RateMeter()
        self.procmeter = ProcMeter()
        self.stopped = threading.Event()
        self.running = False
        self.state = None
        self.db = self.servers = self.gate = self.agent = None
        self.p2p = {}
        self.invites = invites.InviteStore(self.paths.invites_file, clock)
        self.accounts = read_json(self.paths.accounts_file, {}) or {}
        self.accounts_lock = threading.Lock()
        self.verifier = None
        self.reachability = "none"
        self.external_ip = None
        self.lan_ip = _lan_ip()
        self.listed = False
        self.last_heartbeat = None
        self.last_error = None
        self.firewall_ok = None
        self.started_at = None
        self._login_times = []
        self._soap = None
        self._threads = []
        self.node_failed = None              # a volunteer node we couldn't reach (told to the directory)

    # ------------------------------------------------------------ helpers
    @property
    def host_id(self):
        return self.p2p.get("host_id")

    def _save_p2p(self):
        write_json(self.paths.p2p_file, self.p2p)

    def _save_accounts(self):
        write_json(self.paths.accounts_file, self.accounts)

    def soap(self):
        if self._soap is None:
            P = play_local()
            self._soap = soap.Soap(P.SOLO_ADMIN, self.state["soap_password"], self.state["ports"]["soap"])
        return self._soap

    def query(self, sql, db=None):
        return self.db.query(sql, db)

    def open_ports(self):
        """Players connect to this PC itself (direct or lan), not only through the relay."""
        return self.cfg.connection in ("direct", "lan") or bool(self.cfg.upnp_consent or self.cfg.public_host)

    def bind_address(self):
        if self.cfg.connection == "lan":
            return self.lan_ip or "127.0.0.1"
        return "0.0.0.0" if self.open_ports() else "127.0.0.1"

    def realm_address(self):
        """What realmd tells clients to connect to for the world server."""
        if self.cfg.connection == "lan":
            return self.lan_ip or "127.0.0.1"
        if self.cfg.connection == "direct":
            return self.cfg.public_host or self.external_ip or self.lan_ip or "127.0.0.1"
        return self.cfg.public_host or "127.0.0.1"

    def exposed_ports(self):
        if not self.gate or self.bind_address().startswith("127."):
            return []
        return [int(self.state["ports"]["gate"]), int(self.state["ports"]["world"])]

    def _load_state(self):
        P = play_local()
        os.makedirs(self.host_root, exist_ok=True)
        st = read_json(self.paths.state_file, {}) or {}
        ports = st.setdefault("ports", {})
        for k, v in HOST_PORTS.items():
            ports.setdefault(k, v)
        write_json(self.paths.state_file, st)
        self.state = P.load_state(self.paths)
        self.p2p = read_json(self.paths.p2p_file, {}) or {}
        return self.state

    # ------------------------------------------------------------ start / stop
    def start(self):
        """Blocking. Raises P2PError (or play_local.SoloError) with a message for the host."""
        P = play_local()
        r = self.reporter
        try:
            self._load_state()
            for d in (self.paths.logs, self.paths.custom, self.paths.backups):
                os.makedirs(d, exist_ok=True)
            if self.start_servers:
                P.cleanup_stale(self.paths, self.state, r)
                self._start_servers()
            self._start_agent()
            self.running = True
            self.started_at = time.monotonic()
            r.stage("ready", f"{self.cfg.name} is up ({self.reachability}).")
            return self.status()
        except BaseException:
            self.stop()
            raise

    def _start_servers(self):
        P = play_local()
        r, p, cfg = self.reporter, self.paths, self.cfg
        self.servers = P.ServerSet(p, self.state, popen=self.popen)
        if P.is_port_open(self.state["ports"]["gate"]):
            raise P2PError(f"Port {self.state['ports']['gate']} is in use. Close Solo or any other local realm first.")
        self.servers.check_ports_free()
        solo = P.SoloSession(self.solo_root, r, client=cfg.client, settings=self.settings, popen=self.popen)
        pack = solo.ensure_pack()
        if cfg.template == "vanilla" and not P.seed_files(p).get("classicmangos"):
            raise P2PError("This server pack has no Vanilla world yet. Host the Classic+ template for now.")
        _, _, data = P.find_client(cfg.client, self.settings if self.settings is not None else None)
        solo.ensure_gamedata(data)
        cap = ram_bot_cap()
        if cfg.bots > cap:
            r.warn(f"Playerbots capped at {cap} for this PC's memory.")
            cfg.bots = cap
        configs = P.write_configs(p, self.state)
        apply_host_overrides(configs, host_conf_overrides(cfg, self.bind_address(), self.state))
        self.db = P.SoloDB(p, self.state, popen=self.popen)
        if not self.db.initialized():
            r.stage("database", "Setting up the host database…")
            self.db.initialize(r)
        r.stage("database", "Starting the host database…")
        self.db.start()
        self._record()
        P.ensure_databases(self.db, p, self.state, pack, r)
        if cfg.template == "classicplus":
            P.fix_server_dbcs(p, P.race_class_pairs(self.db), r)
        # The Solo account (password SOLO) must never exist on a realm other people can reach.
        self.db.query(f"DELETE FROM account WHERE username='{P.SOLO_ACCOUNT}';", "classicrealmd")
        self.db.query(realmlist_host_sql(cfg, self.state, self.realm_address()), "classicrealmd")
        P.save_state(p, self.state)
        self.servers.start(configs, r)
        self._record()
        P.save_state(p, self.state)

    def _record(self):
        P = play_local()
        procs = {}
        if self.db and self.db.proc:
            procs["mariadb"] = self.db.proc
        if self.servers:
            procs.update(self.servers.procs)
        P.write_run_record(self.paths, procs)

    def _start_agent(self):
        r, cfg, ports = self.reporter, self.cfg, self.state["ports"]
        bind = self.bind_address()
        self.gate = Gate(bind, int(ports["gate"]), int(ports["realm"]), self._login, self.meter)
        self.gate.start()
        game_ports = [int(ports["gate"]), int(ports["world"])]
        if self.open_ports():
            if cfg.firewall:
                res = firewall.add_rules(game_ports, self.firewall_run)
                self.firewall_ok = all(res.values())
                if not self.firewall_ok:
                    r.warn("Couldn't add the Windows Firewall rules (the launcher isn't running as administrator). "
                           "Windows may ask to allow Open Vanilla the first time a player connects.")
            if cfg.upnp_consent:
                r.stage("network", "Asking your router to open the game ports…")
                method, ext = self.mapper.map(game_ports)
                if method:
                    self.reachability, self.external_ip = "upnp", ext
                else:
                    r.warn("Your router didn't open the ports (UPnP / NAT-PMP is off or missing). "
                           + ("Forward TCP %d and %d yourself, or use the relay." % tuple(game_ports)
                              if cfg.connection == "direct" else "Using the relay."))
            if cfg.connection == "lan":
                self.reachability = "lan"
            elif cfg.public_host or cfg.connection == "direct":
                self.reachability = "direct" if self.reachability != "upnp" else "upnp"
            if self.db and self.realm_address() != "127.0.0.1":
                try:   # realmd re-reads realmlist within ~20 s
                    self.db.query(realmlist_host_sql(cfg, self.state, self.realm_address()), "classicrealmd")
                except Exception as e:
                    self.last_error = f"realmlist: {e}"
        if cfg.connection != "lan":
            r.stage("network", "Registering the realm…")
            try:
                self.heartbeat()     # central down only degrades status; the realm keeps running
            except Exception as e:
                self.last_error = f"directory: {e}"
        if cfg.use_relay and cfg.connection == "relay" and self.host_id and self.p2p.get("token") and self.reachability == "none" \
                and self.agent is None:   # (the heartbeat may already have put it on a volunteer node)
            self._start_relay()
        elif cfg.use_relay and cfg.connection == "relay" and self.reachability == "none":
            r.warn("The Open Vanilla directory can't be reached, so players can't join through the relay yet. "
                   "It will retry every minute.")
        if cfg.connection != "lan":
            self._spawn(self._loop_heartbeat)
        self._spawn(self._loop_backup)
        self._spawn(self._loop_revoked)
        if cfg.armory and cfg.connection != "lan":
            self._spawn(self._loop_armory)
        if self.mapper.method:
            self._spawn(self._loop_upnp)

    def _start_relay(self, url=None, token=None, node_id=None):
        ports = self.state["ports"]
        self.agent = RelayAgent(url or self.cfg.relay, self.host_id, token or self.p2p["token"],
                                {3724: int(self.gate.port), 8085: int(ports["world"])},
                                self.invites.check, connect=self.connect, meter=self.meter,
                                on_state=self._relay_state, node_id=node_id,
                                host_key=self.host_key_secret() if self.cfg.node_network else None)
        self.agent.start()

    def _switch_relay(self, url=None, token=None, node_id=None):
        old, self.agent = self.agent, None
        if old:
            old.stop()
        self._start_relay(url, token, node_id)

    def apply_assignment(self, a):
        """The directory's heartbeat answer may put this realm on a verified volunteer node:
        {"url": "ws(s)://…", "ticket": "v4.public…", "node_id": "<16 base32>"}. No (or a bad) assignment
        while on a node -> back to Open Vanilla's relay."""
        if not (self.cfg.node_network and self.cfg.use_relay and self.cfg.connection == "relay") or self.gate is None:
            return
        if self.reachability not in ("none", "relay") or not self.host_id:
            return
        ok = (isinstance(a, dict) and isinstance(a.get("url"), str) and re.match(r"^wss?://[^/\s]+$", a["url"].rstrip("/"))
              and str(a.get("ticket", "")).startswith("v4.public.") and HOST_ID_RE.match(str(a.get("node_id", "")))
              and self.cfg.allow_nodes and a.get("node_id") != self.node_failed)
        cur = self.agent
        if not ok:
            if cur and cur.node_id:
                self._switch_relay()
            return
        url = a["url"].rstrip("/")
        if cur and cur.node_id == a["node_id"] and cur.relay_url == url:
            cur.update_ticket(a["ticket"])
        else:
            self._switch_relay(url, a["ticket"], a["node_id"])

    def _check_node_failover(self):
        a = self.agent
        if a and a.node_id and a.failures >= 3:
            self.node_failed = a.node_id
            self._switch_relay()

    def _relay_state(self, connected):
        if self.reachability in ("none", "relay"):
            self.reachability = "relay" if connected else "none"

    def _spawn(self, fn):
        t = threading.Thread(target=fn, daemon=True, name=fn.__name__)
        t.start()
        self._threads.append(t)

    def stop(self):
        """Stop hosting: agent first (players see the realm go), then the servers, rules and mappings."""
        P = play_local()
        self.stopped.set()
        self.running = False
        if self.agent:
            self.agent.stop()
        if self.gate:
            self.gate.stop()
        try:
            if self.servers:
                self.servers.stop(self.reporter)
            if self.db:
                self.reporter.stage("stop", "Stopping the host database…")
                self.db.shutdown()
        finally:
            ports = [int(self.state["ports"]["gate"]), int(self.state["ports"]["world"])] if self.state else []
            if self.mapper and self.mapper.method:
                self.mapper.unmap()
            if self.cfg.firewall and self.open_ports() and ports:
                firewall.remove_rules(ports, self.firewall_run)
            if self.state and self.start_servers:
                try:
                    P.save_state(self.paths, self.state)
                    os.remove(self.paths.run_file)
                except OSError:
                    pass
        self.listed = False
        self.reachability = "none"
        self.reporter.stage("done", "Hosting stopped. Your realm's characters are saved on this PC.")

    # ------------------------------------------------------------ directory heartbeat
    def _post(self, url, payload, headers):
        if self._http_post:
            return self._http_post(url, payload, headers)
        from . import http_json
        return http_json(url, "POST", payload, headers, timeout=10)

    def population(self):
        """Players online (bot accounts excluded)."""
        if not self.db:
            return 0
        try:
            out = self.db.query(
                "SELECT COUNT(*) FROM classiccharacters.characters c JOIN classicrealmd.account a ON a.id = c.account "
                f"WHERE c.online = 1 AND a.username NOT LIKE '{BOT_PREFIX}%';")
            return int(out.strip() or 0)
        except Exception:
            return 0

    def bots_online(self):
        if not self.db:
            return 0
        try:
            out = self.db.query(
                "SELECT COUNT(*) FROM classiccharacters.characters c JOIN classicrealmd.account a ON a.id = c.account "
                f"WHERE c.online = 1 AND a.username LIKE '{BOT_PREFIX}%';")
            return int(out.strip() or 0)
        except Exception:
            return 0

    def heartbeat_payload(self):
        cfg = self.cfg
        relay = self.reachability in ("none", "relay") and cfg.use_relay and cfg.connection == "relay"
        host = port = None   # relayed: the directory lists the relay itself (host/port omitted)
        if not relay:
            host, port = cfg.public_host or self.external_ip or "", int(self.state["ports"]["gate"])
        pack = read_json(self.paths.pack_json, {}) or {}
        version = re.sub(r"[^A-Za-z0-9.+_-]", "", str(pack.get("version") or "1.0"))[:32] or "1.0"
        tags = list(cfg.tags) + (["Classic+"] if cfg.template == "classicplus" and "Classic+" not in cfg.tags else [])
        body = {"name": cfg.name, "type": cfg.type, "population": self.population(),
                "version": version, "build": 5875, "tags": tags[:4], "visibility": cfg.visibility,
                "relay": relay, "template": cfg.template, "region": REGION}
        if host is not None:
            body["host"], body["port"] = host, port
        if cfg.description:
            body["description"] = cfg.description
        if cfg.node_network:
            body["key"] = self.fingerprint()     # players check the e2e handshake against it
            body["e2e"] = True
            body["nodes"] = bool(cfg.allow_nodes and relay)
            if self.node_failed:
                body["node_failed"] = self.node_failed
        return body

    def heartbeat(self):
        """One heartbeat. First claim stores token + host_id; a refused token is dropped and re-claimed."""
        url = self.cfg.central + "/api/directory/heartbeat"
        payload = self.heartbeat_payload()
        headers = {"Authorization": "Bearer " + self.p2p["token"]} if self.p2p.get("token") else {}
        try:
            status, data = self._post(url, payload, headers)
        except OSError as e:
            self.last_error = f"directory: {e}"
            return False
        data = data if isinstance(data, dict) else {}
        if status == 403 and headers:
            self.p2p.pop("token", None)
            self._save_p2p()
            try:
                status, data = self._post(url, payload, {})
            except OSError as e:
                self.last_error = f"directory: {e}"
                return False
            data = data if isinstance(data, dict) else {}
        if status in (200, 201):
            if data.get("token"):
                self.p2p["token"] = data["token"]
            if data.get("host_id"):
                self.p2p["host_id"] = data["host_id"]
            self._save_p2p()
            self.last_heartbeat = self.clock()
            self.listed = self.cfg.visibility == "public" and bool(data.get("listed", True))
            if self.host_id and self.verifier is None:
                self.verifier = paseto.TokenVerifier(self.keys, self.host_id, self.clock, self.revoked)
            self.last_error = None
            if self.cfg.node_network:
                self.apply_assignment(data.get("relay"))
            return True
        self.listed = False
        self.last_error = f"directory answered {status}: {data.get('error', '')}".strip()
        return False

    def _loop_heartbeat(self):
        while not self.stopped.wait(HEARTBEAT_EVERY):
            try:
                self.heartbeat()
            except Exception as e:
                self.last_error = f"directory: {e}"
            if self.cfg.use_relay and self.cfg.connection == "relay" and self.agent is None and self.host_id and self.p2p.get("token") \
                    and self.reachability == "none":
                self._start_relay()
            elif self.agent and not self.agent.node_id and self.agent.token != self.p2p.get("token"):
                self.agent.token = self.p2p.get("token") or self.agent.token
            self._check_node_failover()

    def _loop_upnp(self):
        while not self.stopped.wait(UPNP_RENEW_EVERY):
            try:
                self.mapper.renew()
            except OSError:
                pass

    # ------------------------------------------------------------ sign-in through the gate
    def _rate_ok(self):
        now = time.monotonic()
        self._login_times = [t for t in self._login_times if now - t < 60]
        if len(self._login_times) >= LOGINS_PER_MINUTE:
            return False
        self._login_times.append(now)
        return True

    def _login(self, req, peer):
        if not self._rate_ok():
            return {"ok": False, "error": "Too many sign-ins right now. Try again in a minute."}
        reply = self._guest_login(req) if req.get("guest") else self._token_login(req)
        nonce = str(req.get("nonce") or "")
        if re.fullmatch(r"[0-9a-f]{16,64}", nonce):
            # proves this reply comes from the host whose key fingerprint is in the link (TOFU on the player side)
            reply["host_key"] = self.host_key_public().hex()
            reply["sig"] = ed25519.sign(self.host_key_secret(), reply_message(nonce, reply)).hex()
        return reply

    def _guest_login(self, req):
        """A guest invite: no Open Vanilla sign-in, a local account made from the invite."""
        code = str(req.get("guest") or "").upper()
        base = re.sub(r"[^A-Z0-9]", "", str(req.get("name") or "").upper())[:12] or "GUEST"
        if len(base) < 3:
            base = (base + "GUEST")[:5]
        with self.accounts_lock:
            if not self.invites.consume(code):
                return {"ok": False, "error": "This invite is used up or has expired. Ask the host for a new one."}
            user, n = base, 1
            while "guest:" + user in self.accounts or user.startswith(BOT_PREFIX) or user in ("SOLO", "SOLOADMIN"):
                n += 1
                user = f"{base}{n}"[:16]
            try:
                acc = self._create_account(user, req.get("name"))
            except (P2PError, OSError, ValueError) as e:
                return {"ok": False, "error": f"The realm couldn't make your account ({e})."}
            acc["guest"] = code
            self.accounts["guest:" + user] = acc
            self._save_accounts()
        return {"ok": True, "user": acc["user"], "password": acc["password"], "realm": self.cfg.name}

    def _token_login(self, req):
        if self.verifier is None:
            return {"ok": False, "error": "This realm isn't registered with Open Vanilla yet. Try again in a minute."}
        try:
            claims = self.verifier.verify(str(req.get("token", "")))
        except paseto.TokenError as e:
            return {"ok": False, "error": f"Sign-in refused: {e}."}
        sub = str(claims["sub"])
        if sub in self.p2p.get("banned_subs", []):
            return {"ok": False, "error": "You are banned from this realm."}
        with self.accounts_lock:
            acc = self.accounts.get(sub)
            if not acc:
                if self.cfg.visibility == "private" and not self.invites.consume(str(req.get("invite") or "")):
                    return {"ok": False, "error": "This realm is private: you need a valid invite link."}
                try:
                    acc = self._create_account(account_for(sub), claims.get("name"))
                except (P2PError, OSError, ValueError) as e:
                    return {"ok": False, "error": f"The realm couldn't make your account ({e})."}
                self.accounts[sub] = acc
                self._save_accounts()
        reply = {"ok": True, "user": acc["user"], "password": acc["password"], "realm": self.cfg.name}
        if self.cfg.visibility == "private":
            reply["pass"] = self.invites.pass_for(sub)   # lets this player's game streams through the relay
        return reply

    def _create_account(self, user, display_name=None):
        P = play_local()
        pw = soap.random_password()
        try:
            self.soap().create_account(user, pw)
        except P2PError:
            pass
        # Whatever SOAP said, make sure the account exists with this password (SQL is the source of truth).
        if self.db:
            self.db.query(P.account_sql(user, pw, 0), "classicrealmd")
        return {"user": user, "password": pw, "name": "".join(ch for ch in str(display_name or "") if ch.isprintable())[:32],
                "created": int(self.clock())}

    # ------------------------------------------------------------ host key (guest invites, TOFU)
    def host_key_secret(self):
        path = os.path.join(self.host_root, "host_key.seed")
        seed = None
        try:
            with open(path) as f:
                seed = bytes.fromhex(f.read().strip())
        except (OSError, ValueError):
            pass
        if not seed or len(seed) != 32:
            seed = os.urandom(32)
            os.makedirs(self.host_root, exist_ok=True)
            with open(path, "w") as f:
                f.write(seed.hex())
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
        return seed

    def host_key_public(self):
        if getattr(self, "_host_pub", None) is None:
            self._host_pub = ed25519.public_key(self.host_key_secret())
        return self._host_pub

    def fingerprint(self):
        return key_fingerprint(self.host_key_public())

    def guest_invite(self, uses=1, hours=24, address=None):
        """An invite that needs no Open Vanilla sign-in (works with central offline). Direct/LAN:
        openvanilla://join/direct/<host>:<port>?g=…&n=…&k=…; relay: openvanilla://join/<host_id>?g=…&k=…"""
        code = self.invites.create(uses, hours)
        fp = self.fingerprint()
        gate = int(self.state["ports"]["gate"]) if self.state else 3724
        if self.cfg.connection == "relay" and not address:
            if not self.host_id:
                self.invites.revoke(code)
                raise P2PError("Relay invites need the Open Vanilla directory. Switch to Direct or LAN to invite while it is offline.")
            return invites.make_link(self.host_id, None, self.cfg.name, guest=code, fp=fp)
        address = address or (self.lan_ip if self.cfg.connection == "lan" else
                              (self.cfg.public_host or self.external_ip or self.lan_ip))
        if not address:
            self.invites.revoke(code)
            raise P2PError("This PC's address isn't known yet. Enter your public address (or use LAN).")
        return invites.make_direct_link(self.cfg.connection if self.cfg.connection == "lan" else "direct",
                                        address, gate, code, self.cfg.name, fp)

    def create_account(self, name, password):
        """A named local account to hand out by hand (stock client, no launcher)."""
        name = (name or "").strip().upper()
        if not re.fullmatch(r"[A-Z0-9]{3,16}", name) or name.startswith(BOT_PREFIX) or name in ("SOLO", "SOLOADMIN"):
            raise P2PError("Account names are 3-16 letters or numbers.")
        password = (password or "").strip().upper()
        if not re.fullmatch(r"[A-Z0-9]{4,16}", password):
            raise P2PError("Passwords are 4-16 letters or numbers (the game's login screen limit).")
        P = play_local()
        try:
            self.soap().create_account(name, password)
        except P2PError:
            pass
        if self.db:
            self.db.query(P.account_sql(name, password, 0), "classicrealmd")
        with self.accounts_lock:
            self.accounts["manual:" + name] = {"user": name, "password": password, "created": int(self.clock())}
            self._save_accounts()
        return {"user": name, "password": password, "realm": self.cfg.name,
                "realmlist": self.realm_address() if self.open_ports() else None}

    # ------------------------------------------------------------ host actions
    def invite(self, uses=1, hours=24):
        if not self.host_id:
            raise P2PError("The realm isn't registered yet; invites work once it is online.")
        code = self.invites.create(uses, hours)
        return invites.make_link(self.host_id, code, self.cfg.name)

    def kick(self, name):
        return self.soap().kick(name)

    def ban(self, name, reason="Banned by the host"):
        """Ban the character in game and its Open Vanilla identity from this realm."""
        reply = self.soap().ban(name, reason)
        if self.db and soap.CHAR_RE.match(name):
            try:
                acc = self.db.query(f"SELECT a.username FROM classiccharacters.characters c JOIN classicrealmd.account a "
                                    f"ON a.id = c.account WHERE c.name = '{name}';").strip()
            except Exception:
                acc = ""
            for sub, a in self.accounts.items():
                if a["user"] == acc:
                    banned = self.p2p.setdefault("banned_subs", [])
                    if sub not in banned:
                        banned.append(sub)
                        self._save_p2p()
                    self.invites.revoke_pass(sub)
        return reply

    def announce(self, text):
        return self.soap().announce(text)

    def backup(self):
        """characters + accounts to backups\\backup-YYYYmmdd-HHMMSS.sql.gz; older than 7 days are deleted."""
        P = play_local()
        if not self.db:
            raise P2PError("The realm isn't running.")
        dump = P.find_exe(self.paths.mariadb_bin, "mariadb-dump", "mysqldump")
        if not dump:
            raise P2PError("The server pack has no mariadb-dump.")
        os.makedirs(self.paths.backups, exist_ok=True)
        stamp = datetime.datetime.fromtimestamp(self.clock()).strftime("%Y%m%d-%H%M%S")
        out = os.path.join(self.paths.backups, f"backup-{stamp}.sql.gz")
        argv = [dump, "--no-defaults", "--protocol=TCP", "--host=127.0.0.1", f"--port={self.db.port}", "--user=root",
                "--single-transaction", "--databases", "classiccharacters", "classicrealmd"]
        env = dict(os.environ, MYSQL_PWD=self.state["db_root_password"])
        with gzip.open(out + ".tmp", "wb") as gz:
            proc = self.popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, **P.hidden_run_kwargs())
            for chunk in iter(lambda: proc.stdout.read(1 << 20), b""):
                gz.write(chunk)
            code = proc.wait()
        if code != 0:
            os.remove(out + ".tmp")
            raise P2PError("The backup failed (mariadb-dump exit %d)." % code)
        os.replace(out + ".tmp", out)
        prune_backups(self.paths.backups, self.clock())
        return out

    def _loop_backup(self):
        while not self.stopped.wait(BACKUP_EVERY):
            try:
                self.backup()
            except (P2PError, OSError) as e:
                self.last_error = f"backup: {e}"

    # ------------------------------------------------------------ armory (opt-in; docs/ARMORY.md)
    def armory_upload(self, force=False):
        from . import armory
        return armory.export_and_upload(self, force=force)

    def _loop_armory(self):
        from . import armory
        armory.loop(self)

    def _loop_revoked(self):
        while True:
            try:
                if self.revoked.poll(force=True):
                    self._kick_revoked()
            except Exception as e:  # never let a bad list kill the loop
                self.last_error = f"revocation list: {e}"
            if self.stopped.wait(REVOKED_EVERY):
                return

    def _kick_revoked(self):
        users = [a["user"] for sub, a in self.accounts.items() if self.revoked.is_revoked(sub)]
        if not users or not self.db:
            return
        names = ",".join(f"'{u}'" for u in users if re.fullmatch(r"[A-Z0-9]{3,16}", u))
        if not names:
            return
        out = self.db.query("SELECT c.name FROM classiccharacters.characters c JOIN classicrealmd.account a "
                            f"ON a.id = c.account WHERE c.online = 1 AND a.username IN ({names});")
        for n in out.split():
            try:
                self.kick(n)
            except P2PError:
                pass

    # ------------------------------------------------------------ status
    def pids(self):
        out = []
        if self.db and self.db.proc:
            out.append(self.db.proc.pid)
        if self.servers:
            out += [p.pid for p in self.servers.procs.values() if getattr(p, "pid", None)]
        return out

    def status(self):
        cpu, ram = self.procmeter.sample(self.pids())
        up, down = self.meter.rates()
        return {
            "running": self.running,
            "name": self.cfg.name,
            "host_id": self.host_id,
            "players": self.population(),
            "bots": self.bots_online(),
            "max_players": self.cfg.max_players,
            "cpu": cpu,                       # % of one core (can exceed 100 on several cores)
            "ram": ram,                       # MB, MariaDB + realmd + mangosd
            "up_kbps": up,                    # host -> players through the gate / relay
            "down_kbps": down,
            "reachability": self.reachability,   # "relay" | "direct" | "upnp" | "lan" | "none"
            "connection": self.cfg.connection,
            "lan_ip": self.lan_ip,
            "exposed_ports": self.exposed_ports(),
            "fingerprint": self.fingerprint() if self.state else None,
            "external_ip": self.external_ip,
            "listed": self.listed,
            "visibility": self.cfg.visibility,
            "last_heartbeat": self.last_heartbeat,
            "relay_connected": bool(self.agent and self.agent.connected),
            "relay_node": self.agent.node_id if self.agent else None,   # None: Open Vanilla's relay
            "firewall_ok": self.firewall_ok,
            "last_error": self.last_error,
            "uptime": int(time.monotonic() - self.started_at) if self.started_at else 0,
            "invites": self.invites.list(),
        }


def prune_backups(folder, now=None, keep_days=BACKUP_KEEP_DAYS):
    now = now or time.time()
    removed = []
    for p in glob.glob(os.path.join(folder, "backup-*.sql.gz")):
        m = re.search(r"backup-(\d{8}-\d{6})\.sql\.gz$", p)
        if not m:
            continue
        t = datetime.datetime.strptime(m.group(1), "%Y%m%d-%H%M%S").timestamp()
        if now - t > keep_days * 86400:
            try:
                os.remove(p)
                removed.append(p)
            except OSError:
                pass
    return removed


def ram_bot_cap():
    return bot_cap_for_ram(total_ram_mb())


