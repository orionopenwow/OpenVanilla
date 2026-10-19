"""Herald learns from how people play — only if they say yes, and only anonymous numbers.

What is recorded (nothing else):
  session  class, level band (10-19 …), goal, minutes, XP/hour, kills, deaths, rests, levels and
           the rules that were in force
  death    class, level band, goal, the rest/pull rules, how many extra enemies, the level gap
  change   class, level band, which rule the player changed, from what, to what, and whether it
           was right after a death
No character or account names, no realm address, no chat, no positions; dates are the day only.
A random install id (new every month) lets the realm drop duplicate uploads; it ties to nothing.

When it is sent: in one small gzip batch (a few KB) when a session ends, or when the program has
been idle a while — never mid-run, at most once every 30 minutes, and after a failure it waits
longer each time. Nothing is sent before the player answers the first-run question with yes;
Settings shows the exact text that would go next, and turning learning off deletes what's queued.

What comes back: the realm turns everyone's batches into profiles.json (hetzner/
herald_autopilot_api.py): for each class and level band, the rule values that gave the best XP
per hour without dying. Those become Herald's defaults (ap_core.defaults_for). They are data,
checked against the rule list, never code; the player's own choices always win.
"""
from __future__ import annotations

import gzip
import json
import os
import secrets
import threading
import time
import urllib.error
import urllib.request

from ap_core import level_band

CLIENT = "herald-autopilot/1.0"
MIN_GAP = 30 * 60          # seconds between uploads
IDLE_AFTER = 5 * 60        # idle this long (not running) before an idle upload
MAX_RECORDS = 300          # kept on disk at most (oldest dropped)
MAX_BATCH_BYTES = 16_000   # gzip size cap per upload
RULE_KEYS = ("rest_hp", "rest_mana", "pull", "danger", "role", "bags", "keep", "stop")


def _day(t):
    return time.strftime("%Y-%m-%d", time.gmtime(t))


class Learner:
    def __init__(self, folder, base_url=None, opener=None, clock=time.time):
        self.folder = folder
        self.base = (base_url or "").rstrip("/")
        self._open = opener or urllib.request.urlopen
        self.clock = clock
        os.makedirs(folder, exist_ok=True)
        self._cfg_path = os.path.join(folder, "learning.json")
        self._queue_path = os.path.join(folder, "learning_queue.jsonl")
        self._profiles_path = os.path.join(folder, "profiles.json")
        self.cfg = self._load(self._cfg_path, {})
        self.lock = threading.Lock()
        self.last_activity = clock()
        self.last_result = ""

    # ---------------------------------------------------------------------------- consent
    @property
    def consent(self):
        """None = not asked yet, True / False = the player's answer."""
        return self.cfg.get("consent")

    def set_consent(self, yes):
        self.cfg["consent"] = bool(yes)
        if not yes:
            self.clear()
        self._save_cfg()

    def install_id(self):
        month = time.strftime("%Y-%m", time.gmtime(self.clock()))
        if self.cfg.get("id_month") != month or not self.cfg.get("install"):
            self.cfg["install"] = secrets.token_hex(8)
            self.cfg["id_month"] = month
            self._save_cfg()
        return self.cfg["install"]

    # ---------------------------------------------------------------------------- recording
    def _clean_rules(self, rules):
        return {k: rules[k] for k in RULE_KEYS if k in (rules or {})}

    def record(self, rec):
        if self.consent is not True:
            return False
        rec = dict(rec)
        rec["day"] = _day(self.clock())
        with self.lock:
            lines = self._read_queue()
            lines.append(json.dumps(rec, separators=(",", ":")))
            self._write_queue(lines[-MAX_RECORDS:])
        return True

    def note_session(self, cls, level, goal, summary, rules):
        if summary.get("minutes", 0) < 2:   # a start-and-stop tells nothing
            return False
        keep = ("minutes", "xp_per_hour", "kills", "deaths", "rests", "levels", "quests", "nodes")
        return self.record({"type": "session", "cls": cls, "band": level_band(level), "goal": goal,
                            **{k: summary.get(k, 0) for k in keep}, "rules": self._clean_rules(rules)})

    def note_death(self, cls, level, goal, data):
        return self.record({"type": "death", "cls": cls, "band": level_band(level), "goal": goal,
                            "rest_hp": data.get("rest_hp"), "pull": data.get("pull"),
                            "adds": int(data.get("adds", 0)), "gap": int(data.get("mob_level_diff", 0))})

    def note_change(self, cls, level, key, old, new, after_death=False):
        if key not in RULE_KEYS or old == new:
            return False
        return self.record({"type": "change", "cls": cls, "band": level_band(level), "key": key,
                            "from": old, "to": new, "after_death": bool(after_death)})

    def touch(self):
        self.last_activity = self.clock()

    # ---------------------------------------------------------------------------- sending
    def pending(self):
        with self.lock:
            return len(self._read_queue())

    def batch(self):
        """(payload_bytes_gzip, n_records, json_text) for the records that fit one upload."""
        with self.lock:
            lines = self._read_queue()
        recs = []
        for line in lines:
            try:
                recs.append(json.loads(line))
            except ValueError:
                continue
        n = len(recs)
        while True:
            body = {"v": 1, "client": CLIENT, "install": self.install_id(), "records": recs[:n]}
            text = json.dumps(body, separators=(",", ":"))
            gz = gzip.compress(text.encode(), 6)
            if len(gz) <= MAX_BATCH_BYTES or n <= 1:
                return gz, n, text
            n = max(1, n // 2)

    def preview(self):
        """The exact JSON the next upload would send (pretty), for the Settings page."""
        if not self.pending():
            return "Nothing queued."
        _, _, text = self.batch()
        return json.dumps(json.loads(text), indent=1)

    def due(self, running, session_ended=False):
        if self.consent is not True or not self.base or running or not self.pending():
            return False
        now = self.clock()
        if now < self.cfg.get("retry_at", 0):
            return False
        if now - self.cfg.get("last_upload", 0) < MIN_GAP:
            return False
        return session_ended or now - self.last_activity >= IDLE_AFTER

    def upload(self):
        """Send one batch now. Returns (ok, message)."""
        gz, n, _ = self.batch()
        if not n:
            return True, "Nothing to send."
        req = urllib.request.Request(self.base + "/api/herald/learn", data=gz, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Content-Encoding", "gzip")
        req.add_header("User-Agent", CLIENT)
        now = self.clock()
        try:
            with self._open(req, timeout=10) as r:
                ok = 200 <= r.status < 300
        except urllib.error.HTTPError as e:
            ok = False
            if e.code in (400, 413, 422):   # the realm will never take these: drop them
                self._drop(n)
                self.last_result = f"The realm refused {n} records ({e.code}); dropped."
                return False, self.last_result
        except Exception:
            ok = False
        if ok:
            self._drop(n)
            self.cfg["last_upload"] = now
            self.cfg["fails"] = 0
            self.cfg.pop("retry_at", None)
            self.last_result = f"Shared {n} records ({len(gz):,} bytes)."
        else:
            fails = self.cfg.get("fails", 0) + 1
            self.cfg["fails"] = fails
            self.cfg["retry_at"] = now + min(6 * 3600, 300 * 2 ** (fails - 1))
            self.last_result = "Couldn't reach the realm; will try later."
        self._save_cfg()
        return ok, self.last_result

    def maybe_upload(self, running, session_ended=False):
        if self.due(running, session_ended):
            return self.upload()
        return None

    def clear(self):
        with self.lock:
            self._write_queue([])

    def _drop(self, n):
        with self.lock:
            lines = self._read_queue()
            self._write_queue(lines[n:])

    # ---------------------------------------------------------------------------- profiles
    def profiles(self):
        return self._load(self._profiles_path, {})

    def fetch_profiles(self):
        """Download the realm's learned defaults (if changed). Returns the profiles dict."""
        cached = self.profiles()
        if not self.base:
            return cached
        req = urllib.request.Request(self.base + "/api/herald/profiles.json")
        if cached.get("_etag"):
            req.add_header("If-None-Match", cached["_etag"])
        try:
            with self._open(req, timeout=8) as r:
                data = json.loads(r.read().decode() or "{}")
                if not valid_profiles(data):
                    return cached
                data["_etag"] = r.headers.get("ETag", "") if getattr(r, "headers", None) else ""
                self._save(self._profiles_path, data)
                return data
        except urllib.error.HTTPError as e:
            return cached if e.code == 304 else cached
        except Exception:
            return cached

    # ---------------------------------------------------------------------------- files
    def _read_queue(self):
        try:
            with open(self._queue_path, encoding="utf-8") as f:
                return [ln.rstrip("\n") for ln in f if ln.strip()]
        except OSError:
            return []

    def _write_queue(self, lines):
        tmp = self._queue_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("".join(ln + "\n" for ln in lines))
        os.replace(tmp, self._queue_path)

    def _save_cfg(self):
        self._save(self._cfg_path, self.cfg)

    @staticmethod
    def _load(path, default):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return default

    @staticmethod
    def _save(path, data):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1)
        os.replace(tmp, path)


def valid_profiles(data):
    if not isinstance(data, dict) or not isinstance(data.get("classes", {}), dict):
        return False
    for cls, bands in data.get("classes", {}).items():
        if not isinstance(bands, dict):
            return False
        for band, rules in bands.items():
            if not isinstance(rules, dict):
                return False
    return True
