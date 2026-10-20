"""Herald's support desk: in-game tickets -> Discord, with one-click fixes.

A player opens a ticket in game (the Help button, "Talk to a GM"). Within half a minute Herald:
  * posts it in #support-queue (staff only) as a card: who, where, what they wrote, and what Herald
    thinks it is (stuck, dead, talents, a bug...) with buttons:
        Unstuck · Revive · Reset talents · Reply… · Log bug · Ignore
  * DMs the owner the same card (SUPPORT_DM_OWNER=1), so you can run support from your phone.
Buttons do the fix on the realm (the world server's console, SOAP), mail the player a short note,
and close the ticket in game. Actions in OWNER_APPROVAL (default: Reset talents) need the owner: when
other staff press them, Herald DMs you an Approve / Deny and waits.

Settings (/etc/openvanilla-herald.env; hetzner/herald_up.sh writes the server ones):
  OWNER_DISCORD_ID        your Discord user id (approvals and the DM feed)
  SUPPORT_CHANNEL=support-queue
  SUPPORT_DM_OWNER=1      also DM the owner every new ticket
  OWNER_APPROVAL=talents  comma list of actions only the owner may run (talents, revive, unstuck, reply, bug)
  AUTO_UNSTUCK=0          1: tickets that clearly say "stuck" are fixed straight away (the card says so)
  TICKET_POLL_SEC=30
  SUPPORT_DB_HOST, SUPPORT_DB_PORT, SUPPORT_DB_USER, SUPPORT_DB_PASS, CHARACTERS_DATABASE=classiccharacters
  SOAP_URL=http://127.0.0.1:17878/, SOAP_USER, SOAP_PASS   a GM-3 console account
  GITHUB_TOKEN, GITHUB_REPO=orionopenwow/OpenVanilla             optional: Log bug opens a GitHub issue
"""
import asyncio
import base64
import json
import os
import re
import time
import urllib.request

ACTIONS = {
    "unstuck": ("Unstuck", "🧭", "sent back to their hearthstone"),
    "revive": ("Revive", "✨", "revived"),
    "talents": ("Reset talents", "📜", "had their talents reset"),
    "reply": ("Reply…", "✉", "got a reply"),
    "bug": ("Log bug", "🐞", "logged as a bug"),
    "ignore": ("Ignore", "🗑", "closed without action"),
}
TRIAGE = [
    ("unstuck", r"\b(stuck|can'?t move|cannot move|fell (through|under)|under ?the ?(world|map)|trapped|inside a wall)\b"),
    ("revive", r"\b(dead|ghost|corpse|spirit healer|can'?t (res|resurrect)|died)\b"),
    ("talents", r"\b(talents?|respec|reset (my )?points)\b"),
    ("bug", r"\b(bug|broken|error|crash|doesn'?t work|not working|glitch|missing)\b"),
]
NAME_RE = re.compile(r"^[^\W\d_]{2,12}$", re.UNICODE)


def env(name, default=""):
    v = os.environ.get(name, "").strip()
    return v if v else default


def triage(text):
    t = (text or "").lower()
    for act, rx in TRIAGE:
        if re.search(rx, t):
            return act
    return None


def clean(text, n=400):
    """Text that is safe inside a quoted console argument."""
    t = re.sub(r"[\"\\\r\n\t]", " ", str(text or ""))
    return re.sub(r"\s+", " ", t).strip()[:n]


# ----------------------------------------------------------------------------------------- the realm
class Realm:
    """The characters database (tickets) and the world server's console (fixes)."""

    def __init__(self):
        self.db = dict(host=env("SUPPORT_DB_HOST", "127.0.0.1"), port=int(env("SUPPORT_DB_PORT", "13306")),
                       user=env("SUPPORT_DB_USER", "herald"), password=env("SUPPORT_DB_PASS"),
                       database=env("CHARACTERS_DATABASE", "classiccharacters"), connect_timeout=8, autocommit=True)
        self.soap = (env("SOAP_URL", "http://127.0.0.1:17878/"), env("SOAP_USER"), env("SOAP_PASS"))
        self.schema = None

    def connect(self):
        import pymysql
        return pymysql.connect(**self.db)

    def detect(self, con):
        """CMaNGOS has used two ticket tables; work with whichever this realm has."""
        cur = con.cursor()
        cur.execute("SELECT table_name, column_name FROM information_schema.columns WHERE table_schema=DATABASE() "
                    "AND table_name IN ('gm_tickets','character_ticket')")
        cols = {}
        for t, c in cur.fetchall():
            cols.setdefault(t, set()).add(c.lower())
        if "gm_tickets" in cols:
            c = cols["gm_tickets"]
            pick = lambda *names: next((n for n in names if n in c), None)
            s = dict(table="gm_tickets", id=pick("id", "ticket_id", "guid"), guid=pick("author_guid", "guid", "player_guid"),
                     name=pick("author_name", "name"), text=pick("text", "message", "ticket_text"),
                     created=pick("created", "createtime", "timestamp", "ticket_lastchange"),
                     closed=pick("closed", "closedby", "resolved", "completed"),
                     map=pick("mapid", "map"), x=pick("x", "position_x"), y=pick("y", "position_y"))
        elif "character_ticket" in cols:
            c = cols["character_ticket"]
            s = dict(table="character_ticket", id="ticket_id", guid="guid", name=None, text="ticket_text",
                     created="ticket_lastchange" if "ticket_lastchange" in c else None,
                     closed="resolved" if "resolved" in c else None, map=None, x=None, y=None)
        else:
            raise RuntimeError("no gm_tickets or character_ticket table in " + self.db["database"])
        self.schema = s
        return s

    def open_tickets(self):
        con = self.connect()
        try:
            s = self.schema or self.detect(con)
            cols = [f"t.`{s['id']}`", f"t.`{s['text']}`", f"t.`{s['guid']}`"]
            cols.append(f"t.`{s['name']}`" if s["name"] else "c.name")
            cols.append(f"t.`{s['created']}`" if s["created"] else "NULL")
            cols += [f"t.`{s[k]}`" if s[k] else "NULL" for k in ("map", "x", "y")]
            cols += ["c.level", "c.race", "c.class", "c.online", "c.map", "c.zone"]
            where = f"WHERE (t.`{s['closed']}` IS NULL OR t.`{s['closed']}`=0)" if s["closed"] else ""
            sql = (f"SELECT {', '.join(cols)} FROM `{s['table']}` t LEFT JOIN characters c ON c.guid=t.`{s['guid']}` "
                   f"{where} ORDER BY t.`{s['id']}` LIMIT 200")
            cur = con.cursor()
            cur.execute(sql)
            out = []
            for r in cur.fetchall():
                out.append(dict(id=int(r[0]), text=r[1] or "", guid=r[2], name=r[3] or "?", created=r[4],
                                tmap=r[5], x=r[6], y=r[7], level=r[8], race=r[9], cls=r[10], online=r[11],
                                map=r[12], zone=r[13]))
            return out
        finally:
            con.close()

    def close_in_db(self, tid):
        con = self.connect()
        try:
            s = self.schema or self.detect(con)
            cur = con.cursor()
            if s["closed"]:
                cur.execute(f"UPDATE `{s['table']}` SET `{s['closed']}`=%s WHERE `{s['id']}`=%s", (int(time.time()), tid))
            else:
                cur.execute(f"DELETE FROM `{s['table']}` WHERE `{s['id']}`=%s", (tid,))
        finally:
            con.close()

    def console(self, command):
        url, user, pw = self.soap
        if not user:
            raise RuntimeError("SOAP_USER is not set")
        body = ('<?xml version="1.0" encoding="utf-8"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" '
                'xmlns:ns1="urn:MaNGOS"><SOAP-ENV:Body><ns1:executeCommand><command>'
                + command.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                + "</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>")
        req = urllib.request.Request(url, data=body.encode("utf-8"), method="POST", headers={
            "Content-Type": "text/xml", "Authorization": "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()})
        with urllib.request.urlopen(req, timeout=15) as r:  # nosec B310 - the realm's own console on localhost
            xml = r.read().decode("utf-8", "replace")
        m = re.search(r"<result>(.*?)</result>", xml, re.S)
        fault = re.search(r"<faultstring>(.*?)</faultstring>", xml, re.S)
        if fault:
            raise RuntimeError(fault.group(1).strip())
        return (m.group(1) if m else "").replace("&#xD;", "").strip()

    def close_ticket(self, tid):
        """Close it the way the world server knows about (it caches tickets), else in the database."""
        for cmd in (f".ticket close {tid}", f".delticket {tid}"):
            try:
                out = self.console(cmd)
                if out and not re.search(r"(no such|not found|unknown|incorrect|syntax|wrong)", out, re.I):
                    return
            except Exception:
                pass
        self.close_in_db(tid)

    def mail(self, name, subject, text):
        self.console(f'.send mail {name} "{clean(subject, 60)}" "{clean(text)}"')

    def run(self, act, name):
        if not NAME_RE.match(name or ""):
            raise RuntimeError(f"refusing an odd character name: {name!r}")
        if act == "unstuck":
            return self.console(f".tele name {name} $home")
        if act == "revive":
            return self.console(f".revive {name}")
        if act == "talents":
            return self.console(f".reset talents {name}")
        return ""


def github_issue(title, body):
    token, repo = env("GITHUB_TOKEN"), env("GITHUB_REPO", "orionopenwow/OpenVanilla")
    if not token:
        return None
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/issues", method="POST",
                                 data=json.dumps({"title": title[:120], "body": body, "labels": ["in-game report"]}).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                                          "User-Agent": "OpenVanilla-Herald"})
    with urllib.request.urlopen(req, timeout=15) as r:  # nosec B310 - fixed https host
        return json.loads(r.read().decode()).get("html_url")


# ----------------------------------------------------------------------------------------- Discord
RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
CLASSES = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}


def install(bot, discord, db, chan, is_staff, gid, staff_roles=("Founder", "Admin", "Developer", "Game Master", "Moderator")):
    """Wire the support desk into Herald. Returns an object whose start() begins the polling."""
    realm = Realm()
    owner_id = int(env("OWNER_DISCORD_ID", "0") or 0)
    channel_name = env("SUPPORT_CHANNEL", "support-queue")
    dm_owner = env("SUPPORT_DM_OWNER", "1") == "1"
    needs_owner = {a.strip() for a in env("OWNER_APPROVAL", "talents").split(",") if a.strip()}
    auto_unstuck = env("AUTO_UNSTUCK", "0") == "1"
    poll = max(10, int(env("TICKET_POLL_SEC", "30")))
    is_staff_role = lambda n: n in set(staff_roles)
    NONE = discord.AllowedMentions.none()

    con = db()
    con.execute("""CREATE TABLE IF NOT EXISTS support_tickets (
        ticket_id INTEGER PRIMARY KEY, name TEXT, text TEXT, suggested TEXT,
        channel_id INTEGER, message_id INTEGER, dm_message_id INTEGER,
        status TEXT DEFAULT 'open', outcome TEXT, created REAL, closed REAL)""")
    con.commit()

    def card(t, status="open", outcome=None, suggested=None):
        color = {"open": 0xF0C058, "done": 0x22C55E, "ignored": 0x64748B, "closed": 0x64748B, "waiting": 0xA855F7}.get(status, 0xF0C058)
        e = discord.Embed(title=f"Ticket #{t['id']} · {t['name']}", description=(t.get("text") or "")[:1500] or "*(no text)*", color=color)
        who = []
        if t.get("level"):
            who.append(f"Level {t['level']} {RACES.get(t.get('race'), '')} {CLASSES.get(t.get('cls'), '')}".strip())
        if t.get("online") is not None:
            who.append("🟢 online" if t.get("online") else "⚪ offline")
        if who:
            e.add_field(name="Character", value=" · ".join(who), inline=True)
        if t.get("map") is not None:
            e.add_field(name="Where", value=f"map {t['map']}, zone {t.get('zone')}", inline=True)
        if suggested:
            e.add_field(name="Herald thinks", value=f"{ACTIONS[suggested][1]} {ACTIONS[suggested][0].rstrip('…')}", inline=True)
        if outcome:
            e.add_field(name="Outcome", value=outcome[:1000], inline=False)
        e.set_footer(text="In-game ticket · " + ("waiting for the owner" if status == "waiting" else status))
        return e

    def buttons(tid, suggested=None, disabled=False):
        v = discord.ui.View(timeout=None)
        for i, (act, (label, emoji, _)) in enumerate(ACTIONS.items()):
            style = discord.ButtonStyle.success if act == suggested else (
                discord.ButtonStyle.danger if act == "ignore" else discord.ButtonStyle.secondary)
            v.add_item(discord.ui.Button(label=label, emoji=emoji, style=style, custom_id=f"tk:do:{tid}:{act}",
                                         disabled=disabled, row=0 if i < 4 else 1))
        return v

    async def owner_user():
        if not owner_id:
            return None
        return bot.get_user(owner_id) or await bot.fetch_user(owner_id)

    async def update_cards(tid, embed):
        con = db()
        row = con.execute("SELECT channel_id, message_id, dm_message_id FROM support_tickets WHERE ticket_id=?", (tid,)).fetchone()
        if not row:
            return
        targets = []
        if row[0] and row[1]:
            ch = bot.get_channel(row[0])
            if ch:
                targets.append((ch, row[1]))
        if row[2]:
            u = await owner_user()
            if u:
                targets.append((u.dm_channel or await u.create_dm(), row[2]))
        for ch, mid in targets:
            try:
                msg = await ch.fetch_message(mid)
                await msg.edit(embed=embed, view=None)
            except discord.HTTPException:
                pass

    async def perform(tid, act, by, reply_text=None):
        """Run an action for a ticket and close it. Returns a one-line outcome."""
        con = db()
        row = con.execute("SELECT name, text FROM support_tickets WHERE ticket_id=?", (tid,)).fetchone()
        if not row:
            return "I don't know that ticket any more."
        name, text = row
        outcome = f"{ACTIONS[act][1]} {name} {ACTIONS[act][2]} by {by}."
        if act in ("unstuck", "revive", "talents"):
            res = await asyncio.to_thread(realm.run, act, name)
            if res and re.search(r"(not found|no such|incorrect|can'?t|cannot)", res, re.I):
                return f"⚠ The realm said: {res[:200]}"
            await asyncio.to_thread(realm.mail, name, "Your ticket",
                                    {"unstuck": "You were stuck, so we sent you back to your hearthstone. Safe travels!",
                                     "revive": "We brought you back to life. Welcome back!",
                                     "talents": "Your talents have been reset; spend them again at no cost."}[act])
        elif act == "reply":
            await asyncio.to_thread(realm.mail, name, "Reply to your ticket", reply_text or "")
            outcome += f"\n> {clean(reply_text, 300)}"
        elif act == "bug":
            url = None
            try:
                url = await asyncio.to_thread(github_issue, f"[in game] {clean(text, 80)}",
                                              f"Reported in game by **{name}** (ticket #{tid}).\n\n> {clean(text, 1500)}")
            except Exception as e:
                outcome += f"\n(GitHub: {e})"
            if url:
                outcome += f"\n{url}"
            await asyncio.to_thread(realm.mail, name, "Thanks for the report",
                                    "Thanks! We've logged it for the team and will fix it in a coming update.")
        await asyncio.to_thread(realm.close_ticket, tid)
        con.execute("UPDATE support_tickets SET status=?, outcome=?, closed=? WHERE ticket_id=?",
                    ("ignored" if act == "ignore" else "done", outcome, time.time(), tid))
        con.commit()
        return outcome

    async def finish(tid, act, by, reply_text=None):
        try:
            outcome = await perform(tid, act, by, reply_text)
        except Exception as e:
            outcome = f"⚠ That didn't work: {e}"
            return outcome
        con = db()
        r = con.execute("SELECT name, text, suggested FROM support_tickets WHERE ticket_id=?", (tid,)).fetchone()
        t = {"id": tid, "name": r[0], "text": r[1]}
        await update_cards(tid, card(t, "ignored" if act == "ignore" else "done", outcome))
        return outcome

    async def ask_owner(tid, act, requester):
        u = await owner_user()
        if not u:
            return False
        v = discord.ui.View(timeout=None)
        v.add_item(discord.ui.Button(label="Approve", style=discord.ButtonStyle.success, custom_id=f"tk:ok:{tid}:{act}:{requester.id}"))
        v.add_item(discord.ui.Button(label="Deny", style=discord.ButtonStyle.danger, custom_id=f"tk:no:{tid}:{act}:{requester.id}"))
        con = db()
        r = con.execute("SELECT name, text FROM support_tickets WHERE ticket_id=?", (tid,)).fetchone()
        await u.send(f"🔐 **{requester.display_name}** wants to **{ACTIONS[act][0]}** for **{r[0]}** (ticket #{tid}).\n> {clean(r[1], 300)}",
                     view=v, allowed_mentions=NONE)
        return True

    class ReplyModal(discord.ui.Modal, title="Reply to the player"):
        message = discord.ui.TextInput(label="Your reply (sent by in-game mail)", style=discord.TextStyle.paragraph, max_length=400)

        def __init__(self, tid):
            super().__init__()
            self.tid = tid

        async def on_submit(self, interaction):
            await interaction.response.defer(ephemeral=True, thinking=True)
            out = await finish(self.tid, "reply", interaction.user.display_name, str(self.message.value))
            await interaction.followup.send(out, ephemeral=True)

    @bot.event
    async def on_interaction(interaction):
        cid = (interaction.data or {}).get("custom_id", "") if interaction.type == discord.InteractionType.component else ""
        if not cid.startswith("tk:"):
            return
        parts = cid.split(":")
        kind, tid, act = parts[1], int(parts[2]), parts[3]
        user = interaction.user
        is_owner = owner_id and user.id == owner_id
        member = interaction.guild.get_member(user.id) if interaction.guild else None
        if not (is_owner or (member and is_staff(member))):
            await interaction.response.send_message("Only staff can use these.", ephemeral=True)
            return
        if kind == "do":
            if act in needs_owner and not is_owner:
                ok = await ask_owner(tid, act, user)
                db().execute("UPDATE support_tickets SET status='waiting' WHERE ticket_id=?", (tid,))
                await interaction.response.send_message("Sent to the owner for approval." if ok else
                                                        "No owner is set (OWNER_DISCORD_ID), so I can't ask for approval.", ephemeral=True)
                return
            if act == "reply":
                await interaction.response.send_modal(ReplyModal(tid))
                return
            await interaction.response.defer(ephemeral=True, thinking=True)
            await interaction.followup.send(await finish(tid, act, user.display_name), ephemeral=True)
        elif kind in ("ok", "no") and is_owner:
            requester = parts[4] if len(parts) > 4 else "?"
            if kind == "no":
                db().execute("UPDATE support_tickets SET status='open' WHERE ticket_id=?", (tid,))
                await interaction.response.edit_message(content=interaction.message.content + "\n❌ Denied.", view=None)
                return
            if act == "reply":
                await interaction.response.send_modal(ReplyModal(tid))
                return
            await interaction.response.defer()
            out = await finish(tid, act, f"{user.display_name} (approved for <@{requester}>)")
            await interaction.message.edit(content=interaction.message.content + f"\n✅ Approved. {out}", view=None)

    async def post(t):
        guild = bot.get_guild(int(gid))
        suggested = triage(t["text"])
        con = db()
        con.execute("INSERT OR IGNORE INTO support_tickets(ticket_id, name, text, suggested, created) VALUES(?,?,?,?,?)",
                    (t["id"], t["name"], t["text"], suggested, time.time()))
        con.commit()
        ch = chan(guild, channel_name) if guild else None
        mid = dmid = None
        if ch:
            try:
                mid = (await ch.send(embed=card(t, suggested=suggested), view=buttons(t["id"], suggested), allowed_mentions=NONE)).id
            except discord.HTTPException as e:
                print(f"[support] post: {e}")
        if dm_owner:
            u = await owner_user()
            if u:
                try:
                    dmid = (await u.send(embed=card(t, suggested=suggested), view=buttons(t["id"], suggested))).id
                except discord.HTTPException:
                    pass
        con.execute("UPDATE support_tickets SET channel_id=?, message_id=?, dm_message_id=? WHERE ticket_id=?",
                    (ch.id if ch else None, mid, dmid, t["id"]))
        con.commit()
        if auto_unstuck and suggested == "unstuck" and "unstuck" not in needs_owner:
            await finish(t["id"], "unstuck", "Herald (automatic)")

    async def ensure_channel():
        """#support-queue, visible to staff only. Made once if it isn't there."""
        guild = bot.get_guild(int(gid))
        if not guild or chan(guild, channel_name):
            return
        over = {guild.default_role: discord.PermissionOverwrite(view_channel=False),
                guild.me: discord.PermissionOverwrite(view_channel=True, send_messages=True, embed_links=True)}
        for r in guild.roles:
            if is_staff_role(r.name):
                over[r] = discord.PermissionOverwrite(view_channel=True, send_messages=True)
        try:
            await guild.create_text_channel(channel_name, overwrites=over, topic="In-game tickets from Herald. Buttons fix them on the realm.")
        except discord.HTTPException as e:
            print(f"[support] can't make #{channel_name}: {e}")

    async def tick():
        try:
            tickets = await asyncio.to_thread(realm.open_tickets)
        except Exception as e:
            from herald_quiet import warn
            warn("support", "can't read tickets", e)
            return
        from herald_quiet import ok as recovered
        recovered("support", "can't read tickets")
        con = db()
        known = {r[0]: r[1] for r in con.execute("SELECT ticket_id, status FROM support_tickets")}
        open_ids = set()
        for t in tickets:
            open_ids.add(t["id"])
            if t["id"] not in known:
                await post(t)
        # closed in game (the player deleted it, or a GM handled it there)
        for tid, status in known.items():
            if status in ("open", "waiting") and tid not in open_ids:
                con.execute("UPDATE support_tickets SET status='closed', outcome='Closed in game.', closed=? WHERE ticket_id=?",
                            (time.time(), tid))
                con.commit()
                r = con.execute("SELECT name, text FROM support_tickets WHERE ticket_id=?", (tid,)).fetchone()
                await update_cards(tid, card({"id": tid, "name": r[0], "text": r[1]}, "closed", "Closed in game."))

    from discord import app_commands

    @bot.tree.command(name="tickets", description="Staff: open in-game tickets")
    @app_commands.default_permissions(manage_messages=True)
    async def tickets_cmd(interaction):
        con = db()
        rows = con.execute("SELECT ticket_id, name, status, suggested FROM support_tickets WHERE status IN ('open','waiting') ORDER BY ticket_id").fetchall()
        if not rows:
            await interaction.response.send_message("No open tickets. 🎉", ephemeral=True)
            return
        lines = [f"#{r[0]} · {r[1]} · {r[2]}" + (f" · looks like {ACTIONS[r[3]][0].rstrip('…').lower()}" if r[3] else "") for r in rows[:25]]
        await interaction.response.send_message(f"**{len(rows)} open** (cards in #{channel_name}):\n" + "\n".join(lines), ephemeral=True)

    class Desk:
        task = None

        def start(self):
            async def loop():
                await bot.wait_until_ready()
                await ensure_channel()
                while not bot.is_closed():
                    await tick()
                    await asyncio.sleep(poll)
            self.task = asyncio.get_event_loop().create_task(loop())

    return Desk()
