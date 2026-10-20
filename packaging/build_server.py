#!/usr/bin/env python3
"""Build OpenVanilla-Server.zip: the separate download for running your own realm (the launcher doesn't host).

    python packaging/build_server.py [--version 1.17.0] [--out release]

Inside, one folder OpenVanilla-Server/:
  Start Open Vanilla Server.bat      finds Python, installs aiohttp/pillow/psutil/pymysql once, opens the panel
  openvanilla_server.py             finds (or asks for) the SPP Classics install, then runs launcher_gui.py
  launcher_gui.py, server_control.py, asset_server.py, studio_server.py, studio/, play_local.py, ...
  launcher/spp.py, fetch.py, defaults.json   the SPP finder and the official realm list
  realm/classicplus/            the Classic+ SQL and DBC fix-ups
  www/                          the realm website + browser client (no download files)
  bin/caddy.exe                 the optional HTTPS gateway for players on the internet
Refuses game files (.mpq, Data/, WoW.exe) and anything private (.env, settings, logs, databases).
"""
import argparse
import fnmatch
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOP = "OpenVanilla-Server"

FILES = ["openvanilla_server.py", "launcher_gui.py", "server_control.py", "asset_server.py", "studio_server.py",
         "play_local.py", "authcheck.py", "set_realm.py", "SECURITY.md",
         "launcher/spp.py", "launcher/fetch.py", "launcher/defaults.json",
         "docs/CLASSIC_PLUS_ARCHITECTURE.md", "bin/caddy.exe", "bin/heraldlite.exe", "Herald Autopilot.bat",
         "launcher/account.py", "launcher/launcher_art.py"]   # launcher_art: the Server Host's buttons
OPTIONAL = {"bin/caddy.exe", "bin/heraldlite.exe"}   # (no Caddyfile: launcher_gui writes its own, and the local one holds your IP) built by the release workflow; a local build may not have them
RENAME = {"Host a Realm.bat": "Start Open Vanilla Server.bat"}
TREES = ["studio", "assets", "realm/classicplus", "www", "autopilot", "launcher/assets/launcher/fonts"]
SKIP = ["__pycache__", "*.pyc", "*.zip", "*.exe", "*.part", "*.log", "*.db", "*.sqlite*", ".env*", "*.mpq", "*.MPQ",
        "settings.json", "launcher_settings.json", "server_settings.json", "node_modules", ".git*"]
SKIP_DIRS = {"www/downloads", "www/__pycache__", "www/CNAME"}
NEVER = ("wow.exe", ".mpq")  # Blizzard's game files never ship


def skipped(rel):
    name = rel.rsplit("/", 1)[-1]
    return any(fnmatch.fnmatch(name, p) for p in SKIP) or any(rel == d or rel.startswith(d + "/") for d in SKIP_DIRS)


def readme(version):
    return f"""Open Vanilla Server {version}
=====================

Run your own World of Warcraft 1.12.1 realm (Vanilla or Classic+) on a Windows PC: SPP Classics'
database, login and world servers, plus the realm website with sign-up, the browser client, Server
Studio and GM tools, all from one window.

1. Install Python 3 (python.org, tick "Add to PATH").
2. Have SPP Classics V2: https://github.com/celguar/spp-classics-cmangos/releases
   (or let the Open Vanilla launcher's Play Solo set it up for you once).
3. Double-click "Start Open Vanilla Server.bat". The first start installs what it needs and finds your SPP
   install (or asks you to pick the SPP_Classics_V2 folder).
4. Press START, then open http://127.0.0.1:18090/ for the realm website.
5. Want Herald to play on it? Press HERALD in the server window (or double-click "Herald Autopilot.bat"),
   enter the account he should play (make one with CREATE / UPDATE ACCOUNT) and press START.
   Keep that account out of the game while he plays; watch him from your own account.

Players connect with the Open Vanilla launcher: REALMS -> Add realm, with your PC's address.
The full guide: https://openvanilla.app/guide.html  ·  Hosting help: https://openvanilla.app/host.html

python openvanilla_server.py --spp "D:\\SPP_Classics_V2"   runs a different SPP install
python openvanilla_server.py --forget                      asks for the SPP folder again
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=None)
    ap.add_argument("--out", default=os.path.join(HERE, "release"))
    a = ap.parse_args()
    version = a.version or open(os.path.join(HERE, "VERSION"), encoding="utf-8").read().strip()
    os.makedirs(a.out, exist_ok=True)
    out = os.path.join(a.out, "OpenVanilla-Server.zip")
    tmp = out + ".part"
    entries = []
    for rel in FILES:
        if os.path.isfile(os.path.join(HERE, rel)):
            entries.append((rel, rel))
        elif rel not in OPTIONAL:
            sys.exit(f"missing {rel}")
    entries += [(src, dst) for src, dst in RENAME.items()]
    for tree in TREES:
        for d, dirs, files in os.walk(os.path.join(HERE, tree)):
            rd = os.path.relpath(d, HERE).replace(os.sep, "/")
            dirs[:] = sorted(x for x in dirs if not skipped(f"{rd}/{x}"))
            entries += [(f"{rd}/{f}", f"{rd}/{f}") for f in sorted(files) if not skipped(f"{rd}/{f}")]
    for _, dst in entries:
        low = dst.lower()
        if low.endswith(NEVER):
            sys.exit(f"refusing to ship {dst}")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for src, dst in entries:
            z.write(os.path.join(HERE, src), f"{TOP}/{dst}")
        z.writestr(f"{TOP}/README.txt", readme(version).replace("\n", "\r\n"))
        z.writestr(f"{TOP}/requirements.txt", "aiohttp>=3.8\npillow>=9\npsutil>=5.9\npymysql>=1.0\n")
    os.replace(tmp, out)
    print(f"{out}: {len(entries) + 2} files, {os.path.getsize(out) // (1024 * 1024)} MB (Open Vanilla Server {version})")


if __name__ == "__main__":
    main()
