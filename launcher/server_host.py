"""HOST > Dedicated server: run an SPP Classics realm (database, login, world), its website and Server
Studio from the launcher itself. Replaces the separate OpenVanilla-Server.zip + launcher_gui.py control panel.

    cfg = load_config(settings, layout)          openvanilla.json (the server folder the launcher saved),
                                                 Settings\\server.json, then defaults
    ded = Dedicated(spp.SppPaths(...), cfg, layout)
    ded.start_all(report) / ded.stop_all()       SPP's mysqld/realmd/mangosd, hidden
    ded.start_web() / ded.stop_web()             the web backend: website, sign-up API, browser relay,
                                                 Server Studio at http://127.0.0.1:18090/studio/
    ded.gm("server info")                        world console (stdin of a world server we started;
                                                 SOAP when openvanilla.json has soap_user/soap_pass)
    ded.log_tail("mangosd")

Frozen, the web backend is this same OpenVanilla.exe run as `OpenVanilla.exe --run web-backend 18090` (aiohttp,
asset_server, studio are frozen in) serving Server\\www; from source it is `python asset_server.py 18090`,
and missing packages (aiohttp, pymysql) are pip-installed for the user first.

Standard library only; Python 3.10 compatible.
"""
import importlib.util
import json
import os
import subprocess
import sys
import time

import spp

WEB_PORT = 18090             # the web backend on this PC: website, sign-up API, browser-game relay, Studio
PUBLIC_HTTPS_PORT = 8090     # the optional HTTPS gateway (Caddy) players on the internet reach the website on
PORTS = (
    ("db", 3310, "Database", "this PC only"),
    ("realm", 3724, "Login server", "players connect here: open TCP 3724 for internet players"),
    ("world", 8085, "World server", "players connect here: open TCP 8085 for internet players"),
    ("web", WEB_PORT, "Website + Server Studio", f"this PC only: http://127.0.0.1:{WEB_PORT}/"),
)
NEEDED_PACKAGES = (("aiohttp", "aiohttp"), ("pymysql", "pymysql"))
DETACHED = 0x00000008 | 0x00000200 | 0x08000000   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def load_config(settings, lay):
    """Merged server settings. openvanilla.json beside the server folder the older launcher installed (it wrote
    spp_root, mysql_user, mysql_password) is read first, so an existing host keeps working."""
    cfg = {"spp_root": None, "mysql_user": None, "mysql_password": None, "soap_user": None, "soap_pass": None,
           "soap_port": 7878, "realm_address": "127.0.0.1"}
    sources = []
    if settings.get("server_dir"):
        sources.append(os.path.join(settings["server_dir"], "openvanilla.json"))
    sources += [os.path.join(lay.server, "openvanilla.json"), os.path.join(lay.settings_dir, "server.json")]
    for path in sources:
        for k, v in _read(path).items():
            if k in cfg and v not in (None, ""):
                cfg[k] = v
    if settings.get("spp_root") and not cfg["spp_root"]:
        cfg["spp_root"] = settings["spp_root"]
    return cfg


def save_config(lay, cfg):
    path = os.path.join(lay.settings_dir, "server.json")
    os.makedirs(lay.settings_dir, exist_ok=True)
    keep = {k: v for k, v in cfg.items() if v not in (None, "")}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(keep, f, indent=2)
    os.replace(tmp, path)
    return path


def resolve_paths(cfg, lay, find=spp.find_existing):
    """The SPP install to run: the configured folder, Play Solo's (Realms\\Solo), or one found on this PC."""
    root = cfg.get("spp_root")
    if root:
        for cand in (root, os.path.join(root, spp.SERVER_FOLDER)):
            if spp.is_spp_server(cand) or os.path.isdir(os.path.join(cand, "Server", "Database")):
                return spp.SppPaths(lay.solo, server=cand)
    solo = spp.SppPaths(lay.solo)
    if spp.is_spp_server(solo.server):
        return solo
    found = find()
    return spp.SppPaths(lay.solo, server=found) if found else None


def missing_packages(find_spec=importlib.util.find_spec):
    return [pip for mod, pip in NEEDED_PACKAGES if find_spec(mod) is None]


def ensure_packages(frozen, run=subprocess.run, find_spec=importlib.util.find_spec):
    """Source runs only: pip-install what the web backend needs. Returns (ok, message)."""
    if frozen:
        return True, "bundled"
    need = missing_packages(find_spec)
    if not need:
        return True, "installed"
    r = run([sys.executable, "-m", "pip", "install", "--user", "--quiet", "--disable-pip-version-check", *need],
            capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"pip couldn't install {', '.join(need)}: {(r.stderr or '').strip()[-200:]}"
    return True, f"installed {', '.join(need)}"


def web_backend_argv(frozen, exe, source_root, port=WEB_PORT):
    if frozen:
        return [exe, "--run", "web-backend", str(port)]
    return [exe, os.path.join(source_root, "asset_server.py"), str(port)]


class Dedicated:
    def __init__(self, paths, cfg, lay, frozen=False, exe=None, source_root=None, popen=subprocess.Popen,
                 run=subprocess.run, port_open=spp.is_port_open, sleep=time.sleep):
        self.p, self.cfg, self.lay = paths, cfg, lay
        self.frozen, self.exe, self.source_root = frozen, exe or sys.executable, source_root
        self.popen, self.run, self.port_open = popen, run, port_open
        self.servers = spp.SppServers(paths, popen=popen, run=run, port_open=port_open, sleep=sleep, logs_dir=lay.logs,
                                      realm_address=cfg.get("realm_address") or "127.0.0.1", solo_account=False)
        if cfg.get("mysql_user") and cfg.get("mysql_password"):
            host, port, _, _ = self.servers.db
            self.servers.db = (host, port, cfg["mysql_user"], cfg["mysql_password"])
        self.web = None

    def status(self):
        return {key: self.port_open(port) for key, port, _, _ in PORTS}

    def start_all(self, report=None, cancel=None):
        return self.servers.start(report, cancel)

    def stop_all(self, report=None):
        self.stop_web()
        self.servers.stop(report)

    def start_web(self):
        if self.port_open(WEB_PORT):
            return "already running"
        ok, msg = ensure_packages(self.frozen, self.run)
        if not ok:
            raise spp.SppError(msg)
        host, port, user, pw = self.servers.db
        env = dict(os.environ, PYTHONUNBUFFERED="1", SPP_ROOT=self.p.server, MYSQL_HOST=host, MYSQL_PORT=str(port),
                   MYSQL_USER=user, MYSQL_PASSWORD=pw, OPENVANILLA_STATE_DIR=self.lay.settings_dir)
        if self.frozen:
            env["OPENVANILLA_SERVER_DIR"] = self.lay.server
        os.makedirs(self.lay.logs, exist_ok=True)
        with open(os.path.join(self.lay.logs, "web-backend.log"), "ab") as log:
            kw = dict(cwd=self.lay.server if self.frozen else self.source_root, env=env, stdin=subprocess.DEVNULL,
                      stdout=log, stderr=subprocess.STDOUT)
            if sys.platform == "win32":
                kw["creationflags"] = DETACHED
            self.web = self.popen(web_backend_argv(self.frozen, self.exe, self.source_root), **kw)
        return "starting"

    def stop_web(self):
        if self.web is not None and self.web.poll() is None:
            self.web.terminate()
        self.web = None

    def gm(self, command):
        """One world-console command. Returns the reply text (the console's own output goes to the log)."""
        command = (command or "").strip()
        if not command:
            return ""
        if not self.port_open(8085):
            raise spp.SppError("The world server isn't running.")
        m = self.servers.procs.get("mangosd")
        if m is not None and m.poll() is None:
            self.servers.console(command)
            return "sent (the reply appears in the world log below)"
        if self.cfg.get("soap_user") and self.cfg.get("soap_pass"):
            import play_local
            return play_local.soap_command(command, self.cfg["soap_user"], self.cfg["soap_pass"], int(self.cfg.get("soap_port") or 7878))
        raise spp.SppError("This world server was started outside Open Vanilla. Stop it and start it here to use the console, "
                           "or turn on SOAP (SOAP.Enabled = 1 in mangosd.conf) and add soap_user / soap_pass to "
                           "Settings\\server.json.")

    def log_tail(self, name="mangosd", n=40):
        for path in (self.servers.log_path(name), os.path.join(self.p.logs, "Server.log")):
            try:
                with open(path, "rb") as f:
                    f.seek(0, os.SEEK_END)
                    size = f.tell()
                    f.seek(max(0, size - 16384))
                    return f.read().decode("utf-8", "replace").splitlines()[-n:]
            except OSError:
                continue
        return []
