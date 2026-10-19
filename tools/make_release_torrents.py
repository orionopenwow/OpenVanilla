#!/usr/bin/env python3
"""Make .torrent files (with web seeds) for Open Vanilla's own release files and add them to the signed
manifests the launcher reads.

    python3 tools/make_release_torrents.py --dir dist --base-url URL \\
        [--manifest dist/version.json] [--manifest dist/solo/solo.json] \\
        [--patchz realm/classicplus/patch-Z.MPQ --patchz-version 1.15.0] \\
        [--tracker https://play.openvanilla.app/announce] [--mirror https://mirror.example/openvanilla] \\
        [--allow-file dist/torrents.allow] [--require-signature]

For every downloadable entry in each manifest ({"url", "size", "sha256"} at the top level or under
"setup"/"zip") whose file is in --dir (or beside the manifest), this writes <file>.torrent next to it
and adds to the entry:
    "torrent": {"url", "info_hash", "name", "files": [{"path", "size", "sha256"}], "web_seeds", "trackers"}
--patchz also writes patchz.json for patch-Z.MPQ (the only MPQ that may ever be shared).

Each manifest is rewritten and re-signed: <manifest>.sig = hex Ed25519 over its exact bytes, with the
seed in OPENVANILLA_MANIFEST_KEY (as packaging/release_manifest.py). The info-hashes are appended to
--allow-file (one hex per line): the tracker on play.openvanilla.app only tracks what is in that list.

Refuses anything that looks like Blizzard game data (game file types, MPQs other than patch-Z.MPQ,
game file signatures), inside zips too. Web seeds: the entry's own URL, then each --mirror + /<file>.
"""
import argparse
import hashlib
import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "launcher"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import ed25519  # noqa: E402
from p2p import torrent as T  # noqa: E402
from build_solo_pack import FORBIDDEN_EXT, FORBIDDEN_MAGIC  # noqa: E402

PATCHZ = "patch-z.mpq"
DEFAULT_TRACKER = "https://play.openvanilla.app/announce"


class RefuseError(Exception):
    pass


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def game_data_reason(name, head):
    base = name.replace("\\", "/").split("/")[-1].lower()
    if base == PATCHZ:
        return None
    if base.endswith(FORBIDDEN_EXT):
        return f"'{os.path.splitext(base)[1]}' is a game data file type"
    if head[:4] in FORBIDDEN_MAGIC:
        return f"starts with the {head[:4]!r} game file signature"
    return None


def guard(path):
    """Raise RefuseError when path (or a zip member) looks like Blizzard data."""
    with open(path, "rb") as f:
        head = f.read(4)
    why = game_data_reason(os.path.basename(path), head)
    if why:
        raise RefuseError(f"{os.path.basename(path)}: {why}")
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                if info.is_dir():
                    continue
                with z.open(info) as m:
                    why = game_data_reason(info.filename, m.read(4))
                if why:
                    raise RefuseError(f"{os.path.basename(path)}!{info.filename}: {why}")


def torrent_entry(path, url, base_url, trackers, mirrors, out_dir):
    guard(path)
    name = os.path.basename(path)
    seeds = [url] + [m.rstrip("/") + "/" + name for m in mirrors]
    data, ih = T.make_torrent(path, trackers, seeds)
    with open(os.path.join(out_dir, name + ".torrent"), "wb") as f:
        f.write(data)
    digest = sha256(path)
    return {"url": f"{base_url}/{name}.torrent", "info_hash": ih, "name": name,
            "files": [{"path": name, "size": os.path.getsize(path), "sha256": digest}],
            "web_seeds": seeds, "trackers": list(trackers)}, digest


def write_signed(path, manifest, key, require):
    body = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    with open(path, "wb") as f:
        f.write(body)
    if key:
        with open(path + ".sig", "w", encoding="ascii", newline="\n") as f:
            f.write(ed25519.sign(bytes.fromhex(key), body).hex() + "\n")
        return True
    if require:
        raise SystemExit("OPENVANILLA_MANIFEST_KEY is not set: refusing to publish an unsigned manifest")
    if os.path.exists(path + ".sig"):
        os.remove(path + ".sig")   # the old signature no longer matches
    return False


def process_manifest(mpath, dirs, base_url, trackers, mirrors, out_dir):
    with open(mpath, encoding="utf-8") as f:
        m = json.load(f)
    hashes = []
    entries = [m] + [m[k] for k in ("setup", "zip") if isinstance(m.get(k), dict)]
    done = {}
    for e in entries:
        if not e.get("url"):
            continue
        name = os.path.basename(e["url"].split("?")[0])
        path = next((os.path.join(d, name) for d in dirs if os.path.isfile(os.path.join(d, name))), None)
        if not path:
            print(f"  skip {name}: not in {', '.join(dirs)}")
            continue
        if name not in done:
            done[name] = torrent_entry(path, e["url"], base_url, trackers, mirrors, out_dir)
        t, digest = done[name]
        if e.get("sha256") and e["sha256"].lower() != digest:
            raise RefuseError(f"{name}: the manifest's sha256 doesn't match the file")
        e["sha256"], e["size"], e["torrent"] = digest, os.path.getsize(path), t
        hashes.append(t["info_hash"])
        print(f"  {name}: info-hash {t['info_hash']}")
    return m, hashes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", required=True, help="folder holding the release files (.torrent files go here)")
    ap.add_argument("--base-url", required=True, help="where the .torrent files will be downloadable")
    ap.add_argument("--manifest", action="append", default=[])
    ap.add_argument("--patchz")
    ap.add_argument("--patchz-version", default="")
    ap.add_argument("--patchz-url", help="where patch-Z.MPQ is downloadable (default: base-url/patch-Z.MPQ)")
    ap.add_argument("--tracker", action="append", default=[])
    ap.add_argument("--mirror", action="append", default=[])
    ap.add_argument("--allow-file", help="append info-hashes here (the tracker's torrents.allow)")
    ap.add_argument("--require-signature", action="store_true")
    a = ap.parse_args(argv)
    base = a.base_url.rstrip("/")
    trackers = a.tracker or [DEFAULT_TRACKER]
    key = os.environ.get("OPENVANILLA_MANIFEST_KEY", "").strip()
    all_hashes = []
    try:
        for mp in a.manifest:
            print(f"{mp}:")
            m, hashes = process_manifest(mp, [a.dir, os.path.dirname(os.path.abspath(mp))], base, trackers,
                                         a.mirror, a.dir)
            signed = write_signed(mp, m, key, a.require_signature)
            print(f"  {'signed' if signed else 'UNSIGNED (no OPENVANILLA_MANIFEST_KEY)'}")
            all_hashes += hashes
        if a.patchz:
            if os.path.basename(a.patchz).lower() != PATCHZ:
                raise RefuseError("--patchz must be patch-Z.MPQ")
            url = a.patchz_url or f"{base}/patch-Z.MPQ"
            t, digest = torrent_entry(a.patchz, url, base, trackers, a.mirror, a.dir)
            m = {"version": a.patchz_version, "url": url, "size": os.path.getsize(a.patchz), "sha256": digest, "torrent": t}
            out = os.path.join(a.dir, "patchz.json")
            signed = write_signed(out, m, key, a.require_signature)
            print(f"patchz.json: info-hash {t['info_hash']} ({'signed' if signed else 'UNSIGNED'})")
            all_hashes.append(t["info_hash"])
    except RefuseError as e:
        print(f"Refusing: {e}")
        return 1
    if a.allow_file:
        have = set()
        if os.path.isfile(a.allow_file):
            with open(a.allow_file, encoding="ascii") as f:
                have = {l.strip().lower() for l in f if l.strip()}
        with open(a.allow_file, "a", encoding="ascii", newline="\n") as f:
            for h in all_hashes:
                if h not in have:
                    f.write(h + "\n")
                    have.add(h)
        print(f"{a.allow_file}: {len(have)} info-hashes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
