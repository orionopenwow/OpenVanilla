import os
import sys
import json
import urllib.parse
import asyncio
import hashlib
import ipaddress
import re
import subprocess
import aiohttp
from aiohttp import web

from authcheck import verify_realm_login
from server_control import db_args, db_env, sql_value

# OPENVANILLA_SERVER_DIR: the launcher's Server\ folder when the backend runs frozen inside OpenVanilla.exe
# (OpenVanilla.exe --run web-backend); otherwise this checkout.
BASE_DIR = os.environ.get("OPENVANILLA_SERVER_DIR") or os.path.dirname(os.path.abspath(__file__))
WWW_DIR = os.path.join(BASE_DIR, "www")
DATA_DIR = os.path.join(BASE_DIR, "Data")
INDEX_PATH = os.path.join(WWW_DIR, "__index.json")
# Lets the launcher spot a backend still running older code (it restarts it).
try:
    CODE_VERSION = int(os.path.getmtime(os.path.abspath(__file__)))
except OSError:   # frozen inside OpenVanilla.exe: no .py beside it, so the exe's own date
    CODE_VERSION = int(os.path.getmtime(sys.executable))

# Database configuration (environment variable configurable for cloud hosting)
SPP_ROOT = os.environ.get("SPP_ROOT", os.path.join(os.path.expanduser("~"), "Desktop", "Games", "SPP_Classics_V2", "SPP_Server"))
MYSQL_BIN = os.environ.get("MYSQL_BIN", os.path.join(SPP_ROOT, r"Server\Database\bin\mysql.exe"))

# Loose art folders under Data/ that the web client should see as if they were in the MPQs.
# Their files are added to the asset index at startup (lowercase, backslashes, like the rest),
# so SetTexture("Interface\\ClassicPlus\\CompassRing") resolves and streams from /data/.
EXTRA_INDEX_DIRS = [os.path.join("interface", "classicplus")]

def build_index_bytes():
    entries = []
    if os.path.exists(INDEX_PATH):
        with open(INDEX_PATH, "rb") as f:
            entries = json.loads(f.read() or b"[]")
    known = set(entries)
    for rel_dir in EXTRA_INDEX_DIRS:
        root = find_dir_ci(DATA_DIR, *rel_dir.split(os.sep))
        if not root:
            continue
        for dirpath, _, filenames in os.walk(root):
            for fn in filenames:
                rel = os.path.relpath(os.path.join(dirpath, fn), DATA_DIR).replace("/", "\\").replace(os.sep, "\\").lower()
                if rel not in known:
                    entries.append(rel)
                    known.add(rel)
    body = json.dumps(entries, separators=(", ", ": ")).encode("utf-8")
    return body, hashlib.sha1(body).hexdigest()[:16]  # nosec B324 - SHA1 is mandated by the 1.12.1 SRP6 login protocol

INDEX_BYTES, INDEX_ETAG = b"[]", "0"

MIME_TYPES = {
    ".blp": "image/x-blp",
    ".tga": "image/x-tga",
    ".mp3": "audio/mpeg",
    ".wav": "audio/wav",
    ".wasm": "application/wasm",
    ".js": "application/javascript",
    ".html": "text/html; charset=utf-8",
    ".json": "application/json",
    ".css": "text/css",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".ico": "image/x-icon",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".ttf": "font/ttf",
}

def generate_srp6(username, password):
    N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
    g = 7
    s = os.urandom(32)
    h1 = hashlib.sha1(f"{username.upper()}:{password.upper()}".encode("utf-8")).digest()  # nosec B324 - SHA1 is mandated by the 1.12.1 SRP6 login protocol
    # The Classic client/server protocol serializes SRP integers little-endian,
    # while the account table stores s/v as big-endian hex strings.
    h2 = hashlib.sha1(s[::-1] + h1).digest()  # nosec B324 - SHA1 is mandated by the 1.12.1 SRP6 login protocol
    x = int.from_bytes(h2, byteorder="little")
    v = pow(g, x, N)
    v_bytes = int.to_bytes(v, 32, byteorder="little")
    return s.hex().upper(), v_bytes[::-1].hex().upper()

def safe_join(root, rel):
    """Resolve rel under root, refusing anything that escapes it (../, absolute, drive)."""
    root = os.path.realpath(root)
    path = os.path.realpath(os.path.join(root, rel.lstrip("/\\")))
    r, p = os.path.normcase(root), os.path.normcase(path)
    if p != r and not p.startswith(r.rstrip(os.sep) + os.sep):
        return None
    return path

def resolve_case_insensitive(root, rel):
    """Resolve rel under root one component at a time, ignoring case, like the 1.12 client's
    Windows file namespace. A no-op on NTFS (exact lookups already succeed); on a case-sensitive
    host it lets `Interface\\AddOns\\pfQuest\\img\\tracking\\chests\\Barrel.tga` and
    `interface/addons/pfquest/...` reach the same file. The result goes back through safe_join,
    so a symlink or `..` cannot leave root."""
    parts = [p for p in re.split(r"[\\/]+", rel) if p not in ("", ".")]
    if any(p == ".." or ":" in p for p in parts):
        return None
    cur = os.path.realpath(root)
    for part in parts:
        exact = os.path.join(cur, part)
        if os.path.exists(exact):
            cur = exact
            continue
        try:
            want = part.lower()
            match = next((e for e in os.listdir(cur) if e.lower() == want), None)
        except OSError:
            return None
        if match is None:
            return None
        cur = os.path.join(cur, match)
    try:
        return safe_join(root, os.path.relpath(cur, os.path.realpath(root)))
    except ValueError:  # a different drive on Windows
        return None

def find_dir_ci(root, *names):
    """root/names... matched case-insensitively, or None."""
    path = resolve_case_insensitive(root, os.sep.join(names))
    return path if path and os.path.isdir(path) else None

INDEX_BYTES, INDEX_ETAG = build_index_bytes()

ADDON_LIST_MAX_FILES = 20000

def list_loose_addons():
    """Every folder in Data/Interface/AddOns that holds a `<Folder>.toc` (case-insensitive, the
    client's rule), with its files relative to the AddOns root. The web client has no directory
    listing of its own, so this is what its loose-folder discovery pass can enumerate."""
    root = find_dir_ci(DATA_DIR, "Interface", "AddOns")
    out = []
    if not root:
        return out
    for name in sorted(os.listdir(root), key=str.upper):
        folder = os.path.join(root, name)
        if not os.path.isdir(folder) or name.startswith("."):
            continue
        toc = next((e for e in os.listdir(folder) if e.lower() == name.lower() + ".toc"), None)
        if toc is None:
            continue  # not an addon folder; the client skips it silently too
        files = []
        for dirpath, dirnames, filenames in os.walk(folder):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for fn in filenames:
                rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
                files.append(rel)
                if len(files) >= ADDON_LIST_MAX_FILES:
                    break
            if len(files) >= ADDON_LIST_MAX_FILES:
                break
        files.sort(key=str.lower)
        try:
            mtime = int(os.path.getmtime(os.path.join(folder, toc)))
        except OSError:
            mtime = 0
        out.append({"name": name, "toc": f"{name}/{toc}", "tocMtime": mtime, "files": files})
    return out

async def async_port_check(port, timeout=0.5):
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1", port), timeout=timeout
        )
        writer.close()
        await writer.wait_closed()
        return True
    except (OSError, asyncio.TimeoutError):
        return False

def register_realm_account(username, password, client_ip="127.0.0.1"):
    username = username.strip().upper()
    password = password.strip().upper()

    if not username or not password:
        return False, "Username and password are required."
    if len(username) < 3 or len(username) > 16:
        return False, "Username must be between 3 and 16 characters."
    if not re.fullmatch(r"[A-Z0-9]+", username):
        return False, "Username may only contain alphanumeric characters."
    if not re.fullmatch(r"[A-Z0-9]{4,16}", password):
        return False, "Password must be 4 to 16 letters or numbers (the 1.12.1 client's limit)."
    if _rate_limited("register:" + str(client_ip), limit=3, window=86400):
        return False, "Too many new accounts from this address today. Try again tomorrow."

    try:
        client_ip = str(ipaddress.ip_address(client_ip))
    except ValueError:
        client_ip = "127.0.0.1"

    try:
        s_hex, v_hex = generate_srp6(username, password)
        username, s_hex, v_hex, client_ip = (sql_value(x) for x in (username, s_hex, v_hex, client_ip))
        # One transaction: a failure in the website_accounts row must not leave a
        # half-created game account behind (which would then report "name taken").
        # `locale` is left to its column default; '' is rejected by strict-mode MySQL.
        sql = f"""USE classicrealmd;
START TRANSACTION;
INSERT INTO account (username, s, v, gmlevel, joindate)
VALUES ('{username}', '{s_hex}', '{v_hex}', 0, NOW());
INSERT INTO website_accounts (account_id, display_name, registration_ip, g_id)
VALUES (LAST_INSERT_ID(), '{username}', '{client_ip}', 2)
ON DUPLICATE KEY UPDATE display_name='{username}';
COMMIT;
"""
        cmd = [MYSQL_BIN, *db_args()]
        # Feed SQL on stdin; with -e the mysql client stops at the first error without
        # running ROLLBACK, and stdin mode lets the transaction abort cleanly on exit.
        res = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=15, env=db_env())
        if res.returncode == 0:
            return confirm_new_account(username, password, cmd)
        elif "Duplicate entry" in res.stderr:
            return False, "That account name is already taken. Choose another username."
        else:
            print(f"[REGISTER] database error: {res.stderr.strip() or res.stdout.strip()}")
            return False, "The server couldn't create the account right now. Please try again later."
    except Exception as e:
        print(f"[REGISTER] error: {e}")
        return False, "The server couldn't create the account right now. Please try again later."

def confirm_new_account(username, password, mysql_cmd):
    """Prove the new account logs in through realmd before telling the player it is ready.

    This is the guard against the in-game "information you have entered is not valid"
    error: if realmd rejects the stored verifier, the half-working account is removed so
    the name stays free and the player is told to retry instead of failing at the client.
    """
    try:
        ok, detail = verify_realm_login(username, password)
    except OSError as e:
        print(f"[REGISTER] {username}: created, but realmd login check could not run: {e}")
        return True, (f"Account '{username}' created. The login server is not reachable right now, "
                      "so it could not be test-logged in yet.")
    if ok:
        print(f"[REGISTER] {username}: created and verified against realmd.")
        return True, f"Account '{username}' registered and verified! You may now enter the realm."

    print(f"[REGISTER] {username}: realmd rejected the new account ({detail}); rolling it back.")
    cleanup = f"""USE classicrealmd;
DELETE FROM website_accounts WHERE account_id=(SELECT id FROM account WHERE username='{username}');
DELETE FROM account WHERE username='{username}';
"""
    subprocess.run(mysql_cmd, input=cleanup, capture_output=True, text=True, timeout=15, env=db_env())
    return False, f"The login server did not accept the new account ({detail}). Nothing was saved; please try again."

# --- Password change (used by the Open Vanilla launcher's Account page) ---
# Sign-up and password-change attempts per client, kept on disk so a restart doesn't reset the limits.
RATE_FILE = os.path.join(os.environ.get("OPENVANILLA_STATE_DIR", BASE_DIR), "rate_limits.json")


def _load_attempts():
    try:
        with open(RATE_FILE, encoding="utf-8") as f:
            data = json.load(f)
        return {str(k): [float(t) for t in v] for k, v in data.items() if isinstance(v, list)}
    except (OSError, ValueError, TypeError, AttributeError):
        return {}


_PW_ATTEMPTS = _load_attempts()  # "register:<ip>" / "password:<ip>" -> recent attempt timestamps


def _save_attempts():
    tmp = RATE_FILE + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(_PW_ATTEMPTS, f)
        os.replace(tmp, RATE_FILE)
    except OSError as e:
        print(f"[RATE] couldn't save {RATE_FILE}: {e}")


def _rate_limited(key, limit=6, window=600):
    import time as _time
    now = _time.time()
    # drop keys with nothing in the last day (register limits use a one-day window)
    for k in [k for k, ts in _PW_ATTEMPTS.items() if not ts or now - ts[-1] > 86400]:
        del _PW_ATTEMPTS[k]
    recent = [t for t in _PW_ATTEMPTS.get(key, []) if now - t < window]
    recent.append(now)
    _PW_ATTEMPTS[key] = recent
    _save_attempts()
    return len(recent) > limit


def client_ip(request):
    """The player's IP. X-Forwarded-For is trusted only from the local reverse proxy (Caddy)."""
    remote = request.remote or "127.0.0.1"
    fwd = request.headers.get("X-Forwarded-For", "")
    if fwd and remote in ("127.0.0.1", "::1"):
        try:
            return str(ipaddress.ip_address(fwd.split(",")[-1].strip()))
        except ValueError:
            pass
    return remote


def change_realm_password(username, old_password, new_password, client_ip="127.0.0.1"):
    username = (username or "").strip().upper()
    old_password = (old_password or "").strip().upper()
    new_password = (new_password or "").strip().upper()
    if not re.fullmatch(r"[A-Z0-9]{3,16}", username):
        return False, "Unknown account name."
    if not re.fullmatch(r"[A-Z0-9]{4,16}", new_password):
        return False, "The new password must be 4 to 16 letters or numbers."
    if _rate_limited("password:" + str(client_ip)):
        return False, "Too many attempts. Wait a few minutes and try again."
    try:
        ok, detail = verify_realm_login(username, old_password)
    except OSError as e:
        return False, f"The login server is not reachable right now ({e})."
    if not ok:
        return False, "The current password is not correct."
    s_hex, v_hex = generate_srp6(username, new_password)
    username, s_hex, v_hex = (sql_value(x) for x in (username, s_hex, v_hex))
    sql = f"""USE classicrealmd;
UPDATE account SET s='{s_hex}', v='{v_hex}' WHERE username='{username}';
"""
    res = subprocess.run([MYSQL_BIN, *db_args()], input=sql, capture_output=True, text=True, timeout=15, env=db_env())
    if res.returncode != 0:
        print(f"[PASSWORD] database error: {res.stderr.strip() or res.stdout.strip()}")
        return False, "The server couldn't change the password right now. Please try again later."
    try:
        ok, detail = verify_realm_login(username, new_password)
    except OSError:
        ok = True
    if not ok:
        return False, f"The password was saved but the login server did not accept it yet ({detail}). Try signing in again in a minute."
    print(f"[PASSWORD] {username}: password changed from {client_ip}.")
    return True, "Password changed. Use the new password from now on."


# --- Security Headers Middleware ---
@web.middleware
async def security_headers_middleware(request, handler):
    if request.method == "OPTIONS":
        resp = web.Response(status=204)
    else:
        resp = await handler(request)

    path = request.path.lower()
    if "game.html" in path or path.endswith(".wasm") or path.startswith("/data/"):
        resp.headers["Cross-Origin-Opener-Policy"] = "same-origin"
        resp.headers["Cross-Origin-Embedder-Policy"] = "require-corp"
    else:
        resp.headers["Cross-Origin-Opener-Policy"] = "same-origin-allow-popups"

    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    resp.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
    resp.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS, HEAD"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return resp

# --- WebSocket Relay Handler (/ws/{port}) ---
async def handle_ws(request):
    port_str = request.match_info.get("port", "3724")
    try:
        port = int(port_str)
    except ValueError:
        return web.Response(status=400, text="Invalid port")

    if port not in {3724, 8085}:
        return web.Response(status=403, text="Relay port is not allowed")

    origin = request.headers.get("Origin")
    if origin:
        try:
            origin_host = urllib.parse.urlsplit(origin).hostname
        except ValueError:
            origin_host = None
        request_host = urllib.parse.urlsplit(f"//{request.host}").hostname
        if not origin_host or origin_host.lower() != (request_host or "").lower():
            return web.Response(status=403, text="Cross-origin relay requests are not allowed")

    ip = client_ip(request)
    if _RELAYS.get(ip, 0) >= MAX_RELAYS_PER_IP:
        return web.Response(status=429, text="Too many game connections from this address")
    _RELAYS[ip] = _RELAYS.get(ip, 0) + 1
    try:
        return await _relay(request, port)
    finally:
        _RELAYS[ip] -= 1
        if _RELAYS[ip] <= 0:
            del _RELAYS[ip]


_RELAYS = {}  # ip -> open relay connections
MAX_RELAYS_PER_IP = 6  # login + world for a few game windows


async def _relay(request, port):
    ws = web.WebSocketResponse(protocols=("binary",))
    await ws.prepare(request)
    print(f"[WS Relay] Client connected to /ws/{port}")

    try:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        print(f"[WS Relay] Connected to TCP backend 127.0.0.1:{port}")
    except Exception as e:
        print(f"[WS Relay] Failed to connect to TCP backend 127.0.0.1:{port}: {e}")
        await ws.close()
        return ws

    async def tcp_to_ws():
        try:
            while not ws.closed:
                data = await reader.read(4096)
                if not data:
                    break
                await ws.send_bytes(data)
        except Exception:
            pass
        finally:
            if not ws.closed:
                await ws.close()

    async def ws_to_tcp():
        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.BINARY:
                    writer.write(msg.data)
                    await writer.drain()
                elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.ERROR):
                    break
        except Exception:
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    t1 = asyncio.create_task(tcp_to_ws())
    t2 = asyncio.create_task(ws_to_tcp())
    await asyncio.gather(t1, t2, return_exceptions=True)
    print(f"[WS Relay] Connection closed for /ws/{port}")
    return ws

# --- Data Index Endpoint ---
async def handle_data_index(request):
    # Revalidated on every boot (304 when unchanged), so art added to Data/ reaches players
    # on their next page load instead of a day later.
    etag = '"' + INDEX_ETAG + '"'
    if request.headers.get("If-None-Match") == etag:
        return web.Response(status=304, headers={"ETag": etag, "Cache-Control": "no-cache"})
    return web.Response(
        body=INDEX_BYTES,
        content_type="application/json",
        headers={"Cache-Control": "no-cache", "ETag": etag}
    )

# --- Loose AddOns listing (/data/__addons) ---
# Live, never cached: the static __index.json is generated once and does not see addon folders
# dropped into Data/Interface/AddOns afterwards. Read-only, Data/Interface/AddOns only.
async def handle_addons_index(request):
    addons = await asyncio.to_thread(list_loose_addons)
    return web.json_response(
        {"root": "Interface/AddOns/", "addons": addons},
        headers={"Cache-Control": "no-store"},
    )

# --- Asset Streaming Endpoint (/data/{name:.*}) ---
async def handle_data_asset(request):
    raw_name = request.match_info.get("name", "")
    decoded = urllib.parse.unquote(raw_name)
    norm_name = decoded.replace("/", os.sep).replace("\\", os.sep)
    data_file = safe_join(DATA_DIR, norm_name)
    if data_file is None:
        return web.Response(status=403, text="Forbidden")

    if not os.path.exists(data_file):
        # Every component, not just the basename: nested mixed-case addon folders
        # (pfQuest\img\tracking\chests\Barrel.tga) must resolve on a case-sensitive host too.
        resolved = await asyncio.to_thread(resolve_case_insensitive, DATA_DIR, norm_name)
        if resolved:
            data_file = resolved

    if os.path.exists(data_file) and os.path.isfile(data_file):
        ext = os.path.splitext(data_file)[1].lower()
        content_type = MIME_TYPES.get(ext, "application/octet-stream")
        # Addon code and the suite's art change between releases; let browsers revalidate
        # them (304s are cheap). Game data from the MPQs never changes and stays immutable.
        low = decoded.replace("\\", "/").lower().lstrip("/")
        mutable = low.startswith("interface/addons/") or low.startswith("interface/classicplus/")
        return web.FileResponse(
            data_file,
            headers={
                "Content-Type": content_type,
                "Cache-Control": "no-cache" if mutable else "private, max-age=31536000, immutable"
            }
        )
    return web.Response(status=404, text="Asset not found")

# --- Account Registration API ---
async def handle_api_register(request):
    try:
        data = await request.json()
        user = data.get("username", "")
        pwd = data.get("password", "")
        ip = client_ip(request)

        # Runs mysql and a realmd round trip; keep it off the event loop so the
        # WebSocket relays of players already in game do not stall.
        success, message = await asyncio.to_thread(register_realm_account, user, pwd, ip)
        return web.json_response({"success": success, "message": message}, status=200 if success else 400)
    except Exception as e:
        print(f"[REGISTER] bad request: {e}")
        return web.json_response({"success": False, "message": "Bad request."}, status=400)

async def handle_api_change_password(request):
    try:
        data = await request.json()
        success, message = await asyncio.to_thread(
            change_realm_password, data.get("username", ""), data.get("old_password", ""),
            data.get("new_password", ""), client_ip(request))
        return web.json_response({"success": success, "message": message}, status=200 if success else 400)
    except Exception as e:
        print(f"[PASSWORD] bad request: {e}")
        return web.json_response({"success": False, "message": "Bad request."}, status=400)

async def handle_api_status(request):
    mysql, realmd, mangosd = await asyncio.gather(
        async_port_check(3310),
        async_port_check(3724),
        async_port_check(8085),
    )
    services = {
        "mysql": "online" if mysql else "offline",
        "realmd": "online" if realmd else "offline",
        "mangosd": "online" if mangosd else "offline",
        # The relay is same-origin on this server; report it ready with its TCP backend.
        "ws_auth": "online" if realmd else "offline",
        "ws_world": "online" if mangosd else "offline",
    }
    local = client_ip(request) in ("127.0.0.1", "::1")
    return web.json_response({
        "realm": {
            "name": "Vanilla Remastered",
            "online": realmd and mangosd,
            "population": "Online" if mangosd else "Offline",
        },
        "services": services,
        "gameEngine": {"running": False},
        "assetCache": {"manifestReady": os.path.isfile(INDEX_PATH)},
        "codeVersion": CODE_VERSION,
        "pid": os.getpid() if local else None,  # the local control panel uses it; strangers don't need it
    }, headers={"Cache-Control": "no-store"})

# --- Static WWW Files Handler ---
async def handle_static_files(request):
    rel_path = request.match_info.get("tail", "")
    if not rel_path or rel_path == "/":
        rel_path = "index.html"
    
    file_path = safe_join(WWW_DIR, rel_path.replace("/", os.sep))
    if file_path is None:
        return web.Response(status=403, text="Forbidden")
    if os.path.exists(file_path) and os.path.isfile(file_path):
        ext = os.path.splitext(file_path)[1].lower()
        content_type = MIME_TYPES.get(ext)
        if content_type:
            return web.FileResponse(file_path, headers={"Content-Type": content_type})
        return web.FileResponse(file_path)
    print(f"[HTTP 404] Requested: {request.path}")
    return web.Response(status=404, text="File not found")

def create_app():
    app = web.Application(middlewares=[security_headers_middleware])
    
    # 1. WebSocket relay on /ws/{port}
    app.router.add_get('/ws/{port}', handle_ws)
    
    # 2. Data endpoints
    app.router.add_get('/data/__index', handle_data_index)
    app.router.add_get('/data/__addons', handle_addons_index)
    app.router.add_get('/data/{name:.*}', handle_data_asset)
    
    # 3. API endpoints
    app.router.add_post('/api/register', handle_api_register)
    app.router.add_post('/api/change-password', handle_api_change_password)
    app.router.add_get('/api/status', handle_api_status)
    
    # 3b. Server Studio at /studio: local-only admin app (studio/app.py). On Windows it drives the
    #     SPP realm; elsewhere set STUDIO_MODE (docker or demo) to turn it on.
    if os.name == "nt" or os.environ.get("STUDIO_MODE"):
        try:
            from studio import setup_studio
            setup_studio(app, BASE_DIR, mode=os.environ.get("STUDIO_MODE") or "spp")
        except Exception as e:  # Studio must never stop the website or the game relay
            print(f"[STUDIO] not started: {e.__class__.__name__}: {e}")

    # 4. Root & Static files
    app.router.add_get('/', lambda r: web.FileResponse(os.path.join(WWW_DIR, "index.html"), headers={"Content-Type": "text/html; charset=utf-8"}))
    app.router.add_get('/{tail:.*}', handle_static_files)
    
    return app

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18090
    print(f"Open Vanilla Unified Web & WebSocket Server on http://127.0.0.1:{port}/")
    print(f"Serving static site from: {WWW_DIR}")
    print(f"Streaming game data from: {DATA_DIR}")
    print(f"Relaying WebSocket traffic: /ws/3724 -> TCP 3724 | /ws/8085 -> TCP 8085")
    
    app = create_app()
    # Public traffic must enter through the HTTPS reverse proxy. Keep the app and its
    # registration/database API off the public interface.
    web.run_app(app, host="127.0.0.1", port=port, print=None)

if __name__ == "__main__":
    main()
