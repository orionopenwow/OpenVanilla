"""Herald Autopilot: feature tests for the rules, the demo world, the realm link, the sim, the
learning loop (client and realm) and the autopilot API.

    python -m unittest tests.test_herald_autopilot -v

The realm API tests need aiohttp; they skip without it. The window itself is exercised by
tests/ui_autopilot_walkthrough.py under a real (virtual) display.
"""
import asyncio
import gzip
import io
import json
import os
import random
import sys
import tempfile
import unittest
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "autopilot"))
sys.path.insert(0, os.path.join(ROOT, "bot"))

import ap_core as core  # noqa: E402
import ap_learn  # noqa: E402
import ap_link  # noqa: E402
import ap_sim  # noqa: E402
import herald_autopilot_api as api  # noqa: E402

try:
    import aiohttp  # noqa: F401
    from aiohttp.test_utils import TestClient, TestServer
except ImportError:
    TestClient = None


def run_demo(rules_over, seconds=3600, seed=1, goal="level"):
    d = ap_link.DemoLink(seed=seed)
    rules = core.merged_rules("Hunter", 12, rules_over)
    d.start("Herald", core.plan("Hunter", goal, rules))
    s = core.Session(character="Herald", cls="Hunter", goal=goal, started=0)
    for _ in range(seconds):
        d.tick(1)
        evs, _st = d.poll()
        for e in evs:
            s.apply(e)
    s.ended = seconds
    return s, d, rules


# ------------------------------------------------------------------------------------- rules
class TestRules(unittest.TestCase):
    def test_class_defaults_only_rules_that_apply(self):
        war = core.defaults_for("Warrior", 20)
        self.assertNotIn("rest_mana", war)          # no mana
        self.assertIn("role", war)                  # can tank
        self.assertNotIn("role", core.defaults_for("Rogue", 20))
        self.assertEqual(core.defaults_for("Priest", 20)["role"], "heal")

    def test_learned_profile_tunes_defaults_and_player_wins(self):
        prof = {"classes": {"Hunter": {"10-19": {"rest_hp": {"value": 50, "sessions": 40}, "pull": {"value": "bogus"}}}}}
        self.assertEqual(core.defaults_for("Hunter", 12, prof)["rest_hp"], 50)
        self.assertEqual(core.defaults_for("Hunter", 12, prof)["pull"], "two")      # invalid learned value ignored
        self.assertEqual(core.defaults_for("Hunter", 25, prof)["rest_hp"], 35)      # other band untouched
        self.assertEqual(core.merged_rules("Hunter", 12, {"rest_hp": 25}, prof)["rest_hp"], 25)
        self.assertIn("40", core.learned_note("Hunter", 12, prof))

    def test_level_bands(self):
        self.assertEqual([core.level_band(x) for x in (1, 9, 10, 19, 59, 60, 99)],
                         ["1-9", "1-9", "10-19", "10-19", "50-59", "60", "60"])

    def test_plan_says_what_the_bot_ai_should_do(self):
        p = core.plan("Rogue", "level", core.merged_rules("Rogue", 10, {}))
        self.assertIn("+grind", p["noncombat"])
        self.assertEqual(p["combat"][0], "+dps")
        p = core.plan("Priest", "dungeon", core.merged_rules("Priest", 30, {}))
        self.assertEqual(p["combat"][0], "+heal")

    def test_every_rule_sentence_reads(self):
        for r in core.RULES:
            for v, label in r.options:
                self.assertEqual(r.value_of(label), v)
                self.assertNotIn("  ", r.sentence(v))

    def test_money_and_clock(self):
        self.assertEqual(core.money(45210), "4g 52s")
        self.assertEqual(core.money(312), "3s 12c")
        self.assertEqual(core.money(7), "7c")
        self.assertEqual(core.clock(3725), "1:02:05")
        self.assertEqual(core.clock(65), "1:05")

    def test_session_pause_does_not_count(self):
        s = core.Session(started=0)
        s.pause(now=100)
        s.resume(now=400)
        self.assertAlmostEqual(s.elapsed(now=1000), 700)


# ------------------------------------------------------------------------------------- demo world
class TestDemo(unittest.TestCase):
    def test_a_run_makes_progress(self):
        s, d, _ = run_demo({}, 1800)
        self.assertGreater(s.kills, 50)
        self.assertGreater(s.xp, 5000)
        self.assertGreater(s.loot_copper, 0)
        self.assertTrue(s.timeline)

    def test_reckless_rules_die_more(self):
        """The demo has to make rules matter, or the learning loop learns nothing."""
        safe = sum(run_demo({}, 3600, seed)[0].deaths for seed in range(3))
        reckless = sum(run_demo({"rest_hp": 20, "pull": "any"}, 3600, seed)[0].deaths for seed in range(3))
        self.assertGreater(reckless, safe * 2)

    def test_full_bags_go_to_the_vendor(self):
        s, d, _ = run_demo({"bags": "vendor", "keep": "quest"}, 5400, seed=4)
        self.assertTrue(any(kind == "vendor" for _, kind, _ in s.timeline))
        self.assertLessEqual(len(d.bags), d.bag_slots)

    def test_stop_when_bags_full(self):
        d = ap_link.DemoLink(seed=2)
        d.bag_slots = 2
        d.start("Herald", core.plan("Hunter", "level", core.merged_rules("Hunter", 12, {"bags": "stop"})))
        for _ in range(3000):
            d.tick(1)
            if not d.running:
                break
        self.assertFalse(d.running)

    def test_gather_goal_gathers(self):
        s, _, _ = run_demo({}, 1800, goal="gather")
        self.assertGreater(s.nodes, 5)

    def test_pause_freezes_the_world(self):
        d = ap_link.DemoLink(seed=3)
        d.start("Herald", core.plan("Hunter", "level", core.merged_rules("Hunter", 12, {})))
        d.pause()
        xp = d.xp
        for _ in range(600):
            d.tick(1)
        self.assertEqual(d.xp, xp)
        self.assertEqual(d.state()["status"], "paused")


# ------------------------------------------------------------------------------------- realm link
class FakeResp(io.BytesIO):
    def __init__(self, status, body, headers=None):
        super().__init__(json.dumps(body).encode() if not isinstance(body, bytes) else body)
        self.status = status
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class TestRealmLink(unittest.TestCase):
    def test_realm_info_and_bearer(self):
        seen = []

        def opener(req, timeout=0):
            seen.append(req)
            return FakeResp(200, {"name": "VR", "autoplay_allowed": True, "tag": "[Autopilot]"})
        link = ap_link.RealmLink("https://realm.example/", "tok", opener=opener)
        info = link.realm_info()
        self.assertTrue(info["autoplay_allowed"])
        self.assertEqual(seen[0].get_header("Authorization"), "Bearer tok")
        self.assertEqual(seen[0].full_url, "https://realm.example/api/autopilot/realm")

    def test_offline_realm_is_not_allowed(self):
        def opener(req, timeout=0):
            raise OSError("no route")
        info = ap_link.RealmLink("https://x.example", opener=opener).realm_info()
        self.assertFalse(info["autoplay_allowed"])
        self.assertFalse(info["reachable"])

    def test_start_refused_message(self):
        def opener(req, timeout=0):
            raise urllib.error.HTTPError(req.full_url, 409, "x", {}, io.BytesIO(b'{"message": "Log Herald in first."}'))
        ok, msg = ap_link.RealmLink("https://x.example", opener=opener).start("Herald", {})
        self.assertFalse(ok)
        self.assertIn("Log Herald in", msg)

    def test_poll_tracks_seq(self):
        def opener(req, timeout=0):
            return FakeResp(200, {"seq": 7, "events": [{"kind": "level", "text": "Level 13!", "t": 1}], "state": {"level": 13}})
        link = ap_link.RealmLink("https://x.example", opener=opener)
        evs, st = link.poll()
        self.assertEqual(link.seq, 7)
        self.assertEqual(evs[0].kind, "level")
        self.assertEqual(st["level"], 13)


# ------------------------------------------------------------------------------------- Herald Lite
class TestHeraldLiteLink(unittest.TestCase):
    def make(self, target="https://play.openvanilla.app", user="BOTHUNTER1", pw="pw", binary="heraldlite"):
        self.dir = tempfile.mkdtemp()
        self.calls = []
        fake = os.path.join(ROOT, "tests", "fixtures", "fake_heraldlite.py")

        def popen(args, **kw):
            self.calls.append((args, kw))
            return __import__("subprocess").Popen([sys.executable, fake] + args[1:], **kw)
        root = tempfile.mkdtemp()                       # a checkout with just a route in it
        os.makedirs(os.path.join(root, "tools", "autopilot", "out"))
        with open(os.path.join(root, "tools", "autopilot", "out", "route_elwynn.json"), "w") as f:
            f.write("{}")
        return ap_link.HeraldLiteLink(root, self.dir, target, user, pw, "Huntbot", binary=binary, popen=popen)

    def test_only_openvanilla_realms(self):
        for t, ok in (("https://play.openvanilla.app", True), ("127.0.0.1:3724", True), ("http://realm.test", True),
                      ("https://some-private-server.com", False), ("play.openvanilla.app.evil.com", False)):
            self.assertEqual(ap_link.hl_allowed(t), ok, t)
        link = self.make(target="https://other.example")
        self.assertFalse(link.realm_info()["autoplay_allowed"])
        ok, msg = link.start("Huntbot", {"rules": {}})
        self.assertFalse(ok)
        self.assertEqual(self.calls, [])

    def test_needs_binary_and_account(self):
        self.assertIn("cargo build", self.make(binary="").realm_info()["message"])
        self.assertIn("bot account", self.make(pw="").realm_info()["message"])

    def test_rules_become_tactics(self):
        t = ap_link.tactics_for("Hunter", {"rest_hp": 40, "rest_mana": 20, "pull": "one"}, {"rest": {"max_rest_s": 45}})
        self.assertEqual(t["rest"], {"max_rest_s": 45, "eat_below": 0.4, "drink_below": 0.2})
        self.assertEqual(t["pull"]["max_level_above"], 1)
        self.assertEqual(ap_link.tactics_for("Warrior", {"rest_hp": 50})["strategy"], "melee")

    def test_a_run(self):
        link = self.make()
        ok, _ = link.start("Huntbot", core.plan("Hunter", "level", core.merged_rules("Hunter", 2, {"stop": "30m"})))
        self.assertTrue(ok)
        args, kw = self.calls[0]
        self.assertNotIn("pw", args)                               # the password is never on the command line
        self.assertEqual(kw["env"]["HL_PASS"], "pw")
        self.assertEqual(args[args.index("--minutes") + 1], "30")
        self.assertEqual(args[args.index("--web") + 1], "https://play.openvanilla.app")
        link.proc.wait(10)
        events, state = link.poll()
        kinds = [e.kind for e in events]
        for k in ("kill", "xp", "loot", "quest", "level", "death", "state"):
            self.assertIn(k, kinds)
        s = core.Session(started=0)
        for e in events:
            s.apply(e)
        self.assertEqual((s.kills, s.xp, s.deaths, s.levels), (1, 165, 1, 1))
        self.assertEqual(s.loot_copper, 92)
        self.assertEqual(state["level"], 3)
        u, v = state["pos"]
        self.assertTrue(0 < u < 1 and 0 < v < 1)                   # Northshire is inside the Elwynn map
        self.assertFalse(link.running)
        self.assertEqual(link.last_step, 5)                        # START resumes here

    def test_own_server_on_this_pc(self):
        """Open Vanilla Server's HERALD button: the server on this PC, over loopback even though its realm
        list advertises the public address."""
        link = self.make(target="127.0.0.1")
        self.assertEqual(link.label, "Your server (this PC)")
        ok, _ = link.start("Huntbot", {"rules": {}})
        self.assertTrue(ok)
        args, _ = self.calls[0]
        self.assertEqual(args[args.index("--host") + 1], "127.0.0.1")
        self.assertEqual(args[args.index("--world") + 1], "127.0.0.1:8085")
        link.proc.wait(10)
        link.poll()

    def test_login_failure_is_explained(self):
        os.environ["FAKE_HL_EXIT"] = "2"
        try:
            link = self.make()
            link.start("Huntbot", {"rules": {}})
            link.proc.wait(10)
            events, _ = link.poll()
            self.assertTrue(any("Couldn't log in" in e.text for e in events))
        finally:
            os.environ.pop("FAKE_HL_EXIT")


# ------------------------------------------------------------------------------------- sim
class TestSim(unittest.TestCase):
    def test_every_class_sims(self):
        for cls in ap_sim.SIMMABLE:
            r = ap_sim.simulate(cls, ap_sim.PRESETS[cls], iterations=60)
            self.assertGreater(r.dps, 50, cls)
            self.assertLessEqual(r.low, r.dps)
            self.assertGreaterEqual(r.high, r.dps)

    def test_more_stats_more_damage(self):
        for cls in ("Warrior", "Rogue", "Hunter", "Mage", "Warlock"):
            w = ap_sim.stat_weights(cls, ap_sim.PRESETS[cls], iterations=200)
            for k, v in w.items():
                self.assertGreater(v, 0, f"{cls} {k}")

    def test_debuffs_help_physical_only(self):
        p = ap_sim.PRESETS["Warrior"]
        self.assertGreater(ap_sim.simulate("Warrior", p, 200, debuffs=True).dps, ap_sim.simulate("Warrior", p, 200, debuffs=False).dps)
        m = ap_sim.PRESETS["Mage"]
        self.assertAlmostEqual(ap_sim.simulate("Mage", m, 200, debuffs=True).dps, ap_sim.simulate("Mage", m, 200, debuffs=False).dps)

    def test_compare_sign(self):
        a = ap_sim.PRESETS["Rogue"]
        b = ap_sim.stats_from("Rogue", {"ap": "1300"})
        _, _, pct = ap_sim.compare("Rogue", a, b, iterations=200)
        self.assertGreater(pct, 0)

    def test_bad_input_falls_back(self):
        s = ap_sim.stats_from("Warrior", {"ap": "lots", "speed": "0", "weapon_min": "300", "weapon_max": "10"})
        self.assertEqual(s.ap, ap_sim.PRESETS["Warrior"].ap)
        self.assertEqual(s.speed, ap_sim.PRESETS["Warrior"].speed)
        self.assertEqual(s.weapon_max, 300)


# ------------------------------------------------------------------------------------- learning (client)
class Clock:
    def __init__(self, t=1_790_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


class TestLearner(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.clock = Clock()
        self.sent = []
        self.reply = 200

        def opener(req, timeout=0):
            if req.full_url.endswith("/learn"):
                self.sent.append(json.loads(gzip.decompress(req.data)))
                if self.reply != 200:
                    raise urllib.error.HTTPError(req.full_url, self.reply, "x", {}, io.BytesIO(b"{}"))
                return FakeResp(200, {"accepted": 1})
            return FakeResp(200, {"v": 1, "classes": {"Hunter": {"10-19": {"rest_hp": {"value": 50, "sessions": 9}}}}},
                            {"ETag": '"abc"'})
        self.L = ap_learn.Learner(self.dir, "https://realm.example", opener=opener, clock=self.clock)
        self.summary = {"minutes": 30, "xp_per_hour": 20000, "kills": 80, "deaths": 1, "rests": 10, "levels": 1}

    def test_nothing_without_consent(self):
        self.assertIsNone(self.L.consent)
        self.assertFalse(self.L.note_session("Hunter", 12, "level", self.summary, {}))
        self.assertEqual(self.L.pending(), 0)
        self.L.set_consent(False)
        self.assertFalse(self.L.note_change("Hunter", 12, "rest_hp", 35, 50))

    def test_records_are_anonymous(self):
        self.L.set_consent(True)
        self.L.note_session("Hunter", 12, "level", dict(self.summary, character="Herald", account="ORION"),
                            {"rest_hp": 35, "secret": "x"})
        self.L.note_death("Hunter", 12, "level", {"rest_hp": 35, "pull": "two", "adds": 1, "mob_level_diff": 2, "mob": "Prowler"})
        text = self.L.preview()
        for bad in ("Herald", "ORION", "secret", "Prowler"):
            self.assertNotIn(bad, text)
        self.assertIn('"band": "10-19"', text)

    def test_too_short_sessions_are_not_recorded(self):
        self.L.set_consent(True)
        self.assertFalse(self.L.note_session("Hunter", 12, "level", dict(self.summary, minutes=1), {}))

    def test_when_it_sends(self):
        self.L.set_consent(True)
        self.L.note_change("Hunter", 12, "rest_hp", 35, 50)
        self.assertFalse(self.L.due(running=True, session_ended=True))       # never mid-run
        self.L.touch()
        self.assertFalse(self.L.due(running=False))                           # not idle yet
        self.assertTrue(self.L.due(running=False, session_ended=True))        # a run just ended
        self.clock.t += ap_learn.IDLE_AFTER + 1
        self.assertTrue(self.L.due(running=False))                            # idle long enough
        ok, _ = self.L.upload()
        self.assertTrue(ok)
        self.assertEqual(self.L.pending(), 0)
        self.assertEqual(self.sent[0]["records"][0]["type"], "change")
        self.L.note_change("Hunter", 12, "rest_hp", 50, 40)
        self.assertFalse(self.L.due(running=False, session_ended=True))       # 30-minute gap
        self.clock.t += ap_learn.MIN_GAP
        self.assertTrue(self.L.due(running=False, session_ended=True))

    def test_backoff_and_refusal(self):
        self.L.set_consent(True)
        self.L.note_change("Hunter", 12, "rest_hp", 35, 50)
        self.reply = 503
        ok, _ = self.L.upload()
        self.assertFalse(ok)
        self.assertEqual(self.L.pending(), 1)                                 # kept for later
        self.assertFalse(self.L.due(running=False, session_ended=True))       # backing off
        self.clock.t += 301
        self.reply = 400
        ok, _ = self.L.upload()
        self.assertEqual(self.L.pending(), 0)                                 # the realm will never take it

    def test_batches_stay_small(self):
        self.L.set_consent(True)
        for i in range(ap_learn.MAX_RECORDS + 50):
            self.L.note_session("Hunter", 12, "level", dict(self.summary, kills=i), {"rest_hp": 35})
        self.assertEqual(self.L.pending(), ap_learn.MAX_RECORDS)
        gz, n, _ = self.L.batch()
        self.assertLessEqual(len(gz), ap_learn.MAX_BATCH_BYTES)
        self.assertGreater(n, 0)

    def test_turning_off_deletes_the_queue(self):
        self.L.set_consent(True)
        self.L.note_change("Hunter", 12, "pull", "one", "two")
        self.L.set_consent(False)
        self.assertEqual(self.L.pending(), 0)

    def test_install_id_rotates_monthly(self):
        a = self.L.install_id()
        self.assertEqual(a, self.L.install_id())
        self.clock.t += 32 * 86400
        self.assertNotEqual(a, self.L.install_id())

    def test_profiles_download(self):
        p = self.L.fetch_profiles()
        self.assertEqual(core.defaults_for("Hunter", 12, p)["rest_hp"], 50)
        self.assertEqual(self.L.profiles()["_etag"], '"abc"')


# ------------------------------------------------------------------------------------- learning (realm)
class TestRealmLearning(unittest.TestCase):
    def test_validation_drops_anything_personal(self):
        r = api.validate_record({"type": "session", "cls": "Hunter", "band": "10-19", "goal": "level", "minutes": 30,
                                 "xp_per_hour": 1, "kills": 1, "deaths": 0, "rests": 0, "levels": 0, "quests": 0, "nodes": 0,
                                 "name": "Herald", "rules": {"rest_hp": 35, "evil": "x", "pull": "everything"}})
        self.assertNotIn("name", r)
        self.assertEqual(r["rules"], {"rest_hp": 35})
        self.assertIsNone(api.validate_record({"type": "session", "cls": "Necromancer", "band": "10-19"}))
        self.assertIsNone(api.validate_record({"type": "change", "cls": "Hunter", "band": "10-19", "key": "rest_hp",
                                               "from": 35, "to": 999}))

    def test_parse_batch(self):
        body = {"v": 1, "install": "abcdef0123456789", "records": [
            {"type": "change", "cls": "Mage", "band": "20-29", "key": "pull", "from": "one", "to": "two"}]}
        install, recs = api.parse_batch(gzip.compress(json.dumps(body).encode()), True)
        self.assertEqual(install, "abcdef0123456789")
        self.assertEqual(len(recs), 1)
        with self.assertRaises(ValueError):
            api.parse_batch(json.dumps(dict(body, install="../../etc")).encode(), False)
        with self.assertRaises(ValueError):
            api.parse_batch(b"x" * (api.MAX_BODY + 1), False)

    def _sessions(self, value, xph, deaths, n):
        return [{"type": "session", "cls": "Hunter", "band": "10-19", "goal": "level", "minutes": 60, "xp_per_hour": xph,
                 "deaths": deaths, "kills": 0, "rests": 0, "levels": 0, "quests": 0, "nodes": 0,
                 "rules": {"rest_hp": value}} for _ in range(n)]

    def test_aggregate_picks_the_value_that_works(self):
        recs = self._sessions(20, 30000, 12, 10) + self._sessions(40, 26000, 1, 10)
        out = api.aggregate(recs)
        self.assertEqual(out["classes"]["Hunter"]["10-19"]["rest_hp"]["value"], 40)   # dying costs more than it gains

    def test_aggregate_needs_enough_sessions(self):
        recs = self._sessions(20, 30000, 0, 3) + self._sessions(40, 10000, 0, 10)
        self.assertNotIn("Hunter", api.aggregate(recs)["classes"])

    def test_near_ties_go_to_what_players_choose(self):
        recs = self._sessions(35, 20000, 0, 8) + self._sessions(40, 20200, 0, 8)
        recs += [{"type": "change", "cls": "Hunter", "band": "10-19", "key": "rest_hp", "from": 40, "to": 35,
                  "after_death": True}] * 3
        self.assertEqual(api.aggregate(recs)["classes"]["Hunter"]["10-19"]["rest_hp"]["value"], 35)

    def test_strategies_cannot_inject_commands(self):
        txt = api.strategies_text({"noncombat": ["+grind", "+quest; .server shutdown", "+loot"], "combat": ["+dps", "+pull one"]})
        self.assertEqual(txt, "+grind,+loot,+dps,+pull one")


class TestLoopEndToEnd(unittest.TestCase):
    def test_runs_teach_better_defaults(self):
        """Players run the demo with different rest rules; the realm learns which is better and
        Herald's default for that class and band changes to it."""
        records = []
        rng = random.Random(5)
        for i in range(24):
            rest = rng.choice([20, 50])
            s, _, rules = run_demo({"rest_hp": rest, "pull": "any"}, 2400, seed=100 + i)
            summ = s.summary(now=2400)
            records.append({"type": "session", "cls": "Hunter", "band": "10-19", "goal": "level",
                            **{k: summ[k] for k in ("minutes", "xp_per_hour", "kills", "deaths", "rests", "levels", "quests", "nodes")},
                            "rules": {k: rules[k] for k in ("rest_hp", "pull")}})
        clean = [api.validate_record(r) for r in records]
        profiles = api.aggregate([r for r in clean if r], min_sessions=4)
        learned = profiles["classes"]["Hunter"]["10-19"]["rest_hp"]["value"]
        self.assertIn(learned, (20, 50))
        self.assertEqual(core.defaults_for("Hunter", 12, profiles)["rest_hp"], learned)


# ------------------------------------------------------------------------------------- the realm API
class FakeRealm:
    def __init__(self):
        self.chars = {"ORION": [{"guid": 1, "name": "Herald", "cls": "Hunter", "level": 12, "zone_id": 12, "online": True,
                                 "money": 100, "xp": 50},
                                {"guid": 2, "name": "Alt", "cls": "Mage", "level": 5, "zone_id": 1, "online": False,
                                 "money": 0, "xp": 0}]}
        self.commands = []
        self.take = "autopilot: {name} - on"      # what ".wnl autopilot <name> on" answers (0015)
        self.detail = {"x": -9000.0, "y": -100.0, "map": 0, "zone_id": 12, "items": [(2589, 5)],
                       "names": {2589: ("Linen Cloth", 1)}, "quests": [(33, 3)], "titles": {33: "Wolves Across the Border"},
                       "done": 4}

    def characters(self, user):
        return [dict(c) for c in self.chars.get(user.upper(), [])]

    def details(self, guid):
        return dict(self.detail)

    def console(self, cmd):
        self.commands.append(cmd)
        if cmd.startswith(".wnl autopilot"):
            name = cmd.split()[2]
            return self.take.format(name=name) if cmd.endswith(" on") else f"autopilot: {name} - off"
        return "ok"


@unittest.skipIf(TestClient is None, "aiohttp not installed")
class TestApi(unittest.TestCase):
    def run_app(self, allowed, fn, setup=None):
        os.environ["AUTOPILOT_ALLOWED"] = "1" if allowed else "0"
        os.environ["AUTOPILOT_TAKE_WAIT"] = "0"
        realm = setup(FakeRealm()) if setup else FakeRealm()
        store = api.LearnStore(":memory:")
        app = api.make_app(realm, store, who=lambda tok: "ORION" if tok == "good" else None)

        async def go():
            async with TestClient(TestServer(app)) as c:
                await fn(c, realm)
        asyncio.run(go())

    def test_off_realm_refuses_start(self):
        async def fn(c, realm):
            r = await c.get("/api/autopilot/realm")
            self.assertFalse((await r.json())["autoplay_allowed"])
            r = await c.post("/api/autopilot/start", json={"character": "Herald"}, headers={"Authorization": "Bearer good"})
            self.assertEqual(r.status, 403)
            self.assertEqual(realm.commands, [])
        self.run_app(False, fn)

    def test_sign_in_needed(self):
        async def fn(c, realm):
            r = await c.get("/api/autopilot/characters", headers={"Authorization": "Bearer bad"})
            self.assertEqual(r.status, 401)
        self.run_app(True, fn)

    def test_start_poll_stop(self):
        H = {"Authorization": "Bearer good"}

        async def fn(c, realm):
            r = await c.get("/api/autopilot/characters", headers=H)
            self.assertEqual([x["name"] for x in (await r.json())["characters"]], ["Herald", "Alt"])
            r = await c.post("/api/autopilot/start", json={"character": "Alt", "plan": {}}, headers=H)
            self.assertEqual(r.status, 409)                         # offline character
            r = await c.post("/api/autopilot/start", json={"character": "Nope", "plan": {}}, headers=H)
            self.assertEqual(r.status, 404)                         # not on this account
            plan = core.plan("Hunter", "level", core.merged_rules("Hunter", 12, {}))
            r = await c.post("/api/autopilot/start", json={"character": "Herald", "plan": plan}, headers=H)
            self.assertEqual(r.status, 200, await r.text())
            self.assertEqual(realm.commands[-4], ".wnl autopilot Herald on")          # taken over from here
            self.assertTrue(realm.commands[-3].startswith(".rndbot cmd Herald nc +grind,+rpg"), realm.commands[-3])
            # then the fight and loot orders: no fleeing from two mobs, loot every kill
            self.assertEqual(realm.commands[-2:], [".rndbot cmd Herald co -flee,+potions",
                                                   ".rndbot cmd Herald nc +custom::herald"])
            self.assertIn("-rpg vendor", realm.commands[-3])                       # never sells or uses the AH
            self.assertIn("-pvp", realm.commands[-3])
            realm.chars["ORION"][0].update(level=13, xp=10, money=900)
            r = await c.get("/api/autopilot/poll?since=0", headers=H)
            body = await r.json()
            kinds = [e["kind"] for e in body["events"]]
            self.assertIn("level", kinds)
            self.assertIn("loot", kinds)
            self.assertEqual(body["state"]["level"], 13)
            r = await c.get(f"/api/autopilot/poll?since={body['seq']}", headers=H)
            self.assertEqual((await r.json())["events"], [])
            self.assertEqual(body["state"]["zone"], "Elwynn Forest")
            self.assertIsNotNone(body["state"]["pos"])
            self.assertEqual(body["state"]["bags"][0]["name"], "Linen Cloth")
            self.assertEqual(body["state"]["quests"][0]["title"], "Wolves Across the Border")
            realm.detail.update(quests=[(33, 1), (40, 3)], titles={33: "Wolves Across the Border", 40: "A Fishy Peril"}, done=5)
            r = await c.get(f"/api/autopilot/poll?since={body['seq']}", headers=H)
            texts = [e["text"] for e in (await r.json())["events"]]
            self.assertIn("Wolves Across the Border: objectives done.", texts)
            self.assertIn("Took the quest A Fishy Peril.", texts)
            self.assertIn("Turned in 1 quest.", texts)
            r = await c.post("/api/autopilot/stop", json={}, headers=H)
            self.assertEqual(r.status, 200)
            self.assertTrue(realm.commands[-2].startswith(".rndbot cmd Herald nc -grind"), realm.commands[-2])
            self.assertEqual(realm.commands[-1], ".wnl autopilot Herald off")       # back to the player
        self.run_app(True, fn)

    def test_selfbot_off_on_realm(self):
        H = {"Authorization": "Bearer good"}

        def setup(realm):
            realm.take = "autopilot: {name} - refused (Self-bot is disabled)"
            return realm

        async def fn(c, realm):
            r = await c.post("/api/autopilot/start", json={"character": "Herald", "plan": {}}, headers=H)
            self.assertEqual(r.status, 409)
            self.assertIn("switched off", (await r.json())["message"])
            self.assertFalse(any(x.startswith(".rndbot") for x in realm.commands))   # nothing else sent
        self.run_app(True, fn, setup)

    def test_older_world_server_needs_the_game_step(self):
        """A world server without 0015 answers .wnl autopilot with nothing: the old way still works."""
        H = {"Authorization": "Bearer good"}

        def setup(realm):
            realm.take = ""
            return realm

        async def fn(c, realm):
            r = await c.post("/api/autopilot/start", json={"character": "Herald", "plan": {}}, headers=H)
            self.assertEqual(r.status, 200, await r.text())
            self.assertTrue(realm.commands[-3].startswith(".rndbot cmd Herald nc +grind"))
            self.assertEqual(realm.commands[-1], ".rndbot cmd Herald nc +custom::herald")
        self.run_app(True, fn, setup)

    def test_learn_then_profiles(self):
        async def fn(c, realm):
            recs = [{"type": "session", "cls": "Hunter", "band": "10-19", "goal": "level", "minutes": 60,
                     "xp_per_hour": 20000 + 1000 * (v == 40), "deaths": 0, "kills": 1, "rests": 1, "levels": 0, "quests": 0,
                     "nodes": 0, "rules": {"rest_hp": v}} for v in (35, 40) for _ in range(6)]
            body = gzip.compress(json.dumps({"v": 1, "install": "0123456789abcdef", "records": recs}).encode())
            r = await c.post("/api/herald/learn", data=body, headers={"Content-Encoding": "gzip"})
            self.assertEqual(r.status, 200)
            self.assertGreater((await r.json())["accepted"], 0)
            r = await c.post("/api/herald/learn", data=body, headers={"Content-Encoding": "gzip"})
            self.assertEqual((await r.json())["accepted"], 0)          # a retried batch is stored once
            r = await c.post("/api/herald/learn", data=b"not json")
            self.assertEqual(r.status, 400)
            r = await c.get("/api/herald/profiles.json")
            prof = await r.json()
            self.assertEqual(prof["classes"]["Hunter"]["10-19"]["rest_hp"]["value"], 40)
            etag = r.headers["ETag"]
            r = await c.get("/api/herald/profiles.json", headers={"If-None-Match": etag})
            self.assertEqual(r.status, 304)
        self.run_app(True, fn)

    def test_learn_rate_limit(self):
        async def fn(c, realm):
            body = json.dumps({"v": 1, "install": "0123456789abcdef", "records": []}).encode()
            codes = []
            for _ in range(14):
                r = await c.post("/api/herald/learn", data=body)
                codes.append(r.status)
            self.assertIn(429, codes)
        self.run_app(True, fn)


if __name__ == "__main__":
    unittest.main()
