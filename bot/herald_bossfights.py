"""Herald: Boss Fights in Discord. Recap cards for first clears and new records, the week's twist on Monday,
and the fastest of the week on Sunday evening.

Herald reads the file the realm writes every 20 s (hetzner/bossfights_up.sh write_live ->
<HERALD_PUBLIC_DIR>/bossfights_live.json): its "recent" list (the last finished runs, newest first, self-test runs
never in it) and its "week" block. It posts to one channel:

  · a run that is the FIRST clear of its raid and tier on its board (people, with bots, hardcore): a gold card;
  · a run that is the new RECORD (fastest) of its board: a card too (a first clear is never posted twice);
  · Monday after 00:30 UTC: this week's twist, when the realm has one;
  · Sunday at BOSSFIGHTS_WEEKLY_HOUR UTC (default 20): the fastest of the week, per raid and tier.

Practice and story runs never rank, so they are never posted. On its first start Herald remembers the newest run
and posts nothing older (BOSSFIGHTS_BACKFILL=1 posts the backlog once). At most BOSSFIGHTS_MAX_PER_TICK cards
(default 3) go out each BOSSFIGHTS_POLL_SEC (default 60); the rest wait for the next round, so a burst of clears is
spread out, never lost.

Settings: BOSSFIGHTS_CHANNEL_ID, or BOSSFIGHTS_CHANNEL (a channel name, e.g. boss-fights; neither = off), BOSSFIGHTS_LIVE_JSON (default
<HERALD_PUBLIC_DIR>/bossfights_live.json), BOSSFIGHTS_STATE (default bossfights_herald.json beside HERALD_DB),
BOSSFIGHTS_SITE (default https://openvanilla.app/), BOSSFIGHTS_DRY_RUN=1 (print the cards, send nothing),
BOSSFIGHTS_POLL_SEC, BOSSFIGHTS_MAX_PER_TICK, BOSSFIGHTS_WEEKLY_HOUR, BOSSFIGHTS_BACKFILL.

Try it without Discord:   python3 bot/herald_bossfights.py --dry-run [path/to/bossfights_live.json]
"""
import asyncio
import datetime as dt
import json
import os
import sys
import time

RAIDS = {"onyxia": "Onyxia's Lair", "mc": "Molten Core", "bwl": "Blackwing Lair", "zg": "Zul'Gurub",
         "aq20": "Ruins of Ahn'Qiraj", "aq40": "Temple of Ahn'Qiraj", "naxx": "Naxxramas"}
BOARDS = {"people": "people", "bots": "with bots", "hardcore": "hardcore"}
FEATS = {"nodeaths": "Nobody died", "under3": "Under 3 minutes", "nobreath": "Fireproof", "botsonly": "Lone hero",
         "firsttry": "First try"}
GOLD, GREEN, BLUE, RED = 0xF0C058, 0x5EE08A, 0x7CC4FF, 0xF87171
WEEK = 7 * 86400


def env(name, default=""):
    v = os.environ.get(name, "").strip()
    return v if v else default


def enabled():
    return (env("BOSSFIGHTS_CHANNEL_ID") != "" or env("BOSSFIGHTS_CHANNEL") != "") and env("BOSSFIGHTS_POSTS", "1") != "0"


def clock(ms):
    s = max(0, int(ms or 0)) // 1000
    h, m, s = s // 3600, (s // 60) % 60, s % 60
    return (f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}")


def week_start(now):
    """Monday 00:00 UTC of the week `now` is in."""
    d = dt.datetime.fromtimestamp(now, dt.timezone.utc)
    monday = (d - dt.timedelta(days=d.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    return int(monday.timestamp())


def raid_name(key):
    return RAIDS.get(key, str(key))


def people(run):
    return [m for m in run.get("members") or [] if isinstance(m, dict) and not m.get("bot")]


def postable(run):
    """A finished, cleared, ranked run of real people (never a self-test run)."""
    return (isinstance(run, dict) and not run.get("test") and run.get("cleared") and run.get("ranked", True)
            and int(run.get("id") or 0) > 0 and run.get("raid") in RAIDS)


def card(run, why, site="https://openvanilla.app/"):
    """A Discord embed (dict) for a first clear ("first") or a new record ("record")."""
    kind = run.get("kind") or ("bots" if run.get("bots") else "people")
    who = people(run)
    leader = who[0]["name"] if who else "A group"
    raid = raid_name(run.get("raid"))
    tier = int(run.get("tier") or 0)
    if why == "first":
        title = f"First clear: {raid}, tier {tier}"
        lead = f"**{leader}'s group** is the first to clear {raid} at tier {tier}" + (
            f" on the {BOARDS.get(kind, kind)} board" if kind != "people" else "") + "."
        color = GREEN
    else:
        title = f"New record: {raid}, tier {tier}"
        lead = f"**{leader}'s group** set the fastest {raid} tier {tier} clear" + (
            f" on the {BOARDS.get(kind, kind)} board" if kind != "people" else "") + "."
        color = GOLD
    names = ", ".join(m["name"] for m in who[:10]) or "–"
    fields = [{"name": "Time", "value": clock(run.get("ms")), "inline": True},
              {"name": "Deaths", "value": str(int(run.get("deaths") or 0)), "inline": True},
              {"name": "Wipes", "value": str(int(run.get("wipes") or 0)), "inline": True},
              {"name": "Group" + (f" + {int(run.get('bots') or 0)} bots" if run.get("bots") else ""), "value": names, "inline": False}]
    feats = [FEATS[f] for f in run.get("feats") or [] if f in FEATS]
    if feats:
        fields.append({"name": "Feats", "value": " · ".join(feats), "inline": False})
    return {"title": title, "description": lead, "color": color,
            "url": f"{site.rstrip('/')}/bossfights-run.html?id={int(run['id'])}", "fields": fields,
            "footer": {"text": "Boss Fights · Open Vanilla"}}


def weekly_card(doc, site="https://openvanilla.app/"):
    """Sunday's "fastest of the week": one line per raid, tier and board. None when nobody cleared anything."""
    rows = [r for r in ((doc or {}).get("week") or {}).get("fastest") or [] if isinstance(r, dict) and r.get("raid") in RAIDS]
    if not rows:
        return None
    rows.sort(key=lambda r: (r.get("raid"), int(r.get("tier") or 0), r.get("kind") or ""))
    lines = []
    for r in rows:
        kind = r.get("kind") or "people"
        tag = "" if kind == "people" else f" ({BOARDS.get(kind, kind)})"
        lines.append(f"**{raid_name(r['raid'])} {int(r.get('tier') or 0)}**{tag}: {r.get('leader') or '?'}'s group, "
                     f"{clock(r.get('ms'))} · [run]({site.rstrip('/')}/bossfights-run.html?id={int(r.get('id') or 0)})")
    return {"title": "Fastest of the week", "description": "\n".join(lines[:20]), "color": GOLD,
            "url": f"{site.rstrip('/')}/bossfights.html#week", "footer": {"text": "The week ends Monday 00:00 UTC"}}


def twist_card(doc, site="https://openvanilla.app/"):
    w = (doc or {}).get("week") or {}
    if not w.get("twist") or not w.get("name"):
        return None
    return {"title": f"This week's twist: {w['name']}", "description": f"{w.get('text', '')}\n\nOn every Boss Fights raid until Monday.",
            "color": RED, "url": f"{site.rstrip('/')}/bossfights.html#week", "footer": {"text": "Boss Fights · Open Vanilla"}}


class Recaps:
    """Decides what to post from one read of the live file; keeps what it posted in a small state file."""

    def __init__(self, path, state_path, now=time.time, max_per_tick=3, weekly_hour=20, backfill=False,
                 site="https://openvanilla.app/"):
        self.path, self.state_path, self.now = path, state_path, now
        self.max, self.hour, self.backfill, self.site = max(1, max_per_tick), weekly_hour, backfill, site
        self.state = self.load_state()

    def load_state(self):
        try:
            with open(self.state_path, encoding="utf-8") as f:
                s = json.load(f)
                return s if isinstance(s, dict) else {}
        except (OSError, ValueError):
            return {}

    def save_state(self):
        tmp = self.state_path + ".tmp"
        try:
            os.makedirs(os.path.dirname(self.state_path) or ".", exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.state, f)
            os.replace(tmp, self.state_path)
        except OSError as e:
            print(f"[bossfights] can't save {self.state_path}: {e}")

    def read(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                doc = json.load(f)
                return doc if isinstance(doc, dict) else None
        except (OSError, ValueError):
            return None

    def plan(self, doc):
        """The cards due now, oldest run first, at most max_per_tick: [(key, embed)]. `key` is what commit() records."""
        if not doc:
            return []
        out = []
        recent = sorted((r for r in doc.get("recent") or [] if isinstance(r, dict)), key=lambda r: int(r.get("id") or 0))
        top = max([int(r.get("id") or 0) for r in recent] or [0])
        last = self.state.get("last_id")
        if last is None:
            if self.backfill:
                last = 0
            else:
                self.state["last_id"] = top        # a first start: nothing from before
                self.save_state()
                return []
        for r in recent:
            rid = int(r.get("id") or 0)
            if rid <= last:
                continue
            if postable(r) and (r.get("first") or r.get("record")):
                out.append((("run", rid), card(r, "first" if r.get("first") else "record", self.site)))
            else:
                out.append((("run", rid), None))  # nothing to say: only moves the bookmark
        now = self.now()
        ws = week_start(now)
        if now >= ws + 1800 and self.state.get("twist_week", 0) < ws:
            out.append((("twist", ws), twist_card(doc, self.site)))
        # Sunday, at the hour: the week ends at the next Monday 00:00 UTC
        if now >= ws + 6 * 86400 + self.hour * 3600 and self.state.get("weekly_week", 0) < ws:
            out.append((("weekly", ws), weekly_card(doc, self.site)))
        # the posts that say something count against the limit; bookmark-only entries are free
        picked, said = [], 0
        for key, emb in out:
            if emb is not None:
                if said >= self.max:
                    break
                said += 1
            picked.append((key, emb))
        return picked

    def commit(self, key):
        what, value = key
        if what == "run":
            self.state["last_id"] = max(int(self.state.get("last_id") or 0), value)
        elif what == "twist":
            self.state["twist_week"] = value
        elif what == "weekly":
            self.state["weekly_week"] = value
        self.save_state()


def install(bot, discord, channel_id=None, path=None, state_path=None, now=time.time, dry_run=None):
    """Wire the recap cards into Herald. Returns an object whose start() begins the loop."""
    public = env("HERALD_PUBLIC_DIR", os.path.join(os.path.dirname(env("HERALD_DB", "herald.db")) or ".", "public"))
    path = path or env("BOSSFIGHTS_LIVE_JSON", os.path.join(public, "bossfights_live.json"))
    state_path = state_path or env("BOSSFIGHTS_STATE", os.path.join(os.path.dirname(env("HERALD_DB", "herald.db")) or ".",
                                                                    "bossfights_herald.json"))
    channel_id = int(channel_id or env("BOSSFIGHTS_CHANNEL_ID", "0") or 0)
    channel_name = env("BOSSFIGHTS_CHANNEL", "").lstrip("#").lower()
    dry = env("BOSSFIGHTS_DRY_RUN", "0") == "1" if dry_run is None else dry_run
    recaps = Recaps(path, state_path, now, int(env("BOSSFIGHTS_MAX_PER_TICK", "3")), int(env("BOSSFIGHTS_WEEKLY_HOUR", "20")),
                    env("BOSSFIGHTS_BACKFILL", "0") == "1", env("BOSSFIGHTS_SITE", "https://openvanilla.app/"))
    every = max(20, int(env("BOSSFIGHTS_POLL_SEC", "60")))

    async def send(emb):
        if dry:
            print("[bossfights] (dry run) " + json.dumps(emb, ensure_ascii=False))
            return True
        ch = bot.get_channel(channel_id) if channel_id else None
        if ch is None and channel_id:
            ch = await bot.fetch_channel(channel_id)
        if ch is None and channel_name:
            ch = next((c for c in bot.get_all_channels() if getattr(c, "name", "").lower() == channel_name
                       and hasattr(c, "send")), None)
        if ch is None:
            raise LookupError(f"no channel {channel_id or '#' + channel_name}")
        await ch.send(embed=discord.Embed.from_dict(emb),
                      allowed_mentions=discord.AllowedMentions.none())
        return True

    async def tick():
        doc = await asyncio.to_thread(recaps.read)
        for key, emb in recaps.plan(doc):
            if emb is not None:
                try:
                    await send(emb)
                except Exception as e:  # Discord down, no permission, no such channel: the same card is tried next round
                    try:
                        from herald_quiet import warn
                        warn("bossfights", f"can't post to {channel_id or '#' + channel_name}", e)
                    except ImportError:
                        print(f"[bossfights] can't post to {channel_id or '#' + channel_name}: {e}")
                    return
                await asyncio.sleep(2)
            recaps.commit(key)

    class Loop:
        task = None

        def start(self):
            async def loop():
                await bot.wait_until_ready()
                while not bot.is_closed():
                    try:
                        await tick()
                    except Exception as e:
                        print(f"[bossfights] {type(e).__name__}: {e}")
                    await asyncio.sleep(every)
            self.task = asyncio.get_event_loop().create_task(loop())

    lp = Loop()
    lp.recaps, lp.tick = recaps, tick
    return lp


def main(argv):
    """--dry-run [live.json]: print the cards Herald would post now (a fresh bookmark posts the backlog)."""
    if "--dry-run" not in argv:
        print(__doc__)
        return 2
    rest = [a for a in argv if not a.startswith("--")]
    path = rest[0] if rest else env("BOSSFIGHTS_LIVE_JSON", "bossfights_live.json")
    r = Recaps(path, os.devnull, backfill=True, max_per_tick=100)
    r.state = {}
    doc = r.read()
    if doc is None:
        print(f"can't read {path}")
        return 1
    n = 0
    for _key, emb in r.plan(doc):
        if emb is not None:
            n += 1
            print(json.dumps(emb, ensure_ascii=False, indent=2))
    print(f"{n} card(s) would be posted")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
