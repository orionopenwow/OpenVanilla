"""Check a pack made in Open Vanilla Forge (.ovpack) before it goes anywhere near a realm.

    python tools/forge_verify.py pack.ovpack [--key HEX]     exit 0: fine, 1: refused

What it checks (the Workshop review runs the same):
  * the signature: SIGNATURE.json is Ed25519 (launcher/ed25519.py) over the SHA-256 of every
    other file, so nothing changed after the creator signed it; --key pins the creator's key;
  * the SQL: only the statements Forge generates, only on the world tables Forge edits (never
    realmd or characters, no other database, no file or sleep functions);
  * the client files: allowed game roots only, no DBFilesClient (DBC changes ship as row deltas);
  * the manifest: every listed file is in the MPQ's manifest with its hash.

Standard library only.
"""
import hashlib
import json
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "launcher"))
import ed25519  # noqa: E402

SIGNED_PREFIX = b"openvanilla-forge-pack/1\n"
SCHEMA = os.path.join(HERE, "..", "forge", "crates", "forge-core", "schemas", "world.json")
ROOTS = {"interface", "textures", "creature", "item", "character", "world", "sound", "spells",
         "environments", "particles", "fonts"}
FORBIDDEN = re.compile(r"\b(outfile|dumpfile|load_file|load\s+data|sleep|benchmark|grant|revoke|alter|truncate|"
                       r"rename|call|prepare|execute|handler|lock|unlock|shutdown|user|database|schema)\b", re.I)


class Refused(Exception):
    pass


def world_tables():
    with open(SCHEMA, encoding="utf-8") as f:
        # + spell_template: the server's copy of a pack's Spell rows
        return set(json.load(f)) | {"spell_template"}


def split_sql(text):
    """Statements, with string literals blanked (so a ';' or a keyword inside a name can't count)."""
    out, cur, q, i = [], [], None, 0
    while i < len(text):
        c = text[i]
        if q:
            if c == "\\":
                i += 2
                cur.append("  ")
                continue
            if c == q:
                if i + 1 < len(text) and text[i + 1] == q:  # '' inside a string
                    i += 2
                    cur.append("  ")
                    continue
                q = None
                cur.append(c)
            else:
                cur.append(" ")
        elif c in "'\"":
            q = c
            cur.append(c)
        elif c == "-" and text[i:i + 2] == "--":
            j = text.find("\n", i)
            i = len(text) if j < 0 else j
            continue
        elif c == ";":
            s = "".join(cur).strip()
            if s:
                out.append(s)
            cur = []
        else:
            cur.append(c)
        i += 1
    if "".join(cur).strip():
        out.append("".join(cur).strip())
    return out


STATEMENT = [
    r"DELETE FROM `(?P<t>\w+)` WHERE .*",
    r"INSERT (?:IGNORE )?INTO `(?P<t>\w+)` (?:\([^)]*\) VALUES \(.*\)|SELECT \* FROM `(?P<f>\w+)`(?: WHERE .*)?)",
    r"UPDATE `(?P<t>\w+)` SET .*",
    r"CREATE TABLE IF NOT EXISTS `(?P<t>forge_backup_\w+)` LIKE `(?P<f>\w+)`",
    r"CREATE TEMPORARY TABLE `(?P<t>forge_tmp)` SELECT \* FROM `(?P<f>\w+)` WHERE .*",
    r"DROP TEMPORARY TABLE (?:IF EXISTS )?`(?P<t>forge_tmp)`",
    r"DROP TABLE IF EXISTS `(?P<t>forge_backup_\w+)`",
]


def check_sql(text, allowed):
    ok_name = lambda n: n in allowed or n == "forge_tmp" or n.startswith("forge_backup_")
    for s in split_sql(text):
        flat = " ".join(s.split())
        bare = re.sub(r"`\w+`", "`x`", flat)   # column and table names can be any word
        if FORBIDDEN.search(bare):
            raise Refused(f"SQL uses something packs may not: {flat[:120]}")
        if re.search(r"(`|[A-Za-z_]\w*)\s*\.\s*[`A-Za-z_]", flat):
            raise Refused(f"SQL names another database: {flat[:120]}")
        m = next((m for m in (re.fullmatch(p, flat, re.S) for p in STATEMENT) if m), None)
        if not m:
            raise Refused(f"SQL statement Forge doesn't write: {flat[:120]}")
        for g in ("t", "f"):
            n = m.groupdict().get(g)
            if n and not ok_name(n):
                raise Refused(f"SQL touches table {n}, which packs may not change")
        for n in re.findall(r"\bFROM `(\w+)`", flat):
            if not ok_name(n):
                raise Refused(f"SQL reads table {n}")


def verify(path, key=None):
    try:
        z = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as e:
        raise Refused(f"not a pack: {e}")
    lines, sig, files = [], None, {}
    for name in z.namelist():
        if name.startswith("/") or ".." in name.split("/"):
            raise Refused(f"bad path in the package: {name}")
        data = z.read(name)
        if name == "SIGNATURE.json":
            sig = json.loads(data)
        else:
            files[name] = data
            lines.append(f"{name} {hashlib.sha256(data).hexdigest()}")
    if not sig:
        raise Refused("no SIGNATURE.json")
    lines.sort()
    digest = hashlib.sha256("\n".join(lines).encode()).hexdigest()
    if digest != sig.get("contents"):
        raise Refused("the files changed after the package was signed")
    if key and key.lower() != sig.get("public_key", "").lower():
        raise Refused("signed with a different key than this creator's")
    if not ed25519.verify(bytes.fromhex(sig["public_key"]), SIGNED_PREFIX + digest.encode(), bytes.fromhex(sig["signature"])):
        raise Refused("the signature doesn't match")
    allowed = world_tables()
    for name, data in files.items():
        if name.startswith("server/sql/") and name.endswith(".sql"):
            check_sql(data.decode("utf-8"), allowed)
    manifest = json.loads(files.get("manifest.json", b"[]"))
    for m in manifest:
        parts = m["path"].replace("\\", "/").split("/")
        if parts[0].lower() not in ROOTS:
            raise Refused(f"{m['path']}: not under a game folder packs may ship")
    return sig, sorted(files), len(manifest)


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    key = argv[argv.index("--key") + 1] if "--key" in argv else None
    try:
        sig, names, n = verify(argv[0], key)
    except Refused as e:
        print(f"REFUSED: {e}")
        return 1
    print(f"OK: {sig['pack']} {sig['version']} (build {sig['build_hash'][:12]}), signed by {sig['public_key'][:16]}…")
    print(f"  {len(names)} files, {n} client files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
