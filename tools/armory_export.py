#!/usr/bin/env python3
"""The armory exporter: the realm's characters and guilds as static JSON for the website.

    python3 tools/armory_export.py --out www/armory [--realm classicplus] [--realm-name "Open Vanilla Classic+"]
        [--db-host 127.0.0.1 --db-port 3306 --db-user armory]   (password: ARMORY_DB_PASSWORD)
        [--socket /run/mysqld/mysqld.sock] [--dbc-dir /opt/mangos/data/dbc] [--state FILE]
        [--full] [--dry-run] [--publish git|r2] [--torrent DIR] [-v]

Runs on the realm server every 10 minutes (hetzner/armory_cron.sh, systemd timer openvanilla-armory).
Read-only on the databases. The schema of everything it writes is in docs/ARMORY.md, the guild
files follow docs/ARMORY_GUILDS.md exactly.

What it writes under --out (the site's www/armory/):
    index.json                       every realm in the folder (this one + uploaded community realms)
    guilds.json                      every realm's guilds (docs/ARMORY_GUILDS.md)
    <realm>/index.json               this realm: public characters (search) and its guild rows
    <realm>/rankings.json            level, achievement points, honorable kills, professions
    <realm>/firsts.json              realm-first achievements
    <realm>/<name>.json              one public character
    <realm>/<name>~<key>.json        one friends-only character (the key is the character's secret)
    <realm>/guilds/<slug>.json       one guild

Privacy (classiccharacters.openvanilla_character.armory, set in game with ".wnl armory <mode>"):
    public   (default) everything above
    friends  only the secret-named file; never in search, rankings or firsts; "limited" in guilds
    hidden   nothing; counted (not named) in guild totals

Incremental: a character is exported again only when its logout time, online flag, privacy,
level, name or guild changed since the last run (the state file keeps a small summary of every
character, which the indexes and guild files are rebuilt from every run). --full ignores the state.
A file is rewritten only when its content changed (the "generated" time does not count), so
re-running with nothing new changes nothing on disk.

Optional data, used when present: openvanilla_character (privacy, dual spec), openvanilla_spec (the second
spec), character_achievement + classicmangos.openvanilla_achievement (achievements), openvanilla_realm_first,
character_honor_cp, character_stats, classicmangos.spell_template (item effect and talent names) and
the server's DBC folder (--dbc-dir: item icons, talents, reputations, enchantments, item sets).

--publish git   commits --out into the static pages branch (ARMORY_GIT_DIR: a clone with push access,
                ARMORY_GIT_BRANCH default gh-pages, ARMORY_GIT_SUBDIR default armory) and pushes.
--publish r2    uploads changed files to Cloudflare R2 (S3 API) with AWS_ACCESS_KEY_ID,
                AWS_SECRET_ACCESS_KEY, ARMORY_R2_ENDPOINT (https://<account>.r2.cloudflarestorage.com),
                ARMORY_R2_BUCKET and ARMORY_R2_PREFIX (default armory/).
--torrent DIR   once a day: armory-YYYYMMDD.zip of --out in DIR plus its .torrent (via
                tools/make_release_torrents.py; ARMORY_TORRENT_BASE_URL, ARMORY_TORRENT_ALLOW).
"""
import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

SCHEMA = 1
HERE = os.path.dirname(os.path.abspath(__file__))
SLUG_RE = re.compile(r"^[a-z0-9-]{1,64}$")
KEY_RE = re.compile(r"^[a-z0-9]{16,40}$")
HOST_ID_RE = re.compile(r"^[a-z2-7]{16}$")
MODES = ("public", "friends", "hidden")

CLASSES = {1: "WARRIOR", 2: "PALADIN", 3: "HUNTER", 4: "ROGUE", 5: "PRIEST", 7: "SHAMAN", 8: "MAGE",
           9: "WARLOCK", 11: "DRUID"}
RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
ALLIANCE = {1, 3, 4, 7}
PROFESSIONS = {171: "Alchemy", 164: "Blacksmithing", 333: "Enchanting", 202: "Engineering", 182: "Herbalism",
               165: "Leatherworking", 186: "Mining", 393: "Skinning", 197: "Tailoring", 185: "Cooking",
               129: "First Aid", 356: "Fishing"}
SECONDARY = {"Cooking", "First Aid", "Fishing"}
SLOTS = ["head", "neck", "shoulder", "shirt", "chest", "waist", "legs", "feet", "wrist", "hands", "finger1",
         "finger2", "trinket1", "trinket2", "back", "mainhand", "offhand", "ranged", "tabard"]
QUALITY = ["poor", "common", "uncommon", "rare", "epic", "legendary", "artifact"]
STAT = {0: "Mana", 1: "Health", 3: "Agility", 4: "Strength", 5: "Intellect", 6: "Spirit", 7: "Stamina"}
RESIST = ["holy", "fire", "nature", "frost", "shadow", "arcane"]
SCHOOL = ["Physical", "Holy", "Fire", "Nature", "Frost", "Shadow", "Arcane"]
INV_TYPE = {1: "Head", 2: "Neck", 3: "Shoulder", 4: "Shirt", 5: "Chest", 6: "Waist", 7: "Legs", 8: "Feet",
            9: "Wrist", 10: "Hands", 11: "Finger", 12: "Trinket", 13: "One-Hand", 14: "Off Hand", 15: "Ranged",
            16: "Back", 17: "Two-Hand", 19: "Tabard", 20: "Chest", 21: "Main Hand", 22: "Off Hand",
            23: "Held In Off-hand", 25: "Thrown", 26: "Ranged", 28: "Relic"}
ARMOR_SUB = {1: "Cloth", 2: "Leather", 3: "Mail", 4: "Plate", 6: "Shield", 7: "Libram", 8: "Idol", 9: "Totem"}
WEAPON_SUB = {0: "Axe", 1: "Axe", 2: "Bow", 3: "Gun", 4: "Mace", 5: "Mace", 6: "Polearm", 7: "Sword", 8: "Sword",
              10: "Staff", 13: "Fist Weapon", 14: "Miscellaneous", 15: "Dagger", 16: "Thrown", 17: "Spear",
              18: "Crossbow", 19: "Wand", 20: "Fishing Pole"}
BOND = {1: "Binds when picked up", 2: "Binds when equipped", 3: "Binds when used", 4: "Quest Item"}
TRIGGER = {0: "Use", 1: "Equip", 2: "Chance on hit"}
REP_LEVELS = [(-42000, "Hated", 36000), (-6000, "Hostile", 3000), (-3000, "Unfriendly", 3000), (0, "Neutral", 3000),
              (3000, "Friendly", 6000), (9000, "Honored", 12000), (21000, "Revered", 21000), (42000, "Exalted", 1000)]
HONOR_RANKS = {5: "Private", 6: "Corporal", 7: "Sergeant", 8: "Master Sergeant", 9: "Sergeant Major",
               10: "Knight", 11: "Knight-Lieutenant", 12: "Knight-Captain", 13: "Knight-Champion",
               14: "Lieutenant Commander", 15: "Commander", 16: "Marshal", 17: "Field Marshal", 18: "Grand Marshal"}
HONOR_RANKS_H = {5: "Scout", 6: "Grunt", 7: "Sergeant", 8: "Senior Sergeant", 9: "First Sergeant",
                 10: "Stone Guard", 11: "Blood Guard", 12: "Legionnaire", 13: "Centurion", 14: "Champion",
                 15: "Lieutenant General", 16: "General", 17: "Warlord", 18: "High Warlord"}
RANKING_SIZE = 100


def log(*a):
    print(*a, file=sys.stderr)


def slugify(name):
    """docs/ARMORY_GUILDS.md: lowercase, every run of non [a-z0-9] -> one '-', strip '-' at both ends."""
    return re.sub(r"[^a-z0-9]+", "-", str(name or "").lower()).strip("-")


def iso(ts):
    return dt.datetime.fromtimestamp(int(ts), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def day(ts):
    return dt.datetime.fromtimestamp(int(ts), dt.timezone.utc).strftime("%Y-%m-%d")


def clean_text(s, n):
    s = "".join(ch for ch in str(s or "") if ch == "\n" or (ord(ch) >= 32 and ord(ch) != 127))
    return s.strip()[:n]


def faction_of(race):
    return "Alliance" if int(race) in ALLIANCE else "Horde"


def rep_level(value):
    value = max(-42000, min(42999, int(value)))
    for lo, name, size in reversed(REP_LEVELS):
        if value >= lo:
            return name, value - lo, size
    return "Hated", 0, 36000


def file_base(name):
    return str(name).lower()


# ---------------------------------------------------------------------------------------- databases

class Db:
    """rows(sql, args) -> list of tuples. SQL uses %s placeholders and db.table names."""

    def rows(self, sql, args=()):
        raise NotImplementedError

    def has(self, table, column=None):
        try:
            self.rows(f"SELECT {column or '1'} FROM {table} LIMIT 1")
            return True
        except Exception:
            return False


class PyMySQLDb(Db):
    def __init__(self, **kw):
        import pymysql
        self.conn = pymysql.connect(charset="utf8mb4", autocommit=True, **kw)

    def rows(self, sql, args=()):
        with self.conn.cursor() as c:
            c.execute(sql, tuple(args))
            return list(c.fetchall())


class SqliteDb(Db):
    """Tests: an sqlite connection with the databases ATTACHed under their MySQL names."""

    def __init__(self, conn):
        self.conn = conn

    def rows(self, sql, args=()):
        return list(self.conn.execute(sql.replace("%s", "?"), tuple(args)).fetchall())


def sql_literal(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return repr(v)
    s = str(v)
    for a, b in (("\\", "\\\\"), ("\0", "\\0"), ("\n", "\\n"), ("\r", "\\r"), ("'", "\\'"), ('"', '\\"'), ("\x1a", "\\Z")):
        s = s.replace(a, b)
    return "'" + s + "'"


class CliDb(Db):
    """Over a function that runs SQL with the mariadb client in --batch --skip-column-names mode and
    returns its stdout (the host agent's HostSession.query). Values are tab separated, escaped."""

    def __init__(self, query):
        self.query = query

    @staticmethod
    def _unescape(v):
        if v == "NULL":
            return None
        out, i = [], 0
        while i < len(v):
            c = v[i]
            if c == "\\" and i + 1 < len(v):
                out.append({"t": "\t", "n": "\n", "\\": "\\", "0": "\0"}.get(v[i + 1], v[i + 1]))
                i += 2
            else:
                out.append(c)
                i += 1
        return "".join(out)

    def rows(self, sql, args=()):
        parts = sql.split("%s")
        if len(parts) - 1 != len(args):
            raise ValueError("placeholder count")
        text = parts[0] + "".join(sql_literal(a) + p for a, p in zip(args, parts[1:]))
        out = self.query("SET NAMES utf8mb4; " + text + ";")
        res = []
        for line in (out or "").split("\n"):
            if line == "":
                continue
            res.append(tuple(self._num(self._unescape(x)) for x in line.split("\t")))
        return res

    @staticmethod
    def _num(v):
        if v is None:
            return None
        if re.fullmatch(r"-?\d{1,18}", v):
            return int(v)
        return v


# ---------------------------------------------------------------------------------------- DBC files

class Dbc:
    """A WDBC table (1.12 client data on the server). get(id) -> record (tuple of u32), s(rec, f)."""

    def __init__(self, path):
        with open(path, "rb") as f:
            data = f.read()
        if data[:4] != b"WDBC":
            raise ValueError(path + ": not a DBC")
        self.n, self.fields, self.size, ssize = struct.unpack_from("<4I", data, 4)
        self.strings = data[20 + self.n * self.size:]
        self.recs = {}
        fmt = "<%dI" % self.fields
        for r in range(self.n):
            rec = struct.unpack_from(fmt, data, 20 + r * self.size)
            self.recs[rec[0]] = rec

    def get(self, rid):
        return self.recs.get(int(rid))

    def s(self, rec, field):
        off = rec[field]
        end = self.strings.find(b"\0", off)
        return self.strings[off:end if end >= 0 else None].decode("utf-8", "replace")

    def i(self, rec, field):
        v = rec[field]
        return v - (1 << 32) if v >= 1 << 31 else v


class GameData:
    """Lookups from the DBC folder (all optional) and the world database."""

    def __init__(self, dbc_dir=None):
        self.dbc = {}
        if dbc_dir and os.path.isdir(dbc_dir):
            names = {n.lower(): n for n in os.listdir(dbc_dir)}
            for key in ("itemdisplayinfo", "talent", "talenttab", "spellicon", "faction", "spellitemenchantment",
                        "itemrandomproperties", "itemset", "spell"):
                fn = names.get(key + ".dbc")
                if fn:
                    try:
                        self.dbc[key] = Dbc(os.path.join(dbc_dir, fn))
                    except (OSError, ValueError, struct.error) as e:
                        log(f"armory: skipping {fn}: {e}")
        self._talents = None

    def icon(self, display_id):
        d = self.dbc.get("itemdisplayinfo")
        rec = d and d.get(display_id)
        return d.s(rec, 5) if rec else None

    def spell_icon(self, icon_id):
        d = self.dbc.get("spellicon")
        rec = d and d.get(icon_id)
        if not rec:
            return None
        return d.s(rec, 1).replace("\\", "/").split("/")[-1] or None

    def enchant(self, eid):
        d = self.dbc.get("spellitemenchantment")
        rec = d and d.get(eid)
        return d.s(rec, 13) if rec else None

    def random_suffix(self, rid):
        """-> (name, [enchant ids]) of an ItemRandomProperties row."""
        d = self.dbc.get("itemrandomproperties")
        rec = d and d.get(rid)
        if not rec:
            return None, []
        return d.s(rec, 7), [rec[i] for i in (2, 3, 4) if rec[i]]

    def item_set(self, sid):
        d = self.dbc.get("itemset")
        rec = d and d.get(sid)
        if not rec:
            return None
        return {"name": d.s(rec, 1), "items": [rec[i] for i in range(10, 27) if rec[i]]}

    def faction(self, fid, race, cls):
        """-> (name, base reputation) for this race/class, or (None, 0)."""
        d = self.dbc.get("faction")
        rec = d and d.get(fid)
        if not rec:
            return None, 0
        rmask, cmask = 1 << (int(race) - 1), 1 << (int(cls) - 1)
        base = 0
        for i in range(4):
            rm, cm = rec[2 + i], rec[6 + i]
            if (rm == 0 or rm & rmask) and (cm == 0 or cm & cmask) and (rm or cm):
                base = d.i(rec, 10 + i)
                break
        return d.s(rec, 19), base

    def talents(self):
        """{class id: [tab {id, order, name, talents: {talent id: {row, col, ranks:[spell]}}}]} + spell->(talent, rank)."""
        if self._talents is None:
            tabs, by_spell = {}, {}
            t, tt = self.dbc.get("talent"), self.dbc.get("talenttab")
            if t and tt:
                for rec in tt.recs.values():
                    tabs[rec[0]] = {"id": rec[0], "name": tt.s(rec, 1), "classMask": rec[12], "order": rec[13],
                                    "icon": self.spell_icon(rec[10]), "talents": {}}
                for rec in t.recs.values():
                    tab = tabs.get(rec[1])
                    if not tab:
                        continue
                    ranks = [rec[i] for i in range(4, 9) if rec[i]]
                    tab["talents"][rec[0]] = {"row": rec[2], "col": rec[3], "ranks": ranks}
                    for n, sp in enumerate(ranks):
                        by_spell[sp] = (rec[0], n + 1)
            by_class = {}
            for tab in tabs.values():
                for cid in CLASSES:
                    if tab["classMask"] & (1 << (cid - 1)):
                        by_class.setdefault(cid, []).append(tab)
            for v in by_class.values():
                v.sort(key=lambda x: x["order"])
            talent_tab = {tid: tab for tab in tabs.values() for tid in tab["talents"]}
            self._talents = (by_class, by_spell, talent_tab)
        return self._talents


# ---------------------------------------------------------------------------------------- exporter

class Exporter:
    def __init__(self, db, out, realm=None, realm_name=None, chars_db="classiccharacters", world_db="classicmangos",
                 realmd_db="classicrealmd", game=None, state_path=None, now=None, dry_run=False, full=False,
                 community=False, skip_prefix="RNDBOT", verbose=False, community_dir=None):
        self.db, self.out = db, out
        self.C, self.W, self.R = chars_db, world_db, realmd_db
        self.game = game or GameData()
        self.now = int(now if now is not None else time.time())
        self.dry, self.full, self.community, self.verbose = dry_run, full, community, verbose
        self.skip_prefix = skip_prefix
        self.community_dir = community_dir
        self.realm_name = realm_name or self._realmlist_name() or "Open Vanilla"
        self.realm = slugify(realm) if realm else slugify(self.realm_name)
        if not SLUG_RE.match(self.realm):
            raise SystemExit(f"armory: bad realm directory name {self.realm!r}")
        self.state_path = state_path or os.path.join(out, ".armory-state-" + self.realm + ".json")
        self.written, self.deleted, self.unchanged = [], [], 0
        self.generated = iso(self.now)
        self._items, self._spells = {}, {}

    # ---- helpers
    def q(self, sql, args=()):
        return self.db.rows(sql, args)

    def _realmlist_name(self):
        try:
            r = self.q(f"SELECT name FROM {self.R}.realmlist ORDER BY id LIMIT 1")
            return clean_text(r[0][0], 40) if r else None
        except Exception:
            return None

    def detect(self):
        C, W = self.C, self.W
        self.has_oc = self.db.has(f"{C}.openvanilla_character")
        self.has_privacy = self.has_oc and self.db.has(f"{C}.openvanilla_character", "armory, armory_key")
        self.has_spec = self.db.has(f"{C}.openvanilla_spec")
        self.has_ach = self.db.has(f"{C}.character_achievement") and self.db.has(f"{W}.openvanilla_achievement")
        self.has_first = self.db.has(f"{C}.openvanilla_realm_first")
        self.has_honor_cp = self.db.has(f"{C}.character_honor_cp")
        self.has_stats = self.db.has(f"{C}.character_stats")
        self.has_spell_tpl = self.db.has(f"{W}.spell_template", "Id, SpellName")
        self.has_delete = self.db.has(f"{C}.characters", "deleteInfos_Name")
        self.has_account = bool(self.skip_prefix) and self.db.has(f"{self.R}.account", "id, username")

    def load_state(self):
        if self.full:
            return {"chars": {}}
        try:
            with open(self.state_path, encoding="utf-8") as f:
                st = json.load(f)
            if st.get("schema") == SCHEMA and st.get("realm") == self.realm and isinstance(st.get("chars"), dict):
                return st
        except (OSError, ValueError):
            pass
        return {"chars": {}}

    # ---- file writing (idempotent: content without "generated" decides)
    @staticmethod
    def _same(a, b):
        strip = lambda o: {k: v for k, v in o.items() if k != "generated"} if isinstance(o, dict) else o  # noqa: E731
        return strip(a) == strip(b)

    def write(self, rel, obj):
        path = os.path.join(self.out, rel)
        try:
            with open(path, encoding="utf-8") as f:
                old = json.load(f)
            if self._same(old, obj):
                self.unchanged += 1
                return False
        except (OSError, ValueError):
            pass
        self.written.append(rel)
        if self.dry:
            return True
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, path)
        return True

    def _generated_on_disk(self, rel, fallback):
        """The "generated" of a file as it is on disk: it only moves when the content changed."""
        try:
            with open(os.path.join(self.out, rel), encoding="utf-8") as f:
                return clean_text(json.load(f).get("generated"), 32) or fallback
        except (OSError, ValueError, AttributeError):
            return fallback

    def remove(self, rel):
        path = os.path.join(self.out, rel)
        if os.path.exists(path):
            self.deleted.append(rel)
            if not self.dry:
                os.remove(path)

    # ---- roster
    def roster(self):
        C = self.C
        cols = ("c.guid, c.name, c.race, c.class, c.gender, c.level, c.logout_time, c.online, "
                "c.stored_honorable_kills, c.stored_dishonorable_kills, c.honor_highest_rank, c.honor_standing, "
                "c.account, gm.guildid, gm.rank")
        priv = ", oc.armory, oc.armory_key" if self.has_privacy else ", NULL, NULL"
        spec = ", oc.active_spec" if self.has_oc else ", NULL"
        join = f" LEFT JOIN {C}.openvanilla_character oc ON oc.guid = c.guid" if self.has_oc else ""
        where = " WHERE c.deleteInfos_Name IS NULL" if self.has_delete else ""
        rows = self.q(f"SELECT {cols}{priv}{spec} FROM {C}.characters c LEFT JOIN {C}.guild_member gm ON gm.guid = c.guid"
                      f"{join}{where}")
        skip = set()
        if self.has_account:
            for (aid,) in self.q(f"SELECT id FROM {self.R}.account WHERE username LIKE %s", (self.skip_prefix + "%",)):
                skip.add(int(aid))
        out = {}
        for r in rows:
            (guid, name, race, cls, gender, level, logout, online, hk, dk, hrank, hstand, account, gid, grank,
             mode, key, active_spec) = r
            if int(account or 0) in skip or int(cls) not in CLASSES or int(race) not in RACES or not name:
                continue
            mode = (mode or "public").lower()
            key = (key or "").lower()
            if mode not in MODES:
                mode = "public"
            if mode == "friends" and not KEY_RE.match(key):
                mode = "hidden"          # a friends setting without a usable secret publishes nothing
            out[str(int(guid))] = {
                "guid": int(guid), "name": str(name), "race": int(race), "class": int(cls), "gender": int(gender or 0),
                "level": int(level), "logout": int(logout or 0), "online": bool(int(online or 0)),
                "hk": int(hk or 0), "dk": int(dk or 0), "hrank": int(hrank or 0), "hstand": int(hstand or 0),
                "guild": int(gid) if gid is not None else None, "grank": int(grank) if grank is not None else None,
                "mode": mode, "key": key if mode == "friends" else "", "spec": int(active_spec or 1),
            }
        return out

    @staticmethod
    def signature(c):
        return [c["logout"], c["online"], c["mode"], c["key"], c["name"], c["level"], c["guild"], c["grank"]]

    # ---- per-character detail
    def item_templates(self, entries):
        need = [e for e in set(entries) if e not in self._items]
        for i in range(0, len(need), 200):
            chunk = need[i:i + 200]
            ph = ",".join(["%s"] * len(chunk))
            stat_cols = ", ".join(f"stat_type{n}, stat_value{n}" for n in range(1, 11))
            spell_cols = ", ".join(f"spellid_{n}, spelltrigger_{n}" for n in range(1, 6))
            for r in self.q(f"SELECT entry, name, Quality, ItemLevel, RequiredLevel, InventoryType, class, subclass, displayid, "
                            f"armor, block, dmg_min1, dmg_max1, dmg_type1, delay, holy_res, fire_res, nature_res, frost_res, "
                            f"shadow_res, arcane_res, bonding, MaxDurability, itemset, description, {stat_cols}, {spell_cols} "
                            f"FROM {self.W}.item_template WHERE entry IN ({ph})", chunk):
                self._items[int(r[0])] = r
        return self._items

    def spell_names(self, ids):
        ids = [int(i) for i in set(ids) if i and int(i) not in self._spells]
        if not ids or not self.has_spell_tpl:
            return self._spells
        for i in range(0, len(ids), 300):
            chunk = ids[i:i + 300]
            ph = ",".join(["%s"] * len(chunk))
            for sid, name, *rest in self.q(f"SELECT Id, SpellName, SpellIconID FROM {self.W}.spell_template WHERE Id IN ({ph})", chunk):
                self._spells[int(sid)] = (clean_text(name, 80), int(rest[0] or 0) if rest else 0)
        return self._spells

    def equipment(self, c):
        rows = self.q(f"SELECT ci.slot, ci.item_template, ii.enchantments, ii.randomPropertyId, ii.durability "
                      f"FROM {self.C}.character_inventory ci LEFT JOIN {self.C}.item_instance ii ON ii.guid = ci.item "
                      f"WHERE ci.guid = %s AND ci.bag = 0 AND ci.slot < 19 ORDER BY ci.slot", (c["guid"],))
        tpl = self.item_templates([int(r[1]) for r in rows])
        spells = []
        for r in rows:
            t = tpl.get(int(r[1]))
            if t:
                spells += [t[45 + 2 * n] for n in range(5)]
        names = self.spell_names(spells)
        worn = {int(r[1]) for r in rows}
        out = []
        for slot, entry, ench, rprop, dur in rows:
            t = tpl.get(int(entry))
            if not t or int(slot) >= len(SLOTS):
                continue
            (_, name, quality, ilvl, req, inv, icls, isub, disp, armor, block, dmin, dmax, dtype, delay) = t[:15]
            res = t[15:21]
            bonding, maxdur, itemset, desc = t[21:25]
            it = {"slot": SLOTS[int(slot)], "slotId": int(slot), "id": int(entry), "name": clean_text(name, 80),
                  "quality": int(quality), "qualityName": QUALITY[int(quality)] if 0 <= int(quality) < 7 else "common",
                  "itemLevel": int(ilvl)}
            icon = self.game.icon(int(disp))
            if icon:
                it["icon"] = icon
            if int(req) > 1:
                it["requiredLevel"] = int(req)
            if int(bonding) in BOND:
                it["bonding"] = BOND[int(bonding)]
            kind = INV_TYPE.get(int(inv))
            if kind:
                it["invType"] = kind
            sub = WEAPON_SUB.get(int(isub)) if int(icls) == 2 else ARMOR_SUB.get(int(isub)) if int(icls) == 4 else None
            if sub:
                it["subType"] = sub
            if int(armor):
                it["armor"] = int(armor)
            if int(block):
                it["block"] = int(block)
            if float(dmax or 0) > 0:
                speed = int(delay or 0) / 1000.0
                d = {"min": int(round(float(dmin))), "max": int(round(float(dmax))), "speed": round(speed, 2)}
                if int(dtype or 0):
                    d["school"] = SCHOOL[int(dtype)] if int(dtype) < len(SCHOOL) else "Physical"
                if speed > 0:
                    d["dps"] = round((float(dmin) + float(dmax)) / 2 / speed, 1)
                it["damage"] = d
            stats = []
            for n in range(10):
                st, val = t[25 + 2 * n], t[26 + 2 * n]
                if int(val or 0) and int(st) in STAT:
                    stats.append({"stat": STAT[int(st)], "value": int(val)})
            if stats:
                it["stats"] = stats
            r = {RESIST[n]: int(v) for n, v in enumerate(res) if int(v or 0)}
            if r:
                it["resist"] = r
            effects = []
            for n in range(5):
                sid, trig = int(t[45 + 2 * n] or 0), int(t[46 + 2 * n] or 0)
                if sid and trig in TRIGGER and sid in names and names[sid][0]:
                    effects.append({"trigger": TRIGGER[trig], "text": names[sid][0]})
            if effects:
                it["effects"] = effects
            if desc:
                it["description"] = clean_text(desc, 200)
            parts = str(ench or "").split()
            if parts and parts[0].isdigit() and int(parts[0]):
                text = self.game.enchant(int(parts[0]))
                if text:
                    it["enchant"] = clean_text(text, 80)
            if rprop and int(rprop) > 0:
                suffix, ids = self.game.random_suffix(int(rprop))
                if suffix:
                    it["suffix"] = clean_text(suffix, 40)
                    it["name"] = it["name"] + " " + it["suffix"]
                    lines = [clean_text(self.game.enchant(e), 80) for e in ids if self.game.enchant(e)]
                    if lines:
                        it["randomStats"] = lines
            if int(itemset or 0):
                s = self.game.item_set(int(itemset))
                if s:
                    it["set"] = {"id": int(itemset), "name": clean_text(s["name"], 60),
                                 "equipped": len(worn & set(s["items"])), "pieces": len(s["items"])}
            if int(maxdur or 0):
                it["durability"] = {"current": int(dur or 0), "max": int(maxdur)}
            out.append(it)
        return out

    def professions(self, guid):
        ids = list(PROFESSIONS)
        ph = ",".join(["%s"] * len(ids))
        rows = self.q(f"SELECT skill, value, max FROM {self.C}.character_skills WHERE guid = %s AND skill IN ({ph})",
                      [guid] + ids)
        out = [{"name": PROFESSIONS[int(s)], "skill": int(v), "max": int(m)} for s, v, m in rows]
        out.sort(key=lambda p: (-p["skill"], p["name"]))
        return out

    def reputations(self, c):
        if "faction" not in self.game.dbc:
            return []
        out = []
        for fid, standing, flags in self.q(f"SELECT faction, standing, flags FROM {self.C}.character_reputation WHERE guid = %s",
                                           (c["guid"],)):
            flags = int(flags or 0)
            if not flags & 1 or flags & (4 | 8):
                continue
            name, base = self.game.faction(int(fid), c["race"], c["class"])
            if not name:
                continue
            value = base + int(standing)
            level, into, size = rep_level(value)
            out.append({"id": int(fid), "name": clean_text(name, 60), "value": value, "standing": level,
                        "progress": into, "max": size})
        out.sort(key=lambda r: (-r["value"], r["name"]))
        return out

    def achievements(self, guid):
        if not self.has_ach:
            return []
        rows = self.q(f"SELECT a.id, a.name, a.description, a.points, a.category, a.icon, a.flags, ca.date "
                      f"FROM {self.C}.character_achievement ca JOIN {self.W}.openvanilla_achievement a ON a.id = ca.achievement "
                      f"WHERE ca.guid = %s ORDER BY ca.date DESC, a.id", (guid,))
        out = []
        for aid, name, desc, pts, cat, icon, flags, date in rows:
            a = {"id": int(aid), "name": clean_text(name, 80), "description": clean_text(desc, 255), "points": int(pts),
                 "category": clean_text(cat, 16), "icon": str(icon or "").replace("\\", "/").split("/")[-1],
                 "date": day(date)}
            if int(flags or 0) & 4:
                a["featOfStrength"] = True
            out.append(a)
        return out

    def honor_kills(self, c):
        hk = c["hk"]
        if self.has_honor_cp:
            r = self.q(f"SELECT COUNT(*) FROM {self.C}.character_honor_cp WHERE guid = %s AND type = 1 AND victim_type = 4",
                       (c["guid"],))
            hk += int(r[0][0] or 0) if r else 0
        return hk

    def talents(self, c):
        by_class, by_spell, talent_tab = self.game.talents()
        tabs = by_class.get(c["class"])
        if not tabs:
            return None
        known = [int(s) for (s,) in self.q(f"SELECT spell FROM {self.C}.character_spell WHERE guid = %s AND disabled = 0",
                                           (c["guid"],)) if int(s) in by_spell]
        live = {}
        for s in known:
            tid, rank = by_spell[s]
            live[tid] = max(live.get(tid, 0), rank)
        specs = {}
        active = c["spec"] if c["spec"] in (1, 2) else 1
        names = {}
        if self.has_spec:
            for spec, name, text in self.q(f"SELECT spec, name, talents FROM {self.C}.openvanilla_spec WHERE guid = %s",
                                           (c["guid"],)):
                names[int(spec)] = clean_text(name, 24)
                if int(spec) == active:
                    continue
                pts = {}
                for part in str(text or "").split(","):
                    m = re.fullmatch(r"\s*(\d+):(\d+)\s*", part)
                    if m and int(m.group(1)) in talent_tab:
                        pts[int(m.group(1))] = int(m.group(2)) + 1
                specs[int(spec)] = pts
        specs[active] = live
        tree_tabs = [t for t in tabs][:3]
        names_spell = self.spell_names([t["talents"][tid]["ranks"][0] for t in tree_tabs for tid in t["talents"]])
        out = []
        for idx in sorted(specs):
            pts = specs[idx]
            trees = []
            for tab in tree_tabs:
                tl = []
                for tid, info in sorted(tab["talents"].items(), key=lambda kv: (kv[1]["row"], kv[1]["col"])):
                    rank = min(pts.get(tid, 0), len(info["ranks"]))
                    sp = names_spell.get(info["ranks"][0]) if info["ranks"] else None
                    t = {"id": tid, "row": info["row"], "col": info["col"], "rank": rank, "max": len(info["ranks"])}
                    if sp and sp[0]:
                        t["name"] = sp[0]
                    icon = self.game.spell_icon(sp[1]) if sp else None
                    if icon:
                        t["icon"] = icon
                    tl.append(t)
                tree = {"name": clean_text(tab["name"], 40), "points": sum(t["rank"] for t in tl), "talents": tl}
                if tab.get("icon"):
                    tree["icon"] = tab["icon"]
                trees.append(tree)
            out.append({"index": idx, "name": names.get(idx) or f"Spec {idx}", "active": idx == active,
                        "points": [t["points"] for t in trees], "trees": trees})
        return out

    def char_stats(self, guid):
        if not self.has_stats:
            return None
        r = self.q(f"SELECT maxhealth, maxpower1, strength, agility, stamina, intellect, spirit, armor, "
                   f"resHoly, resFire, resNature, resFrost, resShadow, resArcane, blockPct, dodgePct, parryPct, critPct, "
                   f"rangedCritPct, attackPower, rangedAttackPower FROM {self.C}.character_stats WHERE guid = %s", (guid,))
        if not r:
            return None
        v = r[0]
        keys = ["health", "mana", "strength", "agility", "stamina", "intellect", "spirit", "armor", "resHoly", "resFire",
                "resNature", "resFrost", "resShadow", "resArcane", "block", "dodge", "parry", "crit", "rangedCrit",
                "attackPower", "rangedAttackPower"]
        out = {}
        for k, x in zip(keys, v):
            if x is None:
                continue
            out[k] = round(float(x), 2) if k in ("block", "dodge", "parry", "crit", "rangedCrit") else int(x)
        return out if any(out.values()) else None

    def character(self, c, guilds):
        """-> (character JSON, summary for the state file)."""
        guid = c["guid"]
        profs = self.professions(guid)
        ach = self.achievements(guid)
        points = sum(a["points"] for a in ach)
        hk = self.honor_kills(c)
        doc = {"schema": SCHEMA, "generated": self.generated, "realm": self.realm, "realmName": self.realm_name,
               "name": c["name"], "level": c["level"], "class": CLASSES[c["class"]], "race": RACES[c["race"]],
               "gender": "female" if c["gender"] == 1 else "male", "faction": faction_of(c["race"]),
               "privacy": c["mode"], "online": c["online"]}
        if not c["online"] and c["logout"]:
            doc["lastSeen"] = iso(c["logout"])
        g = guilds.get(c["guild"]) if c["guild"] is not None else None
        if g:
            doc["guild"] = {"name": g["name"], "slug": g["slug"], "rank": c["grank"],
                            "rankName": g["ranks"].get(c["grank"], f"Rank {c['grank']}")}
        honor = {"honorableKills": hk, "dishonorableKills": c["dk"]}
        if c["hrank"] >= 5:
            honor["highestRank"] = c["hrank"] - 4
            honor["highestRankName"] = (HONOR_RANKS if doc["faction"] == "Alliance" else HONOR_RANKS_H).get(c["hrank"], "")
        if c["hstand"]:
            honor["standing"] = c["hstand"]
        doc["honor"] = honor
        doc["equipment"] = self.equipment(c)
        st = self.char_stats(guid)
        if st:
            doc["stats"] = st
        tal = self.talents(c)
        if tal:
            doc["talents"] = tal
        doc["achievements"] = {"points": points, "count": len(ach), "list": ach}
        doc["professions"] = profs
        reps = self.reputations(c)
        if reps:
            doc["reputations"] = reps
        summary = {"name": c["name"], "level": c["level"], "race": c["race"], "class": c["class"], "mode": c["mode"],
                   "key": c["key"], "ap": points, "hk": hk, "online": c["online"], "logout": c["logout"],
                   "guild": c["guild"], "grank": c["grank"],
                   "profs": [{"name": p["name"], "skill": p["skill"]} for p in profs],
                   "recent": [{"id": a["id"], "name": a["name"], "icon": a["icon"], "points": a["points"], "date": a["date"]}
                              for a in ach[:10]],
                   "sig": self.signature(c)}
        return doc, summary

    # ---- guilds
    def guilds(self):
        rows = self.q(f"SELECT guildid, name, leaderguid, info, createdate FROM {self.C}.guild ORDER BY guildid")
        ranks = {}
        for gid, rid, rname in self.q(f"SELECT guildid, rid, rname FROM {self.C}.guild_rank"):
            ranks.setdefault(int(gid), {})[int(rid)] = clean_text(rname, 32) or f"Rank {int(rid)}"
        out, used = {}, set()
        for gid, name, leader, info, created in rows:
            base = slugify(name) or "guild"
            slug = base if base not in used else f"{base}-{int(gid)}"
            if base == "guild" and not slugify(name):
                slug = f"guild-{int(gid)}"
            if len(slug) > 64:
                slug = slug[:64].strip("-")
            used.add(slug)
            out[int(gid)] = {"id": int(gid), "name": clean_text(name, 40), "slug": slug, "leader": int(leader or 0),
                             "info": clean_text(info, 500), "created": int(created or 0),
                             "ranks": ranks.get(int(gid), {})}
        return out

    def guild_docs(self, guilds, chars):
        members = {}
        for guid, s in chars.items():
            if s.get("guild") is not None and s["guild"] in guilds:
                members.setdefault(s["guild"], []).append((int(guid), s))
        docs, rows = {}, []
        for gid, g in guilds.items():
            ms = members.get(gid, [])
            if not ms:
                continue
            lead = chars.get(str(g["leader"]))
            faction = faction_of(lead["race"]) if lead else faction_of(ms[0][1]["race"])
            listed, classes, profs, recent = [], {}, {}, []
            private = level60 = points = 0
            total_level = 0
            for guid, s in ms:
                cls = CLASSES[s["class"]]
                classes[cls] = classes.get(cls, 0) + 1
                total_level += s["level"]
                level60 += 1 if s["level"] >= 60 else 0
                rank = s["grank"] if s["grank"] is not None else 0
                rank_name = g["ranks"].get(rank, f"Rank {rank}")
                if s["mode"] == "hidden":
                    private += 1
                    continue
                if s["mode"] == "friends":
                    listed.append({"name": s["name"], "level": s["level"], "class": cls, "rank": rank,
                                   "rankName": rank_name, "limited": True})
                    continue
                m = {"name": s["name"], "level": s["level"], "class": cls, "race": RACES[s["race"]], "rank": rank,
                     "rankName": rank_name, "online": bool(s["online"])}
                if not s["online"] and s.get("logout"):
                    m["lastSeen"] = iso(s["logout"])
                m["achievementPoints"] = int(s.get("ap", 0))
                m["professions"] = list(s.get("profs", []))
                listed.append(m)
                points += m["achievementPoints"]
                for p in m["professions"]:
                    profs[p["name"]] = profs.get(p["name"], 0) + 1
                for a in s.get("recent", []):
                    recent.append(dict(a, member=s["name"]))
            listed.sort(key=lambda m: (m["rank"], -m["level"], m["name"]))
            recent.sort(key=lambda a: (a["date"], a["id"]), reverse=True)
            doc = {"schema": SCHEMA, "generated": self.generated, "realm": self.realm, "realmName": self.realm_name,
                   "name": g["name"], "slug": g["slug"], "faction": faction}
            if g["created"]:
                doc["created"] = day(g["created"])
            if lead and lead["mode"] != "hidden" and lead.get("guild") == gid:
                doc["leader"] = lead["name"]
            if g["info"]:
                doc["info"] = g["info"]
            doc["ranks"] = [{"index": k, "name": v} for k, v in sorted(g["ranks"].items())]
            doc["members"] = listed
            doc["totals"] = {"members": len(ms), "listed": len(listed), "private": private, "level60": level60,
                             "averageLevel": round(total_level / len(ms), 1), "achievementPoints": points,
                             "classes": classes, "professions": profs}
            doc["recentAchievements"] = [{"id": a["id"], "name": a["name"], "icon": a["icon"], "points": a["points"],
                                          "member": a["member"], "date": a["date"]} for a in recent[:10]]
            docs[g["slug"]] = doc
            row = {"slug": g["slug"], "name": g["name"], "faction": faction}
            if "leader" in doc:
                row["leader"] = doc["leader"]
            row.update({"members": len(ms), "level60": level60, "achievementPoints": points})
            if "created" in doc:
                row["created"] = doc["created"]
            rows.append(row)
        rows.sort(key=lambda r: (-r["members"], r["name"]))
        return docs, rows

    # ---- indexes
    def rankings(self, chars, guilds):
        pub = [s for s in chars.values() if s["mode"] == "public"]

        def entry(s, **extra):
            e = {"name": s["name"], "level": s["level"], "class": CLASSES[s["class"]], "race": RACES[s["race"]],
                 "faction": faction_of(s["race"])}
            g = guilds.get(s.get("guild"))
            if g:
                e["guild"] = g["name"]
            e.update(extra)
            return e

        level = sorted(pub, key=lambda s: (-s["level"], -s.get("ap", 0), s["name"]))[:RANKING_SIZE]
        ap = sorted([s for s in pub if s.get("ap")], key=lambda s: (-s["ap"], s["name"]))[:RANKING_SIZE]
        hk = sorted([s for s in pub if s.get("hk")], key=lambda s: (-s["hk"], s["name"]))[:RANKING_SIZE]
        profs = {}
        for s in pub:
            for p in s.get("profs", []):
                profs.setdefault(p["name"], []).append((s, p["skill"]))
        return {"schema": SCHEMA, "generated": self.generated, "realm": self.realm, "realmName": self.realm_name,
                "level": [entry(s) for s in level],
                "achievementPoints": [entry(s, points=s["ap"]) for s in ap],
                "honorableKills": [entry(s, kills=s["hk"]) for s in hk],
                "professions": {k: [entry(s, skill=v) for s, v in sorted(lst, key=lambda x: (-x[1], x[0]["name"]))[:RANKING_SIZE]]
                                for k, lst in sorted(profs.items())}}

    def firsts(self, chars):
        if not self.has_first or not self.has_ach:
            return None
        by_guid = {int(g): s for g, s in chars.items()}
        out = []
        for aid, guid, name, date, aname, pts, icon in self.q(
                f"SELECT f.achievement, f.guid, f.name, f.date, a.name, a.points, a.icon FROM {self.C}.openvanilla_realm_first f "
                f"JOIN {self.W}.openvanilla_achievement a ON a.id = f.achievement ORDER BY f.date, f.achievement"):
            e = {"id": int(aid), "name": clean_text(aname, 80), "points": int(pts),
                 "icon": str(icon or "").replace("\\", "/").split("/")[-1], "date": day(date)}
            s = by_guid.get(int(guid))
            if s and s["mode"] == "public":
                e.update({"character": s["name"], "class": CLASSES[s["class"]]})
            else:
                e["private"] = True
            out.append(e)
        return {"schema": SCHEMA, "generated": self.generated, "realm": self.realm, "realmName": self.realm_name, "firsts": out}

    def realm_index(self, chars, guilds, guild_rows):
        lst = []
        for s in chars.values():
            if s["mode"] != "public":
                continue
            e = {"name": s["name"], "level": s["level"], "class": CLASSES[s["class"]], "race": RACES[s["race"]],
                 "faction": faction_of(s["race"])}
            g = guilds.get(s.get("guild"))
            if g:
                e["guild"] = g["name"]
                e["guildSlug"] = g["slug"]
            lst.append(e)
        lst.sort(key=lambda e: e["name"].lower())
        aliases = sorted({a for a in (slugify(self.realm_name),) if a and a != self.realm})
        doc = {"schema": SCHEMA, "generated": self.generated, "realm": self.realm, "name": self.realm_name,
               "community": bool(self.community), "characters": lst, "guilds": guild_rows}
        if aliases:
            doc["aliases"] = aliases
        return doc

    def merge_root(self, own):
        """index.json and guilds.json over every realm folder (ours + uploaded community realms)."""
        realms = [own]
        try:
            names = sorted(os.listdir(self.out))
        except OSError:
            names = []
        for d in names:
            if d == self.realm or not SLUG_RE.match(d) or not os.path.isdir(os.path.join(self.out, d)):
                continue
            try:
                with open(os.path.join(self.out, d, "index.json"), encoding="utf-8") as f:
                    idx = json.load(f)
            except (OSError, ValueError):
                continue
            if not isinstance(idx, dict) or idx.get("schema") != SCHEMA:
                continue
            rows = []
            for g in idx.get("guilds") or []:
                if not isinstance(g, dict) or not SLUG_RE.match(str(g.get("slug", ""))):
                    continue
                r = {"slug": g["slug"], "name": clean_text(g.get("name"), 40),
                     "faction": "Horde" if g.get("faction") == "Horde" else "Alliance"}
                if g.get("leader"):
                    r["leader"] = clean_text(g["leader"], 24)
                for k in ("members", "level60", "achievementPoints"):
                    r[k] = max(0, int(g.get(k) or 0)) if str(g.get(k) or 0).isdigit() else 0
                if re.fullmatch(r"\d{4}-\d\d-\d\d", str(g.get("created", ""))):
                    r["created"] = g["created"]
                rows.append(r)
            rows.sort(key=lambda r: (-r["members"], r["name"]))
            aliases = [a for a in (idx.get("aliases") or []) if isinstance(a, str) and SLUG_RE.match(a)][:4]
            realms.append({"realm": d, "name": clean_text(idx.get("name"), 40) or d,
                           "community": bool(idx.get("community")) or bool(HOST_ID_RE.match(d)),
                           "aliases": aliases, "characters": len(idx.get("characters") or []), "guilds": rows,
                           "updated": clean_text(idx.get("generated"), 32)})
        index = {"schema": SCHEMA, "generated": self.generated, "realms": []}
        gidx = {"schema": SCHEMA, "generated": self.generated, "realms": []}
        realms[1:] = sorted(realms[1:], key=lambda r: (r["community"], r["name"].lower()))
        for r in realms:
            entry = {"realm": r["realm"], "name": r["name"], "community": r["community"], "characters": r["characters"],
                     "guilds": len(r["guilds"]), "updated": r["updated"]}
            if r.get("aliases"):
                entry["aliases"] = r["aliases"]
            index["realms"].append(entry)
            gidx["realms"].append({"realm": r["realm"], "name": r["name"], "guilds": r["guilds"]})
        return index, gidx

    # ---- community uploads
    UPLOAD_FILE_RE = re.compile(r"^(?:guilds/)?[a-z0-9~._-]{1,80}\.json$")

    def sync_community(self):
        """Copy the realm service's upload store (ARMORY_UPLOAD_DIR/<host_id>/) into --out, JSON only."""
        src_root = self.community_dir
        if not src_root or not os.path.isdir(src_root):
            return
        present = set()
        for hid in sorted(os.listdir(src_root)):
            src = os.path.join(src_root, hid)
            if not HOST_ID_RE.match(hid) or hid == self.realm or not os.path.isfile(os.path.join(src, "index.json")):
                continue
            present.add(hid)
            want = set()
            for root, dirs, files in os.walk(src):
                dirs[:] = [d for d in dirs if d == "guilds" and root == src]
                for fn in files:
                    rel = os.path.relpath(os.path.join(root, fn), src).replace(os.sep, "/")
                    if not self.UPLOAD_FILE_RE.match(rel) or os.path.islink(os.path.join(root, fn)):
                        continue
                    try:
                        with open(os.path.join(root, fn), encoding="utf-8") as f:
                            obj = json.load(f)
                    except (OSError, ValueError):
                        continue
                    want.add(rel)
                    self.write(f"{hid}/{rel}", obj)
            dst = os.path.join(self.out, hid)
            for root, _, files in os.walk(dst):
                for fn in files:
                    rel = os.path.relpath(os.path.join(root, fn), dst).replace(os.sep, "/")
                    if rel not in want:
                        self.remove(f"{hid}/{rel}")
        try:
            names = os.listdir(self.out)
        except OSError:
            names = []
        for hid in names:
            if HOST_ID_RE.match(hid) and hid not in present and hid != self.realm and os.path.isdir(os.path.join(self.out, hid)):
                for root, _, files in os.walk(os.path.join(self.out, hid)):
                    for fn in files:
                        self.remove(os.path.relpath(os.path.join(root, fn), self.out).replace(os.sep, "/"))

    # ---- the run
    def run(self):
        self.detect()
        state = self.load_state()
        old = state.get("chars", {})
        roster = self.roster()
        guilds = self.guilds()
        chars, exported = {}, 0
        rdir = self.realm
        for guid, c in roster.items():
            prev = old.get(guid)
            if prev and prev.get("sig") == self.signature(c) and not self.full:
                chars[guid] = prev
                continue
            doc, summary = self.character(c, guilds)
            exported += 1
            base = file_base(c["name"])
            keep = None
            if c["mode"] == "public":
                keep = f"{rdir}/{base}.json"
            elif c["mode"] == "friends":
                keep = f"{rdir}/{base}~{c['key']}.json"
            if keep:
                self.write(keep, doc)
            summary["file"] = keep
            # anything else this character had (renamed, privacy changed, new secret)
            for rel in {prev.get("file") if prev else None, f"{rdir}/{base}.json"}:
                if rel and rel != keep:
                    self.remove(rel)
            chars[guid] = summary
        for guid, prev in old.items():
            if guid not in roster and prev.get("file"):
                self.remove(prev["file"])          # deleted or moved away
        docs, guild_rows = self.guild_docs(guilds, chars)
        for slug, doc in docs.items():
            self.write(f"{rdir}/guilds/{slug}.json", doc)
        gdir = os.path.join(self.out, rdir, "guilds")
        if os.path.isdir(gdir):
            for fn in sorted(os.listdir(gdir)):
                if fn.endswith(".json") and fn[:-5] not in docs:
                    self.remove(f"{rdir}/guilds/{fn}")
        own_index = self.realm_index(chars, guilds, guild_rows)
        self.write(f"{rdir}/index.json", own_index)
        updated = self._generated_on_disk(f"{rdir}/index.json", self.generated)
        self.write(f"{rdir}/rankings.json", self.rankings(chars, guilds))
        fr = self.firsts(chars)
        if fr is not None:
            self.write(f"{rdir}/firsts.json", fr)
        if not self.community:
            self.sync_community()
            own = {"realm": self.realm, "name": self.realm_name, "community": False,
                   "aliases": own_index.get("aliases", []), "characters": len(own_index["characters"]),
                   "guilds": guild_rows, "updated": updated}
            index, gidx = self.merge_root(own)
            self.write("index.json", index)
            self.write("guilds.json", gidx)
        if not self.dry:
            os.makedirs(os.path.dirname(os.path.abspath(self.state_path)), exist_ok=True)
            tmp = self.state_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"schema": SCHEMA, "realm": self.realm, "at": self.now, "chars": chars}, f, ensure_ascii=False)
            os.replace(tmp, self.state_path)
        return {"realm": self.realm, "characters": len(roster), "exported": exported, "written": list(self.written),
                "deleted": list(self.deleted), "unchanged": self.unchanged, "guilds": len(docs)}


# ---------------------------------------------------------------------------------------- publishing

def sync_json(src, dest):
    """Mirror the JSON files of src into dest; other files in dest (the pages: character.html) stay."""
    want = set()
    for root, _, files in os.walk(src):
        for fn in files:
            if fn.endswith(".json") and not fn.startswith(".armory-state"):
                rel = os.path.relpath(os.path.join(root, fn), src)
                want.add(rel)
                os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
                shutil.copyfile(os.path.join(root, fn), os.path.join(dest, rel))
    for root, _, files in os.walk(dest):
        for fn in files:
            rel = os.path.relpath(os.path.join(root, fn), dest)
            if fn.endswith(".json") and rel not in want:
                os.remove(os.path.join(root, fn))
    return want


def publish_git(out, env=os.environ, run=subprocess.run, dry=False):
    """Copy out/ into the pages clone (ARMORY_GIT_DIR) under ARMORY_GIT_SUBDIR, commit, push."""
    repo = env.get("ARMORY_GIT_DIR")
    if not repo or not os.path.isdir(os.path.join(repo, ".git")):
        raise SystemExit("armory: --publish git needs ARMORY_GIT_DIR (a clone of the site with push access)")
    branch = env.get("ARMORY_GIT_BRANCH", "gh-pages")
    sub = env.get("ARMORY_GIT_SUBDIR", "armory").strip("/")
    cmds = [["git", "-C", repo, "fetch", "--depth=1", "origin", branch], ["git", "-C", repo, "checkout", "-B", branch, "FETCH_HEAD"]]
    if dry:
        return cmds
    for c in cmds:
        run(c, check=True)
    dest = os.path.join(repo, sub)
    sync_json(out, dest)
    run(["git", "-C", repo, "add", "-A", sub], check=True)
    if run(["git", "-C", repo, "diff", "--cached", "--quiet"]).returncode == 0:
        return []
    run(["git", "-C", repo, "-c", "user.name=Open Vanilla Armory", "-c", "user.email=armory@openvanilla.app", "commit", "-q", "-m",
         "armory: export " + iso(time.time())], check=True)
    run(["git", "-C", repo, "push", "-q", "origin", branch], check=True)
    return cmds


def s3_sign(method, url, body, key_id, secret, region="auto", now=None, content_type="application/json"):
    """AWS Signature V4 headers for one S3 request (Cloudflare R2 speaks it with region "auto")."""
    t = dt.datetime.fromtimestamp(now if now is not None else time.time(), dt.timezone.utc)
    amz, date = t.strftime("%Y%m%dT%H%M%SZ"), t.strftime("%Y%m%d")
    u = urllib.parse.urlsplit(url)
    payload = hashlib.sha256(body).hexdigest()
    headers = {"host": u.netloc, "x-amz-content-sha256": payload, "x-amz-date": amz}
    if body:
        headers["content-type"] = content_type
    signed = ";".join(sorted(headers))
    canon = "\n".join([method, urllib.parse.quote(u.path or "/", safe="/~"), u.query,
                       "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed, payload])
    scope = f"{date}/{region}/s3/aws4_request"
    sts = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(canon.encode()).hexdigest()])
    k = ("AWS4" + secret).encode()
    for part in (date, region, "s3", "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = f"AWS4-HMAC-SHA256 Credential={key_id}/{scope}, SignedHeaders={signed}, Signature={sig}"
    return headers


def publish_r2(out, changed, deleted, env=os.environ, opener=urllib.request.urlopen, dry=False):
    endpoint = env.get("ARMORY_R2_ENDPOINT", "").rstrip("/")
    bucket, prefix = env.get("ARMORY_R2_BUCKET", ""), env.get("ARMORY_R2_PREFIX", "armory/")
    kid, secret = env.get("AWS_ACCESS_KEY_ID", ""), env.get("AWS_SECRET_ACCESS_KEY", "")
    if not (endpoint.startswith("https://") and bucket and kid and secret):
        raise SystemExit("armory: --publish r2 needs ARMORY_R2_ENDPOINT, ARMORY_R2_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY")
    plan = [("PUT", rel) for rel in changed] + [("DELETE", rel) for rel in deleted]
    if dry:
        return plan
    for method, rel in plan:
        url = f"{endpoint}/{bucket}/{prefix}{urllib.parse.quote(rel)}"
        body = b""
        if method == "PUT":
            with open(os.path.join(out, rel), "rb") as f:
                body = f.read()
        h = s3_sign(method, url, body, kid, secret)
        h["cache-control"] = "public, max-age=300"
        opener(urllib.request.Request(url, data=body if method == "PUT" else None, method=method, headers=h), timeout=30).close()
    return plan


def torrent_snapshot(out, snap_dir, now=None, env=os.environ, dry=False):
    """Once a day: armory-YYYYMMDD.zip of the JSON plus its .torrent (tools/make_release_torrents.py)."""
    stamp = dt.datetime.fromtimestamp(now or time.time(), dt.timezone.utc).strftime("%Y%m%d")
    zpath = os.path.join(snap_dir, f"armory-{stamp}.zip")
    if os.path.exists(zpath + ".torrent"):
        return None
    if dry:
        return zpath
    os.makedirs(snap_dir, exist_ok=True)
    with zipfile.ZipFile(zpath + ".tmp", "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(out):
            for fn in sorted(files):
                if fn.endswith(".json") and "~" not in fn and not fn.startswith(".armory-state"):
                    p = os.path.join(root, fn)          # friends-only files never go into a public snapshot
                    z.write(p, os.path.relpath(p, out))
    os.replace(zpath + ".tmp", zpath)
    sys.path.insert(0, HERE)
    import make_release_torrents as mrt
    base = env.get("ARMORY_TORRENT_BASE_URL", "https://play.openvanilla.app/armory-snapshots")
    entry, _ = mrt.torrent_entry(zpath, f"{base}/{os.path.basename(zpath)}", base,
                                 [env.get("ARMORY_TORRENT_TRACKER", mrt.DEFAULT_TRACKER)], [], snap_dir)
    allow = env.get("ARMORY_TORRENT_ALLOW")
    if allow:
        with open(allow, "a", encoding="utf-8") as f:
            f.write(entry["info_hash"] + "\n")
    return zpath


# ---------------------------------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="the armory folder (www/armory)")
    ap.add_argument("--realm", help="realm folder name (default: the realmlist name as a slug)")
    ap.add_argument("--realm-name", help="display name (default: classicrealmd.realmlist)")
    ap.add_argument("--community", action="store_true", help="a community host's own export (no root files)")
    ap.add_argument("--community-dir", default=os.environ.get("ARMORY_UPLOAD_DIR"),
                    help="the realm service's upload store (ARMORY_UPLOAD_DIR); its realms are copied into --out")
    ap.add_argument("--db-host", default=os.environ.get("ARMORY_DB_HOST", "127.0.0.1"))
    ap.add_argument("--db-port", type=int, default=int(os.environ.get("ARMORY_DB_PORT", "3306")))
    ap.add_argument("--db-user", default=os.environ.get("ARMORY_DB_USER", "armory"))
    ap.add_argument("--socket", default=os.environ.get("ARMORY_DB_SOCKET"))
    ap.add_argument("--chars-db", default="classiccharacters")
    ap.add_argument("--world-db", default="classicmangos")
    ap.add_argument("--realmd-db", default="classicrealmd")
    ap.add_argument("--skip-accounts", default="RNDBOT", help="account name prefix to leave out (playerbots); '' = none")
    ap.add_argument("--dbc-dir", default=os.environ.get("ARMORY_DBC_DIR"))
    ap.add_argument("--state", help="state file (default: <out>/.armory-state-<realm>.json)")
    ap.add_argument("--full", action="store_true", help="export every character again")
    ap.add_argument("--dry-run", action="store_true", help="read and report; write nothing")
    ap.add_argument("--publish", choices=["git", "r2"])
    ap.add_argument("--torrent", metavar="DIR", help="daily snapshot zip + .torrent into DIR")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    kw = {"user": a.db_user, "password": os.environ.get("ARMORY_DB_PASSWORD", "")}
    if a.socket:
        kw["unix_socket"] = a.socket
    else:
        kw.update(host=a.db_host, port=a.db_port)
    db = PyMySQLDb(**kw)
    ex = Exporter(db, a.out, realm=a.realm, realm_name=a.realm_name, chars_db=a.chars_db, world_db=a.world_db,
                  realmd_db=a.realmd_db, game=GameData(a.dbc_dir), state_path=a.state, dry_run=a.dry_run,
                  full=a.full, community=a.community, skip_prefix=a.skip_accounts, verbose=a.verbose,
                  community_dir=a.community_dir)
    res = ex.run()
    print(f"armory {res['realm']}: {res['characters']} characters, {res['exported']} exported, {res['guilds']} guilds, "
          f"{len(res['written'])} written, {len(res['deleted'])} deleted, {res['unchanged']} unchanged"
          + (" (dry run)" if a.dry_run else ""))
    if a.verbose or a.dry_run:
        for rel in res["written"]:
            print("  write  " + rel)
        for rel in res["deleted"]:
            print("  delete " + rel)
    if a.publish == "git":
        publish_git(a.out, dry=a.dry_run)
    elif a.publish == "r2":
        publish_r2(a.out, res["written"], res["deleted"], dry=a.dry_run)
    if a.torrent:
        torrent_snapshot(a.out, a.torrent, dry=a.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
