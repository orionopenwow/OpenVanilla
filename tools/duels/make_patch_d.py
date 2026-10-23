"""
make_patch_d.py  (Open Vanilla / Duels)

The Duels realm's client patch: Warfront's patch-Z (realm/warfront/patch-Z.MPQ: the Classic+ addons
and art, no client tables, stock race/class pairs) plus the Duels addon (Data/Interface/AddOns/Duels)
and the Boss Fights addon (Data/Interface/AddOns/BossFights), which runs on the same world server.

    STORMLIB=/path/to/libstorm.so python3 tools/duels/make_patch_d.py
writes realm/duels/patch-Z.MPQ (served as the browser client's patch-Z on the Duels stack).
Run it again after tools/warfront/make_patch_w.py, or after a change to the Duels addon.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "devkit"))
from mpqread import MPQ  # noqa: E402

SRC = os.path.join(ROOT, "realm", "warfront", "patch-Z.MPQ")
ADDONS = ("Duels", "BossFights")     # the Modes realm's own addons, on top of Warfront's patch
OUT = os.path.join(ROOT, "realm", "duels", "patch-Z.MPQ")


def files():
    m = MPQ(SRC)
    out = {}
    prefixes = ["Interface\\AddOns\\%s\\" % a for a in ADDONS]
    for name in m.names():
        if name.startswith("(") or any(name.lower().startswith(p.lower()) for p in prefixes):
            continue
        out[name] = m.read(name)
    for addon, prefix in zip(ADDONS, prefixes):
        folder = os.path.join(ROOT, "Data", "Interface", "AddOns", addon)
        for n in sorted(os.listdir(folder)):
            if n.endswith((".lua", ".toc", ".xml")):
                with open(os.path.join(folder, n), "rb") as f:
                    out[prefix + n] = f.read()
    return out


def main():
    data = files()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="patchd-")
    try:
        try:
            import ctypes
            ctypes.CDLL(os.environ.get("STORMLIB", "libstorm.so"))
            for name, body in data.items():
                path = os.path.join(tmp, *name.split("\\"))
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    f.write(body)
            subprocess.run([sys.executable, os.path.join(ROOT, "tools", "build_mpq.py"), tmp, OUT], check=True)
        except OSError:
            # No StormLib (always the case on Windows): the model porter's pure-Python MPQ writer.
            sys.path.insert(0, os.path.join(ROOT, "tools"))
            from modelport import mpq as pympq
            pympq.write(OUT, data)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    names = MPQ(OUT).names()
    low = [n.lower() for n in names]
    assert not any(n.startswith("dbfilesclient\\") for n in low), "a DBC slipped through"
    assert "interface\\addons\\warfront\\warfront.toc" in low, "no Warfront addon"
    assert "interface\\addons\\duels\\duels.toc" in low, "no Duels addon"
    assert "interface\\addons\\bossfights\\bossfights.toc" in low, "no Boss Fights addon"
    print("%s: %d files, %d bytes" % (OUT, len(names), os.path.getsize(OUT)))


if __name__ == "__main__":
    main()
