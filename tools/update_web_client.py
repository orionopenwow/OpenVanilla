"""Bring the PC's browser client (www/wenilla_bg.wasm + www/wenilla.js) up to the realm's build.

The realm image is built with Open Vanilla's engine patches (realm/patches: login backdrop, the
nine-class character-create grid, ...). The realm-image workflow publishes that same client as
the GitHub release "web-client"; this downloads it into www/, so local play matches the realm.

    python tools/update_web_client.py            # download and install
    python tools/update_web_client.py --check    # only say whether an update is available

The previous files are kept in www/.web-client-prev/ (copy them back to undo).
"""
import argparse
import gzip
import hashlib
import json
import os
import shutil
import sys
import urllib.request

REPO = os.environ.get("OPENVANILLA_REPO", "orionopenwow/OpenVanilla")
BASE = f"https://github.com/{REPO}/releases/download/web-client/"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WWW = os.path.join(ROOT, "www")
FILES = ["wenilla_bg.wasm.gz", "wenilla.js"]
STAMP = os.path.join(WWW, ".web-client-revision")


def get(name):
    with urllib.request.urlopen(BASE + name, timeout=60) as r:
        return r.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    rev = get("REVISION").decode().strip()
    have = open(STAMP).read().strip() if os.path.exists(STAMP) else None
    if have == rev:
        print(f"Browser client is current ({rev[:10]}).")
        return 0
    print(f"Update available: {have[:10] if have else 'unknown'} -> {rev[:10]}")
    if a.check:
        return 1

    sums = {}
    for line in get("SHA256SUMS").decode().splitlines():
        h, _, name = line.partition("  ")
        sums[name.strip()] = h
    blobs = {}
    for name in FILES:
        print(f"  downloading {name} ...", flush=True)
        data = get(name)
        if sums.get(name) and hashlib.sha256(data).hexdigest() != sums[name]:
            sys.exit(f"{name}: checksum mismatch, nothing installed")
        blobs[name] = data
    wasm = gzip.decompress(blobs["wenilla_bg.wasm.gz"])
    if sums.get("wenilla_bg.wasm") and hashlib.sha256(wasm).hexdigest() != sums["wenilla_bg.wasm"]:
        sys.exit("wenilla_bg.wasm: checksum mismatch, nothing installed")

    prev = os.path.join(WWW, ".web-client-prev")
    os.makedirs(prev, exist_ok=True)
    out = {
        "wenilla_bg.wasm": wasm,
        "wenilla_bg.wasm.gz": blobs["wenilla_bg.wasm.gz"],
        "wenilla.js": blobs["wenilla.js"],
        "wenilla.js.gz": gzip.compress(blobs["wenilla.js"], 9),
    }
    try:
        import brotli  # optional: pip install brotli
        out["wenilla_bg.wasm.br"] = brotli.compress(wasm, quality=9)
        out["wenilla.js.br"] = brotli.compress(blobs["wenilla.js"], quality=11)
    except ImportError:
        pass
    # Old compressed copies would be served instead of the new file, so they go too.
    for name in ["wenilla_bg.wasm", "wenilla_bg.wasm.gz", "wenilla_bg.wasm.br", "wenilla.js", "wenilla.js.gz", "wenilla.js.br"]:
        p = os.path.join(WWW, name)
        if os.path.exists(p):
            shutil.move(p, os.path.join(prev, name))
    for name, data in out.items():
        with open(os.path.join(WWW, name) + ".tmp", "wb") as f:
            f.write(data)
        os.replace(os.path.join(WWW, name) + ".tmp", os.path.join(WWW, name))
    with open(STAMP, "w") as f:
        f.write(rev + "\n")
    print(f"Installed browser client {rev[:10]} ({len(wasm) / 1e6:.0f} MB). Previous copy: www/.web-client-prev/")
    print(json.dumps({"revision": rev, "files": sorted(out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
