"""How Herald Autopilot talks to a realm.

Two links with the same shape:

  RealmLink  a realm's autopilot API (hetzner/herald_autopilot_api.py) over HTTPS, signed in with
             the Open Vanilla launcher's token. The realm says whether autoplay is allowed, which of the
             account's characters are online, and runs the character with its own bot AI.
  DemoLink   a small offline world (Elwynn Forest, a hunter, wolves and kobolds) so the program can
             be tried, tested and shown with no realm at all. Its outcomes follow the rules the way
             a real run would (rest too late and you die more), so it also feeds the learning loop
             believable numbers in tests.

Every link returns Events (what happened) and a state dict (where the character is now):
  name cls level xp xp_max hp hp_max mana mana_max zone pos path target status bags bag_slots money
"""
from __future__ import annotations

import json
import math
import os
import random
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field


@dataclass
class Event:
    t: float
    kind: str          # log kill loot xp death rest level quest vendor gather state
    text: str
    data: dict = field(default_factory=dict)


# ------------------------------------------------------------------------------------- realm
class RealmLink:
    def __init__(self, base_url, token=None, timeout=8, opener=None):
        self.base = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self.seq = 0
        self._open = opener or urllib.request.urlopen
        self.label = self.base.split("//")[-1]

    def _call(self, path, payload=None, method=None):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method or ("POST" if data else "GET"))
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with self._open(req, timeout=self.timeout) as r:
                return r.status, json.loads(r.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            try:
                body = json.loads(e.read().decode() or "{}")
            except Exception:
                body = {}
            return e.code, body
        except Exception as e:  # offline, DNS, TLS
            return 0, {"message": str(e)}

    def realm_info(self):
        status, body = self._call("/api/autopilot/realm")
        if status != 200:
            msg = ("Can't reach the realm. Check your connection, or the address in Settings." if status == 0
                   else body.get("message") or f"The realm answered {status}.")
            return {"name": self.label, "reachable": status != 0, "autoplay_allowed": False, "message": msg}
        body.setdefault("reachable", True)
        return body

    def characters(self):
        status, body = self._call("/api/autopilot/characters")
        return body.get("characters", []) if status == 200 else []

    def start(self, name, plan):
        status, body = self._call("/api/autopilot/start", {"character": name, "plan": plan})
        return status == 200, body.get("message", "Started." if status == 200 else f"Couldn't start ({status}).")

    def stop(self):
        status, body = self._call("/api/autopilot/stop", {})
        return status == 200, body.get("message", "")

    def pause(self):
        return self._call("/api/autopilot/pause", {})[0] == 200

    def resume(self):
        return self._call("/api/autopilot/resume", {})[0] == 200

    def poll(self):
        status, body = self._call(f"/api/autopilot/poll?since={self.seq}")
        if status != 200:
            return [], None
        self.seq = body.get("seq", self.seq)
        events = [Event(e.get("t", time.time()), e.get("kind", "log"), e.get("text", ""), e.get("data") or {})
                  for e in body.get("events", [])]
        return events, body.get("state")

    def tick(self, dt):  # the realm runs the world
        pass


# --------------------------------------------------------------------------------------- demo
def xp_to_level(level):
    """Roughly 1.12's table (400 at 1, 7,600 at 10, 85,000 near 50)."""
    return int(40 * level * level + 360 * level) if level < 60 else 0


MOBS = (  # name, min level, max level, loot
    ("Young Wolf", 1, 3, [("Ruined Pelt", "pelt", 0), ("Chunk of Boar Meat", "meat", 1)]),
    ("Kobold Vermin", 2, 4, [("Linen Cloth", "cloth", 1), ("Large Candle", "junk", 0)]),
    ("Forest Spider", 5, 7, [("Small Spider Leg", "meat", 1), ("Thin Spider Silk", "cloth", 1)]),
    ("Prowler", 7, 9, [("Ruined Leather Scraps", "pelt", 0), ("Light Leather", "pelt", 1)]),
    ("Murloc Streamer", 9, 11, [("Murloc Fin", "junk", 0), ("Linen Cloth", "cloth", 1)]),
    ("Riverpaw Gnoll", 10, 12, [("Linen Cloth", "cloth", 1), ("Minor Healing Potion", "potion", 1)]),
    ("Defias Thug", 11, 13, [("Linen Cloth", "cloth", 1), ("Red Defias Mask", "mask", 2)]),
    ("Young Thistle Boar", 12, 14, [("Ruined Leather Scraps", "pelt", 0), ("Chunk of Boar Meat", "meat", 1)]),
)
NODES = (("Copperbloom", "herb"), ("Silverleaf", "herb"), ("Copper Vein", "ore"), ("Peacebloom", "herb"))
QUESTS = ("Wolves Across the Border", "Kobold Candles", "Princess Must Die!", "The Fargodeep Mine",
          "Riverpaw Gnoll Bounty", "Red Linen Goods", "Bounty on Murlocs", "Protect the Frontier")

# a loop through Elwynn on a 0..1 map (Goldshire is the town)
TOWN = (0.47, 0.52)
ROUTE = [(0.47, 0.52), (0.40, 0.60), (0.30, 0.66), (0.22, 0.58), (0.25, 0.44), (0.33, 0.36),
         (0.46, 0.33), (0.58, 0.38), (0.70, 0.46), (0.76, 0.60), (0.66, 0.70), (0.55, 0.64)]


class DemoLink:
    """An offline world for trying Autopilot. Call tick(dt) as time passes; poll() drains events."""

    def __init__(self, seed=None, speed=1.0, name="Herald", cls="Hunter", level=12):
        self.rng = random.Random(seed)
        self.speed = speed
        self.label = "Demo realm (offline)"
        self.events = []
        self.char = {"name": name, "cls": cls, "level": level, "zone": "Elwynn Forest", "online": True}
        self.xp = int(xp_to_level(level) * 0.43)
        self.hp_max = 90 + level * 22
        self.mana_max = 60 + level * 18 if cls != "Warrior" and cls != "Rogue" else 0
        self.hp, self.mana = self.hp_max, self.mana_max
        self.money = 4 * 10000 + 52 * 100
        self.bag_slots = 16
        self.bags = []            # [name, icon, count, quality] per slot; greys don't stack, the rest stack to 20
        self.potions = 2
        self.pos = TOWN
        self.wp = 1
        self.status = "idle"
        self.target = None
        self.timer = 0.0
        self.running = False
        self.paused = False
        self.rules = {}
        self.goal = "level"
        self.path = list(ROUTE)
        self.extra_adds = 0

    # -- the interface ------------------------------------------------------------------------
    def realm_info(self):
        return {"name": self.label, "reachable": True, "autoplay_allowed": True, "tag": "[Autopilot]",
                "demo": True, "message": "Offline demo: nothing here touches a real realm."}

    def characters(self):
        return [dict(self.char)]

    def start(self, name, plan):
        if self.running:
            return False, "Already running."
        self.rules = dict(plan.get("rules") or {})
        self.goal = plan.get("goal", "level")
        self.running, self.paused = True, False
        self.status = "travel"
        self._emit("state", f"Autopilot on: {name}, {self._goal_text()}.")
        return True, "Started."

    def stop(self):
        if not self.running:
            return False, "Not running."
        self.running = False
        self.status, self.target = "idle", None
        self._emit("state", "Autopilot off. Herald stands where he is.")
        return True, "Stopped."

    def pause(self):
        self.paused = True
        self._emit("state", "Paused.")
        return True

    def resume(self):
        self.paused = False
        self._emit("state", "Back to it.")
        return True

    def poll(self):
        out, self.events = self.events, []
        return out, self.state()

    def state(self):
        level = self.char["level"]
        return {
            "name": self.char["name"], "cls": self.char["cls"], "level": level,
            "xp": self.xp, "xp_max": xp_to_level(level), "hp": int(self.hp), "hp_max": self.hp_max,
            "mana": int(self.mana), "mana_max": self.mana_max, "zone": self.char["zone"],
            "pos": self.pos, "path": self.path, "target": self.target,
            "status": "paused" if (self.paused and self.running) else self.status,
            "bags": [{"name": n, "icon": i, "count": c, "quality": q} for n, i, c, q in self.bags],
            "bag_slots": self.bag_slots, "money": self.money, "potions": self.potions,
        }

    # -- the world ------------------------------------------------------------------------------
    def _emit(self, kind, text, **data):
        self.events.append(Event(time.time(), kind, text, data))

    def _goal_text(self):
        return {"level": "levelling in Elwynn Forest", "quest": "questing in Elwynn Forest",
                "gather": "gathering herbs and ore", "follow": "following Orionalt",
                "dungeon": "waiting for the group"}.get(self.goal, self.goal)

    def _rule(self, key, default):
        return self.rules.get(key, default)

    def _bag_used(self):
        return len(self.bags)

    def _add_item(self, name, icon, quality):
        if quality > 0:
            for slot in self.bags:
                if slot[0] == name and slot[2] < 20:
                    slot[2] += 1
                    return True
        if self._bag_used() >= self.bag_slots:
            return False
        self.bags.append([name, icon, 1, quality])
        return True

    def _move(self, dt, dest):
        x, y = self.pos
        dx, dy = dest[0] - x, dest[1] - y
        d = math.hypot(dx, dy)
        step = 0.018 * dt
        if d <= step:
            self.pos = dest
            return True
        self.pos = (x + dx / d * step, y + dy / d * step)
        return False

    def tick(self, dt):
        dt *= self.speed
        if not self.running or self.paused:
            return
        level = self.char["level"]
        if self.status == "dead":
            self.timer -= dt
            if self.timer <= 0:
                self.hp, self.mana = self.hp_max * 0.5, self.mana_max * 0.5
                self.status = "rest"
                self._emit("log", "Back at the body. Resurrected with half health.")
            return
        if self.status == "rest":
            self.hp = min(self.hp_max, self.hp + self.hp_max * 0.09 * dt)
            self.mana = min(self.mana_max, self.mana + self.mana_max * 0.09 * dt)
            if self.hp >= self.hp_max * 0.98 and self.mana >= self.mana_max * 0.98:
                self.status = "travel"
                self._emit("log", "Rested. Moving on.")
            return
        if self.status == "vendor":
            if self._move(dt, TOWN):
                keep = self._rule("keep", "quest")
                top = {"all": 0, "green": 1, "quest": 2}.get(keep, 2)   # sell this quality and below
                junk = [b for b in self.bags if b[3] == 0 or (b[3] <= top and b[1] != "potion")]
                copper = 0
                for b in junk:
                    copper += b[2] * self.rng.randint(4, 30) * (1 + b[3] * 3)
                    self.bags.remove(b)
                self.money += copper
                self._emit("vendor", f"Sold {len(junk)} stacks at Goldshire for {_money(copper)}.", copper=copper)
                self._emit("loot", "", copper=copper, items=0)
                self.status = "travel"
            return
        if self.status == "combat":
            self._combat(dt, level)
            return
        # travelling: follow the route, meet things
        dest = self.path[self.wp % len(self.path)]
        if self._move(dt, dest):
            self.wp += 1
        self.timer -= dt
        if self.timer <= 0:
            self.timer = self.rng.uniform(2.5, 5.5)
            if self.goal == "gather" and self.rng.random() < 0.55:
                node, icon = self.rng.choice(NODES)
                if self._add_item(node, icon, 1):
                    self._emit("gather", f"Gathered {node}.", node=node)
                    self._emit("loot", "", copper=0, items=1)
                    return
            self._pull(level)

    def _pull(self, level):
        choices = [m for m in MOBS if m[1] <= level + 1 and m[2] >= level - 3] or [MOBS[-1]]
        name, lo, hi, loot = self.rng.choice(choices)
        a, b = max(lo, level - 2), min(hi, level + 2)
        mob_level = self.rng.randint(a, b) if a <= b else min(hi, max(lo, level))
        pull = self._rule("pull", "one")
        adds = 0
        if self.rng.random() < {"one": 0.08, "two": 0.25, "any": 0.45}[pull]:
            adds = 1 if pull != "any" else self.rng.randint(1, 2)
        self.extra_adds = adds
        self.target = {"name": name, "level": mob_level, "hp": 1.0, "loot": loot, "adds": adds}
        self.status = "combat"
        extra = f" (+{adds} more)" if adds else ""
        self._emit("log", f"Target: {name} (Lvl {mob_level}){extra}.")

    def _combat(self, dt, level):
        t = self.target
        diff = t["level"] - level
        kill_speed = 0.16 * (1 - 0.12 * diff) / (1 + 0.65 * t["adds"])
        t["hp"] -= kill_speed * dt * self.rng.uniform(0.7, 1.3)
        dmg = self.hp_max * 0.032 * (1 + 0.18 * diff) * (1 + 0.9 * t["adds"]) * dt * self.rng.uniform(0.6, 1.4)
        self.hp -= dmg
        if self.mana_max:
            self.mana = max(0.0, self.mana - self.mana_max * 0.035 * dt)
        danger = self._rule("danger", 20) / 100
        if self.hp < self.hp_max * danger and self.potions:
            self.potions -= 1
            self.hp += self.hp_max * 0.35
            self._emit("log", f"Health {int(danger * 100)}%: drank a healing potion ({self.potions} left).")
        if self.hp <= 0:
            self.hp = 0
            self.status, self.timer, self.target = "dead", 45.0, None
            self._emit("death", f"Died to {t['name']} (Lvl {t['level']}). Running back.", mob_level_diff=diff,
                       adds=t["adds"], rest_hp=self._rule("rest_hp", 35), pull=self._rule("pull", "one"))
            return
        if t["hp"] > 0:
            return
        # the kill
        xp = int((level * 5 + 45) * (1 + 0.05 * diff) * (1 + t["adds"]))
        self.xp += xp
        self._emit("kill", f"Defeated {t['name']}{' and its friends' if t['adds'] else ''}. +{xp} XP.",
                   xp=xp, mob=t["name"], mob_level=t["level"])
        copper = self.rng.randint(3, 12) * level * (1 + t["adds"])
        got, full = [], False
        for item, icon, quality in t["loot"]:
            if self.rng.random() < 0.55:
                if self._rule("bags", "vendor") == "ignore" and self._bag_used() >= self.bag_slots:
                    continue
                if self._add_item(item, icon, quality):
                    got.append(item)
                else:
                    full = True
        if self.rng.random() < 0.06:
            self.potions += 1
        self.money += copper
        self._emit("loot", "Looted " + (", ".join(got) + ", " if got else "") + _money(copper) + ".",
                   copper=copper, items=len(got), notable=any(q >= 2 for n, _i, q in t["loot"] if n in got))
        self.target = None
        if self.goal == "quest" and self.rng.random() < 0.12:
            q = self.rng.choice(QUESTS)
            qxp = level * 40 + 120
            self.xp += qxp
            self._emit("quest", f"Quest complete: {q}. +{qxp} XP.", xp=qxp, quest=q)
        if self.xp >= xp_to_level(level):
            self.xp -= xp_to_level(level)
            self.char["level"] = level + 1
            self.hp_max += 22
            self.mana_max += 18 if self.mana_max else 0
            self.hp, self.mana = self.hp_max, self.mana_max
            self._emit("level", f"Level {level + 1}! Health and mana restored.", level=level + 1)
        if full or self._bag_used() >= self.bag_slots:
            how = self._rule("bags", "vendor")
            if how == "vendor":
                self.status = "vendor"
                self._emit("log", "Bags full. Walking to Goldshire to sell greys.")
                return
            if how == "stop":
                self._emit("state", "Bags full. Going home and stopping, as asked.")
                self.stop()
                return
        rest_hp = self._rule("rest_hp", 35) / 100
        rest_mana = self._rule("rest_mana", 25) / 100
        if self.hp < self.hp_max * rest_hp or (self.mana_max and self.mana < self.mana_max * rest_mana):
            self.status = "rest"
            self._emit("rest", f"Resting: health {int(100 * self.hp / self.hp_max)}%"
                       + (f", mana {int(100 * self.mana / self.mana_max)}%." if self.mana_max else "."))
        else:
            self.status = "travel"


def _money(copper):
    g, r = divmod(int(copper), 10000)
    s, c = divmod(r, 100)
    return " ".join(p for p in (f"{g}g" if g else "", f"{s}s" if s else "", f"{c}c" if c or not (g or s) else "") if p)


# ------------------------------------------------------------------------------- Herald Lite
# devkit/heraldlite's autopilot: a headless client that logs a BOT account in and plays a
# tools/autopilot route (Northshire/Elwynn, a Human Hunter first). Its own allowlist only lets it
# connect to Open Vanilla's realms and local test hosts; this link checks the same list up front so the
# window can say why START is off instead of letting the binary refuse.
HL_ALLOWED_HOSTS = ("play.openvanilla.app", "staging.openvanilla.app", "play.openwow.app", "staging.openwow.app",  # old names, same realm
                    "localhost", "127.0.0.1")
HL_ALLOWED_SUFFIXES = (".test", ".localhost")
ELWYNN = (1535.42, -1941.67, -7939.58, -10254.17)   # WorldMapArea: left, right, top, bottom (world y, y, x, x)
CREATURES = {6: "Kobold Vermin", 38: "Defias Thug", 80: "Kobold Laborer", 257: "Kobold Worker", 299: "Diseased Young Wolf"}


def hl_host(target):
    t = target.strip().lower()
    if "//" in t:
        t = t.split("//", 1)[1]
    t = t.split("/", 1)[0]
    if t.startswith("["):
        return t[1:t.index("]")] if "]" in t else t
    return t.rsplit(":", 1)[0] if t.count(":") == 1 else t


def hl_allowed(target):
    h = hl_host(target)
    return h in HL_ALLOWED_HOSTS or any(h.endswith(s) for s in HL_ALLOWED_SUFFIXES)


def find_heraldlite(root):
    exe = "heraldlite.exe" if os.name == "nt" else "heraldlite"
    for p in (os.path.join(root, "devkit", "heraldlite", "target", "release", exe), os.path.join(root, "bin", exe)):
        if os.path.isfile(p):
            return p
    return None


def tactics_for(cls, rules, base=None):
    """Herald Lite's tactics file from the window's rules (rest thresholds, how high to pull)."""
    t = json.loads(json.dumps(base or {}))
    t.setdefault("strategy", "kite" if cls == "Hunter" else "melee")
    rest = t.setdefault("rest", {})
    rest["eat_below"] = rules.get("rest_hp", 35) / 100
    if cls in ("Warrior", "Rogue"):
        rest["drink_below"] = 0.0
    else:
        rest["drink_below"] = rules.get("rest_mana", 25) / 100
    pull = t.setdefault("pull", {})
    pull["max_level_above"] = {"one": 1, "two": 2, "any": 3}.get(rules.get("pull"), 2)
    return t


class HeraldLiteLink:
    """Runs `heraldlite autopilot` and turns its JSONL run log into Events and state."""

    def __init__(self, root, folder, target, user, password, char=None, cls="Hunter", binary=None,
                 popen=None, clock=time.time):
        self.root, self.folder = root, folder
        self.target, self.user, self.password, self.char, self.cls = target, user, password, char or "Herald", cls
        self.binary = binary if binary is not None else find_heraldlite(root)
        self._popen = popen or subprocess.Popen
        self.clock = clock
        self.proc = None
        self.log_path = None
        self._offset = 0
        self.state_ = None
        self.last_step = 0
        self.running = False
        self.world_port = 8085
        self.label = ("Your server (this PC)" if hl_host(target) in ("127.0.0.1", "localhost")
                      else f"Herald Lite · {hl_host(target) or 'no realm'}")
        self.events = []

    def realm_info(self):
        info = {"name": self.label, "reachable": True, "tag": "bot account", "autoplay_allowed": False}
        if not hl_allowed(self.target):
            info["message"] = "Herald Lite only plays on Open Vanilla's realms and test hosts."
        elif not self.binary:
            info["message"] = ("Herald Lite isn't here: it comes with Open Vanilla Server (bin/heraldlite.exe), or build it with "
                               "cargo build --release in devkit/heraldlite.")
        elif not (self.user and self.password):
            info["message"] = "Add the bot account and its password in Settings."
        else:
            info["autoplay_allowed"] = True
            info["message"] = ("Herald logs this account in by himself: keep it out of the game client while he plays "
                               "(watch him from another account).")
        return info

    def characters(self):
        lvl = (self.state_ or {}).get("level", 1)
        return [{"name": self.char, "cls": self.cls, "level": lvl, "online": True}]

    def _route(self):
        for p in (os.path.join(self.root, "tools", "autopilot", "out", "route_elwynn.json"),
                  os.path.join(self.root, "autopilot", "routes", "route_elwynn.json"),
                  os.path.join(self.root, "tests", "fixtures", "route_elwynn_enriched.json")):
            if os.path.isfile(p):
                return p
        return None

    def start(self, name, plan):
        if self.proc and self.proc.poll() is None:
            return False, "Already running."
        info = self.realm_info()
        if not info["autoplay_allowed"]:
            return False, info["message"]
        route = self._route()
        if not route:
            return False, "No route: run tools/autopilot (planner.py, route_enrich.py) first."
        rules = plan.get("rules") or {}
        tname = "tactics_hunter.json" if self.cls == "Hunter" else "tactics_melee.json"
        base_file = next((p for p in (os.path.join(self.root, "devkit", "heraldlite", "autopilot", tname),
                                      os.path.join(self.root, "autopilot", "routes", tname)) if os.path.isfile(p)), "")
        try:
            with open(base_file, encoding="utf-8") as f:
                base = json.load(f)
        except (OSError, ValueError):
            base = {}
        os.makedirs(self.folder, exist_ok=True)
        tactics = os.path.join(self.folder, "heraldlite_tactics.json")
        with open(tactics, "w", encoding="utf-8") as f:
            json.dump(tactics_for(self.cls, rules, base), f, indent=1)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(self.clock()))
        self.log_path = os.path.join(self.folder, f"heraldlite-{stamp}.jsonl")
        self._offset = 0
        minutes = {"30m": 30, "1h": 60, "2h": 120}.get(rules.get("stop"), 600)
        args = [self.binary, "autopilot", "--route", route, "--tactics", tactics, "--minutes", str(minutes),
                "--log", self.log_path, "--start-step", str(self.last_step), "--user", self.user, "--char", name]
        if "//" in self.target:
            args += ["--web", self.target]
        else:
            args += ["--host", self.target]
            if hl_host(self.target) in ("127.0.0.1", "localhost"):
                # a server on this PC advertises its public address in the realm list; play over loopback
                args += ["--world", f"{hl_host(self.target)}:{self.world_port}"]
        if rules.get("stop") == "ding" and self.state_:
            args += ["--max-level", str(self.state_.get("level", 1) + 1)]
        env = dict(os.environ, HL_PASS=self.password)          # never on the command line
        out = self._out = open(os.path.join(self.folder, "heraldlite-stdout.txt"), "w", encoding="utf-8")
        kw = {"creationflags": 0x08000000} if os.name == "nt" else {}   # no console window
        self.proc = self._popen(args, env=env, stdout=out, stderr=subprocess.STDOUT, cwd=os.path.dirname(route), **kw)
        self.running = True
        self.events.append(Event(self.clock(), "state", f"Herald Lite started ({name}, from route step {self.last_step})."))
        return True, "Started."

    def stop(self):
        if not self.proc or self.proc.poll() is not None:
            self.running = False
            return False, "Not running."
        self.proc.terminate()
        self.running = False
        self._close_out()
        self.events.append(Event(self.clock(), "state", f"Herald Lite stopped. START picks up again at step {self.last_step}."))
        return True, "Stopped."

    def _close_out(self):
        out = getattr(self, "_out", None)
        if out and not out.closed:
            out.close()

    def pause(self):
        self.events.append(Event(self.clock(), "state", "Herald Lite can't pause: STOP, then START carries on from the same step."))
        return False

    def resume(self):
        return False

    def tick(self, dt):
        pass

    def _read_lines(self):
        if not self.log_path or not os.path.isfile(self.log_path):
            return []
        with open(self.log_path, encoding="utf-8", errors="replace") as f:
            f.seek(self._offset)
            data = f.read()
        complete = data[:data.rfind("\n") + 1] if "\n" in data else ""
        self._offset += len(complete.encode("utf-8"))
        out = []
        for line in complete.splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    def poll(self):
        for row in self._read_lines():
            self._take(row)
        if self.proc is not None and self.running and self.proc.poll() is not None:
            code = self.proc.returncode
            self.running = False
            self._close_out()
            why = {0: "Route finished or time is up.", 1: "A step failed or the connection dropped (see the log).",
                   2: "Couldn't log in: check the bot account and password in Settings."}.get(code, f"Herald Lite exited ({code}).")
            self.events.append(Event(self.clock(), "state", why))
        out, self.events = self.events, []
        return out, self.state_

    def _take(self, row):
        t = self.clock()
        if row.get("step") is not None:
            self.last_step = int(row["step"])
        st = dict(self.state_ or {"name": self.char, "cls": self.cls, "bags": None, "bag_slots": 16, "money": 0, "path": []})
        for k in ("level", "xp", "hp", "mana"):
            if row.get(k) is not None:
                st[k] = row[k]
        if row.get("max_hp"):
            st["hp_max"] = row["max_hp"]
        pos = row.get("pos")
        if pos and (pos[0] or pos[1]):
            left, right, top, bottom = ELWYNN
            u = (left - pos[1]) / (left - right)
            v = (top - pos[0]) / (top - bottom)
            if 0 <= u <= 1 and 0 <= v <= 1:
                st["pos"] = (u, v)
                trail = st.get("path") or []
                if not trail or abs(trail[-1][0] - u) + abs(trail[-1][1] - v) > 0.01:
                    st["path"] = (trail + [(u, v)])[-40:]
        st["status"] = "travel"
        st["zone"] = "Elwynn Forest"
        ev, action, result = row.get("event"), str(row.get("action") or ""), str(row.get("result") or "")
        if ev == "decision" and action.startswith(("Ranged", "KiteRun", "Melee", "Turn", "fight")):
            st["status"] = "combat"
        elif ev == "decision" and action.startswith("rest"):
            st["status"] = "rest"
        self.state_ = st
        if ev == "outcome":
            self._outcome(t, action, result, row)
        elif ev == "summary" or "summary" in row:
            s = row.get("summary") or {}
            self.events.append(Event(t, "state", f"Run summary: {s.get('minutes', '?')} min, {s.get('kills', 0)} kills, "
                                                  f"{s.get('deaths', 0)} deaths, level {s.get('level_start', '?')} → {s.get('level_end', '?')}."))

    def _outcome(self, t, action, result, row):
        import re as _re
        num = lambda s: int(_re.search(r"-?\d+", s).group()) if _re.search(r"-?\d+", s) else 0  # noqa: E731
        if action == "kill":
            entry = num(result)
            self.events.append(Event(t, "kill", f"Defeated {CREATURES.get(entry, f'creature {entry}')}.", {"xp": 0, "mob": entry}))
        elif action == "xp":
            self.events.append(Event(t, "xp", "", {"xp": num(result)}))
        elif action == "level up":
            self.events.append(Event(t, "level", f"Level {num(result)}!", {"level": num(result)}))
        elif action == "quest rewarded":
            m = _re.search(r"quest (\d+) \(\+(\d+) xp, (\d+) copper\)", result)
            q, xp, money = (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else (num(result), 0, 0)
            self.events.append(Event(t, "quest", f"Quest {q} turned in. +{xp} XP.", {"xp": xp}))
            if money:
                self.events.append(Event(t, "loot", "", {"copper": money, "items": 0}))
        elif action == "loot" and result.endswith("copper"):
            c = num(result)
            st = self.state_
            st["money"] = st.get("money", 0) + c
            self.events.append(Event(t, "loot", f"Looted {c} copper.", {"copper": c, "items": 0}))
        elif action == "item":
            self.events.append(Event(t, "loot", f"Got item {result.replace('received ', '')}.", {"copper": 0, "items": 1}))
        elif action == "died":
            self.state_["status"] = "dead"
            self.events.append(Event(t, "death", "Died. Running back to the body.", {}))
        elif action == "rest":
            self.events.append(Event(t, "rest", f"Rested ({result})." if result else "Rested."))
        elif action.startswith("step:"):
            self.events.append(Event(t, "log", f"{action[5:].strip()}: {result}"))
        elif action in ("stuck", "finish", "logout", "connection"):
            self.events.append(Event(t, "state" if action != "stuck" else "log", f"{action.capitalize()}: {result}"))
