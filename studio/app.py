"""Open Vanilla Server Studio: the admin API behind /studio.

Mounted into the web backend (asset_server.py) on a Windows SPP host, or run on its own by
studio_server.py next to the wenilla-realm Docker stack.

Security model (P1):
  * Local only. Every /studio/api request must come straight from this machine: a loopback peer,
    no proxy forwarding headers (so nothing that came in through Caddy), and a localhost Host
    header (so a web page elsewhere can't reach it by DNS rebinding). A VPS host uses an SSH tunnel.
  * Sign in with a realm account of GM level 3, checked against its stored SRP6 verifier.
  * Session cookie: random, HttpOnly, SameSite=Strict, path /studio, 8 h max, 2 h idle.
  * Every POST carries the session's CSRF token in X-Studio-CSRF.
  * The admin's password is kept in memory for the session only, to sign SOAP commands.
"""
import asyncio
import datetime as dt
import ipaddress
import os
import re
import secrets
import socket
import time
import urllib.parse

from aiohttp import web

from . import srp
from .adapters import make_adapter
from .journal import Journal
from .realmdata import NAME_RE, PASS_RE, RealmDataError
from .soap import SoapError, SoapUnavailable

ROLES = {0: "Player", 1: "Moderator", 2: "Game Master", 3: "Administrator"}
SESSION_COOKIE = "ow_studio"
SESSION_MAX = 8 * 3600
SESSION_IDLE = 2 * 3600
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"} | {h.strip().lower() for h in os.environ.get("STUDIO_ALLOWED_HOSTS", "").split(",") if h.strip()}
BACKUP_RE = re.compile(r"^[\w.-]+\.sql(\.gz)?$")
HOST_RE = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
DURATION_RE = re.compile(r"^(-1|\d+[smhdw]?)$")

KEY = web.AppKey("studio", object) if hasattr(web, "AppKey") else "studio"


class ApiError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


class Studio:
    def __init__(self, base_dir, state_dir=None, mode=None):
        self.base_dir = base_dir
        self.state_dir = state_dir or os.path.join(base_dir, "studio_state")
        self.adapter = make_adapter(mode, base_dir, self.state_dir)
        self.journal = Journal(os.path.join(self.state_dir, "studio.sqlite"))
        os.makedirs(self.adapter.backups_dir, exist_ok=True)
        self.sessions = {}
        self.attempts = {}
        self.restart_at = None
        self._task = None
        self._backup_running = False
        self.undo_lock = asyncio.Lock()

    # ── helpers ─────────────────────────────────────────────────────────────────────────
    async def db(self, fn, *args):
        await self.adapter.ready()
        try:
            return await asyncio.to_thread(getattr(self.adapter.data, fn), *args)
        except RealmDataError as e:
            if "can't reach" in str(e):
                await self.adapter.ready(refresh=True)
                try:
                    return await asyncio.to_thread(getattr(self.adapter.data, fn), *args)
                except RealmDataError as e2:
                    raise ApiError(f"The database isn't answering: {e2}", 503) from e2
            raise ApiError(str(e), 400) from e

    async def soap(self, sess, command):
        try:
            return await self.adapter.soap(command, sess["user"], sess["password"])
        except SoapUnavailable as e:
            raise ApiError(f"The world server isn't answering commands: {e}. Is it running, with SOAP turned on?", 503) from e
        except SoapError as e:
            raise ApiError(f"The world server said: {e}", 400) from e

    def log(self, text, level="info"):
        self.journal.event(text, level)

    # ── background: scheduled backups ───────────────────────────────────────────────────
    def backup_settings(self):
        return {"enabled": True, "hour": 4, "keep_days": 14, **(self.journal.setting("backups", {}) or {})}

    async def scheduler(self):
        while True:
            try:
                await asyncio.sleep(60)
                cfg = self.backup_settings()
                if not cfg["enabled"]:
                    continue
                now = dt.datetime.now()
                last = self.journal.setting("last_auto_backup")
                if now.hour == int(cfg["hour"]) and last != now.strftime("%Y-%m-%d"):
                    self.journal.set_setting("last_auto_backup", now.strftime("%Y-%m-%d"))
                    await self.make_backup("scheduled")
                    self.prune_backups(int(cfg["keep_days"]))
                if self.restart_at and time.time() > self.restart_at + 300:
                    self.restart_at = None
            except asyncio.CancelledError:
                raise
            except Exception as e:  # never let the loop die
                self.log(f"Scheduler: {e}", "error")

    async def make_backup(self, why="manual", user="Studio"):
        if self._backup_running:
            raise ApiError("A backup is already running.", 409)
        self._backup_running = True
        name = f"studio_{dt.datetime.now():%Y%m%d_%H%M%S}.sql"
        path = os.path.join(self.adapter.backups_dir, name)
        t0 = time.time()
        try:
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))  # dumps hold password verifiers
            await self.adapter.dump(path)
            if os.path.getsize(path) == 0:
                raise RuntimeError("the dump was empty")
        except Exception as e:
            try:
                os.remove(path)
            except OSError:
                pass
            self.log(f"Backup failed ({why}): {e}", "error")
            raise ApiError(f"Backup failed: {e}", 500) from e
        finally:
            self._backup_running = False
        self.log(f"Backup {name} written ({why}, {user}, {os.path.getsize(path) / 2**20:.1f} MB, {time.time() - t0:.0f} s).")
        return name

    def prune_backups(self, keep_days):
        cutoff = time.time() - keep_days * 86400
        for fn in os.listdir(self.adapter.backups_dir):
            p = os.path.join(self.adapter.backups_dir, fn)
            if fn.startswith("studio_") and BACKUP_RE.match(fn) and os.path.getmtime(p) < cutoff:
                os.remove(p)
                self.log(f"Removed old backup {fn} (older than {keep_days} days).")

    def list_backups(self):
        out = []
        d = self.adapter.backups_dir
        for fn in os.listdir(d):
            p = os.path.join(d, fn)
            if BACKUP_RE.match(fn) and os.path.isfile(p):
                out.append({"name": fn, "size": os.path.getsize(p), "mtime": os.path.getmtime(p),
                            "kind": "full" if fn.startswith("studio_") else "accounts + characters" if fn.startswith("accounts_characters") else "other"})
        return sorted(out, key=lambda b: -b["mtime"])

    # ── sessions ────────────────────────────────────────────────────────────────────────
    def session(self, request):
        tok = request.cookies.get(SESSION_COOKIE)
        s = self.sessions.get(tok) if tok else None
        now = time.time()
        if not s or now - s["created"] > SESSION_MAX or now - s["seen"] > SESSION_IDLE:
            if tok:
                self.sessions.pop(tok, None)
            return None
        s["seen"] = now
        return s

    def too_many_failures(self, key, limit, window=600):
        now = time.time()
        recent = [t for t in self.attempts.get(key, []) if now - t < window]
        self.attempts[key] = recent
        return len(recent) >= limit

    def record_failure(self, key, window=600):
        now = time.time()
        if len(self.attempts) > 5000:  # bounded memory
            for k in [k for k, ts in self.attempts.items() if not ts or now - ts[-1] > window]:
                del self.attempts[k]
        self.attempts.setdefault(key, []).append(now)

    def drop_sessions(self, account_id, keep=None):
        """Sign an account out everywhere (after its role, password or ban changes)."""
        for tok in [t for t, s in self.sessions.items() if s["account_id"] == account_id and t != keep]:
            del self.sessions[tok]

    async def still_admin(self, sess):
        """Re-check the account behind a session at most every 30 s: still GM 3, same password."""
        now = time.time()
        if now - sess.get("checked", 0) < 30:
            return True
        row = await self.db("auth_row", sess["user"])
        ok = bool(row) and int(row["gmlevel"] or 0) >= 3 and row["s"] == sess["salt"]
        sess["checked"] = now
        return ok


def is_local(request):
    """True only for a request made on this machine, not relayed through a proxy."""
    try:
        if not ipaddress.ip_address(request.remote or "0.0.0.0").is_loopback:
            return False
    except ValueError:
        return False
    for name in request.headers:
        n = name.lower()
        if n.startswith("x-forwarded-") or n in ("forwarded", "via", "x-real-ip", "x-client-ip", "true-client-ip", "cf-connecting-ip"):
            return False
    host = urllib.parse.urlsplit("//" + (request.host or "")).hostname or ""
    return host.lower() in LOCAL_HOSTS


def api(auth=True):
    def wrap(fn):
        async def handler(request):
            st = request.app[KEY]
            if not is_local(request):
                return web.json_response({"error": "Server Studio only answers on this computer. On a VPS, open an SSH tunnel "
                                                   "(ssh -L 18091:127.0.0.1:18091 you@server) and browse to http://localhost:18091/studio/."}, status=403)
            sess = None
            if auth:
                sess = st.session(request)
                if not sess:
                    return web.json_response({"error": "Please sign in again."}, status=401)
                given = request.headers.get("X-Studio-CSRF", "").encode("utf-8", "replace")
                if request.method == "POST" and not secrets.compare_digest(given, sess["csrf"].encode()):
                    return web.json_response({"error": "This page is out of date; reload it."}, status=403)
                try:
                    if not await st.still_admin(sess):
                        st.sessions.pop(request.cookies.get(SESSION_COOKIE), None)
                        st.log(f"Signed {sess['user']} out of Studio: no longer an Administrator, or the password changed.", "warning")
                        return web.json_response({"error": "Please sign in again."}, status=401)
                except ApiError:
                    pass  # database down: keep the session; every write needs the database anyway
            if request.method == "POST":
                origin = request.headers.get("Origin")
                if origin and origin.rstrip("/").lower() != f"{request.scheme}://{request.host}".lower():
                    return web.json_response({"error": "Cross-site request refused."}, status=403)
            try:
                body = {}
                if request.method == "POST" and request.can_read_body:
                    try:
                        body = await request.json()
                    except ValueError:
                        raise ApiError("Bad request body.")
                    if not isinstance(body, dict):
                        raise ApiError("Bad request body.")
                result = await fn(st, request, sess, body)
                if isinstance(result, web.StreamResponse):
                    return result
                return web.json_response(result, headers={"Cache-Control": "no-store"})
            except ApiError as e:
                return web.json_response({"error": str(e)}, status=e.status)
            except (ValueError, KeyError, TypeError) as e:
                return web.json_response({"error": f"Bad request: {e}"}, status=400)
            except Exception as e:  # last resort: say what happened, keep the server up
                st.log(f"{request.method} {request.path}: {e.__class__.__name__}: {e}", "error")
                return web.json_response({"error": f"Something went wrong: {e}"}, status=500)
        return handler
    return wrap


def _uname(sess):
    return sess["user"] if sess else "Studio"


# ── auth ────────────────────────────────────────────────────────────────────────────────
@api(auth=False)
async def h_login(st, request, sess, body):
    user = str(body.get("username", "")).strip().upper()
    pw = str(body.get("password", "")).strip().upper()
    if not NAME_RE.match(user) or not pw:
        raise ApiError("Enter your account name and password.", 400)
    if st.too_many_failures("user:" + user, 6) or st.too_many_failures("any", 40):
        raise ApiError("Too many failed sign-ins. Wait ten minutes and try again.", 429)
    row = await st.db("auth_row", user)
    if not row or not srp.check(user, pw, row["s"], row["v"]):
        st.record_failure("user:" + user)
        st.record_failure("any")
        st.log(f"Failed Studio sign-in for {user}.", "warning")
        raise ApiError("That account name and password don't match.", 401)
    if int(row["gmlevel"] or 0) < 3:
        st.log(f"Studio sign-in refused for {user}: not an Administrator.", "warning")
        raise ApiError("Only Administrator (GM 3) accounts can use Server Studio.", 403)
    tok = secrets.token_urlsafe(32)
    now = time.time()
    st.sessions[tok] = {"user": user, "account_id": row["id"], "password": pw, "csrf": secrets.token_urlsafe(24),
                        "created": now, "seen": now, "salt": row["s"], "checked": now}
    st.log(f"{user} signed in to Studio.")
    resp = web.json_response({"ok": True})
    resp.set_cookie(SESSION_COOKIE, tok, httponly=True, samesite="Strict", path="/studio", max_age=SESSION_MAX)
    return resp


@api()
async def h_logout(st, request, sess, body):
    st.sessions.pop(request.cookies.get(SESSION_COOKIE), None)
    resp = web.json_response({"ok": True})
    resp.del_cookie(SESSION_COOKIE, path="/studio")
    return resp


@api()
async def h_session(st, request, sess, body):
    return {"user": sess["user"], "csrf": sess["csrf"], "host": st.adapter.describe(), "roles": ROLES}


# ── overview & services ─────────────────────────────────────────────────────────────────
def _parse_info(text):
    out = {}
    m = re.search(r"Players online:\s*(\d+)(?:\s*\(max:\s*(\d+)\))?", text or "")
    if m:
        out["online"] = int(m.group(1))
        out["max"] = int(m.group(2)) if m.group(2) else None
    m = re.search(r"uptime:\s*(.+?)\.?\s*$", text or "", re.M | re.I)
    if m:
        out["uptime"] = m.group(1).strip()
    m = re.search(r"^(\S*MaNGOS\S*.*)$", text or "", re.M | re.I)
    if m:
        out["core"] = m.group(1).strip()
    return out


async def _safe(coro, default=None):
    try:
        return await coro
    except Exception as e:
        return {"error": str(e)} if default is None else default


@api()
async def h_overview(st, request, sess, body):
    services, counts, realm, info = await asyncio.gather(
        _safe(st.adapter.services(), []), _safe(st.db("counts")), _safe(st.db("realm")),
        _safe(st.adapter.soap("server info", sess["user"], sess["password"])))
    backups = st.list_backups()
    checks = st.adapter.security_checks()
    if not backups:
        checks.append({"level": "warning", "text": "There's no backup yet. Press Back up now."})
    elif time.time() - backups[0]["mtime"] > 3 * 86400:
        checks.append({"level": "warning", "text": "The newest backup is more than three days old."})
    return {
        "services": services,
        "counts": counts,
        "realm": realm,
        "info": _parse_info(info) if isinstance(info, str) else {"error": (info or {}).get("error")},
        "last_backup": backups[0] if backups else None,
        "backup_settings": st.backup_settings(),
        "restart_at": st.restart_at,
        "checks": checks,
        "changes": st.journal.changes(6),
        "host": st.adapter.describe(),
        "now": time.time(),
    }


@api()
async def h_services(st, request, sess, body):
    return {"services": await st.adapter.services()}


@api()
async def h_service_action(st, request, sess, body):
    action = request.match_info["action"]
    service = str(body.get("service", "all"))
    if action not in ("start", "stop", "restart"):
        raise ApiError("Unknown action.")
    known = {s["id"] for s in await st.adapter.services()} | {"all"}
    if service not in known:
        raise ApiError("Unknown service.")
    st.log(f"{sess['user']}: {action} {service}.")
    try:
        msg = await st.adapter.control(action, service, (sess["user"], sess["password"]))
    except (RuntimeError, ValueError) as e:
        st.log(f"{action} {service} failed: {e}", "error")
        raise ApiError(str(e), 500 if isinstance(e, RuntimeError) else 400)
    return {"ok": True, "message": msg}


@api()
async def h_logs(st, request, sess, body):
    source = request.query.get("source", "studio")
    lines = max(10, min(int(request.query.get("lines", 200)), 2000))
    sources = [{"id": "studio", "label": "Studio activity"}] + st.adapter.log_sources()
    if source == "studio":
        rows = [f"{dt.datetime.fromtimestamp(e['ts']):%Y-%m-%d %H:%M:%S} [{e['level']}] {e['text']}" for e in st.journal.events(lines)]
    elif source in {s["id"] for s in sources}:
        rows = await st.adapter.logs(source, lines)
    else:
        raise ApiError("Unknown log.")
    return {"sources": sources, "source": source, "lines": rows}


# ── accounts ────────────────────────────────────────────────────────────────────────────
@api()
async def h_accounts(st, request, sess, body):
    q = request.query.get("q", "").strip()[:16]
    if q and not re.fullmatch(r"[A-Za-z0-9]*", q):
        raise ApiError("Search by letters and digits only.")
    limit = max(1, min(int(request.query.get("limit", 50)), 200))
    offset = max(0, int(request.query.get("offset", 0)))
    role = request.query.get("role")
    return await st.db("list_accounts", q, limit, offset, int(role) if role not in (None, "") else None)


@api()
async def h_account_create(st, request, sess, body):
    name = str(body.get("username", "")).strip().upper()
    pw = str(body.get("password", "")).strip().upper()
    role = int(body.get("role", 0))
    if not NAME_RE.match(name):
        raise ApiError("Account names are 3 to 16 letters or digits.")
    if not PASS_RE.match(pw):
        raise ApiError("Passwords are 4 to 16 letters or digits (the 1.12.1 client's limit).")
    if role not in ROLES:
        raise ApiError("Unknown role.")
    s, v = srp.generate(name, pw)
    new_id = await st.db("create_account", name, s, v, role)
    st.journal.record(sess["user"], "players", f"Created account {name} as {ROLES[role]}", "create_account",
                      {"account_id": new_id, "username": name, "role": role}, undoable=False)
    st.log(f"{sess['user']} created account {name} ({ROLES[role]}).")
    return {"ok": True, "id": new_id, "message": f"Account {name} created."}


async def _account(st, request):
    acc = await st.db("account", int(request.match_info["id"]))
    if not NAME_RE.match(acc["username"] or ""):
        raise ApiError("This account's name has characters Studio can't send to the world server safely.")
    return acc


@api()
async def h_account_role(st, request, sess, body):
    acc = await _account(st, request)
    role = int(body.get("role"))
    if role not in ROLES:
        raise ApiError("Unknown role.")
    if acc["id"] == sess["account_id"] and role < 3:
        raise ApiError("You can't remove your own Administrator role here; ask another Administrator.")
    if acc["gmlevel"] == role:
        return {"ok": True, "message": "No change."}
    await st.db("set_gmlevel", acc["id"], role)
    st.drop_sessions(acc["id"])
    cid = st.journal.record(sess["user"], "players", f"{acc['username']}: {ROLES.get(acc['gmlevel'], acc['gmlevel'])} → {ROLES[role]}",
                            "role", {"account_id": acc["id"], "username": acc["username"], "from": acc["gmlevel"], "to": role})
    return {"ok": True, "change": cid, "message": f"{acc['username']} is now {ROLES[role]}. It applies the next time they log in."}


@api()
async def h_account_password(st, request, sess, body):
    acc = await _account(st, request)
    pw = str(body.get("password", "")).strip().upper()
    if not PASS_RE.match(pw):
        raise ApiError("Passwords are 4 to 16 letters or digits (the 1.12.1 client's limit).")
    s, v = srp.generate(acc["username"], pw)
    await st.db("set_verifier", acc["id"], s, v)
    st.drop_sessions(acc["id"], keep=request.cookies.get(SESSION_COOKIE))
    st.journal.record(sess["user"], "players", f"Reset the password of {acc['username']}", "password",
                      {"account_id": acc["id"], "username": acc["username"]}, undoable=False)
    if acc["id"] == sess["account_id"]:
        sess["password"], sess["salt"] = pw, s
    return {"ok": True, "message": f"{acc['username']}'s password was changed. Tell them the new one."}


@api()
async def h_account_ban(st, request, sess, body):
    acc = await _account(st, request)
    if acc["id"] == sess["account_id"]:
        raise ApiError("You can't ban yourself.")
    duration = str(body.get("duration", "1d")).strip().lower()
    reason = re.sub(r"[\x00-\x1f\x7f\"]+", " ", str(body.get("reason", ""))).strip()[:120] or "No reason given"
    if not DURATION_RE.match(duration):
        raise ApiError("Duration looks like 30m, 12h, 7d, or -1 for permanent.")
    reply = await st.soap(sess, f"ban account {acc['username']} {duration} {reason}")
    st.drop_sessions(acc["id"])
    cid = st.journal.record(sess["user"], "players", f"Banned {acc['username']} ({'permanent' if duration == '-1' else duration}): {reason}",
                            "ban", {"account_id": acc["id"], "username": acc["username"], "duration": duration, "reason": reason})
    return {"ok": True, "change": cid, "message": reply or f"{acc['username']} is banned."}


@api()
async def h_account_unban(st, request, sess, body):
    acc = await _account(st, request)
    reply = await st.soap(sess, f"unban account {acc['username']}")
    st.journal.record(sess["user"], "players", f"Unbanned {acc['username']}", "unban",
                      {"account_id": acc["id"], "username": acc["username"]}, undoable=False)
    return {"ok": True, "message": reply or f"{acc['username']} is unbanned."}


@api()
async def h_kick(st, request, sess, body):
    name = request.match_info["name"]
    if not re.fullmatch(r"[A-Za-z]{2,12}", name):
        raise ApiError("That isn't a character name.")
    reply = await st.soap(sess, f"kick {name}")
    st.log(f"{sess['user']} kicked {name}.")
    return {"ok": True, "message": reply or f"{name} was kicked."}


@api()
async def h_online(st, request, sess, body):
    return {"players": await st.db("online_players")}


# ── messages & restarts ─────────────────────────────────────────────────────────────────
def _motd_from(reply):
    lines = (reply or "").splitlines()
    return "\n".join(lines[1:]).strip() if len(lines) > 1 else (reply or "").strip()


def _clean_text(text, limit):
    text = re.sub(r"[\x00-\x1f]+", " ", str(text or "")).strip()
    if not text:
        raise ApiError("Type a message first.")
    if len(text) > limit:
        raise ApiError(f"Keep it under {limit} characters.")
    return text


@api()
async def h_messages(st, request, sess, body):
    motd = await _safe(st.soap(sess, "server motd"))
    return {"motd": _motd_from(motd) if isinstance(motd, str) else None,
            "motd_error": None if isinstance(motd, str) else motd.get("error"),
            "restart_at": st.restart_at, "persist_motd": st.adapter.mode == "spp", "now": time.time()}


@api()
async def h_motd(st, request, sess, body):
    text = _clean_text(body.get("text"), 255)
    old = await _safe(st.soap(sess, "server motd"))
    old = _motd_from(old) if isinstance(old, str) else None
    await st.soap(sess, f"server set motd {text}")
    cid = st.journal.record(sess["user"], "messages", "Changed the message of the day", "motd", {"from": old, "to": text},
                            undoable=old is not None)
    return {"ok": True, "change": cid, "message": "Message of the day updated."}


@api()
async def h_announce(st, request, sess, body):
    text = _clean_text(body.get("text"), 255)
    style = "notify" if body.get("style") == "notify" else "announce"
    await st.soap(sess, f"{style} {text}")
    st.log(f"{sess['user']} {'sent a screen notice' if style == 'notify' else 'announced'}: {text}")
    return {"ok": True, "message": "Sent to everyone online."}


@api()
async def h_restart(st, request, sess, body):
    if body.get("cancel"):
        await st.soap(sess, "server restart cancel")
        st.restart_at = None
        st.log(f"{sess['user']} cancelled the restart.")
        return {"ok": True, "message": "Restart cancelled."}
    secs = int(body.get("seconds", 300))
    if not 10 <= secs <= 86400:
        raise ApiError("Pick between 10 seconds and 24 hours.")
    await st.soap(sess, f"server restart {secs}")
    st.restart_at = time.time() + secs
    st.log(f"{sess['user']} scheduled a world restart in {secs} s.")
    return {"ok": True, "restart_at": st.restart_at, "message": "Restart scheduled. Players see a countdown in chat."}


# ── backups ─────────────────────────────────────────────────────────────────────────────
@api()
async def h_backups(st, request, sess, body):
    return {"backups": st.list_backups(), "settings": st.backup_settings(), "dir": st.adapter.backups_dir,
            "running": st._backup_running}


@api()
async def h_backup_now(st, request, sess, body):
    name = await st.make_backup("manual", sess["user"])
    return {"ok": True, "name": name, "message": f"Backup {name} saved."}


@api()
async def h_backup_settings(st, request, sess, body):
    cfg = st.backup_settings()
    cfg["enabled"] = bool(body.get("enabled", cfg["enabled"]))
    cfg["hour"] = int(body.get("hour", cfg["hour"]))
    cfg["keep_days"] = int(body.get("keep_days", cfg["keep_days"]))
    if not 0 <= cfg["hour"] <= 23 or not 1 <= cfg["keep_days"] <= 365:
        raise ApiError("Hour is 0–23 and days to keep 1–365.")
    st.journal.set_setting("backups", cfg)
    st.log(f"{sess['user']} set daily backups: {'on' if cfg['enabled'] else 'off'}, {cfg['hour']:02d}:00, keep {cfg['keep_days']} days.")
    return {"ok": True, "settings": cfg, "message": "Backup schedule saved."}


@api()
async def h_backup_file(st, request, sess, body):
    name = request.match_info["name"]
    if not BACKUP_RE.match(name):
        raise ApiError("Unknown backup.", 404)
    path = os.path.join(st.adapter.backups_dir, name)
    if not os.path.isfile(path):
        raise ApiError("Unknown backup.", 404)
    return web.FileResponse(path, headers={"Content-Disposition": f'attachment; filename="{name}"', "Cache-Control": "no-store"})


# ── realm identity ──────────────────────────────────────────────────────────────────────
def lan_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
    except OSError:
        return None


@api()
async def h_realm(st, request, sess, body):
    realm = await st.db("realm")
    return {"realm": realm, "suggestions": {"this_pc": "127.0.0.1", "lan": lan_ip()}}


@api()
async def h_realm_save(st, request, sess, body):
    realm = await st.db("realm")
    changes = []
    if "name" in body:
        name = re.sub(r"[\x00-\x1f]+", "", str(body["name"])).strip()
        if not 1 <= len(name) <= 32:
            raise ApiError("Realm names are 1 to 32 characters.")
        if name != realm["name"]:
            await st.db("set_realm", realm["id"], name, None)
            changes.append(st.journal.record(sess["user"], "realm", f"Realm renamed: {realm['name']} → {name}", "realm",
                                             {"realm_id": realm["id"], "field": "name", "from": realm["name"], "to": name}))
    if "address" in body:
        addr = str(body["address"]).strip()
        if "%" in addr or " " in addr:
            raise ApiError("The address must be an IP address or a host name like play.example.com.")
        try:
            ipaddress.ip_address(addr)
        except ValueError:
            if not HOST_RE.match(addr):
                raise ApiError("The address must be an IP address or a host name like play.example.com.")
        if addr != realm["address"]:
            await st.db("set_realm", realm["id"], None, addr)
            changes.append(st.journal.record(sess["user"], "realm", f"Realm address: {realm['address']} → {addr}", "realm",
                                             {"realm_id": realm["id"], "field": "address", "from": realm["address"], "to": addr}))
    return {"ok": True, "changes": changes, "message": "Saved. The realm list picks it up within a minute." if changes else "No change."}


# ── history & undo ──────────────────────────────────────────────────────────────────────
@api()
async def h_changes(st, request, sess, body):
    limit = max(1, min(int(request.query.get("limit", 200)), 1000))
    return {"changes": st.journal.changes(limit, request.query.get("area") or None)}


@api()
async def h_undo(st, request, sess, body):
    async with st.undo_lock:
        return await _undo(st, request, sess)


async def _undo(st, request, sess):
    ch = st.journal.get(int(request.match_info["id"]))
    if not ch:
        raise ApiError("Unknown change.", 404)
    if not ch["undoable"]:
        raise ApiError("This change can't be undone.")
    d = ch["data"]
    if ch["kind"] == "role":
        cur = await st.db("account", d["account_id"])
        if cur["gmlevel"] != d["to"]:
            raise ApiError(f"{d['username']}'s role has changed since then; set it on the Players page instead.")
        if cur["id"] == sess["account_id"] and d["from"] < 3:
            raise ApiError("Undoing this would remove your own Administrator role.")
        await st.db("set_gmlevel", d["account_id"], d["from"])
        summary = f"Undo: {d['username']} back to {ROLES.get(d['from'], d['from'])}"
        undo_data = {**d, "from": d["to"], "to": d["from"]}
    elif ch["kind"] == "realm":
        if (await st.db("realm"))[d["field"]] != d["to"]:
            raise ApiError(f"The realm {d['field']} has changed since then; set it on the Realm page instead.")
        if d["field"] == "name":
            await st.db("set_realm", d["realm_id"], d["from"], None)
        else:
            await st.db("set_realm", d["realm_id"], None, d["from"])
        summary = f"Undo: realm {d['field']} back to {d['from']}"
        undo_data = {**d, "from": d["to"], "to": d["from"]}
    elif ch["kind"] == "motd":
        await st.soap(sess, f"server set motd {_clean_text(d['from'], 255)}")
        summary = "Undo: message of the day restored"
        undo_data = {"from": d["to"], "to": d["from"]}
    elif ch["kind"] == "ban":
        if not NAME_RE.match(d["username"]):
            raise ApiError("Can't undo this one safely.")
        await st.soap(sess, f"unban account {d['username']}")
        summary = f"Undo: unbanned {d['username']}"
        undo_data = d
        new_id = st.journal.record(sess["user"], ch["area"], summary, "unban", undo_data, undoable=False)
        st.journal.mark_undone(ch["id"], new_id)
        return {"ok": True, "message": summary}
    else:
        raise ApiError("This change can't be undone.")
    new_id = st.journal.record(sess["user"], ch["area"], summary, ch["kind"], undo_data)
    st.journal.mark_undone(ch["id"], new_id)
    return {"ok": True, "message": summary}


@api()
async def h_fix(st, request, sess, body):
    what = request.match_info["what"]
    if what == "enable_soap" and hasattr(st.adapter, "enable_soap"):
        await asyncio.to_thread(st.adapter.enable_soap)
        st.journal.record(sess["user"], "settings", "Turned on the SOAP console (127.0.0.1:7878) in mangosd.conf", "conf",
                          {"keys": ["SOAP.Enabled", "SOAP.IP", "SOAP.Port"]}, live=False, undoable=False)
        return {"ok": True, "message": "SOAP turned on. Restart the world server to apply it."}
    raise ApiError("Nothing to fix there.")


# ── wiring ──────────────────────────────────────────────────────────────────────────────
def mount_studio(app, base_dir, mode=None, state_dir=None):
    """Add Studio's routes to an app that serves nothing else (see studio/server.py)."""
    st = Studio(base_dir, state_dir, mode)
    app[KEY] = st
    r = app.router
    p = "/studio/api"
    r.add_post(f"{p}/login", h_login)
    r.add_post(f"{p}/logout", h_logout)
    r.add_get(f"{p}/session", h_session)
    r.add_get(f"{p}/overview", h_overview)
    r.add_get(f"{p}/services", h_services)
    r.add_post(p + "/services/{action}", h_service_action)
    r.add_get(f"{p}/logs", h_logs)
    r.add_get(f"{p}/accounts", h_accounts)
    r.add_post(f"{p}/accounts", h_account_create)
    r.add_post(p + "/accounts/{id:\\d+}/role", h_account_role)
    r.add_post(p + "/accounts/{id:\\d+}/password", h_account_password)
    r.add_post(p + "/accounts/{id:\\d+}/ban", h_account_ban)
    r.add_post(p + "/accounts/{id:\\d+}/unban", h_account_unban)
    r.add_post(p + "/characters/{name}/kick", h_kick)
    r.add_get(f"{p}/online", h_online)
    r.add_get(f"{p}/messages", h_messages)
    r.add_post(f"{p}/motd", h_motd)
    r.add_post(f"{p}/announce", h_announce)
    r.add_post(f"{p}/restart", h_restart)
    r.add_get(f"{p}/backups", h_backups)
    r.add_post(f"{p}/backups", h_backup_now)
    r.add_post(f"{p}/backups/settings", h_backup_settings)
    r.add_get(p + "/backups/file/{name}", h_backup_file)
    r.add_get(f"{p}/realm", h_realm)
    r.add_post(f"{p}/realm", h_realm_save)
    r.add_get(f"{p}/changes", h_changes)
    r.add_post(p + "/changes/{id:\\d+}/undo", h_undo)
    r.add_post(p + "/fix/{what}", h_fix)

    async def headers(request, response):
        if request.path.startswith("/studio"):
            response.headers["Content-Security-Policy"] = (
                "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; "
                "connect-src 'self'; font-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'")
            response.headers["X-Frame-Options"] = "SAMEORIGIN"
            response.headers["Referrer-Policy"] = "no-referrer"

    async def index(request):
        return web.FileResponse(os.path.join(www_dir, "studio", "index.html"), headers={"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"})

    async def to_slash(request):
        raise web.HTTPFound("/studio/")

    www_dir = os.path.join(base_dir, "www")
    r.add_get("/studio", to_slash)
    r.add_get("/studio/", index)
    app.on_response_prepare.append(headers)

    async def start(app_):
        st._task = asyncio.create_task(st.scheduler())
        st.log(f"Studio started ({st.adapter.label}).")

    async def stop(app_):
        if st._task:
            st._task.cancel()

    app.on_startup.append(start)
    app.on_cleanup.append(stop)
    return st
