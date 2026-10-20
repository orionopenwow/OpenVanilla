#!/usr/bin/env python3
"""Open Vanilla Workshop builder: catalogue -> the static JSON the website and the launcher read.

    python3 tools/workshop_build.py                  JSON only (uses packages already built)
    python3 tools/workshop_build.py --fetch          also (re)package rehostable addons: clone the
                                                     pinned commit, scan it, zip it, record sha256
    python3 tools/workshop_build.py --only pfui,cp-raid --fetch
    python3 tools/workshop_build.py --stats stats.json   bake a ratings/installs snapshot in

Reads  workshop/catalog/*.yml (tools/workshop_index.py + hand edits) and workshop/collections/*.yml.
Writes www/community/workshop/index.json, www/community/workshop/<id>.json and, with --fetch,
       www/community/workshop/files/<id>-<sha12>.zip (+ `files:` and `scan:` back into the .yml).

Rules:
  * Only `rehost: true` entries (licence on workshop_lib.ALLOWED_LICENSES) and our own Classic+
    addons are packaged. Everything else is a link to the author's page ("Get it from the author").
  * Each package carries OPENVANILLA-CREDITS.txt (name, author, source, commit, licence) in every addon
    folder, and the upstream LICENSE file when the folder has none of its own.
  * Every package is scanned (tools/workshop_scan.py); `compat` comes from the scan unless the
    entry sets `compat_locked: true` (a person checked it in the game).
  * Entries with `listed: false` (new indexer finds nobody has reviewed yet) are left out.
  * Packages larger than --max-mb (default 8) are not mirrored; the entry stays a link-out.

index.json  {"updated", "base", "categories": [...], "addons": [card], "collections": [...],
             "creators": [...], "badges": {...}}
<id>.json   the card plus description, screenshots, files, credits, scan, requires, links.
Ratings, reviews and install counts are live from the realm (`/api/workshop/*`, patch 0013); the
`stats` block in the JSON is a snapshot for when that is unreachable (pages say so).
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import workshop_lib as W  # noqa: E402
import workshop_scan as S  # noqa: E402

import yaml  # noqa: E402

COLLECTIONS_DIR = os.path.join(W.ROOT, "workshop", "collections")
SITE = "https://openvanilla.app/"
ZIP_DATE = (1980, 1, 1, 0, 0, 0)
BADGES = {
    "works": {"label": "Works", "icon": "assets/workshop/badge_works.webp",
              "tip": "Loaded and logged in clean in the Vanilla simulator."},
    "partly": {"label": "Partly", "icon": "assets/workshop/badge_partly.webp",
               "tip": "Loads; some parts use client features the simulator does not model, or later-client code paths."},
    "needs-fixes": {"label": "Needs fixes", "icon": "assets/workshop/badge_needs.webp",
                    "tip": "Errors on load or at login in the Vanilla simulator."},
    "unknown": {"label": "Not checked", "icon": "assets/workshop/badge_unknown.webp",
                "tip": "Not scanned yet (only rehostable addons are scanned)."},
    "ours": {"label": "Ours", "icon": "assets/workshop/badge_ours.webp",
             "tip": "Made by Open Vanilla for Classic+; ships with the client."},
}


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def creator_id(author):
    first = re.split(r"\s*[(,]|\s+and\s+", str(author or "unknown"))[0]
    return W.slug(first)


def credits_text(e):
    up = e.get("upstream") or {}
    lines = [
        f"{e['name']} — packaged by the Open Vanilla Workshop",
        "",
        f"Author:   {e.get('author', '')}",
        f"Source:   {e.get('source_url') or e.get('homepage') or ''}",
        f"Commit:   {up.get('commit', '')}" if up.get("commit") else "",
        f"Licence:  {e.get('license', '')}",
        "",
        "This package is the author's code as published, unmodified except for this file (and a copy of",
        "the licence when the addon folder had none). All credit belongs to the author. Report problems",
        "with the addon to the author; problems with the package to https://openvanilla.app/workshop.html.",
    ]
    return "\n".join(ln for ln in lines if ln is not None) + "\n"


def det_zip(out_path, folders, extra):
    """A deterministic zip: sorted entries, fixed timestamps. folders: [(src_dir, name_in_zip)],
    extra: {zip_path: text}."""
    entries = []
    for src, name in folders:
        for dp, dn, files in os.walk(src):
            dn[:] = sorted(d for d in dn if d not in (".git", ".github", "__MACOSX"))
            for f in sorted(files):
                full = os.path.join(dp, f)
                rel = os.path.relpath(full, src).replace(os.sep, "/")
                if os.path.islink(full):
                    continue
                entries.append((f"{name}/{rel}", full, None))
    for zp, text in extra.items():
        entries.append((zp, None, text.encode("utf-8")))
    entries.sort(key=lambda t: t[0])
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for zp, full, data in entries:
            info = zipfile.ZipInfo(zp, ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            if data is None:
                with open(full, "rb") as fh:
                    data = fh.read()
            z.writestr(info, data)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=600,
                          env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})


def fetch_source(e, cache):
    """A checkout of the entry's pinned commit (shallow). Returns the folder or raises."""
    up = e.get("upstream") or {}
    repo, commit = up.get("repo"), up.get("commit")
    if not repo:
        raise RuntimeError("no upstream repo")
    dest = os.path.join(cache, e["id"])
    if not os.path.isdir(os.path.join(dest, ".git")):
        shutil.rmtree(dest, ignore_errors=True)
        r = git("clone", "-q", "--depth", "1", "--recurse-submodules", "--shallow-submodules",
                f"https://github.com/{repo}", dest)
        if r.returncode:
            raise RuntimeError("clone failed: " + r.stderr.strip()[-200:])
    head = git("rev-parse", "HEAD", cwd=dest).stdout.strip()
    if commit and head != commit:
        r = git("fetch", "-q", "--depth", "1", "origin", commit, cwd=dest)
        if r.returncode == 0:
            git("checkout", "-q", commit, cwd=dest)
            git("submodule", "update", "-q", "--init", "--depth", "1", cwd=dest)
        else:
            raise RuntimeError(f"pinned commit {commit[:7]} not fetchable")
    return dest


def toc_name(folder):
    for f in os.listdir(folder):
        if f.lower().endswith(".toc"):
            return f[:-4]
    return os.path.basename(folder)


LICENSE_NAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING", "COPYING.txt", "license.txt")


def package(e, out_dir, cache, known, max_mb, log):
    """Build (or rebuild) the entry's zip; returns (files, scan, folders) or raises."""
    if e.get("ours"):
        src_root = None
        folders = [(os.path.join(W.ADDONS_DIR, f), f) for f in e.get("folders") or []]
        scan = S.scan_path(folders[0][0], known=known) if folders else {"compat": "unknown", "findings": [], "addons": []}
        license_text = None
    else:
        src_root = fetch_source(e, cache)
        found = S.addon_folders(src_root)
        if not found:
            raise RuntimeError("no .toc in the repository")
        folders = [(f, S.toc_basename(f) or toc_name(f)) for f in found]
        scan = S.scan_path(src_root, known=known)
        license_text = None
        for n in LICENSE_NAMES:
            p = os.path.join(src_root, n)
            if os.path.isfile(p):
                with open(p, encoding="utf-8", errors="replace") as fh:
                    license_text = fh.read()
                break
    extra = {}
    for src, name in folders:
        extra[f"{name}/OPENVANILLA-CREDITS.txt"] = credits_text(e)
        has_own = any(os.path.isfile(os.path.join(src, n)) for n in LICENSE_NAMES)
        if license_text and not has_own:
            extra[f"{name}/LICENSE-{e['id']}.txt"] = license_text
    os.makedirs(os.path.join(out_dir, "files"), exist_ok=True)
    tmp = tempfile.NamedTemporaryFile(suffix=".zip", delete=False, dir=os.path.join(out_dir, "files"))
    tmp.close()
    det_zip(tmp.name, folders, extra)
    size = os.path.getsize(tmp.name)
    if size > max_mb * 1024 * 1024:
        os.remove(tmp.name)
        raise RuntimeError(f"package is {size / 1048576:.1f} MB (over {max_mb} MB): left as a link-out")
    digest = sha256(tmp.name)
    name = f"{e['id']}-{digest[:12]}.zip"
    final = os.path.join(out_dir, "files", name)
    for old in os.listdir(os.path.join(out_dir, "files")):
        if old.startswith(e["id"] + "-") and old.endswith(".zip") and old != name and re.fullmatch(
                re.escape(e["id"]) + r"-[0-9a-f]{12}\.zip", old):
            os.remove(os.path.join(out_dir, "files", old))
    os.replace(tmp.name, final)
    files = [{"name": name, "url": f"community/workshop/files/{name}", "sha256": digest, "size": size,
              "folders": [n for _s, n in folders]}]
    return files, scan, [n for _s, n in folders]


def scan_summary(scan):
    addons = scan.get("addons") or []
    return {
        "compat": scan.get("compat", "unknown"),
        "checked": dt.date.today().isoformat(),
        "findings": [{k: f.get(k) for k in ("kind", "severity", "detail", "addon")} for f in scan.get("findings", [])][:12],
        "errors": [e.splitlines()[0][:220] for a in addons for e in a.get("errors", [])][:6],
        "sim_gaps": sum(len(a.get("sim_gaps", [])) for a in addons),
        "saved": sorted({s for a in addons for s in a.get("saved", [])}),
        "xml_files": sum((a.get("xml") or {}).get("files", 0) for a in addons),
    }


def requires_of(e, by_folder):
    if not e.get("ours"):
        return []
    deps = re.split(r"[,\s]+", (e.get("upstream") or {}).get("deps", "") or "")
    return [by_folder[d] for d in deps if d in by_folder and by_folder[d] != e["id"]]


def card(e, stats):
    s = stats.get(e["id"], {})
    installable = bool(e.get("files")) and (e.get("ours") or e.get("rehost"))
    shots = e.get("screenshots") or []
    return {
        "id": e["id"], "name": e["name"], "author": e.get("author", ""), "creator": creator_id(e.get("author")),
        "summary": e.get("summary", ""), "category": e.get("category", "utility"),
        "compat": e.get("compat", "unknown"), "ours": bool(e.get("ours")), "rehost": bool(e.get("rehost")),
        "install": installable, "license": e.get("license", "NOASSERTION"), "version": e.get("version"),
        "added": str(e.get("added") or ""), "tags": e.get("tags") or [],
        "thumb": shots[0] if shots else f"assets/workshop/cat_{e.get('category', 'utility')}.webp",
        "verified": bool(e.get("verified")),
        "stats": {"rating": s.get("rating", 0), "votes": s.get("votes", 0), "installs": s.get("installs", 0)},
    }


def build(args, log=print):
    entries = [e for e in W.load_catalog(args.catalog) if e.get("listed", True) is not False]
    only = set(filter(None, (args.only or "").split(",")))
    stats = {}
    if args.stats:
        with open(args.stats, encoding="utf-8") as f:
            stats = json.load(f)
    os.makedirs(args.out, exist_ok=True)
    known = S.known_saved_names(args.catalog)
    problems = []
    for e in entries:
        e["rehost"] = bool(e.get("ours")) or (W.may_rehost(e.get("license")) and not e.get("no_rehost"))
        if e.get("compat") not in W.COMPAT_VALUES:
            e["compat"] = "unknown"
        if args.fetch and (not only or e["id"] in only) and e["rehost"]:
            try:
                files, scan, folders = package(e, args.out, args.cache, known, args.max_mb, log)
                e["files"] = files
                e["folders"] = folders
                e["scan"] = scan_summary(scan)
                if not e.get("compat_locked"):
                    e["compat"] = e["scan"]["compat"] if not e.get("ours") or e["scan"]["compat"] != "unknown" else "works"
                log(f"  packaged {e['id']}: {files[0]['size'] / 1024:.0f} KB, {e['compat']}")
            except Exception as ex:  # noqa: BLE001  (one bad repo must not stop the build)
                problems.append(f"{e['id']}: {ex}")
                e.pop("files", None)
                e.setdefault("scan", {})["note"] = str(ex)[:200]
            W.write_entry(e, args.catalog)
        # never offer a package whose file is gone
        if e.get("files"):
            ok = all(os.path.isfile(os.path.join(args.out, "files", f["name"])) for f in e["files"])
            if not ok:
                e["files"] = []

    by_folder = {f: e["id"] for e in entries if e.get("ours") for f in (e.get("folders") or [])}
    ids = {e["id"] for e in entries}
    cards = []
    for e in sorted(entries, key=lambda x: (not x.get("ours"), x["name"].lower())):
        c = card(e, stats)
        cards.append(c)
        full = dict(c)
        full.update({
            "description": e.get("description") or e.get("summary", ""),
            "screenshots": e.get("screenshots") or [],
            "source_url": e.get("source_url"), "homepage": e.get("homepage") or e.get("source_url"),
            "files": e.get("files") or [], "folders": e.get("folders") or [],
            "requires": requires_of(e, by_folder),
            "scan": e.get("scan") or None,
            "credits": {"author": e.get("author", ""), "license": e.get("license", "NOASSERTION"),
                        "source": e.get("source_url") or e.get("homepage"),
                        "commit": (e.get("upstream") or {}).get("commit"),
                        "text": credits_text(e) if e.get("rehost") else None},
            "install_url": f"openvanilla://workshop/install/{e['id']}" if c["install"] else None,
            "versions": [{"version": e.get("version") or "", "date": str(e.get("added") or ""),
                          "sha256": f["sha256"], "size": f["size"]} for f in (e.get("files") or [])],
        })
        with open(os.path.join(args.out, f"{e['id']}.json"), "w", encoding="utf-8") as f:
            json.dump(full, f, indent=1, ensure_ascii=False)

    collections = []
    if os.path.isdir(args.collections):
        for name in sorted(os.listdir(args.collections)):
            if name.endswith(".yml"):
                with open(os.path.join(args.collections, name), encoding="utf-8") as f:
                    col = yaml.safe_load(f)
                missing = [a for a in col.get("addons", []) if a not in ids]
                if missing:
                    problems.append(f"collection {col['id']}: unknown addons {missing}")
                col["addons"] = [a for a in col.get("addons", []) if a in ids]
                collections.append(col)

    creators = {}
    for c in cards:
        cr = creators.setdefault(c["creator"], {"id": c["creator"], "name": re.split(r"\s*[(,]|\s+and\s+", c["author"] or "?")[0],
                                                "addons": [], "links": []})
        cr["addons"].append(c["id"])
    for e in entries:
        src = e.get("source_url") or ""
        m = re.match(r"https://github\.com/([^/]+)/", src)
        if m and not e.get("ours"):
            link = f"https://github.com/{m.group(1)}"
            cr = creators[creator_id(e.get("author"))]
            if link not in cr["links"]:
                cr["links"].append(link)

    cats = []
    for cid, cname in W.CATEGORIES.items():
        n = sum(1 for c in cards if c["category"] == cid)
        if n:
            cats.append({"id": cid, "name": cname, "count": n, "banner": f"assets/workshop/cat_{cid}.webp"})
    index = {
        "updated": now_iso(), "base": SITE, "count": len(cards),
        "categories": cats, "badges": BADGES, "addons": cards, "collections": collections,
        "creators": sorted(creators.values(), key=lambda c: c["name"].lower()),
        "api": "https://play.openvanilla.app/api/workshop/",
    }
    with open(os.path.join(args.out, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1, ensure_ascii=False)
    # per-addon files of entries that left the catalogue
    for name in os.listdir(args.out):
        if name.endswith(".json") and name != "index.json" and name[:-5] not in ids:
            os.remove(os.path.join(args.out, name))
    for p in problems:
        log("note: " + p)
    log(f"wrote {len(cards)} addons, {len(collections)} collections, {len(creators)} creators to {args.out}")
    return index, problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--catalog", default=W.CATALOG_DIR)
    ap.add_argument("--collections", default=COLLECTIONS_DIR)
    ap.add_argument("--out", default=W.OUT_DIR)
    ap.add_argument("--cache", default=os.path.join(os.path.expanduser("~"), ".cache", "openvanilla-workshop"))
    ap.add_argument("--fetch", action="store_true", help="package (clone, scan, zip) rehostable addons")
    ap.add_argument("--only")
    ap.add_argument("--stats", help="JSON {id: {rating, votes, installs}} snapshot")
    ap.add_argument("--max-mb", type=float, default=8)
    args = ap.parse_args(argv)
    build(args)


if __name__ == "__main__":
    main()
