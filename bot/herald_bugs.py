"""Herald's bug desk: bug reports sent from the game go to the Discord #bug-reports forum.

The blue bug button by the chat (WenillaCore/Bugs.lua) sends ".wnl bug <category>,<text>,<context>";
the world server (realm/mangos/0014-openvanilla-bug-reports.patch) stores it, with who and where, in
classiccharacters.openvanilla_bug_report (realm/classicplus/classicplus_bugs.sql). Herald checks that
table every BUGS_POLL_SEC and makes one forum post per report, tagged by category, then marks the row
posted (posted = 1, discord_id = the post) so nothing is posted twice.

Settings (/etc/openvanilla-herald.env):
  BUGS_ENABLED=1          0 turns the desk off
  BUGS_CHANNEL=bug-reports  the forum (name, or the part after "│"); a text channel works too
  BUGS_POLL_SEC=15
  plus the support desk's SUPPORT_DB_* login (hetzner/herald_up.sh grants it SELECT, UPDATE on the table).
  BUGS_GITHUB_REPO=owner/repo  also open a GitHub issue per report (label bug-report), for fixing from there
  BUGS_GITHUB_TOKEN=...        a fine-grained token with Issues: read and write on that repo only
                               (hetzner/bugs_github.sh asks for it, hidden). The issue never fails the Discord post.
The account number never goes to Discord; the character name, level, class and place do.
"""
import asyncio
import os
import re
import time

CLASS_NAMES = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage",
               9: "Warlock", 11: "Druid"}
RACE_NAMES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
CATEGORY = {   # category -> (label, forum tag)
    "quest": ("Quest", "Quest"), "spell": ("Spell or ability", "Spell"), "addon": ("Addon or interface", "Addon"),
    "graphics": ("Graphics", None), "server": ("Server or lag", "Server"), "other": ("Other", None),
    "feedback": ("Feedback", None), "idea": ("Idea", None),
    "feedback": ("Feedback", None), "idea": ("Idea", None),
}
MAX_TITLE = 90
MAX_BODY = 1900
MENTION_RE = re.compile(r"@(everyone|here)", re.I)


def env(name, default=""):
    v = os.environ.get(name, "").strip()
    return v if v else default


def enabled():
    return env("BUGS_ENABLED", "1") != "0"


def clean(text):
    """Report text into Discord: no mass mentions, no markdown links pretending to be something else."""
    text = MENTION_RE.sub(lambda m: "@\u200b" + m.group(1), str(text or ""))
    return text.replace("](", "] (").strip()


def post_for(row):
    """A report row -> (title, body, tag names)."""
    rid = row["id"]
    label, tag = CATEGORY.get(row.get("category") or "other", CATEGORY["other"])
    text = clean(row.get("text"))
    first = text.splitlines()[0] if text else "Bug report"
    title = f"{label}: {first}"
    if len(title) > MAX_TITLE:
        title = title[:MAX_TITLE - 1].rstrip() + "…"
    who = f"{row.get('name') or '?'}, level {row.get('level') or '?'} " \
          f"{RACE_NAMES.get(row.get('race'), '')} {CLASS_NAMES.get(row.get('class'), '')}".replace("  ", " ").strip()
    ctx = clean(row.get("context"))
    where = f"map {row.get('map')}, zone {row.get('zone')}, area {row.get('area')} " \
            f"({row.get('x', 0):.1f}, {row.get('y', 0):.1f}, {row.get('z', 0):.1f})"
    lines = [f"**What happened**\n{text}", f"**Who** {who}", f"**Where** {where}"]
    if ctx:
        lines.append(f"**From the game** {ctx}")
    lines.append(f"-# Report #{rid} · sent from the game · "
                 f"<t:{int(row.get('created') or time.time())}:f>")
    body = "\n".join(lines)
    if len(body) > MAX_BODY:
        body = body[:MAX_BODY - 1] + "…"
    tags = [tag] if tag else []
    if ctx and re.search(r"\bclient=web\b", ctx):
        tags.append("Browser")
    elif ctx and re.search(r"\bclient=desktop\b", ctx):
        tags.append("Launcher")
    return title, body, tags


def issue_for(row):
    """A report row -> (title, Markdown body, labels) for a GitHub issue. Public: character, level, class and
    place, never the account. No Discord markup."""
    title, _, tags = post_for(row)
    label, _ = CATEGORY.get(row.get("category") or "other", CATEGORY["other"])
    who = f"{row.get('name') or '?'}, level {row.get('level') or '?'} " \
          f"{RACE_NAMES.get(row.get('race'), '')} {CLASS_NAMES.get(row.get('class'), '')}".replace("  ", " ").strip()
    where = f"map {row.get('map')}, zone {row.get('zone')}, area {row.get('area')} " \
            f"({row.get('x', 0):.1f}, {row.get('y', 0):.1f}, {row.get('z', 0):.1f})"
    text = str(row.get("text") or "").replace("@", "@\u200b").strip()
    ctx = str(row.get("context") or "").replace("@", "@\u200b").strip()
    when = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(int(row.get("created") or time.time())))
    body = "\n".join([
        "### What happened", "", text or "(no text)", "",
        f"**Category:** {label}  ", f"**Who:** {who}  ", f"**Where:** {where}  ",
        f"**From the game:** {ctx or '-'}  ", f"**Sent:** {when}", "",
        f"<sub>In-game bug report #{row['id']}, filed by Herald.</sub>",
    ])
    return f"[Bug #{row['id']}] {title}", body[:60000], ["bug-report"] + [t.lower() for t in tags]


def github_issue(row, repo=None, token=None, opener=None):
    """Open the issue; returns its number, or None (logged) when GitHub refuses or isn't set up."""
    repo, token = repo or env("BUGS_GITHUB_REPO"), token or env("BUGS_GITHUB_TOKEN")
    if not repo or not token:
        return None
    import json
    import urllib.request
    title, body, labels = issue_for(row)
    opener = opener or urllib.request.urlopen

    def send(lbls):
        data = {"title": title, "body": body}
        if lbls:
            data["labels"] = lbls
        req = urllib.request.Request(f"https://api.github.com/repos/{repo}/issues", data=json.dumps(data).encode(),
                                     method="POST", headers={"Authorization": f"Bearer {token}",
                                                             "Accept": "application/vnd.github+json",
                                                             "User-Agent": "OpenVanilla-Herald"})
        with opener(req, timeout=20) as r:
            return json.loads(r.read().decode() or "{}").get("number")
    try:
        try:
            return send(labels)
        except Exception as e:
            if getattr(e, "code", None) == 422:     # a label the token may not create: file it without labels
                return send(None)
            raise
    except Exception as e:
        print(f"[bugs] GitHub issue for report #{row.get('id')} not opened: {getattr(e, 'code', '')} {e}")
        return None


class BugRealm:
    """classiccharacters.openvanilla_bug_report, through the support desk's login."""

    COLUMNS = ("id", "created", "name", "level", "class", "race", "map", "zone", "area", "x", "y", "z",
               "category", "text", "context")

    def __init__(self, base=None):
        if base is None:
            import herald_support
            base = herald_support.Realm()
        self.base = base

    def new_reports(self, limit=10):
        con = self.base.connect()
        try:
            cur = con.cursor()
            cur.execute(f"SELECT {', '.join(self.COLUMNS)} FROM openvanilla_bug_report WHERE posted = 0 "
                        f"ORDER BY id LIMIT %s", (int(limit),))
            return [dict(zip(self.COLUMNS, r)) for r in cur.fetchall()]
        finally:
            con.close()

    def mark(self, rid, discord_id):
        con = self.base.connect()
        try:
            con.cursor().execute("UPDATE openvanilla_bug_report SET posted = 1, discord_id = %s WHERE id = %s",
                                 (int(discord_id or 0), int(rid)))
            con.commit()
        finally:
            con.close()


def install(bot, discord, chan, gid, realm=None, poll=None):
    """Wire the bug desk into Herald. Returns an object whose start() begins the loop."""
    realm = realm or BugRealm()
    channel_name = env("BUGS_CHANNEL", "bug-reports")
    poll = max(5.0, float(poll if poll is not None else env("BUGS_POLL_SEC", "15")))
    NONE = discord.AllowedMentions.none()

    async def post(row):
        g = bot.get_guild(int(gid))
        # forums aren't in text_channels (herald.chan): look through every channel
        ch = next((c for c in g.channels if c.name.split("│")[-1] == channel_name), None) if g else None
        if ch is None:
            return None
        title, body, tag_names = post_for(row)
        try:
            if hasattr(ch, "create_thread") and hasattr(ch, "available_tags"):      # a forum
                tags = [t for t in ch.available_tags if t.name in tag_names]
                made = await ch.create_thread(name=title, content=body, applied_tags=tags, allowed_mentions=NONE)
                thread = getattr(made, "thread", made)
                return getattr(thread, "id", 0) or 1
            msg = await ch.send(f"**{title}**\n{body}", allowed_mentions=NONE)
            return getattr(msg, "id", 0) or 1
        except discord.HTTPException as e:
            print(f"[bugs] can't post in #{getattr(ch, 'name', channel_name)}: {e}")
            return None

    async def tick():
        try:
            rows = await asyncio.to_thread(realm.new_reports)
        except Exception as e:
            from herald_quiet import warn
            warn("bugs", "can't read openvanilla_bug_report", e)
            return
        from herald_quiet import ok as recovered
        recovered("bugs", "can't read openvanilla_bug_report")
        for row in rows:
            made = await post(row)
            if made is None:
                return                                    # try again next round
            await asyncio.to_thread(realm.mark, row["id"], made)
            # after the mark, so a GitHub hiccup can never post the report to Discord twice
            await asyncio.to_thread(github_issue, row)

    class Desk:
        task = None

        def start(self):
            async def loop():
                await bot.wait_until_ready()
                while not bot.is_closed():
                    await tick()
                    await asyncio.sleep(poll)
            self.task = asyncio.get_event_loop().create_task(loop())

    desk = Desk()
    desk.tick = tick
    return desk
