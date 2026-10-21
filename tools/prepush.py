#!/usr/bin/env python3
"""Rebuild every generated file from its sources, so a push never carries a stale one.

    python tools/prepush.py           rebuild what is out of date (dev\\Ship.bat runs this)
    python tools/prepush.py --check   only say what is out of date (exit 1 if anything is)

In order (each step reads the one before it):
  1. realm/classicplus/patch-Z.MPQ   from Data/Interface (tools/sync_patchz.py)
  2. realm/warfront/patch-Z.MPQ      Classic+ patch-Z without client tables (tools/warfront/make_patch_w.py)
  3. realm/duels/patch-Z.MPQ         Warfront's plus the Duels addon (tools/duels/make_patch_d.py)
  4. realm/www/manifests/_ui.json    the browser client's prefetch list (tools/gen_ui_manifest.py)
Steps 2 and 3 build into a temporary file and replace the real one only when a file inside differs,
so an unchanged archive is never rewritten (no empty binary changes in git).
Uses StormLib when STORMLIB points at it, else the model porter's pure-Python MPQ writer (Windows).
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "devkit"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
CHECK = "--check" in sys.argv


def say(msg):
    print("  " + msg, flush=True)


def mpq_files(path):
    from mpqread import MPQ
    if not os.path.exists(path):
        return None
    m = MPQ(path)
    return {n.lower(): m.read(n) for n in m.names() if not n.startswith("(")}


def run(*args):
    return subprocess.run([sys.executable] + list(args), cwd=ROOT)


def classicplus():
    r = run(os.path.join("tools", "sync_patchz.py"), "--check")
    if r.returncode == 0:
        say("Classic+ patch-Z: up to date")
        return False
    if CHECK:
        say("Classic+ patch-Z: OUT OF DATE")
        return True
    r = run(os.path.join("tools", "sync_patchz.py"))
    if r.returncode != 0:
        raise SystemExit("prepush: tools/sync_patchz.py failed")
    say("Classic+ patch-Z: rebuilt")
    return True


def derived(name, module, rel_out):
    """Build module.main() into a temp file; replace rel_out only if its contents differ."""
    import importlib.util
    path = os.path.join(ROOT, *module.split("/"))
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    real = os.path.join(ROOT, *rel_out.split("/"))
    tmpdir = tempfile.mkdtemp(prefix="prepush-")
    try:
        tmp = os.path.join(tmpdir, "patch-Z.MPQ")
        mod.OUT = tmp
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            mod.main()
        if mpq_files(tmp) == mpq_files(real):
            say(name + ": up to date")
            return False
        if CHECK:
            say(name + ": OUT OF DATE")
            return True
        os.makedirs(os.path.dirname(real), exist_ok=True)
        shutil.copyfile(tmp, real)
        say(name + ": rebuilt")
        return True
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def ui_manifest():
    out = os.path.join(ROOT, "realm", "www", "manifests", "_ui.json")
    before = open(out, "rb").read() if os.path.exists(out) else b""
    if CHECK:
        tmpdir = tempfile.mkdtemp(prefix="prepush-")
        try:
            shutil.copyfile(out, os.path.join(tmpdir, "keep")) if before else None
            r = run(os.path.join("tools", "gen_ui_manifest.py"))
            after = open(out, "rb").read() if os.path.exists(out) else b""
            if before:
                shutil.copyfile(os.path.join(tmpdir, "keep"), out)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
        stale = after != before
        say("UI file list: " + ("OUT OF DATE" if stale else "up to date"))
        return stale
    r = subprocess.run([sys.executable, os.path.join("tools", "gen_ui_manifest.py")], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("prepush: tools/gen_ui_manifest.py failed\n" + r.stdout + r.stderr)
    after = open(out, "rb").read()
    say("UI file list: " + ("rebuilt" if after != before else "up to date"))
    return after != before


def main():
    print("Generated files" + (" (check only)" if CHECK else "") + ":", flush=True)
    changed = [classicplus(),
               derived("Warfront patch-Z", "tools/warfront/make_patch_w.py", "realm/warfront/patch-Z.MPQ"),
               derived("Duels patch-Z", "tools/duels/make_patch_d.py", "realm/duels/patch-Z.MPQ"),
               ui_manifest()]
    if CHECK and any(changed):
        sys.exit(1)


if __name__ == "__main__":
    main()
