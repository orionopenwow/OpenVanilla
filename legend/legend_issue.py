#!/usr/bin/env python3
"""Realm-side Legend issuer for Open Vanilla. Run from cron on the game server.

    python3 legend_issue.py --host duels.openvanilla.app --name Duels \
        --key /opt/openvanilla-legend/duels.key --rows rows.tsv \
        [--heroes heroes.json] --out DIR --wellknown PATH

rows.tsv (tab-separated, with header):
    guid name race class gender level account rating best wins losses
heroes.json (optional, opted-in players only):
    {"heroes":[{"account":<int>,"hero":"ovh1...."}]}

Only characters whose record changed are re-signed (serial + 1, prev chained).
Account ids are used only to look up heroes; they never appear in output.
Licence: MIT.
"""

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
import time

import legend

RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead",
         6: "Tauren", 7: "Gnome", 8: "Troll"}
CLASSES = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest",
           7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}
GENDERS = {0: "male", 1: "female"}
COLUMNS = ["guid", "name", "race", "class", "gender", "level", "account",
           "rating", "best", "wins", "losses"]
STATE_FILE = ".state.json"


def warn(msg):
    print("legend_issue: " + msg, file=sys.stderr)


def atomic_write(path, data, mode=0o644):
    if isinstance(data, str):
        data = data.encode("utf-8")
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def pretty(obj):
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def load_or_create_key(path, now):
    """Key file: {"legend_key":1,"alg":"Ed25519","seed":"<b64url>","since":<unix>}."""
    if not os.path.exists(path):
        seed, _, kid = legend.make_realm_key()
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        body = pretty({"legend_key": 1, "alg": "Ed25519",
                       "seed": legend.b64u_encode(seed), "since": now})
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(body)
        warn("created new realm key %s (kid %s)" % (path, kid))
    st = os.stat(path)
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        warn("warning: %s is readable by others; chmod 600 it" % path)
    with open(path) as f:
        kf = json.load(f)
    seed = legend.b64u_decode(kf["seed"], 32)
    since = kf["since"]
    if not isinstance(since, int):
        raise ValueError("key file 'since' must be an integer")
    pub = legend.ed25519_public_key(seed)
    return seed, pub, legend.kid_for(pub), since


def read_rows(path):
    with open(path, encoding="utf-8") as f:
        lines = [ln.rstrip("\r\n") for ln in f]
    lines = [ln for ln in lines if ln.strip()]
    if not lines:
        return []
    header = [h.strip().lower() for h in lines[0].split("\t")]
    missing = [c for c in COLUMNS if c not in header]
    if missing:
        raise ValueError("rows file is missing columns: " + ", ".join(missing))
    idx = {c: header.index(c) for c in COLUMNS}
    rows = []
    for n, ln in enumerate(lines[1:], start=2):
        cells = ln.split("\t")
        try:
            r = {c: cells[idx[c]].strip() for c in COLUMNS}
            for c in COLUMNS:
                if c != "name":
                    r[c] = int(r[c])
        except (IndexError, ValueError):
            warn("skipping bad row at line %d" % n)
            continue
        if r["guid"] <= 0 or not r["name"]:
            warn("skipping bad row at line %d" % n)
            continue
        rows.append(r)
    return rows


def read_heroes(path):
    if not path:
        return {}
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    out = {}
    for h in data.get("heroes", []):
        acc, hero = h.get("account"), h.get("hero")
        if isinstance(acc, int) and isinstance(hero, str) and legend.HERO_RE.match(hero):
            out[acc] = hero
        else:
            warn("ignoring bad heroes.json entry")
    return out


def build_body(host, row, hero):
    return {
        "legend": 1,
        "kind": "character",
        "realm": host,
        "subject": {
            "id": "%s/%d" % (host, row["guid"]),
            "name": row["name"],
            "race": RACES.get(row["race"], "Unknown"),
            "class": CLASSES.get(row["class"], "Unknown"),
            "gender": GENDERS.get(row["gender"], "unknown"),
            "level": row["level"],
        },
        "hero": hero,
        "records": {"duels": {"rating": row["rating"], "best": row["best"],
                              "wins": row["wins"], "losses": row["losses"]}},
    }


def content_hash(body):
    return legend.b64u_encode(hashlib.sha256(legend.canonical(body)).digest())


def write_wellknown(path, host, name, kid, pub, since):
    kf = None
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                kf = json.load(f)
            if kf.get("realm", {}).get("host") != host:
                kf = None
        except (ValueError, OSError, AttributeError):
            kf = None
    keys = [k for k in (kf or {}).get("keys", []) if isinstance(k, dict) and k.get("kid") != kid]
    current = {"kid": kid, "alg": "Ed25519", "pub": legend.b64u_encode(pub),
               "since": since, "until": None}
    for k in (kf or {}).get("keys", []):  # keep a hand-set "until" on the current key
        if isinstance(k, dict) and k.get("kid") == kid and isinstance(k.get("until"), int):
            current["until"] = k["until"]
    out = {"legend": 1, "realm": {"host": host, "name": name},
           "keys": [current] + keys, "revoked": (kf or {}).get("revoked", [])}
    atomic_write(path, pretty(out))
    return out


def issue(host, name, key_path, rows_path, heroes_path, out_dir, wellknown, now=None):
    if not legend.HOST_RE.match(host):
        raise ValueError("bad --host")
    now = int(time.time()) if now is None else now
    seed, pub, kid, since = load_or_create_key(key_path, now)
    issued = max(now, since)
    rows = read_rows(rows_path)
    heroes = read_heroes(heroes_path)
    os.makedirs(out_dir, exist_ok=True)

    state_path = os.path.join(out_dir, STATE_FILE)
    state = {"version": 1, "chars": {}}
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as f:
            state = json.load(f)
    chars = state.setdefault("chars", {})

    signed = unchanged = 0
    index, seen = [], set()
    for row in rows:
        g = str(row["guid"])
        if g in seen:
            warn("duplicate guid %s; keeping the first row" % g)
            continue
        seen.add(g)
        body = build_body(host, row, heroes.get(row["account"]))
        h = content_hash(body)
        st = chars.get(g)
        path = os.path.join(out_dir, g + ".json")
        if st and st.get("h") == h and st.get("kid") == kid and os.path.exists(path):
            unchanged += 1
        else:
            doc = dict(body)
            doc["issued"] = issued
            doc["serial"] = (st["serial"] + 1) if st else 1
            doc["prev"] = st["last"] if st else None
            doc = legend.sign_document(doc, seed, kid, pub)
            atomic_write(path, pretty(doc))
            chars[g] = {"h": h, "kid": kid, "serial": doc["serial"], "last": legend.doc_hash(doc)}
            signed += 1
        s = body["subject"]
        d = body["records"]["duels"]
        index.append({"name": s["name"], "class": s["class"], "race": s["race"],
                      "level": s["level"], "rating": d["rating"], "wins": d["wins"],
                      "losses": d["losses"], "file": g + ".json",
                      "hero": body["hero"] is not None})

    index.sort(key=lambda e: (-e["rating"], e["name"]))
    atomic_write(os.path.join(out_dir, "index.json"),
                 pretty({"legend": 1, "realm": host, "name": name,
                         "generated": now, "characters": index}))
    atomic_write(state_path, pretty(state), mode=0o600)
    write_wellknown(wellknown, host, name, kid, pub, since)
    return {"signed": signed, "unchanged": unchanged, "kid": kid}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Issue signed Open Vanilla Legends for a realm.")
    ap.add_argument("--host", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--rows", required=True)
    ap.add_argument("--heroes")
    ap.add_argument("--out", required=True)
    ap.add_argument("--wellknown", required=True)
    ap.add_argument("--now", type=int, help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    r = issue(a.host, a.name, a.key, a.rows, a.heroes, a.out, a.wellknown, a.now)
    print("legend_issue: signed %d, unchanged %d, kid %s" % (r["signed"], r["unchanged"], r["kid"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
