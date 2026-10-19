#!/usr/bin/env python3
"""Make Forge's table schemas (crates/forge-core/schemas/*.json) from their sources:

  world.json  the CMaNGOS Classic world tables Forge edits, from sql/base/mangos.sql
              (https://github.com/cmangos/mangos-classic, GPL-2.0; only column names, types and
              defaults are used)
  dbc.json    the 1.12.1 (build 5875) client DBC layouts Forge edits, from WoWDBDefs
              (https://github.com/wowdev/WoWDBDefs, definitions CC BY-SA 4.0), copies in dbd/

    python3 gen_schemas.py path/to/mangos.sql
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "crates", "forge-core", "schemas")

WORLD = ["creature_template", "creature", "creature_model_info", "creature_equip_template",
         "creature_questrelation", "creature_involvedrelation", "creature_loot_template",
         "item_template", "item_loot_template", "reference_loot_template", "gameobject_template",
         "quest_template", "npc_text", "gossip_menu", "gossip_menu_option", "npc_vendor", "npc_trainer",
         "instance_template", "areatrigger_teleport", "game_tele", "gameobject",
         "creature_movement", "creature_ai_scripts", "custom_texts", "gameobject_loot_template",
         "game_event", "game_event_creature", "game_event_gameobject", "skinning_loot_template",
         "pickpocketing_loot_template"]
DBC = ["CreatureDisplayInfo", "CreatureModelData", "ItemDisplayInfo", "Spell", "SpellIcon", "Map", "AreaTable", "AreaTrigger", "LoadingScreens",
       "Light", "LightParams", "LightIntBand", "LightFloatBand", "LightSkybox", "ZoneMusic", "SoundAmbience", "GameObjectDisplayInfo"]
BUILD = (1, 12, 1, 5875)


def world(sql_path):
    text = open(sql_path, encoding="utf-8", errors="replace").read()
    out = {}
    for t in WORLD:
        m = re.search(r"CREATE TABLE `%s` \((.*?)\n\)" % re.escape(t), text, re.S)
        if not m:
            raise SystemExit(f"{t} not in {sql_path}")
        cols, key = [], []
        for line in m.group(1).splitlines():
            line = line.strip().rstrip(",")
            c = re.match(r"`(\w+)`\s+([a-z]+)(\([^)]*\))?\s*(unsigned)?(.*)", line, re.I)
            if c:
                name, base, size, uns, rest = c.groups()
                base = base.lower()
                kind = ("float" if base in ("float", "double", "decimal") else
                        "string" if base in ("varchar", "char", "text", "longtext", "mediumtext", "tinytext") else "int")
                d = re.search(r"DEFAULT\s+('(?:[^']|'')*'|[-\d.]+|NULL)", rest, re.I)
                default = None
                if d:
                    v = d.group(1)
                    default = None if v.upper() == "NULL" else (v[1:-1].replace("''", "'") if v.startswith("'") else (float(v) if "." in v else int(v)))
                com = re.search(r"COMMENT\s+'((?:[^']|'')*)'", rest)
                cols.append({"name": name, "type": kind, "sql": base + (size or "") + (" unsigned" if uns else ""),
                             "default": default, "null": "NOT NULL" not in rest.upper(),
                             "comment": com.group(1).replace("''", "'") if com else ""})
            k = re.match(r"(PRIMARY|UNIQUE) KEY\s*(`\w+`\s*)?\(([^)]*)\)", line, re.I)
            if k and (k.group(1).upper() == "PRIMARY" or not key):
                key = [x.strip(" `") for x in k.group(3).split(",")]
        names = {c["name"].lower(): c["name"] for c in cols}
        key = [names[k.lower()] for k in key]
        out[t] = {"columns": cols, "key": key}
    return out


def parse_build(s):
    return tuple(int(x) for x in s.split("."))


def covers(spec):
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-")
            if parse_build(a) <= BUILD <= parse_build(b):
                return True
        elif part and parse_build(part) == BUILD:
            return True
    return False


def dbc(name):
    lines = open(os.path.join(HERE, "dbd", name + ".dbd"), encoding="utf-8").read().split("\n")
    types = {}
    i = 0
    assert lines[0].strip() == "COLUMNS"
    i = 1
    while lines[i].strip():
        m = re.match(r"(\w+)(<[^>]*>)?\s+(\w+)\??", lines[i].strip())
        types[m.group(3)] = m.group(1)
        i += 1
    blocks, cur = [], None
    for line in lines[i:]:
        s = line.strip()
        if not s:
            if cur:
                blocks.append(cur)
            cur = None
            continue
        if cur is None:
            cur = {"builds": [], "fields": []}
        if s.startswith("BUILD "):
            cur["builds"].append(s[6:])
        elif s.startswith(("LAYOUT", "COMMENT")):
            continue
        else:
            cur["fields"].append(s)
    if cur:
        blocks.append(cur)
    for b in blocks:
        if any(covers(x) for x in b["builds"]):
            fields = []
            for f in b["fields"]:
                m = re.match(r"(\$[^$]*\$)?(\w+)(<(u)?(\d+)>)?(\[(\d+)\])?", f)
                annot, fname, _, uns, bits, _, count = m.groups()
                t = types[fname]
                kind = {"int": "uint" if uns else "int", "float": "float", "string": "string", "locstring": "locstring"}[t]
                if bits and bits != "32":
                    raise SystemExit(f"{name}.{fname}: {bits}-bit field in a 1.12 DBC?")
                fields.append({"name": fname, "type": kind, "count": int(count or 1), "id": bool(annot and "id" in annot)})
            return {"fields": fields}
    raise SystemExit(f"{name}: no layout for build 1.12.1.5875")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    json.dump(world(sys.argv[1]), open(os.path.join(OUT, "world.json"), "w"), indent=1)
    d = {n: dbc(n) for n in DBC}
    # a 1.12 locstring is 8 locale strings + a flags word
    for n, s in d.items():
        width = sum((9 if f["type"] == "locstring" else 1) * f["count"] for f in s["fields"])
        s["record_fields"] = width
    json.dump(d, open(os.path.join(OUT, "dbc.json"), "w"), indent=1)
    print("world:", {t: len(v["columns"]) for t, v in world(sys.argv[1]).items()})
    print("dbc:", {n: s["record_fields"] for n, s in d.items()})
