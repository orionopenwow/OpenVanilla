"""Background updates: stage the new release while the player keeps using the launcher, then
"Update ready - restart to update" hands off to a small step that runs after the launcher exits.

    pick_asset(manifest, mode)          which file of a signed version.json this install takes
    stage(manifest, layout, ...)        download + check SHA-256 (the signed manifest carries it);
                                        a zip is also unpacked into Cache\\Updates\\<v>\\staged
    ready(layout, current_version)      a staged update that is still intact, or None
    handoff(info, layout, ...)          start the step that finishes the update; the launcher then exits
    apply_staged(staged, target, ...)   (zip build) swap program files in, never user data
    main_apply(argv)                    `OpenVanilla.exe --apply-update <staged> --target <dir> --wait-pid <pid>`

Installer build: handoff runs the new OpenVanilla-Setup-<v>.exe /VERYSILENT /SUPPRESSMSGBOXES
/CLOSEAPPLICATIONS /NORESTART /RELAUNCH (OpenVanilla.iss starts OpenVanilla.exe again after a /RELAUNCH run).
Zip build: handoff runs the staged copy of the NEW OpenVanilla.exe from the staging folder with
--apply-update; it waits for this launcher to exit, swaps the program files and starts the
installed OpenVanilla.exe. The signature check stays where it was: openvanilla_launcher.signed_manifest()
only returns a manifest whose version.json.sig verifies, and that manifest's SHA-256 is checked
here before anything is staged and again right before it is used.

Standard library only; Python 3.10 compatible.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse

import fetch
import layout as L

STATE_FILE = "ready.json"
# Program files an update replaces. Everything else in the folder (AddOns, Realms, Screenshots, Logs,
# Backups, Settings, Cache, Game\benilla-config, links.txt) belongs to the player and is never touched.
PROGRAM_ITEMS = (L.LAUNCHER_EXE, L.OLD_LAUNCHER_EXE, "app", "Server", "LICENSES", "README.txt")
GAME_KEEP = (L.ENGINE_CONFIG,)
FIRST_INSTALL_ONLY = ("links.txt",)
SETUP_ARGS = ("/VERYSILENT", "/SUPPRESSMSGBOXES", "/CLOSEAPPLICATIONS", "/NORESTART", "/RELAUNCH")
DETACHED = 0x00000008 | 0x00000200   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP


def launcher_in(folder):
    """The launcher exe in a release or install folder: OpenVanilla.exe, else the pre-rename OpenWoW.exe."""
    for name in L.LAUNCHER_EXES:
        p = os.path.join(folder or "", name)
        if os.path.isfile(p):
            return p
    return None


class UpdateError(Exception):
    pass


def version_tuple(v):
    out = []
    for part in str(v).split("."):
        digits = "".join(ch for ch in part if ch.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out)


def newer(candidate, current):
    return version_tuple(candidate) > version_tuple(current)


def pick_asset(manifest, mode):
    """(kind, entry) for this install: the setup exe for an installed copy, the zip for a portable one.
    None when the manifest has nothing this install can apply by itself (a run from source)."""
    if not isinstance(manifest, dict):
        return None
    if mode == "installed" and isinstance(manifest.get("setup"), dict):
        return "setup", manifest["setup"]
    if mode in ("portable", "custom") and isinstance(manifest.get("zip"), dict):
        return "zip", manifest["zip"]
    url = str(manifest.get("url") or "")
    if mode in ("portable", "custom") and url.lower().endswith(".zip"):
        return "zip", {k: manifest.get(k) for k in ("url", "size", "sha256")}
    if mode == "installed" and url.lower().endswith(".exe"):
        return "setup", {k: manifest.get(k) for k in ("url", "size", "sha256")}
    return None


def _vdir(lay, version):
    safe = "".join(ch for ch in str(version) if ch.isalnum() or ch in ".-_") or "next"
    return os.path.join(lay.updates, safe)


def stage(manifest, lay, mode=None, progress=None, cancel=None, opener=None):
    """Download and check the update for this install. Returns the ready info dict (also saved)."""
    mode = mode or lay.mode
    pick = pick_asset(manifest, mode)
    if not pick:
        raise UpdateError("This copy of Open Vanilla can't update itself (run from source). Download the new version instead.")
    kind, entry = pick
    url, sha = entry.get("url"), (entry.get("sha256") or "").lower()
    if not url or len(sha) != 64:
        raise UpdateError("The update manifest has no checksum for this download, so it isn't used.")
    version = str(manifest.get("version", ""))
    vdir = _vdir(lay, version)
    name = os.path.basename(urllib.parse.urlsplit(url).path) or (f"OpenVanilla-Setup-{version}.exe" if kind == "setup"
                                                                   else f"OpenVanilla_{version}_Win64.zip")
    path = os.path.join(vdir, name)
    fetch.download(url, path, sha256=sha, size=entry.get("size"), progress=progress, cancel=cancel, opener=opener)
    info = {"version": version, "kind": kind, "file": path, "sha256": sha, "staged": None}
    if kind == "zip":
        staged = os.path.join(vdir, "staged")
        if os.path.isdir(staged):
            shutil.rmtree(staged)
        fetch.safe_extract(path, staged, strip_top=True, cancel=cancel)
        if not launcher_in(staged):
            shutil.rmtree(staged, ignore_errors=True)
            raise UpdateError(f"The update has no {L.LAUNCHER_EXE}; it was not applied.")
        info["staged"] = staged
    L.write_json(os.path.join(vdir, STATE_FILE), info)
    return info


def ready(lay, current_version, verify=True):
    """The newest staged update that is newer than current_version and still matches its checksum."""
    best = None
    try:
        names = os.listdir(lay.updates)
    except OSError:
        return None
    for n in names:
        info = L.read_json(os.path.join(lay.updates, n, STATE_FILE))
        if not isinstance(info, dict) or not newer(info.get("version", "0"), current_version):
            continue
        if not os.path.isfile(info.get("file") or ""):
            continue
        if info.get("kind") == "zip" and not launcher_in(info.get("staged")):
            continue
        if best is None or newer(info["version"], best["version"]):
            best = info
    if best and verify and fetch.sha256_file(best["file"]) != best.get("sha256"):
        return None
    return best


def cleanup(lay, current_version):
    """Remove staged updates that are not newer than the running version (they were applied)."""
    removed = []
    try:
        names = os.listdir(lay.updates)
    except OSError:
        return removed
    for n in names:
        info = L.read_json(os.path.join(lay.updates, n, STATE_FILE)) or {}
        if info.get("version") and not newer(info["version"], current_version):
            shutil.rmtree(os.path.join(lay.updates, n), ignore_errors=True)
            removed.append(n)
    return removed


def handoff_command(info, lay, pid=None):
    """(argv, cwd) of the step that finishes the update after this launcher exits."""
    if info["kind"] == "setup":
        return [info["file"], *SETUP_ARGS], os.path.dirname(info["file"])
    exe = launcher_in(info["staged"]) or os.path.join(info["staged"], L.LAUNCHER_EXE)
    return [exe, "--apply-update", info["staged"], "--target", lay.install,
            "--wait-pid", str(pid if pid is not None else os.getpid())], info["staged"]


def handoff(info, lay, popen=subprocess.Popen, pid=None):
    """Check the file once more, then start the finishing step. The caller exits right after."""
    if fetch.sha256_file(info["file"]) != info.get("sha256"):
        raise UpdateError("The downloaded update changed on disk since it was checked; it will be downloaded again.")
    argv, cwd = handoff_command(info, lay, pid)
    kw = {"cwd": cwd, "close_fds": True}
    if sys.platform == "win32":
        kw["creationflags"] = DETACHED
    return popen(argv, **kw)


# ---------------------------------------------------------------- the zip build's swap step

def pid_alive(pid):
    if not pid:
        return False
    if sys.platform == "win32":
        import ctypes
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x1000, False, int(pid))   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        try:
            ok = k32.GetExitCodeProcess(h, ctypes.byref(code))
            return bool(ok) and code.value == 259     # STILL_ACTIVE
        finally:
            k32.CloseHandle(h)
    try:
        os.kill(int(pid), 0)
    except OSError:
        return False
    try:
        with open(f"/proc/{int(pid)}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return True


def _retry(fn, tries=20, sleep=time.sleep):
    """Windows keeps a file busy for a moment after a process exits (and antivirus scans): retry."""
    for i in range(tries):
        try:
            return fn()
        except PermissionError:
            if i == tries - 1:
                raise
            sleep(0.5)


def _items(staged):
    """(relative path, is_dir) of every program item in the staged release."""
    out = []
    for name in PROGRAM_ITEMS:
        p = os.path.join(staged, name)
        if os.path.exists(p):
            out.append((name, os.path.isdir(p)))
    game = os.path.join(staged, L.GAME_DIR)
    if os.path.isdir(game):
        for name in sorted(os.listdir(game)):
            if name not in GAME_KEEP:
                out.append((os.path.join(L.GAME_DIR, name), os.path.isdir(os.path.join(game, name))))
    return out


def apply_staged(staged, target, wait_pid=None, log=None, sleep=time.sleep, alive=pid_alive, timeout=120):
    """Swap the staged release's program files into target. Old program files are moved aside first
    and put back if anything fails, so a half-applied update never happens. Returns the items replaced."""
    log = log or (lambda s: None)
    t0 = time.monotonic()
    while wait_pid and alive(wait_pid):
        if time.monotonic() - t0 > timeout:
            raise UpdateError("Open Vanilla is still running; close it and start the update again.")
        sleep(0.25)
    if not launcher_in(staged):
        raise UpdateError(f"{staged} has no {L.LAUNCHER_EXE}.")
    items = _items(staged)
    aside = os.path.join(target, ".update-old")
    if os.path.isdir(aside):
        shutil.rmtree(aside, ignore_errors=True)
    moved, placed = [], []
    try:
        for rel, _ in items:
            dst = os.path.join(target, rel)
            if os.path.lexists(dst):
                keep = os.path.join(aside, rel)
                os.makedirs(os.path.dirname(keep), exist_ok=True)
                _retry(lambda: os.replace(dst, keep), sleep=sleep)
                moved.append(rel)
        for rel, is_dir in items:
            src, dst = os.path.join(staged, rel), os.path.join(target, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if is_dir:
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)
            placed.append(rel)
            log(f"updated {rel}")
        for rel in FIRST_INSTALL_ONLY:
            src, dst = os.path.join(staged, rel), os.path.join(target, rel)
            if os.path.isfile(src) and not os.path.exists(dst):
                shutil.copy2(src, dst)
    except BaseException:
        log("update failed: putting the previous version back")
        for rel in placed:
            p = os.path.join(target, rel)
            shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else _silent_remove(p)
        for rel in moved:
            try:
                os.replace(os.path.join(aside, rel), os.path.join(target, rel))
            except OSError:
                pass
        raise
    shutil.rmtree(aside, ignore_errors=True)
    return [rel for rel, _ in items]


def _silent_remove(p):
    try:
        os.remove(p)
    except OSError:
        pass


def main_apply(argv, popen=subprocess.Popen):
    """`--apply-update <staged> --target <dir> --wait-pid <pid>`: finish a zip update, then start Open Vanilla."""
    def arg(flag):
        return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None

    staged, target, pid = arg("--apply-update"), arg("--target"), arg("--wait-pid")
    if not staged or not target:
        return 2
    logs = os.path.join(target, "Logs")
    os.makedirs(logs, exist_ok=True)
    with open(os.path.join(logs, "update.log"), "a", encoding="utf-8") as lf:
        def log(s):
            lf.write(time.strftime("%Y-%m-%d %H:%M:%S ") + s + "\n")
            lf.flush()

        code = 0
        try:
            apply_staged(staged, target, int(pid) if pid and pid.isdigit() else None, log)
            log("update applied")
        except Exception as e:
            log(f"update not applied: {e}")
            code = 1
        exe = launcher_in(target) or os.path.join(target, L.LAUNCHER_EXE)
        kw = {"cwd": target, "close_fds": True}
        if sys.platform == "win32":
            kw["creationflags"] = DETACHED
        try:
            popen([exe] + (["--update-failed"] if code else ["--updated"]), **kw)
        except OSError as e:
            log(f"couldn't start {exe}: {e}")
    return code


def summary(info):
    return json.dumps({k: info.get(k) for k in ("version", "kind")})
