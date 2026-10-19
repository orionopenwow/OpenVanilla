"""Open Vanilla local play: PLAY SOLO, and the local test realm for hosts.

    py -3 play_local.py                  Play Solo: your own offline world on this PC (the launcher's
    py -3 play_local.py solo             PLAY SOLO button runs exactly this). First run downloads the
                                         solo server pack into OpenVanilla\\solo and extracts maps from your
                                         client; after that it starts the servers in the background,
                                         signs you in and stops everything when the game closes.
        --mmaps                          also generate movement maps (optional, an hour or more)
        --client PATH                    the game to start: WoW.exe, the Open Vanilla engine or the client folder
        --data PATH                      the client folder whose Data the game and the solo server use
                                         (Vanilla Forge's test copy of the game)
        --no-play                        start the solo servers and leave them running (stop: solo-stop)
    py -3 play_local.py solo-stop        stop solo servers left running
    py -3 play_local.py status           is the live realm busy? (what the launcher's banner checks)

  For hosts with SPP Classics (the old local test path, unchanged):
    py -3 play_local.py host             realm on 127.0.0.1 through SPP, web backend, launcher
    py -3 play_local.py lan              realm on this PC's LAN address
    py -3 play_local.py public HOST      realm on HOST plus the HTTPS gateway on https://HOST:8090/

Solo characters stay on this PC: they can't be moved to the live realm.

Everything here is standard library only, so the frozen launcher can import it (launcher_gui.py's
PLAY SOLO button and the player launcher call SoloSession directly; this file's CLI is the same code
with a console progress bar). Windows is the target; the database steps also run on Linux, which is
how the tests exercise them.
"""
import gzip
import hashlib
import http.client
import json
import os
import re
import runpy
import secrets
import shutil
import socket
import string
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.sax.saxutils
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
IS_WINDOWS = sys.platform == "win32"

# ---------------------------------------------------------------- constants

PACK_FORMAT = 1
SOLO_ACCOUNT = "SOLO"
SOLO_PASSWORD = "SOLO"          # local only (every server binds 127.0.0.1); the stock client needs it typed
SOLO_ADMIN = "SOLOADMIN"        # GM 3, random password: only for the SOAP shutdown
SOLO_REALM_NAME = "Open Vanilla Solo"
DEFAULT_PORTS = {"db": 3311, "realm": 3724, "world": 8085, "soap": 7879}
SOLO_MANIFEST_URL = "https://openvanilla.app/downloads/solo.json"
SOLO_PAGE_URL = "https://openvanilla.app/solo.html"
SOLO_NOTE = "Solo characters stay on this PC. They can't be moved to the live realm."
USER_AGENT = "OpenVanilla-Solo/1"

# The pack owns these (replaced on update); everything else under solo\ is the player's.
PACK_DIRS = ("bin", "mariadb", "db", "conf", "sql", "tools")
PACK_FILES = ("README.txt", "pack.json")
DATABASES = ("classicmangos", "classicrealmd", "classiccharacters", "classiclogs")
EXTRACTORS = {"ad": "ad", "vmap_extractor": "vmap_extractor", "vmap_assembler": "vmap_assembler",
              "mmapgen": "MoveMapGen"}

# Windows process flags: background servers get no console window at all.
CREATE_NO_WINDOW = 0x08000000
CREATE_NEW_PROCESS_GROUP = 0x00000200
DETACHED_PROCESS = 0x00000008

# Busy-realm thresholds. /healthz on the realm runs one world-server console command (SOAP) before it
# answers, so its round trip is the world's own responsiveness, not just the network.
SLOW_MS = 1500
DOWN_MS = 8000
FULL_RATIO = 0.95
SLOW_SAMPLES = 2


class SoloError(Exception):
    """A problem to show the player, in plain words."""


class Cancelled(SoloError):
    pass


# ---------------------------------------------------------------- small helpers

def app_dir():
    """The Open Vanilla folder: beside the frozen launcher, or this checkout."""
    return os.path.dirname(os.path.abspath(sys.executable)) if getattr(sys, "frozen", False) else HERE


def _writable(folder):
    try:
        os.makedirs(folder, exist_ok=True)
        probe = os.path.join(folder, ".write-test")
        with open(probe, "w") as f:
            f.write("ok")
        os.remove(probe)
        return True
    except OSError:
        return False


def default_solo_root():
    """OpenVanilla\\solo, or %LOCALAPPDATA%\\OpenVanilla\\solo when the Open Vanilla folder is read-only."""
    env = os.environ.get("OPENVANILLA_SOLO_DIR")
    if env:
        return os.path.abspath(env)
    here = os.path.join(app_dir(), "solo")
    if _writable(here):
        return here
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA") or os.path.expanduser("~")
    old = os.path.join(base, "OpenWoW", "solo")   # a solo folder from before the rename keeps being used
    return old if os.path.isdir(old) else os.path.join(base, "OpenVanilla", "solo")


def is_port_open(port, host="127.0.0.1", timeout=0.5):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def sha256_file(path, cancel=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            if cancel is not None and cancel.is_set():
                raise Cancelled("Cancelled.")
            h.update(block)
    return h.hexdigest()


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def human_size(n):
    for unit in ("bytes", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1024.0


def hidden_popen_kwargs():
    """Popen arguments for a background server: no window on Windows, its own process group."""
    if not IS_WINDOWS:
        return {"start_new_session": True}
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 0  # SW_HIDE
    return {"creationflags": CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, "startupinfo": si}


def hidden_run_kwargs():
    """subprocess.run arguments for a short helper (mariadb client, extractors): no console flash."""
    if not IS_WINDOWS:
        return {}
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 0
    return {"creationflags": CREATE_NO_WINDOW, "startupinfo": si}


def exe_name(name):
    return name + ".exe" if IS_WINDOWS else name


def find_exe(folder, *names):
    """The first of names (with .exe on Windows) that exists in folder, else None. Elsewhere the
    pack's Windows names (mangosd.exe) are accepted too, which is how the tests run a pack on Linux."""
    for n in names:
        for cand in (exe_name(n), n, n + ".exe"):
            p = os.path.join(folder, cand)
            if os.path.isfile(p):
                return p
    return None


# ---------------------------------------------------------------- progress reporting

class Reporter:
    """What the solo steps tell the player. The GUI and the console implement the same four calls."""

    def stage(self, key, text):
        pass

    def progress(self, done, total=None, text=None):
        pass

    def info(self, text):
        pass

    def warn(self, text):
        pass


class ConsoleReporter(Reporter):
    def __init__(self, stream=None):
        self.out = stream or sys.stdout
        self._bar = False
        self._last = 0.0

    def _end_bar(self):
        if self._bar:
            self.out.write("\n")
            self._bar = False

    def stage(self, key, text):
        self._end_bar()
        self.out.write(f"[SOLO] {text}\n")
        self.out.flush()

    def progress(self, done, total=None, text=None):
        now = time.monotonic()
        if total and done < total and now - self._last < 0.2:
            return
        self._last = now
        if total:
            frac = max(0.0, min(1.0, done / total))
            bar = "#" * int(frac * 30)
            line = f"  [{bar:<30}] {frac * 100:5.1f}%  {text or ''}"
        else:
            line = f"  {text or ''}"
        self.out.write("\r" + line[:110].ljust(110))
        self.out.flush()
        self._bar = True

    def info(self, text):
        self._end_bar()
        self.out.write(f"       {text}\n")
        self.out.flush()

    def warn(self, text):
        self._end_bar()
        self.out.write(f"[SOLO] ! {text}\n")
        self.out.flush()


def check_cancel(cancel):
    if cancel is not None and cancel.is_set():
        raise Cancelled("Cancelled.")


# ---------------------------------------------------------------- the solo folder

class SoloPaths:
    def __init__(self, root=None):
        self.root = os.path.abspath(root or default_solo_root())
        j = lambda *p: os.path.join(self.root, *p)
        self.bin = j("bin")
        self.tools = j("bin", "tools")
        self.mariadb = j("mariadb")
        self.mariadb_bin = j("mariadb", "bin")
        self.db_seed = j("db")
        self.conf = j("conf")
        self.sql = j("sql")
        self.sql_live = j("sql-live")
        self.pytools = j("tools")
        self.data = j("data")
        self.gamedata = j("gamedata")
        self.etc = j("etc")
        self.custom = j("custom")
        # Open Vanilla Forge's Test & Play drops a pack's dev SQL here (forge_dev_<pack>.sql); it
        # runs like the Classic+ files, after them
        self.forge_dev = j("forge-dev")
        self.logs = j("logs")
        self.download = j("download")
        self.state_file = j("state.json")
        self.run_file = j("run.json")
        self.pack_json = j("pack.json")

    def templates_dir(self):
        """The repo's solo/templates in a dev checkout (edit and relaunch), else the pack's conf/."""
        dev = os.path.join(self.root, "templates")
        return dev if os.path.isdir(dev) else self.conf

    def pack_installed(self):
        return os.path.isfile(self.pack_json) and os.path.isfile(find_exe(self.bin, "mangosd") or "")


def load_state(paths):
    st = read_json(paths.state_file, {}) or {}
    changed = False
    for key in ("db_root_password", "db_password", "soap_password"):
        if not re.fullmatch(r"[0-9a-f]{32}", str(st.get(key, ""))):
            st[key] = secrets.token_hex(16)  # hex only: safe inside SQL text and conf files
            changed = True
    st.setdefault("format", 1)
    st.setdefault("ports", dict(DEFAULT_PORTS))
    for k, v in DEFAULT_PORTS.items():
        st["ports"].setdefault(k, v)
    if changed or not os.path.isfile(paths.state_file):
        write_json(paths.state_file, st)
    return st


def save_state(paths, st):
    write_json(paths.state_file, st)


# ---------------------------------------------------------------- manifest + download + unpack

def fetch_json(url, timeout=10, opener=None):
    opener = opener or urllib.request.urlopen
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Cache-Control": "no-cache"})
    with opener(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def validate_manifest(m):
    """The launcher's view of the pack (www/downloads/solo.json, written by tools/build_solo_pack.py)."""
    if not isinstance(m, dict) or m.get("format") != PACK_FORMAT:
        raise SoloError("The solo pack information online is from a newer launcher. Update Open Vanilla first.")
    for key in ("version", "url", "sha256", "size"):
        if not m.get(key):
            raise SoloError(f"The solo pack information online is incomplete (no {key}).")
    if not re.fullmatch(r"[0-9a-f]{64}", str(m["sha256"]).lower()):
        raise SoloError("The solo pack information online has a bad checksum.")
    if urllib.parse.urlsplit(m["url"]).scheme not in ("https", "file") and not m["url"].startswith("http://127.0.0.1"):
        raise SoloError("The solo pack address must be https.")
    return m


def download(url, dest, sha256=None, size=None, reporter=None, cancel=None, opener=None,
             chunk=1 << 20, retries=4, sleep=time.sleep, label="Downloading"):
    """Download url to dest, resuming dest.part with an HTTP Range request, then check size and SHA-256.

    A server that ignores Range (200 instead of 206) restarts the file; a dropped connection retries
    from where it stopped. A checksum mismatch deletes the partial file so the next try starts clean."""
    reporter = reporter or Reporter()
    opener = opener or urllib.request.urlopen
    part = dest + ".part"
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    if os.path.isfile(dest) and sha256 and sha256_file(dest, cancel) == sha256.lower():
        return dest  # already here and good
    attempt = 0
    while True:
        check_cancel(cancel)
        have = os.path.getsize(part) if os.path.isfile(part) else 0
        if size and have > size:
            os.remove(part)
            have = 0
        if size and have == size:
            break
        headers = {"User-Agent": USER_AGENT}
        if have:
            headers["Range"] = f"bytes={have}-"
        try:
            resp = opener(urllib.request.Request(url, headers=headers), timeout=30)
        except urllib.error.HTTPError as e:
            if e.code == 416 and have:  # nothing left to send: the part is complete
                break
            if e.code in (404, 410):
                raise SoloError(f"The solo pack isn't on the download server ({e.code}). Try again later.")
            if attempt >= retries:
                raise SoloError(f"The download failed ({e.code} {e.reason}). Try again later.")
            attempt += 1
            sleep(min(2 ** attempt, 20))
            continue
        except (urllib.error.URLError, OSError) as e:
            if attempt >= retries:
                raise SoloError(f"Can't reach the download server ({getattr(e, 'reason', e)}). "
                                "Check your connection and press Play Solo again: the download picks up where it stopped.")
            attempt += 1
            sleep(min(2 ** attempt, 20))
            continue
        with resp:
            status = getattr(resp, "status", None) or resp.getcode()
            mode = "ab"
            if have and status == 200:
                have, mode = 0, "wb"  # the server ignored Range: start over
            elif status == 206:
                m = re.match(r"bytes (\d+)-", resp.headers.get("Content-Range", "") or "")
                if not m or int(m.group(1)) != have:
                    have, mode = 0, "wb"
                    resp.close()
                    if os.path.isfile(part):
                        os.remove(part)
                    continue
            elif not have:
                mode = "wb"
            length = resp.headers.get("Content-Length")
            total = size or (have + int(length) if length and length.isdigit() else None)
            done = have
            try:
                with open(part, mode) as f:
                    while True:
                        check_cancel(cancel)
                        block = resp.read(chunk)
                        if not block:
                            break
                        f.write(block)
                        done += len(block)
                        reporter.progress(done, total, f"{label}: {human_size(done)}" + (f" of {human_size(total)}" if total else ""))
            except (OSError, http.client.IncompleteRead, socket.timeout):
                if attempt >= retries:
                    raise SoloError("The download stopped. Press Play Solo again: it picks up where it stopped.")
                attempt += 1
                sleep(min(2 ** attempt, 20))
                continue
        if size is None or os.path.getsize(part) >= size:
            break
        # Short read without an error: loop and ask for the rest.
        attempt += 1
        if attempt > retries:
            raise SoloError("The download stopped early. Press Play Solo again: it picks up where it stopped.")
    got = os.path.getsize(part) if os.path.isfile(part) else 0
    if size and got != size:
        os.remove(part)
        raise SoloError("The download came out the wrong size. Press Play Solo to download it again.")
    if sha256:
        reporter.progress(0, None, "Checking the download…")
        if sha256_file(part, cancel) != sha256.lower():
            os.remove(part)
            raise SoloError("The download was damaged (checksum mismatch) and has been removed. Press Play Solo to download it again.")
    os.replace(part, dest)
    return dest


def _safe_member(name):
    """The member's path parts, or None for anything that would escape the folder."""
    name = name.replace("\\", "/")
    if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
        return None
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return None
    return parts


def verify_pack_files(root, pack, cancel=None, reporter=None):
    """Check every file pack.json lists (size + SHA-256). Returns the list of bad paths."""
    bad = []
    files = pack.get("files", {})
    total = sum(int(v.get("size", 0)) for v in files.values()) or 1
    done = 0
    for rel, meta in sorted(files.items()):
        check_cancel(cancel)
        parts = _safe_member(rel)
        p = os.path.join(root, *parts) if parts else None
        if not p or not os.path.isfile(p) or os.path.getsize(p) != int(meta.get("size", -1)) \
                or sha256_file(p, cancel) != meta.get("sha256"):
            bad.append(rel)
        done += int(meta.get("size", 0))
        if reporter:
            reporter.progress(done, total, "Checking files…")
    return bad


def unpack_pack(zip_path, paths, reporter=None, cancel=None):
    """Unpack the pack zip into solo\\: into a staging folder first, verify it, then swap the pack's
    own folders in. The player's data (data, gamedata, custom, logs, state.json) is never touched."""
    reporter = reporter or Reporter()
    root = paths.root
    os.makedirs(root, exist_ok=True)
    staging = os.path.join(root, ".staging")
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)
    try:
        with zipfile.ZipFile(zip_path) as z:
            members = [m for m in z.infolist() if not m.is_dir()]
            total = sum(m.file_size for m in members) or 1
            done = 0
            for m in members:
                check_cancel(cancel)
                parts = _safe_member(m.filename)
                if parts is None:
                    raise SoloError(f"The solo pack has an unsafe file name ({m.filename}); it was not unpacked.")
                if parts[0] not in PACK_DIRS and not (len(parts) == 1 and parts[0] in PACK_FILES):
                    raise SoloError(f"The solo pack has an unexpected file ({m.filename}); it was not unpacked.")
                out = os.path.join(staging, *parts)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                with z.open(m) as src, open(out, "wb") as dst:
                    while True:
                        block = src.read(1 << 20)
                        if not block:
                            break
                        dst.write(block)
                        done += len(block)
                        reporter.progress(done, total, f"Unpacking: {human_size(done)} of {human_size(total)}")
        pack = read_json(os.path.join(staging, "pack.json"))
        if not isinstance(pack, dict) or pack.get("format") != PACK_FORMAT:
            raise SoloError("The solo pack is missing its file list (pack.json); it was not installed.")
        bad = verify_pack_files(staging, pack, cancel, reporter)
        if bad:
            raise SoloError(f"{len(bad)} file(s) in the solo pack failed their checksum (first: {bad[0]}). "
                            "Press Play Solo to download it again.")
        # Swap: move the old pack folders aside, the new ones in, then delete the old ones.
        old = os.path.join(root, ".old")
        shutil.rmtree(old, ignore_errors=True)
        os.makedirs(old)
        for name in PACK_DIRS + PACK_FILES:
            cur = os.path.join(root, name)
            if os.path.exists(cur):
                try:
                    os.replace(cur, os.path.join(old, name))
                except OSError as e:
                    raise SoloError(f"Can't replace solo\\{name} ({e.strerror}). Is a solo server still running? "
                                    "Close the game and the launcher, then try again.")
        if not IS_WINDOWS:  # zip entries carry no exec bit; only matters off Windows
            for folder in ("bin", os.path.join("mariadb", "bin")):
                for dirpath, _dirs, names in os.walk(os.path.join(staging, folder)):
                    for n in names:
                        os.chmod(os.path.join(dirpath, n), 0o755)
        for name in PACK_DIRS + PACK_FILES:
            src = os.path.join(staging, name)
            if os.path.exists(src):
                os.replace(src, os.path.join(root, name))
        shutil.rmtree(old, ignore_errors=True)
        return pack
    finally:
        shutil.rmtree(staging, ignore_errors=True)


# ---------------------------------------------------------------- config files

def render_template(text, values):
    """${NAME} placeholders; an unknown name in a setting is an error, not an empty string.
    Comment lines may mention ${NAME} freely."""
    out = []
    for line in text.splitlines():
        t = string.Template(line)
        out.append(t.safe_substitute(values) if line.lstrip().startswith("#") else t.substitute(values))
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def parse_overrides(text):
    """'Key = Value' lines (comments and blanks skipped), in order."""
    out = []
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("[") or "=" not in s:
            continue
        k, _, v = s.partition("=")
        out.append((k.strip(), v.strip()))
    return out


def apply_overrides(dist_text, overrides):
    """Set each key in a CMaNGOS .conf: replace the first active 'Key = …' line, else uncomment the
    first '# Key = …' line, else append. Other lines (and every comment) stay exactly as they were."""
    lines = dist_text.splitlines()
    appended = []
    for key, value in overrides:
        k = re.escape(key)
        active = re.compile(rf"^\s*{k}\s*=")
        commented = re.compile(rf"^\s*#\s*{k}\s*=")
        new = f"{key} = {value}"
        idx = next((i for i, l in enumerate(lines) if active.match(l)), None)
        if idx is None:
            idx = next((i for i, l in enumerate(lines) if commented.match(l)), None)
        if idx is None:
            appended.append(new)
        else:
            lines[idx] = new
    if appended:
        lines += ["", "# Open Vanilla Solo"] + appended
    return "\n".join(lines) + "\n"


def conf_path(p):
    """Paths inside .conf/.ini files: forward slashes work for CMaNGOS and MariaDB on Windows."""
    return os.path.abspath(p).replace("\\", "/")


def mariadb_basedir(paths):
    """solo\\mariadb. Elsewhere (the tests on Linux) the pack's bin may only wrap a system MariaDB:
    then its install prefix, where the share files are."""
    if IS_WINDOWS or os.path.isdir(os.path.join(paths.mariadb, "share", "english")):
        return paths.mariadb
    server = find_exe(paths.mariadb_bin, "mariadbd", "mysqld")
    if server and os.path.islink(server):
        return os.path.dirname(os.path.dirname(os.path.realpath(server)))
    system = shutil.which("mariadbd") or ("/usr/sbin/mariadbd" if os.path.isfile("/usr/sbin/mariadbd") else None)
    return os.path.dirname(os.path.dirname(os.path.realpath(system))) if system else paths.mariadb


def config_values(paths, state):
    ports = state["ports"]
    return {
        "DB_PORT": ports["db"], "REALM_PORT": ports["realm"], "WORLD_PORT": ports["world"],
        "SOAP_PORT": ports["soap"], "DB_PASSWORD": state["db_password"],
        "GAMEDATA": conf_path(paths.gamedata) + "/", "LOGS": conf_path(paths.logs),
        "DATA": conf_path(paths.data), "MARIADB": conf_path(mariadb_basedir(paths)),
        "MMAPS": "1" if has_mmaps(paths.gamedata) else "0",
    }


def write_configs(paths, state):
    """etc\\*.conf from the pack's *.conf.dist + our overrides + the player's custom\\*.conf, and
    etc\\my.ini. Returns the server config files that exist (by name), for the command lines."""
    os.makedirs(paths.etc, exist_ok=True)
    os.makedirs(paths.logs, exist_ok=True)
    values = config_values(paths, state)
    tdir = paths.templates_dir()
    written = {}
    for name in ("mangosd.conf", "realmd.conf", "aiplayerbot.conf", "ahbot.conf", "anticheat.conf"):
        dist = os.path.join(paths.bin, name + ".dist")
        if not os.path.isfile(dist):
            continue
        with open(dist, encoding="utf-8", errors="replace") as f:
            text = f.read()
        ours = os.path.join(tdir, name + ".overrides")
        if os.path.isfile(ours):
            with open(ours, encoding="utf-8") as f:
                text = apply_overrides(text, parse_overrides(render_template(f.read(), values)))
        mine = os.path.join(paths.custom, name)
        if os.path.isfile(mine):
            with open(mine, encoding="utf-8", errors="replace") as f:
                text = apply_overrides(text, parse_overrides(f.read()))
        out = os.path.join(paths.etc, name)
        with open(out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        written[name] = out
    with open(os.path.join(tdir, "my.ini"), encoding="utf-8") as f:
        ini = render_template(f.read(), values)
    with open(os.path.join(paths.etc, "my.ini"), "w", encoding="utf-8", newline="\n") as f:
        f.write(ini)
    written["my.ini"] = os.path.join(paths.etc, "my.ini")
    return written


# ---------------------------------------------------------------- game data (maps)

def _nonempty(folder, pattern=None):
    try:
        names = os.listdir(folder)
    except OSError:
        return False
    return any(re.search(pattern, n, re.I) for n in names) if pattern else bool(names)


def has_gamedata(folder):
    """dbc + maps + vmaps: what mangosd needs. mmaps are optional for solo."""
    return bool(folder) and _nonempty(os.path.join(folder, "dbc"), r"\.dbc$") \
        and _nonempty(os.path.join(folder, "maps"), r"\.map$") \
        and _nonempty(os.path.join(folder, "vmaps"), r"\.vmtree$")


def has_mmaps(folder):
    return _nonempty(os.path.join(folder, "mmaps"), r"\.mmap$")


def gamedata_candidates(paths, client_dir=None, extra=()):
    """Map data the player may already have: solo\\gamedata, OPENVANILLA_GAMEDATA, the client folder
    (CMaNGOS's extractors write next to themselves), a local Open Vanilla server, an SPP install."""
    out = [paths.gamedata]
    if os.environ.get("OPENVANILLA_GAMEDATA"):
        out.append(os.environ["OPENVANILLA_GAMEDATA"])
    out += list(extra)
    if client_dir:
        out += [client_dir, os.path.join(client_dir, "server-data")]
    out.append(os.path.join(app_dir(), "gamedata"))
    spp = os.environ.get("SPP_ROOT", os.path.join(os.path.expanduser("~"), "Desktop", "Games", "SPP_Classics_V2", "SPP_Server"))
    out += [os.path.join(spp, "Server", "Data", "vanilla"), os.path.join(spp, "Server", "Data")]
    seen, uniq = set(), []
    for p in out:
        k = os.path.normcase(os.path.abspath(p))
        if k not in seen:
            seen.add(k)
            uniq.append(p)
    return uniq


def link_dir(src, dst):
    """dst -> src without copying: a directory junction on Windows (no admin rights needed), a
    symlink elsewhere."""
    if os.path.lexists(dst):
        return
    if IS_WINDOWS:
        r = subprocess.run(["cmd", "/c", "mklink", "/J", dst, src], capture_output=True, text=True, **hidden_run_kwargs())
        if r.returncode != 0:
            raise SoloError(f"Can't link {src} into the solo folder: {(r.stdout + r.stderr).strip()}")
    else:
        os.symlink(src, dst, target_is_directory=True)


def adopt_gamedata(src, paths):
    """Reuse map data found elsewhere: copy dbc (small; solo patches it) and link maps/vmaps/mmaps."""
    os.makedirs(paths.gamedata, exist_ok=True)
    dbc_dst = os.path.join(paths.gamedata, "dbc")
    if not os.path.isdir(dbc_dst):
        shutil.copytree(os.path.join(src, "dbc"), dbc_dst)
    for d in ("maps", "vmaps", "mmaps", "Cameras"):
        s = os.path.join(src, d)
        if os.path.isdir(s):
            link_dir(os.path.abspath(s), os.path.join(paths.gamedata, d))


def client_root(folder):
    """The 1.12 client folder, also when the player picked its Data folder."""
    if folder and os.path.basename(os.path.normpath(folder)).lower() == "data" and not os.path.isdir(os.path.join(folder, "Data")):
        return os.path.dirname(os.path.normpath(folder))
    return folder


def client_has_mpqs(client_dir):
    data = os.path.join(client_dir or "", "Data")
    if not os.path.isdir(data):
        return False
    for _root, _dirs, files in os.walk(data):
        if any(f.lower().endswith(".mpq") for f in files):
            return True
    return False


def _stream_lines(proc, on_line, cancel):
    buf = b""
    while True:
        if cancel is not None and cancel.is_set():
            proc.kill()
            raise Cancelled("Cancelled.")
        chunk = proc.stdout.read1(4096) if hasattr(proc.stdout, "read1") else proc.stdout.read(4096)
        if not chunk:
            break
        buf += chunk
        while True:
            m = re.search(rb"[\r\n]", buf)
            if not m:
                break
            line, buf = buf[:m.start()], buf[m.end():]
            if line.strip():
                on_line(line.decode("utf-8", "replace"))
    if buf.strip():
        on_line(buf.decode("utf-8", "replace"))
    return proc.wait()


def run_extractors(client_dir, out_dir, tools_dir, reporter=None, cancel=None, mmaps=False,
                   popen=subprocess.Popen, threads=None, log_path=None):
    """CMaNGOS's extractors on the player's own client: dbc + maps, vmaps, then (optional) mmaps.
    Progress comes from the tools' own output ('Extract <map> (i/n)', 'Processing Map <id>')."""
    reporter = reporter or Reporter()
    client_dir = client_root(client_dir)
    tools = {k: find_exe(tools_dir, v) for k, v in EXTRACTORS.items()}
    missing = [EXTRACTORS[k] for k in ("ad", "vmap_extractor", "vmap_assembler") if not tools[k]]
    if missing:
        raise SoloError("The solo pack is missing the map extractors (" + ", ".join(exe_name(m) for m in missing)
                        + "). Delete the solo folder's bin folder and press Play Solo to download it again.")
    if not client_has_mpqs(client_dir):
        raise SoloError(f"No game data (.MPQ files) under {os.path.join(client_dir or '?', 'Data')}. "
                        "Point the launcher at your World of Warcraft 1.12.1 folder in Settings.")
    os.makedirs(out_dir, exist_ok=True)
    log = open(log_path, "a", encoding="utf-8") if log_path else None
    state = {"maps": 0, "vmaps_done": 0}

    def run(stage_text, argv, cwd, on_line, weight_from, weight_to):
        reporter.stage("extract", stage_text)
        if log:
            log.write(f"\n== {' '.join(argv)}\n")
        proc = popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                     **hidden_run_kwargs())

        def line_cb(line):
            if log:
                log.write(line + "\n")
            frac = on_line(line)
            if frac is not None:
                reporter.progress(weight_from + (weight_to - weight_from) * frac, 100, stage_text)

        code = _stream_lines(proc, line_cb, cancel)
        if code != 0:
            raise SoloError(f"{os.path.basename(argv[0])} stopped with an error (exit {code}). "
                            f"Details: {log_path or 'its output'}")

    def ad_line(line):
        m = re.search(r"Done! \((\d+) maps loaded\)", line)
        if m:
            state["maps"] = int(m.group(1))
        m = re.search(r"Extract \S+ \((\d+)/(\d+)\)", line)
        if m:
            return int(m.group(1)) / max(1, int(m.group(2)))
        return None

    def vmap_line(line):
        if line.startswith("Processing Map"):
            state["vmaps_done"] += 1
            return min(1.0, state["vmaps_done"] / max(1, state["maps"] or 40))
        return None

    try:
        run("Reading maps from your game client (1 of 3)…", [tools["ad"], "-i", client_dir, "-o", out_dir],
            out_dir, ad_line, 0, 35)
        run("Reading buildings from your game client (2 of 3)…",
            [tools["vmap_extractor"], "-d", os.path.join(client_dir, "Data"), "-o", out_dir], out_dir, vmap_line, 35, 85)
        os.makedirs(os.path.join(out_dir, "vmaps"), exist_ok=True)
        run("Assembling building data (3 of 3)…",
            [tools["vmap_assembler"], os.path.join(out_dir, "Buildings"), os.path.join(out_dir, "vmaps")],
            out_dir, lambda _l: None, 85, 100)
        shutil.rmtree(os.path.join(out_dir, "Buildings"), ignore_errors=True)
        if mmaps:
            build_mmaps(out_dir, tools_dir, reporter, cancel, popen, log)
    finally:
        if log:
            log.close()
    if not has_gamedata(out_dir):
        raise SoloError(f"The extractors finished but the map data is incomplete. Details: {log_path or out_dir}")


def build_mmaps(gamedata, tools_dir, reporter=None, cancel=None, popen=subprocess.Popen, log=None):
    """Movement maps (optional for solo): MoveMapGen reads maps + vmaps from its workdir and writes
    mmaps there. Into a temporary mmaps folder first, so a cancelled run leaves no half set behind."""
    reporter = reporter or Reporter()
    gen = find_exe(tools_dir, EXTRACTORS["mmapgen"])
    if not gen:
        reporter.warn("This solo pack has no movement map generator; creatures will walk in straight lines.")
        return False
    final = os.path.join(gamedata, "mmaps")
    if has_mmaps(gamedata):
        return True
    if os.path.lexists(final):
        os.remove(final) if os.path.islink(final) else shutil.rmtree(final, ignore_errors=True)
    os.makedirs(final)
    reporter.stage("extract", "Building movement maps (this takes an hour or more; you can stop and resume later)…")
    argv = [gen, "--workdir", gamedata.rstrip("\\/") + os.sep, "--threads", str(max(1, (os.cpu_count() or 2) - 1)),
            "--buildGameObjects"]
    for opt, fname in (("--offMeshInput", "offmesh.txt"), ("--configInputPath", "config.json")):
        if os.path.isfile(os.path.join(tools_dir, fname)):
            argv += [opt, os.path.join(tools_dir, fname)]
    proc = popen(argv, cwd=tools_dir, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                 **hidden_run_kwargs())
    tiles = {"n": 0}

    def on_line(line):
        if log:
            log.write(line + "\n")
        if "mmtile" in line.lower() or line.startswith("[Map"):
            tiles["n"] += 1
            reporter.progress(tiles["n"], None, f"Movement maps: {tiles['n']} pieces built…")

    code = _stream_lines(proc, on_line, cancel)
    if code != 0 or not has_mmaps(gamedata):
        shutil.rmtree(final, ignore_errors=True)
        raise SoloError("Building the movement maps failed. Solo works without them (creatures walk in straight lines).")
    return True


def dbc_file(folder, name):
    try:
        for n in os.listdir(folder):
            if n.lower() == name.lower():
                return os.path.join(folder, n)
    except OSError:
        pass
    return None


def run_script(path, argv, log_path=None):
    """Run one of our Python tools in this process (the frozen launcher has no separate python.exe),
    its output going to log_path."""
    import contextlib
    old = sys.argv
    sys.argv = [path] + list(argv)
    if log_path:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
    out = open(log_path, "a", encoding="utf-8") if log_path else open(os.devnull, "w")
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            runpy.run_path(path, run_name="__main__")
        return 0
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    finally:
        sys.argv = old
        out.close()


def fix_server_dbcs(paths, pairs_text, reporter=None, script_dirs=None):
    """The same server DBC fix-ups the live realm runs (hetzner/openvanilla_realm_up.sh, openvanilla_server_dbc.sh):
    starting gear and weapon skills for every Classic+ race/class pair. Always from the stock file
    (kept as .orig), so it is safe to run on every launch."""
    reporter = reporter or Reporter()
    dbc_dir = os.path.join(paths.gamedata, "dbc")
    dirs = list(script_dirs or [paths.pytools, os.path.join(HERE, "realm", "classicplus")])
    find = lambda n: next((os.path.join(d, n) for d in dirs if os.path.isfile(os.path.join(d, n))), None)
    gen, fix = find("gen_outfits.py"), find("fix_skillraceclassinfo.py")
    weapons = next((p for p in sql_candidates(paths).get("classicplus_weapons.sql", [])), None)
    done = []
    for name, script, extra in (("CharStartOutfit.dbc", gen, []),
                                ("SkillRaceClassInfo.dbc", fix, None)):
        live = dbc_file(dbc_dir, name)
        if not live or not script:
            continue
        orig = live + ".orig"
        if not os.path.isfile(orig):
            shutil.copy2(live, orig)
        tmp = live + ".new"
        if extra is None:
            pairs = os.path.join(paths.etc, "pairs.txt")
            os.makedirs(paths.etc, exist_ok=True)
            with open(pairs, "w") as f:
                f.write(pairs_text)
            extra = ["--combos", pairs] + (["--sql", weapons] if weapons else [])
        code = run_script(script, [orig, tmp] + extra, os.path.join(paths.logs, "dbc-fixups.log"))
        if os.path.isfile(tmp):
            os.replace(tmp, live)
            done.append(name)
        elif code:
            reporter.warn(f"Couldn't update {name} for the Classic+ race/class pairs (exit {code}).")
    return done


# ---------------------------------------------------------------- the database

class SoloDB:
    """The portable MariaDB: install the data folder, start/stop it hidden, run SQL as root."""

    def __init__(self, paths, state, popen=subprocess.Popen, run=subprocess.run, port_open=is_port_open,
                 sleep=time.sleep):
        self.paths, self.state = paths, state
        self.popen, self.runner, self.port_open, self.sleep = popen, run, port_open, sleep
        self.proc = None
        b = paths.mariadb_bin
        self.server = find_exe(b, "mariadbd", "mysqld")
        self.client = find_exe(b, "mariadb", "mysql")
        self.admin = find_exe(b, "mariadb-admin", "mysqladmin")
        self.install = find_exe(b, "mariadb-install-db", "mysql_install_db")

    @property
    def port(self):
        return int(self.state["ports"]["db"])

    def _env(self):
        return dict(os.environ, MYSQL_PWD=self.state["db_root_password"])

    def client_args(self, db=None):
        args = [self.client, "--no-defaults", "--protocol=TCP", "--host=127.0.0.1", f"--port={self.port}",
                "--user=root", "--batch", "--skip-column-names", "--default-character-set=utf8mb4"]
        return args + ([db] if db else [])

    def initialized(self):
        return os.path.isdir(os.path.join(self.paths.data, "mysql"))

    def initialize(self, reporter=None):
        """A fresh data folder with our root password (no service, no admin rights)."""
        if not (self.server and self.client and self.install):
            raise SoloError("The solo pack's database files are missing. Delete solo\\mariadb and press Play Solo again.")
        os.makedirs(self.paths.logs, exist_ok=True)
        if IS_WINDOWS:  # mariadb-install-db.exe: the Windows tool (not the Unix script)
            # --allow-remote-root-access adds root@'%' with the same password, so a TCP login from
            # 127.0.0.1 matches whatever the name resolves to; bind-address=127.0.0.1 keeps it local.
            argv = [self.install, f"--datadir={self.paths.data}", f"--password={self.state['db_root_password']}",
                    f"--port={self.port}", "--allow-remote-root-access", "--silent"]
        else:  # Linux (tests, and anyone running solo there): the shell script, socket auth off
            argv = [self.install, "--no-defaults", f"--datadir={self.paths.data}", f"--basedir={mariadb_basedir(self.paths)}",
                    "--auth-root-authentication-method=normal", "--skip-test-db"]
            if os.geteuid() == 0:
                argv.append("--user=root")
        r = self.runner(argv, capture_output=True, text=True, cwd=self.paths.mariadb, **hidden_run_kwargs())
        if r.returncode != 0:
            shutil.rmtree(self.paths.data, ignore_errors=True)
            raise SoloError("Couldn't set up the solo database: " + (r.stderr or r.stdout or "").strip()[-400:])
        self._linux_needs_password = not IS_WINDOWS

    def start(self, timeout=90, cancel=None):
        if self.port_open(self.port):
            if self.ping():
                return False  # ours, already running (a launcher crash left it up)
            raise SoloError(f"Another program is using port {self.port}, which the solo database needs.")
        argv = [self.server, f"--defaults-file={os.path.join(self.paths.etc, 'my.ini')}", "--console"]
        if not IS_WINDOWS:
            argv.append(f"--socket={os.path.join(self.paths.data, 'mysqld.sock')}")
            if os.geteuid() == 0:
                argv.append("--user=root")
        log = open(os.path.join(self.paths.logs, "mariadb.out"), "a", encoding="utf-8")
        try:
            self.proc = self.popen(argv, cwd=self.paths.mariadb, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, **hidden_popen_kwargs())
        finally:
            log.close()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            check_cancel(cancel)
            if self.proc.poll() is not None:
                raise SoloError("The solo database stopped while starting. Details: solo\\logs\\mariadb.err")
            if self.port_open(self.port):
                if getattr(self, "_linux_needs_password", False):
                    self._set_root_password()
                if self.ping():
                    return True
            self.sleep(0.5)
        raise SoloError("The solo database didn't start in time. Details: solo\\logs\\mariadb.err")

    def _set_root_password(self):
        """Linux install-db leaves root without a password; give it ours (once)."""
        pw = self.state["db_root_password"]
        sql = "".join(f"ALTER USER IF EXISTS 'root'@'{h}' IDENTIFIED BY '{pw}';" for h in ("localhost", "127.0.0.1", "::1"))
        r = self.runner(self.client_args(), input=sql + "FLUSH PRIVILEGES;", capture_output=True, text=True,
                        env=dict(os.environ, MYSQL_PWD=""))
        self._linux_needs_password = False
        return r.returncode == 0

    def ping(self):
        try:
            return self.query("SELECT 1").strip() == "1"
        except SoloError:
            return False

    def query(self, sql, db=None, timeout=600):
        r = self.runner(self.client_args(db), input=sql, capture_output=True, text=True, env=self._env(),
                        timeout=timeout, **hidden_run_kwargs())
        if r.returncode != 0:
            raise SoloError((r.stderr or "the database refused the query").strip()[-500:])
        return r.stdout

    def import_file(self, path, db, reporter=None, cancel=None, label=None):
        """Stream a .sql or .sql.gz into db, with progress by bytes read."""
        reporter = reporter or Reporter()
        size = os.path.getsize(path) or 1
        raw = open(path, "rb")
        src = gzip.GzipFile(fileobj=raw) if path.endswith(".gz") else raw
        err = open(os.path.join(self.paths.logs, "import.err"), "wb")
        proc = self.popen(self.client_args(db), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=err,
                          env=self._env(), **hidden_run_kwargs())
        try:
            while True:
                if cancel is not None and cancel.is_set():
                    proc.kill()
                    raise Cancelled("Cancelled.")
                block = src.read(1 << 20)
                if not block:
                    break
                proc.stdin.write(block)
                reporter.progress(raw.tell(), size, label or f"Loading {db}")
            proc.stdin.close()
            code = proc.wait()
        except BrokenPipeError:
            code = proc.wait()
        finally:
            src.close()
            raw.close()
            err.close()
        if code != 0:
            with open(os.path.join(self.paths.logs, "import.err"), encoding="utf-8", errors="replace") as f:
                detail = f.read().strip()[-400:]
            raise SoloError(f"Loading {os.path.basename(path)} into the solo database failed: {detail}")

    def shutdown(self, timeout=60):
        if self.admin and self.port_open(self.port):
            self.runner([self.admin, "--no-defaults", "--protocol=TCP", "--host=127.0.0.1", f"--port={self.port}",
                         "--user=root", "shutdown"], capture_output=True, env=self._env(), timeout=timeout,
                        **hidden_run_kwargs())
        if self.proc is not None:
            try:
                self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None


def sql_text(v):
    """Last guard before a value goes into SQL text: letters, digits, spaces and a little punctuation."""
    v = str(v)
    if not re.fullmatch(r"[A-Za-z0-9 .:()_+-]{0,64}", v):
        raise ValueError("unsafe SQL value")
    return v


# The 1.12.1 SRP6 group (same as server_control.generate_srp6, which the host panel has used for years).
SRP_N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
SRP_G = 7


def srp6_verifier(username, password, salt=None):
    """(s, v) as CMaNGOS stores them: upper-case hex, big-endian. The wire salt is s reversed."""
    salt = salt if salt is not None else os.urandom(32)
    h1 = hashlib.sha1(f"{username.upper()}:{password.upper()}".encode()).digest()  # nosec B324 - mandated by the 1.12 protocol
    x = int.from_bytes(hashlib.sha1(salt[::-1] + h1).digest(), "little")  # nosec B324
    v = pow(SRP_G, x, SRP_N)
    return salt.hex().upper(), v.to_bytes(32, "little")[::-1].hex().upper()


def account_sql(username, password, gmlevel, salt=None):
    user = sql_text(username.upper())
    s, v = srp6_verifier(user, password, salt)
    return (f"INSERT INTO account (username, s, v, gmlevel) VALUES ('{user}', '{s}', '{v}', {int(gmlevel)}) "
            f"ON DUPLICATE KEY UPDATE s='{s}', v='{v}', gmlevel={int(gmlevel)};")


def realmlist_sql(state):
    p = state["ports"]
    return ("INSERT INTO realmlist (id,name,address,port,icon,realmflags,timezone,allowedSecurityLevel,population,realmbuilds) "
            f"VALUES (1,'{sql_text(SOLO_REALM_NAME)}','127.0.0.1',{int(p['world'])},0,0,8,0,0,'5875') "
            f"ON DUPLICATE KEY UPDATE name=VALUES(name), address='127.0.0.1', port={int(p['world'])}, "
            "realmflags=0, realmbuilds='5875';")


# ---------------------------------------------------------------- SQL updates (same files as the live realm)

def sql_target_db(path):
    """realm/classicplus files say '(run against classicrealmd …)' in their header; default classicmangos."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = f.read(2000)
    except OSError:
        return "classicmangos"
    m = re.search(r"run against (classic\w+)", head)
    return m.group(1) if m and m.group(1) in DATABASES else "classicmangos"


def sql_after(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = f.read(2000)
    except OSError:
        return []
    return re.findall(r"run after (\w+\.sql)", head)


def sql_candidates(paths):
    """name -> [paths], best first: this checkout's realm/classicplus, then the copies the launcher
    downloaded (sql-live), then the pack's own. Pending files (realm/classicplus/pending) never run."""
    out = {}
    for folder in (os.path.join(HERE, "realm", "classicplus"), paths.sql_live, paths.sql, paths.forge_dev):
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            continue
        for n in names:
            if n.lower().endswith(".sql") and os.path.isfile(os.path.join(folder, n)):
                out.setdefault(n, []).append(os.path.join(folder, n))
    return out


def order_sql(files):
    """Alphabetical, except a file runs after the files its header names ('run after x.sql'),
    the way openvanilla_realm_up.sh runs races before weapons."""
    names = sorted(files)
    deps = {n: [d for d in sql_after(files[n]) if d in files and d != n] for n in names}
    out, seen = [], set()

    def visit(n, stack=()):
        if n in seen or n in stack:
            return
        for d in deps[n]:
            visit(d, stack + (n,))
        seen.add(n)
        out.append(n)

    for n in ["classicplus_races.sql"] + names:
        if n in files and not n.startswith("forge_dev_"):
            visit(n)
    for n in names:   # packs being tested in Forge go on top of Open Vanilla's own content
        if n.startswith("forge_dev_"):
            visit(n)
    return out


def fetch_live_sql(manifest, paths, opener=None, reporter=None):
    """The newest Classic+ SQL listed in solo.json (name, sha256, url), into solo\\sql-live. Offline or a
    bad checksum just keeps what we have."""
    got = 0
    for item in (manifest or {}).get("sql", []) or []:
        name, sha, url = item.get("name", ""), str(item.get("sha256", "")).lower(), item.get("url", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+\.sql", name) or not re.fullmatch(r"[0-9a-f]{64}", sha) or not url.startswith("https://"):
            continue
        dest = os.path.join(paths.sql_live, name)
        if os.path.isfile(dest) and sha256_file(dest) == sha:
            continue
        try:
            with (opener or urllib.request.urlopen)(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=15) as r:
                data = r.read()
        except (urllib.error.URLError, OSError):
            continue
        if hashlib.sha256(data).hexdigest() != sha:
            if reporter:
                reporter.warn(f"Skipped an update to {name}: its checksum didn't match.")
            continue
        os.makedirs(paths.sql_live, exist_ok=True)
        with open(dest + ".tmp", "wb") as f:
            f.write(data)
        os.replace(dest + ".tmp", dest)
        got += 1
    return got


MARKER_DDL = """CREATE DATABASE IF NOT EXISTS openvanilla_solo;
CREATE TABLE IF NOT EXISTS openvanilla_solo.sql_applied (
  name VARCHAR(128) NOT NULL PRIMARY KEY,
  target VARCHAR(32) NOT NULL,
  sha256 CHAR(64) NOT NULL,
  applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS openvanilla_solo.meta (k VARCHAR(64) NOT NULL PRIMARY KEY, v VARCHAR(255) NOT NULL);
"""


def applied_markers(db):
    out = {}
    for line in db.query(MARKER_DDL + "SELECT name, sha256 FROM openvanilla_solo.sql_applied;").splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            out[parts[0]] = parts[1]
    return out


LEGACY_PREFIX = "openwow"   # the project's name before Open Vanilla; tables made under it are renamed once


def rename_legacy_tables(db):
    """Solo databases set up before the rename keep their data: each table named with the old prefix
    (and the old marker database's tables) moves to the Open Vanilla name, unless that name is taken."""
    old = LEGACY_PREFIX
    rows = db.query("SELECT table_schema, table_name FROM information_schema.tables "
                    f"WHERE table_name LIKE '{old}\\_%' OR table_schema = '{old}_solo';")
    have = set(tuple(l.split("\t")) for l in db.query(
        "SELECT table_schema, table_name FROM information_schema.tables;").splitlines() if "\t" in l)
    moves = []
    for line in rows.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        schema, table = parts
        new_schema = "openvanilla_solo" if schema == f"{old}_solo" else schema
        new_table = "openvanilla" + table[len(old):] if table.startswith(old + "_") else table
        if (new_schema, new_table) not in have:
            moves.append(f"`{schema}`.`{table}` TO `{new_schema}`.`{new_table}`")
    if moves:
        db.query("CREATE DATABASE IF NOT EXISTS openvanilla_solo; RENAME TABLE " + ", ".join(moves) + ";")
    return len(moves)


def apply_sql_updates(db, paths, reporter=None, cancel=None):
    """Run every Classic+ SQL file whose content changed since it last ran here (version marker:
    its SHA-256 in openvanilla_solo.sql_applied). The files are idempotent, as on the live realm."""
    reporter = reporter or Reporter()
    if rename_legacy_tables(db):
        reporter.info("Moved this solo world's tables to the Open Vanilla names")
    cands = sql_candidates(paths)
    files = {n: ps[0] for n, ps in cands.items()}
    done = applied_markers(db)
    ran = []
    for name in order_sql(files):
        check_cancel(cancel)
        path = files[name]
        sha = sha256_file(path)
        if done.get(name) == sha:
            continue
        target = sql_target_db(path)
        reporter.info(f"Applying {name} to {target}")
        db.import_file(path, target, reporter, cancel, label=f"Classic+ update: {name}")
        db.query(f"REPLACE INTO openvanilla_solo.sql_applied (name, target, sha256) VALUES "
                 f"('{sql_text(name)}', '{sql_text(target)}', '{sha}');")
        ran.append(name)
    return ran


def seed_files(paths):
    """db\\<name>.sql.gz (or .sql) for each database the pack ships."""
    out = {}
    for name in DATABASES:
        for ext in (".sql.gz", ".sql"):
            p = os.path.join(paths.db_seed, name + ext)
            if os.path.isfile(p):
                out[name] = p
                break
    return out


def ensure_databases(db, paths, state, pack, reporter=None, cancel=None):
    """First run: load every database from the pack. Pack update with a new world: reload
    classicmangos only (characters and accounts stay). Then the Classic+ SQL, users, accounts."""
    reporter = reporter or Reporter()
    seeds = seed_files(paths)
    if "classicmangos" not in seeds:
        raise SoloError("The solo pack has no world database (db\\classicmangos.sql.gz).")
    have = set(db.query("SHOW DATABASES;").split())
    world_version = (pack or {}).get("world_version", "")
    todo = [n for n in DATABASES if n in seeds and n not in have]
    reload_world = "classicmangos" in have and world_version and state.get("world_version") != world_version
    if reload_world:
        todo.insert(0, "classicmangos")
    if todo:
        reporter.stage("database", "Loading the Classic+ world into the solo database (once; about a minute)…")
    for name in todo:
        check_cancel(cancel)
        db.query(f"DROP DATABASE IF EXISTS {name}; CREATE DATABASE {name} DEFAULT CHARACTER SET utf8mb4;"
                 if name == "classicmangos" else f"CREATE DATABASE IF NOT EXISTS {name} DEFAULT CHARACTER SET utf8mb4;")
        db.import_file(seeds[name], name, reporter, cancel, label=f"Loading {name}")
        if name == "classicmangos":
            # World reloaded: forget which world SQL ran; the pack's baseline says what is already in.
            db.query(MARKER_DDL + "DELETE FROM openvanilla_solo.sql_applied WHERE target='classicmangos';")
            for fname, sha in ((pack or {}).get("sql_baseline") or {}).items():
                if re.fullmatch(r"[0-9a-f]{64}", str(sha)):
                    db.query(f"REPLACE INTO openvanilla_solo.sql_applied (name, target, sha256) VALUES "
                             f"('{sql_text(fname)}', 'classicmangos', '{sha}');")
    if world_version:
        state["world_version"] = world_version
    reporter.stage("database", "Checking for Classic+ world updates…")
    ran = apply_sql_updates(db, paths, reporter, cancel)
    pw, admin_pw = state["db_password"], state["soap_password"]
    db.query(f"CREATE USER IF NOT EXISTS 'mangos'@'127.0.0.1' IDENTIFIED BY '{pw}';"
             f"ALTER USER 'mangos'@'127.0.0.1' IDENTIFIED BY '{pw}';"
             f"CREATE USER IF NOT EXISTS 'mangos'@'localhost' IDENTIFIED BY '{pw}';"
             f"ALTER USER 'mangos'@'localhost' IDENTIFIED BY '{pw}';"
             "GRANT ALL PRIVILEGES ON `classic%`.* TO 'mangos'@'127.0.0.1';"
             "GRANT ALL PRIVILEGES ON `classic%`.* TO 'mangos'@'localhost';"
             "FLUSH PRIVILEGES;")
    db.query(account_sql(SOLO_ACCOUNT, SOLO_PASSWORD, 0) + account_sql(SOLO_ADMIN, admin_pw, 3) + realmlist_sql(state),
             "classicrealmd")
    return ran


def race_class_pairs(db):
    return db.query("SELECT DISTINCT race, class FROM playercreateinfo;", "classicmangos")


# ---------------------------------------------------------------- the servers

def soap_command(command, user, password, port, timeout=10):
    """One console command on mangosd through SOAP (localhost only); the text reply."""
    import base64
    body = ('<?xml version="1.0" encoding="utf-8"?>'
            '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:MaNGOS">'
            '<SOAP-ENV:Body><ns1:executeCommand><command>' + xml.sax.saxutils.escape(command)
            + '</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>').encode()
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=body, method="POST",
                                 headers={"Content-Type": "text/xml; charset=utf-8", "Authorization": f"Basic {auth}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
    m = re.search(r"<result>(.*?)</result>", text, re.S)
    if m:
        return xml.sax.saxutils.unescape(m.group(1)).strip()
    raise SoloError("The world server didn't take the command.")


class ServerSet:
    """realmd + mangosd as hidden background processes, with readiness waits and an orderly stop.
    popen/port_open/sleep/soap are injectable so the orchestration is testable with fake processes."""

    def __init__(self, paths, state, popen=subprocess.Popen, port_open=is_port_open, sleep=time.sleep,
                 soap=soap_command, clock=time.monotonic):
        self.paths, self.state = paths, state
        self.popen, self.port_open, self.sleep, self.soap, self.clock = popen, port_open, sleep, soap, clock
        self.procs = {}

    def _spawn(self, name, argv, log_name):
        os.makedirs(self.paths.logs, exist_ok=True)
        log = open(os.path.join(self.paths.logs, log_name), "a", encoding="utf-8", errors="replace")
        log.write(f"\n===== {name} start {time.strftime('%Y-%m-%d %H:%M:%S')} =====\n")
        log.flush()
        try:
            proc = self.popen(argv, cwd=self.paths.bin, stdin=subprocess.DEVNULL, stdout=log,
                              stderr=subprocess.STDOUT, **hidden_popen_kwargs())
        finally:
            log.close()  # the server has its own handle now
        self.procs[name] = proc
        return proc

    def _wait_port(self, name, port, timeout, cancel, reporter, text):
        start = self.clock()
        while self.clock() - start < timeout:
            check_cancel(cancel)
            proc = self.procs.get(name)
            if proc is not None and proc.poll() is not None:
                raise SoloError(f"The {'world' if name == 'mangosd' else 'login'} server stopped while starting. "
                                f"Details: {self.last_log_lines(name)}")
            if self.port_open(port):
                return True
            if reporter:
                reporter.progress(min(self.clock() - start, timeout), timeout, text)
            self.sleep(1.0)
        raise SoloError(f"The {'world' if name == 'mangosd' else 'login'} server didn't start in time. "
                        f"Details: {self.last_log_lines(name)}")

    def last_log_lines(self, name, n=3):
        log = os.path.join(self.paths.logs, "Server.log" if name == "mangosd" else "Realmd.log")
        if not os.path.isfile(log):
            log = os.path.join(self.paths.logs, f"{name}.out")
        try:
            with open(log, encoding="utf-8", errors="replace") as f:
                lines = [l.strip() for l in f.read().splitlines() if l.strip()]
            return " | ".join(lines[-n:]) or log
        except OSError:
            return log

    def check_ports_free(self):
        p = self.state["ports"]
        for name, port, what in (("realm", p["realm"], "login"), ("world", p["world"], "world"), ("soap", p["soap"], "SOAP")):
            if self.port_open(port):
                raise SoloError(f"Another server on this PC is already using port {port} (the {what} port). "
                                "If a local realm is running ('Host a Realm.bat' / the host panel), stop it and press Play Solo again.")

    def start(self, configs, reporter=None, cancel=None, world_timeout=900):
        p = self.state["ports"]
        realmd = find_exe(self.paths.bin, "realmd")
        mangosd = find_exe(self.paths.bin, "mangosd")
        if not realmd or not mangosd:
            raise SoloError("The solo pack's server files are missing. Delete solo\\bin and press Play Solo again.")
        if reporter:
            reporter.stage("start", "Starting the login server…")
        self._spawn("realmd", [realmd, "-c", configs["realmd.conf"]], "realmd.out")
        self._wait_port("realmd", p["realm"], 60, cancel, reporter, "Starting the login server…")
        argv = [mangosd, "-c", configs["mangosd.conf"]]
        if "ahbot.conf" in configs:
            argv += ["-a", configs["ahbot.conf"]]
        if "aiplayerbot.conf" in configs:
            argv += ["-p", configs["aiplayerbot.conf"]]
        first = not self.state.get("world_started_once")
        text = ("Starting the world and creating the playerbots (the first start takes a few minutes)…" if first
                else "Starting the world…")
        if reporter:
            reporter.stage("start", text)
        self._spawn("mangosd", argv, "mangosd.out")
        self._wait_port("mangosd", p["world"], world_timeout, cancel, reporter, text)
        self.state["world_started_once"] = True
        return True

    def stop(self, reporter=None, grace=120):
        """World first (SOAP: save everyone, shut down), then login. A server that won't stop is killed."""
        p = self.state["ports"]
        m = self.procs.get("mangosd")
        if m is not None and m.poll() is None:
            if reporter:
                reporter.stage("stop", "Saving and stopping the world…")
            try:
                self.soap("saveall", SOLO_ADMIN, self.state["soap_password"], p["soap"])
                self.soap("server shutdown 1", SOLO_ADMIN, self.state["soap_password"], p["soap"])
            except (SoloError, OSError):
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
            while r.poll() is None and self.clock() - start < 10:
                self.sleep(0.5)
            if r.poll() is None:
                r.kill()
        self.procs.clear()


# ---------------------------------------------------------------- run record (stale cleanup)

def pid_alive(pid):
    if not pid:
        return False
    if IS_WINDOWS:
        r = subprocess.run(["tasklist", "/FI", f"PID eq {int(pid)}", "/FO", "CSV", "/NH"], capture_output=True,
                           text=True, **hidden_run_kwargs())
        return str(int(pid)) in r.stdout
    try:
        os.kill(int(pid), 0)
    except OSError:
        return False
    try:
        with open(f"/proc/{int(pid)}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"  # a zombie has already exited
    except (OSError, IndexError):
        return True


def pid_image(pid):
    """The executable name of a running pid ('' when unknown), so a stale pid reused by another
    program is never killed."""
    if IS_WINDOWS:
        r = subprocess.run(["tasklist", "/FI", f"PID eq {int(pid)}", "/FO", "CSV", "/NH"], capture_output=True,
                           text=True, **hidden_run_kwargs())
        m = re.match(r'"([^"]+)"', r.stdout.strip())
        return m.group(1).lower() if m else ""
    try:
        return os.path.basename(os.readlink(f"/proc/{int(pid)}/exe")).lower()
    except OSError:
        return ""


def kill_pid(pid):
    if IS_WINDOWS:
        subprocess.run(["taskkill", "/PID", str(int(pid)), "/T", "/F"], capture_output=True, **hidden_run_kwargs())
    else:
        try:
            os.kill(int(pid), 9)
        except OSError:
            pass


def write_run_record(paths, procs, controller=None):
    write_json(paths.run_file, {"controller": controller or os.getpid(),
                                "servers": {k: getattr(p, "pid", None) for k, p in procs.items() if p is not None}})


def cleanup_stale(paths, state, reporter=None, alive=pid_alive, image=pid_image, kill=kill_pid):
    """Servers a crashed or closed launcher left running: stop them (world via SOAP first)."""
    rec = read_json(paths.run_file)
    if not rec:
        return False
    ctl = rec.get("controller")
    if ctl and ctl != os.getpid() and alive(ctl) and not rec.get("detached"):
        name = image(ctl)
        # Still running in another launcher or console window (not a pid reused by some other program)?
        if any(k in name for k in ("python", "openvanilla", "launcher", "py.exe")):
            raise SoloError("Solo is already running from another window. Close that game first.")
    expected = {"mangosd": "mangosd", "realmd": "realmd", "mariadb": ("mariadbd", "mysqld")}
    servers = rec.get("servers", {})
    if servers.get("mangosd") and alive(servers["mangosd"]):
        try:
            soap_command("server shutdown 1", SOLO_ADMIN, state["soap_password"], state["ports"]["soap"], timeout=5)
            for _ in range(60):
                if not alive(servers["mangosd"]):
                    break
                time.sleep(1)
        except (SoloError, OSError):
            pass
    def ours(name, pid):
        want = expected.get(name, name)
        want = want if isinstance(want, tuple) else (want,)
        if not pid or not alive(pid):
            return False
        if any(image(pid).startswith(w) for w in want):
            return True
        if not IS_WINDOWS and image is pid_image:  # a script stand-in (tests): its command line names our folder
            try:
                with open(f"/proc/{int(pid)}/cmdline", "rb") as f:
                    return paths.root.encode() in f.read()
            except OSError:
                return False
        return False

    def wait_gone(pid, seconds):
        for _ in range(int(seconds * 4)):
            if not alive(pid):
                return True
            time.sleep(0.25)
        return False

    for name in ("mangosd", "realmd", "mariadb"):  # world first, the database last
        pid = servers.get(name)
        if not ours(name, pid):
            continue
        if reporter:
            reporter.info(f"Stopping the {name} left running from last time.")
        if name == "mariadb" and kill is kill_pid:
            SoloDB(paths, state).shutdown(timeout=30)  # a clean database stop, not a crash recovery next time
            if wait_gone(pid, 30):
                continue
        kill(pid)
        if kill is kill_pid:
            wait_gone(pid, 10)
    try:
        os.remove(paths.run_file)
    except OSError:
        pass
    return True


# ---------------------------------------------------------------- the game client

def launcher_settings():
    """The player launcher's settings.json (portable beside it, else the roaming settings folder)."""
    for p in (os.path.join(app_dir(), "launcher", "settings.json"), os.path.join(app_dir(), "settings.json"),
              os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "OpenWoW", "settings.json")):
        data = read_json(p)
        if isinstance(data, dict):
            return data
    return {}


ENGINE_NAMES = ("OpenWoW.exe", "benilla.exe")
STOCK_NAMES = ("WoW.exe", "Wow.exe", "wow.exe")


def find_client(explicit=None, settings=None):
    """(kind, exe, data_folder): 'engine' = the Open Vanilla engine (signs in by itself), 'exe' = a stock client.
    explicit may be an exe or a folder; otherwise the launcher's settings and the Open Vanilla folder."""
    settings = settings if settings is not None else launcher_settings()
    wow = settings.get("wow_folder") or ""
    tries = []
    if explicit:
        tries.append(explicit)
    tries += [c.get("path") for c in settings.get("clients", []) if isinstance(c, dict) and c.get("path")]
    tries += [os.path.join(app_dir(), n) for n in ENGINE_NAMES] + [wow]
    for t in tries:
        if not t:
            continue
        if os.path.isfile(t):
            name = os.path.basename(t)
            kind = "engine" if name.lower() in [n.lower() for n in ENGINE_NAMES] else "exe"
            data = wow if kind == "engine" else os.path.dirname(t)
            return kind, t, data
        if os.path.isdir(t):
            for n in ENGINE_NAMES:
                if os.path.isfile(os.path.join(t, n)):
                    return "engine", os.path.join(t, n), wow or t
            for n in STOCK_NAMES:
                if os.path.isfile(os.path.join(t, n)):
                    return "exe", os.path.join(t, n), t
    return None, None, wow or None


def _read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return None


def point_client_at_solo(client_folder, state):
    """Stock client: realmlist.wtf -> 127.0.0.1, Config.wtf account/realm pre-filled. Returns a function
    that puts back exactly what was there (only if the files still hold our values)."""
    p = state["ports"]
    host = "127.0.0.1" if int(p["realm"]) == 3724 else f"127.0.0.1:{p['realm']}"
    rl = os.path.join(client_folder, "realmlist.wtf")
    cfg = os.path.join(client_folder, "WTF", "Config.wtf")
    old_rl = _read_lines(rl)
    old_cfg = _read_lines(cfg)
    ours_rl = [f"set realmlist {host}"]
    with open(rl, "w", encoding="ascii", newline="\r\n") as f:
        f.write("\n".join(ours_rl) + "\n")
    lines = [l for l in (old_cfg or []) if not re.match(r"(?i)^\s*set\s+(accountname|realmname)\s", l)]
    lines += [f'SET accountName "{SOLO_ACCOUNT}"', f'SET realmName "{SOLO_REALM_NAME}"']
    os.makedirs(os.path.dirname(cfg), exist_ok=True)
    with open(cfg, "w", encoding="utf-8", newline="\r\n") as f:
        f.write("\n".join(lines) + "\n")

    def restore():
        if _read_lines(rl) == ours_rl:
            if old_rl is None:
                os.remove(rl)
            else:
                with open(rl, "w", encoding="ascii", errors="replace", newline="\r\n") as f:
                    f.write("\n".join(old_rl) + "\n")
        now = _read_lines(cfg)
        if now is not None:
            keep = [l for l in now if not re.match(r"(?i)^\s*set\s+(accountname|realmname)\s", l)]
            olds = [l for l in (old_cfg or []) if re.match(r"(?i)^\s*set\s+(accountname|realmname)\s", l)]
            with open(cfg, "w", encoding="utf-8", newline="\r\n") as f:
                f.write("\n".join(keep + olds) + "\n")
    return restore


def client_env(state, data_folder):
    """The Open Vanilla engine signs in by itself with WOW_HOST/WOW_USER/WOW_PASS (and picks the realm by WOW_REALM)."""
    p = state["ports"]
    env = dict(os.environ)
    env["WOW_HOST"] = "127.0.0.1" if int(p["realm"]) == 3724 else f"127.0.0.1:{p['realm']}"
    env["WOW_USER"], env["WOW_PASS"], env["WOW_REALM"] = SOLO_ACCOUNT, SOLO_PASSWORD, SOLO_REALM_NAME
    if data_folder:
        root = client_root(data_folder)
        env["WOW_DATA"] = os.path.join(root, "Data") if os.path.isdir(os.path.join(root, "Data")) else data_folder
    return env


# ---------------------------------------------------------------- busy realm check

def official_realm():
    """The first realm in launcher/defaults.json (Vanilla Remastered)."""
    for p in (os.path.join(app_dir(), "launcher", "defaults.json"), os.path.join(HERE, "launcher", "defaults.json")):
        d = read_json(p)
        if isinstance(d, dict) and d.get("realms"):
            return d["realms"][0]
    return {"name": "Vanilla Remastered", "host": "play.openvanilla.app", "port": 3724, "portal": "https://play.openvanilla.app/"}


def probe_realm(realm=None, fetch=None, tcp=None, clock=time.monotonic):
    """One sample of the live realm's load. /healthz (wenilla-realm, public) says whether the database
    and the world server answer; its round trip includes a world console command, so it is the world's
    latency. If the realm ever adds players/queue numbers there ("players", "player_limit", "queue",
    flat or under "world"), they are used too. The auth port's TCP connect is the fallback."""
    realm = realm or official_realm()
    portal = (realm.get("portal") or "").rstrip("/")
    sample = {"reachable": False, "latency_ms": None}
    if portal:
        url = portal + "/healthz"
        t0 = clock()
        try:
            if fetch:
                code, data = fetch(url)
            else:
                req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Cache-Control": "no-cache"})
                try:
                    with urllib.request.urlopen(req, timeout=DOWN_MS / 1000) as r:
                        code, data = r.status, json.loads(r.read().decode("utf-8") or "{}")
                except urllib.error.HTTPError as e:
                    code, data = e.code, json.loads(e.read().decode("utf-8") or "{}")
            sample["latency_ms"] = int((clock() - t0) * 1000)
            sample["http"] = code
            sample["reachable"] = code < 500 or isinstance(data, dict)
            if isinstance(data, dict):
                world = data.get("world") if isinstance(data.get("world"), dict) else data
                for k_out, keys in (("players", ("players", "players_online", "online")),
                                    ("limit", ("player_limit", "max_players", "limit")),
                                    ("queue", ("queue", "queued"))):
                    for k in keys:
                        if isinstance(world.get(k), (int, float)) and not isinstance(world.get(k), bool):
                            sample[k_out] = int(world[k])
                            break
                for k in ("soap", "mariadb"):
                    if k in data:
                        sample[k] = bool(data[k])
        except (urllib.error.URLError, OSError, ValueError):
            sample["latency_ms"] = None
    if not sample["reachable"]:
        host, port = realm.get("host"), int(realm.get("port", 3724))
        t0 = clock()
        ok = (tcp or (lambda h, p: is_port_open(p, h, timeout=4)))(host, port) if host else False
        sample["auth_up"] = bool(ok)
        if ok:
            sample["auth_ms"] = int((clock() - t0) * 1000)
    return sample


def classify(sample):
    """(state, reason) from one sample: 'ok', 'slow', 'full' or 'down'. Pure, so the thresholds are tested."""
    if not sample.get("reachable"):
        if sample.get("auth_up"):
            return "slow", "The realm's website isn't answering, so it may be struggling."
        return "down", "The realm isn't answering right now."
    if sample.get("http", 200) >= 500 and not sample.get("soap"):
        return "down", "The realm is having trouble right now."
    if sample.get("soap") is False:
        return "down", "The world server is down or restarting."
    if sample.get("mariadb") is False:
        return "down", "The realm's database is down."
    q = sample.get("queue") or 0
    if q > 0:
        return "full", f"The realm is full: {q} {'player is' if q == 1 else 'players are'} in the queue."
    players, limit = sample.get("players"), sample.get("limit")
    if players is not None and limit and players >= FULL_RATIO * limit:
        return "full", f"The realm is full ({players} of {limit} players)."
    ms = sample.get("latency_ms")
    if ms is not None and ms >= SLOW_MS:
        return "slow", f"The realm is slow right now (the world takes {ms / 1000:.1f} s to answer)."
    return "ok", "The realm is running normally."


class BusyTracker:
    """Hysteresis for the banner: 'down' and 'full' show at once, 'slow' only after SLOW_SAMPLES slow
    samples in a row (one slow answer is just a hiccup); one good sample hides it again."""

    def __init__(self, slow_samples=SLOW_SAMPLES):
        self.slow_samples = slow_samples
        self.slow_run = 0
        self.state, self.reason = "ok", ""

    def update(self, sample):
        state, reason = classify(sample)
        if state == "slow":
            self.slow_run += 1
            if self.slow_run < self.slow_samples:
                return self.busy
        else:
            self.slow_run = 0
        self.state, self.reason = state, reason
        return self.busy

    @property
    def busy(self):
        return self.state in ("slow", "full", "down")


def check_realm(realm=None, fetch=None, tcp=None):
    sample = probe_realm(realm, fetch, tcp)
    state, reason = classify(sample)
    return {"state": state, "reason": reason, "busy": state != "ok", **sample}


# ---------------------------------------------------------------- the whole thing

class SoloSession:
    """PLAY SOLO, start to finish. The launcher runs run() on a worker thread with its own Reporter;
    the console runs it directly. stop() from any thread ends a running session cleanly."""

    def __init__(self, root=None, reporter=None, manifest_url=None, client=None, mmaps=False, play=True,
                 cancel=None, opener=None, popen=subprocess.Popen, settings=None, data=None):
        self.paths = SoloPaths(root)
        self.data_hint = data
        self.reporter = reporter or ConsoleReporter()
        self.manifest_url = manifest_url or os.environ.get("OPENVANILLA_SOLO_MANIFEST") or SOLO_MANIFEST_URL
        self.client_hint, self.mmaps, self.play = client, mmaps, play
        self.cancel = cancel or threading.Event()
        self.opener, self.popen = opener, popen
        self.settings = settings
        self.state = None
        self.db = None
        self.db_started = False
        self.keep_running = False
        self.manifest = None
        self.servers = None
        self.game = None

    # -- pack

    def pack_status(self):
        """('missing'|'update'|'ok'|'offline', manifest or None) without downloading anything."""
        manifest = None
        try:
            manifest = validate_manifest(fetch_json(self.manifest_url, opener=self.opener))
        except urllib.error.HTTPError as e:
            if e.code == 404 and not self.paths.pack_installed():
                raise SoloError("Play Solo isn't published yet: the solo server pack isn't on the download site. "
                                "Check back after the next Open Vanilla update.")
        except (urllib.error.URLError, OSError, ValueError):
            pass
        except SoloError:
            if not self.paths.pack_installed():
                raise
        installed = read_json(self.paths.pack_json) if self.paths.pack_installed() else None
        if not installed:
            return ("missing" if manifest else "offline"), manifest
        if manifest and manifest["version"] != installed.get("version"):
            return "update", manifest
        return "ok", manifest

    def ensure_pack(self):
        status, manifest = self.pack_status()
        if status == "offline":
            raise SoloError("The solo server pack isn't downloaded yet and the download server can't be reached. "
                            "Connect to the internet once and press Play Solo again.")
        if status in ("missing", "update"):
            r = self.reporter
            r.stage("download", ("Downloading the solo server" if status == "missing" else "Updating the solo server")
                    + f" ({human_size(int(manifest['size']))}, once)…")
            zip_path = os.path.join(self.paths.download, f"OpenVanilla-Solo-{manifest['version']}.zip")
            download(manifest["url"], zip_path, manifest["sha256"], int(manifest["size"]), r, self.cancel, self.opener)
            r.stage("unpack", "Unpacking the solo server…")
            unpack_pack(zip_path, self.paths, r, self.cancel)
            for f in os.listdir(self.paths.download):
                try:
                    os.remove(os.path.join(self.paths.download, f))
                except OSError:
                    pass
        self.manifest = manifest
        if manifest:
            try:
                fetch_live_sql(manifest, self.paths, self.opener, self.reporter)
            except OSError:
                pass
        return read_json(self.paths.pack_json, {})

    # -- maps

    def ensure_gamedata(self, client_data):
        """Map data: solo\\gamedata, else data the player already has (adopted, not copied), else the
        extractors on their own client. Movement maps only when asked (--mmaps)."""
        p = self.paths
        client_data = client_root(client_data)
        if not has_gamedata(p.gamedata):
            for cand in gamedata_candidates(p, client_data)[1:]:
                if has_gamedata(cand):
                    self.reporter.stage("extract", f"Using the map data you already have in {cand}")
                    adopt_gamedata(cand, p)
                    break
        if not has_gamedata(p.gamedata):
            if not client_data:
                raise SoloError("Solo needs your World of Warcraft 1.12.1 folder to make its maps. "
                                "Set it in the launcher's Settings and press Play Solo again.")
            self.reporter.stage("extract", "Making the solo world's maps from your game client (once; 10-20 minutes)…")
            run_extractors(client_data, p.gamedata, p.tools, self.reporter, self.cancel, mmaps=False,
                           popen=self.popen, log_path=os.path.join(p.logs, "extract.log"))
        if self.mmaps and not has_mmaps(p.gamedata):
            with open(os.path.join(p.logs, "extract.log"), "a", encoding="utf-8") as log:
                build_mmaps(p.gamedata, p.tools, self.reporter, self.cancel, self.popen, log)
        return p.gamedata

    # -- run

    def run(self):
        r = self.reporter
        p = self.paths
        os.makedirs(p.root, exist_ok=True)
        for d in (p.logs, p.custom):
            os.makedirs(d, exist_ok=True)
        self.state = load_state(p)
        cleanup_stale(p, self.state, r)
        self.servers = ServerSet(p, self.state, popen=self.popen)
        self.servers.check_ports_free()  # a local realm on 3724/8085: say so before downloading anything
        restore = None
        try:
            pack = self.ensure_pack()
            kind, exe, data = find_client(self.client_hint, self.settings)
            if self.data_hint:
                data = self.data_hint
            if self.play and not exe:
                raise SoloError("No game client found. Set your World of Warcraft 1.12.1 folder (or the Open Vanilla engine) "
                                "in the launcher's Settings and press Play Solo again.")
            self.ensure_gamedata(data)
            configs = write_configs(p, self.state)
            self.db = SoloDB(p, self.state, popen=self.popen)
            if not self.db.initialized():
                r.stage("database", "Setting up the solo database…")
                self.db.initialize(r)
            r.stage("database", "Starting the solo database…")
            self.db.start(cancel=self.cancel)
            self.db_started = True
            self._record()
            ensure_databases(self.db, p, self.state, pack, r, self.cancel)
            fix_server_dbcs(p, race_class_pairs(self.db), r)
            save_state(p, self.state)
            self.servers.check_ports_free()
            self.servers.start(configs, r, self.cancel)
            self._record()
            save_state(p, self.state)
            if not self.play:
                self.keep_running = True
                rec = read_json(p.run_file, {}) or {}
                rec["detached"] = True  # solo-stop (or the next Play Solo) stops them
                write_json(p.run_file, rec)
                r.stage("ready", "Solo servers are running. Stop them with: 'Play Solo.bat' solo-stop")
                return 0
            r.stage("play", f"Starting the game. {SOLO_NOTE}")
            if kind == "exe":
                restore = point_client_at_solo(os.path.dirname(exe), self.state)
                r.info(f"Sign in with account {SOLO_ACCOUNT}, password {SOLO_PASSWORD}.")
                self.game = self.popen([exe], cwd=os.path.dirname(exe))
            else:
                self.game = self.popen([exe], cwd=os.path.dirname(exe), env=client_env(self.state, data))
            started = time.monotonic()
            while self.game.poll() is None:
                if self.cancel.is_set():
                    break
                time.sleep(1.0)
            if time.monotonic() - started < 15 and self.game.poll() not in (None, 0):
                r.warn(f"The game closed right away (exit {self.game.poll()}).")
            return 0
        finally:
            self.shutdown(restore)

    def _record(self):
        procs = {}
        if self.db and self.db.proc:
            procs["mariadb"] = self.db.proc
        if self.servers:
            procs.update(self.servers.procs)
        write_run_record(self.paths, procs)

    def shutdown(self, restore=None):
        r = self.reporter
        if self.keep_running:
            return  # --no-play: leave them running
        try:
            if self.servers:
                self.servers.stop(r)
            if self.db and self.db_started:
                r.stage("stop", "Stopping the solo database…")
                self.db.shutdown()
        finally:
            if restore:
                try:
                    restore()
                except OSError:
                    pass
            if self.state:
                save_state(self.paths, self.state)
            try:
                os.remove(self.paths.run_file)
            except OSError:
                pass
        r.stage("done", "Solo stopped. Your solo characters are saved on this PC.")

    def stop(self):
        """From another thread: end the session (closes nothing in the game; the servers stop)."""
        self.cancel.set()


def solo_stop(root=None, reporter=None):
    paths = SoloPaths(root)
    reporter = reporter or ConsoleReporter()
    state = load_state(paths)
    if cleanup_stale(paths, state, reporter):
        reporter.stage("done", "Solo servers stopped.")
    else:
        reporter.stage("done", "No solo servers were running.")
    return 0


# ---------------------------------------------------------------- the SPP host path (unchanged behaviour)

def lan_ip():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect(("10.255.255.255", 1))  # no packet is sent; this just picks the outgoing interface
        return s.getsockname()[0]


def start_gateway(host, launcher_gui, server_control):
    """Caddy on https://HOST:8090 in front of the web backend (same config the control panel writes)."""
    port = launcher_gui.PUBLIC_HTTPS_PORT
    if server_control.is_port_open(port):
        print(f"[HTTPS] Already listening on :{port}.")
        return
    caddy = os.path.join(HERE, "bin", "caddy.exe")
    if not os.path.isfile(caddy):
        print("[HTTPS] bin\\caddy.exe is missing: no public website. Download Caddy from caddyserver.com into bin\\.")
        return
    web_port = launcher_gui.LOCAL_WEB_PORT
    with open(launcher_gui.CADDY_CONFIG, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"{{\n    default_sni {host}\n}}\n\nhttps://{host}:{port} {{\n    tls {{\n"
                f"        issuer acme https://acme-v02.api.letsencrypt.org/directory {{\n            profile shortlived\n"
                f"        }}\n    }}\n    reverse_proxy 127.0.0.1:{web_port}\n}}\n")
    log = open(os.path.join(HERE, "caddy.log"), "a", encoding="utf-8")
    subprocess.Popen([caddy, "run", "--config", launcher_gui.CADDY_CONFIG, "--adapter", "caddyfile"], cwd=HERE,
                     stdout=log, stderr=subprocess.STDOUT, env={**os.environ, "APPDATA": os.path.join(HERE, "CaddyData")},
                     creationflags=launcher_gui.DETACHED_FLAGS if IS_WINDOWS else 0)
    print(f"[HTTPS] Gateway starting on https://{host}:{port}/ (certificate in a minute; log: caddy.log)")


def host_main(args):
    """The SPP Classics test realm for hosts: `host` (127.0.0.1), `lan`, or `public HOST`."""
    import glob
    import webbrowser
    sys.path.insert(0, HERE)
    import server_control  # noqa: E402  (SPP paths, MySQL, realmd/mangosd start-up)
    import launcher_gui  # noqa: E402  (start_web_backend: asset_server.py detached, logging to web-backend.log)
    web_port = launcher_gui.LOCAL_WEB_PORT
    mode = args[0].lower() if args else "host"
    if mode == "public":
        if len(args) < 2:
            print("Usage: play_local.py public HOST")
            return 2
        host = server_control.sql_value(args[1])
    else:
        host = lan_ip() if mode == "lan" else "127.0.0.1"
    print(f"=== Open Vanilla local test realm on {host} ===")
    if not server_control.start_all():
        print("\nThe server did not start. Check SPP_ROOT in server_control.py points at your SPP Classics install.")
        return 1
    # realmd hands this address to the client for the world server, so it must be reachable from the players.
    ret, _, err = server_control.run_mysql_query(f"UPDATE classicrealmd.realmlist SET address='{server_control.sql_value(host)}';")
    print(f"[REALM] Realm address set to {host}." if ret == 0 else f"[REALM] Could not set the realm address: {err.strip()}")
    if not server_control.is_port_open(web_port):
        print(f"[WEB] Starting the web backend on :{web_port}...")
        launcher_gui.start_web_backend()
        for _ in range(40):
            if server_control.is_port_open(web_port):
                break
            time.sleep(0.5)
    print(f"[WEB] {'Running' if server_control.is_port_open(web_port) else 'NOT running (see web-backend.log)'}: http://127.0.0.1:{web_port}/")
    if mode == "public":
        start_gateway(host, launcher_gui, server_control)
    builds = sorted(glob.glob(os.path.join(HERE, "release", "OpenVanilla_*_Win64", "OpenVanilla.exe")), key=os.path.getmtime)
    cmd = [builds[-1]] if builds else [sys.executable, os.path.join(HERE, "launcher", "openvanilla_launcher.py")]
    try:
        subprocess.Popen(cmd + ["--realm", host], cwd=os.path.dirname(cmd[-1]))
        print(f"[LAUNCHER] Opened on realm {host}. PLAY = desktop client, PLAY IN BROWSER = browser client.")
    except OSError as e:
        print(f"[LAUNCHER] Could not open the launcher ({e}); opening the browser client instead.")
        webbrowser.open(f"http://127.0.0.1:{web_port}/")
    print("\nServers keep running after this window closes. Stop them from 'Host a Realm.bat' (HALT ALL SERVICES).")
    return 0


# ---------------------------------------------------------------- CLI

def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    mode = args[0].lower() if args and not args[0].startswith("-") else "solo"
    rest = args[1:] if args and not args[0].startswith("-") else args
    if mode in ("host", "lan", "public"):
        return host_main(args)
    if mode == "status":
        res = check_realm()
        print(json.dumps(res, indent=2))
        print(("BUSY: " if res["busy"] else "OK: ") + res["reason"])
        return 0
    if mode == "solo-stop":
        return solo_stop()
    if mode != "solo":
        print(__doc__)
        return 2
    opts = {"mmaps": "--mmaps" in rest, "play": "--no-play" not in rest}
    client = None
    if "--client" in rest:
        i = rest.index("--client")
        client = rest[i + 1] if i + 1 < len(rest) else None
    data = None
    if "--data" in rest:
        i = rest.index("--data")
        data = rest[i + 1] if i + 1 < len(rest) else None
    print("=== Open Vanilla Solo ===")
    print(SOLO_NOTE)
    session = SoloSession(client=client, data=data, **opts)
    try:
        return session.run()
    except Cancelled:
        print("\n[SOLO] Cancelled.")
        return 1
    except SoloError as e:
        print(f"\n[SOLO] {e}")
        return 1
    except KeyboardInterrupt:
        session.stop()
        print("\n[SOLO] Stopped.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
