"""Herald's Boss Fights cards (bot/herald_bossfights.py): the live file -> first clears, records, the week's twist
and fastest, never a self-test or practice run, at most a few cards a round.

    python3 -m unittest tests.test_herald_bossfights -v
"""
import asyncio
import datetime as dt
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bot"))
import herald_bossfights as hb  # noqa: E402

# Wednesday 2026-10-21 12:00 UTC; its week started Monday 2026-10-19 00:00 UTC
WED = int(dt.datetime(2026, 10, 21, 12, 0, tzinfo=dt.timezone.utc).timestamp())
MON = int(dt.datetime(2026, 10, 19, 0, 0, tzinfo=dt.timezone.utc).timestamp())
SUN_EVENING = MON + 6 * 86400 + 20 * 3600 + 60


def member(name, bot=False, cls="Mage", role="dps"):
    return {"name": name, "class": cls, "role": role, "bot": bot}


def run(rid, **kw):
    r = {"id": rid, "raid": "onyxia", "tier": 1, "size": 10, "bots": 0, "mode": "", "kind": "people", "ranked": True,
         "t": WED - 600, "ms": 241000, "cleared": True, "wipes": 0, "deaths": 1, "first": False, "record": False, "feats": [],
         "members": [member("Arth", cls="Warrior", role="tank"), member("Bel", cls="Priest", role="healer"), member("Cyn")]}
    r.update(kw)
    return r


def doc(recent, week=None):
    return {"version": 2, "recent": sorted(recent, key=lambda r: -r["id"]),
            "week": week or {"start": MON, "twist": "", "name": "", "text": "", "fastest": []}}


class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.live = os.path.join(self.d.name, "bossfights_live.json")
        self.state = os.path.join(self.d.name, "state.json")
        self.t = WED

    def tearDown(self):
        self.d.cleanup()

    def write(self, d):
        with open(self.live, "w", encoding="utf-8") as f:
            json.dump(d, f)

    def recaps(self, **kw):
        return hb.Recaps(self.live, self.state, now=lambda: self.t, **kw)

    def run_round(self, r):
        posted = []
        for key, emb in r.plan(r.read()):
            if emb is not None:
                posted.append(emb)
            r.commit(key)
        return posted


class TestCards(Base):
    def test_first_clear_card(self):
        c = hb.card(run(12, first=True, feats=["under3", "bogus"]), "first")
        self.assertEqual(c["title"], "First clear: Onyxia's Lair, tier 1")
        self.assertIn("Arth's group", c["description"])
        self.assertTrue(c["url"].endswith("/bossfights-run.html?id=12"))
        f = {x["name"]: x["value"] for x in c["fields"]}
        self.assertEqual(f["Time"], "4:01")
        self.assertEqual(f["Deaths"], "1")
        self.assertEqual(f["Feats"], "Under 3 minutes")

    def test_record_with_bots_names_people_only(self):
        r = run(14, record=True, kind="bots", bots=9, members=[member("Puncc"), member("Tawzi", bot=True)])
        c = hb.card(r, "record")
        self.assertTrue(c["title"].startswith("New record"))
        self.assertIn("with bots board", c["description"])
        group = [x for x in c["fields"] if x["name"].startswith("Group")][0]
        self.assertEqual(group["name"], "Group + 9 bots")
        self.assertEqual(group["value"], "Puncc")

    def test_clock(self):
        self.assertEqual(hb.clock(0), "0:00")
        self.assertEqual(hb.clock(3_725_000), "1:02:05")

    def test_week_start(self):
        self.assertEqual(hb.week_start(WED), MON)
        self.assertEqual(hb.week_start(MON), MON)


class TestPlan(Base):
    def test_first_start_posts_nothing_old(self):
        self.write(doc([run(12, first=True), run(13, record=True)]))
        r = self.recaps()
        self.assertEqual(self.run_round(r), [])
        self.assertEqual(r.state["last_id"], 13)
        # a new run after that is posted
        self.write(doc([run(12, first=True), run(13), run(14, tier=2, first=True)]))
        posted = self.run_round(self.recaps())
        self.assertEqual([p["title"] for p in posted], ["First clear: Onyxia's Lair, tier 2"])

    def test_backfill(self):
        self.write(doc([run(12, first=True), run(13, record=True)]))
        posted = self.run_round(self.recaps(backfill=True))
        self.assertEqual(len(posted), 2)

    def test_never_test_practice_or_uncleared(self):
        self.write(doc([run(1)]))
        self.run_round(self.recaps())
        self.write(doc([run(1), run(2, test=1, first=True), run(3, mode="practice", ranked=False, first=True),
                        run(4, cleared=False, first=True), run(5, raid="nowhere", first=True), run(6)]))
        r = self.recaps()
        self.assertEqual(self.run_round(r), [])
        self.assertEqual(r.state["last_id"], 6)

    def test_first_not_also_record(self):
        self.write(doc([run(1)]))
        self.run_round(self.recaps())
        self.write(doc([run(1), run(2, first=True, record=True)]))
        posted = self.run_round(self.recaps())
        self.assertEqual(len(posted), 1)
        self.assertTrue(posted[0]["title"].startswith("First clear"))

    def test_rate_limit_spreads_not_drops(self):
        self.write(doc([run(1)]))
        self.run_round(self.recaps())
        self.write(doc([run(1)] + [run(i, tier=i - 1, first=True) for i in range(2, 7)]))
        first = self.run_round(self.recaps(max_per_tick=3))
        second = self.run_round(self.recaps(max_per_tick=3))
        third = self.run_round(self.recaps(max_per_tick=3))
        self.assertEqual((len(first), len(second), len(third)), (3, 2, 0))

    def test_failed_send_is_retried(self):
        self.write(doc([run(1)]))
        self.run_round(self.recaps())
        self.write(doc([run(1), run(2, first=True)]))
        r = self.recaps()
        plan = r.plan(r.read())        # not committed: the post failed
        self.assertEqual(len([e for _k, e in plan if e]), 1)
        self.assertEqual(len(self.run_round(self.recaps())), 1)

    def test_twist_once_a_week(self):
        week = {"start": MON, "twist": "bloodmoon", "name": "Blood Moon", "text": "More critical strikes, both ways.", "fastest": []}
        self.write(doc([run(1)], week))
        r = self.recaps()
        self.run_round(r)                                   # the bookmark round
        posted = self.run_round(self.recaps())
        self.assertEqual([p["title"] for p in posted], ["This week's twist: Blood Moon"])
        self.assertEqual(self.run_round(self.recaps()), [])

    def test_weekly_on_sunday_evening(self):
        fastest = [{"id": 12, "raid": "onyxia", "tier": 1, "kind": "people", "ms": 241000, "leader": "Arth"},
                   {"id": 14, "raid": "onyxia", "tier": 1, "kind": "bots", "ms": 301000, "leader": "Puncc"}]
        self.write(doc([run(1)], {"start": MON, "twist": "", "name": "", "text": "", "fastest": fastest}))
        self.run_round(self.recaps())
        self.assertEqual(self.run_round(self.recaps()), [])     # Wednesday: not yet
        self.t = SUN_EVENING
        posted = self.run_round(self.recaps())
        self.assertEqual(len(posted), 1)
        self.assertEqual(posted[0]["title"], "Fastest of the week")
        self.assertIn("Arth's group, 4:01", posted[0]["description"])
        self.assertIn("(with bots)", posted[0]["description"])
        self.assertEqual(self.run_round(self.recaps()), [])     # once

    def test_bad_file(self):
        with open(self.live, "w") as f:
            f.write("{not json")
        self.assertEqual(self.recaps().plan(self.recaps().read()), [])
        os.unlink(self.live)
        self.assertEqual(self.recaps().plan(self.recaps().read()), [])


class FakeChannel:
    def __init__(self):
        self.sent = []

    async def send(self, embed=None, allowed_mentions=None):
        self.sent.append(embed)


class FakeDiscord:
    class Embed:
        @staticmethod
        def from_dict(d):
            return d

    class AllowedMentions:
        @staticmethod
        def none():
            return None


class FakeBot:
    def __init__(self, ch):
        self.ch = ch

    def get_channel(self, _id):
        return self.ch


class TestInstall(Base):
    def test_tick_sends_and_dry_run_prints(self):
        self.write(doc([run(1)]))
        ch = FakeChannel()
        lp = hb.install(FakeBot(ch), FakeDiscord, channel_id=42, path=self.live, state_path=self.state, now=lambda: self.t, dry_run=False)
        asyncio.run(lp.tick())                     # bookmark
        self.write(doc([run(1), run(2, first=True)]))
        lp = hb.install(FakeBot(ch), FakeDiscord, channel_id=42, path=self.live, state_path=self.state, now=lambda: self.t, dry_run=False)
        orig = asyncio.sleep

        async def fast(_s):
            return None
        hb.asyncio.sleep = fast
        try:
            asyncio.run(lp.tick())
        finally:
            hb.asyncio.sleep = orig
        self.assertEqual(len(ch.sent), 1)
        self.assertTrue(ch.sent[0]["title"].startswith("First clear"))

    def test_cli_dry_run(self):
        self.write(doc([run(12, first=True), run(13, record=True), run(14)]))
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = hb.main(["--dry-run", self.live])
        self.assertEqual(rc, 0)
        self.assertIn("2 card(s) would be posted", buf.getvalue())

    def test_enabled(self):
        old = os.environ.pop("BOSSFIGHTS_CHANNEL_ID", None)
        try:
            self.assertFalse(hb.enabled())
            os.environ["BOSSFIGHTS_CHANNEL_ID"] = "123"
            self.assertTrue(hb.enabled())
        finally:
            os.environ.pop("BOSSFIGHTS_CHANNEL_ID", None)
            if old is not None:
                os.environ["BOSSFIGHTS_CHANNEL_ID"] = old


if __name__ == "__main__":
    unittest.main()
