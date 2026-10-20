"""
make_patch_w.py  (Open Vanilla / Warfront)

Warfront's client patch: patch-Z (the Classic+ addons and art) without its DBFilesClient tables,
so the character screen offers only the stock 1.12.1 race/class pairs and everything else in the
client is stock data. Warfront's world server runs a stock world database.

    STORMLIB=/path/to/libstorm.so python3 tools/warfront/make_patch_w.py
writes realm/warfront/patch-Z.MPQ (served as the browser client's patch-Z on the Warfront stack).
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "devkit"))
from mpqread import MPQ  # noqa: E402

SRC = os.path.join(ROOT, "realm", "classicplus", "patch-Z.MPQ")
OUT = os.path.join(ROOT, "realm", "warfront", "patch-Z.MPQ")


def main():
    m = MPQ(SRC)
    tmp = tempfile.mkdtemp(prefix="patchw-")
    kept = dropped = 0
    try:
        for name in m.names():
            if name.lower().startswith("dbfilesclient\\") or name.startswith("("):
                dropped += 1
                continue
            path = os.path.join(tmp, *name.split("\\"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(m.read(name))
            kept += 1
        try:
            import ctypes
            ctypes.CDLL(os.environ.get("STORMLIB", "libstorm.so"))
            subprocess.run([sys.executable, os.path.join(ROOT, "tools", "build_mpq.py"), tmp, OUT], check=True)
        except OSError:
            # No StormLib (always the case on Windows): the model porter's pure-Python MPQ writer.
            sys.path.insert(0, os.path.join(ROOT, "tools"))
            from modelport import mpq as pympq
            files = {}
            for name in m.names():
                if name.lower().startswith("dbfilesclient\\") or name.startswith("("):
                    continue
                files[name] = m.read(name)
            pympq.write(OUT, files)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    check = MPQ(OUT)
    names = check.names()
    assert not any(n.lower().startswith("dbfilesclient\\") for n in names), "a DBC slipped through"
    assert any(n.lower() == "interface\\addons\\warfront\\warfront.toc" for n in names), "no Warfront addon"
    print("%s: %d files (dropped %d DBFilesClient tables), %d bytes" % (OUT, kept, dropped, os.path.getsize(OUT)))


if __name__ == "__main__":
    main()
