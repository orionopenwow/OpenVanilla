#!/usr/bin/env python3
"""Rebuild realm/classicplus/patch-Z.MPQ so it matches the source folders exactly.

    STORMLIB=/path/to/libstorm.so python3 tools/sync_patchz.py          rebuild
    STORMLIB=/path/to/libstorm.so python3 tools/sync_patchz.py --check  only report differences

Sources of truth:
  Data/Interface/AddOns/<suite addon>/**   every folder whose .toc has "## X-ClassicPlus"
                                           (plus !Compat_112), as Interface\\AddOns\\...
  Data/Interface/ClassicPlus/*.blp         as Interface\\ClassicPlus\\...
  Data/Interface/ClassicPlus/LoadingScreens/*.blp   Open Vanilla's loading screens, as
                                           Interface\\Glues\\LoadingScreens\\... (tools/png_to_blp_dxt1.py)
  Data/Creature/OpenVanilla/**                 ported models (tools/modelport), as Creature\\OpenVanilla\\...
  Data/ClassicPlusDBC/{CreatureModelData,CreatureDisplayInfo,Spell}.dbc   their table rows
Everything else already in the archive (DBFilesClient\\*.dbc, Interface\\Glues\\...) is kept as is.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MPQ = os.path.join(ROOT, "realm", "classicplus", "patch-Z.MPQ")
ADDONS = os.path.join(ROOT, "Data", "Interface", "AddOns")
CPART = os.path.join(ROOT, "Data", "Interface", "ClassicPlus")
TOOLS = os.path.join(ROOT, "tools")


# Text files go in with plain LF line endings, whatever the checkout used: on Windows git hands out
# CRLF (core.autocrlf), on Linux (CI) LF, and the archive must not depend on which one built it.
TEXT_EXT = (".toc", ".lua", ".xml", ".txt", ".md", ".json")


def source_bytes(path):
    data = open(path, "rb").read()
    return data.replace(b"\r\n", b"\n") if path.lower().endswith(TEXT_EXT) else data


def suite_folders():
    out = []
    for d in sorted(os.listdir(ADDONS)):
        toc = os.path.join(ADDONS, d, d + ".toc")
        if not os.path.isfile(toc):
            continue
        txt = open(toc, encoding="utf-8", errors="replace").read()
        if "## X-ClassicPlus" in txt or d.startswith("!Compat"):
            out.append(d)
    return out


# Only what the game loads: backups ("Plates.lua.before-pill", "*.bak", "*~") and editor
# litter stay out of the patch.
SHIPPED_EXT = (".lua", ".toc", ".xml", ".blp", ".tga", ".ttf", ".wav", ".mp3", ".ogg", ".txt", ".m2", ".skin")


def shipped(name):
    low = name.lower()
    return low.endswith(SHIPPED_EXT) and not low.startswith(".")


def wanted():
    """archive path (lower-case key) -> (archive path, source file)"""
    w = {}
    for d in suite_folders():
        base = os.path.join(ADDONS, d)
        for r, _, names in os.walk(base):
            for n in names:
                if not shipped(n):
                    continue
                full = os.path.join(r, n)
                arc = "Interface\\AddOns\\" + os.path.relpath(full, ADDONS).replace(os.sep, "\\")
                w[arc.lower()] = (arc, full)
    sys.path.insert(0, TOOLS)
    from modelport import content
    w.update(content.patch_files(ROOT))
    for n in sorted(os.listdir(CPART)):
        if n.lower().endswith(".blp"):
            arc = "Interface\\ClassicPlus\\" + n
            w[arc.lower()] = (arc, os.path.join(CPART, n))
    screens = os.path.join(CPART, "LoadingScreens")
    if os.path.isdir(screens):
        for n in sorted(os.listdir(screens)):
            if n.lower().endswith(".blp"):
                arc = "Interface\\Glues\\LoadingScreens\\" + n
                w[arc.lower()] = (arc, os.path.join(screens, n))
    return w


def main():
    check = "--check" in sys.argv
    sys.path.insert(0, TOOLS)
    from modelport import content
    try:
        import ctypes
        ctypes.CDLL(os.environ.get("STORMLIB", "libstorm.so"))
    except OSError:
        # No StormLib (always the case on Windows): the porter's pure-Python MPQ does the same job.
        return pure_python(check)
    tmp = tempfile.mkdtemp(prefix="patchz-")
    try:
        src = os.path.join(tmp, "src")
        subprocess.run([sys.executable, os.path.join(TOOLS, "mpq_extract.py"), MPQ, src],
                       check=True, stdout=subprocess.DEVNULL)
        have = {}
        for r, _, names in os.walk(src):
            for n in names:
                full = os.path.join(r, n)
                arc = os.path.relpath(full, src).replace(os.sep, "\\")
                have[arc.lower()] = (arc, full)
        w = wanted()
        changes = []
        for k, (arc, full) in sorted(w.items()):
            if k not in have:
                changes.append(("add", arc))
            elif source_bytes(full) != open(have[k][1], "rb").read():
                changes.append(("update", arc))
        for k, (arc, full) in sorted(have.items()):
            managed = (k.startswith("interface\\addons\\") or k.startswith("interface\\classicplus\\")
                       or content.is_model_managed(k))
            if managed and k not in w:
                changes.append(("remove", arc))
        for c in changes:
            print(f"  {c[0]:7} {c[1]}")
        if not changes:
            print("patch-Z.MPQ matches Data/Interface (nothing to do)")
            return 0
        if check:
            print(f"{len(changes)} difference(s); run without --check to rebuild")
            return 1
        for kind, arc in changes:
            path = os.path.join(src, arc.replace("\\", os.sep))
            if kind == "remove":
                os.remove(path)
            else:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as fh:
                    fh.write(source_bytes(w[arc.lower()][1]))
        out = os.path.join(tmp, "patch-Z.MPQ")
        subprocess.run([sys.executable, os.path.join(TOOLS, "build_mpq.py"), src, out],
                       check=True, stdout=subprocess.DEVNULL)
        shutil.copyfile(out, MPQ)
        print(f"patch-Z.MPQ rebuilt: {len(changes)} change(s), {os.path.getsize(MPQ)} bytes")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def pure_python(check):
    from modelport import content, mpq
    a = mpq.Archive(MPQ)
    have = {n.lower(): n for n in a.names()}
    w = wanted()
    files = {}
    changes = []
    for k, n in have.items():
        managed = (k.startswith("interface\\addons\\") or k.startswith("interface\\classicplus\\")
                   or k.startswith("interface\\glues\\loadingscreens\\") or content.is_model_managed(k))
        if managed and k not in w:
            changes.append(("remove", n))
            continue
        files[n] = a.read(n)
    for k, (arc, full) in sorted(w.items()):
        data = source_bytes(full)
        if k not in have:
            changes.append(("add", arc))
        elif files.get(have[k]) != data:
            changes.append(("update", arc))
        files.pop(have.get(k, arc), None)
        files[arc] = data
    for c in changes:
        print(f"  {c[0]:7} {c[1]}")
    if not changes:
        print("patch-Z.MPQ matches the source folders (nothing to do)")
        return 0
    if check:
        print(f"{len(changes)} difference(s); run without --check to rebuild")
        return 1
    size = mpq.write(MPQ, files)
    print(f"patch-Z.MPQ rebuilt: {len(changes)} change(s), {size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
