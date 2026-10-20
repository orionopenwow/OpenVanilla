"""Tests for gm_console.py: no database, world server or docker needed (sql, console and subprocess are mocked)."""
import json, os, re, sys, tempfile, threading, unittest, urllib.error, urllib.request
from unittest import mock

TMP = tempfile.mkdtemp()
os.environ["OVGM_TOKEN"] = "sekrit-token"
os.environ["OVGM_NOTES"] = os.path.join(TMP, "ovgm", "notes.sqlite")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hetzner"))
import gm_console as g  # noqa: E402

COLS = {("classiccharacters", "characters", c) for c in ("power1", "playerflags", "stored_honorable_kills", "honor_highest_rank")}
COLS |= {("classicrealmd", "account", "last_ip")}
COLS |= {("classiccharacters", "guild_member", c) for c in ("guid", "guildid")} | {("classiccharacters", "guild", c) for c in ("guildid", "name")}
COLS |= {("classiccharacters", "character_inventory", c) for c in ("guid", "bag", "slot", "item", "item_template")}
COLS |= {("classiccharacters", "item_instance", c) for c in ("guid", "count")}
COLS |= {("classicmangos", "item_template", c) for c in ("entry", "name", "quality", "containerslots")}
COLS |= {("classiccharacters", "openvanilla_bug_report", c) for c in ("id", "created", "name", "category", "text", "zone", "level",
                                                                       "class", "race", "map", "x", "y", "z", "context")}
COLS |= {("classiccharacters", "corpse", c) for c in ("player", "map", "position_x", "position_y", "time")}
COLS |= {("classiccharacters", "mail", c) for c in ("sender", "receiver", "money", "deliver_time", "messagetype")}

ROSTER = [
    # guid name lvl race class gender zone map x y z money played hp account gm muted xp | mana flags hks rank ip guild
    ["7", "Fenz", "3", "2", "1", "0", "14", "1", "-600.2", "-4250.1", "38.4", "57100", "18000", "61", "WR000007", "0", "0", "120",
     "0", "0", "4", "0", "81.2.69.160", "Order of Dawn"],
    ["8", "Pip", "12", "7", "4", "1", "1", "0", "-5600.0", "-480.0", "390.0", "1000", "7200", "0", "WR000008", "0", "300", "0",
     "0", "16", "0", "0", "81.2.69.160", "NULL"],
    ["9", "Borgrim", "41", "3", "2", "0", "3", "0", "-6680", "-2190", "240", "9999999", "250000", "1210", "WR000009", "3", "0", "0",
     "900", "0", "120", "3", "172.18.0.5", "NULL"],
]


def fake_sql(q):
    if "information_schema.columns" in q:
        return [list(c) for c in COLS]
    if "FROM characters c JOIN classicrealmd.account a ON a.id = c.account " in q and "c.online = 1 AND a.username NOT LIKE" in q:
        return [list(r) for r in ROSTER]
    if "ContainerSlots" in q:
        return [["7", "12"], ["8", "3"]]
    if q.startswith("SELECT (SELECT COUNT(*)"):
        return [["200", "1300", "640", "150"]]
    if "openvanilla_world_log" in q:
        return [["14:50", "Goldking", "cheap gold 1000g for 5$ www.g0ldz.com"], ["14:49", "Fenz", "anyone for RFC?"]]
    if "openvanilla_bug_report" in q:
        return [["41", "10-20 10:12", "Fenz", "quest", "Sarkoth drops nothing", "14", "3", "1", "2", "1", "-600.2", "-4250.1", "38.4", ""],
                ["40", "10-20 09:00", "Pip", "ui", "<b>bold</b>", "1", "12", "4", "7", "0", "NULL", "NULL", "NULL", ""]]
    if "FROM corpse" in q:
        return [["Pip", "0", "-5610", "-470", "10-20 14:00"]]
    if "game_tele" in q:
        return [["Stormwind"], ["Orgrimmar"], ["GMIsland"], ["ThunderBluff"], ["Northshire"]]
    if "game_event" in q:
        return [["1", "Midsummer Fire Festival"], ["2", "Winter Veil"]]
    if "SELECT a.username" in q and "WHERE c.name = 'Fenz'" in q:
        return [["WR000007", "81.2.69.160"]]
    if "SELECT a.username" in q and "WHERE c.name = 'Borgrim'" in q:
        return [["WR000009", "172.18.0.5"]]
    if "character_inventory ci" in q:
        return [["100", "0", "4", "6125", "1", "Brawler's Harness", "1"], ["101", "0", "19", "4496", "1", "Small Brown Pouch", "1"],
                ["102", "101", "0", "2589", "12", "Linen Cloth", "1"]]
    if "ORDER BY c.money DESC" in q:
        return [["Borgrim", "41", "2", "9999999", "WR000009", "1"]]
    if "FROM mail m" in q:
        return [["10-20 11:00", "Borgrim", "Fenz", "5000000"]]
    return []


class Base(unittest.TestCase):
    def setUp(self):
        self.cmds = []
        self.p_sql = mock.patch.object(g, "sql", side_effect=fake_sql)
        self.p_con = mock.patch.object(g, "console", side_effect=self.fake_console)
        self.p_sql.start(); self.p_con.start()
        g.SCHEMA.update(at=0, cols=set()); g.META.update(at=0, data=None)
        g.CPU_HIST.clear(); g.HP_SEEN.clear()

    def tearDown(self):
        mock.patch.stopall()

    def fake_console(self, c):
        self.cmds.append(c)
        if c == ".server info":
            return True, "Online players: 3 (max: 10) Queued players: 2 (max: 2)\nServer uptime: 1 Hour(s)"
        return True, "ok: " + c


def fake_run(args, **kw):
    out = ""
    if args[:2] == ["docker", "stats"]:
        out = "mangosd\t95.5%\t1GiB / 8GiB\t12.5%\t1MB / 2MB\nmariadb\t10.0%\t6GiB / 8GiB\t80.0%\t3kB / 4kB\nrealm\t1.0%\t100MiB / 8GiB\t1.2%\t5kB / 6kB\n"
    return mock.Mock(stdout=out, stderr="", returncode=0)


class GatherTests(Base):
    def test_gather_builds_state(self):
        with mock.patch.object(g.subprocess, "run", side_effect=fake_run):
            g.gather(); g.gather()
        s = g.STATE
        self.assertEqual([p["name"] for p in s["players"]], ["Fenz", "Pip", "Borgrim"])
        fenz, pip, borg = s["players"]
        self.assertEqual(fenz["race"], "Orc"); self.assertEqual(fenz["faction"], "Horde"); self.assertEqual(fenz["zone"], "Durotar")
        self.assertEqual(fenz["guild"], "Order of Dawn"); self.assertEqual(pip["guild"], "")
        self.assertEqual(fenz["gold"], 5.71); self.assertEqual(fenz["hks"], 4); self.assertEqual(fenz["bag_free"], 12)
        self.assertEqual(pip["state"], "ghost"); self.assertEqual(pip["muted_s"], 300); self.assertEqual(borg["state"], "alive")
        self.assertEqual(fenz["same_ip"], ["WR000008"]); self.assertEqual(pip["same_ip"], ["WR000007"])
        self.assertEqual(borg["same_ip"], [])            # a private (relay) address never counts
        self.assertEqual(s["totals"], {"online": 3, "bots": 200, "characters": 1300, "accounts": 640, "seen_24h": 150, "queued": 2})
        self.assertEqual(s["chat"][0]["flags"], ["gold selling / link"]); self.assertEqual(s["chat"][1]["flags"], [])
        b41, b40 = s["bugs"]
        self.assertEqual(b41["go"], ".go xyz -600.2 -4250.1 38.4 1"); self.assertEqual(b41["status"], "Open")
        self.assertEqual(b41["zone"], "Durotar"); self.assertEqual(b41["class"], "Warrior")
        self.assertNotIn("go", b40)                      # no coordinates, no teleport button
        self.assertEqual(s["corpses"][0]["name"], "Pip")
        mang = s["containers"][0]
        self.assertEqual(mang["status"], "BAD"); self.assertEqual(mang["hist"], [95.5, 95.5]); self.assertEqual(mang["net"], "1MB / 2MB")
        self.assertEqual(s["containers"][1]["status"], "WARNING"); self.assertEqual(s["containers"][2]["status"], "GOOD")
        json.dumps(s)

    def test_gather_without_optional_columns(self):
        def bare(q):
            if "information_schema" in q:
                return []
            if "c.online = 1 AND a.username NOT LIKE" in q:
                self.assertNotIn("last_ip", q); self.assertNotIn("guild_member", q)
                return [r[:18] for r in ROSTER]
            return fake_sql(q)
        with mock.patch.object(g, "sql", side_effect=bare), mock.patch.object(g.subprocess, "run", side_effect=fake_run):
            g.gather()
        self.assertEqual(len(g.STATE["players"]), 3)
        self.assertIsNone(g.STATE["players"][0]["hks"]); self.assertIsNone(g.STATE["players"][0]["bag_free"])

    def test_cpu_history_capped_at_60(self):
        with mock.patch.object(g.subprocess, "run", side_effect=fake_run):
            for _ in range(70):
                g.docker_stats()
        self.assertEqual(len(g.CPU_HIST["mangosd"]), 60)


class ActTests(Base):
    def test_name_is_validated(self):
        for bad in ("", "a", "Fenz; .server shutdown", "Fen z", "Fenz1", "x" * 13):
            ok, msg = g.act({"act": "kick", "name": bad})
            self.assertFalse(ok, bad)
        self.assertEqual(self.cmds, [])

    def test_simple_commands(self):
        self.assertTrue(g.act({"act": "kick", "name": "Fenz"})[0])
        g.act({"act": "mute", "name": "Fenz", "minutes": "999999"})
        g.act({"act": "mute", "name": "Fenz", "minutes": "abc"})
        g.act({"act": "reset_talents", "name": "Fenz"})
        g.act({"act": "repair", "name": "Fenz"})
        g.act({"act": "whisper", "name": "Fenz", "text": "hi |cffff0000there\n"})
        self.assertEqual(self.cmds, [".kick Fenz", ".mute Fenz 10080", ".mute Fenz 10", ".reset talents Fenz", ".repairitems Fenz",
                                     ".send message Fenz hi  cffff0000there"])

    def test_tele_only_to_known_places(self):
        self.assertFalse(g.act({"act": "tele", "name": "Fenz", "place": "Nowhere"})[0])
        self.assertFalse(g.act({"act": "tele", "name": "Fenz", "place": "Stormwind; .server shutdown"})[0])
        self.assertTrue(g.act({"act": "tele", "name": "Fenz", "place": "orgrimmar"})[0])
        self.assertEqual(self.cmds, [".tele name Fenz Orgrimmar"])

    def test_jail_is_teleport_and_mute(self):
        ok, msg = g.act({"act": "jail", "name": "Fenz", "minutes": "30"})
        self.assertTrue(ok)
        self.assertEqual(self.cmds, [".tele name Fenz GMIsland", ".mute Fenz 30"])

    def test_ban_needs_reason_and_valid_length(self):
        self.assertFalse(g.act({"act": "ban_account", "name": "Fenz", "duration": "7d", "reason": ""})[0])
        self.assertFalse(g.act({"act": "ban_account", "name": "Fenz", "duration": "7d", "reason": "  "})[0])
        self.assertFalse(g.act({"act": "ban_account", "name": "Fenz", "duration": "forever", "reason": "gold selling"})[0])
        self.assertEqual(self.cmds, [])
        ok, _ = g.act({"act": "ban_account", "name": "Fenz", "duration": "7d12h", "reason": "gold selling | spam"})
        self.assertTrue(ok)
        self.assertEqual(self.cmds, [".ban account WR000007 7d12h gold selling   spam"])

    def test_ip_ban(self):
        self.assertTrue(g.act({"act": "ban_ip", "name": "Fenz", "duration": "-1", "reason": "botting"})[0])
        self.assertEqual(self.cmds[-1], ".ban ip 81.2.69.160 -1 botting")
        ok, msg = g.act({"act": "ban_ip", "name": "Borgrim", "duration": "1d", "reason": "botting"})
        self.assertFalse(ok)                              # the relay's private address: refused
        self.assertIn("private", msg)

    def test_free_command_and_unknown(self):
        self.assertFalse(g.act({"act": "cmd", "text": "server shutdown"})[0])
        self.assertTrue(g.act({"act": "cmd", "text": ".server info"})[0])
        self.assertFalse(g.act({"act": "rm -rf"})[0])
        self.assertFalse(g.act(["not", "a", "dict"])[0])
        self.assertFalse(g.act({"act": "announce", "text": ""})[0])

    def test_maintenance_and_events_allowlisted(self):
        self.assertFalse(g.act({"act": "maint", "which": "server shutdown"})[0])
        self.assertTrue(g.act({"act": "maint", "which": "reload_config"})[0])
        self.assertFalse(g.act({"act": "event_start", "event": "99"})[0])     # not in game_event
        self.assertFalse(g.act({"act": "event_start", "event": "1; .x"})[0])
        self.assertTrue(g.act({"act": "event_start", "event": "2"})[0])
        self.assertTrue(g.act({"act": "event_stop", "event": "2"})[0])
        self.assertEqual(self.cmds, [".reload config", ".event start 2", ".event stop 2"])

    def test_restart_spawns_ov_gm(self):
        g.RESTART["proc"] = None
        with mock.patch.object(g.subprocess, "Popen") as po, mock.patch("builtins.open", mock.mock_open()):
            ok, _ = g.act({"act": "restart", "minutes": "99", "text": "patch day"})
        self.assertTrue(ok)
        self.assertEqual(po.call_args[0][0], ["bash", g.GM_SH, "restart", "30", "patch day"])
        g.RESTART["proc"] = None


class TicketTests(Base):
    def test_ticket_status_update(self):
        g.STATE["bugs"] = [{"id": 41, "status": "Open", "note": ""}]
        ok, msg = g.act({"act": "ticket", "id": "41", "status": "Investigating", "note": "repro'd in Durotar"})
        self.assertTrue(ok, msg)
        self.assertEqual(g.tickets_for([41])[41]["status"], "Investigating")
        self.assertEqual(g.tickets_for([41])[41]["note"], "repro'd in Durotar")
        self.assertEqual(g.STATE["bugs"][0]["status"], "Investigating")
        self.assertTrue(g.act({"act": "ticket", "id": 41, "status": "Resolved", "note": ""})[0])
        self.assertEqual(g.tickets_for([41])[41]["status"], "Resolved")
        self.assertTrue(os.path.exists(os.environ["OVGM_NOTES"]))

    def test_ticket_validation(self):
        self.assertFalse(g.act({"act": "ticket", "id": "41", "status": "Closed"})[0])
        self.assertFalse(g.act({"act": "ticket", "id": "x", "status": "Open"})[0])
        self.assertFalse(g.act({"act": "ticket", "id": "0", "status": "Open"})[0])


class DataTests(Base):
    def test_inventory(self):
        self.assertFalse(g.inventory("Bad Name")["ok"])
        inv = g.inventory("Fenz")
        self.assertTrue(inv["ok"])
        self.assertEqual([(i["where"], i["name"]) for i in inv["items"]],
                         [("Equipped", "Brawler's Harness"), ("Bags", "Small Brown Pouch"), ("Bags", "Linen Cloth")])
        self.assertEqual(inv["items"][2]["count"], 12); self.assertEqual(inv["items"][2]["detail"], "in bag 1, slot 1")

    def test_audit(self):
        a = g.audit()
        self.assertEqual(a["rich"][0]["gold"], 1000.0)
        self.assertEqual(a["mails"][0]["gold"], 500.0)

    def test_chat_flags(self):
        self.assertIn("gold selling / link", g.chat_flags("X", "WTS gold, visit www.cheap.com"))
        self.assertIn("GM impersonation", g.chat_flags("X", "I am a GM, give me your password"))
        self.assertIn("GM impersonation", g.chat_flags("GMhelper", "hello"))
        self.assertIn("slur", g.chat_flags("X", "you " + __import__("codecs").decode("snttbg", "rot13")))
        self.assertEqual(g.chat_flags("Fenz", "anyone up for Ragefire Chasm?"), [])
        self.assertEqual(g.chat_flags("Pip", "need a fag? no, I mean a cigarette"), ["slur"])  # deliberately strict

    def test_public_ip(self):
        self.assertFalse(g.public_ip("172.18.0.5")); self.assertFalse(g.public_ip("127.0.0.1")); self.assertFalse(g.public_ip(""))
        self.assertTrue(g.public_ip("8.8.8.8"))


class HttpTests(Base):
    @classmethod
    def setUpClass(cls):
        cls.srv = g.ThreadingHTTPServer(("127.0.0.1", 0), g.H)
        cls.port = cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def req(self, path, body=None):
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=json.dumps(body).encode() if body is not None else None,
                                   headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=5) as resp:
                return resp.status, resp.read().decode(), dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(), dict(e.headers)

    def test_token_required_everywhere(self):
        for path in ("/", "/api/state", "/api/meta", "/api/inventory?name=Fenz", "/api/audit", "/?t=wrong", "/api/state?t="):
            self.assertEqual(self.req(path)[0], 403, path)
        self.assertEqual(self.req("/api/act", {"act": "kick", "name": "Fenz"})[0], 403)
        self.assertEqual(self.req("/api/act?t=nope", {"act": "kick", "name": "Fenz"})[0], 403)
        self.assertEqual(self.cmds, [])

    def test_page_has_key_sections(self):
        code, body, headers = self.req("/?t=sekrit-token")
        self.assertEqual(code, 200)
        self.assertIn("default-src 'self'", headers["Content-Security-Policy"])
        for s in ("Open Vanilla &ndash; GM Console", "In the world now", "Player actions", "Where everyone is", "Everyone",
                  "Server status", "World chat", "Bug reports", "Restart with countdown", "Call it off", "Go to them",
                  "Bring them to me", "Send them there", "Revive", "Info", "Mute", "Unmute", "Kick", "Ban account", "Ban IP",
                  "Show inventory", "Reset talents", "Gold audit", "Reveal IPs", "Teleport to incident site", "feTurbulence",
                  "feDisplacementMap"):
            self.assertIn(s, body, s)
        self.assertNotRegex(body, r"__I_\w+__|__ICONS__")
        self.assertNotRegex(body, r'(?:src|href)\s*=\s*["\']?https?:')      # nothing fetched from elsewhere
        self.assertNotIn("innerHTML = c.", body); self.assertNotIn("innerHTML = p.", body)
        self.assertNotIn("Wenilla", body)

    def test_state_and_actions_over_http(self):
        g.STATE.update(players=[{"name": "<img src=x>"}])
        code, body, _ = self.req("/api/state?t=sekrit-token")
        self.assertEqual(code, 200); self.assertEqual(json.loads(body)["players"][0]["name"], "<img src=x>")
        code, body, _ = self.req("/api/act?t=sekrit-token", {"act": "kick", "name": "Fenz"})
        self.assertEqual(json.loads(body), {"ok": True, "result": "ok: .kick Fenz"})
        code, body, _ = self.req("/api/act?t=sekrit-token", {"act": "ban_account", "name": "Fenz", "duration": "1d"})
        self.assertFalse(json.loads(body)["ok"])
        code, body, _ = self.req("/api/meta?t=sekrit-token")
        m = json.loads(body); self.assertIn("GMIsland", m["quick"]); self.assertEqual(m["events"][0], [1, "Midsummer Fire Festival"])
        code, body, _ = self.req("/api/inventory?t=sekrit-token&name=Fenz")
        self.assertTrue(json.loads(body)["ok"])
        code, body, _ = self.req("/api/audit?t=sekrit-token")
        self.assertTrue(json.loads(body)["ok"])
        self.assertEqual(self.req("/nope?t=sekrit-token")[0], 404)


if __name__ == "__main__":
    unittest.main(verbosity=2)
