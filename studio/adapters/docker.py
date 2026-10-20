"""The wenilla-realm Docker Compose stack (wenilla's recommended way to host).

Studio runs on the VPS itself (studio_server.py, bound to 127.0.0.1) next to the compose folder,
by default /opt/wenilla-realm. Nothing in the stack publishes its database or SOAP port, so
Studio reaches them on the containers' bridge addresses, which the host can always route to.
Reach Studio from your PC with an SSH tunnel: ssh -L 18091:127.0.0.1:18091 root@your-server
"""
import asyncio
import json
import os
import shutil

from ..realmdata import SqlRealmData
from .base import DB_NAMES, Adapter


def _read_env(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and k and not k.startswith("#"):
                    out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


class DockerAdapter(Adapter):
    mode = "docker"
    label = "wenilla-realm (Docker)"

    def __init__(self, base_dir, state_dir):
        super().__init__(base_dir, state_dir)
        self.dir = os.environ.get("STUDIO_COMPOSE_DIR", "/opt/wenilla-realm")
        self.env = _read_env(os.path.join(self.dir, ".env"))
        self.db_service = os.environ.get("STUDIO_DB_SERVICE", "mariadb")
        self.world_service = os.environ.get("STUDIO_WORLD_SERVICE", "mangosd")
        self.db_password = os.environ.get("STUDIO_DB_PASSWORD") or self.env.get("DB_ROOT_PASSWORD", "")
        self.backups_dir = os.environ.get("STUDIO_BACKUPS_DIR", os.path.join(state_dir, "backups"))
        self._ips = {}

    # docker plumbing --------------------------------------------------------------------
    async def _run(self, *args, input_bytes=None, timeout=120, env=None, stdout=None):
        if not os.path.isdir(self.dir):
            raise RuntimeError(f"no wenilla-realm folder at {self.dir}; set STUDIO_COMPOSE_DIR to where compose.yaml is")
        if not shutil.which("docker"):
            raise RuntimeError("the docker command isn't installed or isn't on PATH")
        proc = await asyncio.create_subprocess_exec(
            "docker", *args, cwd=self.dir, env=env or os.environ.copy(),
            stdin=asyncio.subprocess.PIPE if input_bytes else asyncio.subprocess.DEVNULL,
            stdout=stdout or asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            out, err = await asyncio.wait_for(proc.communicate(input_bytes), timeout)
        except asyncio.TimeoutError:
            proc.kill()
            raise RuntimeError(f"docker {args[0]} timed out")
        if proc.returncode != 0:
            raise RuntimeError((err or b"").decode(errors="replace").strip() or f"docker {' '.join(args[:2])} failed")
        return (out or b"").decode(errors="replace")

    async def _ps(self):
        text = await self._run("compose", "ps", "-a", "--format", "json", timeout=20)
        text = text.strip()
        if not text:
            return []
        if text.startswith("["):
            return json.loads(text)
        return [json.loads(line) for line in text.splitlines() if line.strip()]

    async def _ip(self, service):
        if service in self._ips:
            return self._ips[service]
        cid = (await self._run("compose", "ps", "-q", service, timeout=20)).strip().splitlines()
        if not cid:
            raise RuntimeError(f"the {service} container is not running")
        ip = (await self._run("inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", cid[0], timeout=20)).split()
        if not ip:
            raise RuntimeError(f"no network address for {service}")
        self._ips[service] = ip[0]
        return ip[0]

    async def resolve(self):
        """Point the database and SOAP clients at the containers' current addresses."""
        self._ips.clear()
        db_ip = await self._ip(self.db_service)
        self.data = SqlRealmData(db_ip, 3306, "root", self.db_password, **DB_NAMES)
        try:
            self.soap_url = f"http://{await self._ip(self.world_service)}:7878/"
        except RuntimeError:
            pass

    async def ready(self, refresh=False):
        if refresh or self.data is None:
            await self.resolve()

    async def soap(self, command, user, password):
        if self.soap_url.startswith("http://127.0.0.1"):
            await self.resolve()
        return await super().soap(command, user, password)

    # services ---------------------------------------------------------------------------
    async def services(self):
        rows = await self._ps()
        stats = {}
        try:
            for line in (await self._run("stats", "--no-stream", "--format", "{{json .}}", timeout=20)).splitlines():
                s = json.loads(line)
                stats[s.get("Name")] = s
        except (RuntimeError, ValueError):
            pass
        out = []
        for r in rows:
            name = r.get("Service") or r.get("Name")
            st = (r.get("State") or "").lower()
            health = (r.get("Health") or "").lower()
            state = "running" if st == "running" and health in ("", "healthy") else \
                    "starting" if st in ("restarting", "created") or health == "starting" else \
                    "stopped" if st in ("exited", "dead", "paused") else "unknown"
            s = stats.get(r.get("Name"), {})
            label = {"mariadb": "Database", "realmd": "Login server", "mangosd": "World server",
                     "realm": "Website and sign-in", "caddy": "HTTPS gateway"}.get(name, name)
            out.append({"id": name, "label": label, "detail": f"{name} · {r.get('Image', '')}", "state": state,
                        "cpu": _pct(s.get("CPUPerc")), "mem_mb": _mem(s.get("MemUsage")), "controllable": True})
        return out

    async def control(self, action, service, creds=None):
        if action not in ("start", "stop", "restart"):
            raise ValueError("unknown action")
        args = ["compose", action] + ([] if service == "all" else [service])
        await self._run(*args, timeout=300)
        self._ips.clear()
        return f"{action} {'every service' if service == 'all' else service}: done"

    def log_sources(self):
        return [{"id": s, "label": s} for s in ("mangosd", "realmd", self.db_service, "realm", "caddy")]

    async def logs(self, source, lines=200):
        text = await self._run("compose", "logs", "--no-color", "--no-log-prefix", "--tail", str(int(lines)), source, timeout=30)
        return text.splitlines()[-int(lines):]

    async def dump(self, path):
        env = {**os.environ, "MYSQL_PWD": self.db_password}
        with open(path, "wb") as f:
            await self._run("compose", "exec", "-T", "-e", "MYSQL_PWD", self.db_service, "mariadb-dump", "-uroot",
                            "--single-transaction", "--routines", "--databases", *DB_NAMES.values(),
                            env=env, stdout=f, timeout=1800)

    def security_checks(self):
        out = []
        if not self.db_password:
            out.append({"level": "warning", "text": f"No database password found in {self.dir}/.env (DB_ROOT_PASSWORD)."})
        return out


def _pct(v):
    try:
        return round(float(str(v).rstrip("%")), 1)
    except (TypeError, ValueError):
        return None


def _mem(v):
    try:
        used = str(v).split("/")[0].strip()
        num = float("".join(ch for ch in used if ch.isdigit() or ch == "."))
        unit = used.lstrip("0123456789.").strip().lower()
        return round(num * {"b": 1 / 2**20, "kib": 1 / 1024, "mib": 1, "gib": 1024, "kb": 1 / 1000, "mb": 1, "gb": 1000}.get(unit, 1))
    except (TypeError, ValueError):
        return None
