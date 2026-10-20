"""Herald's Discord <-> in-game "World" channel bridge (docs/DISCORD_BRIDGE.md).

Game -> Discord. The world server (patch realm/mangos/0007-openvanilla-world-channel.patch) appends
every World line to classiccharacters.openvanilla_world_log. Herald tails it every BRIDGE_POLL_SEC (2 s) and
posts the new lines, batched, to #world (BRIDGE_CHANNEL) as  **Name** (Class): text  with mentions off,
links shown as text (no previews), Discord markdown escaped, and messages split at 2,000 characters.

Discord -> game. A message in #world from a member with the Adventurer role (or staff) goes to the game
over the world server's console (SOAP):  .wnl worldsay <Name> <text>  and players see "[D] Name: text"
in their World tab. Attachments, embeds and stickers become "[image]", emoji become :their name:,
mentions their display names; at most 255 bytes; one message per BRIDGE_USER_GAP_SEC (3 s) and
BRIDGE_USER_PER_MIN (12) per minute per member (extra messages get a reaction and are not relayed).
Bots and webhooks are never relayed (so Herald's own posts don't loop).

One shared ignore list (staff: /bridge ignore <name>, /bridge unignore, /bridge status) works both ways:
a Discord member on it isn't relayed to the game, a character on it isn't posted to Discord. The moderation
desk's mutes count too: a Discord member in a Discord timeout, or whose game name is a character muted from
#moderation (Mute 1h / Mute 24h, or Herald's automatic 10-minute mute, until it runs out or is undone), is not
relayed, and that character's lines are not posted. In game, each player's own ignore list also hides [D]
names in the Chat addon, and the stock mute stops a muted player from talking in World at all.

Guild channels. "/guild discord #channel" (by someone who can manage messages in that channel, or staff)
gives a 6-digit code; the guild master or an officer types "/guildlink <code>" in game (".wnl guildlink");
Herald sees the code, links the guild: its guild chat is posted to that channel and messages there go to
the guild chat as "[D] Name: text" (.wnl guildsay). "/guild unlink #channel" ends it.

Settings (/etc/openvanilla-herald.env):
  BRIDGE_ENABLED=1        0 turns the whole bridge off (and Herald doesn't ask for the message content intent)
  BRIDGE_CHANNEL=world    the Discord channel mapped to World (name, or the part after "│")
  BRIDGE_POLL_SEC=2  BRIDGE_USER_GAP_SEC=3  BRIDGE_USER_PER_MIN=12
  BRIDGE_ROLE=Adventurer  who may talk into the game (staff always may)
  plus the support desk's SUPPORT_DB_* (a user that may also INSERT/DELETE the openvanilla_guild_* tables)
  and SOAP_URL / SOAP_USER / SOAP_PASS (a GM-3 console account).
Needs the MESSAGE CONTENT INTENT (Developer Portal -> Bot -> Privileged Gateway Intents) to read #world.
"""
import asyncio
import os
import random
import re
import time
import unicodedata

CLASS_NAMES = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage",
               9: "Warlock", 11: "Druid"}
MAX_DISCORD = 2000
MAX_GAME_BYTES = 255
LINK_TTL = 600            # a guild link code is good for 10 minutes
URL_RE = re.compile(r"(https?://[^\s<>]+|www\.[^\s<>]+)", re.I)
CUSTOM_EMOJI_RE = re.compile(r"<a?:([A-Za-z0-9_~]+):\d+>")
SPOILER_RE = re.compile(r"\|\|(.+?)\|\|", re.S)
FLAG_RE = re.compile("[\U0001F1E6-\U0001F1FF]{2}")
CODE_RE = re.compile(r"```(?:[a-z0-9_+-]*\n)?(.*?)```", re.S | re.I)
WOW_LINK_RE = re.compile(r"\|H[^|]*\|h(.*?)\|h")
WOW_COLOUR_RE = re.compile(r"\|c[0-9a-fA-F]{8}|\|r")
MUTE_SECONDS = {"mute1h": 3600, "mute24h": 86400}      # herald_mod.py's ACTIONS
AUTO_MUTE_SECONDS = {"mute10": 600}
ROLE_ALIASES = {"Adventurer": {"Player"}}               # discord_setup.py renamed Player -> Adventurer
ROLE_HINT_SEC = 3600                                      # a member without the role gets the 🔒 reaction once an hour


def env(name, default=""):
    v = os.environ.get(name, "").strip()
    return v if v else default


def enabled():
    return env("BRIDGE_ENABLED", "1") != "0"


# ----------------------------------------------------------------------------------------- text, both ways
def game_name(display, uid=0):
    """A Discord display name the game shows safely: ASCII letters, digits, _ - . (max 24)."""
    s = unicodedata.normalize("NFKD", str(display or ""))
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"\s+", "_", s.strip())
    s = re.sub(r"[^A-Za-z0-9_.-]", "", s).strip("_.-")[:24]
    return s or f"User{int(uid or 0) % 10000:04d}"


def _is_emoji(c):
    o = ord(c)
    return (0x1F000 <= o <= 0x1FAFF or 0x2600 <= o <= 0x27BF or 0x2300 <= o <= 0x23FF or 0x2B00 <= o <= 0x2BFF
            or 0x1F1E6 <= o <= 0x1F1FF or o in (0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139, 0x3030, 0x303D))


EMOJI_NAMES = {"\u2764": "heart", "\U0001F44D": "thumbsup", "\U0001F44E": "thumbsdown", "\U0001F602": "joy",
               "\U0001F923": "rofl", "\U0001F642": "slight_smile", "\U0001F600": "grinning", "\U0001F604": "smile",
               "\U0001F609": "wink", "\U0001F622": "cry", "\U0001F62D": "sob", "\U0001F525": "fire", "\U0001F389": "tada",
               "\U0001F64F": "pray", "\U0001F440": "eyes", "\U0001F914": "thinking", "\U0001F60D": "heart_eyes",
               "\U0001F44B": "wave", "\U0001F4AF": "100", "\u2694": "crossed_swords", "\U0001F6E1": "shield",
               "\u2728": "sparkles", "\U0001F480": "skull", "\U0001F643": "upside_down", "\U0001F605": "sweat_smile"}


def emoji_to_text(s):
    """Emoji -> :their name: (the game's fonts have none). Custom emoji <:name:id> -> :name:."""
    s = CUSTOM_EMOJI_RE.sub(lambda m: f":{m.group(1)}:", s or "")
    s = FLAG_RE.sub(lambda m: ":flag_" + "".join(chr(ord(c) - 0x1F1E6 + 97) for c in m.group(0)) + ":", s)
    out, last = [], None
    for c in s:
        o = ord(c)
        if o in (0x200D, 0xFE0F, 0xFE0E) or 0x1F3FB <= o <= 0x1F3FF or 0xE0020 <= o <= 0xE007F:
            continue                                   # joiners, variation selectors, skin tones, tags
        if _is_emoji(c):
            name = EMOJI_NAMES.get(c) or unicodedata.name(c, "emoji").lower().replace(" ", "_")
            tok = f":{name}:"
            if tok != last:                            # a run of the same emoji once
                out.append(tok)
            last = tok
            continue
        last = None
        out.append(c)
    return "".join(out)


def cut_bytes(s, limit=MAX_GAME_BYTES):
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s
    return b[:limit - 3].decode("utf-8", "ignore").rstrip() + "..."


def to_game_text(content, attachments=0, embeds=0, stickers=0):
    """A Discord message as one game chat line (or "" when nothing is left)."""
    t = content or ""
    t = CODE_RE.sub(lambda m: m.group(1), t)
    t = SPOILER_RE.sub("[spoiler]", t)
    t = emoji_to_text(t)
    t = re.sub(r"(\*\*|__|~~|`)", "", t)
    t = re.sub(r"(?<!\w)[*_](\S(?:.*?\S)?)[*_](?!\w)", r"\1", t)     # *italic* / _italic_
    t = t.replace("|", "/")                                        # the game's escape character
    t = re.sub(r"[\x00-\x1f\x7f]+", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    extra = attachments + embeds + stickers
    if extra:
        t = (t + " " if t else "") + " ".join(["[image]"] * min(extra, 3))
    return cut_bytes(t)


def discord_escape(text):
    """A game line made inert for Discord: markdown escaped, no masked links, no mentions. Web addresses stay
    plain text (the bridge posts with embeds suppressed, so they never preview)."""
    parts = URL_RE.split(str(text or ""))
    out = []
    for i, part in enumerate(parts):
        if i % 2:                                      # a URL: left alone so it still reads and copies
            out.append(part)
            continue
        part = re.sub(r"([\\*_~`|\[\]])", r"\\\1", part)
        part = re.sub(r"<(?=[@#:a])", "<\u200b", part)
        part = re.sub(r"@(everyone|here)", "@\u200b\\1", part)
        out.append(part)
    return "".join(out)


def from_game_text(text):
    """A game chat line as the players saw it: item/quest/spell links as their [Name], colours dropped,
    the escaped "||" back to one "|"."""
    t = WOW_LINK_RE.sub(lambda m: m.group(1), str(text or ""))
    t = WOW_COLOUR_RE.sub("", t)
    return t.replace("||", "|")


def format_line(row):
    cls = CLASS_NAMES.get(int(row.get("class") or 0))
    name = discord_escape(row.get("name") or "?")
    return f"**{name}**" + (f" ({cls})" if cls else "") + ": " + discord_escape(from_game_text(row.get("text")))


def split_messages(lines, limit=MAX_DISCORD):
    """Whole lines packed into messages of at most `limit` characters (a longer line is cut)."""
    out, cur = [], ""
    for line in lines:
        while len(line) > limit:
            if cur:
                out.append(cur)
                cur = ""
            out.append(line[:limit])
            line = line[limit:]
        if not line:
            continue
        if cur and len(cur) + 1 + len(line) > limit:
            out.append(cur)
            cur = ""
        cur = cur + "\n" + line if cur else line
    if cur:
        out.append(cur)
    return out


class RateLimiter:
    """One message per `gap` seconds and at most `per_min` a minute, per key."""

    def __init__(self, gap=3.0, per_min=12, now=time.time):
        self.gap, self.per_min, self.now, self.seen = gap, per_min, now, {}

    def allow(self, key):
        t = self.now()
        hist = [x for x in self.seen.get(key, []) if t - x < 60]
        if (hist and t - hist[-1] < self.gap) or len(hist) >= self.per_min:
            self.seen[key] = hist
            return False
        hist.append(t)
        self.seen[key] = hist
        return True


# ----------------------------------------------------------------------------------------- the realm
class BridgeRealm:
    """classiccharacters (the log, the guild links) and the world server's console."""

    def __init__(self, base=None):
        if base is None:
            import herald_support
            base = herald_support.Realm()
        self.base = base

    def _rows(self, sql, args=()):
        con = self.base.connect()
        try:
            cur = con.cursor()
            cur.execute(sql, args)
            return cur.fetchall()
        finally:
            con.close()

    def _exec(self, sql, args=()):
        con = self.base.connect()
        try:
            con.cursor().execute(sql, args)
            con.commit()
        finally:
            con.close()

    def max_id(self):
        r = self._rows("SELECT COALESCE(MAX(id), 0) FROM openvanilla_world_log")
        return int(r[0][0]) if r else 0

    def lines(self, after, limit=200):
        rows = self._rows("SELECT id, guid, name, class, guild, text, created FROM openvanilla_world_log WHERE id > %s "
                          "ORDER BY id LIMIT %s", (int(after), int(limit)))
        return [dict(id=r[0], guid=r[1], name=r[2], **{"class": r[3]}, guild=r[4], text=r[5], created=r[6]) for r in rows]

    def link_codes(self):
        return [dict(code=r[0], guild=r[1], guid=r[2], name=r[3], created=r[4])
                for r in self._rows("SELECT code, guildid, guid, name, created FROM openvanilla_guild_link_code")]

    def drop_code(self, code):
        self._exec("DELETE FROM openvanilla_guild_link_code WHERE code = %s", (code,))

    def bridges(self):
        return {int(r[0]): int(r[1]) for r in self._rows("SELECT guildid, discord_channel FROM openvanilla_guild_bridge")}

    def set_bridge(self, guild, channel, by):
        self._exec("REPLACE INTO openvanilla_guild_bridge (guildid, discord_channel, linked_by, created) "
                   "VALUES (%s, %s, %s, UNIX_TIMESTAMP())", (int(guild), int(channel), str(by)[:64]))

    def unbridge(self, channel):
        self._exec("DELETE FROM openvanilla_guild_bridge WHERE discord_channel = %s", (int(channel),))

    def guild_name(self, guild):
        r = self._rows("SELECT name FROM guild WHERE guildid = %s", (int(guild),))
        return r[0][0] if r else f"guild {guild}"

    def console(self, cmd):
        return self.base.console(cmd)


def console_refused(out):
    """The console answers in words, not errors: anything but "worldsay: N player(s)" / "guildsay: ..." means the
    line did not reach the game. Returns why (shown in the log and /bridge status), or None when it went through."""
    text = (out or "").strip()
    if re.match(r"^(worldsay|guildsay):\s*\d+", text):
        return None
    low = text.lower()
    if not text:
        return "the world server's console gave no answer"
    if "no such command" in low or "unknown command" in low or "there is no such" in low:
        return f"the world server doesn't know .wnl worldsay (realm patch 0007 not deployed?): {text[:120]}"
    if "(staff)" in low or "usage" in low:
        return f"the console account isn't staff, or the line was malformed: {text[:120]}"
    return text[:200]


# ----------------------------------------------------------------------------------------- the logic
class Bridge:
    """Everything but Discord itself, so it can be tested with fakes."""

    def __init__(self, realm, db, now=time.time, gap=None, per_min=None, role=None):
        self.realm, self.db, self.now = realm, db, now
        self.role = role or env("BRIDGE_ROLE", "Adventurer")
        self.limit = RateLimiter(float(gap if gap is not None else env("BRIDGE_USER_GAP_SEC", "3")),
                                 int(per_min if per_min is not None else env("BRIDGE_USER_PER_MIN", "12")), now)
        self.last_id = None
        self.guilds = {}              # guild id -> Discord channel id
        self.guilds_at = 0.0
        con = db()
        con.execute("CREATE TABLE IF NOT EXISTS bridge_state (key TEXT PRIMARY KEY, value TEXT)")
        con.execute("CREATE TABLE IF NOT EXISTS bridge_ignore (kind TEXT, value TEXT, by TEXT, created REAL, "
                    "PRIMARY KEY (kind, value))")
        con.execute("CREATE TABLE IF NOT EXISTS bridge_link (code TEXT PRIMARY KEY, channel_id INTEGER, user_id INTEGER, "
                    "user_name TEXT, created REAL)")
        con.commit()

    # -- shared ignore list ("game" = a character name, "discord" = a Discord user id) --
    def ignore(self, kind, value, by=""):
        value = str(value).strip()
        if kind == "game":
            value = value.capitalize()
        con = self.db()
        con.execute("INSERT OR REPLACE INTO bridge_ignore(kind, value, by, created) VALUES(?,?,?,?)", (kind, value, by, self.now()))
        con.commit()
        return value

    def unignore(self, kind, value):
        value = str(value).strip()
        con = self.db()
        n = con.execute("DELETE FROM bridge_ignore WHERE kind=? AND lower(value)=lower(?)", (kind, value)).rowcount
        con.commit()
        return n > 0

    def ignored(self, kind, value):
        return self.db().execute("SELECT 1 FROM bridge_ignore WHERE kind=? AND lower(value)=lower(?)",
                                 (kind, str(value))).fetchone() is not None

    def ignore_list(self):
        return self.db().execute("SELECT kind, value, by FROM bridge_ignore ORDER BY kind, value").fetchall()

    # -- the moderation desk's mutes (herald_mod.py's mod_cases, same database) --
    def muted_names(self):
        """Lower-case character names under a mute from #moderation that has not run out or been undone."""
        t = self.now()
        out = set()
        try:
            rows = self.db().execute("SELECT target, action, acted, auto_action, auto_at, auto_undone FROM mod_cases "
                                     "WHERE target IS NOT NULL AND (action IN ('mute1h','mute24h') OR auto_action='mute10')"
                                     ).fetchall()
        except Exception:                               # no moderation desk (yet): nobody is muted here
            return out
        for target, action, acted, auto_action, auto_at, auto_undone in rows:
            if action in MUTE_SECONDS and acted and t - float(acted) < MUTE_SECONDS[action]:
                out.add(str(target).lower())
            if auto_action in AUTO_MUTE_SECONDS and auto_at and not auto_undone \
                    and t - float(auto_at) < AUTO_MUTE_SECONDS[auto_action]:
                out.add(str(target).lower())
        return out

    # -- game -> Discord --
    def _state(self, key, default=None):
        r = self.db().execute("SELECT value FROM bridge_state WHERE key=?", (key,)).fetchone()
        return r[0] if r else default

    def _set_state(self, key, value):
        con = self.db()
        con.execute("INSERT OR REPLACE INTO bridge_state(key, value) VALUES(?,?)", (key, str(value)))
        con.commit()

    def refresh_guilds(self, force=False):
        if force or self.now() - self.guilds_at > 60:
            self.guilds = self.realm.bridges()
            self.guilds_at = self.now()
        return self.guilds

    def poll(self):
        """New log lines -> {target: [messages]}; target "world" or a Discord channel id."""
        if self.last_id is None:
            stored = self._state("last_id")
            # first start: begin at the end of the log (no backlog flood); later: carry on
            self.last_id = int(stored) if stored is not None else self.realm.max_id()
            self._set_state("last_id", self.last_id)
        rows = self.realm.lines(self.last_id)
        if not rows:
            return {}
        self.last_id = max(r["id"] for r in rows)
        self._set_state("last_id", self.last_id)
        guilds = self.refresh_guilds()
        muted = self.muted_names()
        per = {}
        for r in rows:
            if not r.get("guid"):                       # came from Discord: don't echo it back
                continue
            if self.ignored("game", r.get("name") or "") or str(r.get("name") or "").lower() in muted:
                continue
            g = int(r.get("guild") or 0)
            target = "world" if g == 0 else guilds.get(g)
            if target is None:
                continue
            per.setdefault(target, []).append(format_line(r))
        return {t: split_messages(lines) for t, lines in per.items()}

    # -- Discord -> game --
    def note_relay(self, ok, detail):
        self.last_relay = (self.now(), bool(ok), str(detail)[:200])

    def relay_status(self):
        r = getattr(self, "last_relay", None)
        if not r:
            return "Discord -> game: nothing relayed since Herald started."
        ago = int(max(0, self.now() - r[0]) // 60)
        return f"Discord -> game: last {'OK' if r[1] else 'FAILED'} {ago} min ago ({r[2]})."

    def check_console(self):
        """At start: can Herald use the world server's console at all? Returns why not, or None."""
        try:
            self.realm.console(".server info")
        except Exception as e:
            why = (f"{type(e).__name__}: {e}. Herald's console account (SOAP_USER, HELPDESK) is refused or the "
                   f"console relay (SOAP_URL) is down: run  bash hetzner/herald_up.sh  on the server, then restart Herald")
            self.note_relay(False, why)
            return why
        return None

    def may_talk(self, roles, staff):
        return staff or self.role in roles or bool(ROLE_ALIASES.get(self.role, set()) & set(roles))

    def from_discord(self, user_id, display, roles, staff, is_bot, content, attachments=0, embeds=0, stickers=0,
                     guild=None, timed_out=False):
        """(command, None) to run on the console, or (None, why) when the message is not relayed.
        guild: None for World, else the guild id the channel is linked to. timed_out: a Discord timeout."""
        if is_bot:
            return None, "bot"
        if not self.may_talk(roles, staff):
            return None, "role"
        if self.ignored("discord", user_id):
            return None, "ignored"
        name = game_name(display, user_id)
        if timed_out or (not staff and name.lower() in self.muted_names()):
            return None, "muted"
        text = to_game_text(content, attachments, embeds, stickers)
        if not text:
            return None, "empty"
        if not self.limit.allow(user_id):
            return None, "rate"
        if guild is None:
            return f".wnl worldsay {name} {text}", None
        return f".wnl guildsay {int(guild)} {name} {text}", None

    def channel_guild(self, channel_id):
        for g, c in self.refresh_guilds().items():
            if c == channel_id:
                return g
        return None

    # -- guild links --
    def start_link(self, channel_id, user_id, user_name):
        code = f"{random.SystemRandom().randrange(0, 1000000):06d}"
        con = self.db()
        con.execute("DELETE FROM bridge_link WHERE created < ?", (self.now() - LINK_TTL,))
        con.execute("INSERT OR REPLACE INTO bridge_link(code, channel_id, user_id, user_name, created) VALUES(?,?,?,?,?)",
                    (code, int(channel_id), int(user_id), str(user_name), self.now()))
        con.commit()
        return code

    def check_links(self):
        """Codes typed in game that match one Herald gave: link them. Returns [(guild, channel, guild_name, who)]."""
        done = []
        con = self.db()
        for c in self.realm.link_codes():
            row = con.execute("SELECT channel_id, user_name, created FROM bridge_link WHERE code=?", (c["code"],)).fetchone()
            stale = self.now() - float(c.get("created") or 0) > LINK_TTL
            if row and self.now() - row[2] <= LINK_TTL and not stale:
                self.realm.set_bridge(c["guild"], row[0], f"{row[1]} / {c['name']}")
                con.execute("DELETE FROM bridge_link WHERE code=?", (c["code"],))
                con.commit()
                done.append((c["guild"], row[0], self.realm.guild_name(c["guild"]), c["name"]))
                self.realm.drop_code(c["code"])
            elif stale or not row:
                if stale:
                    self.realm.drop_code(c["code"])
        if done:
            self.refresh_guilds(force=True)
        return done


# ----------------------------------------------------------------------------------------- Discord
def listen(bot, fn, name="on_message"):
    """bot.add_listener when the client has it (commands.Bot), else chain onto the existing handler."""
    if hasattr(bot, "add_listener"):
        bot.add_listener(fn, name)
        return
    prev = getattr(bot, name, None)

    async def chained(*a, **kw):
        if prev:
            await prev(*a, **kw)
        await fn(*a, **kw)
    setattr(bot, name, chained)


def install(bot, discord, db, chan, is_staff, gid, realm=None, now=time.time, poll=None):
    """Wire the bridge into Herald. Returns an object whose start() begins tailing the log."""
    bridge = Bridge(realm or BridgeRealm(), db, now=now)
    channel_name = env("BRIDGE_CHANNEL", "world")
    hinted = {}                                     # member id -> when they last got the "no role" reaction
    poll = float(poll if poll is not None else env("BRIDGE_POLL_SEC", "2"))
    NONE = discord.AllowedMentions.none()

    def guild():
        return bot.get_guild(int(gid))

    def world_channel():
        g = guild()
        return chan(g, channel_name) if g else None

    def roles_of(member):
        return {r.name for r in getattr(member, "roles", [])}

    def timed_out(member):
        f = getattr(member, "is_timed_out", None)
        if callable(f):
            try:
                return bool(f())
            except Exception:
                return False
        return False

    async def send(target, text):
        ch = world_channel() if target == "world" else bot.get_channel(int(target))
        if ch is None:
            return False
        try:
            await ch.send(text, allowed_mentions=NONE, suppress_embeds=True)
        except TypeError:                               # discord.py before 2.0 had no suppress_embeds
            await ch.send(text, allowed_mentions=NONE)
        except discord.HTTPException as e:
            print(f"[bridge] can't post in #{getattr(ch, 'name', target)}: {e}")
            return False
        return True

    async def tick():
        try:
            batches = await asyncio.to_thread(bridge.poll)
        except Exception as e:
            from herald_quiet import warn
            warn("bridge", "can't read openvanilla_world_log", e)
            return
        from herald_quiet import ok as recovered
        recovered("bridge", "can't read openvanilla_world_log")
        for target, messages in batches.items():
            for m in messages:
                await send(target, m)
        try:
            links = await asyncio.to_thread(bridge.check_links)
        except Exception:
            links = []
        for g, ch_id, gname, who in links:
            await send(ch_id, f"🔗 This channel is now linked to the guild chat of **{discord_escape(gname)}** "
                              f"(confirmed in game by {discord_escape(who)}).")

    async def on_message(message):
        author = message.author
        if message.guild is None or message.guild.id != int(gid) or getattr(message, "webhook_id", None):
            return
        ch = message.channel
        world = world_channel()
        g = None
        if world is None or ch.id != world.id:
            g = bridge.channel_guild(ch.id)
            if g is None:
                return
        cmd, why = bridge.from_discord(author.id, getattr(author, "display_name", None) or author.name, roles_of(author),
                                       is_staff(author), bool(getattr(author, "bot", False)), message.content or "",
                                       len(getattr(message, "attachments", []) or []), len(getattr(message, "embeds", []) or []),
                                       len(getattr(message, "stickers", []) or []), guild=g, timed_out=timed_out(author))
        if not cmd:
            mark = None
            if why == "rate":
                mark = "⏳"
            elif why == "role" and bridge.now() - hinted.get(author.id, -1e9) > ROLE_HINT_SEC:
                hinted[author.id] = bridge.now()    # once an hour: their messages stay on Discord only
                mark = "🔒"
            if mark:
                try:
                    await message.add_reaction(mark)
                except Exception:
                    pass
            return
        try:
            out = await asyncio.to_thread(bridge.realm.console, cmd)
            bad = console_refused(out)
            if bad:
                raise RuntimeError(bad)
            bridge.note_relay(True, out)
        except Exception as e:
            bridge.note_relay(False, e)
            from herald_quiet import warn
            warn("bridge", "Discord -> game", e)
            try:
                await message.add_reaction("⚠")
            except Exception:
                pass

    listen(bot, on_message)

    from discord import app_commands

    grp = app_commands.Group(name="bridge", description="Staff: the Discord <-> World chat bridge")

    @grp.command(name="ignore", description="Stop relaying a Discord member or a character, both ways")
    async def ignore_cmd(interaction, member: discord.Member = None, character: str = None):
        if not is_staff(interaction.user):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        done = []
        if member is not None:
            bridge.ignore("discord", member.id, str(interaction.user))
            done.append(member.display_name)
        if character:
            done.append(bridge.ignore("game", character, str(interaction.user)))
        await interaction.response.send_message(("Ignored: " + ", ".join(done)) if done else "Name a member or a character.",
                                                ephemeral=True)

    @grp.command(name="unignore", description="Relay a member or a character again")
    async def unignore_cmd(interaction, member: discord.Member = None, character: str = None):
        if not is_staff(interaction.user):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        ok = (member is not None and bridge.unignore("discord", member.id)) | bool(character and bridge.unignore("game", character))
        await interaction.response.send_message("Done." if ok else "Not on the list.", ephemeral=True)

    @grp.command(name="status", description="The bridge: channel, linked guilds, ignore list")
    async def status_cmd(interaction):
        if not is_staff(interaction.user):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        ign = bridge.ignore_list()
        g = await asyncio.to_thread(bridge.refresh_guilds, True)
        await interaction.response.send_message(
            f"World <-> #{channel_name}, last log id {bridge.last_id}. Linked guilds: {len(g)}. "
            f"Ignored: {', '.join(f'{k}:{v}' for k, v, _ in ign) or 'nobody'}. {bridge.relay_status()}", ephemeral=True)

    guild_grp = app_commands.Group(name="guild", description="Your in-game guild and Discord")

    def can_manage(member, channel):
        if is_staff(member):
            return True
        try:
            return bool(channel.permissions_for(member).manage_messages)
        except Exception:
            return False

    @guild_grp.command(name="discord", description="Link a channel to your guild's chat (officers)")
    async def guild_discord(interaction, channel: discord.TextChannel):
        world = world_channel()
        if world is not None and channel.id == world.id:
            await interaction.response.send_message("That's the World channel.", ephemeral=True)
            return
        if not can_manage(interaction.user, channel):
            await interaction.response.send_message(f"You need Manage Messages in {channel.mention} (ask staff to set "
                                                    "the channel up for your guild).", ephemeral=True)
            return
        code = bridge.start_link(channel.id, interaction.user.id, str(interaction.user))
        await interaction.response.send_message(
            f"Now, in game, as your guild's **guild master or an officer**, type `/guildlink {code}` "
            f"(within 10 minutes). Guild chat then shows up in {channel.mention} and messages there reach your guild.",
            ephemeral=True)

    @guild_grp.command(name="unlink", description="Stop linking a channel to a guild's chat")
    async def guild_unlink(interaction, channel: discord.TextChannel):
        if not can_manage(interaction.user, channel):
            await interaction.response.send_message("You need Manage Messages in that channel.", ephemeral=True)
            return
        await asyncio.to_thread(bridge.realm.unbridge, channel.id)
        await asyncio.to_thread(bridge.refresh_guilds, True)
        await interaction.response.send_message(f"{channel.mention} is no longer linked to a guild.", ephemeral=True)

    try:
        bot.tree.add_command(grp)
        bot.tree.add_command(guild_grp)
    except Exception as e:
        print(f"[bridge] slash commands: {e}")

    class Relay:
        task = None

        def __init__(self):
            self.bridge, self.tick, self.on_message = bridge, tick, on_message

        def start(self):
            async def loop():
                await bot.wait_until_ready()
                if world_channel() is None:
                    print(f"[bridge] no #{channel_name} channel: World lines are not posted (guild links still work)")
                why = await asyncio.to_thread(bridge.check_console)
                if why:
                    print(f"[bridge] Discord -> game is OFF: {why}")
                while not bot.is_closed():
                    await tick()
                    await asyncio.sleep(poll)
            self.task = asyncio.get_event_loop().create_task(loop())

    return Relay()
