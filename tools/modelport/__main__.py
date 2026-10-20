"""Command line: port a model without the app.

    python tools/modelport model.glb --name StarCourser --kind mount --title "Star-Forged Courser"
    python tools/modelport model.glb --add --speed epic
    python tools/modelport --app [model.glb ...]          the drag-and-drop app
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from modelport import content  # noqa: E402
from modelport.gltf import GltfError  # noqa: E402
from modelport.port import port  # noqa: E402


def _readb(path):
    with open(path, "rb") as f:
        return f.read()


def _writeb(path, data):
    with open(path, "wb") as f:
        f.write(data)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    ap = argparse.ArgumentParser(prog="modelport", description="glTF/GLB → Open Vanilla 1.12 model")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--app", action="store_true", help="open the drag-and-drop app")
    ap.add_argument("--name")
    ap.add_argument("--title")
    ap.add_argument("--kind", choices=["mount", "creature", "doodad"], default="mount")
    ap.add_argument("--height", type=float, help="yards (default: the model's metres)")
    ap.add_argument("--facing", choices=["+z", "-z", "+x", "-x"], default="+z")
    ap.add_argument("--texture-max", type=int, default=512)
    ap.add_argument("--max-triangles", type=int)
    ap.add_argument("--collision", choices=["mesh", "box", "none"],
                    help="what players bump into: the model's shape, its box, or nothing (default: mesh for doodads, else box)")
    ap.add_argument("--sound", choices=sorted(content.SOUND_FAMILIES))
    ap.add_argument("--anim", action="append", default=[], metavar="CLIP=ID[:SPEED]",
                    help='map a clip, e.g. --anim "Gallop=5:12" or --anim "Idle_Look=skip"')
    ap.add_argument("--out", help="also write the game files under this folder")
    ap.add_argument("--folder", help="game folder for the files (default Creature\\OpenVanilla\\<name>)")
    ap.add_argument("--preview", help="write the ported model as viewer JSON here (mesh, skeleton, animations)")
    ap.add_argument("--report", help="write what happened as JSON here (Open Vanilla Forge reads it)")
    ap.add_argument("--add", action="store_true", help="add to Open Vanilla and rebuild patch-Z.MPQ")
    ap.add_argument("--speed", choices=["normal", "epic"], default="normal", help="mount speed")
    ap.add_argument("--item-name")
    a = ap.parse_args()
    if a.app or not a.files:
        from modelport import server
        sys.argv = [sys.argv[0]] + a.files
        return server.main()
    opts = {"kind": a.kind, "facing": a.facing, "texture_max": a.texture_max}
    for k in ("name", "title", "height", "sound", "folder"):
        if getattr(a, k):
            opts[k] = getattr(a, k)
    if a.max_triangles:
        opts["max_triangles"] = a.max_triangles
    if a.collision:
        opts["collision"] = a.collision
    anims = {}
    for spec in a.anim:
        clip, _, val = spec.partition("=")
        if val == "skip":
            anims[clip] = {"skip": True}
        else:
            i, _, sp = val.partition(":")
            anims[clip] = {"id": int(i)}
            if sp:
                anims[clip]["speed"] = float(sp)
    if anims:
        opts["anims"] = anims
    code = 0
    for f in a.files:
        modern = f.lower().endswith(".m2")
        try:
            src, o, extra = f, opts, []
            if modern:  # a modern model: convert, keep its clip ids and speeds
                from modelport.server import from_modern
                src, o, extra = from_modern(f, opts)
            r = port(src, o)
            r.info[:0] = extra
        except GltfError as e:
            print(f"{f}: {e}")
            if a.report:
                with open(a.report, "w", encoding="utf-8") as rf:
                    json.dump({"ok": False, "error": str(e)}, rf)
            code = 1
            continue
        print(f"{f} → {r.meta['model_path'][:-4]}.m2")
        for w in r.warnings:
            print("  ! " + w)
        for i in r.info:
            print("  · " + i)
        for an in r.meta["animations"]:
            print(f"    {an['clip']:<24} → {an['wow']:<14} {an['seconds']:>5.2f}s  {an['speed']:>5.1f} yd/s  {'loop' if an['loop'] else 'once'}")
        if a.out:
            for arc, data in r.files.items():
                p = os.path.join(a.out, *arc.split("\\"))
                os.makedirs(os.path.dirname(p), exist_ok=True)
                _writeb(p, data)
        if a.report:
            meta = {k: v for k, v in r.meta.items() if k in ("name", "kind", "model_path", "texture_variation",
                                                             "height", "width", "animations", "triangles", "bones")}
            sound = o.get("sound") or ("horse" if r.meta["kind"] == "mount" else "humanoid")
            with open(a.report, "w", encoding="utf-8") as rf:
                json.dump({"ok": True, "source_format": "modern-m2" if modern else "gltf", "meta": meta,
                           "warnings": r.warnings, "info": r.info, "files": sorted(r.files),
                           "donors": content.SOUND_FAMILIES.get(sound, []) + content.SOUND_FAMILIES["horse"]},
                          rf, indent=1, default=lambda x: x.item() if hasattr(x, "item") else str(x))
        if a.preview:
            from modelport import m2read, names
            m2 = next(v for k, v in r.files.items() if k.lower().endswith(".m2"))
            prev = m2read.preview_json(m2)
            prev["anim_names"] = {str(x["id"]): names.anim_name(x["id"]) for x in prev["anims"]}
            with open(a.preview, "w", encoding="utf-8") as pf:
                json.dump(prev, pf, separators=(",", ":"), default=lambda x: x.item() if hasattr(x, "item") else str(x))
        if a.add:
            lib = content.Library(ROOT)
            mount = {"speed": a.speed, "item_name": a.item_name} if r.meta["kind"] == "mount" else None
            e = lib.add(r, src, o, mount=mount)
            before, after = content.update_patch(ROOT)
            print(json.dumps(e, indent=2))
            print(f"patch-Z.MPQ: {before:,} → {after:,} bytes. GM: .npc add {e['creature']}"
                  + (f"  .additem {e['mount']['item']}" if e.get("mount") else ""))
    return code


if __name__ == "__main__":
    sys.exit(main() or 0)
