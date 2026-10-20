#!/usr/bin/env python3
"""Open Vanilla bot lab logger: snapshots every random bot (RNDBOT accounts) once a minute into SQLite.

Runs on the server next to the realm stack. Reads the database through `docker compose exec mariadb`
(no Python packages needed). Only reads; never writes to the game databases.

  botlab_logger.py --realm-dir /opt/wenilla-realm --db /var/lib/botlab/lab.db --hours 8 --every 60

Tables in lab.db:
  chars(guid, name, race, class)                       one row per bot character
  snap(t, guid, level, xp, money, map, zone, x, y, z, online, totaltime, dead)
  quest(t, guid, quest, status, rewarded)              a row each time a quest's state changes
  xp_for_level(level, xp)                              the realm's XP table (for XP/min across level-ups)
"""
import argparse, os, sqlite3, subprocess, sys, time

Q_CHARS = """SELECT c.guid, c.name, c.race, c.class, c.level, c.xp, c.money, c.map, c.zone,
 ROUND(c.position_x,1), ROUND(c.position_y,1), ROUND(c.position_z,1), c.online, c.totaltime,
 IF(k.player IS NULL, 0, 1)
 FROM classiccharacters.characters c
 JOIN classicrealmd.account a ON a.id = c.account
 LEFT JOIN (SELECT DISTINCT player FROM classiccharacters.corpse) k ON k.player = c.guid
 WHERE a.username LIKE 'RNDBOT%'"""
Q_QUESTS = """SELECT q.guid, q.quest, q.status, q.rewarded
 FROM classiccharacters.character_queststatus q
 JOIN classiccharacters.characters c ON c.guid = q.guid
 JOIN classicrealmd.account a ON a.id = c.account
 WHERE a.username LIKE 'RNDBOT%'"""
Q_XP = "SELECT lvl, xp_for_next_level FROM classicmangos.player_xp_for_level"


def _env(realm_dir):
    env = dict(os.environ)
    if not env.get("DB_ROOT_PASSWORD"):
        try:
            for line in open(os.path.join(realm_dir, ".env")):
                if line.startswith("DB_ROOT_PASSWORD="):
                    env["DB_ROOT_PASSWORD"] = line.split("=", 1)[1].strip().strip('"')
        except OSError:
            pass
    return env


def sql(realm_dir, query):
    env = _env(realm_dir)
    out = subprocess.run(
        ["docker", "compose", "exec", "-T", "-e", "MYSQL_PWD=" + env.get("DB_ROOT_PASSWORD", ""),
         "mariadb", "mariadb", "-uroot", "-N", "-B", "-e", query],
        cwd=realm_dir, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:300])
    return [line.split("\t") for line in out.stdout.splitlines() if line.strip()]


def open_db(path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript("""
    CREATE TABLE IF NOT EXISTS chars(guid INTEGER PRIMARY KEY, name TEXT, race INT, class INT);
    CREATE TABLE IF NOT EXISTS snap(t INT, guid INT, level INT, xp INT, money INT, map INT, zone INT,
      x REAL, y REAL, z REAL, online INT, totaltime INT, dead INT);
    CREATE INDEX IF NOT EXISTS snap_g ON snap(guid, t);
    CREATE TABLE IF NOT EXISTS quest(t INT, guid INT, quest INT, status INT, rewarded INT);
    CREATE INDEX IF NOT EXISTS quest_g ON quest(guid, quest, t);
    CREATE TABLE IF NOT EXISTS xp_for_level(level INTEGER PRIMARY KEY, xp INT);
    CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
    """)
    return db


def poll(db, realm_dir, last_q):
    t = int(time.time())
    rows = sql(realm_dir, Q_CHARS)
    for r in rows:
        guid, name, race, cls = int(r[0]), r[1], int(r[2]), int(r[3])
        db.execute("INSERT OR IGNORE INTO chars VALUES (?,?,?,?)", (guid, name, race, cls))
        db.execute("INSERT INTO snap VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   (t, guid, int(r[4]), int(r[5]), int(r[6]), int(r[7]), int(r[8]),
                    float(r[9]), float(r[10]), float(r[11]), int(r[12]), int(r[13]), int(r[14])))
    changed = 0
    for r in sql(realm_dir, Q_QUESTS):
        key = (int(r[0]), int(r[1]))
        state = (int(r[2]), int(r[3]))
        if last_q.get(key) != state:
            last_q[key] = state
            db.execute("INSERT INTO quest VALUES (?,?,?,?,?)", (t, key[0], key[1], state[0], state[1]))
            changed += 1
    db.commit()
    return len(rows), changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--realm-dir", default="/opt/wenilla-realm")
    ap.add_argument("--db", default="/var/lib/botlab/lab.db")
    ap.add_argument("--hours", type=float, default=8)
    ap.add_argument("--every", type=int, default=60)
    a = ap.parse_args()
    db = open_db(a.db)
    if not db.execute("SELECT 1 FROM xp_for_level LIMIT 1").fetchone():
        try:
            for lvl, xp in sql(a.realm_dir, Q_XP):
                db.execute("INSERT OR REPLACE INTO xp_for_level VALUES (?,?)", (int(lvl), int(xp)))
        except Exception as e:  # the report falls back to same-level XP only
            print("xp table not read:", e, file=sys.stderr)
    db.execute("INSERT OR REPLACE INTO meta VALUES ('started', ?)", (str(int(time.time())),))
    db.commit()
    last_q = {}
    for guid, quest, status, rewarded in db.execute(
            "SELECT guid, quest, status, rewarded FROM quest ORDER BY t"):
        last_q[(guid, quest)] = (status, rewarded)
    end = time.time() + a.hours * 3600
    while time.time() < end:
        t0 = time.time()
        try:
            n, ch = poll(db, a.realm_dir, last_q)
            print(f"{time.strftime('%H:%M:%S')} bots={n} quest_changes={ch}", flush=True)
        except Exception as e:
            print(f"{time.strftime('%H:%M:%S')} poll failed: {e}", flush=True)
        time.sleep(max(1, a.every - (time.time() - t0)))
    db.execute("INSERT OR REPLACE INTO meta VALUES ('ended', ?)", (str(int(time.time())),))
    db.commit()


if __name__ == "__main__":
    main()
