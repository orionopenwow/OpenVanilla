"""A tiny stand-in for wenilla-realm, for test_devproxy.py: just the behaviour the dev proxy has
to get right, copied from crates/wenilla-realm (session.rs, csrf.rs, auth/local.rs) and
crates/wenilla-host (data.rs, ws.rs, static_site.rs):

  * POST /login (form): 403 when Sec-Fetch-Site is cross-site (csrf.rs), else a 303 to "/"
    with  Set-Cookie: wr_session=...; HttpOnly; SameSite=Lax; Secure; Path=/; Max-Age=2592000
  * everything else needs the cookie: 401 for /data, /ws, /api; a 303 to /login for pages
  * /data/<name>: percent-decoded, '/' -> '\\', immutable for a year, gzip when asked
  * /data/__index: a JSON array of chain names, max-age=86400
  * /ws/<port>: echoes binary frames
  * the play page carries COOP/COEP and, to exercise the rewriting, a CSP naming its own origin,
    HSTS and Alt-Svc (the real realm sets no CSP; Caddy adds HSTS and Alt-Svc)

It also records what reached it (origins, referers) so the test can check the rewriting.
"""
from __future__ import annotations

import gzip
import json
import secrets
import urllib.parse

from aiohttp import web, WSMsgType

SESSIONS = web.AppKey("sessions", set)
SEEN = web.AppKey("seen", dict)

USER, PASS = "tester", "correct horse"
INDEX = ["Interface\\FrameXML\\UI.lua", "Interface\\AddOns\\WenillaCore\\WenillaCore.toc",
         "Interface\\AddOns\\WenillaCore\\WenillaCore.lua", "World\\Maps\\Azeroth\\Azeroth.wdt"]
FILES = {n.lower(): f"UPSTREAM:{n}".encode() for n in INDEX}


def build(origin_holder: dict) -> web.Application:
    app = web.Application()
    app[SESSIONS] = set()
    app[SEEN] = {"origins": [], "referers": [], "ws_origins": []}

    def origin():
        return origin_holder["origin"]

    def authed(request):
        return request.cookies.get("wr_session") in app[SESSIONS]

    def unauth(request):
        p = request.path
        if p.startswith(("/data/", "/ws/", "/api/")) or "text/html" not in request.headers.get("Accept", ""):
            return web.Response(status=401, headers={"Cache-Control": "no-store"})
        raise web.HTTPSeeOther("/login")

    async def login_page(request):
        return web.Response(text='<form method="post" action="/login"><input name="username">'
                                 '<input name="password" type="password"><button type="submit">go</button></form>',
                            content_type="text/html")

    async def login(request):
        if request.headers.get("Sec-Fetch-Site") == "cross-site":
            return web.Response(status=403)
        app[SEEN]["origins"].append(request.headers.get("Origin"))
        app[SEEN]["referers"].append(request.headers.get("Referer"))
        form = await request.post()
        if form.get("username") != USER or form.get("password") != PASS:
            return web.Response(status=200, text="bad login", content_type="text/html")
        tok = secrets.token_urlsafe(16)
        app[SESSIONS].add(tok)
        r = web.Response(status=303, headers={"Location": "/"})
        r.headers.add("Set-Cookie", f"wr_session={tok}; HttpOnly; SameSite=Lax; Secure; Path=/; Max-Age=2592000")
        return r

    async def absolute_redirect(request):
        raise web.HTTPFound(origin() + "/login")

    async def play(request):
        if not authed(request):
            return unauth(request)
        return web.Response(text="<!doctype html><title>Play</title>PLAY", content_type="text/html", headers={
            "Cache-Control": "no-cache",
            "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp",
            "Content-Security-Policy": f"default-src 'self'; connect-src 'self' {origin().replace('http', 'ws', 1)}; img-src {origin()}",
            "Strict-Transport-Security": "max-age=31536000", "Alt-Svc": 'h3=":443"; ma=2592000',
        })

    def static(body):
        async def h(request):
            if not authed(request):
                return unauth(request)
            return web.Response(text=body, content_type="text/javascript", headers={"Cache-Control": "no-cache"})
        return h

    async def data_index(request):
        if not authed(request):
            return unauth(request)
        body = json.dumps(INDEX).encode()
        headers = {"Cache-Control": "private, max-age=86400", "Content-Type": "application/json"}
        if "gzip" in request.headers.get("Accept-Encoding", ""):
            body = gzip.compress(body)
            headers["Content-Encoding"] = "gzip"
        return web.Response(body=body, headers=headers)

    async def data(request):
        if not authed(request):
            return unauth(request)
        raw = request.rel_url.raw_path[len("/data/"):]
        name = urllib.parse.unquote(raw).replace("/", "\\")
        body = FILES.get(name.lower())
        if body is None:
            return web.Response(status=404)
        headers = {"Cache-Control": "private, max-age=31536000, immutable", "Content-Type": "application/octet-stream",
                   "Cross-Origin-Resource-Policy": "same-origin"}
        if "gzip" in request.headers.get("Accept-Encoding", ""):
            body = gzip.compress(body)
            headers["Content-Encoding"] = "gzip"
        if request.method == "HEAD":
            return web.Response(headers={**headers, "Content-Length": str(len(body))})
        return web.Response(body=body, headers=headers)

    async def ws(request):
        if not authed(request):
            return unauth(request)
        app[SEEN]["ws_origins"].append(request.headers.get("Origin"))
        sock = web.WebSocketResponse()
        await sock.prepare(request)
        async for msg in sock:
            if msg.type == WSMsgType.BINARY:
                await sock.send_bytes(b"echo:" + msg.data)
            elif msg.type == WSMsgType.TEXT:
                await sock.send_str("echo:" + msg.data)
        return sock

    app.router.add_get("/login", login_page)
    app.router.add_post("/login", login)
    app.router.add_get("/go-login", absolute_redirect)
    app.router.add_get("/", play)
    app.router.add_get("/bridge.js", static("// UPSTREAM bridge"))
    app.router.add_get("/addons-loader.js", static("// UPSTREAM loader"))
    app.router.add_get("/ow/openvanilla.js", static("// UPSTREAM openvanilla"))
    app.router.add_get("/ow/only-upstream.js", static("// UPSTREAM only"))
    app.router.add_get("/wenilla.js", static("// UPSTREAM wenilla"))
    app.router.add_get("/data/__index", data_index)
    app.router.add_route("GET", "/data/{name:.*}", data)
    app.router.add_route("HEAD", "/data/{name:.*}", data)
    app.router.add_get("/ws/{port}", ws)
    return app
