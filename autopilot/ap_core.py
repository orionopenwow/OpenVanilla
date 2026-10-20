"""Herald Autopilot: the parts with no window — goals, rules, class defaults, session numbers.

Autopilot plays a character on realms that ALLOW it. The realm decides (its /api/autopilot/realm
says autoplay_allowed), a character on autopilot carries a visible [Autopilot] tag in game, and
there is deliberately nothing here to hide from a realm's staff: no "anti-ban", no fake human
delays, no logging out when a GM whispers. On a realm that does not allow it, START stays off.

Everything the player sets is a Rule: one plain sentence with one choice in it
("Rest when health is below [35%]"). Each class starts from sensible defaults; the realm's learned
profiles (ap_learn.py, built from opted-in players' anonymous session stats) can tune those
defaults, and the player's own choices always win over both.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field

CLASSES = ("Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock", "Druid")
CASTERS = {"Paladin", "Hunter", "Priest", "Shaman", "Mage", "Warlock", "Druid"}  # have mana
HEALERS = {"Paladin", "Priest", "Shaman", "Druid"}
TANKS = {"Warrior", "Paladin", "Druid"}


# --------------------------------------------------------------------------------------- goals
@dataclass(frozen=True)
class Goal:
    id: str
    label: str
    blurb: str
    icon: str                      # asset name: goal_<icon>.png
    strategies: tuple = ()         # what the realm's bot AI is asked to do (non-combat strategies)
    needs_group: bool = False


# strategies are the realm bot AI's own words (cmangos/playerbots: .bot cmd <name> nc +grind,+quest)
GOALS = (
    Goal("level", "Level up", "Fights, quests and travels where your level fits best.", "level",
         ("+grind", "+rpg", "+rpg quest", "+travel", "+loot", "+food", "+quest")),
    Goal("quest", "Quest", "Takes and finishes quests in your zone.", "quest",
         ("+rpg", "+rpg quest", "+quest", "+travel", "+loot", "+food", "-grind")),
    Goal("gather", "Gather", "Mines and picks herbs (needs the profession).", "gather",
         ("+gather", "+loot", "+food", "+travel", "-rpg")),
    Goal("follow", "Follow me", "Follows your other character and helps it fight.", "follow",
         ("+follow", "+loot", "+food", "-grind", "-rpg", "-travel")),
    Goal("dungeon", "Dungeon", "Plays your role in your group's dungeon run.", "dungeon",
         ("+follow", "+loot", "+food", "-grind", "-rpg", "-travel"), needs_group=True),
)
GOAL_BY_ID = {g.id: g for g in GOALS}


# --------------------------------------------------------------------------------------- rules
@dataclass(frozen=True)
class Rule:
    key: str
    before: str                    # sentence text before the choice
    after: str                     # sentence text after the choice
    options: tuple                 # (value, label) pairs
    for_classes: frozenset | None = None   # None = every class
    group: str = "Fighting"

    def labels(self):
        return [label for _, label in self.options]

    def label_of(self, value):
        for v, label in self.options:
            if v == value:
                return label
        return str(value)

    def value_of(self, label):
        for v, lab in self.options:
            if lab == label:
                return v
        raise KeyError(label)

    def applies(self, cls):
        return self.for_classes is None or cls in self.for_classes

    def sentence(self, value):
        return f"{self.before}{self.label_of(value)}{self.after}"


_PCT = lambda vals: tuple((v, f"{v}%") for v in vals)  # noqa: E731

RULES = (
    Rule("rest_hp", "Rest when health is below ", "", _PCT((20, 25, 30, 35, 40, 50, 60)), group="Resting"),
    Rule("rest_mana", "Drink when mana is below ", "", _PCT((10, 15, 20, 25, 30, 40, 50)),
         frozenset(CASTERS), group="Resting"),
    Rule("pull", "Fight ", " at a time", (("one", "one enemy"), ("two", "up to two enemies"), ("any", "any number of enemies"))),
    Rule("danger", "Drink a potion below ", " health in a fight", _PCT((10, 15, 20, 25, 30))),
    Rule("role", "In a group, play as ", "", (("dps", "damage"), ("tank", "the tank"), ("heal", "the healer")),
         frozenset(TANKS | HEALERS), group="Groups"),
    Rule("bags", "When bags are full, ", "", (("vendor", "sell greys and come back"), ("stop", "go home and stop"),
                                             ("ignore", "keep going, loot nothing new")), group="Loot"),
    Rule("keep", "Keep ", "", (("quest", "quest items"), ("green", "quest items and greens"), ("all", "everything")),
         group="Loot"),
    Rule("stop", "Stop ", "", (("30m", "after 30 minutes"), ("1h", "after an hour"), ("2h", "after two hours"),
                               ("ding", "at my next level"), ("never", "only when I say")), group="Session"),
)
RULE_BY_KEY = {r.key: r for r in RULES}

BASE_DEFAULTS = {"rest_hp": 35, "rest_mana": 25, "pull": "one", "danger": 20, "role": "dps",
                 "bags": "vendor", "keep": "quest", "stop": "1h"}

CLASS_DEFAULTS = {  # only what differs from BASE_DEFAULTS
    "Warrior": {"rest_hp": 50, "pull": "one", "role": "dps"},
    "Paladin": {"rest_hp": 30, "rest_mana": 20, "pull": "two"},
    "Hunter": {"rest_hp": 35, "rest_mana": 20, "pull": "two"},
    "Rogue": {"rest_hp": 50, "pull": "one"},
    "Priest": {"rest_hp": 40, "rest_mana": 30, "role": "heal"},
    "Shaman": {"rest_hp": 35, "rest_mana": 25},
    "Mage": {"rest_hp": 40, "rest_mana": 30, "danger": 25},
    "Warlock": {"rest_hp": 30, "rest_mana": 20, "pull": "two"},
    "Druid": {"rest_hp": 35, "rest_mana": 25},
}


def level_band(level):
    """1–9, 10–19 … 50–59, 60: what learned profiles are keyed by."""
    level = max(1, min(60, int(level or 1)))
    if level >= 60:
        return "60"
    lo = (level // 10) * 10
    return f"{max(1, lo)}-{lo + 9}"


def defaults_for(cls, level=1, profiles=None):
    """The class's starting rules, tuned by the realm's learned profile for this level band."""
    out = dict(BASE_DEFAULTS)
    out.update(CLASS_DEFAULTS.get(cls, {}))
    learned = ((profiles or {}).get("classes", {}).get(cls, {}).get(level_band(level), {}))
    for key, entry in learned.items():
        value = entry.get("value") if isinstance(entry, dict) else entry
        rule = RULE_BY_KEY.get(key)
        if rule and any(v == value for v, _ in rule.options):
            out[key] = value
    return {k: v for k, v in out.items() if RULE_BY_KEY[k].applies(cls)}


def learned_note(cls, level, profiles):
    """'Tuned from 1,204 sessions' or '' — shown above the rules."""
    band = (profiles or {}).get("classes", {}).get(cls, {}).get(level_band(level), {})
    n = max((e.get("sessions", 0) for e in band.values() if isinstance(e, dict)), default=0)
    return f"Tuned from {n:,} players' sessions" if n else ""


def merged_rules(cls, level, chosen, profiles=None):
    """Defaults, then the player's own choices on top (theirs always win)."""
    out = defaults_for(cls, level, profiles)
    for k, v in (chosen or {}).items():
        if k in out:
            out[k] = v
    return out


def stop_after_seconds(rules):
    return {"30m": 1800, "1h": 3600, "2h": 7200}.get(rules.get("stop"))


def plan(cls, goal_id, rules):
    """What the realm is asked to do: the bot AI's strategies, in its own words."""
    goal = GOAL_BY_ID[goal_id]
    combat = {"tank": "+tank", "heal": "+heal"}.get(rules.get("role"), "+dps")
    if goal_id != "dungeon" and combat != "+dps" and cls not in HEALERS | TANKS:
        combat = "+dps"
    return {
        "goal": goal.id,
        "combat": [combat],
        "noncombat": list(goal.strategies),
        "rules": dict(rules),
    }


# ------------------------------------------------------------------------------------- money/time
def money(copper):
    copper = int(copper or 0)
    g, rest = divmod(copper, 10000)
    s, c = divmod(rest, 100)
    parts = ([f"{g}g"] if g else []) + ([f"{s}s"] if s or g else []) + [f"{c}c"]
    return " ".join(parts[:2]) if g else " ".join(parts)


def clock(seconds):
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


# ---------------------------------------------------------------------------------------- session
@dataclass
class Session:
    """One autopilot run: the numbers on the Play and Session pages."""
    character: str = ""
    cls: str = ""
    goal: str = "level"
    started: float = field(default_factory=time.time)
    ended: float | None = None
    xp: int = 0
    kills: int = 0
    deaths: int = 0
    loot_copper: int = 0
    items: int = 0
    rests: int = 0
    levels: int = 0
    quests: int = 0
    nodes: int = 0
    timeline: list = field(default_factory=list)   # (t, kind, text)
    paused_for: float = 0.0
    _paused_at: float | None = None

    def elapsed(self, now=None):
        now = self.ended or now or time.time()
        paused = self.paused_for + ((now - self._paused_at) if self._paused_at else 0)
        return max(0.0, now - self.started - paused)

    def pause(self, now=None):
        if self._paused_at is None:
            self._paused_at = now or time.time()

    def resume(self, now=None):
        if self._paused_at is not None:
            self.paused_for += (now or time.time()) - self._paused_at
            self._paused_at = None

    @property
    def paused(self):
        return self._paused_at is not None

    def per_hour(self, value, now=None):
        hours = self.elapsed(now) / 3600
        return int(value / hours) if hours > 1 / 120 else 0

    def apply(self, ev):
        """Count one event from the realm link (ap_link.Event)."""
        k, d = ev.kind, ev.data or {}
        if k == "kill":
            self.kills += 1
            self.xp += int(d.get("xp", 0))
        elif k == "xp":
            self.xp += int(d.get("xp", 0))
        elif k == "loot":
            self.loot_copper += int(d.get("copper", 0))
            self.items += int(d.get("items", 0))
        elif k == "death":
            self.deaths += 1
        elif k == "rest":
            self.rests += 1
        elif k == "level":
            self.levels += 1
        elif k == "quest":
            self.quests += 1
            self.xp += int(d.get("xp", 0))
        elif k == "gather":
            self.nodes += 1
        if k in ("kill", "death", "level", "quest", "vendor", "gather", "state") or (k == "loot" and d.get("notable")):
            self.timeline.append((ev.t, k, ev.text))
            del self.timeline[:-400]

    def summary(self, now=None):
        return {
            "minutes": round(self.elapsed(now) / 60, 1),
            "xp": self.xp, "xp_per_hour": self.per_hour(self.xp, now),
            "kills": self.kills, "deaths": self.deaths, "rests": self.rests,
            "loot_copper": self.loot_copper, "levels": self.levels, "quests": self.quests, "nodes": self.nodes,
        }
