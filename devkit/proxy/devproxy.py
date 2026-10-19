#!/usr/bin/env python3
"""Open Vanilla dev proxy: play the live realm in your browser, but with the page layer and the
Classic+ addons served from your own checkout.

    py -3 -m pip install aiohttp            (once; add "cryptography" for --https)
    py -3 devkit/proxy/devproxy.py                          -> http://localhost:8080/
    py -3 devkit/proxy/devproxy.py --upstream https://play.openvanilla.app --port 8080 --repo .

Everything is forwarded to the upstream realm (HTTP and the /ws/* WebSocket relay) except:

    /ow/<file>                    <- realm/www/<file>              (when the file exists locally)
    /bridge.js                    <- realm/classicplus/bridge.js
    /addons-loader.js             <- realm/classicplus/addons-loader.js
    /login-backdrop.*             <- realm/login-backdrop/*         (when the file exists locally)
    /data/Interface/AddOns/...    <- Data/Interface/AddOns/...      (any spelling the client uses:
    /data/Interface/ClassicPlus/  <- Data/Interface/ClassicPlus/...  '/', '\\', %5C, any case)
    /data/__addons                <- a live listing of Data/Interface/AddOns (the realm has none)
    /data/__index                 <- the realm's listing + every local overlay file

Local files are sent with Cache-Control: no-store and no Content-Encoding, so an edit shows up
on the next page load, or after /reload in game for addon files. Nothing is written anywhere.

Session handling: the realm's cookie (wr_session: Path=/; HttpOnly; Secure; SameSite=Lax, no
Domain, no __Host- prefix) is passed through with any Domain removed and, on plain http, without
Secure (so every browser keeps it on http://localhost). Redirects to the realm's own origin are
rewritten to this proxy, Origin/Referer are rewritten to the realm's origin on the way up, and
HSTS / Alt-Svc headers are dropped so localhost is never pinned to https or QUIC.
Discord sign-in does NOT work through the proxy (Discord sends you back to the realm's own
domain): sign in with a web password (the realm admin can issue one).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import mimetypes
import os
import re
import ssl
import sys
import urllib.parse
from pathlib import Path

try:
    import aiohttp
    from aiohttp import web, WSMsgType
    from yarl import URL
except ImportError:  # pragma: no cover - the one-line fix is the whole message
    sys.exit("aiohttp is missing: py -3 -m pip install aiohttp")

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "trailers", "transfer-encoding", "upgrade", "host", "content-length",
}
# Never let the realm's transport policy stick to localhost.
DROP_RESPONSE = {"strict-transport-security", "alt-svc"}
OVERLAY_PREFIXES = ("interface/addons/", "interface/classicplus/")
CLIENT = web.AppKey("client", aiohttp.ClientSession)
STATS = web.AppKey("stats", dict)
TYPES = {
    ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
    ".json": "application/json", ".html": "text/html; charset=utf-8", ".css": "text/css",
    ".webp": "image/webp", ".webm": "video/webm", ".mp4": "video/mp4", ".png": "image/png",
    ".wasm": "application/wasm", ".svg": "image/svg+xml",
}


def data_type(name: str) -> str:
    """The Content-Type the realm sends for a /data name (wenilla-host data.rs content_type)."""
    low = name.lower()
    if low.endswith(".blp"):
        return "image/x-blp"
    if low.endswith(".mp3"):
        return "audio/mpeg"
    return "application/octet-stream"


def norm_data_name(raw_tail: str) -> str:
    """'/data/<tail>' as the realm resolves it: percent-decoded, '/' and '\\' the same."""
    return urllib.parse.unquote(raw_tail).replace("\\", "/").lstrip("/")


def resolve_ci(root: Path, rel: str) -> Path | None:
    """rel under root, matching each path component case-insensitively (the archive rule).
    Refuses anything that escapes root."""
    cur = root
    for part in [p for p in rel.split("/") if p]:
        if part in (".", "..") or ":" in part:
            return None
        nxt = cur / part
        if not nxt.exists():
            try:
                hit = next((c for c in cur.iterdir() if c.name.lower() == part.lower()), None)
            except OSError:
                return None
            if hit is None:
                return None
            nxt = hit
        cur = nxt
    try:
        cur.resolve().relative_to(root.resolve())
    except ValueError:
        return None
    return cur if cur.is_file() else None


class Config:
    def __init__(self, upstream: str, repo: Path, https: bool = False, insecure: bool = False,
                 data_overlay: bool = True, verbose: bool = False):
        u = URL(upstream.rstrip("/"))
        self.upstream = u
        self.upstream_origin = f"{u.scheme}://{u.authority}"
        self.upstream_ws = u.with_scheme("wss" if u.scheme == "https" else "ws")
        self.repo = repo.resolve()
        self.www = self.repo / "realm" / "www"
        self.classicplus = self.repo / "realm" / "classicplus"
        self.backdrop = self.repo / "realm" / "login-backdrop"
        self.data = self.repo / "Data"
        self.https = https
        self.insecure = insecure
        self.data_overlay = data_overlay
        self.verbose = verbose


# -- Local files --------------------------------------------------------------------------------

def local_page_file(cfg: Config, path: str) -> Path | None:
    """The local file that replaces a page-layer URL path, or None to forward it."""
    if path.startswith("/ow/"):
        return resolve_ci(cfg.www, path[len("/ow/"):]) if cfg.www.is_dir() else None
    if path in ("/bridge.js", "/addons-loader.js"):
        f = cfg.classicplus / path[1:]
        return f if f.is_file() else None
    if path.startswith("/login-backdrop.") and "/" not in path[1:]:
        f = cfg.backdrop / path[1:]
        return f if f.is_file() else None
    return None


def local_data_file(cfg: Config, name: str) -> Path | None:
    if not cfg.data_overlay or not name.lower().startswith(OVERLAY_PREFIXES):
        return None
    return resolve_ci(cfg.data, name)


def local_overlay_names(cfg: Config) -> list[str]:
    """Every overlay file as a chain name ('Interface\\AddOns\\X\\file.lua')."""
    out = []
    if not cfg.data_overlay or not cfg.data.is_dir():
        return out
    for prefix in OVERLAY_PREFIXES:
        parts = prefix.strip("/").split("/")
        base = resolve_dir_ci(cfg.data, parts)
        if base is None:
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for fn in filenames:
                if fn.startswith("."):
                    continue
                rel = Path(dirpath, fn).relative_to(cfg.data).as_posix()
                out.append(rel.replace("/", "\\"))
    return sorted(out, key=str.lower)


def resolve_dir_ci(root: Path, parts: list[str]) -> Path | None:
    cur = root
    for part in parts:
        try:
            cur = next(c for c in cur.iterdir() if c.is_dir() and c.name.lower() == part.lower())
        except (StopIteration, OSError):
            return None
    return cur


def list_addons(cfg: Config) -> list[dict]:
    """Same shape as asset_server.py's /data/__addons: folders holding <Folder>.toc."""
    root = resolve_dir_ci(cfg.data, ["Interface", "AddOns"]) if cfg.data.is_dir() else None
    out = []
    if root is None:
        return out
    for folder in sorted((p for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")),
                         key=lambda p: p.name.upper()):
        toc = next((e.name for e in folder.iterdir() if e.name.lower() == folder.name.lower() + ".toc"), None)
        if toc is None:
            continue
        files = sorted((p.relative_to(root).as_posix() for p in folder.rglob("*") if p.is_file()), key=str.lower)
        out.append({"name": folder.name, "toc": f"{folder.name}/{toc}",
                    "tocMtime": int((folder / toc).stat().st_mtime), "files": files[:2000]})
    return out


def file_response(request: web.Request, f: Path, ctype: str | None = None, extra: dict | None = None):
    ctype = ctype or TYPES.get(f.suffix.lower()) or mimetypes.guess_type(f.name)[0] or "application/octet-stream"
    headers = {"Content-Type": ctype, "Cache-Control": "no-store", "X-OW-Devproxy": "local"}
    headers.update(extra or {})
    body = b"" if request.method == "HEAD" else f.read_bytes()
    if request.method == "HEAD":
        headers["Content-Length"] = str(f.stat().st_size)
    return web.Response(body=body, headers=headers)


# -- Header rewriting ---------------------------------------------------------------------------

def up_headers(cfg: Config, request: web.Request, identity: bool = False) -> dict:
    h = {}
    for k, v in request.headers.items():
        lk = k.lower()
        if lk in HOP_BY_HOP or lk.startswith("sec-websocket") or lk == "origin" or lk == "referer":
            continue
        h[k] = v
    if "Origin" in request.headers:
        h["Origin"] = cfg.upstream_origin
    if "Referer" in request.headers:
        ref = URL(request.headers["Referer"])
        h["Referer"] = cfg.upstream_origin + (ref.raw_path_qs if ref.is_absolute() else "/")
    if identity:
        h["Accept-Encoding"] = "identity"
    return h


def rewrite_cookie(cfg: Config, value: str) -> str:
    parts = [p.strip() for p in value.split(";")]
    name = parts[0].split("=", 1)[0]
    keep = [parts[0]]
    for attr in parts[1:]:
        low = attr.lower()
        if low.startswith("domain="):
            continue  # host-only on localhost
        if low == "secure" and not cfg.https and not name.startswith(("__Host-", "__Secure-")):
            continue  # plain http: a Secure cookie would be dropped by some browsers
        if low == "samesite=none" and not cfg.https:
            attr = "SameSite=Lax"  # None requires Secure
        keep.append(attr)
    return "; ".join(keep)


def down_headers(cfg: Config, resp: aiohttp.ClientResponse, local_origin: str) -> list[tuple[str, str]]:
    out = []
    for k, v in resp.headers.items():
        lk = k.lower()
        if lk in HOP_BY_HOP or lk in DROP_RESPONSE:
            continue
        if lk == "set-cookie":
            v = rewrite_cookie(cfg, v)
        elif lk == "location":
            if v.startswith(cfg.upstream_origin):
                v = local_origin + v[len(cfg.upstream_origin):]
        elif lk in ("content-security-policy", "content-security-policy-report-only"):
            host = cfg.upstream.authority
            v = v.replace(cfg.upstream_origin, local_origin).replace(
                f"wss://{host}", local_origin.replace("http", "ws", 1)).replace(
                f"ws://{host}", local_origin.replace("http", "ws", 1))
        out.append((k, v))
    return out


def local_origin_of(request: web.Request) -> str:
    return f"{request.scheme}://{request.host}"


# -- Handlers -----------------------------------------------------------------------------------

async def forward(cfg: Config, request: web.Request, cache_override: str | None = None) -> web.StreamResponse:
    sess: aiohttp.ClientSession = request.app[CLIENT]
    url = URL(cfg.upstream_origin + request.rel_url.raw_path_qs, encoded=True)
    body = await request.read() if request.can_read_body else None
    try:
        resp = await sess.request(request.method, url, headers=up_headers(cfg, request), data=body,
                                  allow_redirects=False)
    except aiohttp.ClientError as e:
        return web.Response(status=502, text=f"devproxy: upstream unreachable: {e}")
    async with resp:
        out = web.StreamResponse(status=resp.status, reason=resp.reason)
        for k, v in down_headers(cfg, resp, local_origin_of(request)):
            out.headers.add(k, v)
        if cache_override and resp.status == 200:
            out.headers["Cache-Control"] = cache_override
        if "Content-Length" in resp.headers and request.method != "HEAD":
            out.content_length = int(resp.headers["Content-Length"])
        elif request.method == "HEAD" and "Content-Length" in resp.headers:
            out.headers["Content-Length"] = resp.headers["Content-Length"]
        await out.prepare(request)
        if request.method != "HEAD":
            async for chunk in resp.content.iter_chunked(64 * 1024):
                await out.write(chunk)
        await out.write_eof()
        return out


async def ws_relay(cfg: Config, request: web.Request) -> web.StreamResponse:
    sess: aiohttp.ClientSession = request.app[CLIENT]
    url = URL(str(cfg.upstream_ws) + request.rel_url.raw_path_qs, encoded=True)
    h = {"Origin": cfg.upstream_origin}
    for k in ("Cookie", "User-Agent", "Sec-Fetch-Site", "Sec-Fetch-Mode"):
        if k in request.headers:
            h[k] = request.headers[k]
    try:
        up = await sess.ws_connect(url, headers=h, autoping=True, max_msg_size=0, compress=0)
    except aiohttp.WSServerHandshakeError as e:
        return web.Response(status=e.status or 502, text=f"devproxy: upstream refused the WebSocket ({e.status})")
    except aiohttp.ClientError as e:
        return web.Response(status=502, text=f"devproxy: upstream WebSocket failed: {e}")
    down = web.WebSocketResponse(autoping=True, max_msg_size=0)
    await down.prepare(request)

    async def pump(src, dst):
        async for msg in src:
            if msg.type == WSMsgType.BINARY:
                await dst.send_bytes(msg.data)
            elif msg.type == WSMsgType.TEXT:
                await dst.send_str(msg.data)
            elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED, WSMsgType.ERROR):
                break
        await dst.close()

    try:
        await asyncio.gather(pump(down, up), pump(up, down), return_exceptions=True)
    finally:
        await up.close()
        await down.close()
    return down


async def data_index(cfg: Config, request: web.Request) -> web.StreamResponse:
    sess: aiohttp.ClientSession = request.app[CLIENT]
    url = URL(cfg.upstream_origin + request.rel_url.raw_path_qs, encoded=True)
    try:
        async with sess.get(url, headers=up_headers(cfg, request, identity=True), allow_redirects=False) as resp:
            raw = await resp.read()
            if resp.status != 200:
                return web.Response(status=resp.status, body=raw, headers={
                    "Content-Type": resp.headers.get("Content-Type", "text/plain")})
            enc = resp.headers.get("Content-Encoding", "")
            if enc:  # an upstream that ignored identity
                import gzip, zlib
                raw = gzip.decompress(raw) if enc == "gzip" else zlib.decompress(raw) if enc == "deflate" else raw
    except aiohttp.ClientError as e:
        return web.Response(status=502, text=f"devproxy: upstream unreachable: {e}")
    names = json.loads(raw)
    seen = {n.replace("/", "\\").lower() for n in names}
    added = [n for n in local_overlay_names(cfg) if n.lower() not in seen]
    request.app[STATS]["index_added"] = len(added)
    return web.json_response(names + added, headers={"Cache-Control": "no-store", "X-OW-Devproxy": f"merged +{len(added)}"})


def make_handler(cfg: Config):
    async def handler(request: web.Request) -> web.StreamResponse:
        path = request.path  # decoded; used only to classify
        if path.startswith("/ws/") and request.headers.get("Upgrade", "").lower() == "websocket":
            return await ws_relay(cfg, request)
        if request.method in ("GET", "HEAD"):
            if path == "/data/__index":
                return await data_index(cfg, request)
            if path == "/data/__addons" and cfg.data_overlay:
                return web.json_response({"root": "Interface/AddOns/", "addons": list_addons(cfg)},
                                         headers={"Cache-Control": "no-store", "X-OW-Devproxy": "local"})
            if path.startswith("/data/"):
                name = norm_data_name(request.rel_url.raw_path[len("/data/"):])
                f = local_data_file(cfg, name)
                if f is not None:
                    log(cfg, f"local  {name}")
                    return file_response(request, f, data_type(name),
                                         {"Cross-Origin-Resource-Policy": "same-origin"})
                if name.lower().startswith(OVERLAY_PREFIXES):
                    # Not local, but the same folders: never let the browser pin a stale copy
                    # (the realm marks every /data file immutable for a year).
                    return await forward(cfg, request, cache_override="no-cache")
                return await forward(cfg, request)
            f = local_page_file(cfg, path)
            if f is not None:
                log(cfg, f"local  {path}")
                extra = {"Service-Worker-Allowed": "/"} if path == "/ow/sw.js" else None
                return file_response(request, f, extra=extra)
        return await forward(cfg, request)
    return handler


def log(cfg: Config, msg: str):
    if cfg.verbose:
        print(msg, flush=True)


def build_app(cfg: Config) -> web.Application:
    app = web.Application(client_max_size=64 * 1024 * 1024)
    app[STATS] = {}

    async def client_ctx(app):
        ssl_ctx = False if cfg.insecure else ssl.create_default_context()
        conn = aiohttp.TCPConnector(ssl=ssl_ctx, limit=64)
        app[CLIENT] = aiohttp.ClientSession(connector=conn, auto_decompress=False,
                                              cookie_jar=aiohttp.DummyCookieJar(),
                                              timeout=aiohttp.ClientTimeout(total=None, sock_connect=15))
        yield
        await app[CLIENT].close()

    app.cleanup_ctx.append(client_ctx)
    app.router.add_route("*", "/{tail:.*}", make_handler(cfg))
    return app


# -- HTTPS (optional) ---------------------------------------------------------------------------

def self_signed(cert_dir: Path) -> ssl.SSLContext:
    cert, key = cert_dir / "localhost.crt", cert_dir / "localhost.key"
    if not cert.exists():
        try:
            from cryptography import x509
            from cryptography.x509.oid import NameOID
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import ec
        except ImportError:
            sys.exit("--https needs: py -3 -m pip install cryptography")
        import datetime, ipaddress
        k = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
        now = datetime.datetime.now(datetime.timezone.utc)
        c = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(k.public_key())
             .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
             .not_valid_after(now + datetime.timedelta(days=825))
             .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"),
                            x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
             .sign(k, hashes.SHA256()))
        cert_dir.mkdir(parents=True, exist_ok=True)
        cert.write_bytes(c.public_bytes(serialization.Encoding.PEM))
        key.write_bytes(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                        serialization.NoEncryption()))
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.load_cert_chain(cert, key)
    return ctx


def banner(cfg: Config, url: str):
    live = []
    for label, p in (("page layer  /ow/*            ", cfg.www),
                     ("bridge.js / addons-loader.js ", cfg.classicplus),
                     ("login backdrop /login-backdrop.*", cfg.backdrop)):
        live.append(f"  {label} <- {p}{'' if p.exists() else '   (missing: forwarded)'}")
    if cfg.data_overlay:
        addons = [a["name"] for a in list_addons(cfg)]
        live.append(f"  /data/Interface/AddOns|ClassicPlus <- {cfg.data}")
        live.append(f"     addons: {', '.join(addons) if addons else '(none found)'}")
    line = "=" * 72
    print(f"""{line}
 Open Vanilla dev proxy
   open      {url}
   upstream  {cfg.upstream_origin}
 served from your checkout (no-store, edits live on reload / in-game /reload):
{chr(10).join(live)}
 sign in with a web password (Discord sign-in returns to the realm's own domain)
 Ctrl+C to stop
{line}""", flush=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Open Vanilla dev proxy (see the module docstring)")
    ap.add_argument("--upstream", default="https://play.openvanilla.app")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--bind", default="127.0.0.1", help="address to listen on (default 127.0.0.1)")
    ap.add_argument("--repo", default=".", help="the openvanilla checkout (default: current folder)")
    ap.add_argument("--https", action="store_true", help="serve https://localhost with a self-signed cert")
    ap.add_argument("--insecure", action="store_true", help="do not verify the upstream's TLS certificate")
    ap.add_argument("--no-data-overlay", action="store_true", help="forward every /data request untouched")
    ap.add_argument("-v", "--verbose", action="store_true", help="log each locally served file")
    a = ap.parse_args(argv)
    cfg = Config(a.upstream, Path(a.repo), https=a.https, insecure=a.insecure,
                 data_overlay=not a.no_data_overlay, verbose=a.verbose)
    if not (cfg.repo / "realm").is_dir():
        print(f"warning: {cfg.repo} has no realm/ folder; run from the openvanilla checkout or pass --repo", flush=True)
    ssl_ctx = self_signed(Path(__file__).resolve().parent / ".cert") if a.https else None
    url = f"{'https' if a.https else 'http'}://localhost:{a.port}/"
    banner(cfg, url)
    web.run_app(build_app(cfg), host=a.bind, port=a.port, ssl_context=ssl_ctx, print=None,
                access_log=None)


if __name__ == "__main__":
    main()
