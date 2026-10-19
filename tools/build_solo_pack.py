#!/usr/bin/env python3
"""Build the Open Vanilla Solo server pack: the zip the launcher's PLAY SOLO downloads into OpenVanilla\\solo.

    python3 tools/build_solo_pack.py --server BUILD --mariadb MARIADB --db DUMPS --version 1.15.0 \\
        [--out dist/solo] [--base-url URL] [--commit SHA] [--sql-applied] [--dry-run]

Inputs (folders or .zip files):
  --server   a CMaNGOS mangos-classic Windows build with PlayerBots and our server hooks: mangosd.exe,
             realmd.exe, their DLLs and *.conf.dist, and the extractors (ad.exe, vmap_extractor.exe,
             vmap_assembler.exe, MoveMapGen.exe) in Extractors\\ or tools\\. Made by packaging/workflows/solo-pack.yml.off
             (GitHub Actions, windows-2022, at the CMaNGOS/PlayerBots commits the live realm runs, with
             realm/mangos/*.patch and solo/patches/*.patch applied); or a pinned release you trust.
  --mariadb  the portable MariaDB for Windows (mariadb-<ver>-winx64.zip from archive.mariadb.org).
             Only what a server needs is kept: bin\\mariadbd.exe, mariadb.exe, mariadb-admin.exe,
             mariadb-install-db.exe, mariadb-dump.exe, the DLLs, share\\ and lib\\plugin\\.
  --db       the database dumps: classicmangos.sql[.gz] (classic-db + PlayerBots + AHBot world tables,
             with realm/classicplus/*.sql applied), classicrealmd, classiccharacters, classiclogs.
             packaging/workflows/solo-pack.yml.off makes them with classic-db's InstallFullDB.sh on a throwaway MariaDB.
  --sql-dir  the live realm's Classic+ SQL (default realm/classicplus; pending/ is never included).
  --sql-applied   the world dump already has those SQL files applied: recorded as the pack's baseline
             so the first launch doesn't run them again (it would be harmless: they are idempotent).

Outputs in --out: OpenVanilla-Solo-<version>.zip and solo.json (what www/downloads/solo.json should hold:
version, url, size, sha256, and the Classic+ SQL list the launcher fetches between pack releases).

Never packs Blizzard game files: any .mpq/.dbc/.map/.vmtree/.vmtile/.mmap/.mmtile/.adt/.wdt/.wmo/.m2/
.blp/.mdx file, any dbc/maps/vmaps/mmaps/Buildings/Data folder, or anything that starts with the MPQ
or DBC signature stops the build.

--dry-run checks everything and prints the file list and sizes, writing nothing.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import re
import sys
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACK_FORMAT = 1
DATABASES = ("classicmangos", "classicrealmd", "classiccharacters", "classiclogs")
REQUIRED_DBS = ("classicmangos", "classicrealmd", "classiccharacters")

SERVER_EXES = ("mangosd.exe", "realmd.exe")
SERVER_CONFS = ("mangosd.conf.dist", "realmd.conf.dist", "aiplayerbot.conf.dist", "ahbot.conf.dist",
                "anticheat.conf.dist", "mods.conf.dist")
EXTRACTOR_EXES = ("ad.exe", "vmap_extractor.exe", "vmap_assembler.exe", "MoveMapGen.exe")
EXTRACTOR_FILES = ("offmesh.txt", "config.json")
MARIADB_EXES = ("mariadbd.exe", "mariadb.exe", "mariadb-admin.exe", "mariadb-install-db.exe", "mariadb-dump.exe")
MARIADB_REQUIRED = ("mariadbd.exe", "mariadb.exe", "mariadb-admin.exe", "mariadb-install-db.exe")
DEBUG_EXT = (".pdb", ".ilk", ".lib", ".exp", ".map.txt")

# Blizzard data must never ship. Extensions, folder names and file signatures.
FORBIDDEN_EXT = (".mpq", ".dbc", ".map", ".vmtree", ".vmtile", ".vmo", ".mmap", ".mmtile", ".adt", ".wdt",
                 ".wdl", ".wmo", ".m2", ".mdx", ".blp", ".skin", ".anim", ".bls", ".wfx", ".zmp", ".tex")
FORBIDDEN_DIRS = ("dbc", "maps", "vmaps", "mmaps", "buildings", "cameras", "data", "wtf", "interface")
FORBIDDEN_MAGIC = (b"MPQ\x1a", b"MPQ\x1b", b"WDBC", b"BLP1", b"BLP2", b"MD20", b"MVER", b"REVM")


class BuildError(Exception):
    pass


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_path(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


class Source:
    """A folder or a zip, read the same way: list(), read(path)."""

    def __init__(self, path, what):
        if not os.path.exists(path):
            raise BuildError(f"{what}: {path} does not exist")
        self.path, self.what = path, what
        self.zip = zipfile.ZipFile(path) if zipfile.is_zipfile(path) else None

    def list(self):
        if self.zip:
            return [i.filename.replace("\\", "/") for i in self.zip.infolist() if not i.is_dir()]
        out = []
        for root, _dirs, files in os.walk(self.path):
            for f in files:
                out.append(os.path.relpath(os.path.join(root, f), self.path).replace(os.sep, "/"))
        return sorted(out)

    def read(self, rel):
        if self.zip:
            return self.zip.read(rel)
        with open(os.path.join(self.path, *rel.split("/")), "rb") as f:
            return f.read()

    def size(self, rel):
        if self.zip:
            return self.zip.getinfo(rel).file_size
        return os.path.getsize(os.path.join(self.path, *rel.split("/")))


def find_one(names, wanted):
    """The shortest path whose basename is wanted (case-insensitive), or None."""
    hits = [n for n in names if n.rsplit("/", 1)[-1].lower() == wanted.lower()]
    return min(hits, key=len) if hits else None


def collect_server(src):
    """{pack path: (Source, member)} for the server build."""
    names = src.list()
    mangosd = find_one(names, "mangosd.exe")
    if not mangosd:
        raise BuildError("--server: no mangosd.exe in the build")
    bindir = mangosd.rsplit("/", 1)[0] + "/" if "/" in mangosd else ""
    out = {}
    for n in names:
        if not n.startswith(bindir):
            continue
        rel = n[len(bindir):]
        base = rel.rsplit("/", 1)[-1]
        low = base.lower()
        if low.endswith(DEBUG_EXT):
            continue
        if "/" not in rel and (low in [e.lower() for e in SERVER_EXES] or low.endswith(".dll")
                               or low in [c.lower() for c in SERVER_CONFS]):
            out["bin/" + base] = (src, n)
    # The extractors: CMaNGOS installs them to tools/ (the dev build puts them in Extractors/).
    ad = find_one(names, "ad.exe")
    exdir = (ad.rsplit("/", 1)[0] + "/") if ad and "/" in ad else ""
    for want in EXTRACTOR_EXES + EXTRACTOR_FILES:
        hit = next((n for n in names if n.lower() == (exdir + want).lower()), None) if ad else None
        if hit is None and want.endswith(".exe"):
            hit = find_one(names, want)
        if hit:
            out["bin/tools/" + want] = (src, hit)
    for need in SERVER_EXES + ("mangosd.conf.dist", "realmd.conf.dist"):
        if "bin/" + need not in out:
            raise BuildError(f"--server: {need} is missing from the build")
    return out


def collect_mariadb(src):
    names = src.list()
    server = find_one(names, "mariadbd.exe") or find_one(names, "mysqld.exe")
    if not server:
        raise BuildError("--mariadb: no bin/mariadbd.exe in the MariaDB package")
    prefix = server.rsplit("/", 2)[0] + "/" if server.count("/") >= 2 else ""
    out = {}
    for n in names:
        if not n.startswith(prefix):
            continue
        rel = n[len(prefix):]
        low = rel.lower()
        if low.endswith(DEBUG_EXT) or "/mysql-test/" in "/" + low or low.startswith(("include/", "sql-bench/", "data/")):
            continue
        keep = (low.startswith("bin/") and "/" not in low[4:] and (low[4:] in MARIADB_EXES or low.endswith(".dll"))) \
            or low.startswith("share/") or (low.startswith("lib/plugin/") and low.endswith(".dll"))
        if keep:
            out["mariadb/" + rel] = (src, n)
    for need in MARIADB_REQUIRED:
        if "mariadb/bin/" + need not in out:
            raise BuildError(f"--mariadb: bin/{need} is missing from the MariaDB package")
    return out


def collect_db(folder):
    out, missing = {}, []
    for name in DATABASES:
        for ext in (".sql.gz", ".sql"):
            p = os.path.join(folder, name + ext)
            if os.path.isfile(p):
                out[name] = p
                break
        else:
            if name in REQUIRED_DBS:
                missing.append(name)
    if missing:
        raise BuildError("--db: missing dump(s): " + ", ".join(m + ".sql[.gz]" for m in missing))
    return out


def gzip_bytes(data):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=6, mtime=0) as g:
        g.write(data)
    return buf.getvalue()


def check_dump(name, data):
    """A world dump that is too small or not SQL is a broken export, not a pack."""
    head = data[:4096].decode("utf-8", "replace")
    if not re.search(r"(?i)(CREATE TABLE|INSERT INTO|-- MariaDB dump|-- MySQL dump)", head + data[-4096:].decode("utf-8", "replace")):
        raise BuildError(f"--db: {name} doesn't look like an SQL dump")
    if name == "classicmangos" and b"creature_template" not in data:
        raise BuildError("--db: classicmangos has no creature_template table: not a world database")
    warn = []
    if re.search(rb"(?im)^\s*(CREATE DATABASE|USE\s+`?classic)", data[:200000]):
        warn.append(f"{name}: the dump selects or creates its own database; the launcher loads it into {name} anyway")
    return warn


def blizzard_guard(path, data):
    """None when fine, else why this file must not ship."""
    parts = path.lower().split("/")
    for d in parts[:-1]:
        if d in FORBIDDEN_DIRS and not (parts[0] == "mariadb" and d == "data"):
            return f"folder '{d}/' holds game data"
    base = parts[-1]
    if base.endswith(FORBIDDEN_EXT):
        return f"'{os.path.splitext(base)[1]}' is a game data file type"
    if data[:4] in FORBIDDEN_MAGIC:
        return f"starts with the {data[:4]!r} game file signature"
    return None


def classicplus_sql(sql_dir):
    out = {}
    for n in sorted(os.listdir(sql_dir)):
        p = os.path.join(sql_dir, n)
        if n.lower().endswith(".sql") and os.path.isfile(p):
            with open(p, "rb") as f:
                out[n] = f.read()
    return out


def sql_target(data):
    m = re.search(rb"run against (classic\w+)", data[:2000])
    return m.group(1).decode() if m and m.group(1).decode() in DATABASES else "classicmangos"


def plan(args):
    """Every file of the pack as {pack path: bytes}, plus warnings. Raises BuildError on bad input."""
    warnings = []
    files = {}
    server = collect_server(Source(args.server, "--server"))
    if "bin/aiplayerbot.conf.dist" not in server:
        msg = "--server: no aiplayerbot.conf.dist: this build has no PlayerBots"
        if not args.allow_no_bots:
            raise BuildError(msg + " (build with -DBUILD_PLAYERBOTS=ON, or pass --allow-no-bots)")
        warnings.append(msg)
    missing_ex = [e for e in EXTRACTOR_EXES[:3] if "bin/tools/" + e not in server]
    if missing_ex:
        raise BuildError("--server: the map extractors are missing (" + ", ".join(missing_ex)
                         + "); build with -DBUILD_EXTRACTORS=ON")
    if "bin/tools/MoveMapGen.exe" not in server:
        warnings.append("--server: no MoveMapGen.exe: solo players can't build movement maps")
    mariadb = collect_mariadb(Source(args.mariadb, "--mariadb"))
    for path, (src, member) in list(server.items()) + list(mariadb.items()):
        files[path] = src.read(member)

    world_hash = hashlib.sha256()
    for name, p in collect_db(args.db).items():
        with open(p, "rb") as f:
            data = f.read()
        raw = gzip.decompress(data) if p.endswith(".gz") else data
        warnings += check_dump(name, raw)
        files[f"db/{name}.sql.gz"] = data if p.endswith(".gz") else gzip_bytes(raw)
        if name == "classicmangos":
            world_hash.update(raw)

    sql = classicplus_sql(args.sql_dir)
    if not sql:
        raise BuildError(f"--sql-dir: no .sql files in {args.sql_dir}")
    for n, data in sql.items():
        files["sql/" + n] = data

    solo = os.path.join(ROOT, "solo")
    tdir = os.path.join(solo, "templates")
    for n in sorted(os.listdir(tdir)):
        with open(os.path.join(tdir, n), "rb") as f:
            files["conf/" + n] = f.read()
    for n in ("gen_outfits.py", "fix_skillraceclassinfo.py"):
        with open(os.path.join(ROOT, "realm", "classicplus", n), "rb") as f:
            files["tools/" + n] = f.read()
    with open(os.path.join(solo, "PACK_README.txt"), "rb") as f:
        files["README.txt"] = f.read().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")

    bad = [f"{p}: {why}" for p, data in sorted(files.items()) if (why := blizzard_guard(p, data))]
    if bad:
        raise BuildError("Refusing to pack game data:\n  " + "\n  ".join(bad))

    pack = {
        "format": PACK_FORMAT,
        "name": "Open Vanilla Solo",
        "version": args.version,
        "built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "commit": args.commit or "",
        "world_version": world_hash.hexdigest()[:16],
        "sql_baseline": {n: sha256_bytes(d) for n, d in sql.items()} if args.sql_applied else {},
        "playerbots": "bin/aiplayerbot.conf.dist" in files,
        "extractors": sorted(p for p in files if p.startswith("bin/tools/")),
        "components": {k: v for k, v in (("server", args.server_note), ("mariadb", args.mariadb_note),
                                         ("world_db", args.db_note)) if v},
        "files": {p: {"size": len(d), "sha256": sha256_bytes(d)} for p, d in sorted(files.items())},
    }
    return files, pack, sql, warnings


def write_zip(path, files, pack):
    tmp = path + ".tmp"
    stored = (".gz", ".zip", ".png", ".jpg")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for p in sorted(files):
            info = zipfile.ZipInfo(p, date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_STORED if p.lower().endswith(stored) else zipfile.ZIP_DEFLATED
            z.writestr(info, files[p])
        info = zipfile.ZipInfo("pack.json", date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, json.dumps(pack, indent=1))
    os.replace(tmp, path)


def launcher_manifest(args, zip_name, zip_path, sql):
    base = (args.base_url or "").rstrip("/")
    raw = f"https://raw.githubusercontent.com/{args.repo}/{args.commit or 'main'}/realm/classicplus/"
    return {
        "format": PACK_FORMAT,
        "version": args.version,
        "url": f"{base}/{zip_name}" if base else zip_name,
        "size": os.path.getsize(zip_path),
        "sha256": sha256_path(zip_path),
        "notes": "Play Open Vanilla offline on your own PC. Solo characters stay on this PC.",
        "sql": [{"name": n, "db": sql_target(d), "sha256": sha256_bytes(d), "url": raw + n} for n, d in sorted(sql.items())],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--server", required=True)
    ap.add_argument("--mariadb", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--sql-dir", default=os.path.join(ROOT, "realm", "classicplus"))
    ap.add_argument("--sql-applied", action="store_true")
    ap.add_argument("--out", default=os.path.join(ROOT, "dist", "solo"))
    ap.add_argument("--base-url", default="https://github.com/orionopenwow/OpenVanilla/releases/download/solo-{version}")
    ap.add_argument("--repo", default="orionopenwow/OpenVanilla")
    ap.add_argument("--commit", default="")
    ap.add_argument("--server-note", default="", help="where the server build came from (recorded in pack.json)")
    ap.add_argument("--mariadb-note", default="")
    ap.add_argument("--db-note", default="")
    ap.add_argument("--allow-no-bots", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    if not re.fullmatch(r"[0-9A-Za-z.+-]{1,32}", args.version):
        ap.error("--version: letters, digits, dots and dashes only")
    args.base_url = args.base_url.replace("{version}", args.version)
    try:
        files, pack, sql, warnings = plan(args)
    except BuildError as e:
        print(f"build_solo_pack: {e}", file=sys.stderr)
        return 1
    for w in warnings:
        print(f"warning: {w}")
    total = sum(len(d) for d in files.values())
    groups = {}
    for p, d in files.items():
        groups.setdefault(p.split("/")[0], [0, 0])
        groups[p.split("/")[0]][0] += 1
        groups[p.split("/")[0]][1] += len(d)
    print(f"Open Vanilla Solo {args.version}: {len(files)} files, {total / 1048576:.1f} MB before zip")
    for g, (n, size) in sorted(groups.items()):
        name = g if g in ("README.txt", "pack.json") else g + "/"
        print(f"  {name:<12}{n:>5} files {size / 1048576:9.1f} MB")
    print(f"  world_version {pack['world_version']}, playerbots {'on' if pack['playerbots'] else 'OFF'}, "
          f"{len(sql)} Classic+ SQL file(s){' (baseline recorded)' if args.sql_applied else ''}")
    if args.dry_run:
        print("dry run: nothing written")
        return 0
    os.makedirs(args.out, exist_ok=True)
    zip_name = f"OpenVanilla-Solo-{args.version}.zip"
    zip_path = os.path.join(args.out, zip_name)
    write_zip(zip_path, files, pack)
    manifest = launcher_manifest(args, zip_name, zip_path, sql)
    with open(os.path.join(args.out, "solo.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"wrote {zip_path} ({manifest['size'] / 1048576:.1f} MB, sha256 {manifest['sha256'][:16]}…)")
    print(f"wrote {os.path.join(args.out, 'solo.json')} -> publish as www/downloads/solo.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
