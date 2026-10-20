"""Reading and writing the realm's own tables (accounts, characters, the realm list).

Talks to MySQL/MariaDB with PyMySQL and parameterised queries only. Column sets differ a little
between CMaNGOS versions (SPP's build vs. the wenilla-realm image), so optional columns are
looked up once with SHOW COLUMNS instead of being assumed.
"""
import re
import threading

import pymysql

NAME_RE = re.compile(r"^[A-Za-z0-9]{3,16}$")
PASS_RE = re.compile(r"^[A-Za-z0-9]{4,16}$")


class RealmDataError(RuntimeError):
    pass


class SqlRealmData:
    def __init__(self, host, port, user, password, realmd="classicrealmd", characters="classiccharacters", world="classicmangos"):
        self.cfg = dict(host=host, port=int(port), user=user, password=password)
        self.dbs = {"realmd": realmd, "characters": characters, "world": world}
        self._cols = {}
        self._lock = threading.Lock()

    # plumbing ---------------------------------------------------------------------------
    def _conn(self, db):
        try:
            return pymysql.connect(database=self.dbs[db], connect_timeout=4, read_timeout=15, write_timeout=15,
                                   charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor, autocommit=True, **self.cfg)
        except pymysql.MySQLError as e:
            raise RealmDataError(f"can't reach the database ({e.args[-1] if e.args else e})") from e

    def q(self, db, sql, args=None):
        with self._conn(db) as c, c.cursor() as cur:
            cur.execute(sql, args or ())
            return cur.fetchall()

    def x(self, db, sql, args=None):
        with self._conn(db) as c, c.cursor() as cur:
            n = cur.execute(sql, args or ())
            return n, cur.lastrowid

    def columns(self, db, table):
        key = (db, table)
        with self._lock:
            if key in self._cols:
                return self._cols[key]
        try:
            cols = {r["Field"] for r in self.q(db, f"SHOW COLUMNS FROM `{table}`")}
        except (RealmDataError, pymysql.MySQLError):
            cols = set()
        with self._lock:
            self._cols[key] = cols
        return cols

    def ping(self):
        try:
            self.q("realmd", "SELECT 1 AS ok")
            return True
        except (RealmDataError, pymysql.MySQLError):
            return False

    # accounts ---------------------------------------------------------------------------
    def auth_row(self, username):
        rows = self.q("realmd", "SELECT id, username, s, v, gmlevel FROM account WHERE username=%s", (username.upper(),))
        return rows[0] if rows else None

    def _banned_ids(self):
        cols = self.columns("realmd", "account_banned")
        if not cols or "active" not in cols:
            return set()
        key = "account_id" if "account_id" in cols else "id"
        return {r["a"] for r in self.q("realmd", f"SELECT `{key}` AS a FROM account_banned WHERE active=1")}

    def list_accounts(self, query="", limit=50, offset=0, role=None):
        cols = self.columns("realmd", "account")
        extra = ", ".join(f"`{c}`" for c in ("joindate", "last_login", "locked", "email") if c in cols)
        where, args = [], []
        if query:
            where.append("username LIKE %s")
            args.append(f"%{query.upper()}%")
        if role is not None:
            where.append("gmlevel >= %s")
            args.append(int(role))
        w = (" WHERE " + " AND ".join(where)) if where else ""
        total = self.q("realmd", f"SELECT COUNT(*) AS n FROM account{w}", args)[0]["n"]
        rows = self.q("realmd", f"SELECT id, username, gmlevel{', ' + extra if extra else ''} FROM account{w} "
                                "ORDER BY gmlevel DESC, id DESC LIMIT %s OFFSET %s", args + [int(limit), int(offset)])
        banned = self._banned_ids()
        ids = [r["id"] for r in rows]
        chars = {}
        if ids:
            ph = ",".join(["%s"] * len(ids))
            for c in self.q("characters", f"SELECT account, name, level, race, class, online FROM characters "
                                          f"WHERE account IN ({ph}) ORDER BY level DESC", ids):
                chars.setdefault(c["account"], []).append(c)
        out = []
        for r in rows:
            cs = chars.get(r["id"], [])
            out.append({
                "id": r["id"], "username": r["username"], "gmlevel": int(r["gmlevel"] or 0),
                "joindate": _iso(r.get("joindate")), "last_login": _iso(r.get("last_login")),
                "banned": r["id"] in banned, "online": any(c["online"] for c in cs),
                "characters": [{"name": c["name"], "level": c["level"], "race": c["race"], "class": c["class"],
                                "online": bool(c["online"])} for c in cs],
            })
        return {"total": total, "rows": out}

    def account(self, account_id):
        rows = self.q("realmd", "SELECT id, username, gmlevel FROM account WHERE id=%s", (int(account_id),))
        if not rows:
            raise RealmDataError("no such account")
        r = rows[0]
        return {"id": r["id"], "username": r["username"], "gmlevel": int(r["gmlevel"] or 0)}

    def set_gmlevel(self, account_id, level):
        self.x("realmd", "UPDATE account SET gmlevel=%s WHERE id=%s", (int(level), int(account_id)))

    def set_verifier(self, account_id, s_hex, v_hex):
        self.x("realmd", "UPDATE account SET s=%s, v=%s WHERE id=%s", (s_hex, v_hex, int(account_id)))

    def create_account(self, username, s_hex, v_hex, gmlevel=0):
        cols = self.columns("realmd", "account")
        try:
            if "joindate" in cols:
                _, new_id = self.x("realmd", "INSERT INTO account (username, s, v, gmlevel, joindate) VALUES (%s,%s,%s,%s,NOW())",
                                   (username.upper(), s_hex, v_hex, int(gmlevel)))
            else:
                _, new_id = self.x("realmd", "INSERT INTO account (username, s, v, gmlevel) VALUES (%s,%s,%s,%s)",
                                   (username.upper(), s_hex, v_hex, int(gmlevel)))
        except pymysql.err.IntegrityError as e:
            raise RealmDataError("that account name is already taken") from e
        return new_id

    def online_players(self):
        return self.q("characters", "SELECT name, level, race, class, account FROM characters WHERE online=1 ORDER BY name LIMIT 500")

    def counts(self):
        a = self.q("realmd", "SELECT COUNT(*) AS n FROM account")[0]["n"]
        c = self.q("characters", "SELECT COUNT(*) AS n, SUM(online) AS o FROM characters")[0]
        return {"accounts": a, "characters": c["n"] or 0, "online": int(c["o"] or 0)}

    # realm list -------------------------------------------------------------------------
    def realm(self):
        rows = self.q("realmd", "SELECT id, name, address, port FROM realmlist ORDER BY id LIMIT 1")
        if not rows:
            raise RealmDataError("the realm list is empty")
        return rows[0]

    def set_realm(self, realm_id, name=None, address=None):
        if name is not None:
            self.x("realmd", "UPDATE realmlist SET name=%s WHERE id=%s", (name, int(realm_id)))
        if address is not None:
            self.x("realmd", "UPDATE realmlist SET address=%s WHERE id=%s", (address, int(realm_id)))


def _iso(v):
    if v is None:
        return None
    try:
        return v.isoformat(sep=" ")
    except AttributeError:
        return str(v)
