"""Open Vanilla Server: run your own 1.12.1 realm on this PC (the separate download, not the launcher).

    Start Open Vanilla Server.bat        (Windows: finds Python, installs what's missing, runs this)
    python openvanilla_server.py        [--spp "C:\\SPP_Classics_V2"]  [--forget]

It runs SPP Classics' database, login and world servers, the realm website with sign-up and the browser
client (http://127.0.0.1:18090/), Server Studio and the GM tools, from one window (launcher_gui.py).

Which SPP install it runs, first match wins:
  --spp PATH  ·  SPP_ROOT in the environment  ·  the folder you picked last time (server_settings.json)
  ·  an install found on this PC (Desktop, C:\\, D:\\, C:\\Games)  ·  otherwise it asks you to pick one.
--forget clears the saved folder so it asks again.
"""
import json
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SETTINGS = os.path.join(HERE, "server_settings.json")
sys.path.insert(0, HERE)
sys.path.insert(1, os.path.join(HERE, "launcher"))  # spp.py (+ fetch.py): the SPP finder the launcher uses too

import spp  # noqa: E402

SPP_DOWNLOAD = spp.SPP_PAGE  # SPP Classics V2 releases


def read_settings():
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_settings(d):
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1)


def as_server(folder):
    """The SPP_Server folder for ``folder`` (the install or the SPP_Server inside it), or None."""
    if not folder:
        return None
    for cand in (folder, os.path.join(folder, spp.SERVER_FOLDER)):
        if spp.is_spp_server(cand) or os.path.isdir(os.path.join(cand, "Server", "Database")):
            return os.path.abspath(cand)
    return None


def ask_folder():
    """Let the player pick their SPP folder. None when they cancel."""
    import tkinter as tk
    from tkinter import filedialog, messagebox
    root = tk.Tk()
    root.withdraw()
    try:
        while True:
            go = messagebox.askyesnocancel(
                "Open Vanilla Server",
                "Open Vanilla Server runs an SPP Classics realm, and no SPP install was found on this PC.\n\n"
                "Yes: pick your SPP_Classics_V2 folder (or the SPP_Server folder inside it).\n"
                "No: open the SPP Classics download page first.\n"
                "Cancel: quit.", parent=root)
            if go is None:
                return None
            if go is False:
                import webbrowser
                webbrowser.open(SPP_DOWNLOAD)
                continue
            pick = filedialog.askdirectory(title="Your SPP_Classics_V2 folder", parent=root)
            if not pick:
                continue
            found = as_server(pick)
            if found:
                return found
            messagebox.showerror("Open Vanilla Server", f"{pick}\n\nisn't an SPP install: pick the folder that contains "
                                 "Server\\Database and Settings (or the one above it).", parent=root)
    finally:
        root.destroy()


def find_spp(argv):
    if "--spp" in argv:
        i = argv.index("--spp")
        found = as_server(argv[i + 1] if i + 1 < len(argv) else "")
        if not found:
            sys.exit("--spp: no SPP install there")
        return found, True
    for cand in (os.environ.get("SPP_ROOT"), read_settings().get("spp_root")):
        found = as_server(cand)
        if found:
            return found, False
    found = spp.find_existing()
    return (found, True) if found else (ask_folder(), True)


def main(argv):
    if sys.platform != "win32":
        # SPP Classics is a Windows program: on macOS and Linux the realm runs in Docker (host/ovhost,
        # docs/HOSTING_MAC_LINUX.md). With no command, the guided set-up; else ovhost's own commands.
        ovhost = os.path.join(HERE, "host", "ovhost")
        if not os.path.isfile(ovhost):
            print("host/ovhost is missing from this folder: get it from the Open Vanilla repository (host/ovhost).")
            return 1
        os.execvp("bash", ["bash", ovhost] + (argv or ["install"]))
    if "--forget" in argv:
        s = read_settings()
        s.pop("spp_root", None)
        save_settings(s)
    root, remember = find_spp(argv)
    if not root:
        print("No SPP install picked: nothing to run.")
        return 1
    if remember:
        s = read_settings()
        s["spp_root"] = root
        save_settings(s)
    os.environ["SPP_ROOT"] = root  # launcher_gui, server_control and asset_server read it when they load
    print(f"[SERVER] SPP install: {root}")
    os.chdir(HERE)
    runpy.run_path(os.path.join(HERE, "launcher_gui.py"), run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
