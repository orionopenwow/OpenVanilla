#!/usr/bin/env python3
"""Footage encoder for tools/footage/record.mjs.

    encode.py scene --dir D --out D.mp4 --shots a b c [--fps 60]
        each shot folder D/<shot>/ (JPEG frames + frames.json with Chrome's frame times) becomes
        D/<shot>.mp4 at a steady frame rate (frames held for exactly as long as Chrome showed them),
        then the shots are joined into D.mp4.
    encode.py grab --title "Window title" --secs 12 --out F.mp4 [--fps 60]
        films a desktop window by its title (Windows: gdigrab; elsewhere the whole screen).
    encode.py join --dir D --out F.mp4 --files a.mp4 b.mp4
    encode.py reel --dir RUN --out RUN/reel.mp4 [--each 2.6]
        a highlights reel of a whole run: a few seconds from the middle of every shot of every
        scene, each fading in and out, in scene order.
    encode.py prune --root _local/video/raw --keep 7
        deletes all but the newest KEEP runs (folders named by date).

H.264 (yuv420p, CRF 17, +faststart): plays everywhere and edits well. Needs ffmpeg: on PATH, or
`pip install imageio-ffmpeg` (Record_Footage.bat does that).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys


def ffmpeg():
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:  # noqa: BLE001 - say what to do instead
        sys.exit("ffmpeg is needed: install it, or run  pip install imageio-ffmpeg")


H264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]


def run(args):
    r = subprocess.run([ffmpeg(), "-hide_banner", "-loglevel", "error", "-y", *args])
    if r.returncode:
        sys.exit(f"ffmpeg failed ({r.returncode})")


def encode_shot(folder, out, fps):
    meta = json.load(open(os.path.join(folder, "frames.json"), encoding="utf-8"))
    frames = meta["frames"]
    if not frames:
        print(f"  {os.path.basename(folder)}: no frames")
        return False
    lst = os.path.join(folder, "frames.txt")
    with open(lst, "w", encoding="utf-8") as f:
        for i, (name, t) in enumerate(frames):
            nxt = frames[i + 1][1] if i + 1 < len(frames) else max(meta.get("end", t), t + 1 / fps)
            f.write(f"file '{name}'\nduration {max(nxt - t, 0.001):.4f}\n")
        f.write(f"file '{frames[-1][0]}'\n")       # the concat demuxer needs the last file twice
    w, h = meta.get("w", 1920), meta.get("h", 1080)
    vf = f"scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,fps={fps}"
    run(["-f", "concat", "-safe", "0", "-i", lst, "-vf", vf, "-r", str(fps), *H264, out])
    return True


def join(files, out, fps):
    files = [f for f in files if os.path.exists(f)]
    if not files:
        return False
    if len(files) == 1:
        shutil.copyfile(files[0], out)
        return True
    lst = out + ".txt"
    with open(lst, "w", encoding="utf-8") as f:
        for p in files:
            f.write("file '" + os.path.abspath(p).replace("'", "'\\''") + "'\n")
    run(["-f", "concat", "-safe", "0", "-i", lst, "-r", str(fps), *H264, out])
    os.remove(lst)
    return True


def grab(title, secs, out, fps):
    if sys.platform == "win32":
        src = ["-f", "gdigrab", "-framerate", str(fps), "-draw_mouse", "1", "-i", f"title={title}"]
    elif sys.platform == "darwin":
        src = ["-f", "avfoundation", "-framerate", str(fps), "-i", "1:none"]
    else:
        src = ["-f", "x11grab", "-framerate", str(fps), "-i", os.environ.get("DISPLAY", ":0")]
    # even width/height for H.264
    run([*src, "-t", str(secs), "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", *H264, out])
    return os.path.exists(out)


def duration(path):
    exe = ffmpeg()
    probe = os.path.join(os.path.dirname(exe), "ffprobe" + (".exe" if exe.endswith(".exe") else ""))
    if os.path.exists(probe):
        r = subprocess.run([probe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path], capture_output=True, text=True)
        try:
            return float(r.stdout.strip())
        except ValueError:
            pass
    r = subprocess.run([exe, "-hide_banner", "-i", path], capture_output=True, text=True)   # ffmpeg alone: read "Duration:"
    import re
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", r.stderr)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else 0.0


ORDER = ["site-home", "game-start", "game-world", "agents-demo", "site-forge", "forge", "launcher", "site-agents", "site-herald", "site-workshop", "site-host"]


def reel(run_dir, out, each, fps):
    take = os.path.join(run_dir, "take.json")
    scenes = json.load(open(take, encoding="utf-8")).get("done", []) if os.path.exists(take) else []
    scenes.sort(key=lambda n: ORDER.index(n) if n in ORDER else len(ORDER))
    parts, tmp = [], os.path.join(run_dir, "_reel")
    os.makedirs(tmp, exist_ok=True)
    for scene in scenes:
        folder = os.path.join(run_dir, scene)
        if not os.path.isdir(folder):
            continue
        shots = [f for f in os.listdir(folder) if f.endswith(".mp4")]
        for shot in sorted(shots, key=lambda f: os.path.getmtime(os.path.join(folder, f))):   # in the order they were filmed
            src = os.path.join(folder, shot)
            d = duration(src)
            if d < 1.5:
                continue
            length = min(each, d - 0.2)
            start = max(0.0, d * 0.45 - length / 2)
            part = os.path.join(tmp, f"{len(parts):03d}.mp4")
            fade = f"fade=t=in:st=0:d=0.25,fade=t=out:st={length - 0.25:.2f}:d=0.25"
            run(["-ss", f"{start:.2f}", "-t", f"{length:.2f}", "-i", src, "-vf", fade, "-r", str(fps), "-an", *H264, part])
            parts.append(part)
    if not parts:
        print("  reel: no shots")
        return False
    join(parts, out, fps)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"  reel: {len(parts)} shots -> {out}")
    return True


def prune(root, keep):
    runs = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)) and d[:4].isdigit() and "_" in d)
    for d in runs[:-keep] if keep > 0 else []:
        shutil.rmtree(os.path.join(root, d), ignore_errors=True)
        print(f"  pruned {d}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scene"); s.add_argument("--dir", required=True); s.add_argument("--out", required=True)
    s.add_argument("--shots", nargs="+", required=True); s.add_argument("--fps", type=int, default=60)
    g = sub.add_parser("grab"); g.add_argument("--title", required=True); g.add_argument("--secs", type=float, default=10)
    g.add_argument("--out", required=True); g.add_argument("--fps", type=int, default=60)
    j = sub.add_parser("join"); j.add_argument("--dir", required=True); j.add_argument("--out", required=True)
    j.add_argument("--files", nargs="+", required=True); j.add_argument("--fps", type=int, default=60)
    r = sub.add_parser("reel"); r.add_argument("--dir", required=True); r.add_argument("--out", required=True)
    r.add_argument("--each", type=float, default=2.6); r.add_argument("--fps", type=int, default=60)
    p = sub.add_parser("prune"); p.add_argument("--root", required=True); p.add_argument("--keep", type=int, default=7)
    a = ap.parse_args(argv)
    if a.cmd == "scene":
        made = []
        for shot in a.shots:
            folder = os.path.join(a.dir, shot)
            out = os.path.join(a.dir, shot + ".mp4")
            if encode_shot(folder, out, a.fps):
                made.append(out)
                for f in os.listdir(folder):            # the frames have done their job
                    if f.endswith(".jpg"):
                        os.remove(os.path.join(folder, f))
        if join(made, a.out, a.fps):
            print(f"  -> {a.out}")
        return 0 if made else 1
    if a.cmd == "grab":
        return 0 if grab(a.title, a.secs, a.out, a.fps) else 1
    if a.cmd == "join":
        return 0 if join([os.path.join(a.dir, f) for f in a.files], a.out, a.fps) else 1
    if a.cmd == "reel":
        return 0 if reel(a.dir, a.out, a.each, a.fps) else 1
    if a.cmd == "prune":
        prune(a.root, a.keep)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
