"""A pretend realm held in memory, so Studio can be tried (and tested) without a server.

Sign in as ADMIN / ADMIN. Nothing here touches the disk except backups, which are tiny files.
"""
import asyncio
import datetime as dt
import random
import re
import threading
import time

from .. import srp
from ..realmdata import RealmDataError
from ..soap import SoapError
from .base import Adapter

RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
CLASSES = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}


class DemoRealmData:
    def __init__(self):
        self._lock = threading.Lock()
        rnd = random.Random(7)
        names = ["ADMIN", "THRALLFAN", "MOONGLADE", "IRONBEARD", "SHADOWSTEP", "LIGHTWARD", "FROSTNOVA", "GROMMASH",
                 "SYLVANAS99", "KELTHUZ", "BRANN", "MAGNI", "VELEN", "TYRANDE", "ROKHAN", "CAIRNE", "JAINAP", "VARIAN"]
        self.accounts = {}
        self.chars = []
        cnames = iter(["Aldric", "Brakka", "Celestine", "Dorn", "Elowen", "Fizzlespark", "Grukk", "Hestia", "Ilyra", "Jorrin",
                       "Kazrak", "Lunara", "Morgrim", "Nyx", "Orla", "Prall", "Quilla", "Rhast", "Seren", "Tobin", "Ulgar",
                       "Vexa", "Wren", "Xal", "Yorick", "Zuna"])
        now = dt.datetime(2026, 10, 14, 8, 0)
        for i, n in enumerate(names, start=1):
            pw = "ADMIN" if n == "ADMIN" else "PASS" + str(i)
            s, v = srp.generate(n, pw)
            self.accounts[i] = {"id": i, "username": n, "s": s, "v": v, "gmlevel": 3 if i == 1 else (2 if i in (4, 6) else (1 if i == 9 else 0)),
                                "joindate": (now - dt.timedelta(days=rnd.randint(1, 120))).isoformat(sep=" "),
                                "last_login": (now - dt.timedelta(hours=rnd.randint(0, 300))).isoformat(sep=" "), "banned": i == 12}
            for _ in range(rnd.choice([0, 1, 1, 2])):
                try:
                    self.chars.append({"account": i, "name": next(cnames), "level": rnd.randint(8, 60),
                                       "race": rnd.choice(list(RACES)), "class": rnd.choice(list(CLASSES)), "online": rnd.random() < 0.45})
                except StopIteration:
                    break
        self.realm_row = {"id": 1, "name": "Vanilla Remastered", "address": "127.0.0.1", "port": 8085}

    def ping(self):
        return True

    def auth_row(self, username):
        with self._lock:
            for a in self.accounts.values():
                if a["username"] == username.upper():
                    return dict(a)
        return None

    def list_accounts(self, query="", limit=50, offset=0, role=None):
        with self._lock:
            rows = [a for a in self.accounts.values() if query.upper() in a["username"] and (role is None or a["gmlevel"] >= role)]
            rows.sort(key=lambda a: (-a["gmlevel"], -a["id"]))
            page = rows[offset:offset + limit]
            out = []
            for a in page:
                cs = [c for c in self.chars if c["account"] == a["id"]]
                out.append({"id": a["id"], "username": a["username"], "gmlevel": a["gmlevel"], "joindate": a["joindate"],
                            "last_login": a["last_login"], "banned": a["banned"], "online": any(c["online"] for c in cs),
                            "characters": [{k: c[k] for k in ("name", "level", "race", "class", "online")} for c in cs]})
            return {"total": len(rows), "rows": out}

    def account(self, account_id):
        a = self.accounts.get(int(account_id))
        if not a:
            raise RealmDataError("no such account")
        return {"id": a["id"], "username": a["username"], "gmlevel": a["gmlevel"]}

    def set_gmlevel(self, account_id, level):
        with self._lock:
            self.accounts[int(account_id)]["gmlevel"] = int(level)

    def set_verifier(self, account_id, s, v):
        with self._lock:
            self.accounts[int(account_id)].update(s=s, v=v)

    def create_account(self, username, s, v, gmlevel=0):
        with self._lock:
            if any(a["username"] == username.upper() for a in self.accounts.values()):
                raise RealmDataError("that account name is already taken")
            i = max(self.accounts) + 1
            self.accounts[i] = {"id": i, "username": username.upper(), "s": s, "v": v, "gmlevel": int(gmlevel),
                                "joindate": dt.datetime.now().isoformat(sep=" ", timespec="seconds"), "last_login": None, "banned": False}
            return i

    def online_players(self):
        return [dict(c) for c in self.chars if c["online"]]

    def counts(self):
        return {"accounts": len(self.accounts), "characters": len(self.chars), "online": sum(c["online"] for c in self.chars)}

    def realm(self):
        return dict(self.realm_row)

    def set_realm(self, realm_id, name=None, address=None):
        if name is not None:
            self.realm_row["name"] = name
        if address is not None:
            self.realm_row["address"] = address


class DemoAdapter(Adapter):
    mode = "demo"
    label = "Demo realm (nothing real)"

    def __init__(self, base_dir, state_dir):
        super().__init__(base_dir, state_dir)
        self.data = DemoRealmData()
        self.state = {"mysql": "running", "realmd": "running", "mangosd": "running", "web": "running"}
        self.started = time.time() - 3 * 3600 - 17 * 60
        self.motd = "Welcome to Vanilla Remastered! Be kind, have fun."
        self.restart_at = None
        self._log = [f"2026-10-14 0{h}:{m:02d}:00 {t}" for h, m, t in (
            (5, 0, "World server started: CMaNGOS Classic"), (5, 1, "Loaded 57,320 creature spawns"),
            (5, 1, "Loaded 4,211 quests"), (5, 2, "World initialized; 0 players"), (6, 14, "Player Celestine logged in"),
            (7, 3, "Player Grukk logged in"), (7, 45, "Auction house: 312 auctions expired"))]

    async def services(self):
        rnd = random.Random(int(time.time() / 5))
        rows = []
        for sid, label, port in (("mysql", "Database", 3310), ("realmd", "Login server", 3724), ("mangosd", "World server", 8085),
                                 ("web", "Website and Studio", 18090)):
            st = self.state[sid]
            rows.append({"id": sid, "label": label, "detail": f"port {port}", "state": st,
                         "cpu": round(rnd.uniform(0.5, 9), 1) if st == "running" else None,
                         "mem_mb": {"mysql": 410, "realmd": 18, "mangosd": 1630, "web": 64}[sid] if st == "running" else None,
                         "controllable": sid != "web"})
        return rows

    async def control(self, action, service, creds=None):
        ids = ["mysql", "realmd", "mangosd"] if service == "all" else [service]
        if service == "web":
            raise ValueError("Studio runs inside the website service, so it can't stop itself")
        if action in ("stop", "restart"):
            for sid in reversed(ids):
                self.state[sid] = "stopped"
            await asyncio.sleep(0.4)
        if action in ("start", "restart"):
            for sid in ids:
                self.state[sid] = "starting"
            asyncio.get_running_loop().call_later(2.5, lambda: [self.state.__setitem__(s, "running") for s in ids])
            if "mangosd" in ids:
                self.started = time.time()
        return f"{action} {'all services' if service == 'all' else service}: done"

    def log_sources(self):
        return [{"id": "world", "label": "World server"}]

    async def logs(self, source, lines=200):
        return self._log[-lines:]

    async def dump(self, path):
        with open(path, "w", encoding="utf-8") as f:
            f.write("-- Open Vanilla Studio demo backup: no real data\n")
            f.write(f"-- {dt.datetime.now().isoformat()}\n")

    async def soap(self, command, user, password):
        if self.state["mangosd"] != "running":
            from ..soap import SoapUnavailable
            raise SoapUnavailable("the world server is stopped")
        c = command.strip()
        self._log.append(f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} [SOAP] {user}: {c}")
        if c == "server info":
            up = int(time.time() - self.started)
            online = self.data.counts()["online"]
            return (f"CMaNGOS/0.12 for Win64 (demo)\nPlayers online: {online} (max: 14) Queued: 0\n"
                    f"Server uptime: {up // 3600} Hour(s) {up % 3600 // 60} Minute(s) {up % 60} Second(s).")
        if c == "server motd":
            return f"Current Message of the day:\n{self.motd}"
        m = re.match(r"server set motd (.+)", c)
        if m:
            self.motd = m.group(1)
            return "Message of the day changed to:\n" + self.motd
        m = re.match(r"server restart (\d+)", c)
        if m and c != "server restart cancel":
            self.restart_at = time.time() + int(m.group(1))
            return f"Server will restart in {m.group(1)} seconds."
        if c == "server restart cancel":
            self.restart_at = None
            return "Server restart cancelled."
        m = re.match(r"ban account (\w+) (\S+) (.+)", c)
        if m:
            for a in self.data.accounts.values():
                if a["username"] == m.group(1).upper():
                    a["banned"] = True
                    return f"{a['username']} is banned for {m.group(2)}. Reason: {m.group(3)}."
            raise SoapError("Account not found.")
        m = re.match(r"unban account (\w+)", c)
        if m:
            for a in self.data.accounts.values():
                if a["username"] == m.group(1).upper():
                    a["banned"] = False
                    return f"{a['username']} unbanned."
            raise SoapError("Account not found.")
        m = re.match(r"kick (\w+)", c)
        if m:
            for ch in self.data.chars:
                if ch["name"].lower() == m.group(1).lower() and ch["online"]:
                    ch["online"] = False
                    return f"Player {ch['name']} kicked."
            raise SoapError("Player not found or not online.")
        if c.startswith(("announce ", "notify ")):
            return ""
        return f"(demo) {c}"
