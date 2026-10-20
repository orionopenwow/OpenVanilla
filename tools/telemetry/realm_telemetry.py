#!/usr/bin/env python3
"""Open Vanilla realm telemetry: gameplay data from the live realm, for balancing and bug hunting.

Once a minute it reads the characters that are online and stores, under a pseudonym (a keyed hash
of the character id, never the name or the account): level, XP, money, map, zone and position
(rounded to 1 yard), dead or alive. It also logs each quest's state changes (taken, objectives
done, turned in, dropped). Nothing else: no names, accounts, IP addresses, chat or devices.
Disclosed on www/privacy.html ("Gameplay data on the realm").

Runs on the server next to the realm stack (hetzner/telemetry_up.sh makes it a service). Reads the
game databases through `docker compose exec mariadb` and never writes to them.

  realm_telemetry.py --realm-dir /opt/wenilla-realm --db /var/lib/openvanilla-telemetry/realm.db
  realm_telemetry.py --prune-only            drop raw rows past --keep-days (default 30)

Positions in the database are only as fresh as the world server's last save of each character
(PlayerSave.Interval; telemetry_up.sh sets it to 60 s). tools/telemetry/report.py turns the data
into the findings: stuck spots, death spots, quests that are taken but rarely finished, XP per hour.
"""
import argparse, hashlib, hmac, os, secrets, sqlite3, subprocess, sys, time

# Real players only: the realm's own bot accounts (RNDBOT*) are left out.
Q_ONLINE = """SELECT c.guid, c.race, c.class, c.level, c.xp, c.money, c.map, c.zone,
 ROUND(c.position_x), ROUND(c.position_y), ROUND(c.position_z), c.totaltime,
 IF(k.player IS NULL, 0, 1)
 FROM classiccharacters.characters c
 JOIN classicrealmd.account a ON a.id = c.account
 LEFT JOIN (SELECT DISTINCT player FROM classiccharacters.corpse) k ON k.player = c.guid
 WHERE c.online = 1 AND a.username NOT LIKE 'RNDBOT%'"""
Q_QUESTS = """SELECT q.guid, q.quest, q.status, q.rewarded
 FROM classiccharacters.character_queststatus q
 JOIN classiccharacters.characters c ON c.guid = q.guid
 WHERE c.online = 1"""
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
    CREATE TABLE IF NOT EXISTS who(pid TEXT PRIMARY KEY, race INT, class INT, first INT);
    CREATE TABLE IF NOT EXISTS snap(t INT, pid TEXT, level INT, xp INT, money INT, map INT, zone INT,
      x INT, y INT, z INT, totaltime INT, dead INT);
    CREATE INDEX IF NOT EXISTS snap_p ON snap(pid, t);
    CREATE INDEX IF NOT EXISTS snap_t ON snap(t);
    CREATE TABLE IF NOT EXISTS quest(t INT, pid TEXT, quest INT, status INT, rewarded INT);
    CREATE INDEX IF NOT EXISTS quest_q ON quest(quest, t);
    CREATE TABLE IF NOT EXISTS xp_for_level(level INTEGER PRIMARY KEY, xp INT);
    CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
    """)
    return db


def salt(db):
    """The key behind the pseudonyms, made once and kept only in this database."""
    row = db.execute("SELECT v FROM meta WHERE k = 'salt'").fetchone()
    if row:
        return row[0].encode()
    s = secrets.token_hex(32)
    db.execute("INSERT INTO meta VALUES ('salt', ?)", (s,))
    db.commit()
    return s.encode()


def pid_of(key, guid):
    return hmac.new(key, str(guid).encode(), hashlib.sha256).hexdigest()[:16]


def poll(db, key, realm_dir, last_q):
    t = int(time.time())
    rows = sql(realm_dir, Q_ONLINE)
    for r in rows:
        pid = pid_of(key, int(r[0]))
        db.execute("INSERT OR IGNORE INTO who VALUES (?,?,?,?)", (pid, int(r[1]), int(r[2]), t))
        db.execute("INSERT INTO snap VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                   (t, pid, int(r[3]), int(r[4]), int(r[5]), int(r[6]), int(r[7]),
                    int(float(r[8])), int(float(r[9])), int(float(r[10])), int(r[11]), int(r[12])))
    changed = 0
    for r in sql(realm_dir, Q_QUESTS):
        guid, quest, status, rewarded = int(r[0]), int(r[1]), int(r[2]), int(r[3])
        k = (guid, quest)
        if last_q.get(k) != (status, rewarded):
            if k in last_q or status != 0:
                db.execute("INSERT INTO quest VALUES (?,?,?,?,?)", (t, pid_of(key, guid), quest, status, rewarded))
                changed += 1
            last_q[k] = (status, rewarded)
    db.commit()
    return len(rows), changed


def prune(db, keep_days):
    cut = int(time.time()) - keep_days * 86400
    n = db.execute("DELETE FROM snap WHERE t < ?", (cut,)).rowcount
    db.execute("DELETE FROM quest WHERE t < ?", (cut,))
    db.commit()
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--realm-dir", default="/opt/wenilla-realm")
    ap.add_argument("--db", default="/var/lib/openvanilla-telemetry/realm.db")
    ap.add_argument("--every", type=int, default=60)
    ap.add_argument("--keep-days", type=int, default=30)
    ap.add_argument("--prune-only", action="store_true")
    a = ap.parse_args()
    db = open_db(a.db)
    if a.prune_only:
        print("pruned", prune(db, a.keep_days), "rows")
        return
    key = salt(db)
    if not db.execute("SELECT 1 FROM xp_for_level LIMIT 1").fetchone():
        try:
            for lvl, xp in sql(a.realm_dir, Q_XP):
                db.execute("INSERT OR REPLACE INTO xp_for_level VALUES (?,?)", (int(lvl), int(xp)))
            db.commit()
        except Exception as e:
            print("xp table not read:", e, file=sys.stderr)
    last_q, last_prune = {}, 0
    while True:
        t0 = time.time()
        try:
            n, ch = poll(db, key, a.realm_dir, last_q)
            print(f"{time.strftime('%H:%M:%S')} online={n} quest_changes={ch}", flush=True)
        except Exception as e:
            print(f"{time.strftime('%H:%M:%S')} poll failed: {e}", flush=True)
        if time.time() - last_prune > 86400:
            prune(db, a.keep_days)
            last_prune = time.time()
        time.sleep(max(1, a.every - (time.time() - t0)))


if __name__ == "__main__":
    main()
