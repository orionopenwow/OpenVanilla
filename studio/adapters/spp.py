"""SPP Classics on a Windows PC: MySQL on 3310, realmd.exe, mangosd.exe, this web backend on 18090.

Studio runs inside asset_server.py here. It starts services with server_control.py (the same code
the old control panel uses) and finds running ones by their executable path inside the SPP
folder, so it can stop services the old panel started, and never touches another MySQL or WoW
server on the same PC.
"""
import asyncio
import glob
import os
import re
import socket
import sys

from ..realmdata import SqlRealmData
from .base import DB_NAMES, Adapter

try:
    import psutil
except ImportError:  # metrics and stop need psutil; start still works without it
    psutil = None


def _port_open(port, host="127.0.0.1"):
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


class SppAdapter(Adapter):
    mode = "spp"
    label = "SPP Classics (Windows)"

    def __init__(self, base_dir, state_dir):
        super().__init__(base_dir, state_dir)
        if base_dir not in sys.path:
            sys.path.insert(0, base_dir)
        import server_control as sc  # noqa: E402  (lives next to asset_server.py)
        self.sc = sc
        try:
            import openvanilla_config as oc  # the packaged server reads openvanilla.json
            self.spp_root = oc.SPP_ROOT
            user, password = oc.MYSQL_USER, oc.MYSQL_PASSWORD
            host, port = "127.0.0.1", 3310
        except ImportError:
            self.spp_root = getattr(sc, "SPP_ROOT", "")
            user, password = getattr(sc, "MYSQL_USER", "root"), getattr(sc, "MYSQL_PASSWORD", "123456")
            host, port = getattr(sc, "MYSQL_HOST", "127.0.0.1"), int(getattr(sc, "MYSQL_PORT", 3310))
        self.db_password = password
        self.data = SqlRealmData(host, port, user, password, **DB_NAMES)
        self.db_dir = os.path.join(self.spp_root, "Server", "Database")
        self.bin_dir = os.path.join(self.spp_root, "Server", "Binaries", "vanilla", "Bin64")
        self.settings_dir = os.path.join(self.spp_root, "Settings", "vanilla")
        self.backups_dir = os.path.join(base_dir, "backups")  # where the old panel's backups already are
        self._busy = False

    # processes --------------------------------------------------------------------------
    SERVICES = (
        ("mysql", "Database", 3310, "mysqld.exe"),
        ("realmd", "Login server", 3724, "realmd.exe"),
        ("mangosd", "World server", 8085, "mangosd.exe"),
        ("web", "Website and Studio", 18090, None),
    )

    def _procs(self, exe):
        if not psutil or not exe:
            return []
        root = os.path.normcase(os.path.realpath(self.spp_root))
        out = []
        for p in psutil.process_iter(["name", "exe"]):
            try:
                if (p.info["name"] or "").lower() == exe and os.path.normcase(p.info["exe"] or "").startswith(root):
                    out.append(p)
            except (psutil.Error, OSError):
                continue
        return out

    async def services(self):
        def work():
            rows = []
            for sid, label, port, exe in self.SERVICES:
                up = _port_open(port)
                procs = self._procs(exe)
                cpu = mem = None
                if procs:
                    try:
                        cpu = round(sum(p.cpu_percent(interval=None) for p in procs), 1)
                        mem = round(sum(p.memory_info().rss for p in procs) / 2**20)
                    except psutil.Error:
                        pass
                state = "running" if up else ("starting" if procs else "stopped")
                rows.append({"id": sid, "label": label, "detail": f"port {port}", "state": state,
                             "cpu": cpu, "mem_mb": mem, "controllable": sid != "web"})
            return rows
        return await asyncio.to_thread(work)

    async def control(self, action, service, creds=None):
        if self._busy:
            raise RuntimeError("another start or stop is still running")
        if action not in ("start", "stop", "restart"):
            raise ValueError("unknown action")
        if service == "web":
            raise ValueError("Studio runs inside the website service, so it can't stop itself")
        order = ["mysql", "realmd", "mangosd"] if service == "all" else [service]
        self._busy = True
        try:
            if action in ("stop", "restart"):
                for sid in reversed(order):
                    await self._stop(sid, creds)
            if action in ("start", "restart"):
                for sid in order:
                    ok = await asyncio.to_thread(self._start, sid)
                    if not ok:
                        raise RuntimeError(f"{sid} did not start; see the log")
        finally:
            self._busy = False
        return f"{action} {'all services' if service == 'all' else service}: done"

    def _start(self, sid):
        return {"mysql": self.sc.start_database, "realmd": self.sc.start_realmd, "mangosd": self.sc.start_mangosd}[sid]()

    async def _stop(self, sid, creds):
        if sid == "mangosd" and creds and _port_open(7878):
            try:  # a clean shutdown saves every character first
                await self.soap("server shutdown 1", *creds)
                for _ in range(60):
                    if not self._procs("mangosd.exe"):
                        return
                    await asyncio.sleep(1)
            except Exception:
                pass
        if sid == "mysql":
            admin = os.path.join(self.db_dir, "bin", "mysqladmin.exe")
            if os.path.isfile(admin) and _port_open(3310):
                env = {**os.environ, "MYSQL_PWD": self.db_password}
                proc = await asyncio.create_subprocess_exec(admin, "-h", "127.0.0.1", "-P", "3310", "-u", self.data.cfg["user"], "shutdown",
                                                            env=env, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
                await asyncio.wait_for(proc.wait(), 30)
                for _ in range(30):
                    if not _port_open(3310):
                        return
                    await asyncio.sleep(0.5)
        exe = {"mysql": "mysqld.exe", "realmd": "realmd.exe", "mangosd": "mangosd.exe"}[sid]
        for p in self._procs(exe):
            try:
                p.terminate()
                p.wait(10)
            except psutil.Error:
                pass

    # logs -------------------------------------------------------------------------------
    def _log_files(self):
        files = {}
        startup = os.path.join(self.base_dir, "mangosd-startup.log")
        if os.path.isfile(startup):
            files["startup"] = ("World server startup", startup)
        logs_dir = None
        conf = self.conf_path()
        try:
            with open(conf, encoding="utf-8", errors="replace") as f:
                m = re.search(r'^\s*LogsDir\s*=\s*"?([^"\r\n]*)"?', f.read(), re.M)
            if m and m.group(1).strip():
                logs_dir = m.group(1).strip()
                if not os.path.isabs(logs_dir):
                    logs_dir = os.path.join(self.settings_dir, logs_dir)
        except OSError:
            pass
        for d in filter(None, [logs_dir, os.path.join(self.spp_root, "Logs"), os.path.join(self.spp_root, "Server", "Logs"), self.settings_dir]):
            for name, key, label in (("Server.log", "world", "World server"), ("Realmd.log", "login", "Login server"),
                                     ("DBErrors.log", "dberrors", "Database errors")):
                for path in glob.glob(os.path.join(d, name)):
                    files.setdefault(key, (label, path))
        return files

    def log_sources(self):
        return [{"id": k, "label": v[0]} for k, v in self._log_files().items()]

    async def logs(self, source, lines=200):
        f = self._log_files().get(source)
        if not f:
            return []
        return await asyncio.to_thread(_tail, f[1], int(lines))

    # backups ----------------------------------------------------------------------------
    async def dump(self, path):
        exe = os.path.join(self.db_dir, "bin", "mysqldump.exe")
        if not os.path.isfile(exe):
            raise RuntimeError("mysqldump.exe not found in SPP's database folder")
        env = {**os.environ, "MYSQL_PWD": self.db_password}
        with open(path, "wb") as f:
            proc = await asyncio.create_subprocess_exec(exe, "-h", "127.0.0.1", "-P", "3310", "-u", self.data.cfg["user"],
                                                        "--single-transaction", "--routines", "--databases", *DB_NAMES.values(),
                                                        env=env, stdout=f, stderr=asyncio.subprocess.PIPE)
            _, err = await asyncio.wait_for(proc.communicate(), 1800)
        if proc.returncode != 0:
            raise RuntimeError((err or b"").decode(errors="replace").strip() or "mysqldump failed")

    # config -----------------------------------------------------------------------------
    def conf_path(self):
        return os.path.join(self.settings_dir, "mangosd.conf")

    def soap_config(self):
        vals = {}
        try:
            with open(self.conf_path(), encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = re.match(r"\s*(SOAP\.\w+)\s*=\s*\"?([^\"\r\n]*)\"?", line)
                    if m:
                        vals[m.group(1)] = m.group(2).strip()
        except OSError:
            return None
        return vals

    def enable_soap(self):
        """Turn the SOAP console on, bound to this PC only. Keeps a .bak copy. Needs a world restart."""
        path = self.conf_path()
        with open(path, encoding="utf-8", errors="replace", newline="") as f:
            text = f.read()
        want = {"SOAP.Enabled": "1", "SOAP.IP": '"127.0.0.1"', "SOAP.Port": "7878"}
        for k, v in want.items():
            pat = re.compile(rf"^(\s*){re.escape(k)}\s*=.*$", re.M)
            text = pat.sub(lambda m: f"{m.group(1)}{k} = {v}", text) if pat.search(text) else text + f"\n{k} = {v}\n"
        bak = path + ".bak"
        if not os.path.exists(bak):
            with open(bak, "w", encoding="utf-8", newline="") as f, open(path, encoding="utf-8", errors="replace", newline="") as src:
                f.write(src.read())
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)

    def security_checks(self):
        out = []
        if self.db_password == "123456":
            out.append({"level": "warning", "text": "The database still uses SPP's default password (123456). "
                        "Change it before anyone else can reach this PC; guidebook chapter 11 shows how."})
        soap = self.soap_config()
        if soap is not None and soap.get("SOAP.Enabled", "0") != "1":
            out.append({"level": "info", "fix": "enable_soap",
                        "text": "The world server's SOAP console is off, so messages, kicks, bans and timed restarts "
                                "can't be sent. Turn it on (this PC only), then restart the world server."})
        if soap and soap.get("SOAP.Enabled") == "1" and soap.get("SOAP.IP", "127.0.0.1") not in ("127.0.0.1", "localhost"):
            out.append({"level": "warning", "text": f"SOAP listens on {soap.get('SOAP.IP')}, not just this PC. Set SOAP.IP = \"127.0.0.1\" in mangosd.conf."})
        return out


def _tail(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 256 * 1024))
            data = f.read().decode("utf-8", errors="replace")
        return data.splitlines()[-n:]
    except OSError:
        return []
