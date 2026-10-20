"""Herald's Discord <-> World bridge (bot/herald_bridge.py), both directions, with fakes for Discord, the
realm console (SOAP) and the characters database.

    python3 -m unittest tests.test_herald_bridge -v
"""
import asyncio
import os
import sqlite3
import sys
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bot"))
import herald_bridge as hb  # noqa: E402

NOW = 1_800_000_000.0


class Clock:
    def __init__(self, t=NOW):
        self.t = t

    def __call__(self):
        return self.t


def memdb():
    con = sqlite3.connect(":memory:", isolation_level=None, check_same_thread=False)
    return lambda: con


class FakeRealm:
    """openvanilla_world_log, the guild link tables and the console, in memory."""

    def __init__(self, rows=()):
        self.rows = list(rows)
        self.codes, self.links, self.commands, self.names = [], {}, [], {7: "Ashen Vanguard"}
        self.fail = None

    def add(self, name, text, cls=1, guid=None, guild=0):
        rid = (self.rows[-1]["id"] if self.rows else 0) + 1
        self.rows.append({"id": rid, "guid": guid if guid is not None else 100 + rid, "name": name, "class": cls,
                          "guild": guild, "text": text, "created": NOW})
        return rid

    def max_id(self):
        return self.rows[-1]["id"] if self.rows else 0

    def lines(self, after, limit=200):
        return [r for r in self.rows if r["id"] > after][:limit]

    def link_codes(self):
        return list(self.codes)

    def drop_code(self, code):
        self.codes = [c for c in self.codes if c["code"] != code]

    def bridges(self):
        return dict(self.links)

    def set_bridge(self, guild, channel, by):
        self.links[int(guild)] = int(channel)

    def unbridge(self, channel):
        self.links = {g: c for g, c in self.links.items() if c != channel}

    def guild_name(self, guild):
        return self.names.get(guild, "?")

    def console(self, cmd):
        if self.fail:
            raise self.fail
        self.commands.append(cmd)
        return "worldsay: 3 player(s)"


def bridge(realm=None, clock=None, **kw):
    return hb.Bridge(realm or FakeRealm(), memdb(), now=clock or Clock(), **kw)


# ----------------------------------------------------------------------------------------- text
class Text(unittest.TestCase):
    def test_game_line_format_and_escaping(self):
        line = hb.format_line({"name": "Thrall", "class": 7, "text": "LF2M *Deadmines* @everyone <@123> [x](http://a.b)"})
        self.assertTrue(line.startswith("**Thrall** (Shaman): LF2M "))
        self.assertIn("\\*Deadmines\\*", line)
        self.assertNotIn("@everyone", line)          # broken with a zero-width space
        self.assertNotIn("<@123>", line)
        self.assertIn("\\[x\\]", line)               # no masked links
        self.assertIn("http://a.b", line)            # web addresses stay readable (embeds are suppressed)

    def test_game_links_and_colours_become_plain_text(self):
        raw = "need |cffa335ee|Hitem:19019:0:0:0|h[Thunderfury]|h|r and |cffffff00|Hquest:7:10|h[Kobold Camp]|h|r a||b"
        self.assertEqual(hb.from_game_text(raw), "need [Thunderfury] and [Kobold Camp] a|b")
        self.assertEqual(hb.format_line({"name": "Ann", "class": 1, "text": raw}),
                         "**Ann** (Warrior): need \\[Thunderfury\\] and \\[Kobold Camp\\] a\\|b")

    def test_unknown_class_has_no_brackets(self):
        self.assertEqual(hb.format_line({"name": "Bob", "class": 0, "text": "hi"}), "**Bob**: hi")

    def test_split_at_2000_on_line_boundaries(self):
        lines = [("x" * 150) + str(i) for i in range(40)]
        msgs = hb.split_messages(lines)
        self.assertTrue(all(len(m) <= 2000 for m in msgs))
        self.assertEqual("\n".join(msgs).split("\n"), lines)
        self.assertGreater(len(msgs), 1)
        long = hb.split_messages(["y" * 4500])
        self.assertEqual([len(m) for m in long], [2000, 2000, 500])

    def test_discord_text_to_game(self):
        self.assertEqual(hb.to_game_text("**gg** ||boss|| `x` a|b 😂👍"), "gg [spoiler] x a/b :joy::thumbsup:")
        self.assertEqual(hb.to_game_text("", attachments=1), "[image]")
        self.assertEqual(hb.to_game_text("look", embeds=1, stickers=1), "look [image] [image]")
        self.assertEqual(hb.to_game_text("<:pepega:123> hi"), ":pepega: hi")
        self.assertEqual(hb.to_game_text("line1\nline2"), "line1 line2")
        long = hb.to_game_text("é" * 300)
        self.assertLessEqual(len(long.encode("utf-8")), 255)
        self.assertTrue(long.endswith("..."))

    def test_names_for_the_game(self):
        self.assertEqual(hb.game_name("Zoë the Great 🐉"), "Zoe_the_Great")
        self.assertEqual(hb.game_name("🐉", 1234), "User1234")
        self.assertEqual(len(hb.game_name("a" * 50)), 24)

    def test_rate_limiter(self):
        c = Clock()
        r = hb.RateLimiter(3, 3, c)
        self.assertTrue(r.allow(1))
        self.assertFalse(r.allow(1))
        self.assertTrue(r.allow(2))
        c.t += 3
        self.assertTrue(r.allow(1))
        c.t += 3
        self.assertTrue(r.allow(1))
        c.t += 3
        self.assertFalse(r.allow(1))                 # 3 a minute
        c.t += 60
        self.assertTrue(r.allow(1))


# ----------------------------------------------------------------------------------------- game -> Discord
class GameToDiscord(unittest.TestCase):
    def test_first_start_skips_the_backlog_then_tails(self):
        realm = FakeRealm()
        realm.add("Old", "before Herald started")
        b = bridge(realm)
        self.assertEqual(b.poll(), {})
        realm.add("Thrall", "hello", cls=7)
        realm.add("Jaina", "hi!", cls=8)
        out = b.poll()
        self.assertEqual(out, {"world": ["**Thrall** (Shaman): hello\n**Jaina** (Mage): hi!"]})
        self.assertEqual(b.poll(), {})

    def test_restart_carries_on_from_the_stored_id(self):
        realm, db = FakeRealm(), memdb()
        b = hb.Bridge(realm, db, now=Clock())
        b.poll()
        realm.add("A", "one")
        b2 = hb.Bridge(realm, db, now=Clock())      # Herald restarted
        self.assertEqual(b2.poll(), {"world": ["**A** (Warrior): one"]})

    def test_discord_lines_are_not_echoed_and_ignored_characters_are_skipped(self):
        realm = FakeRealm()
        b = bridge(realm)
        b.poll()
        realm.add("Fromdiscord", "relayed", guid=0, cls=0)
        realm.add("Goldbot", "CHEAP GOLD")
        realm.add("Ann", "ok")
        b.ignore("game", "goldbot", by="mod")
        self.assertEqual(b.poll(), {"world": ["**Ann** (Warrior): ok"]})

    def test_batches_split_under_2000(self):
        realm = FakeRealm()
        b = bridge(realm)
        b.poll()
        for i in range(30):
            realm.add(f"P{i}", "z" * 200)
        msgs = b.poll()["world"]
        self.assertGreater(len(msgs), 1)
        self.assertTrue(all(len(m) <= 2000 for m in msgs))
        self.assertEqual(sum(m.count("\n") + 1 for m in msgs), 30)

    def test_guild_lines_go_to_the_linked_channel_only(self):
        realm = FakeRealm()
        realm.links = {7: 555}
        b = bridge(realm)
        b.poll()
        realm.add("Officer", "raid at 8", guild=7)
        realm.add("Other", "secret", guild=9)       # not linked: never posted
        realm.add("Ann", "world line")
        self.assertEqual(b.poll(), {555: ["**Officer** (Warrior): raid at 8"], "world": ["**Ann** (Warrior): world line"]})


# ----------------------------------------------------------------------------------------- Discord -> game
class DiscordToGame(unittest.TestCase):
    def test_adventurers_and_staff_only(self):
        b = bridge()
        cmd, why = b.from_discord(1, "Cool Guy", {"Adventurer"}, False, False, "hello world")
        self.assertEqual(cmd, ".wnl worldsay Cool_Guy hello world")
        self.assertEqual(b.from_discord(2, "x", {"Recruit"}, False, False, "hi"), (None, "role"))
        self.assertEqual(b.from_discord(3, "Mod", set(), True, False, "hi")[0], ".wnl worldsay Mod hi")
        self.assertEqual(b.from_discord(4, "bot", {"Adventurer"}, False, True, "hi"), (None, "bot"))

    def test_per_user_rate_limit(self):
        c = Clock()
        b = bridge(clock=c, gap=3, per_min=12)
        self.assertIsNotNone(b.from_discord(1, "A", {"Adventurer"}, False, False, "one")[0])
        self.assertEqual(b.from_discord(1, "A", {"Adventurer"}, False, False, "two"), (None, "rate"))
        self.assertIsNotNone(b.from_discord(2, "B", {"Adventurer"}, False, False, "other user")[0])
        c.t += 3
        self.assertIsNotNone(b.from_discord(1, "A", {"Adventurer"}, False, False, "three")[0])

    def test_ignored_members_and_empty_messages(self):
        b = bridge()
        b.ignore("discord", 9, by="mod")
        self.assertEqual(b.from_discord(9, "Troll", {"Adventurer"}, False, False, "spam"), (None, "ignored"))
        self.assertEqual(b.from_discord(1, "A", {"Adventurer"}, False, False, "   "), (None, "empty"))
        self.assertTrue(b.unignore("discord", 9))
        self.assertIsNotNone(b.from_discord(9, "Troll", {"Adventurer"}, False, False, "sorry")[0])

    def test_attachments_and_length(self):
        b = bridge()
        cmd, _ = b.from_discord(1, "A", {"Adventurer"}, False, False, "", attachments=2)
        self.assertEqual(cmd, ".wnl worldsay A [image] [image]")
        cmd, _ = bridge().from_discord(1, "A", {"Adventurer"}, False, False, "w" * 600)
        self.assertLessEqual(len(cmd.split(" ", 3)[3].encode()), 255)

    def test_guild_channel_uses_guildsay(self):
        realm = FakeRealm()
        realm.links = {7: 555}
        b = bridge(realm)
        self.assertEqual(b.channel_guild(555), 7)
        self.assertIsNone(b.channel_guild(556))
        cmd, _ = b.from_discord(1, "Gm", {"Adventurer"}, False, False, "inv pls", guild=7)
        self.assertEqual(cmd, ".wnl guildsay 7 Gm inv pls")


class GuildLinks(unittest.TestCase):
    def test_code_typed_in_game_links_the_guild(self):
        c = Clock()
        realm = FakeRealm()
        b = bridge(realm, clock=c)
        code = b.start_link(555, 1, "Officer#1")
        self.assertRegex(code, r"^\d{6}$")
        realm.codes = [{"code": "000000", "guild": 9, "guid": 5, "name": "Mallory", "created": NOW}]   # no such code
        self.assertEqual(b.check_links(), [])
        self.assertEqual(realm.links, {})
        realm.codes.append({"code": code, "guild": 7, "guid": 6, "name": "Varian", "created": NOW})
        self.assertEqual(b.check_links(), [(7, 555, "Ashen Vanguard", "Varian")])
        self.assertEqual(realm.links, {7: 555})
        self.assertNotIn(code, [x["code"] for x in realm.codes])
        self.assertEqual(b.channel_guild(555), 7)

    def test_codes_expire(self):
        c = Clock()
        realm = FakeRealm()
        b = bridge(realm, clock=c)
        code = b.start_link(555, 1, "Officer#1")
        c.t += hb.LINK_TTL + 1
        realm.codes = [{"code": code, "guild": 7, "guid": 6, "name": "Varian", "created": c.t}]
        self.assertEqual(b.check_links(), [])
        self.assertEqual(realm.links, {})


class Moderation(unittest.TestCase):
    """The moderation desk's mutes (herald_mod.py's mod_cases in the same database) and Discord timeouts."""

    def desk(self, b, *rows):
        con = b.db()
        con.execute("CREATE TABLE IF NOT EXISTS mod_cases (id INTEGER PRIMARY KEY AUTOINCREMENT, target TEXT, "
                    "action TEXT, acted REAL, auto_action TEXT, auto_at REAL, auto_undone REAL)")
        for r in rows:
            con.execute("INSERT INTO mod_cases(target, action, acted, auto_action, auto_at, auto_undone) VALUES(?,?,?,?,?,?)", r)
        con.commit()

    def test_no_desk_means_nobody_is_muted(self):
        self.assertEqual(bridge().muted_names(), set())

    def test_active_mutes_run_out_or_are_undone(self):
        c = Clock()
        b = bridge(clock=c)
        self.desk(b, ("Spammer", "mute1h", NOW - 60, None, None, None),
                  ("Shouty", "mute24h", NOW - 7200, None, None, None),
                  ("Oldnews", "mute1h", NOW - 4000, None, None, None),          # ran out
                  ("Goldbot", None, None, "mute10", NOW - 30, None),
                  ("Forgiven", None, None, "mute10", NOW - 30, NOW - 10),        # a moderator undid it
                  ("Warned", "warn", NOW - 10, None, None, None))
        self.assertEqual(b.muted_names(), {"spammer", "shouty", "goldbot"})
        c.t += 601
        self.assertNotIn("goldbot", b.muted_names())

    def test_muted_characters_are_not_posted(self):
        realm = FakeRealm()
        b = bridge(realm)
        self.desk(b, ("Spammer", "mute1h", NOW - 60, None, None, None))
        b.poll()
        realm.add("Spammer", "buy gold")
        realm.add("Ann", "ok")
        self.assertEqual(b.poll(), {"world": ["**Ann** (Warrior): ok"]})

    def test_muted_names_and_timeouts_are_not_relayed_to_the_game(self):
        b = bridge()
        self.desk(b, ("Spammer", "mute24h", NOW - 60, None, None, None))
        self.assertEqual(b.from_discord(1, "spammer", {"Adventurer"}, False, False, "hi"), (None, "muted"))
        self.assertEqual(b.from_discord(2, "Ann", {"Adventurer"}, False, False, "hi", timed_out=True), (None, "muted"))
        self.assertEqual(b.from_discord(3, "Ann", {"Adventurer"}, False, False, "hi")[0], ".wnl worldsay Ann hi")

    def test_the_old_player_role_still_counts(self):
        self.assertEqual(bridge().from_discord(1, "Old", {"Player"}, False, False, "hi")[0], ".wnl worldsay Old hi")
        self.assertEqual(bridge(role="Raider").from_discord(1, "Old", {"Player"}, False, False, "hi"), (None, "role"))


# ----------------------------------------------------------------------------------------- the Discord glue
def fake_discord():
    d = types.ModuleType("discord")

    class HTTPException(Exception):
        pass

    class Group:
        def __init__(self, name, description=""):
            self.name, self.commands = name, {}

        def command(self, name, description=""):
            def deco(fn):
                self.commands[name] = fn
                return fn
            return deco

    d.HTTPException = HTTPException
    d.AllowedMentions = types.SimpleNamespace(none=lambda: "NONE")
    d.Member = object
    d.TextChannel = object
    d.app_commands = types.SimpleNamespace(Group=Group)
    return d


class FakeChannel:
    def __init__(self, name, cid):
        self.name, self.id, self.sent = name, cid, []
        self.mention = f"<#{cid}>"

    async def send(self, content=None, allowed_mentions=None, suppress_embeds=False):
        self.sent.append((content, allowed_mentions, suppress_embeds))


class FakeTree:
    def __init__(self):
        self.groups = {}

    def add_command(self, g):
        self.groups[g.name] = g


class FakeBot:
    """A discord.Client: no add_listener, so the bridge chains on_message."""

    def __init__(self, channels):
        self.channels = {c.id: c for c in channels}
        self.guild = types.SimpleNamespace(id=42, text_channels=channels)
        self.tree = FakeTree()
        self.seen = []

        async def on_message(m):          # what another module had set
            self.seen.append(m)
        self.on_message = on_message

    def get_guild(self, gid):
        return self.guild if gid == 42 else None

    def get_channel(self, cid):
        return self.channels.get(cid)


def member(uid, name, roles=("Adventurer",), bot=False):
    return types.SimpleNamespace(id=uid, display_name=name, name=name, bot=bot,
                                 roles=[types.SimpleNamespace(name=r) for r in roles])


def message(bot, channel, author, content, attachments=()):
    reactions = []

    async def add_reaction(e):
        reactions.append(e)
    m = types.SimpleNamespace(guild=bot.guild, channel=channel, author=author, content=content, attachments=list(attachments),
                              embeds=[], stickers=[], webhook_id=None, add_reaction=add_reaction)
    m.reactions = reactions
    return m


class Glue(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        sys.modules["discord"] = fake_discord()
        self.world = FakeChannel("🌍│world", 10)
        self.guildch = FakeChannel("guild-ashen", 555)
        self.other = FakeChannel("general", 11)
        self.bot = FakeBot([self.world, self.guildch, self.other])
        self.realm = FakeRealm()
        self.realm.links = {7: 555}
        self.clock = Clock()
        chan = lambda g, suffix: next((c for c in g.text_channels if c.name.split("│")[-1] == suffix), None)  # noqa: E731
        is_staff = lambda m: any(r.name == "Moderator" for r in m.roles)  # noqa: E731
        self.relay = hb.install(self.bot, sys.modules["discord"], memdb(), chan, is_staff, 42, realm=self.realm,
                                now=self.clock, poll=2)

    async def asyncTearDown(self):
        sys.modules.pop("discord", None)

    async def test_game_lines_posted_without_mentions_or_embeds(self):
        await self.relay.tick()                      # first tick: start at the end of the log
        self.realm.add("Thrall", "for the Horde @everyone", cls=7)
        self.realm.add("Varian", "guild only", guild=7)
        await self.relay.tick()
        self.assertEqual(len(self.world.sent), 1)
        text, mentions, suppress = self.world.sent[0]
        self.assertTrue(text.startswith("**Thrall** (Shaman): for the Horde @"))
        self.assertEqual(mentions, "NONE")
        self.assertTrue(suppress)
        self.assertEqual(self.guildch.sent[0][0], "**Varian** (Warrior): guild only")

    async def test_discord_messages_reach_the_game(self):
        await self.bot.on_message(message(self.bot, self.world, member(1, "Anna B"), "hi all 👋"))
        self.assertEqual(self.realm.commands, [".wnl worldsay Anna_B hi all :wave:"])
        self.assertEqual(len(self.bot.seen), 1)     # the handler that was there before still runs
        await self.bot.on_message(message(self.bot, self.other, member(1, "Anna B"), "elsewhere"))
        await self.bot.on_message(message(self.bot, self.world, member(2, "Bot", bot=True), "beep"))
        await self.bot.on_message(message(self.bot, self.world, member(3, "New", roles=("Recruit",)), "hi"))
        self.assertEqual(len(self.realm.commands), 1)
        self.clock.t += 5
        await self.bot.on_message(message(self.bot, self.guildch, member(1, "Anna B"), "inv"))
        self.assertEqual(self.realm.commands[-1], ".wnl guildsay 7 Anna_B inv")

    async def test_timed_out_members_are_not_relayed(self):
        m = member(1, "A")
        m.is_timed_out = lambda: True
        await self.bot.on_message(message(self.bot, self.world, m, "hello"))
        self.assertEqual(self.realm.commands, [])

    async def test_rate_limited_messages_get_a_reaction(self):
        await self.bot.on_message(message(self.bot, self.world, member(1, "A"), "one"))
        m = message(self.bot, self.world, member(1, "A"), "two")
        await self.bot.on_message(m)
        self.assertEqual(len(self.realm.commands), 1)
        self.assertEqual(m.reactions, ["⏳"])

    async def test_console_failure_is_marked(self):
        self.realm.fail = RuntimeError("SOAP down")
        m = message(self.bot, self.world, member(1, "A"), "hello")
        await self.bot.on_message(m)
        self.assertEqual(m.reactions, ["⚠"])

    async def test_slash_commands_registered(self):
        self.assertEqual(set(self.bot.tree.groups), {"bridge", "guild"})
        self.assertEqual(set(self.bot.tree.groups["guild"].commands), {"discord", "unlink"})
        self.assertEqual(set(self.bot.tree.groups["bridge"].commands), {"ignore", "unignore", "status"})

    async def test_guild_link_command_and_confirmation(self):
        said = []

        class Resp:
            async def send_message(self, text, ephemeral=False):
                said.append(text)

        perms = types.SimpleNamespace(manage_messages=True)
        self.guildch.permissions_for = lambda m: perms
        officer = member(5, "Officer")
        inter = types.SimpleNamespace(user=officer, response=Resp())
        self.realm.links = {}
        self.relay.bridge.refresh_guilds(force=True)
        await self.bot.tree.groups["guild"].commands["discord"](inter, self.guildch)
        code = said[0].split("/guildlink ")[1][:6]
        self.realm.codes = [{"code": code, "guild": 7, "guid": 6, "name": "Varian", "created": NOW}]
        await self.relay.tick()
        self.assertEqual(self.realm.links, {7: 555})
        self.assertIn("Ashen Vanguard", self.guildch.sent[-1][0])
        perms.manage_messages = False
        await self.bot.tree.groups["guild"].commands["discord"](inter, self.guildch)
        self.assertIn("Manage Messages", said[-1])
        await self.bot.tree.groups["guild"].commands["discord"](inter, self.world)
        self.assertIn("World channel", said[-1])


class ListenerBot(FakeBot):
    """A commands.Bot: listeners are added, never replaced, so herald_mod's DM appeals keep working."""

    def __init__(self, channels):
        super().__init__(channels)
        del self.on_message
        self.listeners = {}

    def add_listener(self, fn, name):
        self.listeners.setdefault(name, []).append(fn)

    async def dispatch(self, name, *args):
        for fn in self.listeners.get(name, []):
            await fn(*args)


class Listeners(unittest.IsolatedAsyncioTestCase):
    async def test_bridge_and_moderation_desk_listen_side_by_side(self):
        sys.modules["discord"] = fake_discord()
        try:
            world = FakeChannel("world", 10)
            bot = ListenerBot([world])
            appeals = []

            async def mod_on_message(m):              # what herald_mod.install adds (DM appeals)
                if m.guild is None:
                    appeals.append(m.content)
            bot.add_listener(mod_on_message, "on_message")
            realm = FakeRealm()
            chan = lambda g, suffix: next((c for c in g.text_channels if c.name.split("│")[-1] == suffix), None)  # noqa: E731
            hb.install(bot, sys.modules["discord"], memdb(), chan, lambda m: False, 42, realm=realm, now=Clock(), poll=2)
            self.assertFalse(hasattr(bot, "on_message"), "the bridge must not replace on_message on a commands.Bot")
            self.assertEqual(len(bot.listeners["on_message"]), 2)
            await bot.dispatch("on_message", message(bot, world, member(1, "Ann"), "hi"))
            dm = message(bot, world, member(1, "Ann"), "appeal Ann sorry")
            dm.guild = None
            await bot.dispatch("on_message", dm)
            self.assertEqual(realm.commands, [".wnl worldsay Ann hi"])
            self.assertEqual(appeals, ["appeal Ann sorry"])
        finally:
            sys.modules.pop("discord", None)


class RealmSql(unittest.TestCase):
    """BridgeRealm's SQL against a fake connection (the statements and parameters it sends)."""

    def test_queries(self):
        sent = []

        class Cur:
            def execute(self, sql, args=()):
                sent.append((sql, args))
                self.sql = sql

            def fetchall(self):
                if "MAX(id)" in self.sql:
                    return [(12,)]
                if "FROM openvanilla_world_log" in self.sql:
                    return [(13, 5, "Thrall", 7, 0, "hi", NOW)]
                if "openvanilla_guild_bridge" in self.sql:
                    return [(7, 555)]
                return []

        class Con:
            def cursor(self):
                return Cur()

            def commit(self):
                pass

            def close(self):
                pass

        base = types.SimpleNamespace(connect=lambda: Con(), console=lambda cmd: "ok:" + cmd)
        r = hb.BridgeRealm(base)
        self.assertEqual(r.max_id(), 12)
        self.assertEqual(r.lines(12), [{"id": 13, "guid": 5, "name": "Thrall", "class": 7, "guild": 0, "text": "hi", "created": NOW}])
        self.assertEqual(r.bridges(), {7: 555})
        r.set_bridge(7, 555, "x")
        r.unbridge(555)
        self.assertEqual(r.console(".wnl worldsay A b"), "ok:.wnl worldsay A b")
        self.assertTrue(any("%s" in s for s, _ in sent))   # parameters, never string-built SQL


if __name__ == "__main__":
    unittest.main()
