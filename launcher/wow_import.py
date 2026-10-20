"""First-run WoW data import for the Open Vanilla launcher.

Finds the player's own 1.12.1 install, checks it has every archive benilla
mounts, remembers it, and hands back the env benilla reads (WOW_DATA).
benilla reads the archives in place, so nothing is copied.

Use from a launcher:
    from wow_import import ensure_wow_data, launch_env
    data = ensure_wow_data(root)          # root = your Tk window, or None
    if data: subprocess.Popen([...benilla...], env=launch_env(data))
"""

import json
import os
import sys
from pathlib import Path

# The ten base archives plus patch.MPQ: benilla's Chain::open errors if a listed one is broken.
REQUIRED = [
    "dbc.MPQ", "speech.MPQ", "fonts.MPQ", "interface.MPQ", "misc.MPQ",
    "sound.MPQ", "wmo.MPQ", "terrain.MPQ", "texture.MPQ", "model.MPQ", "patch.MPQ",
]
BUILD = 5875
CONFIG = Path(__file__).with_name("wow_data.json")
GUESSES = [
    r"C:\Program Files (x86)\World of Warcraft",
    r"C:\Program Files\World of Warcraft",
    r"C:\World of Warcraft",
    r"C:\WoW",
    r"C:\Games\World of Warcraft",
    str(Path.home() / "Games" / "World of Warcraft"),
]


def data_dir(picked):
    """The Data folder for a picked WoW folder or Data folder, else None."""
    p = Path(picked)
    for cand in (p, p / "Data"):
        if cand.is_dir() and any(c.name.lower() == "dbc.mpq" for c in cand.iterdir()):
            return cand
    return None


def problems(data):
    """Human-readable reasons this Data folder won't work; empty means it's good."""
    names = {c.name.lower(): c for c in data.iterdir() if c.is_file()}
    out = []
    for want in REQUIRED:
        f = names.get(want.lower())
        if f is None:
            out.append(f"Missing {want}")
        else:
            with open(f, "rb") as fh:
                if fh.read(4) != b"MPQ\x1a":
                    out.append(f"{want} is damaged (not an MPQ archive)")
    build = exe_build(data.parent)
    if build is not None and build != BUILD:
        out.append(f"This is build {build}; Open Vanilla needs Vanilla Client v1.3 (build {BUILD})")
    return out


def exe_build(wow_dir):
    """WoW.exe's build number, or None when there's no exe or we're not on Windows."""
    exe = next((c for c in Path(wow_dir).glob("*") if c.name.lower() == "wow.exe"), None)
    if exe is None or sys.platform != "win32":
        return None
    import ctypes
    ver = ctypes.windll.version
    size = ver.GetFileVersionInfoSizeW(str(exe), None)
    if not size:
        return None
    buf = ctypes.create_string_buffer(size)
    ver.GetFileVersionInfoW(str(exe), 0, size, buf)
    ptr, n = ctypes.c_void_p(), ctypes.c_uint()
    if not ver.VerQueryValueW(buf, "\\", ctypes.byref(ptr), ctypes.byref(n)):
        return None
    # VS_FIXEDFILEINFO: dwFileVersionLS is the 4th DWORD; its low word is the build.
    return ctypes.cast(ptr, ctypes.POINTER(ctypes.c_uint32))[3] & 0xFFFF


def saved():
    try:
        p = data_dir(json.loads(CONFIG.read_text())["data"])
        return p if p and not problems(p) else None
    except (OSError, ValueError, KeyError):
        return None


def save(data):
    CONFIG.write_text(json.dumps({"data": str(data)}))


def autodetect():
    for g in GUESSES:
        p = data_dir(g) if Path(g).is_dir() else None
        if p and not problems(p):
            return p
    return None


def ensure_wow_data(parent=None):
    """Saved install, else auto-detected, else ask the player. Returns the Data path or None."""
    found = saved() or autodetect()
    if found:
        save(found)
        return found
    from tkinter import filedialog, messagebox
    messagebox.showinfo(
        "Find your game folder",
        "Open Vanilla uses the game files from your own Vanilla Client v1.3 install.\n\n"
        "Pick your Vanilla game folder (the one with WoW.exe or the Data folder). "
        "You only need to do this once.",
        parent=parent,
    )
    while True:
        picked = filedialog.askdirectory(title="Select your Vanilla game folder", parent=parent)
        if not picked:
            return None
        data = data_dir(picked)
        issues = ["No Data folder with game archives found here."] if data is None else problems(data)
        if not issues:
            save(data)
            return data
        if not messagebox.askretrycancel(
            "That folder won't work", "\n".join(issues) + "\n\nPick a different folder?", parent=parent
        ):
            return None


def launch_env(data):
    return {**os.environ, "WOW_DATA": str(data)}


def _self_check():
    import tempfile
    with tempfile.TemporaryDirectory() as t:
        wow = Path(t)
        (wow / "Data").mkdir()
        for name in REQUIRED:
            (wow / "Data" / name.lower()).write_bytes(b"MPQ\x1a" + b"\0" * 28)  # case-insensitive
        assert data_dir(wow) == wow / "Data"
        assert data_dir(wow / "Data") == wow / "Data"
        assert data_dir(wow / "nope") is None
        assert problems(wow / "Data") == []
        (wow / "Data" / "sound.mpq").write_bytes(b"junk")
        (wow / "Data" / "model.mpq").unlink()
        assert problems(wow / "Data") == [
            "sound.MPQ is damaged (not an MPQ archive)", "Missing model.MPQ"
        ]
    print("ok")


if __name__ == "__main__":
    if "--check" in sys.argv:
        _self_check()
    else:
        print(ensure_wow_data() or "No WoW folder chosen.")
