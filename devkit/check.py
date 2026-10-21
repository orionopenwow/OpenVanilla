#!/usr/bin/env python3
"""Fast checks over the whole repo: seconds, no game, no network. Run before every push.

    py -3 devkit/check.py            everything that can run on this machine
    py -3 devkit/check.py --strict   a missing tool (lua, node, bash) is a failure, not a skip (CI)

Checks:
  addons      every .toc lists files that exist; the Lua parses (needs luac5.1 or luac)
  patchz      realm/classicplus/patch-Z.MPQ holds exactly the suite addons and ClassicPlus art in
              Data/Interface (pure Python reader, no StormLib) -> fix with tools/sync_patchz.py
  json/yaml   every JSON file we publish parses; workflow sources parse (if PyYAML is installed)
  js          node --check on the page layer, bridge, loader and tools (needs node)
  shell       bash -n on the server scripts (needs bash)
  python      every tracked .py compiles
  realm_up    openvanilla_realm_up.sh downloads every file in realm/www and the SQL it runs
  version     launcher/version.json matches the client zip the website links
  game data   no Blizzard game files are about to be committed (MPQs other than patch-Z, maps, models)
Exit 0 = all passed.
"""
import glob
import json
import os
import py_compile
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
STRICT = "--strict" in sys.argv
ADDONS = os.path.join(ROOT, "Data", "Interface", "AddOns")
results = []


# Open Vanilla's own MPQs: patch-Z, Warfront's copy of it without the client tables (tools/warfront/make_patch_w.py),
# and Duels' copy of Warfront's with the Duels addon (tools/duels/make_patch_d.py)
OWN_MPQS = ("realm/classicplus/patch-Z.MPQ", "realm/warfront/patch-Z.MPQ", "realm/duels/patch-Z.MPQ")


def report(name, ok, detail=""):
    results.append((name, ok))
    tag = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
    print(f"{tag} {name}" + (f": {detail}" if detail and ok is not True else ""))
    if ok is False and os.environ.get("GITHUB_ACTIONS"):
        # an annotation on the run's public page, readable without opening the log
        msg = (f"{name}: {detail}" if detail else name).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title=Repo check failed::{msg[:900]}")


def tool(*names):
    for n in names:
        if shutil.which(n):
            return n
    return None


def skip(name, why):
    report(name, False if STRICT else None, why)


def rel(p):
    return os.path.relpath(p, ROOT).replace(os.sep, "/")


def suite():
    out = []
    for d in sorted(os.listdir(ADDONS)) if os.path.isdir(ADDONS) else []:
        toc = os.path.join(ADDONS, d, d + ".toc")
        if os.path.isfile(toc):
            txt = open(toc, encoding="utf-8", errors="replace").read()
            if "## X-ClassicPlus" in txt or d.startswith("!Compat"):
                out.append((d, toc, txt))
    return out


def check_addons():
    bad, files = [], []
    for d, toc, txt in suite():
        for line in txt.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            p = os.path.join(ADDONS, d, line.replace("\\", os.sep))
            if not os.path.isfile(p):
                bad.append(f"{d}.toc lists missing {line}")
            elif p.endswith(".lua"):
                files.append(p)
    report("addons: .toc file lists", not bad, "; ".join(bad))
    luac = tool("luac5.1", "luac")
    if not luac:
        return skip("addons: Lua parses", "no luac on PATH")
    errs = []
    for f in files:
        p = subprocess.run([luac, "-p", f], capture_output=True, text=True)
        if p.returncode:
            errs.append(p.stderr.strip().splitlines()[0])
    report(f"addons: Lua parses ({len(files)} files)", not errs, "; ".join(errs))


def lf(path):
    """A source file as tools/sync_patchz.py packs it (text with LF line endings)."""
    data = open(path, "rb").read()
    return data.replace(b"\r\n", b"\n") if path.lower().endswith((".toc", ".lua", ".xml", ".txt", ".md", ".json")) else data


def check_patchz():
    from mpqread import MPQ
    path = os.path.join(ROOT, "realm", "classicplus", "patch-Z.MPQ")
    if not os.path.isfile(path):
        return report("patch-Z matches Data/Interface", False, "no realm/classicplus/patch-Z.MPQ")
    m = MPQ(path)
    have = {n.lower(): n for n in m.names()}
    want = {}
    for d, _, _ in suite():
        for r, _, names in os.walk(os.path.join(ADDONS, d)):
            for n in names:
                full = os.path.join(r, n)
                want[("Interface\\AddOns\\" + os.path.relpath(full, ADDONS).replace(os.sep, "\\")).lower()] = full
    for f in glob.glob(os.path.join(ROOT, "Data", "Interface", "ClassicPlus", "*.blp")):
        want[("Interface\\ClassicPlus\\" + os.path.basename(f)).lower()] = f
    for f in glob.glob(os.path.join(ROOT, "Data", "Interface", "ClassicPlus", "LoadingScreens", "*.blp")):
        want[("Interface\\Glues\\LoadingScreens\\" + os.path.basename(f)).lower()] = f
    diffs = []
    for k, full in sorted(want.items()):
        if k not in have:
            diffs.append("missing " + k)
        elif m.read(have[k]) != lf(full):
            diffs.append("stale " + k)
    for k in have:
        if (k.startswith("interface\\addons\\") or k.startswith("interface\\classicplus\\")
                or k.startswith("interface\\glues\\loadingscreens\\")) and k not in want:
            diffs.append("extra " + k)
    report(f"patch-Z matches Data/Interface ({len(want)} files)", not diffs,
           (", ".join(diffs[:6]) + (" ..." if len(diffs) > 6 else "") + " -> run tools/sync_patchz.py") if diffs else "")


def check_json_yaml():
    bad = []
    pats = ["www/community/*.json", "www/downloads/*.json", "launcher/*.json", "realm/www/**/*.json"]
    n = 0
    for pat in pats:
        for f in glob.glob(os.path.join(ROOT, pat), recursive=True):
            n += 1
            try:
                json.load(open(f, encoding="utf-8"))
            except Exception as e:
                bad.append(f"{rel(f)}: {e}")
    report(f"json parses ({n} files)", not bad, "; ".join(bad))
    try:
        import yaml
    except ImportError:
        return skip("workflow yaml parses", "PyYAML not installed (py -3 -m pip install pyyaml)")
    bad = []
    files = glob.glob(os.path.join(ROOT, "packaging", "workflows", "*.yml"))   # the workflows' one source
    for f in files:
        try:
            yaml.safe_load(open(f, encoding="utf-8"))
        except Exception as e:
            bad.append(f"{rel(f)}: {e}")
    report(f"workflow yaml parses ({len(files)} files)", not bad, "; ".join(bad))


def check_js():
    node = tool("node")
    if not node:
        return skip("js parses", "no node on PATH")
    files = glob.glob(os.path.join(ROOT, "realm", "www", "*.js")) + \
        [os.path.join(ROOT, "realm", "classicplus", f) for f in ("bridge.js", "addons-loader.js")] + \
        glob.glob(os.path.join(ROOT, "tools", "*.mjs")) + glob.glob(os.path.join(HERE, "loadlab", "*.mjs"))
    bad = []
    for f in files:
        if not os.path.isfile(f):
            continue
        src = open(f, "rb").read()
        p = subprocess.run([node, "--check", "--input-type=module"], input=src, capture_output=True)
        if p.returncode and os.sep + "www" + os.sep in f and os.sep + "realm" + os.sep in f:
            # the page layer loads as ES modules: a CommonJS-only parse is not good enough
            bad.append(f"{rel(f)}: {p.stderr.decode(errors='replace').strip().splitlines()[0][:120]}")
        elif p.returncode:
            p2 = subprocess.run([node, "--check", f], capture_output=True)
            if p2.returncode:
                bad.append(f"{rel(f)}: {p.stderr.decode(errors='replace').strip().splitlines()[0][:120]}")
    report(f"js parses ({len(files)} files)", not bad, "; ".join(bad))


def check_shell():
    bash = tool("bash")
    if not bash or os.name == "nt":
        return skip("shell scripts parse", "no bash here (runs in CI)")
    files = glob.glob(os.path.join(ROOT, "hetzner", "*.sh")) + glob.glob(os.path.join(HERE, "**", "*.sh"), recursive=True)
    bad = [rel(f) for f in files if subprocess.run([bash, "-n", f], capture_output=True).returncode]
    report(f"shell scripts parse ({len(files)} files)", not bad, ", ".join(bad))


def check_python():
    bad, n = [], 0
    skipdirs = {"node_modules", ".git", "__pycache__", "target", "release", "build", "dist", "Data", "SPP_Server"}
    for r, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in skipdirs and not d.startswith(".")]
        for n_ in names:
            if n_.endswith(".py"):
                n += 1
                try:
                    py_compile.compile(os.path.join(r, n_), doraise=True, cfile=os.devnull if os.name != "nt" else None)
                except py_compile.PyCompileError as e:
                    bad.append(f"{rel(os.path.join(r, n_))}: {str(e).splitlines()[-1][:120]}")
                except Exception:
                    pass
    report(f"python compiles ({n} files)", not bad, "; ".join(bad))


def check_realm_up():
    p = os.path.join(ROOT, "hetzner", "openvanilla_realm_up.sh")
    if not os.path.isfile(p):
        return report("realm_up downloads every page file", False, "hetzner/openvanilla_realm_up.sh missing")
    s = open(p, encoding="utf-8").read()
    www = [os.path.basename(f) for f in glob.glob(os.path.join(ROOT, "realm", "www", "*")) if os.path.isfile(f)]
    missing = [f for f in www if f not in s]
    report(f"realm_up downloads every page file ({len(www)})", not missing, "not downloaded: " + ", ".join(missing))
    sql = re.findall(r'"\$CP/(classicplus_\w+\.sql)"', s)
    lst = re.search(r"for f in (patch-Z\.MPQ[^;]*);", s)
    listed = lst.group(1).split() if lst else []
    miss = [f for f in sql if f not in listed]
    gone = [f for f in listed if not os.path.isfile(os.path.join(ROOT, "realm", "classicplus", f))]
    report("realm_up downloads the SQL it runs, and every listed file exists", not miss and not gone,
           ("runs but never downloads: " + ", ".join(miss) + " " if miss else "") + ("missing in repo: " + ", ".join(gone) if gone else ""))


def check_version():
    try:
        ver = json.load(open(os.path.join(ROOT, "launcher", "version.json")))["version"]
    except Exception as e:
        return report("version matches the website links", False, str(e))
    html = os.path.join(ROOT, "www", "index.html")
    links = set(re.findall(r"(?:OpenVanilla|Open Vanilla)_([0-9.]+)_Win64\.zip", open(html, encoding="utf-8", errors="replace").read())) if os.path.isfile(html) else set()
    report(f"version {ver} matches the website links", links <= {ver}, f"index.html links {sorted(links)}")
    vf = os.path.join(ROOT, "VERSION")
    if os.path.isfile(vf):
        v2 = open(vf, encoding="utf-8").read().strip()
        report(f"VERSION ({v2}) matches launcher/version.json", v2 == ver, f"launcher/version.json says {ver}")


GAME_EXT = (".mpq", ".adt", ".wdt", ".wdl", ".m2", ".wmo", ".skin", ".anim", ".mmap", ".vmtile", ".vmtree")


def check_game_data():
    git = tool("git")
    if not git or not os.path.isdir(os.path.join(ROOT, ".git")):
        return skip("no game data staged for git", "not a git checkout")
    p = subprocess.run([git, "-C", ROOT, "ls-files", "--cached", "--others", "--exclude-standard"], capture_output=True, text=True)
    bad = [f for f in p.stdout.splitlines()
           if f.lower().endswith(GAME_EXT) and f.replace("\\", "/") not in OWN_MPQS
           or re.search(r"(^|/)(maps|vmaps|mmaps|dbc)/", f, re.I) and not f.startswith("devkit/db/")]
    report("no game data staged for git", not bad, ", ".join(bad[:8]))


WINDOWS_RESERVED = re.compile(r"(^|/)(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.[^/]*)?$", re.I)


def check_windows_names():
    """Windows can't create files named CON, PRN, AUX, NUL, COM1-9 or LPT1-9 (any extension)."""
    bad = []
    skip = {"node_modules", ".git", "__pycache__", "target", "release"}
    for r, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in skip]
        for n in names + dirs:
            p = rel(os.path.join(r, n))
            if WINDOWS_RESERVED.search(p):
                bad.append(p)
    report("no Windows-reserved file names", not bad, ", ".join(bad[:8]))


def main():
    for fn in (check_addons, check_patchz, check_json_yaml, check_js, check_shell, check_python,
               check_realm_up, check_version, check_game_data, check_windows_names):
        try:
            fn()
        except Exception as e:
            report(fn.__name__, False, f"check crashed: {e}")
    failed = [n for n, ok in results if ok is False]
    skipped = [n for n, ok in results if ok is None]
    print(f"\n{sum(1 for _, ok in results if ok)} passed, {len(failed)} failed, {len(skipped)} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
