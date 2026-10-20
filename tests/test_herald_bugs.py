"""bot/herald_bugs.py: bug reports from the game -> one #bug-reports forum post each."""
import asyncio
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bot"))
import herald_bugs as H  # noqa: E402


def row(**kw):
    r = dict(id=7, created=1792450000, name="Zeke", level=5, race=1, map=0, zone=12, area=9,
             x=-8913.2, y=-130.5, z=81.0, category="quest", text="McBride won't take it", context="Northshire Valley")
    r["class"] = 1
    r.update(kw)
    return r


class FakeRealm:
    def __init__(self, rows):
        self.rows, self.marked = list(rows), {}

    def new_reports(self, limit=10):
        return [r for r in self.rows if r["id"] not in self.marked][:limit]

    def mark(self, rid, discord_id):
        self.marked[rid] = discord_id


class Tag:
    def __init__(self, name):
        self.name = name


class HTTPException(Exception):
    pass


class FakeDiscord:
    HTTPException = HTTPException

    class AllowedMentions:
        @staticmethod
        def none():
            return "none"


class Forum:
    def __init__(self, name="💬│bug-reports", fail=False):
        self.name, self.fail, self.posts = name, fail, []
        self.available_tags = [Tag(n) for n in ("Fixed", "Quest", "Spell", "Addon", "Server", "Browser")]

    async def create_thread(self, name, content, applied_tags, allowed_mentions):
        if self.fail:
            raise HTTPException("503")
        self.posts.append((name, content, [t.name for t in applied_tags], allowed_mentions))

        class Made:
            pass
        m = Made()
        m.thread = Made()
        m.thread.id = 1000 + len(self.posts)
        return m


class FakeBot:
    def __init__(self, channel):
        class Guild:
            pass
        self.g = Guild()
        self.g.channels = [channel]

    def get_guild(self, gid):
        return self.g


class PostTests(unittest.TestCase):
    def test_post_text(self):
        title, body, tags = H.post_for(row())
        self.assertEqual(title, "Quest: McBride won't take it")
        self.assertIn("**Who** Zeke, level 5 Human Warrior", body)
        self.assertIn("(-8913.2, -130.5, 81.0)", body)
        self.assertIn("Northshire Valley", body)
        self.assertEqual(tags, ["Quest"])
        self.assertNotIn("account", body.lower(), "the account never goes to Discord")

    def test_mass_mentions_and_long_text(self):
        title, body, _ = H.post_for(row(text="@everyone " + "x" * 3000, category="nonsense"))
        self.assertNotIn("@everyone", body)
        self.assertTrue(title.startswith("Other: "))
        self.assertLessEqual(len(title), H.MAX_TITLE)
        self.assertLessEqual(len(body), H.MAX_BODY)

    def test_client_tag(self):
        self.assertEqual(H.post_for(row(context="x · client=web"))[2], ["Quest", "Browser"])


class DeskTests(unittest.TestCase):
    def run_tick(self, realm, forum):
        desk = H.install(FakeBot(forum), FakeDiscord, None, 1, realm=realm, poll=5)
        asyncio.run(desk.tick())

    def test_posts_each_report_once(self):
        realm, forum = FakeRealm([row(id=1), row(id=2, category="spell", text="Frostbolt misses")]), Forum()
        self.run_tick(realm, forum)
        self.assertEqual([p[0] for p in forum.posts], ["Quest: McBride won't take it", "Spell or ability: Frostbolt misses"])
        self.assertEqual(forum.posts[1][2], ["Spell"])
        self.assertEqual(forum.posts[0][3], "none", "no pings")
        self.assertEqual(realm.marked, {1: 1001, 2: 1002})
        self.run_tick(realm, forum)
        self.assertEqual(len(forum.posts), 2, "nothing posted twice")

    def test_discord_down_keeps_the_report(self):
        realm, forum = FakeRealm([row(id=1)]), Forum(fail=True)
        self.run_tick(realm, forum)
        self.assertEqual(realm.marked, {}, "left unposted, tried again next round")
        forum.fail = False
        self.run_tick(realm, forum)
        self.assertEqual(realm.marked, {1: 1001})

    def test_no_channel(self):
        realm = FakeRealm([row(id=1)])
        self.run_tick(realm, Forum(name="general"))
        self.assertEqual(realm.marked, {})


if __name__ == "__main__":
    unittest.main()
