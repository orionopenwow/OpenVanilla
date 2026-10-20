#!/usr/bin/env python3
"""Footage encoder for tools/footage/record.mjs.

    encode.py scene --dir D --out D.mp4 --shots a b c [--fps 60]
        each shot folder D/<shot>/ (JPEG frames + frames.json with Chrome's frame times) becomes
        D/<shot>.mp4 at a steady frame rate (frames held for exactly as long as Chrome showed them),
        then the shots are joined into D.mp4.
    encode.py grab --title "Window title" --secs 12 --out F.mp4 [--fps 60]
        films a desktop window by its title (Windows: gdigrab; elsewhere the whole screen).
    encode.py join --dir D --out F.mp4 --files a.mp4 b.mp4

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


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scene"); s.add_argument("--dir", required=True); s.add_argument("--out", required=True)
    s.add_argument("--shots", nargs="+", required=True); s.add_argument("--fps", type=int, default=60)
    g = sub.add_parser("grab"); g.add_argument("--title", required=True); g.add_argument("--secs", type=float, default=10)
    g.add_argument("--out", required=True); g.add_argument("--fps", type=int, default=60)
    j = sub.add_parser("join"); j.add_argument("--dir", required=True); j.add_argument("--out", required=True)
    j.add_argument("--files", nargs="+", required=True); j.add_argument("--fps", type=int, default=60)
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
    return 2


if __name__ == "__main__":
    sys.exit(main())
