"""Open Vanilla Herald: the always-on Discord bot, and the voice of Vanilla Remastered.

    py -3 herald.py        (Windows, or Start_Herald.bat)   ·   python3 herald.py   (the server: hetzner/herald_up.sh)

The way in (anti-bot, anti-raid)
  Outsider    joined the Discord, nothing confirmed. Sees only #welcome. Kicked after GATE_TIMEOUT_HOURS.
  Recruit     passed the gate: read the rules, answered Herald's question (account-age check optional).
              Sees START HERE and help, and may create a realm account (or waits for a wave, see SIGNUP_MODE).
  Adventurer  has a realm account (the realm grants this role on "Sign in with Discord"). Full access.
              The first TRAILBLAZER_LIMIT adventurers also get Trailblazer, for good.

What Herald does
  · Gives every newcomer Outsider; the Enter the gate button runs the rules question.
  · Raid shield: too many joins too fast -> the gate bars itself, verification goes to the highest level,
    new invites and member DMs pause (Discord's incident actions), staff are pinged in #alerts. Lifts itself after RAID_COOLDOWN_MIN quiet minutes, or /lockdown off.
  · Sees the realm grant Adventurer -> removes Outsider/Recruit, announces the newcomer silently in #arrivals
    (no pings, ever), DMs them, and writes the public sign-up feed the website shows (public/feed.json).
  · #server-status: one live message. #alerts: realm down/up. #gatehouse: every gate pass, fail and kick.
  · /status /census /herald /feed for everyone; /wave /lockdown /promote for staff.

Settings (.env beside this file, or the environment; only the first two are required):
  DISCORD_BOT_TOKEN, DISCORD_GUILD_ID
  SIGNUP_MODE=open|waves      open: every Recruit may create an account now. waves: Recruits queue for /wave.
  MIN_ACCOUNT_AGE_DAYS=0      Discord accounts younger than this wait at the gate (0 = off, the default).
  GATE_TIMEOUT_HOURS=48       Outsiders who never pass the gate are shown out (0 = never).
  RAID_JOINS=8  RAID_WINDOW_SEC=60  RAID_COOLDOWN_MIN=15
  TRAILBLAZER_LIMIT=500       0 turns the Trailblazer role off.
  REALM_URL, DISCORD_INVITE_URL, HERALD_DB, HERALD_PUBLIC_DIR
  Support desk (in-game tickets): OWNER_DISCORD_ID and the realm settings in herald_support.py.
  World bridge (#world <-> the in-game World channel): BRIDGE_ENABLED=1, BRIDGE_CHANNEL=world, see herald_bridge.py.
  In-game LIVE marks: STREAMS_INGAME=1, STREAMS_JSON (default <HERALD_PUBLIC_DIR>/streams.json), see herald_streams.py.

Needs the SERVER MEMBERS INTENT: Developer Portal -> your app -> Bot -> Privileged Gateway Intents.
"""
import asyncio
import collections
import datetime as dt
import json
import os
import random
import sqlite3
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
GATE_ID = "openvanilla:gate"
LEGACY_ACCESS_ID = "openvanilla:access"          # the old "Get access" button, still answered
SITE = "https://openvanilla.app/"
STAFF_ROLES = {"Founder", "Admin", "Developer", "Game Master", "Moderator"}
OUTSIDER, RECRUIT, ADVENTURER, TRAILBLAZER = "Outsider", "Recruit", "Adventurer", "Trailblazer"
LEGACY = {"Waitlist": RECRUIT, "Player": ADVENTURER}   # old names, renamed by discord_setup.py
TESTERS = {"Alpha Tester", "Beta Tester"}
FACTIONS = [("Alliance", "🛡"), ("Horde", "🪓")]
CLASSES = [("Warrior", "⚔"), ("Paladin", "🔨"), ("Hunter", "🏹"), ("Rogue", "🗡"), ("Priest", "✨"),
           ("Shaman", "⚡"), ("Mage", "🔥"), ("Warlock", "💀"), ("Druid", "🐾")]


def load_env():
    path = os.path.join(HERE, ".env")
    if not os.path.isfile(path) and os.path.basename(HERE) == "bot":
        path = os.path.join(os.path.dirname(HERE), ".env")   # the repo's .env (bot/ lives one level down)
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            k, sep, v = line.partition("=")
            if sep and not k.strip().startswith("#"):
                os.environ.setdefault(k.strip(), v.strip().strip('"'))


def setting(name, default):
    v = os.environ.get(name, "").strip()
    if not v:
        return default
    return type(default)(v) if not isinstance(default, str) else v


# =====================================================================================================
#  Herald's voice. A friendly coach: upbeat, encouraging, on your side. Celebrates every step, never
#  scolds, explains what's next in plain words, two or three sentences at most. Edit freely.
# =====================================================================================================
VOICE = {
    "gate_intro": [
        "**Hey, welcome in!** 👋 I'm the Herald, and I'll get you set up in about a minute. Quick warm-up "
        "question first (the answer's in the rules just above):",
        "**Great to have you here!** 🙌 One quick question to get you started. Peek at the rules above if you "
        "need to, there's no rush:",
        "**Welcome, adventurer!** ⚔ Let's get you in. First up, an easy one from the rules above:",
    ],
    "pass_open": [
        "**Nailed it!** 🎉 You're officially a **Recruit**.\n"
        "One more step and you're all the way in: press **Create my account**, then **Sign in with Discord**. "
        "It takes about ten seconds and there's no password to remember. I'll unlock every channel the "
        "moment you're done!",
        "**That's the one, nice work!** 💪 You're a **Recruit** now.\n"
        "Last step: **Create my account**, then **Sign in with Discord**. As soon as your account exists I'll "
        "open up the whole server for you. You've got this!",
    ],
    "pass_waves": [
        "**Nailed it!** 🎉 You're a **Recruit**, and you're **#{n}** in line.\n"
        "We let people in by **waves** so the realm stays smooth for everyone. I'll DM you the moment it's "
        "your turn. Hang tight, it's coming!",
    ],
    "wrong": [
        "Close, but not quite! 🙂 Give the rules above another look and try again in {secs} seconds. You've got it.",
        "Not that one, no worries! Take a quick look at the rules and have another go in {secs} seconds.",
    ],
    "locked": [
        "Let's take a short breather. ⏸ The gate opens for you again {when}. Give the rules a read in the "
        "meantime and you'll breeze through. If you're stuck, a staff member is happy to help!",
    ],
    "too_fresh": [
        "Your Discord account is brand new (made {made}), so we ask new accounts to wait a little while. "
        "It's just to keep spam bots out. 🛡 You'll be good to go on {when}. See you then!",
    ],
    "lockdown": [
        "Heads up: we're getting a big rush of joins right now, so the gate is paused for a few minutes. 🛡 "
        "It's not you! Try again shortly and you'll be right in.",
    ],
    "already": [
        "You're already all set, **{name}**! 🙌 Jump in at {realm}, and pick your faction and class below.",
    ],
    "need_account": [
        "You're almost there, **{name}**! 💪 Just **Create my account** (Sign in with Discord) and the whole "
        "server opens up.",
    ],
    "need_gate": [
        "Almost! First press **Enter the gate** in welcome and answer the quick question, then come pick your "
        "colours. 🙂",
    ],
    "arrival": [
        "🎉 Give it up for {who}, adventurer **#{n}**{tail}! Welcome to the team!",
        "👋 Say hi to {who}, our newest adventurer, **#{n}**{tail}!",
        "🙌 {who} just joined as adventurer **#{n}**{tail}. Glad you're here!",
        "⚔ Fresh legs on the field: {who}, adventurer **#{n}**{tail}. Let's go!",
        "🍺 The tavern just got better: welcome {who}, adventurer **#{n}**{tail}!",
        "🗺 New adventure starting! {who} is adventurer **#{n}**{tail}.",
    ],
    "trailblazer": ", one of our first {limit} **Trailblazers**",
    "welcome_dm": [
        "🎉 **You're in, {name}!** Your realm account is ready and every channel is open to you.\n"
        "Here's your game plan:\n"
        "• **Play:** {realm} (Chrome or Edge), or grab the launcher at {site}\n"
        "• **Meet people:** say hi in introductions, find a group in looking-for-group\n"
        "• **Stuck on anything?** Post in help. Real people answer, and no question is too small\n"
        "You're adventurer **#{n}**.{trail} I gave you a shout-out in arrivals (no pings). Want your name and "
        "avatar on the website's new-adventurer feed? Type `/feed show` (until then you're listed anonymously). Have a blast out there! 💪",
    ],
    "welcome_back": [
        "Welcome back, **{name}**! 👋 Great to see you again. Your **Adventurer** role is restored, so jump "
        "right back in.",
    ],
    "wave_dm": [
        "🎉 **It's your turn, {name}!** You're in **wave {wave}** on Vanilla Remastered.\n"
        "Open {realm} in Chrome or Edge and press **Sign in with Discord**. Your account is made on the spot "
        "and I'll open up the whole server for you. Desktop players: the launcher is at {site}. Have fun!",
    ],
    "prune_dm": [
        "Hey! You joined the Open Vanilla Discord {hours} hours ago but didn't get through the gate, so I've "
        "tidied you out for now. No worries at all: you're welcome back any time{invite}, and it only takes "
        "a minute. 👋",
    ],
    "raid_on": [
        "🚨 **Raid shield up.** {n} joins in {secs} seconds. The gate is paused, verification is at the highest "
        "level, and invites and member DMs are paused. It lifts itself after {mins} quiet minutes, or "
        "`/lockdown off`.",
    ],
    "raid_off": [
        "🟢 **Raid shield down.** The gate is open again and verification is back to normal. Nice work, team.",
    ],
    "realm_down": ["🔴 **Heads up, the realm isn't answering.** {staff} {realm} looks down."],
    "realm_up": ["🟢 **We're back!** The realm is up again after {mins} min."],
    "proclaim": [
        "💡 **Coach's tip:** Hide your UI with **Alt+Z** before you screenshot. Cleaner shots, every time.",
        "💡 **Coach's tip:** Vanilla Remastered has modern WoW's race and class combos. Tauren Rogue, Orc "
        "Priest and Dwarf Shaman are all waiting!",
        "💡 **Coach's tip:** Stuck on a quest? Ask in help or looking-for-group. Everyone was new once.",
        "💡 **Coach's tip:** Found a bug? Report it in bug-reports. You'll be helping every player after you.",
        "📣 We're **{adv}** adventurers strong and growing. Thanks for being part of it!",
        "📣 The Alliance and the Horde stand at **{a}** to **{h}**. Both sides are welcome at the tavern!",
        "💡 **Coach's tip:** Grab a Dungeon voice channel with your group. Runs go smoother when you can talk.",
        "💡 **Coach's tip:** Never share your password with anyone, staff included. We'll never ask for it.",
        "💡 **Coach's tip:** Take breaks, drink water, stretch between dungeons. Azeroth will still be there!",
    ],
    "presence": [
        "new players arrive", "over {adv} adventurers", "the gate", "the realm", "you succeed",
    ],
}

# Questions for the gate. The answer is in the rules image right above the button (or is common sense).
QUESTIONS = [
    ("Rule II forbids one of these. Which?", "Real-money trading",
     ["Making friends", "Playing a Gnome", "Asking for help"]),
    ("You found a bug. What do you do?", "Report it", ["Abuse it", "Sell it", "Keep it secret"]),
    ("Who has the final say?", "Staff", ["The loudest player", "Whoever posts first", "The Murlocs"]),
    ("What does Rule III ban?", "Spam and scams", ["Druids", "Fishing", "Dancing on mailboxes"]),
    ("You disagree with a staff decision. Where do you go?", "A post in help, calmly",
     ["Ping everyone", "DM every moderator", "Rage in general"]),
    ("Which of these is allowed?", "Asking for a group", ["Cheats and bots", "Scam links", "Harassment"]),
]


def say(key, **kw):
    line = random.choice(VOICE[key]) if isinstance(VOICE[key], list) else VOICE[key]
    return line.format(**kw)


# =====================================================================================================
#  Storage
# =====================================================================================================
def db():
    con = sqlite3.connect(DB, timeout=10, isolation_level=None)  # autocommit: no lock is ever left open
    con.execute("""CREATE TABLE IF NOT EXISTS waitlist (
        discord_id INTEGER PRIMARY KEY, name TEXT NOT NULL, joined REAL NOT NULL,
        wave INTEGER, invited REAL)""")
    con.execute("""CREATE TABLE IF NOT EXISTS members (
        discord_id INTEGER PRIMARY KEY, name TEXT,
        outsider_since REAL,          -- when Herald gave Outsider (the gate timeout counts from here)
        verified REAL,                -- passed the gate
        account REAL,                 -- realm account seen (Adventurer granted)
        number INTEGER,               -- adventurer #
        hidden INTEGER DEFAULT 0,     -- legacy (before the feed was opt-in)
        fails INTEGER DEFAULT 0, retry_at REAL DEFAULT 0)""")
    # The website feed is opt-in: a name and avatar appear only after /feed show.
    if "shown" not in {r[1] for r in con.execute("PRAGMA table_info(members)")}:
        con.execute("ALTER TABLE members ADD COLUMN shown INTEGER DEFAULT 0")
    return con


def member_row(con, uid):
    con.execute("INSERT OR IGNORE INTO members(discord_id) VALUES(?)", (uid,))
    return con.execute("SELECT name,outsider_since,verified,account,number,hidden,fails,retry_at "
                       "FROM members WHERE discord_id=?", (uid,)).fetchone()


def realm_up(timeout=8):
    """True when the realm's website answers (it sits in front of the login and world servers)."""
    try:
        req = urllib.request.Request(REALM_URL, method="HEAD", headers={"User-Agent": "OpenVanilla-Herald"})
        with urllib.request.urlopen(req, timeout=timeout) as r:  # nosec B310 - fixed https URL
            return r.status < 500
    except Exception:
        return False


def players_online():
    """Characters in the world right now (classiccharacters.characters.online), or None when the
    database can't be read. Same login as the moderation and support desks (SUPPORT_DB_*)."""
    try:
        import pymysql
        con = pymysql.connect(host=setting("SUPPORT_DB_HOST", "127.0.0.1"), port=int(setting("SUPPORT_DB_PORT", "13306")),
                              user=setting("SUPPORT_DB_USER", "herald"), password=setting("SUPPORT_DB_PASS", ""),
                              database=setting("CHARACTERS_DATABASE", "classiccharacters"), connect_timeout=5)
        try:
            with con.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM characters WHERE online = 1")
                return int(cur.fetchone()[0])
        finally:
            con.close()
    except Exception as e:  # noqa: BLE001 - optional: the site then just says "online"
        try:
            from herald_quiet import warn
            warn("status", "can't count players online", e)
        except ImportError:
            pass
        return None


def write_json_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def iso(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


load_env()
REALM_URL = setting("REALM_URL", "https://play.openvanilla.app/")
SIGNUP_URL = setting("SIGNUP_URL", REALM_URL.rstrip("/") + "/login")
INVITE_URL = setting("DISCORD_INVITE_URL", "")
DB = setting("HERALD_DB", os.path.join(HERE, "herald.db"))
PUBLIC_DIR = setting("HERALD_PUBLIC_DIR", os.path.join(os.path.dirname(DB), "public"))
SIGNUP_MODE = setting("SIGNUP_MODE", "open").lower()
MIN_AGE_DAYS = setting("MIN_ACCOUNT_AGE_DAYS", 0.0)  # off for now
GATE_TIMEOUT_H = setting("GATE_TIMEOUT_HOURS", 48.0)
RAID_JOINS = setting("RAID_JOINS", 8)
RAID_WINDOW = setting("RAID_WINDOW_SEC", 60)
RAID_COOLDOWN = setting("RAID_COOLDOWN_MIN", 15)
TRAIL_LIMIT = setting("TRAILBLAZER_LIMIT", 500)
WRONG_WAIT, MAX_FAILS, LOCKOUT = 30, 3, 15 * 60
HOOKS = {}  # the bot's internals, for tests


def main():
    token, gid = os.environ.get("DISCORD_BOT_TOKEN"), os.environ.get("DISCORD_GUILD_ID")
    if not token or not gid:
        sys.exit("Set DISCORD_BOT_TOKEN and DISCORD_GUILD_ID in .env (run Setup_Discord.bat once).")
    try:
        import discord
        from discord import app_commands
        from discord.ext import tasks
    except ImportError:
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "discord.py>=2.3"])
        import discord
        from discord import app_commands
        from discord.ext import tasks

    guild_obj = discord.Object(id=int(gid))
    intents = discord.Intents.default()
    intents.members = True  # privileged: joins, role changes, the member list for the census
    if os.environ.get("BRIDGE_ENABLED", "1").strip() != "0":
        intents.message_content = True  # privileged: the #world <-> in-game World bridge reads messages (herald_bridge.py)
    state = {"up": None, "since": time.time(), "status_msg": None, "lockdown_until": 0.0, "raid_level": None,
             "counts": (None, None), "joins": collections.deque(maxlen=200)}
    NONE = discord.AllowedMentions.none()

    # ---------------------------------------------------------------- helpers
    def chan(guild, suffix):
        return next((c for c in guild.text_channels if c.name.split("│")[-1] == suffix), None)

    def role(guild, name):
        r = discord.utils.get(guild.roles, name=name)
        if r is None and name in LEGACY.values():  # before discord_setup.py renamed the old roles
            old = next((k for k, v in LEGACY.items() if v == name), None)
            r = discord.utils.get(guild.roles, name=old) if old else None
        return r

    def names(member):
        out = {r.name for r in getattr(member, "roles", [])}
        return out | {LEGACY[n] for n in out if n in LEGACY}

    def is_staff(member):
        return bool(names(member) & STAFF_ROLES)

    def has_account(member):
        return ADVENTURER in names(member) or is_staff(member)

    def past_gate(member):
        return bool(names(member) & ({RECRUIT, ADVENTURER} | TESTERS | STAFF_ROLES))

    def lockdown():
        return time.time() < state["lockdown_until"]

    def place(con, uid):
        row = con.execute("SELECT joined FROM waitlist WHERE discord_id=? AND invited IS NULL", (uid,)).fetchone()
        if not row:
            return None
        return con.execute("SELECT COUNT(*) FROM waitlist WHERE invited IS NULL AND joined<=?", (row[0],)).fetchone()[0]

    async def gatelog(guild, text):
        ch = chan(guild, "gatehouse") or chan(guild, "waves")
        if ch:
            try:
                await ch.send(text, silent=True, allowed_mentions=NONE)
            except discord.HTTPException:
                pass

    async def safe_roles(member, add=(), remove=(), reason=""):
        add = [r for r in add if r and r not in member.roles]
        remove = [r for r in remove if r and r in member.roles]
        try:
            if add:
                await member.add_roles(*add, reason=reason)
            if remove:
                await member.remove_roles(*remove, reason=reason)
            return True
        except discord.HTTPException as e:
            print(f"[roles] {member}: {e}")
            return False

    def signup_view():
        v = discord.ui.View(timeout=None)
        v.add_item(discord.ui.Button(label="Create my account", url=SIGNUP_URL, emoji="⚔"))
        v.add_item(discord.ui.Button(label="Website", url=SITE))
        return v

    # ---------------------------------------------------------------- the gate
    class Challenge(discord.ui.View):
        """One question, four shuffled answers. Lives only in the newcomer's ephemeral message."""

        def __init__(self, uid):
            super().__init__(timeout=180)
            self.uid = uid
            q, right, wrong = random.choice(QUESTIONS)
            self.question = q
            answers = [right] + random.sample(wrong, 3)
            random.shuffle(answers)
            for i, a in enumerate(answers):
                b = discord.ui.Button(label=a, style=discord.ButtonStyle.secondary, row=i // 2)
                b.callback = self._answer(a == right)
                self.add_item(b)

        def _answer(self, correct):
            async def cb(interaction):
                await answered(interaction, correct)
            return cb

    async def answered(interaction, correct):
        member, guild, con = interaction.user, interaction.guild, db()
        if not correct:
            fails = (member_row(con, member.id)[6] or 0) + 1
            wait = LOCKOUT if fails >= MAX_FAILS else WRONG_WAIT
            con.execute("UPDATE members SET fails=?, retry_at=? WHERE discord_id=?",
                        (0 if fails >= MAX_FAILS else fails, time.time() + wait, member.id))
            con.commit()
            if fails >= MAX_FAILS:
                await gatelog(guild, f"⛔ {member.mention} ({member.name}) failed the gate question {MAX_FAILS}× "
                                     f"(locked {LOCKOUT // 60} min)")
                msg = say("locked", when=f"<t:{int(time.time() + wait)}:R>")
            else:
                msg = say("wrong", secs=wait)
            await interaction.response.edit_message(content=msg, view=None)
            return
        con.execute("UPDATE members SET verified=?, fails=0, retry_at=0, name=? WHERE discord_id=?",
                    (time.time(), member.display_name, member.id))
        con.commit()
        await safe_roles(member, add=[role(guild, RECRUIT)], remove=[role(guild, OUTSIDER)],
                         reason="Passed the gate")
        age = (dt.datetime.now(dt.timezone.utc) - member.created_at).days
        await gatelog(guild, f"🧭 {member.mention} ({member.name}) passed the gate · Discord account {age} days old")
        if SIGNUP_MODE == "waves":
            if not con.execute("SELECT 1 FROM waitlist WHERE discord_id=?", (member.id,)).fetchone():
                con.execute("INSERT INTO waitlist(discord_id,name,joined) VALUES(?,?,?)",
                            (member.id, member.name, time.time()))
                con.commit()
            text, view = say("pass_waves", n=place(con, member.id) or "?"), RolePicker()
        else:
            text, view = say("pass_open"), signup_view()
        await interaction.response.edit_message(content=text, view=view)
        if SIGNUP_MODE == "waves":
            return
        await interaction.followup.send("**Show your colours** 👇 (faction and main class, change any time)",
                                        view=RolePicker(), ephemeral=True)

    async def enter_gate(interaction):
        member, guild = interaction.user, interaction.guild
        if has_account(member):
            await interaction.response.send_message(say("already", name=member.display_name, realm=REALM_URL),
                                                    view=RolePicker(), ephemeral=True)
            return
        if past_gate(member):
            await interaction.response.send_message(say("need_account", name=member.display_name)
                                                    if SIGNUP_MODE != "waves" else
                                                    f"You're **#{place(db(), member.id) or '?'}** in line. "
                                                    "I'll DM you when your wave comes.",
                                                    view=signup_view() if SIGNUP_MODE != "waves" else None,
                                                    ephemeral=True)
            return
        if lockdown():
            await interaction.response.send_message(say("lockdown"), ephemeral=True)
            return
        con = db()
        row = member_row(con, member.id)
        if time.time() < (row[7] or 0):
            await interaction.response.send_message(
                f"Almost! Give it a moment and try again <t:{int(row[7])}:R>. 🙂", ephemeral=True)
            return
        old_enough = member.created_at + dt.timedelta(days=MIN_AGE_DAYS)
        if MIN_AGE_DAYS > 0 and dt.datetime.now(dt.timezone.utc) < old_enough:
            await interaction.response.send_message(say(
                "too_fresh", made=f"<t:{int(member.created_at.timestamp())}:R>", days=f"{MIN_AGE_DAYS:g}",
                when=f"<t:{int(old_enough.timestamp())}:f>"), ephemeral=True)
            await gatelog(guild, f"🐣 {member.mention} ({member.name}) tried the gate with a "
                                 f"{(dt.datetime.now(dt.timezone.utc) - member.created_at).days}-day-old account")
            return
        view = Challenge(member.id)
        await interaction.response.send_message(f"{say('gate_intro')}\n\n**{view.question}**", view=view,
                                                ephemeral=True)

    class Gate(discord.ui.View):
        def __init__(self):
            super().__init__(timeout=None)

        @discord.ui.button(label="Enter the gate", style=discord.ButtonStyle.success, custom_id=GATE_ID, emoji="⚔")
        async def gate(self, interaction, _button):
            await enter_gate(interaction)

    class LegacyAccess(discord.ui.View):  # old "Get access" posts keep working until they're replaced
        def __init__(self):
            super().__init__(timeout=None)

        @discord.ui.button(label="Get access", style=discord.ButtonStyle.success, custom_id=LEGACY_ACCESS_ID)
        async def access(self, interaction, _button):
            await enter_gate(interaction)

    # ---------------------------------------------------------------- faction / class picker
    async def swap_role(interaction, pick, group, label):
        """Give `pick`, remove the others in `group` (one faction, one main class)."""
        member, guild = interaction.user, interaction.guild
        if not past_gate(member):
            await interaction.response.send_message(say("need_gate"), ephemeral=True)
            return
        want = discord.utils.get(guild.roles, name=pick)
        if want is None:
            await interaction.response.send_message("That role doesn't exist yet; tell a staff member.", ephemeral=True)
            return
        drop = [r for r in member.roles if r.name in group and r.name != pick]
        if want in member.roles and not drop:
            await interaction.response.send_message(f"You're already **{pick}**.", ephemeral=True)
            return
        await safe_roles(member, add=[want], remove=drop, reason=f"Picked {pick}")
        await interaction.response.send_message(f"{label} set to **{pick}**. Change it any time here.",
                                                ephemeral=True)
        schedule_feed()

    class FactionButton(discord.ui.Button):
        def __init__(self, name, emoji):
            super().__init__(label=name, emoji=emoji, custom_id=f"openvanilla:faction:{name}", row=0,
                             style=discord.ButtonStyle.primary if name == "Alliance" else discord.ButtonStyle.danger)

        async def callback(self, interaction):
            await swap_role(interaction, self.label, {f for f, _ in FACTIONS}, "Faction")

    class ClassSelect(discord.ui.Select):
        def __init__(self):
            super().__init__(custom_id="openvanilla:class", placeholder="Choose your main class…", row=1,
                             options=[discord.SelectOption(label=n, emoji=e, value=n) for n, e in CLASSES])

        async def callback(self, interaction):
            await swap_role(interaction, self.values[0], {c for c, _ in CLASSES}, "Main class")

    class RolePicker(discord.ui.View):
        def __init__(self):
            super().__init__(timeout=None)
            for n, e in FACTIONS:
                self.add_item(FactionButton(n, e))
            self.add_item(ClassSelect())

    # ---------------------------------------------------------------- the bot
    class Herald(discord.Client):
        def __init__(self):
            self.extra_events = {}         # add_listener (below), before anything can dispatch
            super().__init__(intents=intents, allowed_mentions=NONE)
            self.tree = app_commands.CommandTree(self)
            self.ready_once = False

        # The desks add their own handlers (herald_mod: DM appeals, herald_bridge: #world). discord.Client
        # has no add_listener (only commands.Bot), so Herald carries the same small mechanism: every
        # listener added for an event runs, none replaces another.
        def add_listener(self, func, name=None):
            self.extra_events.setdefault(name or func.__name__, []).append(func)

        def dispatch(self, event_name, /, *args, **kwargs):
            super().dispatch(event_name, *args, **kwargs)
            ev = "on_" + event_name
            for fn in self.extra_events.get(ev, []):
                self._schedule_event(fn, ev, *args, **kwargs)

        async def setup_hook(self):
            self.add_view(Gate())          # answers the welcome buttons and menu, across restarts
            self.add_view(LegacyAccess())
            self.add_view(RolePicker())
            self.tree.copy_global_to(guild=guild_obj)
            await self.tree.sync(guild=guild_obj)
            watch.start()
            housekeeping.start()
            if support:
                support.start()
            if moddesk:
                moddesk.start()
            if bridge:
                bridge.start()
            if livemarks:
                livemarks.start()
            if art:
                art.start()

    bot = Herald()

    # ---------------------------------------------------------------- the support desk (herald_support.py)
    # In-game tickets -> #support-queue and the owner's DMs, with one-click fixes on the realm.
    support = None
    try:
        sys.path.insert(0, HERE)
        import herald_support
        support = herald_support.install(bot, discord, db, chan, is_staff, gid, staff_roles=tuple(STAFF_ROLES))
    except ImportError as e:
        print(f"[support] desk off: {e} (pip install pymysql, and keep herald_support.py beside herald.py)")

    # ---------------------------------------------------------------- moderation (herald_mod.py)
    # Player reports -> triage -> #moderation cards and the staff dashboard (127.0.0.1:8787/mod/).
    moddesk = None
    try:
        import herald_mod
        moddesk = herald_mod.install(bot, discord, db, chan, is_staff, gid, staff_roles=tuple(STAFF_ROLES))
    except ImportError as e:
        print(f"[mod] moderation desk off: {e} (keep herald_mod.py beside herald.py)")

    # ---------------------------------------------------------------- the World bridge (herald_bridge.py)
    # #world <-> the in-game World channel, and guild chats linked by their officers (docs/DISCORD_BRIDGE.md).
    bridge = None
    try:
        import herald_bridge
        if herald_bridge.enabled():
            bridge = herald_bridge.install(bot, discord, db, chan, is_staff, gid)
    except ImportError as e:
        print(f"[bridge] World bridge off: {e} (pip install pymysql, and keep herald_bridge.py beside herald.py)")

    # ---------------------------------------------------------------- in-game LIVE marks (herald_streams.py)
    # Pushes ".wnl livestreamers Name;Name" over SOAP every 5 min from streams.json (tools/streams_fetch.py).
    livemarks = None
    try:
        import herald_streams
        if herald_streams.enabled():
            livemarks = herald_streams.install(bot, path=setting("STREAMS_JSON", os.path.join(PUBLIC_DIR, "streams.json")))
    except ImportError as e:
        print(f"[streams] LIVE marks off: {e} (keep herald_streams.py beside herald.py)")

    # ---------------------------------------------------------------- live art (herald_art.py)
    # A changed image in bot/discord_assets (or at ART_URL) replaces the one in Discord, in place.
    art = None
    try:
        import herald_art
        if herald_art.enabled():
            art = herald_art.install(bot, discord, chan, is_staff, gid)
    except ImportError as e:
        print(f"[art] live art off: {e} (keep herald_art.py beside herald.py)")

    # ---------------------------------------------------------------- arrivals: Outsider in, Adventurer out
    @bot.event
    async def on_member_join(member):
        if member.bot or member.guild.id != int(gid):
            return
        guild, con, now = member.guild, db(), time.time()
        state["joins"].append(now)
        await check_raid(guild)
        row = member_row(con, member.id)
        if ADVENTURER in names(member):  # joined from the website's Sign in with Discord (open sign-up, patch 0021)
            await promote(member)
            return
        if row[3]:  # had a realm account before: restore it (still subject to the raid shield)
            if not lockdown():
                await safe_roles(member, add=[role(guild, ADVENTURER)], reason="Returning adventurer")
                try:
                    await member.send(say("welcome_back", name=member.display_name))
                except discord.HTTPException:
                    pass
                await gatelog(guild, f"↩ {member.mention} ({member.name}) came back: Adventurer #{row[4]} restored")
                return
        con.execute("UPDATE members SET outsider_since=?, name=? WHERE discord_id=?",
                    (now, member.display_name, member.id))
        con.commit()
        await safe_roles(member, add=[role(guild, OUTSIDER)], reason="New arrival: hasn't passed the gate")

    @bot.event
    async def on_member_update(before, after):
        if after.guild.id != int(gid) or after.bot:
            return
        if ADVENTURER in names(after) and ADVENTURER not in names(before):
            await promote(after)

    async def promote(member, announce=True):
        """A realm account appeared (the realm granted Adventurer, or /promote). Open the Hall."""
        guild, con = member.guild, db()
        row = member_row(con, member.id)
        await safe_roles(member, remove=[role(guild, OUTSIDER), role(guild, RECRUIT), role(guild, "Waitlist")],
                         reason="Has a realm account")
        if row[3]:  # already counted (role re-granted after a rejoin, or a restart)
            return
        n = (con.execute("SELECT MAX(number) FROM members").fetchone()[0] or 0) + 1
        now = time.time()
        con.execute("UPDATE members SET account=?, number=?, name=?, verified=COALESCE(verified, ?) "
                    "WHERE discord_id=?", (now, n, member.display_name, now, member.id))
        con.execute("UPDATE waitlist SET invited=COALESCE(invited, ?) WHERE discord_id=?", (now, member.id))
        con.commit()
        trail = TRAIL_LIMIT and n <= TRAIL_LIMIT and role(guild, TRAILBLAZER)
        if trail:
            await safe_roles(member, add=[role(guild, TRAILBLAZER)], reason=f"Adventurer #{n}")
        if announce:
            ch = chan(guild, "arrivals")
            if ch:
                rn = names(member)
                bits = [c for c, _ in CLASSES if c in rn] + [f for f, _ in FACTIONS if f in rn]
                tail = (f" ({' · '.join(bits)})" if bits else "") + (
                    VOICE["trailblazer"].format(limit=TRAIL_LIMIT) if trail else "")
                try:
                    await ch.send(say("arrival", who=member.mention, n=n, tail=tail), silent=True,
                                  allowed_mentions=NONE)
                except discord.HTTPException:
                    pass
            try:
                await member.send(say("welcome_dm", name=member.display_name, realm=REALM_URL, site=SITE, n=n,
                                      trail=" You're also a **Trailblazer**, one of the first "
                                            f"{TRAIL_LIMIT}, forever." if trail else ""))
            except discord.HTTPException:
                pass
            await gatelog(guild, f"🏰 {member.mention} ({member.name}) made a realm account: Adventurer #{n}")
        schedule_feed()

    # ---------------------------------------------------------------- raid shield
    async def check_raid(guild):
        now = time.time()
        recent = [t for t in state["joins"] if now - t <= RAID_WINDOW]
        if len(recent) < RAID_JOINS:
            return
        was = lockdown()
        state["lockdown_until"] = now + RAID_COOLDOWN * 60  # every further join keeps it up
        if was:
            return
        await raise_shield(guild, f"{len(recent)} joins in {RAID_WINDOW} seconds")

    async def raise_shield(guild, why):
        try:
            if state["raid_level"] is None:
                state["raid_level"] = guild.verification_level
            await guild.edit(verification_level=discord.VerificationLevel.highest, reason=f"Raid shield: {why}")
        except discord.HTTPException as e:
            print(f"[raid] could not raise verification: {e}")
        try:  # Discord's own incident actions: pause new invites and member-to-member DMs while it lasts
            until = dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=max(RAID_COOLDOWN, 15))
            await guild.edit(invites_disabled_until=until, dms_disabled_until=until, reason=f"Raid shield: {why}")
        except (TypeError, discord.HTTPException) as e:  # TypeError: discord.py older than 2.4
            print(f"[raid] could not pause invites/DMs: {e}")
        alerts = chan(guild, "alerts")
        if alerts:
            staff = " ".join(r.mention for r in guild.roles if r.name in STAFF_ROLES)
            n = len([t for t in state["joins"] if time.time() - t <= RAID_WINDOW])
            await alerts.send(f"{staff}\n" + say("raid_on", n=n, secs=RAID_WINDOW, mins=RAID_COOLDOWN),
                              allowed_mentions=discord.AllowedMentions(roles=True))
        await gatelog(guild, f"🚨 Raid shield up: {why}")

    async def lower_shield(guild):
        state["lockdown_until"] = 0.0
        try:
            await guild.edit(verification_level=state["raid_level"] or discord.VerificationLevel.medium,
                             reason="Raid shield down")
        except discord.HTTPException:
            pass
        try:
            await guild.edit(invites_disabled_until=None, dms_disabled_until=None, reason="Raid shield down")
        except (TypeError, discord.HTTPException):
            pass
        state["raid_level"] = None
        alerts = chan(guild, "alerts")
        if alerts:
            await alerts.send(say("raid_off"), silent=True)

    # ---------------------------------------------------------------- the public sign-up feed
    feed_pending = {"task": None}

    def schedule_feed():
        """Coalesce bursts of changes into one write a few seconds later."""
        if feed_pending["task"] and not feed_pending["task"].done():
            return
        async def later():
            await asyncio.sleep(5)
            await write_feed()
        feed_pending["task"] = asyncio.get_running_loop().create_task(later())

    def census(guild):
        adv = [m for m in guild.members if not m.bot and ADVENTURER in names(m)]
        fac = {f: sum(1 for m in adv if f in names(m)) for f, _ in FACTIONS}
        cls = {c: sum(1 for m in adv if c in names(m)) for c, _ in CLASSES}
        recruits = sum(1 for m in guild.members if not m.bot and RECRUIT in names(m) and ADVENTURER not in names(m))
        return adv, fac, cls, recruits

    async def write_feed():
        guild = bot.get_guild(int(gid))
        if not guild:
            return
        con, now = db(), time.time()
        adv, fac, cls, recruits = census(guild)
        recent = []
        for uid, name, acct, n, shown in con.execute(
                "SELECT discord_id,name,account,number,shown FROM members WHERE account IS NOT NULL "
                "ORDER BY account DESC LIMIT 12"):
            m = guild.get_member(uid)
            rn = names(m) if m else set()
            entry = {"n": n, "at": iso(acct),
                     "faction": next((f for f, _ in FACTIONS if f in rn), None),
                     "class": next((c for c, _ in CLASSES if c in rn), None),
                     "trailblazer": TRAILBLAZER in rn}
            if not shown or not m:
                entry.update(name="A new adventurer", avatar=None)
            else:
                entry.update(name=m.display_name, avatar=str(m.display_avatar.with_size(64).url))
            recent.append(entry)
        day = con.execute("SELECT COUNT(*) FROM members WHERE account>?", (now - 86400,)).fetchone()[0]
        week = con.execute("SELECT COUNT(*) FROM members WHERE account>?", (now - 7 * 86400,)).fetchone()[0]
        members_n, online_n = state["counts"]
        data = {
            "updated": iso(now),
            "realm": {"name": "Vanilla Remastered", "online": bool(state["up"]), "url": REALM_URL,
                      "players": state.get("players"),
                      "signups": SIGNUP_MODE},
            "stats": {"adventurers": len(adv), "recruits": recruits, "today": day, "week": week,
                      "discord_members": members_n or guild.member_count, "discord_online": online_n},
            "factions": fac, "classes": cls, "recent": recent,
        }
        try:
            await asyncio.to_thread(write_json_atomic, os.path.join(PUBLIC_DIR, "feed.json"), data)
        except OSError as e:
            print(f"[feed] {e}")

    # ---------------------------------------------------------------- slash commands
    @bot.tree.command(description="Is the realm up?")
    async def status(interaction: discord.Interaction):
        up = await asyncio.to_thread(realm_up)
        await interaction.response.send_message(
            f"Vanilla Remastered is **{'online 🟢' if up else 'offline 🔴'}**. {REALM_URL}", ephemeral=True)

    @bot.tree.command(name="census", description="Alliance or Horde? How many adventurers? The Herald's census")
    async def census_cmd(interaction: discord.Interaction):
        adv, fac, cls, recruits = census(interaction.guild)
        a, h = fac["Alliance"], fac["Horde"]
        total = max(1, a + h)
        bar = "🟦" * round(10 * a / total) + "🟥" * (10 - round(10 * a / total)) if a + h else "⬛" * 10
        e = discord.Embed(title="📜 The Herald's Census", colour=0xC9A227,
                          description=f"**{len(adv)}** adventurers · **{recruits}** recruits at the gate")
        e.add_field(name=f"🛡 Alliance {a}  ·  Horde {h} 🪓", value=bar, inline=False)
        top = sorted(((n, c) for c, n in cls.items() if n), reverse=True)
        e.add_field(name="Classes", value=" · ".join(f"{c} {n}" for n, c in top) or "Nobody has picked yet.",
                    inline=False)
        await interaction.response.send_message(embed=e, ephemeral=True)

    @bot.tree.command(name="herald", description="Ask the Herald to proclaim something")
    async def herald_cmd(interaction: discord.Interaction):
        adv, fac, _cls, _r = census(interaction.guild)
        await interaction.response.send_message(say("proclaim", adv=len(adv), a=fac["Alliance"], h=fac["Horde"]))

    @bot.tree.command(description="Show or hide yourself on the website's new-adventurer feed")
    @app_commands.describe(choice="show or hide")
    @app_commands.choices(choice=[app_commands.Choice(name="show", value="show"),
                                  app_commands.Choice(name="hide", value="hide")])
    async def feed(interaction: discord.Interaction, choice: app_commands.Choice[str]):
        con = db()
        member_row(con, interaction.user.id)
        con.execute("UPDATE members SET shown=? WHERE discord_id=?", (choice.value == "show", interaction.user.id))
        con.commit()
        schedule_feed()
        await interaction.response.send_message(
            "Done: the website feed shows you as *A new adventurer*." if choice.value == "hide" else
            "Done: the website feed shows your name and avatar.", ephemeral=True)

    @bot.tree.command(description="Your place in line for the next wave")
    async def waitlist(interaction: discord.Interaction):
        if SIGNUP_MODE != "waves":
            await interaction.response.send_message(
                "There's no line right now: pass the gate in welcome, then create your account.", ephemeral=True)
            return
        n = place(db(), interaction.user.id)
        await interaction.response.send_message(f"You're **#{n}** in line." if n else
                                                "You're not waiting: you're already in, or press **Enter the gate** "
                                                "in welcome.", ephemeral=True)

    @bot.tree.command(description="Staff: let the next players in (SIGNUP_MODE=waves)")
    @app_commands.describe(count="How many players to invite (1-500)")
    @app_commands.default_permissions(manage_roles=True)
    async def wave(interaction: discord.Interaction, count: app_commands.Range[int, 1, 500]):
        if not is_staff(interaction.user):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True, thinking=True)
        guild, con = interaction.guild, db()
        tester = role(guild, "Alpha Tester")
        wave_no = (con.execute("SELECT MAX(wave) FROM waitlist").fetchone()[0] or 0) + 1
        rows = con.execute("SELECT discord_id,name FROM waitlist WHERE invited IS NULL ORDER BY joined LIMIT ?",
                           (count,)).fetchall()
        invited, gone, no_dm = [], 0, 0
        for uid, _name in rows:
            try:
                member = guild.get_member(uid) or await guild.fetch_member(uid)
            except discord.NotFound:  # left the server: skip, keep their place for if they come back
                gone += 1
                continue
            await safe_roles(member, add=[tester], reason=f"Wave {wave_no}")
            con.execute("UPDATE waitlist SET wave=?, invited=? WHERE discord_id=?", (wave_no, time.time(), uid))
            invited.append(member)
            try:
                await member.send(say("wave_dm", name=member.display_name, wave=wave_no, realm=REALM_URL, site=SITE))
            except discord.HTTPException:
                no_dm += 1
            await asyncio.sleep(0.4)  # stay well under Discord's rate limits
        con.commit()
        log = chan(guild, "waves")
        if log and invited:
            lines = "\n".join(f"• {m.mention} ({m.name})" for m in invited)
            for i in range(0, len(lines), 1800):
                await log.send((f"**Wave {wave_no}: {len(invited)} invited.** They can sign in with Discord now:\n"
                                if i == 0 else "") + lines[i:i + 1800], allowed_mentions=NONE)
        await interaction.followup.send(
            f"Wave {wave_no}: invited {len(invited)}, {gone} had left the server, {no_dm} had DMs closed.",
            ephemeral=True)

    @bot.tree.command(name="lockdown", description="Staff: bar or open the gate (raid shield)")
    @app_commands.describe(state_="on: bar the gate and raise verification · off: open it again")
    @app_commands.rename(state_="state")
    @app_commands.choices(state_=[app_commands.Choice(name="on", value="on"),
                                  app_commands.Choice(name="off", value="off")])
    @app_commands.default_permissions(manage_guild=True)
    async def lockdown_cmd(interaction: discord.Interaction, state_: app_commands.Choice[str]):
        if not is_staff(interaction.user):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True)
        if state_.value == "on":
            state["lockdown_until"] = time.time() + 24 * 3600
            await raise_shield(interaction.guild, f"by {interaction.user} (manual, up to 24 h)")
            await interaction.followup.send("Gate barred. `/lockdown off` opens it.", ephemeral=True)
        else:
            await lower_shield(interaction.guild)
            await interaction.followup.send("Gate open.", ephemeral=True)

    @bot.tree.command(name="promote", description="Staff: mark someone as having a realm account (full access)")
    @app_commands.default_permissions(manage_roles=True)
    async def promote_cmd(interaction: discord.Interaction, member: discord.Member):
        if not is_staff(interaction.user):
            await interaction.response.send_message("Staff only.", ephemeral=True)
            return
        adv = role(interaction.guild, ADVENTURER)
        if adv in member.roles:
            await promote(member, announce=False)  # tidies leftover Outsider/Recruit roles
            await interaction.response.send_message(f"{member.mention} is already an Adventurer.", ephemeral=True)
            return
        await safe_roles(member, add=[adv], reason=f"/promote by {interaction.user}")  # on_member_update does the rest
        await interaction.response.send_message(f"{member.mention} is now an Adventurer.", ephemeral=True)

    # ---------------------------------------------------------------- loops
    @tasks.loop(seconds=60)
    async def watch():
        guild = bot.get_guild(int(gid))
        if not guild:
            return
        if state["lockdown_until"] and not lockdown():
            await lower_shield(guild)
        up = await asyncio.to_thread(realm_up)
        if up != state["up"]:
            if state["up"] is not None:
                alerts = chan(guild, "alerts")
                staff = " ".join(r.mention for r in guild.roles if r.name in STAFF_ROLES)
                if alerts:
                    await alerts.send(say("realm_down", staff=staff, realm=REALM_URL) if not up else
                                      say("realm_up", mins=int((time.time() - state["since"]) // 60)),
                                      allowed_mentions=discord.AllowedMentions(roles=True))
            state["up"], state["since"] = up, time.time()
        state["players"] = (await asyncio.to_thread(players_online)) if up else 0
        adv, fac, _cls, recruits = census(guild)
        mins = int((time.time() - state["since"]) // 60)
        lasted = f"{mins // 60} h {mins % 60} min" if mins >= 60 else f"{mins} min"
        headline = "🟢 **Online**" if up else "🔴 **Offline**, we're on it"
        embed = discord.Embed(
            title="Vanilla Remastered", description=f"{headline} for {lasted}",
            colour=0x2ECC71 if up else 0xE74C3C, timestamp=dt.datetime.now(dt.timezone.utc))
        embed.add_field(name="Play", value=f"[Browser]({REALM_URL}) · [Launcher]({SITE})")
        if state.get("players") is not None:
            embed.add_field(name="Players online", value=str(state["players"]))
        embed.add_field(name="Adventurers", value=f"{len(adv)} · 🛡 {fac['Alliance']} / 🪓 {fac['Horde']}")
        if SIGNUP_MODE == "waves":
            waiting = db().execute("SELECT COUNT(*) FROM waitlist WHERE invited IS NULL").fetchone()[0]
            embed.add_field(name="Waitlist", value=f"{waiting} waiting")
        if lockdown():
            embed.add_field(name="Gate", value="🛡 Barred (raid shield)", inline=False)
        embed.set_footer(text="The Herald checks every minute")
        ch = chan(guild, "server-status")
        if not ch:
            return
        msg = state["status_msg"]
        if msg is None:
            async for m in ch.history(limit=30):  # our live post, not the pinned info post
                if m.author.id == bot.user.id and m.embeds and m.embeds[0].title == "Vanilla Remastered":
                    msg = m
                    break
        try:
            state["status_msg"] = await msg.edit(embed=embed) if msg else await ch.send(embed=embed, silent=True)
        except discord.HTTPException:
            state["status_msg"] = None

    @watch.before_loop
    async def _wait_ready():
        await bot.wait_until_ready()

    @tasks.loop(minutes=5)
    async def housekeeping():
        guild = bot.get_guild(int(gid))
        if not guild:
            return
        try:
            g = await bot.fetch_guild(int(gid), with_counts=True)
            state["counts"] = (g.approximate_member_count, g.approximate_presence_count)
        except discord.HTTPException:
            pass
        adv, *_ = census(guild)
        await bot.change_presence(activity=discord.Activity(
            type=discord.ActivityType.watching, name=random.choice(VOICE["presence"]).format(adv=len(adv))))
        await prune(guild)
        await write_feed()

    @housekeeping.before_loop
    async def _wait_ready2():
        await bot.wait_until_ready()

    async def prune(guild):
        """Show out Outsiders who never passed the gate (bots, raiders, the merely curious)."""
        if GATE_TIMEOUT_H <= 0 or lockdown():
            return
        outsider, con, now = role(guild, OUTSIDER), db(), time.time()
        if not outsider:
            return
        shown_out = 0
        for m in list(outsider.members):
            if m.bot or is_staff(m) or any(r.name not in (OUTSIDER, "@everyone") for r in m.roles):
                continue
            since = member_row(con, m.id)[1]
            if since is None:  # was an Outsider before Herald knew: start their clock now
                con.execute("UPDATE members SET outsider_since=? WHERE discord_id=?", (now, m.id))
                continue
            if now - since < GATE_TIMEOUT_H * 3600:
                continue
            try:
                await m.send(say("prune_dm", hours=f"{GATE_TIMEOUT_H:g}",
                                 invite=f": {INVITE_URL}" if INVITE_URL else ""))
            except discord.HTTPException:
                pass
            try:
                await m.kick(reason=f"Didn't pass the gate within {GATE_TIMEOUT_H:g} h")
                shown_out += 1
                con.execute("UPDATE members SET outsider_since=NULL WHERE discord_id=?", (m.id,))
            except discord.HTTPException as e:
                print(f"[prune] {m}: {e}")
            await asyncio.sleep(1)
            if shown_out >= 25:  # a few at a time
                break
        con.commit()
        if shown_out:
            await gatelog(guild, f"🧹 Showed out {shown_out} Outsider(s) who never passed the gate")

    @bot.event
    async def on_ready():
        print(f"Herald online as {bot.user} · realm {REALM_URL} · sign-ups: {SIGNUP_MODE}")
        if bot.ready_once:
            return
        bot.ready_once = True
        guild = bot.get_guild(int(gid))
        if not guild:
            print(f"!! The bot isn't in server {gid}.")
            return
        # Catch up on what happened while Herald was away, without announcing anybody.
        con, now = db(), time.time()
        outsider = role(guild, OUTSIDER)
        for m in guild.members:
            if m.bot:
                continue
            if ADVENTURER in names(m):
                row = member_row(con, m.id)
                if not row[3]:
                    await promote(m, announce=False)
                elif names(m) & {OUTSIDER, RECRUIT, "Waitlist"}:
                    await safe_roles(m, remove=[outsider, role(guild, RECRUIT), role(guild, "Waitlist")],
                                     reason="Has a realm account")
            elif not past_gate(m) and outsider and outsider not in m.roles:
                member_row(con, m.id)
                con.execute("UPDATE members SET outsider_since=COALESCE(outsider_since, ?) WHERE discord_id=?",
                            (now, m.id))
                await safe_roles(m, add=[outsider], reason="Hasn't passed the gate")
        con.commit()
        await write_feed()

    HOOKS.update(bot=bot, Gate=Gate, RolePicker=RolePicker, enter_gate=enter_gate, answered=answered,
                 promote=promote, write_feed=write_feed, prune=prune, state=state, on_ready=on_ready)

    import logging.handlers
    handler = logging.handlers.RotatingFileHandler(os.path.join(os.path.dirname(DB), "herald.log"),
                                                   maxBytes=1_000_000, backupCount=3, encoding="utf-8")
    try:
        bot.run(token, log_handler=handler, log_level=logging.INFO)
    except discord.PrivilegedIntentsRequired:
        sys.exit("Discord refused the Server Members Intent. Turn it on: discord.com/developers/applications -> "
                 "your app -> Bot -> Privileged Gateway Intents -> SERVER MEMBERS INTENT (and MESSAGE CONTENT INTENT for "
                 "the World bridge, or set BRIDGE_ENABLED=0), save, and start Herald again.")


if __name__ == "__main__":
    for _st in (sys.stdout, sys.stderr):
        try:
            _st.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    main()
