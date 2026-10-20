#!/usr/bin/env python3
"""Write realm/www/manifests/_ui.json: the files the browser client reads ONE AT A TIME (synchronous
reads), so ow/prefetch.js can put them in memory before the client asks.

    python tools/gen_ui_manifest.py

Why: from far away (US players, realm in Germany) each of those reads is a ~170 ms round trip on the
client's main thread. A boot plus world entry is ~400 of them: about a minute of waiting at the end
of the loading bar. Warmed 12 at a time, they cost a few seconds, in the background.

  boot   game tables, glue art, fonts and every addon's .toc: read before the character list
  world  the stock interface (FrameXML), the Classic+ addons' files and their media: read after
         Enter World

The stock parts are captured from a real session (tools/ui_manifest_base.json; re-capture with
`owdiag` if the client changes). The Classic+ addons are read from Data/Interface/AddOns here, so a
new addon or a new file is picked up by running this again (dev\\Ship.bat runs the checks).
URLs are exactly what the client requests: '/'-separated addon paths as %2F, media as lower-case
'\\'-separated names (%5C).
"""
import json
import os
import re
import sys
import urllib.parse

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONS = os.path.join(HERE, "Data", "Interface", "AddOns")
BASE = os.path.join(HERE, "tools", "ui_manifest_base.json")
OUT = os.path.join(HERE, "realm", "www", "manifests", "_ui.json")


def enc(path):
    """'Interface/AddOns/Quests/Core.lua' -> 'Interface%2FAddOns%2FQuests%2FCore.lua'."""
    return urllib.parse.quote(path, safe="!")


def addon_files():
    tocs, files = [], []
    for name in sorted(os.listdir(ADDONS), key=str.lower):
        d = os.path.join(ADDONS, name)
        toc = os.path.join(d, name + ".toc")
        if not os.path.isfile(toc) or name.lower().startswith("blizzard_"):
            continue
        tocs.append(enc(f"Interface/AddOns/{name}/{name}.toc"))
        with open(toc, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                rel = line.replace("\\", "/")
                if os.path.isfile(os.path.join(d, *rel.split("/"))):
                    files.append(enc(f"Interface/AddOns/{name}/{rel}"))
        if os.path.isfile(os.path.join(d, "Bindings.xml")):
            files.append(enc(f"Interface/AddOns/{name}/Bindings.xml"))
    return tocs, files


def main():
    with open(BASE, encoding="utf-8") as f:
        base = json.load(f)
    tocs, files = addon_files()
    seen = set()

    def uniq(xs):
        out = []
        for x in xs:
            if x not in seen:
                seen.add(x)
                out.append(x)
        return out

    boot = uniq(base["boot"] + tocs)
    world = uniq(base["world"] + files)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"v": 1, "boot": boot, "world": world}, f, separators=(",", ":"))
        f.write("\n")
    print(f"{os.path.relpath(OUT, HERE)}: {len(boot)} boot + {len(world)} world reads "
          f"({len(tocs)} addons, {len(files)} addon files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
