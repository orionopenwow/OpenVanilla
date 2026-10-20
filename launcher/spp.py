"""Play Solo with SPP Classics (celguar/spp-classics-cmangos): download, set up, start hidden, play, stop.

What SPP Classics V2 needs, and who does each step (docs/LAUNCHER.md has the player-facing version):

  1. download   SPP_Classics_V2.zip (~110 MB, GitHub release v2.0) into Realms\\Solo\\download.
                The launcher, with a progress bar; resumable; SHA-256 checked when live.json/links.txt
                gives one (SPP_SHA256).
  2. unpack     -> Realms\\Solo\\SPP_Classics_V2 (portable Git + Server_Update.bat). The launcher.
  3. base       SPP's Server_Update.bat would `git clone --filter=tree:0` the repo into SPP_Server
                (~700 MB). The launcher runs that same clone itself, hidden, with SPP's bundled git,
                and shows its progress. Then copies Server_Update.bat / Server_Start.bat like SPP does.
  4. vanilla    SPP_Server\\Launcher.bat is an interactive console menu: type 1 (World of Warcraft) and it
                downloads vanilla.7z (~750 MB maps), unpacks MySQL, imports the world/characters/bots
                databases, then shows the Vanilla menu ("2 - Start Server" ... "0 - Shutdown Repack").
                It reads the keyboard with `set /P`, so it can't be driven reliably unattended: the
                launcher opens it in a console and tells the player exactly what to type (1, wait, 0),
                and watches the folder: when the Vanilla binaries, maps and version stamps exist, the
                step turns green on its own.
  5. play       The launcher starts SPP's mysqld (port 3310), realmd (3724) and mangosd (8085) with no
                windows, makes sure realmlist says 127.0.0.1 and a SOLO / SOLO account exists, points the
                client's realmlist.wtf at 127.0.0.1, starts the game, and when the game closes saves the
                world (`saveall`, `server shutdown 1` on mangosd's console) and stops everything it started.

Standard library only; Python 3.10 compatible. Everything that touches processes, ports or the network is
injectable so tests run on Linux with fakes.
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time

import fetch

SPP_ZIP_URL = "https://github.com/celguar/spp-classics-cmangos/releases/download/v2.0/SPP_Classics_V2.zip"
SPP_ZIP_SHA256 = "cde7256161879f219c07648b29d40ac7fa5a239e8458dbebba04825069a76619"   # v2.0 asset, checked Oct 2026
SPP_ZIP_SIZE = 114902146
SPP_REPO = "https://github.com/celguar/spp-classics-cmangos.git"
SPP_BRANCH = "master"
SPP_PAGE = "https://github.com/celguar/spp-classics-cmangos/releases"
BASE_FOLDER = "SPP_Classics_V2"
SERVER_FOLDER = "SPP_Server"
SOLO_ACCOUNT, SOLO_PASSWORD = "SOLO", "SOLO"
PORTS = {"db": 3310, "realm": 3724, "world": 8085}
DEFAULT_DB = ("127.0.0.1", 3310, "root", "123456")   # SPP's bundled MySQL
STATES = ("missing", "downloaded", "unpacked", "base", "ready")
CREATE_NO_WINDOW = 0x08000000
VANILLA_STEPS = ("In the SPP window, type 1 and press Enter (Vanilla).",
                 "Wait. It downloads about 750 MB and sets up the database. Don't close the window.",
                 "When you see the Vanilla menu (2 - Start Server ... 0 - Shutdown Repack), type 0 and press Enter.")


class SppError(Exception):
    """Something to show the player as is."""


Cancelled = fetch.Cancelled


class SppPaths:
    """root = Realms\\Solo. server may point at an SPP_Server folder elsewhere (an existing install)."""

    def __init__(self, root, server=None):
        self.root = os.path.abspath(root)
        self.download = os.path.join(self.root, "download")
        self.zip = os.path.join(self.download, "SPP_Classics_V2.zip")
        if server:
            self.server = os.path.abspath(server)
            self.base = os.path.dirname(self.server)
        else:
            self.base = os.path.join(self.root, BASE_FOLDER)
            self.server = os.path.join(self.base, SERVER_FOLDER)
        self.git = os.path.join(self.base, "Git", "cmd", "git.exe")
        self.update_bat = os.path.join(self.base, "Server_Update.bat")
        self.launcher_bat = os.path.join(self.server, "Launcher.bat")
        s = lambda *p: os.path.join(self.server, *p)
        self.db_dir = s("Server", "Database")
        self.mysqld = s("Server", "Database", "bin", "mysqld.exe")
        self.mysql = s("Server", "Database", "bin", "mysql.exe")
        self.mysqladmin = s("Server", "Database", "bin", "mysqladmin.exe")
        self.db_ini = s("Server", "Database", "SPP-Database.ini")
        self.bin = s("Server", "Binaries", "vanilla", "Bin64")
        self.realmd = s("Server", "Binaries", "vanilla", "Bin64", "realmd.exe")
        self.mangosd = s("Server", "Binaries", "vanilla", "Bin64", "mangosd.exe")
        self.settings = s("Settings", "vanilla")
        self.versions = s("Server", "Versions")
        self.maps = s("Server", "Modules", "vanilla", "maps")
        self.logs = s("Settings", "vanilla", "logs")

    def vanilla_ready(self):
        return (all(os.path.isfile(p) for p in (self.mysqld, self.realmd, self.mangosd))
                and _nonempty(self.maps)
                and os.path.isfile(os.path.join(self.versions, "vanilla_world_version.spp")))


def _nonempty(folder):
    try:
        with os.scandir(folder) as it:
            return any(True for _ in it)
    except OSError:
        return False


def detect_state(paths):
    """Where this SPP install is: missing -> downloaded -> unpacked -> base -> ready."""
    if paths.vanilla_ready():
        return "ready"
    if os.path.isfile(paths.launcher_bat):
        return "base"
    if os.path.isfile(paths.update_bat) and os.path.isfile(paths.git):
        return "unpacked"
    if os.path.isfile(paths.zip):
        return "downloaded"
    return "missing"


def is_spp_server(folder):
    return bool(folder) and os.path.isfile(os.path.join(folder, "Launcher.bat")) and \
        os.path.isdir(os.path.join(folder, "Server"))


def find_existing(extra=(), home=None):
    """An SPP_Server folder from an SPP install the player already has (Desktop, C:\\, …), or None."""
    home = home or os.path.expanduser("~")
    bases = list(extra) + [os.path.join(home, "Desktop", "Games", BASE_FOLDER), os.path.join(home, "Desktop", BASE_FOLDER),
                           os.path.join(home, BASE_FOLDER), "C:\\" + BASE_FOLDER, "D:\\" + BASE_FOLDER,
                           "C:\\Games\\" + BASE_FOLDER]
    for b in bases:
        if not b:
            continue
        for cand in (b, os.path.join(b, SERVER_FOLDER)):
            if is_spp_server(cand):
                return os.path.abspath(cand)
    return None


def db_settings(paths):
    """(host, port, user, password) from mangosd.conf's LoginDatabaseInfo; SPP's defaults otherwise."""
    conf = os.path.join(paths.settings, "mangosd.conf")
    try:
        with open(conf, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r'\s*LoginDatabaseInfo\s*=\s*"([^;"]*);(\d+);([^;"]*);([^;"]*);', line)
                if m:
                    return m.group(1), int(m.group(2)), m.group(3), m.group(4)
    except OSError:
        pass
    return DEFAULT_DB


# ---------------------------------------------------------------- install

GIT_PROGRESS = re.compile(r"(Receiving objects|Resolving deltas|Updating files|Checking out files):\s+(\d+)%")


class SppInstaller:
    """Steps 1-3 unattended, step 4 guided. report(stage, text, fraction or None)."""

    def __init__(self, paths, url=SPP_ZIP_URL, sha256=SPP_ZIP_SHA256, size=SPP_ZIP_SIZE, report=None, cancel=None,
                 opener=None, popen=subprocess.Popen):
        self.p, self.url = paths, url or SPP_ZIP_URL
        # a custom URL without its own checksum is checked for being a sane zip only
        same = self.url == SPP_ZIP_URL
        self.sha256 = (sha256 or (SPP_ZIP_SHA256 if same else None))
        self.size = int(size) if size else (SPP_ZIP_SIZE if same else None)
        self.report = report or (lambda stage, text, frac=None: None)
        self.cancel, self.opener, self.popen = cancel, opener, popen

    def state(self):
        return detect_state(self.p)

    def run(self, until="base"):
        """Do every unattended step up to `until`. Returns the state reached."""
        order = STATES.index(until)
        st = self.state()
        if STATES.index(st) < 1 <= order:
            self.download()
        if STATES.index(self.state()) < 2 <= order:
            self.unpack()
        if STATES.index(self.state()) < 3 <= order:
            self.clone_base()
        return self.state()

    def download(self):
        self.report("download", "Downloading SPP Classics…", 0.0)
        t0 = time.time()

        def prog(done, total):
            speed = done / max(0.001, time.time() - t0)
            self.report("download", f"Downloading SPP Classics: {fetch.human_size(done)}"
                        + (f" of {fetch.human_size(total)}" if total else "") + f"  ·  {speed / 1e6:.1f} MB/s",
                        (done / total) if total else None)
        try:
            fetch.download(self.url, self.p.zip, sha256=self.sha256, size=self.size, progress=prog,
                           cancel=self.cancel, opener=self.opener)
        except fetch.Cancelled:
            raise
        except fetch.FetchError as e:
            raise SppError(str(e))

    def unpack(self):
        self.report("unpack", "Checking and unpacking SPP Classics…", 0.0)
        if self.sha256 and fetch.sha256_file(self.p.zip, self.cancel) != self.sha256.lower():
            os.remove(self.p.zip)
            raise SppError("The SPP Classics download was damaged and has been removed. Press the button again.")
        staging = os.path.join(self.p.root, ".unpacking")
        if os.path.isdir(staging):
            shutil.rmtree(staging, ignore_errors=True)
        try:
            fetch.safe_extract(self.p.zip, staging, progress=lambda d, t: self.report("unpack", "Unpacking SPP Classics…", d / t),
                               cancel=self.cancel)
        except fetch.FetchError as e:
            shutil.rmtree(staging, ignore_errors=True)
            raise SppError(str(e))
        src = os.path.join(staging, BASE_FOLDER)
        if not os.path.isfile(os.path.join(src, "Server_Update.bat")):
            shutil.rmtree(staging, ignore_errors=True)
            raise SppError(f"That download isn't SPP Classics V2 (no {BASE_FOLDER}\\Server_Update.bat inside).")
        os.makedirs(self.p.base, exist_ok=True)
        for name in os.listdir(src):   # keep anything already there (an SPP_Server from an earlier try)
            dst = os.path.join(self.p.base, name)
            if os.path.exists(dst):
                if os.path.isdir(dst):
                    shutil.copytree(os.path.join(src, name), dst, dirs_exist_ok=True)
                else:
                    shutil.copy2(os.path.join(src, name), dst)
            else:
                os.replace(os.path.join(src, name), dst)
        shutil.rmtree(staging, ignore_errors=True)
        self.report("unpack", "SPP Classics unpacked.", 1.0)

    def clone_base(self):
        """What Server_Update.bat does first: clone the SPP repo into SPP_Server (with SPP's own git)."""
        p = self.p
        if os.path.isdir(p.server) and not os.path.isfile(p.launcher_bat):
            aside = p.server + ".partial-" + time.strftime("%Y%m%d-%H%M%S")
            os.replace(p.server, aside)   # an interrupted clone: keep it aside, start clean
        if not os.path.isfile(p.git):
            raise SppError("SPP's Git is missing (SPP_Classics_V2\\Git). Remove Realms\\Solo and try again.")
        argv = [p.git, "clone", "--progress", "--filter=tree:0", SPP_REPO, SERVER_FOLDER, f"--branch={SPP_BRANCH}"]
        self.report("base", "Downloading the SPP server files (about 700 MB)…", 0.0)
        kw = dict(cwd=p.base, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        if sys.platform == "win32":
            kw["creationflags"] = CREATE_NO_WINDOW
        try:
            proc = self.popen(argv, **kw)
        except OSError as e:
            raise SppError(f"Couldn't start SPP's git ({e}).")
        weights = {"Receiving objects": (0.0, 0.85), "Resolving deltas": (0.85, 0.95),
                   "Updating files": (0.95, 1.0), "Checking out files": (0.95, 1.0)}
        tail = []
        buf = b""
        while True:
            if self.cancel is not None and (self.cancel() if callable(self.cancel) else self.cancel.get("cancel")):
                proc.kill()
                raise Cancelled("Cancelled.")
            ch = proc.stdout.read(256)
            if not ch:
                break
            buf += ch
            parts = re.split(rb"[\r\n]", buf)
            buf = parts.pop()
            for raw in parts:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                tail = (tail + [line])[-5:]
                m = GIT_PROGRESS.search(line)
                if m:
                    lo, hi = weights[m.group(1)]
                    self.report("base", f"Downloading the SPP server files: {m.group(1).lower()} {m.group(2)}%",
                                lo + (hi - lo) * int(m.group(2)) / 100)
        code = proc.wait()
        if code != 0 or not os.path.isfile(p.launcher_bat):
            raise SppError("Downloading the SPP server files failed" + (f": {tail[-1]}" if tail else "")
                           + ". Check your connection and press the button again.")
        tools = os.path.join(p.server, "Server", "Tools")
        for name in ("Server_Update.bat", "Server_Start.bat"):
            if os.path.isfile(os.path.join(tools, name)):
                shutil.copy2(os.path.join(tools, name), os.path.join(p.base, name))
        self.report("base", "SPP server files ready.", 1.0)

    def open_vanilla_setup(self):
        """SPP's own menu, in a console the player can type into (step 4)."""
        if not os.path.isfile(self.p.launcher_bat):
            raise SppError("The SPP server files aren't there yet.")
        if sys.platform == "win32":
            return self.popen(["cmd.exe", "/c", "start", "SPP Classics - set up Vanilla", "/D", self.p.server, "Launcher.bat"],
                              cwd=self.p.server)
        return self.popen(["sh", "-c", "echo Launcher.bat needs Windows"], cwd=self.p.server)


# ---------------------------------------------------------------- run the servers

def is_port_open(port, host="127.0.0.1", timeout=0.5):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def sql_text(v):
    return str(v).replace("\\", "\\\\").replace("'", "''")


class SppServers:
    """SPP's mysqld/realmd/mangosd as hidden processes. Only stops what it started itself."""

    def __init__(self, paths, popen=subprocess.Popen, run=subprocess.run, port_open=is_port_open,
                 sleep=time.sleep, clock=time.monotonic, logs_dir=None, realm_address="127.0.0.1", solo_account=True):
        self.p = paths
        self.realm_address = realm_address   # what realmd tells clients to connect to for the world
        self.solo_account = solo_account     # SOLO / SOLO exists only on a realm nobody else can reach
        self.popen, self.run, self.port_open, self.sleep, self.clock = popen, run, port_open, sleep, clock
        self.procs = {}
        self.logs_dir = logs_dir or paths.logs
        self.db = db_settings(paths)
        self._lock = threading.Lock()

    def _hidden(self):
        return {"creationflags": CREATE_NO_WINDOW} if sys.platform == "win32" else {}

    def _wait(self, name, port, timeout, cancel, report, text):
        start = self.clock()
        while not self.port_open(port):
            if cancel is not None and (cancel() if callable(cancel) else cancel.get("cancel")):
                raise Cancelled("Cancelled.")
            proc = self.procs.get(name)
            if proc is not None and proc.poll() is not None:
                raise SppError(f"{name} stopped while starting (see {self.log_path(name)}).")
            if self.clock() - start > timeout:
                raise SppError(f"{name} didn't start within {int(timeout)} seconds (see {self.log_path(name)}).")
            if report:
                report("start", f"{text} ({int(self.clock() - start)} s)", None)
            self.sleep(1.0)

    def log_path(self, name):
        return os.path.join(self.logs_dir, f"spp-{name}.log")

    def _spawn(self, name, argv, cwd, stdin=subprocess.DEVNULL):
        """Start one server hidden, its output appended to Logs\\spp-<name>.log (our copy of the handle
        is closed right away; the child keeps its own)."""
        os.makedirs(self.logs_dir, exist_ok=True)
        with open(self.log_path(name), "ab") as log:
            log.write(time.strftime("\n===== %Y-%m-%d %H:%M:%S start =====\n").encode())
            log.flush()
            self.procs[name] = self.popen(argv, cwd=cwd, stdin=stdin, stdout=log, stderr=subprocess.STDOUT, **self._hidden())
        return self.procs[name]

    def status(self):
        return {k: self.port_open(v) for k, v in PORTS.items()}

    def mysql(self, sql, db=None, timeout=60):
        host, port, user, pw = self.db
        argv = [self.p.mysql, f"-h{host}", f"-P{port}", f"-u{user}", "--batch", "-e", sql] + ([db] if db else [])
        env = dict(os.environ, MYSQL_PWD=pw)
        r = self.run(argv, capture_output=True, text=True, timeout=timeout, env=env, **self._hidden())
        if r.returncode != 0:
            raise SppError(f"The SPP database refused a command: {(r.stderr or '').strip()[:200]}")
        return r.stdout

    def start(self, report=None, cancel=None, world_timeout=1200):
        """Database, login, world. A service already listening (SPP's own menu started it) is reused."""
        p = self.p
        for f in (p.mysqld, p.realmd, p.mangosd):
            if not os.path.isfile(f):
                raise SppError(f"{os.path.basename(f)} is missing: finish the SPP Vanilla setup first.")
        if not self.port_open(self.db[1]):
            if report:
                report("start", "Starting the database…", None)
            self._spawn("mysqld", [p.mysqld, f"--defaults-file={p.db_ini}", f"--basedir={p.db_dir}",
                                   f"--datadir={os.path.join(p.db_dir, 'data')}", "--standalone",
                                   "--explicit_defaults_for_timestamp", "--log_syslog=0", "--sql-mode="], p.server)
            self._wait("mysqld", self.db[1], 90, cancel, report, "Starting the database")
        self.prepare()
        if not self.port_open(PORTS["realm"]):
            if report:
                report("start", "Starting the login server…", None)
            self._spawn("realmd", [p.realmd, "-c", "realmd.conf"], p.settings)
            self._wait("realmd", PORTS["realm"], 60, cancel, report, "Starting the login server")
        if not self.port_open(PORTS["world"]):
            if report:
                report("start", "Starting the world (the first start creates the bots and takes several minutes)…", None)
            self._spawn("mangosd", [p.mangosd, "-c", "mangosd.conf"], p.settings, stdin=subprocess.PIPE)
            self._wait("mangosd", PORTS["world"], world_timeout, cancel, report, "Starting the world")
        return self.status()

    def prepare(self):
        """realmlist -> the realm address (127.0.0.1 for Solo), and the SOLO / SOLO account for Solo only."""
        import play_local   # SRP6 verifier + the account SQL (cmangos classic schema, same as SPP's)
        if not re.fullmatch(r"[A-Za-z0-9.\-:]{1,253}", self.realm_address or ""):
            raise SppError(f"{self.realm_address!r} isn't a valid realm address.")
        self.mysql(f"UPDATE realmlist SET address='{sql_text(self.realm_address)}';", "classicrealmd")
        if self.solo_account:
            self.mysql(play_local.account_sql(SOLO_ACCOUNT, SOLO_PASSWORD, 0), "classicrealmd")
        else:   # a reachable realm must never keep the well-known Solo login
            self.mysql(f"DELETE FROM account WHERE username='{SOLO_ACCOUNT}';", "classicrealmd")

    def console(self, command):
        """A command on mangosd's console (only for a world server this launcher started)."""
        m = self.procs.get("mangosd")
        if m is None or m.poll() is not None or m.stdin is None:
            raise SppError("The world server's console is only available when Open Vanilla started it.")
        with self._lock:
            m.stdin.write((command.strip() + "\n").encode("utf-8"))
            m.stdin.flush()

    def stop(self, report=None, grace=120):
        """World first (save everyone, then shut down), login, database. Only what this object started."""
        m = self.procs.get("mangosd")
        if m is not None and m.poll() is None:
            if report:
                report("stop", "Saving and stopping the world…", None)
            try:
                self.console("saveall")
                self.console("server shutdown 1")
            except (SppError, OSError):
                m.terminate()
            start = self.clock()
            while m.poll() is None and self.clock() - start < grace:
                self.sleep(1.0)
            if m.poll() is None:
                m.kill()
        r = self.procs.get("realmd")
        if r is not None and r.poll() is None:
            r.terminate()
            start = self.clock()
            while r.poll() is None and self.clock() - start < 15:
                self.sleep(0.5)
            if r.poll() is None:
                r.kill()
        d = self.procs.get("mysqld")
        if d is not None and d.poll() is None:
            if report:
                report("stop", "Stopping the database…", None)
            host, port, user, pw = self.db
            try:
                self.run([self.p.mysqladmin, f"-h{host}", f"-P{port}", f"-u{user}", "shutdown"], capture_output=True,
                         timeout=60, env=dict(os.environ, MYSQL_PWD=pw), **self._hidden())
            except (OSError, subprocess.SubprocessError):
                pass
            start = self.clock()
            while d.poll() is None and self.clock() - start < 60:
                self.sleep(0.5)
            if d.poll() is None:
                d.kill()
        self.procs.clear()


# ---------------------------------------------------------------- one click: play

class SoloPlay:
    """Start the servers, point the client at 127.0.0.1, play, stop. report(stage, text, fraction)."""

    def __init__(self, paths, client_exe, kind="exe", report=None, cancel=None, servers=None, popen=subprocess.Popen,
                 data_folder=None, sleep=time.sleep):
        self.p, self.client, self.kind = paths, client_exe, kind
        self.report = report or (lambda stage, text, frac=None: None)
        self.cancel = cancel
        self.servers = servers or SppServers(paths)
        self.popen = popen
        self.data_folder = data_folder
        self.sleep = sleep
        self.game = None

    def run(self):
        import play_local as P
        if not self.client or not os.path.isfile(self.client):
            raise SppError("Pick your game's Data folder first (Settings).")
        self.servers.start(self.report, self.cancel)
        state = {"ports": {"realm": PORTS["realm"]}}
        restore = None
        try:
            if self.kind == "engine":
                env = P.client_env(state, self.data_folder)
                self.game = self.popen([self.client], cwd=os.path.dirname(self.client), env=env)
            else:
                restore = P.point_client_at_solo(os.path.dirname(self.client), state)
                self.game = self.popen([self.client], cwd=os.path.dirname(self.client))
            self.report("play", f"Playing solo. Log in as {SOLO_ACCOUNT} / {SOLO_PASSWORD}. Close the game to stop the servers.", None)
            while self.game.poll() is None:
                if self.cancel is not None and (self.cancel() if callable(self.cancel) else self.cancel.get("cancel")):
                    break
                self.sleep(1.0)
        finally:
            self.servers.stop(self.report)
            if restore:
                try:
                    restore()
                except OSError:
                    pass
        self.report("done", "Solo stopped. Your characters are saved in Realms\\Solo.", 1.0)
