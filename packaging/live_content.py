#!/usr/bin/env python3
"""Builds and signs the launcher's live content (downloads/live.json) from the file you edit.

    python packaging/live_content.py                       check www/downloads/live.src.json, write
                                                           www/downloads/live.json (+ .sig when the key is set)
    python packaging/live_content.py --require-signature   CI (pages.yml): fail without the key
    python packaging/live_content.py --check               only check the source file

The source (www/downloads/live.src.json) is ordinary JSON. Keys starting with "_" are notes for you and
are dropped. "serial" is set automatically (the time of the build) so launchers always prefer the newest
file; set it yourself only to force an order.

Signing uses the same key as the update manifest (packaging/release_manifest.py): the 64-hex-character
seed in the OPENVANILLA_MANIFEST_KEY environment variable, or --key-file PATH (e.g.
_local\\release-keys\\manifest_ed25519.seed). live.json.sig is the hex Ed25519 signature of live.json's
exact bytes. Launchers ignore a live.json that is unsigned, badly signed or older than the one they have.
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))
import ed25519  # noqa: E402
import importlib.util  # noqa: E402

# The launcher's own checks (launcher/live_content.py), loaded by path because this file has the same name:
# what passes here is exactly what launchers accept.
_spec = importlib.util.spec_from_file_location("launcher_live_content", os.path.join(ROOT, "launcher", "live_content.py"))
live_content = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(live_content)

SRC = os.path.join(ROOT, "www", "downloads", "live.src.json")
OUT = os.path.join(ROOT, "www", "downloads")


def strip_notes(v):
    if isinstance(v, dict):
        return {k: strip_notes(x) for k, x in v.items() if not str(k).startswith("_")}
    if isinstance(v, list):
        return [strip_notes(x) for x in v]
    return v


def build(src_doc, serial=None):
    """(body bytes, the sanitized doc, warnings). Raises ValueError for a source launchers would reject."""
    doc = strip_notes(src_doc)
    doc["schema"] = live_content.SCHEMA
    doc["serial"] = int(serial if serial is not None else doc.get("serial") or time.time())
    clean = live_content.sanitize(doc)
    warnings = []
    for key in ("hero", "news", "featured", "clients", "realms", "buttons", "links", "message"):
        if doc.get(key) and not clean.get(key):
            warnings.append(f"'{key}' was dropped entirely (check its links are https:// and titles are set)")
    for key in ("news", "featured", "clients", "realms"):
        if isinstance(doc.get(key), list) and len(clean.get(key, [])) < len(doc[key]):
            warnings.append(f"{len(doc[key]) - len(clean.get(key, []))} of {len(doc[key])} '{key}' entries were dropped")
    for k in (doc.get("flags") or {}):
        if k not in live_content.DEFAULT_FLAGS:
            warnings.append(f"unknown flag '{k}' (known: {', '.join(live_content.DEFAULT_FLAGS)})")
    for k in (doc.get("links") or {}):
        if str(k).upper() not in live_content.LINK_KEYS:
            warnings.append(f"links.{k} isn't one launchers read (allowed: {', '.join(live_content.LINK_KEYS)})")
    body = (json.dumps(clean, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    if isinstance(doc.get("clients"), list):
        for i, c in enumerate(doc["clients"]):
            if isinstance(c, dict) and live_content.sanitize_client(c) is None:
                warnings.append(f"clients #{i + 1}: needs a name and a type (exe, engine or web) and a simple id")
    return body, clean, warnings


def load_key(args):
    key = os.environ.get("OPENVANILLA_MANIFEST_KEY", "").strip()
    if not key and args.key_file and os.path.isfile(args.key_file):
        with open(args.key_file, encoding="ascii") as f:
            key = f.read().strip()
    if key and len(key) != 64:
        sys.exit("the manifest key must be 64 hex characters (the 32-byte seed)")
    return bytes.fromhex(key) if key else None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--out-dir", default=OUT)
    ap.add_argument("--serial", type=int, default=None)
    ap.add_argument("--key-file", default=os.path.join(ROOT, "_local", "release-keys", "manifest_ed25519.seed"))
    ap.add_argument("--require-signature", action="store_true")
    ap.add_argument("--check", action="store_true", help="only check the source file")
    a = ap.parse_args(argv)
    try:
        with open(a.src, encoding="utf-8") as f:
            src = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"can't read {a.src}: {e}")
    try:
        body, clean, warnings = build(src, a.serial)
    except (ValueError, TypeError) as e:
        sys.exit(f"{a.src}: {e}")
    for w in warnings:
        print(f"warning: {w}")
    if a.check:
        print(f"{a.src}: ok ({', '.join(k for k in clean if k not in ('schema', 'serial')) or 'empty'})")
        return 0
    os.makedirs(a.out_dir, exist_ok=True)
    out = os.path.join(a.out_dir, "live.json")
    with open(out, "wb") as f:
        f.write(body)
    sig_path = out + ".sig"
    key = load_key(a)
    if key:
        sig = ed25519.sign(key, body)
        with open(sig_path, "w", encoding="ascii", newline="\n") as f:
            f.write(sig.hex() + "\n")
        print(f"wrote {out} (serial {clean['serial']}) signed with key {ed25519.public_key(key).hex()[:16]}…")
    else:
        if os.path.exists(sig_path):
            os.remove(sig_path)   # a stale signature would never match the new body
        if a.require_signature:
            sys.exit("OPENVANILLA_MANIFEST_KEY is not set: refusing to publish unsigned live content")
        print(f"wrote {out} UNSIGNED (no key): launchers will ignore it until it is signed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
