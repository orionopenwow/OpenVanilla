#!/usr/bin/env python3
"""Open Vanilla Workshop scanner: load an addon in the Lua sim and say how well it runs on 1.12.

    python3 tools/workshop_scan.py path/to/AddonFolder [--dep path/to/Dependency] [--json]
    python3 tools/workshop_scan.py path/to/upload.zip [--json]
    python3 tools/workshop_scan.py --queue DIR      scan every DIR/*.zip that has no .scan.json yet

What it does, per addon folder:
  * a fresh fake 1.12.1 client (devkit/sim/wow_api.lua) loads the folder's .toc in order, every
    file through the Lua 5.0 guard (`#`, `%`, select, string.match/gmatch, `...` as a value);
    XML files contribute their <Script file=> / <Include file=> Lua and their named frames;
  * VARIABLES_LOADED / PLAYER_LOGIN / PLAYER_ENTERING_WORLD, then two seconds of OnUpdate;
  * runtime errors at load and at login, split into the addon's bugs and the sim's own gaps
    ("fake API missing ... real 1.12 function" is the sim's gap, not the addon's);
  * suspicious behaviour: SendChatMessage / SendAddonMessage while loading or at login, chat sent
    on a timer, reading another addon's SavedVariables, reaching for `os` / `io` (static and at
    runtime), plus static flags for calls that move gold or items or run arbitrary code.

Result: {"compat": works|partly|needs-fixes|unknown, "findings": [...], "addons": [...]}.
  works        loaded and logged in clean
  partly       loaded, but used real 1.12 API the sim does not model (judge it in the game)
  needs-fixes  Lua 5.0 guard hits, syntax errors or runtime errors
  unknown      no .toc found / the sim could not run
Any "high" finding is shown on the addon page; uploads with one are held for a moderator either way.

Used by tools/workshop_build.py for rehostable addons and, offline, for the realm's upload queue
(`/api/workshop/upload` stores zips; this writes <zip>.scan.json next to each; a moderator approves).
"""
import argparse
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

HERE = os.path.dirname(os.path.abspath(__file__))
SIM_DIR = os.path.join(W.ROOT, "devkit", "sim")
DRIVER = os.path.join(HERE, "workshop_scan.lua")
LUA = shutil.which("lua5.1") or shutil.which("lua")
MAX_ZIP = 10 * 1024 * 1024
MAX_UNPACKED = 60 * 1024 * 1024
RANK = {"works": 0, "partly": 1, "unknown": 2, "needs-fixes": 3}

STATIC_RULES = [
    # (kind, severity, regex, detail)
    ("os-io", "high", r"(?<![\w.:])(os|io)\s*\.\s*(execute|popen|remove|rename|open|exit|getenv|tmpname|lines|read|write)\b",
     "uses the {0} library (the game has none)"),
    ("runs-code", "medium", r"\bRunScript\s*\(", "runs code from a string (RunScript)"),
    ("moves-gold", "medium", r"\b(SendMail|PlaceAuctionBid|SetTradeMoney|PickupPlayerMoney|AcceptTrade)\s*\(",
     "calls {0} (moves gold or items)"),
    ("guild-admin", "medium", r"\b(GuildUninvite|GuildPromote|GuildDemote|GuildSetLeader|GuildDisband)\s*\(",
     "calls {0} (guild administration)"),
    ("sends-chat", "info", r"\bSendChatMessage\s*\(", "can send chat messages"),
    ("addon-comms", "info", r"\bSendAddonMessage\s*\(", "talks to other players' addons"),
    ("loadstring", "info", r"\bloadstring\s*\(", "compiles code at runtime (loadstring)"),
]


def strip_lua_comments(src):
    src = re.sub(r"--\[(=*)\[.*?\]\1\]", "", src, flags=re.S)
    return re.sub(r"--[^\n]*", "", src)


def known_saved_names(catalog_dir=W.CATALOG_DIR, addons_dir=W.ADDONS_DIR):
    """SavedVariables names of every addon we know: our suite's .tocs plus earlier scans."""
    names = set()
    if os.path.isdir(addons_dir):
        for folder in os.listdir(addons_dir):
            toc = W.read_toc(os.path.join(addons_dir, folder, folder + ".toc"))
            if toc:
                for key in ("SavedVariables", "SavedVariablesPerCharacter"):
                    names.update(x for x in re.split(r"[,\s]+", toc["meta"].get(key, "")) if x)
    for e in W.load_catalog(catalog_dir):
        names.update((e.get("scan") or {}).get("saved", []) or [])
    return names


def toc_basename(folder):
    """The .toc's name (without .toc) in a folder: the folder's own name if it has one, else the
    only .toc there."""
    try:
        tocs = [f[:-4] for f in os.listdir(folder) if f.lower().endswith(".toc")]
    except OSError:
        return None
    base = os.path.basename(folder.rstrip("/"))
    for t in tocs:
        if t.lower() == base.lower():
            return t
    return tocs[0] if len(tocs) == 1 else (sorted(tocs)[0] if tocs else None)


def toc_of(folder):
    name = os.path.basename(folder.rstrip("/"))
    try:
        for f in os.listdir(folder):
            if f.lower() == name.lower() + ".toc":
                return W.read_toc(os.path.join(folder, f))
    except OSError:
        pass
    return None


def static_findings(folder, own_saved, known):
    out, seen = [], set()
    for dp, _dn, files in os.walk(folder):
        for f in sorted(files):
            if not f.lower().endswith(".lua"):
                continue
            path = os.path.join(dp, f)
            rel = os.path.relpath(path, folder)
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    src = strip_lua_comments(fh.read())
            except OSError:
                continue
            for kind, sev, rx, detail in STATIC_RULES:
                m = re.search(rx, src)
                if m and (kind, m.group(0)) not in seen:
                    seen.add((kind, m.group(0)))
                    out.append({"kind": kind, "severity": sev, "detail": detail.format(m.group(1) if m.groups() else ""),
                                "where": rel})
            for name in known - own_saved:
                if len(name) > 4 and re.search(r"(?<![\w.])" + re.escape(name) + r"(?![\w])", src):
                    key = ("reads-other-saved", name)
                    if key not in seen:
                        seen.add(key)
                        out.append({"kind": "reads-other-saved", "severity": "medium",
                                    "detail": f"mentions another addon's saved variables: {name}", "where": rel})
    return out


NIL_GLOBAL_RE = re.compile(r"attempt to (?:index|call|concatenate|perform arithmetic on) global '([A-Za-z_][\w]*)' \(a nil value\)"
                           r"|[Tt]he function (\w+) does not exist")


def real_globals():
    out = set()
    try:
        with open(os.path.join(SIM_DIR, "data", "globals_112.tsv"), encoding="utf-8") as f:
            out = {ln.split("\t")[0] for ln in f if ln.strip() and not ln.startswith("#")}
    except OSError:
        pass
    return out


REAL_GLOBALS = real_globals()


def defines(folders, name):
    """True when one of the folders' Lua/XML defines the global `name` (assigns it, or names a frame)."""
    rx = re.compile(r"(?<![\w.])" + re.escape(name) + r"\s*=[^=]|function\s+" + re.escape(name) + r"\b|name=\"" + re.escape(name) + r"\""
                    r"|CreateFrame\([^)]*[\"']" + re.escape(name) + r"[\"']")
    for folder in folders:
        for dp, _dn, files in os.walk(folder):
            for f in files:
                if f.lower().endswith((".lua", ".xml")):
                    try:
                        with open(os.path.join(dp, f), encoding="utf-8", errors="replace") as fh:
                            if rx.search(fh.read()):
                                return True
                    except OSError:
                        pass
    return False


def reclassify(res, folders):
    """An error on a global the addon never defines is a stock 1.12 object the sim does not model
    (GameMenuButtonKeybindings, ...) or a missing dependency: a sim gap, not an addon bug."""
    keep, cache = [], {}
    for e in res.get("errors", []):
        m = NIL_GLOBAL_RE.search(e)
        if m:
            name = m.group(1) or m.group(2)
            if name not in cache:
                # a real 1.12 function, or an ALL_CAPS GlobalStrings constant, is the sim's gap
                cache[name] = False if (name in REAL_GLOBALS or re.fullmatch(r"[A-Z][A-Z0-9_]+", name)) \
                    else defines(folders, name)
            if not cache[name]:
                res.setdefault("sim_gaps", []).append(f"uses '{name}', which the sim does not model: " + e[:200])
                continue
        keep.append(e)
    res["error_count"] = res.get("error_count", len(res.get("errors", []))) - (len(res.get("errors", [])) - len(keep))
    res["errors"] = keep
    if res.get("compat") == "needs-fixes" and res["error_count"] <= 0:
        res["compat"] = "partly"


def scan_folder(folder, deps=(), known=None, timeout=120):
    """Scan one addon folder. Returns a dict (see the module doc)."""
    folder = os.path.abspath(folder)
    name = os.path.basename(folder.rstrip("/"))
    toc = toc_of(folder)
    if not toc:
        return {"addon": name, "compat": "unknown", "findings": [], "errors": [f"no {name}.toc"], "loaded": False}
    if not LUA:
        return {"addon": name, "compat": "unknown", "findings": [], "errors": ["lua5.1 is not installed"], "loaded": False}
    known = set(known if known is not None else known_saved_names())
    own = set()
    for t in [toc] + [toc_of(d) for d in deps]:
        for k in ("SavedVariables", "SavedVariablesPerCharacter"):
            own.update(x for x in re.split(r"[,\s]+", ((t or {}).get("meta") or {}).get(k, "")) if x)
    cmd = [LUA, DRIVER, SIM_DIR, W.ROOT, folder, ",".join(sorted(known))] + [os.path.abspath(d) for d in deps]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"addon": name, "compat": "needs-fixes", "loaded": False, "errors": [f"did not finish loading in {timeout}s (endless loop?)"],
                "findings": [{"kind": "timeout", "severity": "high", "detail": "loading never finished", "where": "load"}]}
    line = next((ln for ln in reversed(p.stdout.splitlines()) if ln.startswith("{")), "")
    try:
        res = json.loads(line)
    except ValueError:
        return {"addon": name, "compat": "unknown", "loaded": False, "findings": [],
                "errors": ["the sim crashed: " + (p.stderr.strip().splitlines() or ["no output"])[-1][:300]]}
    res["unknown_globals"] = res.get("unknown_globals", [])[:40]
    reclassify(res, [folder] + list(deps))
    dyn = {(f["kind"], f["detail"]) for f in res.get("findings", [])}
    for f in static_findings(folder, own, known):
        if (f["kind"], f["detail"]) not in dyn:
            res["findings"].append(f)
    res["findings"].sort(key=lambda f: ({"high": 0, "medium": 1, "info": 2}.get(f["severity"], 3), f["kind"]))
    res["toc"] = {k: toc["meta"].get(k, "") for k in ("Title", "Version", "Author", "Interface", "Notes", "Dependencies",
                                                       "RequiredDeps", "OptionalDeps", "SavedVariables",
                                                       "SavedVariablesPerCharacter", "X-ClassicPlus")}
    if res["toc"]["Interface"] and res["toc"]["Interface"] not in ("11200", "11201", "11100", "11000"):
        res["findings"].append({"kind": "interface", "severity": "info", "where": "toc",
                                "detail": f"made for interface {res['toc']['Interface']}, not 1.12 (11200)"})
    return res


def addon_folders(root):
    """Folders under root that hold <folder>.toc, outermost first (libraries inside an addon are
    part of it). A GitHub "Repo-master/Addon.toc" layout counts as one addon."""
    found = []
    for dp, dn, files in os.walk(root):
        dn.sort()
        tocs = [f for f in files if f.lower().endswith(".toc")]
        if not tocs:
            continue
        if any(dp.startswith(f + os.sep) for f in found):
            continue
        found.append(dp)
    return found


def safe_extract(zip_path, dest):
    if os.path.getsize(zip_path) > MAX_ZIP:
        raise ValueError("zip is larger than 10 MB")
    total = 0
    root = os.path.realpath(dest)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            total += info.file_size
            if total > MAX_UNPACKED:
                raise ValueError("zip unpacks to more than 60 MB")
            target = os.path.realpath(os.path.join(root, info.filename.replace("\\", "/")))
            if not target.startswith(root + os.sep) and target != root:
                raise ValueError(f"unsafe path in zip: {info.filename}")
        z.extractall(root)


def worst(values):
    vals = [v for v in values if v in RANK] or ["unknown"]
    return max(vals, key=lambda v: RANK[v])


def scan_path(path, deps=(), known=None):
    """A folder or a zip -> {"compat", "findings", "addons": [per-folder results]}."""
    tmp = tmp_links = None
    try:
        if os.path.isfile(path) and path.lower().endswith(".zip"):
            tmp = tempfile.mkdtemp(prefix="owscan-")
            try:
                safe_extract(path, tmp)
            except (ValueError, zipfile.BadZipFile) as e:
                return {"compat": "unknown", "findings": [{"kind": "bad-zip", "severity": "high", "detail": str(e), "where": "zip"}],
                        "addons": []}
            root = tmp
        else:
            root = path
        folders = addon_folders(root)
        if os.path.isdir(root) and toc_of(root):
            folders = [root]
        if not folders:
            return {"compat": "unknown", "findings": [{"kind": "no-toc", "severity": "high", "detail": "no .toc file: not a WoW addon",
                                                       "where": "zip"}], "addons": []}
        # The game names an addon after its folder, and addons compare ADDON_LOADED's arg1 with
        # their own name, so a GitHub checkout ("pfUI-master/pfUI.toc") is scanned under the
        # .toc's name through a symlink.
        links = tempfile.mkdtemp(prefix="owscan-names-")
        tmp_links = links
        named = []
        for f in folders:
            want = toc_basename(f)
            if want and os.path.basename(f.rstrip("/")) != want:
                link = os.path.join(links, want)
                if not os.path.exists(link):
                    os.symlink(os.path.abspath(f), link)
                    named.append(link)
                    continue
            named.append(f)
        folders = named
        by_name = {os.path.basename(f): f for f in folders}
        results = []
        for f in folders:
            toc = toc_of(f) or {"meta": {}}
            mine = [by_name[d] for key in ("Dependencies", "RequiredDeps")
                    for d in re.split(r"[,\s]+", toc["meta"].get(key, "")) if d in by_name and by_name[d] != f]
            ours = [os.path.join(W.ADDONS_DIR, d) for key in ("Dependencies", "RequiredDeps")
                    for d in re.split(r"[,\s]+", toc["meta"].get(key, "")) if d and d not in by_name
                    and os.path.isfile(os.path.join(W.ADDONS_DIR, d, d + ".toc"))]
            results.append(scan_folder(f, deps=list(deps) + ours + mine, known=known))
        findings = [dict(fd, addon=r["addon"]) for r in results for fd in r.get("findings", [])]
        return {"compat": worst(r["compat"] for r in results), "findings": findings, "addons": results}
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
        if tmp_links:
            shutil.rmtree(tmp_links, ignore_errors=True)


def scan_queue(queue_dir, log=print):
    """The realm's upload queue: <id>.zip files; writes <id>.scan.json beside each new one."""
    done = 0
    known = known_saved_names()
    for f in sorted(os.listdir(queue_dir)):
        if not f.endswith(".zip"):
            continue
        out = os.path.join(queue_dir, f[:-4] + ".scan.json")
        if os.path.exists(out):
            continue
        res = scan_path(os.path.join(queue_dir, f), known=known)
        res["held"] = any(fd["severity"] == "high" for fd in res["findings"]) or res["compat"] in ("needs-fixes", "unknown")
        tmp = out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(res, fh, indent=1)
        os.replace(tmp, out)
        log(f"{f}: {res['compat']}, {len(res['findings'])} findings{' (held for a moderator)' if res['held'] else ''}")
        done += 1
    return done


def summary(res):
    lines = [f"compat: {res['compat']}"]
    for a in res.get("addons", []):
        lines.append(f"  {a['addon']}: {a['compat']} ({a.get('error_count', len(a.get('errors', [])))} errors, "
                     f"{len(a.get('sim_gaps', []))} sim gaps, xml files {a.get('xml', {}).get('files', 0)})")
        for e in a.get("errors", [])[:5]:
            lines.append("    error: " + e.splitlines()[0][:160])
    for f in res.get("findings", []):
        lines.append(f"  [{f['severity']}] {f['kind']}: {f['detail']} ({f.get('addon', '')} {f.get('where', '')})")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("path", nargs="?")
    ap.add_argument("--dep", action="append", default=[], help="a dependency folder to load first")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--queue", help="scan every new zip in this folder")
    args = ap.parse_args(argv)
    if args.queue:
        n = scan_queue(args.queue)
        print(f"scanned {n} uploads")
        return 0
    if not args.path:
        ap.error("give a folder, a zip or --queue DIR")
    res = scan_path(args.path, deps=args.dep)
    print(json.dumps(res, indent=1) if args.json else summary(res))
    return 0 if res["compat"] in ("works", "partly") else 1


if __name__ == "__main__":
    sys.exit(main())
