"""Herald: the in-game ● LIVE marks.

Every STREAMS_PUSH_SEC (default 300) Herald reads the streams file the fetcher writes
(tools/streams_fetch.py -> STREAMS_JSON, default <HERALD_PUBLIC_DIR>/streams.json) and tells the
world server who is live right now, over the console (SOAP):

    .wnl livestreamers Name;Name;Name        (".wnl livestreamers -" clears the list)

Only creators who linked a channel on their account, named a character and ticked "Show me as LIVE"
on the website are in the file's "ingame" list. The world server (realm/mangos/pending/
0009-openvanilla-live.patch) then keeps only characters that are online AND have "Show me as LIVE" on in
the Social addon, and sends `LV Name;Name` to every client with the addon suite.

A stale file (not updated for STREAMS_STALE_SEC, default 1200 s: the fetcher stopped) clears the list,
so nobody keeps a LIVE mark after their stream ends. The list is pushed every time, not only on change:
a restarted world server forgets it.

Settings: STREAMS_JSON, STREAMS_PUSH_SEC, STREAMS_STALE_SEC, STREAMS_INGAME=0 turns it off; the console
account is herald_support's SOAP_URL / SOAP_USER / SOAP_PASS.
"""
import asyncio
import datetime as dt
import json
import os
import re
import time

NAME_RE = re.compile(r"^[A-Za-zÀ-ÿ]{2,12}$")
MAX_NAMES = 60


def env(name, default=""):
    v = os.environ.get(name, "").strip()
    return v if v else default


def enabled():
    return env("STREAMS_INGAME", "1") != "0"


def _ts(iso):
    try:
        return dt.datetime.fromisoformat(str(iso).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return 0.0


def live_names(doc, now, stale=1200):
    """The characters to mark, from a streams.json document (empty when it is old or malformed)."""
    if not isinstance(doc, dict) or now - _ts(doc.get("updated")) > stale:
        return []
    out = []
    for row in doc.get("ingame") or []:
        name = str((row or {}).get("character", "")) if isinstance(row, dict) else ""
        if NAME_RE.match(name):
            name = name[:1].upper() + name[1:].lower()
            if name not in out:
                out.append(name)
    return sorted(out)[:MAX_NAMES]


def command(names):
    return ".wnl livestreamers " + (";".join(names) if names else "-")


class Pusher:
    def __init__(self, soap, path, now=time.time, stale=1200):
        self.soap, self.path, self.now, self.stale = soap, path, now, stale
        self.last = None          # the last list the server accepted
        self.errors = 0

    def read(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def tick(self):
        """One push. Returns the names sent, or None when the console refused / was unreachable."""
        names = live_names(self.read(), self.now(), self.stale)
        try:
            self.soap(command(names))
        except Exception as e:  # the console is down or the account is wrong; try again next round
            self.errors += 1
            if self.errors in (1, 10) or self.errors % 100 == 0:
                print(f"[streams] can't push the LIVE list: {e}")
            return None
        if names != self.last:
            print(f"[streams] live in game: {', '.join(names) or 'nobody'}")
        self.last, self.errors = names, 0
        return names


def install(bot, soap=None, path=None, now=time.time):
    """Wire the LIVE-list push into Herald. Returns an object whose start() begins the loop."""
    if soap is None:
        import herald_support
        soap = herald_support.Realm().console
    if path is None:
        public = env("HERALD_PUBLIC_DIR", os.path.join(os.path.dirname(env("HERALD_DB", "herald.db")) or ".", "public"))
        path = env("STREAMS_JSON", os.path.join(public, "streams.json"))
    pusher = Pusher(soap, path, now, int(env("STREAMS_STALE_SEC", "1200")))
    every = max(60, int(env("STREAMS_PUSH_SEC", "300")))

    class Live:
        task = None

        def start(self):
            async def loop():
                await bot.wait_until_ready()
                while not bot.is_closed():
                    await asyncio.to_thread(pusher.tick)
                    await asyncio.sleep(every)
            self.task = asyncio.get_event_loop().create_task(loop())

    live = Live()
    live.pusher = pusher
    return live
