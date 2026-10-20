"""Studio's own state: the change journal, an event log and small settings, in one SQLite file.

Every change Studio makes to the realm is written here with what it did and what undoes it, so
the History screen can list it and Undo can reverse it. The file lives in studio_state/ next
to the server files and never holds passwords.
"""
import json
import os
import sqlite3
import threading
import time

_SCHEMA = """
CREATE TABLE IF NOT EXISTS changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts REAL NOT NULL,
  user TEXT NOT NULL,
  area TEXT NOT NULL,
  summary TEXT NOT NULL,
  kind TEXT NOT NULL,
  data TEXT NOT NULL,
  live INTEGER NOT NULL DEFAULT 1,
  undoable INTEGER NOT NULL DEFAULT 1,
  undone_by INTEGER
);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts REAL NOT NULL,
  level TEXT NOT NULL,
  text TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
"""


class Journal:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.path = path
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        with self._lock:
            self._db.executescript(_SCHEMA)
            self._db.commit()

    # changes ------------------------------------------------------------------------------
    def record(self, user, area, summary, kind, data, live=True, undoable=True):
        with self._lock:
            cur = self._db.execute(
                "INSERT INTO changes (ts, user, area, summary, kind, data, live, undoable) VALUES (?,?,?,?,?,?,?,?)",
                (time.time(), user, area, summary, kind, json.dumps(data), int(live), int(undoable)))
            self._db.commit()
            return cur.lastrowid

    def get(self, change_id):
        with self._lock:
            row = self._db.execute("SELECT * FROM changes WHERE id=?", (change_id,)).fetchone()
        return self._row(row) if row else None

    def mark_undone(self, change_id, by_id):
        with self._lock:
            self._db.execute("UPDATE changes SET undone_by=? WHERE id=?", (by_id, change_id))
            self._db.commit()

    def changes(self, limit=100, area=None):
        q, args = "SELECT * FROM changes", []
        if area:
            q += " WHERE area=?"
            args.append(area)
        q += " ORDER BY id DESC LIMIT ?"
        args.append(int(limit))
        with self._lock:
            rows = self._db.execute(q, args).fetchall()
        return [self._row(r) for r in rows]

    @staticmethod
    def _row(r):
        d = dict(r)
        d["data"] = json.loads(d["data"])
        d["live"] = bool(d["live"])
        d["undoable"] = bool(d["undoable"]) and d["undone_by"] is None
        return d

    # events -------------------------------------------------------------------------------
    def event(self, text, level="info"):
        with self._lock:
            self._db.execute("INSERT INTO events (ts, level, text) VALUES (?,?,?)", (time.time(), level, text))
            self._db.execute("DELETE FROM events WHERE id < (SELECT MAX(id) - 2000 FROM events)")
            self._db.commit()

    def events(self, limit=200):
        with self._lock:
            rows = self._db.execute("SELECT * FROM events ORDER BY id DESC LIMIT ?", (int(limit),)).fetchall()
        return [dict(r) for r in rows][::-1]

    # settings -----------------------------------------------------------------------------
    def setting(self, key, default=None):
        with self._lock:
            row = self._db.execute("SELECT v FROM kv WHERE k=?", (key,)).fetchone()
        return json.loads(row["v"]) if row else default

    def set_setting(self, key, value):
        with self._lock:
            self._db.execute("INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                             (key, json.dumps(value)))
            self._db.commit()
