"""Tests for devproxy.py against fake_realm.py. Run either way:

    py -3 -m pytest devkit/proxy/test_devproxy.py
    py -3 devkit/proxy/test_devproxy.py
"""
from __future__ import annotations

import asyncio
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import aiohttp  # noqa: E402
from aiohttp import web  # noqa: E402

import devproxy  # noqa: E402
import fake_realm  # noqa: E402


def make_repo(root: Path):
    (root / "realm/www").mkdir(parents=True)
    (root / "realm/www/openvanilla.js").write_text("// LOCAL openvanilla")
    (root / "realm/www/sw.js").write_text("// LOCAL sw")
    (root / "realm/classicplus").mkdir(parents=True)
    (root / "realm/classicplus/bridge.js").write_text("// LOCAL bridge")
    (root / "realm/classicplus/addons-loader.js").write_text("// LOCAL loader")
    core = root / "Data/Interface/AddOns/WenillaCore"
    core.mkdir(parents=True)
    (core / "WenillaCore.toc").write_text("## Interface: 11200\n## X-ClassicPlus: Core\nWenillaCore.lua\nNew.lua\n")
    (core / "WenillaCore.lua").write_text("-- LOCAL core")
    (core / "New.lua").write_text("-- LOCAL brand new file")
    (root / "Data/Interface/ClassicPlus").mkdir(parents=True)
    (root / "Data/Interface/ClassicPlus/Sample.blp").write_bytes(b"BLP2local")


async def start(app, port=0):
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", port)
    await site.start()
    return runner, site._server.sockets[0].getsockname()[1]


async def run_checks():
    results = []

    def check(name, cond, detail=""):
        results.append((name, bool(cond), detail))

    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        make_repo(repo)
        holder = {}
        up_app = fake_realm.build(holder)
        up_runner, up_port = await start(up_app)
        holder["origin"] = f"http://127.0.0.1:{up_port}"
        cfg = devproxy.Config(holder["origin"], repo)
        px_runner, px_port = await start(devproxy.build_app(cfg))
        base = f"http://127.0.0.1:{px_port}"
        jar = aiohttp.CookieJar(unsafe=True)
        try:
            async with aiohttp.ClientSession(cookie_jar=jar) as s:
                # Not signed in: forwarded pages and data need the session; local files do not.
                r = await s.get(base + "/data/World%5CMaps%5CAzeroth%5CAzeroth.wdt")
                check("unauthenticated /data is 401 from upstream", r.status == 401, r.status)
                r = await s.get(base + "/", headers={"Accept": "text/html"}, allow_redirects=False)
                check("unauthenticated page redirects to /login", r.status == 303 and r.headers["Location"] == "/login",
                      (r.status, r.headers.get("Location")))
                r = await s.get(base + "/go-login", allow_redirects=False)
                check("absolute Location rewritten to the proxy", r.headers.get("Location") == base + "/login",
                      r.headers.get("Location"))

                # Log in through the proxy, as a browser would (same-origin form post).
                r = await s.post(base + "/login", data={"username": fake_realm.USER, "password": fake_realm.PASS},
                                 headers={"Origin": base, "Referer": base + "/login", "Sec-Fetch-Site": "same-origin"},
                                 allow_redirects=False)
                cookie = r.headers.get("Set-Cookie", "")
                check("login 303 to /", r.status == 303 and r.headers.get("Location") == "/", r.status)
                check("session cookie kept, Secure dropped on http", cookie.startswith("wr_session=") and
                      "secure" not in cookie.lower() and "HttpOnly" in cookie and "Path=/" in cookie, cookie)
                check("Origin rewritten to upstream", up_app[fake_realm.SEEN]["origins"][-1] == holder["origin"],
                      up_app[fake_realm.SEEN]["origins"])
                check("Referer rewritten to upstream", up_app[fake_realm.SEEN]["referers"][-1] == holder["origin"] + "/login",
                      up_app[fake_realm.SEEN]["referers"])
                r = await s.post(base + "/login", data={"username": "x", "password": "y"},
                                 headers={"Sec-Fetch-Site": "cross-site"}, allow_redirects=False)
                check("cross-site POST still refused upstream (csrf.rs)", r.status == 403, r.status)

                # Signed in: the play page comes from upstream, with transport headers stripped.
                r = await s.get(base + "/", headers={"Accept": "text/html"})
                body = await r.text()
                check("cookie survives: play page loads", r.status == 200 and "PLAY" in body, (r.status, body[:40]))
                check("HSTS and Alt-Svc dropped", "Strict-Transport-Security" not in r.headers and "Alt-Svc" not in r.headers)
                csp = r.headers.get("Content-Security-Policy", "")
                check("CSP origin rewritten", holder["origin"] not in csp and base in csp and
                      base.replace("http", "ws", 1) in csp, csp)
                check("COEP passes through", r.headers.get("Cross-Origin-Embedder-Policy") == "require-corp")

                # Overrides.
                for path, want in (("/ow/openvanilla.js", "LOCAL openvanilla"), ("/bridge.js", "LOCAL bridge"),
                                   ("/addons-loader.js?v=1.1.0", "LOCAL loader")):
                    r = await s.get(base + path, headers={"Accept-Encoding": "br, gzip"})
                    t = await r.text()
                    check(f"{path} from disk, no-store, identity", want in t and r.headers.get("Cache-Control") == "no-store"
                          and "Content-Encoding" not in r.headers, (t[:30], dict(r.headers)))
                r = await s.get(base + "/ow/sw.js")
                check("/ow/sw.js gets Service-Worker-Allowed: /", r.headers.get("Service-Worker-Allowed") == "/")
                r = await s.get(base + "/ow/only-upstream.js")
                check("/ow file missing locally falls through to upstream", "UPSTREAM only" in await r.text())
                r = await s.get(base + "/wenilla.js")
                check("other static from upstream", "UPSTREAM wenilla" in await r.text())

                # Addon files in every spelling the page and the wasm use.
                for path in ("/data/Interface/AddOns/WenillaCore/WenillaCore.lua",
                             "/data/Interface%5CAddOns%5CWenillaCore%5CWenillaCore.lua",
                             "/data/interface%2Faddons%2Fwenillacore%2Fwenillacore.lua"):
                    r = await s.get(base + path)
                    t = await r.text()
                    check(f"addon override {path}", t == "-- LOCAL core" and r.headers.get("Cache-Control") == "no-store", t)
                r = await s.head(base + "/data/Interface%5CAddOns%5CWenillaCore%5CNew.lua")
                check("HEAD on a new local addon file is 200", r.status == 200, r.status)
                r = await s.get(base + "/data/Interface/ClassicPlus/Sample.blp")
                check("ClassicPlus art from disk as image/x-blp", (await r.read()) == b"BLP2local" and
                      r.headers.get("Content-Type") == "image/x-blp")
                r = await s.get(base + "/data/Interface/AddOns/WenillaCore/../../../realm/www/openvanilla.js")
                check("no path escape", r.status in (401, 404), r.status)
                r = await s.get(base + "/data/Interface%5CAddOns%5C..%5C..%5C..%5Crealm%5Cwww%5Copenvanilla.js")
                check("no path escape (encoded)", r.status in (401, 404) and "LOCAL" not in await r.text(), r.status)

                # Everything else from upstream, compressed bytes passed through untouched.
                r = await s.get(base + "/data/World%5CMaps%5CAzeroth%5CAzeroth.wdt",
                                headers={"Accept-Encoding": "gzip"}, auto_decompress=False)
                raw = await r.read()
                import gzip
                check("upstream /data passes gzip through", r.headers.get("Content-Encoding") == "gzip" and
                      gzip.decompress(raw) == b"UPSTREAM:World\\Maps\\Azeroth\\Azeroth.wdt", r.headers.get("Content-Encoding"))
                check("upstream /data keeps immutable caching",
                      "immutable" in r.headers.get("Cache-Control", ""), r.headers.get("Cache-Control"))
                r = await s.head(base + "/data/World%5CMaps%5CAzeroth%5CAzeroth.wdt")
                check("HEAD forwarded", r.status == 200, r.status)

                # Listings.
                r = await s.get(base + "/data/__index", headers={"Accept-Encoding": "gzip"})
                names = await r.json()
                low = [n.lower() for n in names]
                check("__index keeps upstream names", "interface\\framexml\\ui.lua" in low)
                check("__index adds new local files once", "interface\\addons\\wenillacore\\new.lua" in low and
                      low.count("interface\\addons\\wenillacore\\wenillacore.lua") == 1 and
                      "interface\\classicplus\\sample.blp" in low, [n for n in names if "AddOns" in n or "Plus" in n])
                check("__index not cached", r.headers.get("Cache-Control") == "no-store")
                r = await s.get(base + "/data/__addons")
                j = await r.json()
                check("__addons lists local suite", [a["name"] for a in j["addons"]] == ["WenillaCore"] and
                      "WenillaCore/New.lua" in j["addons"][0]["files"], j)

                # WebSocket relay with the session cookie.
                async with s.ws_connect(base.replace("http", "ws") + "/ws/3724?host=x",
                                        headers={"Origin": base}) as ws:
                    await ws.send_bytes(b"\x00\x01hello")
                    m = await asyncio.wait_for(ws.receive(), 5)
                    check("WS binary echo through proxy", m.data == b"echo:\x00\x01hello", m)
                    await ws.send_str("text")
                    m = await asyncio.wait_for(ws.receive(), 5)
                    check("WS text echo through proxy", m.data == "echo:text", m)
                check("WS Origin rewritten", up_app[fake_realm.SEEN]["ws_origins"][-1] == holder["origin"])

            async with aiohttp.ClientSession() as anon:
                try:
                    async with anon.ws_connect(base.replace("http", "ws") + "/ws/3724") as ws:
                        check("WS without session refused", False, "connected")
                except aiohttp.WSServerHandshakeError as e:
                    check("WS without session refused", e.status == 401, e.status)
        finally:
            await px_runner.cleanup()
            await up_runner.cleanup()
    return results


def test_devproxy():
    results = asyncio.run(run_checks())
    bad = [r for r in results if not r[1]]
    assert not bad, "\n".join(f"{n}: {d}" for n, _, d in bad)


def test_cookie_rewrite_rules():
    cfg = devproxy.Config("https://play.openvanilla.app", Path("."))
    assert devproxy.rewrite_cookie(cfg, "a=1; Domain=play.openvanilla.app; Secure; Path=/") == "a=1; Path=/"
    assert devproxy.rewrite_cookie(cfg, "__Host-a=1; Secure; Path=/") == "__Host-a=1; Secure; Path=/"
    assert devproxy.rewrite_cookie(cfg, "b=1; SameSite=None; Secure") == "b=1; SameSite=Lax"
    cfg.https = True
    assert devproxy.rewrite_cookie(cfg, "a=1; Domain=x; Secure") == "a=1; Secure"


if __name__ == "__main__":
    res = asyncio.run(run_checks())
    for name, ok, detail in res:
        print(f"{'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"   -> {detail}"))
    test_cookie_rewrite_rules()
    print("PASS  cookie rewrite rules")
    failed = sum(1 for r in res if not r[1])
    print(f"\n{len(res) - failed + 1}/{len(res) + 1} passed")
    sys.exit(1 if failed else 0)
