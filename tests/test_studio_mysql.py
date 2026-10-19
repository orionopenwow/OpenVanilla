"""Studio against a real MySQL/MariaDB loaded with CMaNGOS classic's base schema.

Skipped unless STUDIO_TEST_MYSQL=host:port:user:password is set. To run it:
  1. create classicrealmd and classiccharacters from mangos-classic/sql/base/{realmd,characters}.sql
  2. STUDIO_TEST_MYSQL=127.0.0.1:3310:root:secret py -3 -m pytest tests/test_studio_mysql.py -q
The schema seeds ADMINISTRATOR / ADMINISTRATOR (GM 3), which proves sign-in against verifiers
written by CMaNGOS itself, not just by Open Vanilla.
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from studio import srp  # noqa: E402
from studio.realmdata import SqlRealmData  # noqa: E402
import studio_server  # noqa: E402

CFG = os.environ.get("STUDIO_TEST_MYSQL")
pytestmark = pytest.mark.skipif(not CFG, reason="set STUDIO_TEST_MYSQL=host:port:user:password")


@pytest.fixture
def data():
    host, port, user, pw = CFG.split(":", 3)
    return SqlRealmData(host, int(port), user, pw)


def test_cmangos_seed_verifier(data):
    row = data.auth_row("ADMINISTRATOR")
    assert row and row["gmlevel"] == 3
    assert srp.check("ADMINISTRATOR", "ADMINISTRATOR", row["s"], row["v"])
    assert not srp.check("ADMINISTRATOR", "WRONG", row["s"], row["v"])


def test_queries(data):
    page = data.list_accounts("", 50, 0)
    assert page["total"] >= 4
    names = {r["username"] for r in page["rows"]}
    assert {"ADMINISTRATOR", "PLAYER"} <= names
    realm = data.realm()
    assert realm["id"] == 1
    c = data.counts()
    assert c["accounts"] >= 4
    data.online_players()


@pytest.fixture
async def client(aiohttp_client, tmp_path):
    host, port, user, pw = CFG.split(":", 3)
    app = studio_server.make_app("demo", str(tmp_path))
    from studio.app import KEY
    st = app[KEY]
    st.adapter.data = SqlRealmData(host, int(port), user, pw)  # real tables, demo services and SOAP
    st.adapter.data.x("realmd", "DELETE FROM account WHERE username=%s", ("STUDIOTEST",))  # left by an earlier run
    return await aiohttp_client(app, headers={"Host": "localhost"})


async def test_full_flow_on_real_tables(client):
    r = await client.post("/studio/api/login", json={"username": "administrator", "password": "administrator"})
    assert r.status == 200, await r.text()
    csrf = (await (await client.get("/studio/api/session")).json())["csrf"]
    h = {"X-Studio-CSRF": csrf}
    r = await client.get("/studio/api/overview")
    d = await r.json()
    assert d["counts"]["accounts"] >= 4 and d["realm"]["name"]

    r = await client.post("/studio/api/accounts", json={"username": "studiotest", "password": "pass1", "role": 1}, headers=h)
    assert r.status == 200, await r.text()
    new_id = (await r.json())["id"]
    r = await client.post(f"/studio/api/accounts/{new_id}/role", json={"role": 2}, headers=h)
    change = (await r.json())["change"]
    r = await client.post(f"/studio/api/accounts/{new_id}/password", json={"password": "newpw1"}, headers=h)
    assert r.status == 200
    r = await client.post(f"/studio/api/changes/{change}/undo", headers=h)
    assert r.status == 200
    page = await (await client.get("/studio/api/accounts?q=studiotest")).json()
    assert page["rows"][0]["gmlevel"] == 1
    # the new verifier must sign in (proves the write path matches CMaNGOS)
    r2 = await client.post("/studio/api/login", json={"username": "studiotest", "password": "newpw1"})
    assert r2.status == 403  # right password, but not an Administrator

    old = (await (await client.get("/studio/api/realm")).json())["realm"]
    r = await client.post("/studio/api/realm", json={"name": "Studio Test", "address": "10.0.0.5"}, headers=h)
    assert r.status == 200
    for cid in (await r.json())["changes"]:
        assert (await client.post(f"/studio/api/changes/{cid}/undo", headers=h)).status == 200
    back = (await (await client.get("/studio/api/realm")).json())["realm"]
    assert back["name"] == old["name"] and back["address"] == old["address"]
