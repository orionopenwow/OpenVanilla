#!/usr/bin/env python3
"""Writes a release's checksums and its signed update manifest (CI runs this; see release.yml).

    python packaging/release_manifest.py --version 1.15.0 --dir dist --base-url URL [--require-signature]

Reads every file in --dir and writes, into the same folder:
  SHA256SUMS          "<sha256>  <name>" per file (sha256sum -c compatible)
  version.json        what launchers read: the version, the setup (and zip) URL, size and sha256
  version.json.sig    hex Ed25519 signature of version.json's exact bytes, made with the secret in
                      OPENVANILLA_MANIFEST_KEY (64 hex characters, the 32-byte seed). The launcher only
                      offers an update whose manifest verifies against the public key built into it.
"""
import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "launcher"))
import ed25519  # noqa: E402  (standard-library Ed25519, shared with the launcher)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", required=True)
    ap.add_argument("--dir", required=True, help="folder holding the release files")
    ap.add_argument("--base-url", required=True, help="where the files will be downloadable (no trailing /)")
    ap.add_argument("--notes-url", default="https://openvanilla.app/downloads/patch_notes.json")
    ap.add_argument("--require-signature", action="store_true", help="fail when OPENVANILLA_MANIFEST_KEY is missing")
    a = ap.parse_args()

    names = sorted(n for n in os.listdir(a.dir) if os.path.isfile(os.path.join(a.dir, n))
                   and n not in ("SHA256SUMS", "version.json", "version.json.sig"))
    if not names:
        sys.exit(f"no release files in {a.dir}")
    files = {n: {"size": os.path.getsize(os.path.join(a.dir, n)), "sha256": sha256(os.path.join(a.dir, n))}
             for n in names}
    with open(os.path.join(a.dir, "SHA256SUMS"), "w", encoding="utf-8", newline="\n") as f:
        for n in names:
            f.write(f"{files[n]['sha256']}  {n}\n")

    def entry(n):
        return {"url": f"{a.base_url}/{n}", "size": files[n]["size"], "sha256": files[n]["sha256"]} if n else None

    setup = next((n for n in names if n.lower().endswith(".exe") and "setup" in n.lower()), None)
    zipf = next((n for n in names if n.lower().endswith(".zip") and "_win64" in n.lower()), None)
    main_file = setup or zipf
    if not main_file:
        sys.exit("no setup .exe or client .zip to point launchers at")
    manifest = {"version": a.version, **entry(main_file), "patch_notes_url": a.notes_url}
    if setup:
        manifest["setup"] = entry(setup)
    if zipf:
        manifest["zip"] = entry(zipf)
    body = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    with open(os.path.join(a.dir, "version.json"), "wb") as f:
        f.write(body)

    key = os.environ.get("OPENVANILLA_MANIFEST_KEY", "").strip()
    if key:
        sig = ed25519.sign(bytes.fromhex(key), body)
        with open(os.path.join(a.dir, "version.json.sig"), "w", encoding="ascii", newline="\n") as f:
            f.write(sig.hex() + "\n")
        print(f"signed version.json with key {ed25519.public_key(bytes.fromhex(key)).hex()[:16]}…")
    elif a.require_signature:
        sys.exit("OPENVANILLA_MANIFEST_KEY is not set: refusing to publish an unsigned manifest")
    else:
        print("note: no OPENVANILLA_MANIFEST_KEY, version.json is unsigned (launchers with a key will not offer it)")
    for n in names:
        print(f"  {files[n]['sha256']}  {n}  ({files[n]['size'] / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
