#!/usr/bin/env python3
"""Open Vanilla Workshop porting helper: wrap an openly licensed vanilla addon for Classic+.

    python3 tools/workshop_port.py path/to/Addon [--license MIT] [--name "Nice Name"]
                                   [--author X] [--source URL] [--out DIR]

What it does:
  1. Refuses unless the addon's licence is on the allow-list (MIT, BSD, Apache-2.0, GPL-2.0/3.0,
     LGPL, MPL-2.0, Unlicense, CC0). The licence comes from --license or a LICENSE/COPYING file in
     the folder or the folder above it. No licence found = refused: "all rights reserved" is the
     default for code without one, and we only port what we may redistribute.
  2. Reads the addon: the WoW API functions it calls, the events it registers, its SavedVariables,
     its slash commands and the options those commands take (`msg == "lock"`, `strfind(msg, "^reset")`).
  3. Writes a wrapper addon `<Folder>Plus/` next to nothing of the original (which stays untouched):
       <Folder>Plus.toc   ## Dependencies: WenillaCore, <Folder>; ## X-ClassicPlus: <Folder>
       <Folder>Plus.lua   W:RegisterSchema (switches for paired slash options such as lock/unlock,
                          show/hide, on/off) + W:RegisterAddon (applies them; turning the addon off in
                          /addons runs its own off/disable/hide command when it has one)
       PORT_NOTES.txt     the API report, what was not mapped, and the credits/licence block
  4. Runs tools/workshop_scan.py on the original and on the wrapper, and prints the credits block.

A person reviews every port before it ships: read the wrapper, play with it in the game, check
the licence and the credits, then add the catalogue entry (workshop/catalog/<id>.yml, ours: true).
This tool never publishes anything.
"""
import argparse
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import workshop_lib as W  # noqa: E402
import workshop_scan as S  # noqa: E402

LICENSE_FILES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING", "COPYING.txt", "license.txt")
PAIRS = [("on", "off"), ("enable", "disable"), ("show", "hide"), ("lock", "unlock"), ("start", "stop")]
OPT_RX = [
    re.compile(r"\b(?:msg|cmd|command|arg1|args?|input|text|option|opt|sub|subcmd|word)\s*==\s*\"([A-Za-z][\w-]{0,23})\""),
    re.compile(r"\"([A-Za-z][\w-]{0,23})\"\s*==\s*(?:msg|cmd|command|arg1|args?|input|text|option|opt|sub|subcmd|word)\b"),
    re.compile(r"strfind\(\s*\w+\s*,\s*\"\^([A-Za-z][\w-]{0,23})"),
]


class Refused(Exception):
    pass


def find_license(folder, given=None):
    if given:
        return W.norm_license(given), "--license"
    for d in (folder, os.path.dirname(os.path.abspath(folder))):
        for n in LICENSE_FILES:
            p = os.path.join(d, n)
            if os.path.isfile(p):
                with open(p, encoding="utf-8", errors="replace") as f:
                    return W.classify_license_text(f.read()), p
    tn = S.toc_basename(folder)
    toc = W.read_toc(os.path.join(folder, tn + ".toc")) if tn else None
    lic = toc and (toc["meta"].get("X-License") or toc["meta"].get("License"))
    if lic:
        return W.norm_license(lic), ".toc"
    return "NOASSERTION", None


def lua_sources(folder):
    for dp, dn, files in os.walk(folder):
        dn.sort()
        for f in sorted(files):
            if f.lower().endswith(".lua"):
                p = os.path.join(dp, f)
                with open(p, encoding="utf-8", errors="replace") as fh:
                    yield os.path.relpath(p, folder), S.strip_lua_comments(fh.read())


def analyse(folder):
    """API use, events, SavedVariables, slash commands and their options."""
    tn = S.toc_basename(folder)
    toc = (W.read_toc(os.path.join(folder, tn + ".toc")) if tn else None) or {"meta": {}}
    api = collections.Counter()
    events, slashes, options = set(), {}, collections.OrderedDict()
    for _rel, src in lua_sources(folder):
        for m in re.finditer(r"(?<![\w.:])([A-Z][A-Za-z0-9_]+)\s*\(", src):
            if m.group(1) in S.REAL_GLOBALS:
                api[m.group(1)] += 1
        events.update(re.findall(r"RegisterEvent\(\s*\"([A-Z_]+)\"", src))
        for key, cmd in re.findall(r"SLASH_(\w+?)\d+\s*=\s*[\"'](/[\w-]+)[\"']", src):
            slashes.setdefault(key, []).append(cmd)
        # options: only inside slash handlers (SlashCmdList["KEY"] = function(msg) ... up to the
        # next handler or 4000 characters)
        for m in re.finditer(r"SlashCmdList\[\s*[\"'](\w+)[\"']\s*\]\s*=\s*function\s*\((\w*)", src):
            end = src.find("SlashCmdList[", m.end())
            body = src[m.end(): end if end != -1 else m.end() + 4000][:4000]
            words = options.setdefault(m.group(1), collections.OrderedDict())
            rxs = list(OPT_RX)
            if m.group(2):
                rxs.append(re.compile(r"\b" + re.escape(m.group(2)) + r"\s*==\s*\"([A-Za-z][\w-]{0,23})\""))
            for rx in rxs:
                for word in rx.findall(body):
                    words[word.lower()] = True
    saved = [x for k in ("SavedVariables", "SavedVariablesPerCharacter")
             for x in re.split(r"[,\s]+", toc["meta"].get(k, "")) if x]
    # the main command: the one named like the addon, else the one with the most options
    folder_name = (tn or os.path.basename(folder)).lower()
    keys = list(slashes)
    main = next((k for k in keys if any(folder_name in c.lower() for c in slashes[k])), None)
    if not main and keys:
        main = max(keys, key=lambda k: len(options.get(k, {})))
    if main:
        slashes = {main: slashes[main], **{k: v for k, v in slashes.items() if k != main}}
    return {"api": api, "events": sorted(events), "slash": slashes, "options": list(options.get(main, {})) if main else [],
            "saved": saved, "toc": toc["meta"]}


def switches(options):
    """Paired options become switches; the rest stay commands."""
    opts, used, out = set(options), set(), []
    for on, off in PAIRS:
        if on in opts and off in opts:
            out.append({"key": f"opt_{on}", "label": on.capitalize() if on not in ("on", "enable") else "Enabled",
                        "on": on, "off": off})
            used.update((on, off))
    return out, [o for o in options if o not in used]


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def make_wrapper(folder, out_dir, info, meta):
    orig = S.toc_basename(folder) or os.path.basename(os.path.abspath(folder))
    name = meta["name"] or W.strip_codes(info["toc"].get("Title", orig)) or orig
    wid = orig + "Plus"
    dest = os.path.join(out_dir, wid)
    os.makedirs(dest, exist_ok=True)
    sw, commands = switches(info["options"])
    slash_key = next(iter(info["slash"]), None)
    slash_cmd = info["slash"][slash_key][0] if slash_key else None
    power = next(((on, off) for on, off in (("enable", "disable"), ("on", "off"), ("show", "hide"))
                  if on in info["options"] and off in info["options"]), None)
    toc = [
        "## Interface: 11200",
        f"## Title: {name}",
        f"## Notes: {name} by {meta['author']}, wrapped for Classic+ ({meta['license']}).",
        "## Author: " + meta["author"] + " (port: Open Vanilla)",
        "## Version: 1.0.0",
        f"## Dependencies: WenillaCore, {orig}",
        f"## X-ClassicPlus: {orig}",
        f"## X-License: {meta['license']}",
        f"## X-Source: {meta['source'] or ''}",
        "",
        f"{wid}.lua",
        "",
    ]
    with open(os.path.join(dest, wid + ".toc"), "w", encoding="utf-8", newline="\r\n") as f:
        f.write("\n".join(toc))

    defaults = ", ".join(f"{s['key']} = false" for s in sw) or ""
    opt_lines = "\n".join(
        f"        {{ key = {lua_str(s['key'])}, label = {lua_str(s['label'])}, sub = {lua_str(slash_cmd + ' ' + s['on'] + ' / ' + s['off'])} }},"
        for s in sw)
    map_lines = "\n".join(f"    {{ key = {lua_str(s['key'])}, on = {lua_str(s['on'])}, off = {lua_str(s['off'])} }},"
                          for s in sw)
    cmd_note = (" Commands: " + ", ".join(f"{slash_cmd} {c}" for c in commands[:8]) + ".") if commands and slash_cmd else ""
    lua = f"""-- {name} for Classic+ -- generated by tools/workshop_port.py from {orig} ({meta['license']}).
-- Original addon by {meta['author']}: {meta['source'] or 'see PORT_NOTES.txt'}
-- The original is loaded untouched (it is a dependency); this file only lists it in /addons and
-- turns its paired slash options into switches. A person reviews every port before it ships.
-- Lua 5.0: no '#', no '%', no select(), no string.match.

local W = WenillaCore
local ID = {lua_str(orig)}
local SLASH = {lua_str(slash_key) if slash_key else "nil"}

local SWITCHES = {{
{map_lines}
}}

W:RegisterSchema(ID, {{
    icon = "Interface\\\\Icons\\\\INV_Misc_Gear_02",
    title = {lua_str(name)},
    desc = {lua_str(f"{info['toc'].get('Notes') and W.strip_codes(info['toc']['Notes']) or name} (by {meta['author']}, {meta['license']}).{cmd_note}")},
    defaults = {{ {defaults} }},
    options = {{
{opt_lines}
    }},
}})

local function run(cmd)
    local f = SLASH and SlashCmdList and SlashCmdList[SLASH]
    if f and cmd then f(cmd) end
end

local applied = {{}}
local wasActive
W:RegisterAddon(ID, function(active)
    if wasActive ~= nil and active ~= wasActive then
        run(active and {lua_str(power[0]) if power else "nil"} or {lua_str(power[1]) if power else "nil"})
    end
    wasActive = active
    if not active then return end
    for _, s in ipairs(SWITCHES) do
        local v = W:Setting(ID, s.key, false) and true or false
        if applied[s.key] ~= nil and applied[s.key] ~= v then
            run(v and s.on or s.off)
        end
        applied[s.key] = v
    end
end)
"""
    with open(os.path.join(dest, wid + ".lua"), "w", encoding="utf-8") as f:
        f.write(lua)
    return dest, sw, commands


def credits_block(name, meta):
    return "\n".join([
        "-" * 72,
        f"{name}",
        f"  Original author : {meta['author']}",
        f"  Source          : {meta['source'] or '(not given)'}",
        f"  Licence         : {meta['license']} ({meta['license_from']})",
        "  Port            : Open Vanilla Classic+ wrapper (tools/workshop_port.py); the original files are",
        "                    shipped unmodified next to the wrapper, with their licence file.",
        "  Review          : a person reviews every port before it is listed (see PORT_NOTES.txt).",
        "-" * 72,
    ])


def port(folder, out_dir, license=None, name=None, author=None, source=None, scan=True, log=print):
    if not S.toc_basename(folder):
        raise Refused(f"{folder} has no {os.path.basename(folder)}.toc: not an addon folder")
    lic, lic_from = find_license(folder, license)
    if not W.may_rehost(lic):
        raise Refused(f"licence {lic!r} ({lic_from or 'no licence file'}) does not allow redistribution; "
                      "only MIT, BSD, Apache-2.0, GPL-2.0/3.0, LGPL, MPL-2.0, Unlicense and CC0 addons are ported. "
                      "Link to the author's page instead.")
    info = analyse(folder)
    toc = info["toc"]
    meta = {"name": name, "author": author or toc.get("Author") or "unknown", "source": source or toc.get("X-Website") or "",
            "license": lic, "license_from": lic_from or "?"}
    dest, sw, commands = make_wrapper(folder, out_dir, info, meta)
    disp = name or W.strip_codes(toc.get("Title", os.path.basename(folder)))
    notes = [
        f"PORT NOTES - {disp}", "",
        "Generated by tools/workshop_port.py. A person must review this port before it ships:",
        "  [ ] read the wrapper; [ ] try every switch in the game; [ ] check the licence and credits;",
        "  [ ] add workshop/catalog/<id>.yml (ours: true) and run tools/workshop_build.py.", "",
        f"SavedVariables: {', '.join(info['saved']) or '(none)'}",
        f"Slash commands: {', '.join(c for v in info['slash'].values() for c in v) or '(none)'}",
        f"Switches:       {', '.join(s['on'] + '/' + s['off'] for s in sw) or '(none detected)'}",
        f"Other options:  {', '.join(commands) or '(none)'}",
        f"Events:         {', '.join(info['events'][:24]) or '(none)'}{' ...' if len(info['events']) > 24 else ''}",
        "WoW API calls (most used first):",
    ] + [f"  {n:4d}  {fn}" for fn, n in info["api"].most_common(40)] + ["", credits_block(disp, meta), ""]
    with open(os.path.join(dest, "PORT_NOTES.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(notes))
    result = {"wrapper": dest, "license": lic, "switches": sw, "commands": commands, "saved": info["saved"],
              "events": info["events"], "api": dict(info["api"])}
    if scan:
        result["scan_original"] = S.scan_path(folder)
        core = os.path.join(W.ADDONS_DIR, "WenillaCore")
        result["scan_wrapper"] = S.scan_path(dest, deps=[core, folder])
        log("original: " + S.summary(result["scan_original"]).replace("\n", "\n  "))
        log("wrapper:  " + S.summary(result["scan_wrapper"]).replace("\n", "\n  "))
    log("\n".join(notes[6:12]))
    log(credits_block(disp, meta))
    log(f"wrapper written to {dest}; review it before it ships.")
    return result


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder")
    ap.add_argument("--license")
    ap.add_argument("--name")
    ap.add_argument("--author")
    ap.add_argument("--source")
    ap.add_argument("--out", default=os.path.join(W.ROOT, "workshop", "ports"))
    ap.add_argument("--no-scan", action="store_true")
    args = ap.parse_args(argv)
    try:
        port(args.folder.rstrip("/"), args.out, args.license, args.name, args.author, args.source, scan=not args.no_scan)
    except Refused as e:
        print("refused: " + str(e), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
