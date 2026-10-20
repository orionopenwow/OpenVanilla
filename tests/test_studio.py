"""Server Studio tests: SRP6, sign-in, the local-only guard, CSRF, and every demo-mode route.

    py -3 -m pytest tests/test_studio.py -q
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from studio import srp  # noqa: E402
import studio_server  # noqa: E402


def test_srp_roundtrip():
    s, v = srp.generate("bob", "secret1")
    assert srp.check("BOB", "SECRET1", s, v)
    assert srp.check("bob", "secret1", s, v)  # case-insensitive like the client
    assert not srp.check("BOB", "WRONG", s, v)
    assert not srp.check("BOB", "SECRET1", "zz", v)


def test_srp_matches_existing_generator():
    """Accounts made by the old panel / sign-up page must verify in Studio."""
    import hashlib
    N, g = srp.N, srp.G
    salt = os.urandom(32)
    h1 = hashlib.sha1(b"ALICE:PASS").digest()
    x = int.from_bytes(hashlib.sha1(salt[::-1] + h1).digest(), "little")
    v = pow(g, x, N)
    s_hex, v_hex = salt.hex().upper(), int.to_bytes(v, 32, "little")[::-1].hex().upper()
    assert srp.check("ALICE", "PASS", s_hex, v_hex)


@pytest.fixture
async def client(aiohttp_client, tmp_path):
    app = studio_server.make_app("demo", str(tmp_path))
    return await aiohttp_client(app, headers={"Host": "localhost"})


async def login(client, user="ADMIN", pw="admin"):
    r = await client.post("/studio/api/login", json={"username": user, "password": pw})
    assert r.status == 200, await r.text()
    r = await client.get("/studio/api/session")
    return (await r.json())["csrf"]


async def test_requires_login(client):
    r = await client.get("/studio/api/overview")
    assert r.status == 401


async def test_wrong_password(client):
    r = await client.post("/studio/api/login", json={"username": "ADMIN", "password": "nope"})
    assert r.status == 401


async def test_non_admin_refused(client):
    r = await client.post("/studio/api/login", json={"username": "THRALLFAN", "password": "PASS2"})
    assert r.status == 403


async def test_remote_and_proxied_refused(aiohttp_client, tmp_path):
    app = studio_server.make_app("demo", str(tmp_path))
    c = await aiohttp_client(app, headers={"Host": "evil.example"})
    r = await c.post("/studio/api/login", json={"username": "ADMIN", "password": "ADMIN"})
    assert r.status == 403
    c2 = await aiohttp_client(app, headers={"Host": "localhost", "X-Forwarded-For": "203.0.113.5"})
    r = await c2.post("/studio/api/login", json={"username": "ADMIN", "password": "ADMIN"})
    assert r.status == 403


async def test_csrf_required(client):
    await login(client)
    r = await client.post("/studio/api/motd", json={"text": "hi"})
    assert r.status == 403


async def test_overview_and_routes(client):
    csrf = await login(client)
    h = {"X-Studio-CSRF": csrf}
    r = await client.get("/studio/api/overview")
    d = await r.json()
    assert r.status == 200 and d["realm"]["name"] == "Vanilla Reloaded"
    assert d["info"]["online"] >= 0 and len(d["services"]) == 4

    r = await client.get("/studio/api/accounts?q=moon")
    d = await r.json()
    assert d["total"] == 1 and d["rows"][0]["username"] == "MOONGLADE"
    acc = d["rows"][0]["id"]

    r = await client.post(f"/studio/api/accounts/{acc}/role", json={"role": 2}, headers=h)
    assert r.status == 200, await r.text()
    change = (await r.json())["change"]
    r = await client.post(f"/studio/api/changes/{change}/undo", headers=h)
    assert r.status == 200
    r = await client.get("/studio/api/accounts?q=moon")
    assert (await r.json())["rows"][0]["gmlevel"] == 0

    r = await client.post("/studio/api/accounts", json={"username": "newbie", "password": "abcd1", "role": 0}, headers=h)
    assert r.status == 200
    r = await client.post("/studio/api/accounts", json={"username": "newbie", "password": "abcd1", "role": 0}, headers=h)
    assert r.status == 400 and "taken" in (await r.json())["error"]
    r = await client.post("/studio/api/accounts", json={"username": "x", "password": "abcd1"}, headers=h)
    assert r.status == 400

    r = await client.post(f"/studio/api/accounts/{acc}/ban", json={"duration": "7d", "reason": "spam"}, headers=h)
    assert r.status == 200
    r = await client.post(f"/studio/api/accounts/{acc}/ban", json={"duration": "forever"}, headers=h)
    assert r.status == 400
    r = await client.post("/studio/api/accounts/1/ban", json={"duration": "1d"}, headers=h)
    assert r.status == 400  # yourself
    r = await client.post("/studio/api/accounts/1/role", json={"role": 0}, headers=h)
    assert r.status == 400  # your own admin role

    r = await client.post("/studio/api/motd", json={"text": "Double XP weekend!"}, headers=h)
    assert r.status == 200
    r = await client.get("/studio/api/messages")
    assert (await r.json())["motd"] == "Double XP weekend!"
    r = await client.post("/studio/api/announce", json={"text": "Restart soon", "style": "notify"}, headers=h)
    assert r.status == 200
    r = await client.post("/studio/api/restart", json={"seconds": 300}, headers=h)
    assert r.status == 200
    r = await client.post("/studio/api/restart", json={"cancel": True}, headers=h)
    assert r.status == 200

    r = await client.post("/studio/api/realm", json={"name": "Stormreach", "address": "play.example.com"}, headers=h)
    assert r.status == 200 and len((await r.json())["changes"]) == 2
    r = await client.post("/studio/api/realm", json={"address": "bad host!"}, headers=h)
    assert r.status == 400

    r = await client.post("/studio/api/backups", headers=h)
    assert r.status == 200
    name = (await r.json())["name"]
    r = await client.get(f"/studio/api/backups/file/{name}")
    assert r.status == 200
    r = await client.get("/studio/api/backups/file/..%2F..%2Fetc%2Fpasswd")
    assert r.status in (400, 404)
    r = await client.post("/studio/api/backups/settings", json={"hour": 30}, headers=h)
    assert r.status == 400

    r = await client.post("/studio/api/services/restart", json={"service": "mangosd"}, headers=h)
    assert r.status == 200
    r = await client.post("/studio/api/services/stop", json={"service": "web"}, headers=h)
    assert r.status == 400
    r = await client.post("/studio/api/services/stop", json={"service": "nope"}, headers=h)
    assert r.status == 400

    r = await client.get("/studio/api/changes")
    kinds = [c["kind"] for c in (await r.json())["changes"]]
    assert {"role", "motd", "realm", "ban", "create_account"} <= set(kinds)

    r = await client.get("/studio/api/logs?source=studio")
    assert r.status == 200 and (await r.json())["lines"]

    r = await client.post("/studio/api/logout", headers=h)
    assert r.status == 200
    r = await client.get("/studio/api/overview")
    assert r.status == 401


async def test_static_and_headers(client):
    r = await client.get("/studio/")
    assert r.status == 200 and "Content-Security-Policy" in r.headers
    r = await client.get("/studio/kit/kit.css")
    assert r.status == 200


# ── regressions from the security review ─────────────────────────────────────────────────
async def test_demoted_admin_loses_session(aiohttp_client, tmp_path):
    app = studio_server.make_app("demo", str(tmp_path))
    a = await aiohttp_client(app, headers={"Host": "localhost"})
    csrf = await login(a)
    r = await a.post("/studio/api/accounts", json={"username": "adm2", "password": "pass2", "role": 3}, headers={"X-Studio-CSRF": csrf})
    adm2 = (await r.json())["id"]
    b = await aiohttp_client(app, headers={"Host": "localhost"})
    csrf_b = await login(b, "ADM2", "PASS2")
    assert (await b.get("/studio/api/overview")).status == 200
    r = await a.post(f"/studio/api/accounts/{adm2}/role", json={"role": 0}, headers={"X-Studio-CSRF": csrf})
    assert r.status == 200
    r = await b.post("/studio/api/accounts/1/role", json={"role": 0}, headers={"X-Studio-CSRF": csrf_b})
    assert r.status == 401


async def test_lockout_is_per_account(client):
    for _ in range(8):
        await client.post("/studio/api/login", json={"username": "NOBODY", "password": "x"})
    r = await client.post("/studio/api/login", json={"username": "NOBODY", "password": "x"})
    assert r.status == 429
    r = await client.post("/studio/api/login", json={"username": "ADMIN", "password": "ADMIN"})
    assert r.status == 200


async def test_any_proxy_header_refused(aiohttp_client, tmp_path):
    app = studio_server.make_app("demo", str(tmp_path))
    for hdr in ({"X-Forwarded-Proto": "https"}, {"Via": "1.1 caddy"}, {"X-Real-IP": "1.2.3.4"}):
        c = await aiohttp_client(app, headers={"Host": "localhost", **hdr})
        r = await c.post("/studio/api/login", json={"username": "ADMIN", "password": "ADMIN"})
        assert r.status == 403, hdr


async def test_origin_must_match_exactly(client):
    csrf = await login(client)
    r = await client.post("/studio/api/motd", json={"text": "hi"}, headers={"X-Studio-CSRF": csrf, "Origin": "http://localhost:3000"})
    assert r.status == 403
    r = await client.post("/studio/api/motd", json={"text": "hi"}, headers={"X-Studio-CSRF": "ünïcode"})
    assert r.status == 403


async def test_stale_undo_refused_and_bad_address(client):
    csrf = await login(client)
    h = {"X-Studio-CSRF": csrf}
    r = await client.post("/studio/api/accounts/3/role", json={"role": 1}, headers=h)
    first = (await r.json())["change"]
    await client.post("/studio/api/accounts/3/role", json={"role": 2}, headers=h)
    r = await client.post(f"/studio/api/changes/{first}/undo", headers=h)
    assert r.status == 400
    r = await client.post("/studio/api/realm", json={"address": "fe80::1%eth0"}, headers=h)
    assert r.status == 400


async def test_attaches_beside_website(aiohttp_client, tmp_path, unused_tcp_port):
    from aiohttp import web
    from studio import setup_studio
    site = web.Application()
    setup_studio(site, studio_server.BASE_DIR, mode="demo", state_dir=str(tmp_path), port=unused_tcp_port)
    c = await aiohttp_client(site, headers={"Host": "localhost"})
    r = await c.get("/studio/", allow_redirects=False)
    assert r.status == 302 and r.headers["Location"] == f"http://localhost:{unused_tcp_port}/studio/"
    c2 = await aiohttp_client(site, headers={"Host": "play.example.com"})
    assert (await c2.get("/studio/", allow_redirects=False)).status == 404
    import aiohttp
    async with aiohttp.ClientSession() as s:
        async with s.post(f"http://127.0.0.1:{unused_tcp_port}/studio/api/login", json={"username": "ADMIN", "password": "ADMIN"}) as r:
            assert r.status == 200
