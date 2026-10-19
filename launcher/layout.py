"""Where Open Vanilla keeps its files: the install folder, the user-data folder, and moving old installs over.

Install folder (what the zip or the installer puts down; an update replaces it):

    OpenVanilla\\
      OpenVanilla.exe        the launcher: the one thing players run (bridge releases also ship OpenWoW.exe)
      app\\                  the launcher's internals (PyInstaller --contents-directory app)
      Game\\                 the engine ("Open Vanilla Game.exe") and its state (benilla-config\\)
      Server\\               notes for the bundled server software (the code itself is inside app\\)
      links.txt  README.txt  LICENSES\\

User data (survives updates and reinstalls):

      AddOns\\Enabled\\       addons every client loads (Workshop installs land here)
      AddOns\\Disabled\\      addons switched off in the launcher
      Realms\\Solo\\          SPP Classics (Play Solo)
      Realms\\SoloPack\\      the older Open Vanilla solo pack (fallback; Host for friends runs on it)
      Realms\\Hosted\\        realms this PC hosts for friends (P2P)
      Screenshots\\  Logs\\  Backups\\
      Settings\\             settings.json, layout.json
      Cache\\                live.json cache, staged updates, downloads in progress

The user-data folder is the install folder for the portable zip, and %LOCALAPPDATA%\\OpenVanilla (or an
existing %LOCALAPPDATA%\\OpenWoW) for the
installer build (it has unins000.exe beside the launcher), or whenever the install folder is read-only.
OPENVANILLA_DATA_DIR overrides it. Run from source, it is <checkout>\\_local\\launcher-data (gitignored).

migrate() moves an older install's files (OpenWoW Launcher.exe, the engine as OpenWoW.exe,
benilla-config\\AddOns, solo\\, host\\, launcher\\settings.json) into this layout. It is idempotent and
never deletes anything: when both sides have a file, the old one goes to Backups\\migration-<date>.

Standard library only; Python 3.10 compatible.
"""
import json
import os
import shutil
import sys
import time

LAYOUT_VERSION = 2
LAUNCHER_EXE = "OpenVanilla.exe"
OLD_LAUNCHER_EXE = "OpenWoW.exe"          # the launcher's name before the Open Vanilla rename (layout 2)
LAUNCHER_EXES = (LAUNCHER_EXE, OLD_LAUNCHER_EXE)   # bridge releases ship both: older updaters only know the old one
INTERNAL_DIR = "app"
GAME_DIR = "Game"
ENGINE_EXE = "Open Vanilla Game.exe"
OLD_ENGINE_EXES = ("OpenWoW Game.exe",)   # Game\ engine names before the rename: renamed by migrate(), still found
ENGINE_CONFIG = "benilla-config"          # the engine keeps its state beside its binary
SERVER_DIR = "Server"
LEGACY_LAUNCHER_EXES = ("OpenWoW Launcher.exe",)
LEGACY_ENGINE_NAMES = ("benilla.exe", "OpenWoW.exe")   # OpenWoW.exe was the engine before layout 2
NEXT_ENGINE_NAMES = OLD_ENGINE_EXES     # searched after ENGINE_EXE in Game\ (kept name for older callers)
DATA_DIR_NAME = "OpenVanilla"            # %LOCALAPPDATA%\OpenVanilla for new installs
OLD_DATA_DIR_NAMES = ("OpenWoW",)        # an existing %LOCALAPPDATA%\OpenWoW keeps being used, never moved
MANAGED_FILE = ".openvanilla-managed.json"    # in a client's AddOns folder: which addons the launcher put there
SHIPPED_FILE = ".shipped.json"            # in AddOns\\: which launcher version last seeded the bundled addons
USER_FOLDERS = ("AddOns/Enabled", "AddOns/Disabled", "Realms/Solo", "Realms/Hosted", "Screenshots", "Logs",
                "Backups", "Settings", "Cache")


def _writable(folder):
    try:
        os.makedirs(folder, exist_ok=True)
        probe = os.path.join(folder, ".write-test-%d" % os.getpid())
        with open(probe, "w") as f:
            f.write("ok")
        os.remove(probe)
        return True
    except OSError:
        return False


def local_appdata(env=None):
    env = os.environ if env is None else env
    return env.get("LOCALAPPDATA") or env.get("APPDATA") or os.path.join(os.path.expanduser("~"), ".local", "share")


class Layout:
    """Every folder the launcher uses. Paths only; ensure() creates the user folders."""

    def __init__(self, install_dir, data_dir, mode):
        self.install = os.path.abspath(install_dir)
        self.data = os.path.abspath(data_dir)
        self.mode = mode                      # "portable" | "installed" | "source" | "custom"
        i = lambda *p: os.path.join(self.install, *p)
        d = lambda *p: os.path.join(self.data, *p)
        self.launcher_exe = i(LAUNCHER_EXE)
        self.internal = i(INTERNAL_DIR)
        self.game = i(GAME_DIR)
        self.engine_exe = i(GAME_DIR, ENGINE_EXE)
        self.engine_config = i(GAME_DIR, ENGINE_CONFIG)
        self.engine_addons = i(GAME_DIR, ENGINE_CONFIG, "AddOns")
        self.server = i(SERVER_DIR)
        self.addons = d("AddOns")
        self.addons_enabled = d("AddOns", "Enabled")
        self.addons_disabled = d("AddOns", "Disabled")
        self.realms = d("Realms")
        self.solo = d("Realms", "Solo")
        self.solo_pack = d("Realms", "SoloPack")
        self.hosted = d("Realms", "Hosted")
        self.screenshots = d("Screenshots")
        self.logs = d("Logs")
        self.backups = d("Backups")
        self.clients_txt = d("clients.txt")     # the player's own game clients (Workshop > CLIENTS)
        self.settings_dir = d("Settings")
        self.settings_file = d("Settings", "settings.json")
        self.layout_file = d("Settings", "layout.json")
        self.cache = d("Cache")
        self.live_cache = d("Cache", "live.json")
        self.updates = d("Cache", "Updates")
        self.downloads = d("Cache", "Downloads")

    @property
    def portable(self):
        return self.mode in ("portable", "source")

    def ensure(self):
        for rel in USER_FOLDERS:
            os.makedirs(os.path.join(self.data, *rel.split("/")), exist_ok=True)
        return self

    def export_env(self, env=None):
        """Tell play_local.py and p2p/host.py where Realms\\SoloPack and Realms\\Hosted are."""
        env = os.environ if env is None else env
        env.setdefault("OPENVANILLA_SOLO_DIR", self.solo_pack)
        env.setdefault("OPENVANILLA_HOST_DIR", self.hosted)
        return env

    def describe(self):
        return {"mode": self.mode, "install": self.install, "data": self.data}


def detect(install_dir, *, source=False, env=None, writable=_writable):
    """The layout for a launcher living in install_dir.

    source=True: run from a checkout (install_dir is the checkout); data under _local\\launcher-data."""
    env = os.environ if env is None else env
    install_dir = os.path.abspath(install_dir)
    custom = env.get("OPENVANILLA_DATA_DIR")
    if custom:
        return Layout(install_dir, custom, "custom")
    if source:
        return Layout(install_dir, os.path.join(install_dir, "_local", "launcher-data"), "source")
    installed = os.path.isfile(os.path.join(install_dir, "unins000.exe"))
    if not installed and writable(install_dir):
        return Layout(install_dir, install_dir, "portable")
    return Layout(install_dir, installed_data_dir(env), "installed")


def installed_data_dir(env=None):
    """%LOCALAPPDATA%\\OpenVanilla, unless an older %LOCALAPPDATA%\\OpenWoW already exists: that one keeps being
    used where it is (Solo and hosted realms store absolute paths inside it, so it is never moved)."""
    base = local_appdata(env)
    new = os.path.join(base, DATA_DIR_NAME)
    if os.path.isdir(new):
        return new
    for old in OLD_DATA_DIR_NAMES:
        if os.path.isdir(os.path.join(base, old)):
            return os.path.join(base, old)
    return new


# ---------------------------------------------------------------- migration

def _unique(path):
    if not os.path.exists(path):
        return path
    base, ext = os.path.splitext(path)
    n = 2
    while os.path.exists(f"{base} ({n}){ext}"):
        n += 1
    return f"{base} ({n}){ext}"


def merge_move(src, dst, conflicts, log):
    """Move src (file or folder) to dst. Existing files at dst win; the old copy goes under conflicts.
    Never deletes a file. Returns the number of items moved."""
    if not os.path.lexists(src):
        return 0
    if os.path.abspath(src) == os.path.abspath(dst):
        return 0
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.lexists(dst):
        try:
            os.replace(src, dst)
        except OSError:
            shutil.move(src, dst)   # another drive: copy, then remove the source (only after the copy worked)
        log(f"moved {src} -> {dst}")
        return 1
    if os.path.isdir(src) and os.path.isdir(dst) and not os.path.islink(src):
        moved = 0
        for name in sorted(os.listdir(src)):
            moved += merge_move(os.path.join(src, name), os.path.join(dst, name), os.path.join(conflicts, name), log)
        try:
            os.rmdir(src)   # only when it is empty now
        except OSError:
            pass
        return moved
    keep = _unique(conflicts)
    os.makedirs(os.path.dirname(keep), exist_ok=True)
    try:
        os.replace(src, keep)
    except OSError:
        shutil.move(src, keep)
    log(f"kept both: {dst} stays, the old copy is in {keep}")
    return 1


def _copy_if_missing(src, dst, log):
    if os.path.isfile(src) and not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        log(f"copied {src} -> {dst}")
        return 1
    return 0


def is_checkout(root):
    """A git checkout of the Open Vanilla repo (or its launcher folder), as opposed to an install."""
    return any(os.path.exists(os.path.join(root, *rel)) for rel in
               ((".git",), ("launcher", "openvanilla_launcher.py"), ("openvanilla_launcher.py",)))


def migration_plan(layout, legacy_roots, frozen, env=None):
    """[(kind, src, dst)] for an old install. kind: move | copy | engine | retire."""
    env = os.environ if env is None else env
    plan = []
    for root in legacy_roots:
        root = os.path.abspath(root)
        cfg = os.path.join(root, ENGINE_CONFIG)
        plan.append(("move", os.path.join(cfg, "AddOns"), layout.addons_enabled))
        plan.append(("move", os.path.join(cfg, "AddOns.disabled"), layout.addons_disabled))
        if os.path.abspath(cfg) != os.path.abspath(layout.engine_config):
            plan.append(("move", cfg, layout.engine_config))   # WTF, saved variables (AddOns already moved)
        if not is_checkout(root):   # a source checkout's solo\ and host\ hold tracked build files, not user data
            plan.append(("move", os.path.join(root, "solo"), layout.solo_pack))
            plan.append(("move", os.path.join(root, "host"), layout.hosted))
        for rel in (("launcher", "settings.json"), ("settings.json",)):
            plan.append(("copy", os.path.join(root, *rel), layout.settings_file))
        if frozen and root == layout.install:
            layout1 = any(os.path.isfile(os.path.join(root, n)) for n in LEGACY_LAUNCHER_EXES)
            for name in LEGACY_ENGINE_NAMES:
                # OpenWoW.exe was the engine only before layout 2 (beside "OpenWoW Launcher.exe"); since layout 2
                # it is the launcher (and during the rename bridge, OpenVanilla.exe's twin): never move it then.
                if name in LAUNCHER_EXES and not layout1:
                    continue
                plan.append(("engine", os.path.join(root, name), layout.engine_exe))
            for name in OLD_ENGINE_EXES:   # Game\OpenWoW Game.exe -> Game\Open Vanilla Game.exe
                plan.append(("engine", os.path.join(layout.game, name), layout.engine_exe))
            for name in LEGACY_LAUNCHER_EXES:
                plan.append(("retire", os.path.join(root, name), os.path.join(layout.backups, "old-launcher", name)))
            if os.path.isdir(os.path.join(root, "_internal")) and INTERNAL_DIR != "_internal":
                plan.append(("retire", os.path.join(root, "_internal"),
                             os.path.join(layout.backups, "old-launcher", "_internal")))
    appdata = env.get("APPDATA")
    if appdata:
        plan.append(("copy", os.path.join(appdata, "OpenWoW", "settings.json"), layout.settings_file))   # pre-layout-2 roaming settings
    return plan


def migrate(layout, legacy_roots=None, frozen=False, env=None, now=None, log=None):
    """Bring an older install into this layout. Safe to call at every start. Returns what it did."""
    done = []
    logf = log or (lambda s: None)

    def note(s):
        done.append(s)
        logf(s)

    layout.ensure()
    stamp = time.strftime("%Y-%m-%d", time.localtime(now if now is not None else time.time()))
    conflicts_root = os.path.join(layout.backups, f"migration-{stamp}")
    roots = list(legacy_roots if legacy_roots is not None else [layout.install])
    for kind, src, dst in migration_plan(layout, roots, frozen, env):
        try:
            if kind == "copy":
                _copy_if_missing(src, dst, note)
            elif kind == "engine":
                if os.path.isfile(src) and not os.path.exists(dst):
                    merge_move(src, dst, os.path.join(conflicts_root, os.path.basename(src)), note)
            elif kind in ("move", "retire"):
                rel = os.path.relpath(src, os.path.dirname(os.path.dirname(src))) if os.path.lexists(src) else ""
                merge_move(src, dst, os.path.join(conflicts_root, rel or os.path.basename(src)), note)
        except OSError as e:   # a locked file (solo servers still running…): try again next start
            note(f"couldn't move {src} yet ({e})")
    record = {"layout": LAYOUT_VERSION, "mode": layout.mode}
    try:
        old = read_json(layout.layout_file) or {}
        record["history"] = (old.get("history") or [])[-20:] + ([{"when": stamp, "did": done}] if done else [])
        write_json(layout.layout_file, record)
    except OSError:
        pass
    return done


# ---------------------------------------------------------------- addons

def addon_names(folder):
    try:
        return sorted(n for n in os.listdir(folder) if os.path.isdir(os.path.join(folder, n)) and not n.startswith("."))
    except OSError:
        return []


def _fingerprint(folder):
    count = size = 0
    newest = 0.0
    for dirpath, _, files in os.walk(folder):
        for f in files:
            try:
                st = os.stat(os.path.join(dirpath, f))
            except OSError:
                continue
            count += 1
            size += st.st_size
            newest = max(newest, st.st_mtime)
    return f"{count}:{size}:{int(newest)}"


def seed_shipped_addons(shipped_dir, layout, version):
    """Put the addons bundled with this launcher version into AddOns\\Enabled (or refresh them in
    Disabled when the player switched them off). Runs once per version. Returns the names updated."""
    if not shipped_dir or not os.path.isdir(shipped_dir):
        return []
    if os.path.abspath(shipped_dir) == os.path.abspath(layout.addons_enabled):
        return []
    marker = os.path.join(layout.addons, SHIPPED_FILE)
    if (read_json(marker) or {}).get("version") == version:
        return []
    layout.ensure()
    updated = []
    for name in addon_names(shipped_dir):
        off = os.path.join(layout.addons_disabled, name)
        dst = off if os.path.isdir(off) else os.path.join(layout.addons_enabled, name)
        shutil.copytree(os.path.join(shipped_dir, name), dst, dirs_exist_ok=True)
        updated.append(name)
    write_json(marker, {"version": version, "addons": updated})
    return updated


def sync_addons(enabled_dir, client_addons_dir):
    """Mirror AddOns\\Enabled into one client's AddOns folder before it starts.

    Only touches folders the launcher put there itself (listed in .openvanilla-managed.json): a player's own
    addon of the same name is left alone and reported. Returns dict(copied, removed, skipped)."""
    out = {"copied": [], "removed": [], "skipped": []}
    if not client_addons_dir:
        return out
    if os.path.abspath(enabled_dir) == os.path.abspath(client_addons_dir):
        return out
    os.makedirs(client_addons_dir, exist_ok=True)
    mpath = os.path.join(client_addons_dir, MANAGED_FILE)
    managed = read_json(mpath) or {}
    want = {n: _fingerprint(os.path.join(enabled_dir, n)) for n in addon_names(enabled_dir)}
    present = {n.lower(): n for n in addon_names(client_addons_dir)}
    for name in list(managed):
        if name not in want:
            real = present.get(name.lower())
            if real:
                shutil.rmtree(os.path.join(client_addons_dir, real), ignore_errors=True)   # our own copy
            managed.pop(name)
            out["removed"].append(name)
    for name, fp in want.items():
        real = present.get(name.lower())
        if real and name not in managed:
            out["skipped"].append(name)   # the player's own addon: never overwritten
            continue
        if real and managed.get(name) == fp:
            continue
        dst = os.path.join(client_addons_dir, real or name)
        if real:
            shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(os.path.join(enabled_dir, name), dst)
        managed[name] = fp
        out["copied"].append(name)
    write_json(mpath, managed)
    return out


# ---------------------------------------------------------------- small helpers

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def ensure_launcher_name(layout, frozen, exe=None, log=None):
    """The rename bridge: a launcher still running as OpenWoW.exe (updated by an older updater, which only
    copies that name) puts its OpenVanilla.exe twin beside itself, so shortcuts and the next update find it.
    Returns the path it created, or None."""
    exe = os.path.abspath(exe or sys.executable)
    if not frozen or os.path.basename(exe).lower() != OLD_LAUNCHER_EXE.lower():
        return None
    if os.path.abspath(os.path.dirname(exe)) != os.path.abspath(layout.install):
        return None
    new = os.path.join(layout.install, LAUNCHER_EXE)
    if os.path.exists(new):
        return None
    try:
        shutil.copy2(exe, new)
    except OSError as e:
        if log:
            log(f"couldn't add {LAUNCHER_EXE} yet ({e})")
        return None
    if log:
        log(f"added {new} (the launcher's new name)")
    return new


def find_engine(layout, extra_dirs=()):
    """The engine binary: Game\\Open Vanilla Game.exe (or its older name), else an older name beside the launcher (dev/old)."""
    if os.path.isfile(layout.engine_exe):
        return layout.engine_exe
    names = (ENGINE_EXE,) + NEXT_ENGINE_NAMES + LEGACY_ENGINE_NAMES + ("OpenWoW", "benilla")
    for d in (layout.game,) + tuple(extra_dirs):
        for n in names:
            if n in LAUNCHER_EXES and os.path.isdir(os.path.join(d, INTERNAL_DIR)):
                continue   # beside app\ this name is a launcher (OpenVanilla.exe or its OpenWoW.exe twin), not the engine
            p = os.path.join(d, n)
            if os.path.isfile(p) and os.path.abspath(p) != os.path.abspath(sys.executable):
                return p
    return None
