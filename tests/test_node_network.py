"""Phase 5, the node network: end-to-end encryption, tiers, the supporter leaderboard, the node's
opt-in state machine, the Python relay node (forwarding with fakes), host assignment to a node and
the privacy rules.    python3 -m unittest tests.test_node_network -v"""
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p2p_fakes as F  # noqa: E402
from p2p import P2PError, directory, e2e, host, join, leaderboard, node, paseto, realmproto, tiers, ws  # noqa: E402
from p2p.bridge import Bridge  # noqa: E402
import ed25519  # noqa: E402
from test_p2p_host import HOST_ID, EchoServer, HostHarness, realm_client, wait_for  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST_SEED = bytes(range(100, 132))
HOST_PUB = ed25519.public_key(HOST_SEED)


def ws_pair():
    a, b = socket.socketpair()
    return ws.WebSocket(a, client=True), ws.WebSocket(b, client=False)


def ticket(node_id, host_id=HOST_ID, vis="public", exp_in=600, typ="node", now=None):
    now = int(now or time.time())
    return paseto.sign(F.SEED, {"typ": typ, "aud": node_id, "sub": host_id, "vis": vis, "iat": now,
                                "exp": now + exp_in}, kid=F.KID)


# ---------------------------------------------------------------- e2e

class E2ETests(unittest.TestCase):
    def test_x25519_rfc7748_vector_and_agreement(self):
        k = bytes.fromhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        u = bytes.fromhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        self.assertEqual(e2e.x25519(k, u).hex(), "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
        a, ap = e2e.keypair()
        b, bp = e2e.keypair()
        self.assertEqual(e2e.x25519(a, bp), e2e.x25519(b, ap))
        try:
            from cryptography.hazmat.primitives import serialization as s
            from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        except ImportError:
            return
        pk = X25519PrivateKey.from_private_bytes(a).public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
        self.assertEqual(pk, ap)

    def test_fingerprint_matches_host_key_fingerprint(self):
        self.assertEqual(e2e.fingerprint(HOST_PUB), host.key_fingerprint(HOST_PUB))

    def _pair(self, fp=None, host_id=HOST_ID):
        c, s = ws_pair()
        out = {}
        t = threading.Thread(target=lambda: out.update(s=e2e.server_handshake(s, HOST_ID, HOST_SEED)), daemon=True)
        t.start()
        try:
            cs = e2e.client_handshake(c, host_id, fp or e2e.fingerprint(HOST_PUB), timeout=5)
        finally:
            t.join(5)
        return cs, out.get("s"), c, s

    def test_handshake_seals_both_ways(self):
        cs, ss, raw_c, raw_s = self._pair()
        cs.send(b"hello host")
        self.assertEqual(ss.recv(), b"hello host")
        ss.send(b"hello player" * 100)
        self.assertEqual(cs.recv(), b"hello player" * 100)
        cs.send(b"")
        self.assertEqual(ss.recv(), b"")
        cs.close()
        self.assertIsNone(ss.recv())

    def test_wire_carries_no_plaintext_and_tampering_closes(self):
        # player <-> [spy relay] <-> host
        seen, flip = [], {"on": False}

        def relay(x, y):
            while True:
                m = x.recv()
                if m is None:
                    y.close()
                    return
                seen.append(m)
                if flip["on"] and len(m) > 20:
                    m = m[:5] + bytes([m[5] ^ 1]) + m[6:]
                y.send(m)
        h1, h2 = socket.socketpair()
        host_end, mid_host = ws.WebSocket(h1, client=False), ws.WebSocket(h2, client=True)
        p1, p2 = socket.socketpair()
        player_end, mid_player = ws.WebSocket(p1, client=True), ws.WebSocket(p2, client=False)
        threading.Thread(target=relay, args=(mid_player, mid_host), daemon=True).start()
        threading.Thread(target=relay, args=(mid_host, mid_player), daemon=True).start()
        sv = {}
        threading.Thread(target=lambda: sv.update(s=e2e.server_handshake(host_end, HOST_ID, HOST_SEED)),
                         daemon=True).start()
        cs = e2e.client_handshake(player_end, HOST_ID, e2e.fingerprint(HOST_PUB), timeout=5)
        self.assertTrue(wait_for(lambda: "s" in sv))
        cs.send(b"SECRET chat line v4.public.token")
        self.assertEqual(sv["s"].recv(), b"SECRET chat line v4.public.token")
        self.assertFalse(any(b"SECRET" in m or b"v4.public" in m for m in seen if isinstance(m, bytes)))
        flip["on"] = True
        cs.send(b"x" * 64)
        self.assertIsNone(sv["s"].recv(), "a modified frame closes the stream")
        cs.close()

    def test_wrong_host_key_or_no_key_is_refused(self):
        with self.assertRaises(e2e.E2EError) as cm:
            self._pair(fp="aaaaaaaaaaaaaaaa")
        self.assertIn("doesn't match", str(cm.exception))
        c, _ = ws_pair()
        with self.assertRaises(e2e.E2EError):
            e2e.client_handshake(c, HOST_ID, None)
        with self.assertRaises(e2e.E2EError):   # signed for another realm id: refused
            self._pair(host_id="zzzzzzzzzzzzzzzz")

    def test_replayed_frame_fails(self):
        cs, ss, raw_c, raw_s = self._pair()
        frame = cs._tx.seal(b"once")
        raw_c.send(frame)
        self.assertEqual(ss.recv(), b"once")
        raw_c.send(frame)
        self.assertIsNone(ss.recv())

    def test_connector_adds_query(self):
        self.assertEqual(e2e.with_e2e_query("ws://n:1/h/abc/ws/3724?invite=X"), "ws://n:1/h/abc/ws/3724?invite=X&e2e=1")


# ---------------------------------------------------------------- tiers

def passing_node(now):
    return {"first_seen": now - 5 * 86400, "probes_ok": 700, "probes_total": 720, "probe_ok_now": True,
            "key_proof": True, "protocol": 1, "e2e_required": True, "rules": 1,
            "caps": {"kbps": 512, "daily_gb": 10, "max_streams": 64}, "reports_open": 0}


class TierTests(unittest.TestCase):
    def test_realm_tiers_and_badges(self):
        self.assertEqual(tiers.tier_of_realm({"official": True}), "verified")
        self.assertEqual(tiers.tier_of_realm({"tags": ["Official"]}), "verified")
        self.assertEqual(tiers.tier_of_realm({"verified": True}), "verified")
        self.assertEqual(tiers.tier_of_realm({"relay": True}), "community")
        self.assertEqual(tiers.badges_for_realm({"relay": True, "e2e": True}), ["community", "relayed", "e2e"])
        self.assertEqual(tiers.badges_for_realm({"official": True}), ["official"])
        self.assertEqual(set(tiers.TIER_KEYS), {"verified", "community", "node"})
        for b in tiers.BADGES.values():
            self.assertIn(b["tier"], tiers.TIER_KEYS)

    def test_node_checks(self):
        now = 1_800_000_000
        c = tiers.node_checks(passing_node(now), now)
        self.assertTrue(tiers.checks_pass(c), c)
        for change, failing in (({"probe_ok_now": False}, "reachable"), ({"first_seen": now - 86400}, "history"),
                                ({"probes_ok": 600}, "uptime"), ({"e2e_required": False}, "software"),
                                ({"caps": {"kbps": 64, "daily_gb": 10, "max_streams": 64}}, "caps"),
                                ({"rules": 0}, "rules"), ({"reports_open": 2}, "standing"), ({"blocked": True}, "standing")):
            n = dict(passing_node(now), **change)
            c = tiers.node_checks(n, now)
            self.assertFalse(c[failing]["ok"], change)
            self.assertFalse(tiers.checks_pass(c))

    def test_node_status_flow(self):
        now = 1_800_000_000
        ok = tiers.node_checks(passing_node(now), now)
        bad = tiers.node_checks(dict(passing_node(now), probe_ok_now=False), now)
        young = tiers.node_checks(dict(passing_node(now), first_seen=now - 3600, probes_total=6, probes_ok=6), now)
        self.assertEqual(tiers.node_status("unlisted", young), "pending")          # reachable: pending at once
        self.assertEqual(tiers.node_status("unlisted", bad), "unlisted")
        self.assertEqual(tiers.node_status("pending", young, "approve"), "pending")  # can't approve too early
        self.assertEqual(tiers.node_status("pending", ok), "pending")              # never verified by machines alone
        self.assertEqual(tiers.node_status("pending", ok, "approve"), "verified")
        self.assertEqual(tiers.node_status("verified", ok, uptime_pct=99), "verified")
        self.assertEqual(tiers.node_status("verified", ok, uptime_pct=80), "suspended")
        self.assertEqual(tiers.node_status("verified", bad), "suspended")
        self.assertEqual(tiers.node_status("suspended", ok), "verified")           # recovers by itself
        self.assertEqual(tiers.node_status("verified", ok, "revoke"), "revoked")
        self.assertEqual(tiers.node_status("revoked", ok), "revoked")
        self.assertEqual(tiers.node_status("revoked", ok, "approve"), "revoked")
        self.assertEqual(tiers.node_status("revoked", ok, "unrevoke"), "pending")

    def test_realm_promotion_checks(self):
        now = 1_800_000_000
        r = {"first_listed": now - 20 * 86400, "probes_ok": 990, "probes_total": 1000, "identity": True,
             "backups": True, "description": "A friendly RP realm. Rules: be kind."}
        self.assertTrue(tiers.checks_pass(tiers.realm_promotion_checks(r, now)))
        self.assertFalse(tiers.checks_pass(tiers.realm_promotion_checks(dict(r, reports_upheld=1), now)))

    def test_public_realm_hides_relayed_host_address(self):
        e = {"name": "Home Realm", "host": "198.51.100.23", "port": 3724, "relay": True, "host_id": HOST_ID,
             "portal": "http://198.51.100.23:8090/", "external_ip": "198.51.100.23", "addr": "198.51.100.23:3724",
             "relay_url": "wss://relay.openvanilla.app/h/" + HOST_ID, "key": "abcdefghijklmnop", "e2e": True}
        out = tiers.public_realm(e)
        self.assertNotIn("198.51.100.23", json.dumps(out))
        self.assertEqual((out["host"], out["port"], out["tier"]), ("relay.openvanilla.app", 3724, "community"))
        self.assertIn("e2e", out["badges"])
        direct = tiers.public_realm({"name": "Direct", "host": "realm.example.org", "port": 3725, "relay": False})
        self.assertEqual((direct["host"], direct["port"]), ("realm.example.org", 3725))

    def test_public_node_has_no_address_or_key(self):
        n = {"node_id": "qqqqqqqqqqqqqqqq", "url": "ws://203.0.113.7:3728", "key": "ab" * 32, "status": "verified",
             "region": "eu", "leaderboard": "named", "display_name": "Ann", "since": "2026-10-01", "uptime_pct": 99.4}
        out = tiers.public_node(n)
        blob = json.dumps(out)
        for secret in ("203.0.113.7", "ws://", "qqqqqqqqqqqqqqqq", "ab" * 32):
            self.assertNotIn(secret, blob)
        self.assertEqual((out["name"], out["badges"], out["since"], out["uptime_pct"]), ("Ann", ["node"], "2026-10", 99))
        self.assertEqual(tiers.public_node(dict(n, leaderboard="anonymous"))["name"], "Anonymous node")

    def test_directory_entries_carry_tier_relay_url_and_key(self):
        rs = directory.parse({"servers": [
            {"name": "Node Realm", "host": "relay.openvanilla.app", "port": 3724, "relay": True, "host_id": HOST_ID,
             "relay_url": "ws://203.0.113.7:3728/h/" + HOST_ID, "key": "abcdefghijklmnop", "e2e": True},
            {"name": "Odd", "host": "relay.openvanilla.app", "relay": True, "host_id": "bbbbbbbbbbbbbbbb",
             "relay_url": "javascript:alert(1)", "key": "NOT A KEY", "e2e": True},
            {"name": "Vanilla Reloaded", "host": "play.openvanilla.app", "official": True}]})
        by = {r.name: r for r in rs}
        self.assertEqual(by["Node Realm"].relay_url, "ws://203.0.113.7:3728")
        self.assertTrue(by["Node Realm"].e2e)
        self.assertEqual((by["Odd"].relay_url, by["Odd"].key, by["Odd"].e2e), ("", "", False))
        self.assertEqual(by["Vanilla Reloaded"].tier, "verified")
        self.assertEqual(by["Node Realm"].tier, "community")
        self.assertEqual(directory.relay_base("wss://relay.openvanilla.app/h/" + HOST_ID, HOST_ID), "wss://relay.openvanilla.app")
        self.assertEqual(directory.relay_base("wss://x/other/path", HOST_ID), "")


# ---------------------------------------------------------------- leaderboard

class LeaderboardTests(unittest.TestCase):
    NOW = 1_792_000_000

    def day(self, back):
        import datetime
        return datetime.datetime.fromtimestamp(self.NOW - back * 86400, datetime.timezone.utc).strftime("%Y-%m-%d")

    def data(self):
        nodes = [
            {"node_id": "aaaaaaaaaaaaaaaa", "status": "verified", "region": "eu", "first_seen": self.NOW - 40 * 86400,
             "leaderboard": "named", "display_name": "  Ann  the  Relay ", "probes_ok_30d": 4300, "probes_total_30d": 4320,
             "caps": {"kbps": 512}, "url": "ws://203.0.113.7:3728", "ip": "203.0.113.7", "account_id": 4242},
            {"node_id": "bbbbbbbbbbbbbbbb", "status": "pending", "region": "us", "first_seen": self.NOW - 3 * 86400,
             "leaderboard": "anonymous", "display_name": "Bob", "probes_ok_30d": 400, "probes_total_30d": 432},
            {"node_id": "cccccccccccccccc", "status": "verified", "region": "us", "leaderboard": "off",
             "display_name": "Hidden Carl", "probes_ok_30d": 10, "probes_total_30d": 10},
            {"node_id": "dddddddddddddddd", "status": "revoked", "leaderboard": "named", "display_name": "Mallory"},
            {"node_id": "eeeeeeeeeeeeeeee", "status": "verified", "leaderboard": "named",
             "display_name": "Open Vanilla Staff", "caps": {"kbps": 32}},
        ]
        reports = [
            {"node_id": "aaaaaaaaaaaaaaaa", "day": self.day(1), "relay_bytes": 3_000_000_000, "seed_bytes": 1_000_000_000},
            {"node_id": "aaaaaaaaaaaaaaaa", "day": self.day(2), "relay_bytes": 2_000_000_000, "seed_bytes": 0},
            {"node_id": "aaaaaaaaaaaaaaaa", "day": self.day(45), "relay_bytes": 99_000_000_000},   # outside the window
            {"node_id": "bbbbbbbbbbbbbbbb", "day": self.day(1), "relay_bytes": 1_000_000_000, "seed_bytes": 0},
            {"node_id": "cccccccccccccccc", "day": self.day(1), "relay_bytes": 7_000_000_000},
            {"node_id": "dddddddddddddddd", "day": self.day(1), "relay_bytes": 50_000_000_000},
            {"node_id": "eeeeeeeeeeeeeeee", "day": self.day(1), "relay_bytes": 900_000_000_000},  # beyond its own cap
            {"node_id": "zzzzzzzzzzzzzzzz", "day": self.day(1), "relay_bytes": 1},                # unknown node
        ]
        return nodes, reports

    def test_aggregate(self):
        out = leaderboard.aggregate(*self.data(), now=self.NOW)
        rows = out["supporters"]
        self.assertEqual([r["name"] for r in rows], ["Ann the Relay", "Anonymous node", "Anonymous node"])
        ann, capped, bob = rows
        self.assertEqual(capped["relay_gb"], round(32 * 1024 * 86400 / 1e9, 1), "self-reports are capped by the node's caps")
        self.assertTrue(capped["anonymous"], "a name with 'staff' in it is not shown")
        self.assertEqual((ann["rank"], ann["relay_gb"], ann["seed_gb"], ann["uptime_pct"], ann["since"], ann["region"]),
                         (1, 5.0, 1.0, 100, "2026-09", "eu"))
        self.assertEqual(ann["badges"], ["node", "seeder"])
        self.assertTrue(bob["anonymous"])
        self.assertEqual(bob["badges"], ["pending"])
        net = out["network"]
        self.assertEqual(net["relay_gb"], round(5 + 1 + 7 + 32 * 1024 * 86400 / 1e9, 1), "opted-out nodes still count")
        self.assertEqual((net["nodes_verified"], net["nodes_pending"], net["supporters"]), (3, 1, 3))
        self.assertEqual(out["tiers"], tiers.TIERS)

    def test_no_identifying_data_leaves_aggregate(self):
        blob = json.dumps(leaderboard.aggregate(*self.data(), now=self.NOW))
        for secret in ("203.0.113.7", "ws://", "aaaaaaaaaaaaaaaa", "4242", "Hidden Carl", "Mallory", "Bob\""):
            self.assertNotIn(secret, blob)

    def test_names(self):
        self.assertEqual(leaderboard.clean_name("x"), "")
        self.assertEqual(leaderboard.clean_name("visit www.spam.com/now"), "")
        self.assertEqual(leaderboard.clean_name("Moderator Bob"), "")
        self.assertEqual(leaderboard.clean_name("Tidus\x00 of Lordaeron"), "Tidus of Lordaeron")

    def test_site_file_shape(self):
        with open(os.path.join(ROOT, "www", "community", "nodes.json"), encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["tiers"], tiers.TIERS, "www/community/nodes.json tiers come from p2p/tiers.py")
        for k in ("updated", "window_days", "network", "official", "supporters", "privacy"):
            self.assertIn(k, data)
        rows = leaderboard.parse(data)
        self.assertEqual(len(rows), len(data["supporters"]))
        junk = leaderboard.parse({"supporters": [None, {"rank": "x"}, {"name": "Ok Name", "badges": ["evil", "node"]}]})
        self.assertEqual([(r["name"], r["badges"]) for r in junk], [("Ok Name", ["node"])])


# ---------------------------------------------------------------- the opt-in state machine

class NodeMachineTests(unittest.TestCase):
    def test_happy_path_and_one_click_off(self):
        seen = []
        m = node.NodeMachine(on_change=lambda o, n, e: seen.append((o, n, e)))
        self.assertEqual(m.state, "off")
        self.assertFalse(m.enabled)
        for ev, st in (("enable", "consent"), ("accept", "starting"), ("started", "pending"), ("approved", "verified"),
                       ("cap_reached", "paused"), ("new_day", "verified"), ("turn_off", "stopping"), ("stopped", "off")):
            self.assertEqual(m.fire(ev), st, ev)
        self.assertEqual(seen[0], ("off", "consent", "enable"))

    def test_off_from_everywhere(self):
        for path, end in ((["enable"], "off"), (["enable", "accept"], "stopping"), (["enable", "accept", "failed"], "off"),
                          (["enable", "accept", "started"], "stopping"), (["enable", "accept", "started", "cap_reached"], "stopping")):
            m = node.NodeMachine()
            for ev in path:
                m.fire(ev)
            self.assertEqual(m.fire("turn_off"), end, path)
        self.assertEqual(node.NodeMachine().fire("turn_off"), "off")

    def test_invalid_events_and_pause_memory(self):
        m = node.NodeMachine()
        for ev in ("accept", "started", "approved", "new_day", "cap_reached"):
            with self.assertRaises(node.NodeError):
                m.fire(ev)
        m = node.NodeMachine()
        for ev in ("enable", "decline"):
            m.fire(ev)
        self.assertEqual(m.state, "off")
        for ev in ("resume", "started", "cap_reached"):
            m.fire(ev)
        self.assertEqual(m.fire("approved"), "paused")     # approved while paused: back to verified at midnight
        self.assertEqual(m.fire("new_day"), "verified")
        m.fire("suspended")
        self.assertEqual(m.state, "pending")
        self.assertTrue(m.enabled)


# ---------------------------------------------------------------- the relay node, with fakes

class NodeRig:
    """A RelayNode on 127.0.0.1, a host's RelayAgent (the real one) with a node ticket, fake realmd
    and an upper-casing world echo behind it."""

    def __init__(self, tc, vis="public", limits=None, require_e2e=True, invite_ok=lambda c: c == "ABCDEFGHJK"):
        self.taps = []
        self.cap_hits = []
        self.node_seed = os.urandom(32)
        self.node_id = node.node_id_for(ed25519.public_key(self.node_seed))
        self.node = node.RelayNode(self.node_id, F.keys(), bind=("127.0.0.1", 0), limits=limits or node.NodeLimits(),
                                   node_key=self.node_seed, tap=lambda d, m: self.taps.append(m),
                                   require_e2e=require_e2e, on_cap=lambda: self.cap_hits.append(1))
        self.port = self.node.start()
        tc.addCleanup(self.node.stop)
        self.url = f"ws://127.0.0.1:{self.port}"
        self.realmd = F.FakeRealmd()
        tc.addCleanup(self.realmd.close)
        self.world = EchoServer()
        tc.addCleanup(self.world.close)
        self.agent = host.RelayAgent(self.url, HOST_ID, ticket(self.node_id, vis=vis),
                                     {3724: self.realmd.port, 8085: self.world.port}, invite_ok,
                                     host_key=HOST_SEED, node_id=self.node_id)
        self.agent.start()
        tc.addCleanup(self.agent.stop)
        tc.assertTrue(wait_for(lambda: self.agent.connected), "agent connects with its node ticket")
        self.fp = e2e.fingerprint(HOST_PUB)


class RelayNodeTests(unittest.TestCase):
    def test_forwards_sealed_streams_and_sees_no_plaintext(self):
        rig = NodeRig(self)
        b = Bridge(HOST_ID, rig.url, e2e_fp=rig.fp)
        b.start()
        self.addCleanup(b.stop)
        reply, realms = realm_client(b.auth_port)
        self.assertEqual(reply, b"\x00\x00\x04")
        self.assertEqual(realms[0]["address"], f"127.0.0.1:{b.world_port}".encode())
        with socket.create_connection(("127.0.0.1", b.world_port), timeout=10) as c:
            c.settimeout(10)
            c.sendall(b"secret whisper to guildmate")
            self.assertEqual(realmproto.recv_exact(c, 27), b"SECRET WHISPER TO GUILDMATE")
        blob = b"".join(self.rig_taps(rig))
        self.assertGreater(len(blob), 0)
        for plain in (b"secret whisper", b"SECRET WHISPER", b"TESTER", b"Test Realm", b"203.0.113.9"):
            self.assertNotIn(plain, blob, "the node only ever sees ciphertext")
        st = rig.node.stats()
        self.assertGreater(st["bytes_total"], 0)
        self.assertEqual(st["streams_total"], 2)
        self.assertNotIn("127.0.0.1", json.dumps(st), "the node keeps no addresses")

    @staticmethod
    def rig_taps(rig):
        return [m for m in rig.taps if isinstance(m, bytes)]

    def test_plain_streams_are_refused(self):
        rig = NodeRig(self)
        with self.assertRaises(ws.WebSocketError) as cm:
            ws.connect(f"{rig.url}/h/{HOST_ID}/ws/3724")
        self.assertEqual(cm.exception.status, 400)
        with self.assertRaises(ws.WebSocketError) as cm:
            ws.connect(f"{rig.url}/h/bbbbbbbbbbbbbbbb/ws/3724?e2e=1")
        self.assertEqual(cm.exception.status, 404)
        with self.assertRaises(ws.WebSocketError) as cm:
            ws.connect(f"{rig.url}/h/{HOST_ID}/ws/22?e2e=1")
        self.assertEqual(cm.exception.status, 404)

    def test_tickets_are_checked(self):
        rig = NodeRig(self)
        for bad in (ticket("zzzzzzzzzzzzzzzz"), ticket(rig.node_id, host_id="bbbbbbbbbbbbbbbb"),
                    ticket(rig.node_id, exp_in=-3600), ticket(rig.node_id, typ="identity"),
                    paseto.sign(os.urandom(32), {"typ": "node", "aud": rig.node_id, "sub": HOST_ID,
                                                 "iat": int(time.time()), "exp": int(time.time()) + 60}, kid=F.KID)):
            with self.assertRaises(ws.WebSocketError) as cm:
                ws.connect(rig.url + "/agent", headers={"Authorization": "Bearer " + bad, "X-Host-Id": HOST_ID})
            self.assertEqual(cm.exception.status, 401)
        # a fresh ticket over the control socket keeps the agent on; the node accepts it
        rig.agent.update_ticket(ticket(rig.node_id, exp_in=900))
        time.sleep(0.2)
        self.assertTrue(rig.agent.connected)

    def test_private_hosts_need_an_invite(self):
        rig = NodeRig(self, vis="private")
        b = Bridge(HOST_ID, rig.url, e2e_fp=rig.fp)
        with self.assertRaises(ws.WebSocketError) as cm:
            b._connect(b.url(3724))
        self.assertEqual(cm.exception.status, 403)
        b.invite = "ZZZZZZZZZZ"
        with self.assertRaises(ws.WebSocketError) as cm:
            b._connect(b.url(3724))
        self.assertEqual(cm.exception.status, 403)
        b.invite = "ABCDEFGHJK"
        s = b._connect(b.url(3724))
        s.send(realmproto.logon_challenge("TESTER"))
        self.assertEqual(s.recv(), b"\x00\x00\x04")
        s.close()

    def test_daily_cap_pauses_the_node(self):
        rig = NodeRig(self, limits=node.NodeLimits(daily_gb=0.000001))   # 1000 bytes
        b = Bridge(HOST_ID, rig.url, e2e_fp=rig.fp)
        b.start()
        self.addCleanup(b.stop)
        with socket.create_connection(("127.0.0.1", b.world_port), timeout=10) as c:
            c.settimeout(10)
            c.sendall(b"x" * 2000)
            try:
                realmproto.recv_exact(c, 2000)
            except (OSError, ValueError, ConnectionError):
                pass
        self.assertTrue(wait_for(lambda: rig.cap_hits))
        self.assertTrue(rig.node.stats()["paused"])
        with self.assertRaises(ws.WebSocketError) as cm:
            e2e.connector(HOST_ID, rig.fp)(f"{rig.url}/h/{HOST_ID}/ws/8085")
        self.assertEqual(cm.exception.status, 429)

    def test_health_and_signed_info(self):
        rig = NodeRig(self)
        import urllib.request
        with urllib.request.urlopen(rig.url.replace("ws://", "http://") + "/healthz", timeout=5) as r:
            self.assertEqual(r.read(), b"ok")
        with urllib.request.urlopen(rig.url.replace("ws://", "http://") + "/node?c=00ff", timeout=5) as r:
            info = json.loads(r.read())
        self.assertEqual((info["node_id"], info["e2e_required"], info["protocol"]), (rig.node_id, True, 1))
        self.assertTrue(ed25519.verify(bytes.fromhex(info["key"]), node.info_message(rig.node_id, "00ff"),
                                       bytes.fromhex(info["sig"])))
        self.assertEqual(node.node_id_for(bytes.fromhex(info["key"])), rig.node_id, "the id is the key's fingerprint")


# ---------------------------------------------------------------- host on a node, player joins through it

class NodeHostHarness(HostHarness):
    def __init__(self, tc, node_rig, assign=True, **kw):
        self.rig, self.assign = node_rig, assign
        super().__init__(tc, node_network=True, **kw)

    def post(self, url, payload, headers):
        status, data = super().post(url, payload, headers)
        if self.assign:
            data = dict(data, relay={"url": self.rig.url, "node_id": self.rig.node_id,
                                     "ticket": ticket(self.rig.node_id)})
        return status, data


class HostOnNodeTests(unittest.TestCase):
    def node_only(self):
        """A RelayNode without the rig's own agent (the HostSession brings its own)."""
        rig = type("Rig", (), {})()
        rig.taps = []
        rig.node_id = node.node_id_for(ed25519.public_key(os.urandom(32)))
        rig.node = node.RelayNode(rig.node_id, F.keys(), bind=("127.0.0.1", 0), tap=lambda d, m: rig.taps.append(m))
        rig.url = f"ws://127.0.0.1:{rig.node.start()}"
        self.addCleanup(rig.node.stop)
        return rig

    def test_host_is_put_on_a_node_and_player_joins_sealed(self):
        rig = self.node_only()
        h = NodeHostHarness(self, rig)
        h.s.start()
        self.assertTrue(wait_for(lambda: h.s.agent and h.s.agent.connected))
        self.assertEqual(h.s.agent.node_id, rig.node_id)
        self.assertEqual(h.s.status()["relay_node"], rig.node_id)
        beat = h.beats[0][1]
        self.assertEqual((beat["key"], beat["e2e"], beat["nodes"]), (h.s.fingerprint(), True, True))
        self.assertNotIn("host", beat, "a relayed host never sends its address")
        self.assertEqual(h.relay.agents, {}, "nothing connected to Open Vanilla's relay")

        realm = directory.parse({"servers": [{"name": "Test Realm", "host": "relay.openvanilla.app", "relay": True,
                                              "host_id": HOST_ID, "relay_url": rig.url + "/h/" + HOST_ID,
                                              "key": h.s.fingerprint(), "e2e": True}]})[0]
        s = join.join(realm, lambda env, rl: None, token_provider=lambda aud: F.token(aud), relay_url=h.relay.url,
                      node_network=True)
        self.addCleanup(s.stop)
        self.assertEqual(s.bridge.relay_url, rig.url)
        self.assertEqual(s.bridge.e2e_fp, h.s.fingerprint())
        self.assertEqual(s.creds["user"], host.account_for("12345"))
        reply, realms = realm_client(s.bridge.auth_port)
        self.assertEqual(reply, b"\x00\x00\x04")
        with socket.create_connection(("127.0.0.1", s.bridge.world_port), timeout=10) as c:
            c.settimeout(10)
            c.sendall(b"meet me in goldshire")
            self.assertEqual(realmproto.recv_exact(c, 20), b"MEET ME IN GOLDSHIRE")
        blob = b"".join(m for m in rig.taps if isinstance(m, bytes))
        for plain in (b"v4.public", b"goldshire", b"GOLDSHIRE", s.creds["password"].encode(), s.creds["user"].encode()):
            self.assertNotIn(plain, blob, "token, game account and chat stay sealed from the node operator")

    def test_without_a_known_key_a_node_is_refused(self):
        rig = self.node_only()
        pins = F.fresh_pins(self)
        realm = directory.Realm(name="X", host="relay.openvanilla.app", relay=True, host_id=HOST_ID, relay_url=rig.url)
        with self.assertRaises(P2PError) as cm:
            join.pick_relay(realm, HOST_ID, "wss://relay.openvanilla.app", None, pins, True, lambda h: None)
        self.assertIn("fresh invite link", str(cm.exception))
        # nodes switched off in this launcher: Open Vanilla's relay, unsealed (unchanged behaviour)
        self.assertEqual(join.pick_relay(realm, HOST_ID, "wss://relay.openvanilla.app", None, pins, False, lambda h: None),
                         ("wss://relay.openvanilla.app", None))
        # a private invite: the route lookup names the node and the key; the link's k= wins
        r2 = directory.Realm(name="P", host="", relay=True, host_id=HOST_ID)
        route = lambda h: {"relay_url": rig.url, "key": "abcdefghijklmnop", "e2e": True}
        self.assertEqual(join.pick_relay(r2, HOST_ID, "wss://relay.openvanilla.app", None, pins, True, route),
                         (rig.url, "abcdefghijklmnop"))
        self.assertEqual(join.pick_relay(r2, HOST_ID, "wss://relay.openvanilla.app", "bbbbbbbbbbbbbbbb", pins, True, route),
                         (rig.url, "bbbbbbbbbbbbbbbb"))

    def test_unreachable_node_falls_back_to_openvanilla_relay(self):
        rig = self.node_only()
        h = NodeHostHarness(self, rig)
        h.s.start()
        self.assertTrue(wait_for(lambda: h.s.agent and h.s.agent.connected))
        h.s.agent.failures = 3               # as if the node vanished three reconnects in a row
        h.s._check_node_failover()
        self.assertIsNone(h.s.agent.node_id)
        self.assertTrue(wait_for(lambda: h.s.agent.connected and h.relay.agents), "back on Open Vanilla's relay")
        self.assertEqual(h.s.heartbeat_payload()["node_failed"], rig.node_id)
        h.s.apply_assignment({"url": rig.url, "node_id": rig.node_id, "ticket": ticket(rig.node_id)})
        self.assertIsNone(h.s.agent.node_id, "not put back on the node that failed")

    def test_assignment_off_without_the_network_flag(self):
        rig = self.node_only()
        h = NodeHostHarness(self, rig)
        h.s.cfg.node_network = False
        h.s.start()
        self.assertTrue(wait_for(lambda: h.s.agent and h.s.agent.connected))
        self.assertIsNone(h.s.agent.node_id)
        self.assertNotIn("key", h.beats[0][1])
        self.assertNotIn("e2e", h.beats[0][1])


# ---------------------------------------------------------------- the service the launcher drives

class FakeCentral:
    def __init__(self, status="pending"):
        self.calls, self.status = [], status

    def __call__(self, url, method="GET", payload=None, headers=None, timeout=10):
        self.calls.append((url, method, payload, dict(headers or {})))
        if headers and headers.get("Authorization") == "Bearer nodetoken":
            return 200, {"status": self.status, "checks": {"reachable": {"ok": True, "detail": "ok"}}}
        return 201, {"token": "nodetoken", "status": self.status}


class NodeServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="node-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.saves = []
        self.statuses = []
        self.cfg = {"port": 0}
        self.central = FakeCentral()

    def svc(self, **kw):
        s = node.NodeService(self.cfg, save=lambda: self.saves.append(dict(self.cfg)), http=self.central,
                             keys=F.keys(), state_dir=self.tmp, on_status=self.statuses.append, bind_host="127.0.0.1", **kw)
        self.addCleanup(s.turn_off)
        return s

    def test_off_by_default_and_consent_text(self):
        s = self.svc()
        self.assertFalse(self.cfg["enabled"])
        self.assertEqual(s.machine.state, "off")
        self.assertFalse(s.resume(), "nothing starts unless the volunteer turned it on")
        text = s.enable()
        self.assertEqual(s.machine.state, "consent")
        for phrase in ("Never Blizzard's game files", "end-to-end encrypted", "512 KB/s", "10 GB per day",
                       "can see your IP address", "never see each other's", "writes no logs", "One click",
                       "Behind carrier-grade NAT"):
            self.assertIn(phrase, text)
        s.decline()
        self.assertEqual(s.machine.state, "off")
        self.assertFalse(self.cfg["enabled"])

    def test_closed_test_round(self):
        s = self.svc(relay_enabled=False)
        with self.assertRaises(node.NodeError) as cm:
            s.enable()
        self.assertIn("test round", str(cm.exception))

    def test_needs_a_way_in(self):
        s = self.svc()
        s.enable()
        self.assertFalse(s.accept())
        self.assertEqual(s.machine.state, "error")
        self.assertIn("forwarded", s.status()["error"])
        s.turn_off()
        self.assertEqual(s.machine.state, "off")
        self.assertFalse(self.cfg["enabled"])

    def test_upnp_refusal_explains(self):
        class Mapper:
            def map(self, ports):
                return None, None
        self.cfg["upnp"] = True
        s = self.svc(mapper=Mapper())
        s.enable()
        self.assertFalse(s.accept())
        self.assertIn("didn't open", s.status()["error"])

    def test_on_verified_off_and_game_status(self):
        addons = os.path.join(self.tmp, "AddOns")
        os.makedirs(os.path.join(addons, "Node"))
        open(os.path.join(addons, "Node", "Node.toc"), "w").close()
        self.cfg.update(public_url="ws://203.0.113.5:3728", leaderboard="named", display_name="  Ann  ")
        s = self.svc()
        s.on_status = lambda st: node.write_game_status([addons, os.path.join(self.tmp, "missing")], st)
        s.enable()
        self.assertTrue(s.accept())
        self.assertEqual(s.machine.state, "pending")
        self.assertTrue(self.cfg["enabled"])
        self.assertEqual(self.cfg["consent"], node.CONSENT_VERSION)
        url, method, payload, headers = self.central.calls[0]
        self.assertTrue(url.endswith("/api/nodes/heartbeat"))
        self.assertEqual((payload["node_id"], payload["url"], payload["e2e_required"], payload["display_name"]),
                         (s.node_id, "ws://203.0.113.5:3728", True, "Ann"))
        self.assertEqual(payload["node_id"], node.node_id_for(bytes.fromhex(payload["key"])))
        lua = open(os.path.join(addons, "Node", "Status.lua")).read()
        self.assertIn('state = "pending"', lua)
        self.assertIn("on = true", lua)
        self.central.status = "verified"
        s.tick()
        self.assertEqual(self.central.calls[-1][3]["Authorization"], "Bearer nodetoken")
        self.assertEqual(s.machine.state, "verified")
        self.assertIn("verified = true", open(os.path.join(addons, "Node", "Status.lua")).read())
        port = s.server.port
        s.turn_off()
        self.assertEqual(s.machine.state, "off")
        self.assertFalse(self.cfg["enabled"])
        self.assertIsNone(s.server)
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
        self.assertIn('state = "off"', open(os.path.join(addons, "Node", "Status.lua")).read())

    def test_resume_needs_current_consent(self):
        self.cfg.update(enabled=True, consent=0, public_url="ws://203.0.113.5:3728")
        s = self.svc()
        self.assertFalse(s.resume())
        self.assertFalse(self.cfg["enabled"], "an older explanation: ask again")
        self.cfg.update(enabled=True, consent=node.CONSENT_VERSION)
        s2 = self.svc()
        self.assertTrue(s2.resume())
        self.assertEqual(s2.machine.state, "pending")

    def test_revoked_turns_the_node_off(self):
        self.cfg.update(public_url="ws://203.0.113.5:3728")
        self.central.status = "revoked"
        s = self.svc()
        s.enable()
        s.accept()
        self.assertTrue(wait_for(lambda: s.machine.state == "off"))
        self.assertIn("revoked", s.status()["error"])

    def test_leaderboard_off_sends_no_name(self):
        self.cfg.update(public_url="ws://203.0.113.5:3728", leaderboard="off", display_name="Ann")
        s = self.svc()
        self.assertEqual(s.heartbeat_payload()["display_name"], "")

    def test_game_status_lua_is_lua50(self):
        src = node.game_status_lua({"state": "paused", "on": True, "label": 'Paused "cap"\nreached',
                                    "relayed_today": 2_500_000_000, "daily_gb": 10, "kbps": 512}, now=1_792_000_000)
        self.assertIn('label = "Paused \\"cap\\" reached"', src)
        self.assertIn("relayed_today_mb = 2500", src)
        self.assertNotIn("#", src.split("\n", 2)[2])

    @unittest.skipUnless(shutil.which("lua5.1"), "needs lua5.1")
    def test_game_status_file_loads_in_the_sim_guard(self):
        import subprocess
        d = tempfile.mkdtemp(prefix="nodelua-")
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "Status.lua")
        with open(path, "w") as f:
            f.write(node.game_status_lua({"state": "verified", "on": True, "verified": True, "hosts_now": 2,
                                          "relayed_today": 12_000_000, "daily_gb": 10, "kbps": 512}, now=1_792_000_000))
        guard = os.path.join(ROOT, "devkit", "sim", "lua50_guard.lua")
        script = ('local g = dofile(arg[1]); local issues = g.scan_file(arg[2]); assert(#issues == 0, "5.1-only syntax"); '
                  'dofile(arg[2]); local s = OpenVanillaNode_Status; '
                  'print(s.state, s.source, tostring(s.verified), s.hosts, s.relayed_today_mb, s.updated)')
        out = subprocess.run(["lua5.1", "-e", script.replace("arg[1]", repr(guard)).replace("arg[2]", repr(path))],
                             capture_output=True, text=True, timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.split("\t"), ["verified", "launcher", "true", "2", "12", "2026-10-14 17:46 UTC\n"])



# ---------------------------------------------------------------- the real Rust relay (when built)

def _relay_bin():
    for p in (os.environ.get("OPENVANILLA_RELAY_BIN"), os.path.join(ROOT, "relay", "target", "debug", "openvanilla-relay"),
              os.path.join(ROOT, "relay", "target", "release", "openvanilla-relay")):
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


@unittest.skipUnless(_relay_bin(), "build relay/ first (cargo build) or set OPENVANILLA_RELAY_BIN")
class RustRelaySmokeTests(unittest.TestCase):
    """tools/relay_smoke.py (the maintainer's test-round check) against the real relay binary:
    the Python host agent and player bridge, sealed and plain, through relay/."""

    def test_smoke_tool_through_the_rust_relay(self):
        import subprocess
        import urllib.request
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        import relay_smoke
        host_id, token, line = relay_smoke.gen()
        d = tempfile.mkdtemp(prefix="relay-")
        self.addCleanup(shutil.rmtree, d, True)
        allow = os.path.join(d, "allow.txt")
        with open(allow, "w") as f:
            f.write("# test\n" + line + "\n")
        port = F.free_port()
        env = dict(os.environ, RELAY_BIND=f"127.0.0.1:{port}", RELAY_ALLOW_FILE=allow, RUST_LOG="warn")
        env.pop("RELAY_VERIFY_URL", None)
        proc = subprocess.Popen([_relay_bin()], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (proc.terminate(), proc.wait(10)))

        def up():
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as r:
                    return r.read() == b"ok"
            except OSError:
                return False
        self.assertTrue(wait_for(up, 15))
        lines = []
        self.assertTrue(relay_smoke.run(f"ws://127.0.0.1:{port}", host_id, token, sealed=True, out=lines.append))
        self.assertTrue(relay_smoke.run(f"ws://127.0.0.1:{port}", host_id, token, sealed=False, out=lines.append))
        self.assertTrue(any("end-to-end encrypted" in x for x in lines), lines)
        with self.assertRaises(RuntimeError) as cm:
            relay_smoke.run(f"ws://127.0.0.1:{port}", host_id, "0" * 64, timeout=3, out=lines.append)
        self.assertIn("allow.txt", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
