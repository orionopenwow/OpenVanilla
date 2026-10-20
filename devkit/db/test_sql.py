#!/usr/bin/env python3
"""Apply Open Vanilla's SQL to a throwaway database twice and check the results.

    py -3 devkit/db/test_sql.py                 start devkit/db/compose.yaml (Docker), test, stop it
    py -3 devkit/db/test_sql.py --keep          leave the database running afterwards (port 33306)
    python3 devkit/db/test_sql.py --local       Linux/CI without Docker: a private mariadbd in a temp dir

Loads devkit/db/fixtures (the stock classic-db rows our SQL touches), then runs the realm's SQL
in the order openvanilla_realm_up.sh does: races, weapons, starpouch, the retired vendor cleanup
(classicmangos). Before that it plants the retired vendor NPC 990001 (as an older realm still has
it) so the cleanup has something to remove. It runs the files a second time and checks nothing
changed (every file must be safe to re-run), then checks what the files are for. Exit 0 = all good.
"""
import hashlib
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SQL = os.path.join(ROOT, "realm", "classicplus")
FIX = os.path.join(HERE, "fixtures")
ORDER = [("classicmangos", "classicplus_races.sql"), ("classicmangos", "classicplus_weapons.sql"),
         ("classicmangos", "classicplus_starpouch.sql"),
         ("classicmangos", "classicplus_retired_vendor_cleanup.sql")]
# What an older realm still holds: NPC 990001 (a copy of a stock vendor, 6548), its two spawns and
# its vendor list, and item 990101 (a copy of a stock firework, 21591) that players may own.
OLD_WORLD = """
CREATE TEMPORARY TABLE t_npc SELECT * FROM creature_template WHERE Entry = 6548;
UPDATE t_npc SET Entry = 990001, Name = 'Old Vendor';
INSERT INTO creature_template SELECT * FROM t_npc;
INSERT INTO creature (guid, id, map, position_x, position_y, position_z, orientation) VALUES
  (9100001, 990001, 0, -8925.9, 608.6, 99.61, 3.63), (9100002, 990001, 1, 1617.5, -4372.5, 11.81, 0.30);
CREATE TEMPORARY TABLE t_item SELECT * FROM item_template WHERE entry = 21591;
UPDATE t_item SET entry = 990101, name = 'Old Crate', description = 'Old.';
INSERT INTO item_template SELECT * FROM t_item;
INSERT INTO npc_vendor (entry, item) VALUES (990001, 990101);
"""
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok or not detail else ": " + detail))


class DB:
    def __init__(self, args):
        self.args = args

    def run(self, sql=None, db=None, path=None):
        cmd = self.args + ([db] if db else [])
        data = open(path, "rb").read() if path else sql.encode()
        p = subprocess.run(cmd, input=data, capture_output=True)
        if p.returncode != 0:
            raise RuntimeError((path or sql[:80]) + ": " + p.stderr.decode(errors="replace").strip()[:400])
        return p.stdout.decode(errors="replace")

    def value(self, sql, db=None):
        out = self.run(sql, db).strip().splitlines()
        return out[0] if out else ""


def client():
    for c in ("mariadb", "mysql"):
        if shutil.which(c):
            return c
    sys.exit("Needs the mariadb (or mysql) command-line client on PATH.")


def start_local():
    d = tempfile.mkdtemp(prefix="owdb-")
    sock = os.path.join(d, "s.sock")
    srv = shutil.which("mariadbd") or shutil.which("mysqld") or "/usr/sbin/mariadbd"
    inst = shutil.which("mariadb-install-db") or shutil.which("mysql_install_db")
    # --no-defaults: the system's my.cnf (newer Ubuntu images) puts the PID file in /run/mysqld, which a
    # normal user can't write, so the server would stop right after starting
    subprocess.run([inst, "--no-defaults", f"--datadir={d}/data", "--auth-root-authentication-method=normal",
                    "--skip-test-db", "--user=" + os.environ.get("USER", "root")], check=True, capture_output=True)
    log = os.path.join(d, "mariadbd.log")
    proc = subprocess.Popen([srv, "--no-defaults", f"--datadir={d}/data", f"--socket={sock}", f"--pid-file={d}/m.pid",
                             "--skip-networking", "--user=" + os.environ.get("USER", "root")],
                            stdout=subprocess.DEVNULL, stderr=open(log, "w"))
    for _ in range(60):
        if os.path.exists(sock):
            break
        time.sleep(0.5)
    args = [client(), "-uroot", f"--socket={sock}", "-N", "-B"]
    for _ in range(30):
        if subprocess.run(args + ["-e", "select 1"], capture_output=True).returncode == 0:
            return DB(args), lambda: (proc.terminate(), proc.wait(), shutil.rmtree(d, ignore_errors=True))
        time.sleep(0.5)
    try:
        tail = open(log, encoding="utf-8", errors="replace").read().splitlines()[-12:]
    except OSError:
        tail = []
    sys.exit("local mariadbd did not start" + "".join("\n  " + line for line in tail))


def start_docker(keep):
    compose = ["docker", "compose", "-f", os.path.join(HERE, "compose.yaml")]
    subprocess.run(compose + ["up", "-d", "--wait"], check=True)
    args = [client(), "-uroot", "-pdevkit", "-h127.0.0.1", "-P33306", "--protocol=TCP", "-N", "-B"]
    stop = (lambda: None) if keep else (lambda: subprocess.run(compose + ["down", "-v"], capture_output=True))
    for _ in range(60):
        if subprocess.run(args + ["-e", "select 1"], capture_output=True).returncode == 0:
            return DB(args), stop
        time.sleep(1)
    stop()
    sys.exit("the test database did not come up on 127.0.0.1:33306")


def fingerprint(db):
    """A checksum of every table in the three databases (rows only, order-free)."""
    rows = db.run("""SELECT CONCAT(table_schema, '.', table_name) FROM information_schema.tables
                     WHERE table_schema IN ('classicmangos', 'classicrealmd', 'classiccharacters')
                     AND table_type = 'BASE TABLE' ORDER BY 1""").split()
    out = {}
    for t in rows:
        out[t] = db.value(f"CHECKSUM TABLE {t}").split("\t")[-1]
    return out


def main():
    local = "--local" in sys.argv
    db, stop = start_local() if local else start_docker("--keep" in sys.argv)
    try:
        for name in ("classicmangos", "classicrealmd", "classiccharacters"):
            db.run(f"DROP DATABASE IF EXISTS {name}; CREATE DATABASE {name} DEFAULT CHARSET utf8mb4;")
        db.run(path=os.path.join(FIX, "classicmangos.sql"), db="classicmangos")
        db.run(path=os.path.join(FIX, "classiccharacters.sql"), db="classiccharacters")
        db.run(OLD_WORLD, db="classicmangos")
        stock = int(db.value("SELECT COUNT(*) FROM playercreateinfo", "classicmangos"))
        check("fixtures load (stock race/class pairs: %d)" % stock, stock == 40, f"{stock} rows")

        for i in (1, 2):
            for name, f in ORDER:
                try:
                    db.run(path=os.path.join(SQL, f), db=name)
                    if i == 1:
                        check(f"{f} applies", True)
                except RuntimeError as e:
                    check(f"{f} applies (pass {i})", False, str(e))
            if i == 1:
                first = fingerprint(db)
        second = fingerprint(db)
        changed = [t for t in first if first[t] != second.get(t)]
        check("every file is safe to run twice", not changed, "changed on the second run: " + ", ".join(changed))

        v = lambda q, d="classicmangos": db.value(q, d)
        pairs = int(v("SELECT COUNT(*) FROM playercreateinfo"))
        check(f"Classic+ race/class pairs added ({pairs})", pairs > stock, f"{pairs}")
        check("Human Hunter can be made", v("SELECT COUNT(*) FROM playercreateinfo WHERE race=1 AND class=3") == "1")
        missing = v("""SELECT COUNT(*) FROM playercreateinfo p WHERE NOT EXISTS
                       (SELECT 1 FROM playercreateinfo_action a WHERE a.race=p.race AND a.class=p.class)""")
        check("every pair has action buttons", missing == "0", f"{missing} pairs without")
        hunters = v("""SELECT GROUP_CONCAT(DISTINCT race) FROM playercreateinfo p WHERE class=3 AND NOT EXISTS
                       (SELECT 1 FROM playercreateinfo_skills s WHERE (s.raceMask=0 OR s.raceMask & (1 << (p.race-1)))
                        AND (s.classMask=0 OR s.classMask & 4) AND s.skill=45)""")
        check("every Hunter race starts with Bows (skill 45)", hunters in ("", "NULL"), f"races without: {hunters}")
        check("retired NPC 990001 is gone", v("SELECT COUNT(*) FROM creature_template WHERE entry=990001") == "0")
        check("its spawns are gone", v("SELECT COUNT(*) FROM creature WHERE guid IN (9100001, 9100002)") == "0")
        check("its vendor list is gone", v("SELECT COUNT(*) FROM npc_vendor WHERE entry=990001") == "0")
        check("item 990101 is kept for its owners, renamed",
              v("SELECT name FROM item_template WHERE entry=990101") == "Starfire Firework Crate")
    finally:
        stop()
    bad = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(bad)} passed, {len(bad)} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
