"""Registering ported models in Open Vanilla: IDs, the patch's DBC tables, and the server SQL.

Layout inside the Open Vanilla folder:
  content/models/registry.json          every ported model and the IDs it was given (keep in git)
  content/models/<Name>/source.glb      the original, so it can be re-ported with new settings
  content/models/<Name>/port.json       the settings and the last port report
  content/models/<Name>/game/...        the game files, by archive path (go into patch-Z.MPQ)
  Data/ClassicPlusDBC/*.dbc             CreatureModelData, CreatureDisplayInfo (+ Spell for mounts):
                                        stock 1.12 tables plus our rows (go into patch-Z.MPQ)
  realm/classicplus/classicplus_world_models.sql     creatures, mount spells and items (server)
  realm/classicplus/classicplus_world_models.json    the DBC rows, for the server's own copy

IDs stay clear of 1.12.1's own: model data from 3000, displays from 20000, creatures from 991000,
spells from 40000, items from 991500.
"""
import json
import os
import shutil
import struct
import time


def _readb(path):
    with open(path, "rb") as f:
        return f.read()


def _writeb(path, data):
    with open(path, "wb") as f:
        f.write(data)

FIRST = {"model": 3000, "display": 20000, "creature": 991000, "spell": 40000, "item": 991500}

# Donor rows: the stock row a new one is copied from (sounds, footprints, blood). Looked up by model
# path so no number is guessed; the first that exists wins.
SOUND_FAMILIES = {
    "horse": ["Creature\\RidingHorse\\RidingHorse.mdx", "Creature\\Horse\\Horse.mdx"],
    "wolf": ["Creature\\Wolf\\Wolf.mdx", "Creature\\Worg\\Worg.mdx"],
    "cat": ["Creature\\Tiger\\Tiger.mdx", "Creature\\Lion\\Lion.mdx"],
    "raptor": ["Creature\\Raptor\\Raptor.mdx"],
    "kodo": ["Creature\\Kodo\\Kodo.mdx"],
    "ram": ["Creature\\Ram\\Ram.mdx"],
    "mechanical": ["Creature\\MechaStrider\\MechaStrider.mdx", "Creature\\Mechastrider\\Mechastrider.mdx"],
    "dragon": ["Creature\\Dragon\\Dragon.mdx", "Creature\\Drake\\Drake.mdx", "Creature\\BlackDragon\\BlackDragon.mdx"],
    "bear": ["Creature\\Bear\\Bear.mdx"],
    "spider": ["Creature\\Spider\\Spider.mdx"],
    "humanoid": ["Creature\\Furbolg\\Furbolg.mdx", "Creature\\Kobold\\Kobold.mdx"],
}
# Mount spells to copy: 60% (Brown Horse) and 100% (Swift Brown Steed).
MOUNT_SPELL = {"normal": 458, "epic": 23229}
# ...and the reins items that teach them: Brown Horse Bridle, Swift Brown Steed.
MOUNT_ITEM = {"normal": 5656, "epic": 18777}
# Spell.dbc columns (1.12.1, 173 fields)
SP_ID, SP_MISC1, SP_NAME, SP_DESC = 0, 106, 120, 138
SP_AURA = (91, 92, 93)


class Dbc:
    def __init__(self, data):
        if data[:4] != b"WDBC":
            raise ValueError("not a DBC")
        self.n, self.f, self.rs, ss = struct.unpack_from("<4I", data, 4)
        self.recs = bytearray(data[20:20 + self.n * self.rs])
        self.strs = bytearray(data[20 + self.n * self.rs:20 + self.n * self.rs + ss])

    @classmethod
    def load(cls, path):
        return cls(_readb(path))

    def row(self, i):
        return list(struct.unpack_from(f"<{self.f}I", self.recs, i * self.rs))

    def find(self, rid):
        for i in range(self.n):
            if struct.unpack_from("<I", self.recs, i * self.rs)[0] == rid:
                return i
        return None

    def ids(self):
        return {struct.unpack_from("<I", self.recs, i * self.rs)[0] for i in range(self.n)}

    def string(self, off):
        end = self.strs.index(b"\0", off)
        return self.strs[off:end].decode("latin1")

    def add_string(self, s):
        if not s:
            return 0
        enc = s.encode("latin1", "replace") + b"\0"
        off = len(self.strs)
        self.strs += enc
        return off

    def put(self, row):
        """Append, or replace the row with the same id."""
        data = struct.pack(f"<{self.f}I", *[v & 0xFFFFFFFF for v in row])
        i = self.find(row[0])
        if i is None:
            self.recs += data
            self.n += 1
        else:
            self.recs[i * self.rs:(i + 1) * self.rs] = data

    def bytes(self):
        return b"WDBC" + struct.pack("<4I", self.n, self.f, self.rs, len(self.strs)) + bytes(self.recs) + bytes(self.strs)


def f2u(x):
    return struct.unpack("<I", struct.pack("<f", float(x)))[0]


class Library:
    """The Open Vanilla folder's model library."""

    def __init__(self, root):
        self.root = root
        self.dir = os.path.join(root, "content", "models")
        self.reg_path = os.path.join(self.dir, "registry.json")
        os.makedirs(self.dir, exist_ok=True)
        self.reg = {"models": {}}
        if os.path.exists(self.reg_path):
            with open(self.reg_path, encoding="utf-8") as f:
                self.reg = json.load(f)

    def save(self):
        tmp = self.reg_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.reg, f, indent=2, sort_keys=True)
        os.replace(tmp, self.reg_path)

    def _next(self, kind):
        used = {m.get(kind) for m in self.reg["models"].values()} | {
            (m.get("mount") or {}).get(kind) for m in self.reg["models"].values()}
        n = FIRST[kind]
        while n in used:
            n += 1
        return n

    def stock_dir(self):
        for c in ("dbfilesclient", "DBFilesClient"):
            p = os.path.join(self.root, "Data", c)
            if os.path.isdir(p):
                return p
        raise FileNotFoundError("Data/dbfilesclient (the stock 1.12 tables) isn't in the Open Vanilla folder")

    def stock(self, name):
        d = self.stock_dir()
        for f in os.listdir(d):
            if f.lower() == name.lower() + ".dbc":
                return Dbc.load(os.path.join(d, f))
        raise FileNotFoundError(f"{name}.dbc not in {d}")

    def add(self, ported, source_path, options, mount=None):
        """Store a ported model (replacing an earlier port of the same name, keeping its IDs)."""
        name = ported.meta["name"]
        prev = self.reg["models"].get(name, {})
        entry = {
            "name": name,
            "kind": ported.meta["kind"],
            "model": prev.get("model") or self._next("model"),
            "display": prev.get("display") or self._next("display"),
            "creature": prev.get("creature") or self._next("creature"),
            "model_path": ported.meta["model_path"],
            "texture_variation": ported.meta.get("texture_variation", ""),
            "height": round(ported.meta["height"], 3),
            "width": round(ported.meta["width"], 3),
            "sound": options.get("sound") or ("horse" if ported.meta["kind"] == "mount" else "humanoid"),
            "title": options.get("title") or name,
            "updated": time.strftime("%Y-%m-%d %H:%M"),
        }
        if mount:
            pm = prev.get("mount") or {}
            entry["mount"] = {
                "spell": pm.get("spell") or self._next("spell"),
                "item": pm.get("item") or self._next("item"),
                "speed": mount.get("speed", "normal"),
                "item_name": mount.get("item_name") or f"Reins of the {entry['title']}",
            }
        self.reg["models"][name] = entry
        # files: the game files beside the source, so the folder is the whole model
        keep = os.path.join(self.dir, name)
        game = os.path.join(keep, "game")
        if os.path.isdir(game):
            shutil.rmtree(game)
        for arc, data in ported.files.items():
            p = os.path.join(game, *arc.split("\\"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            _writeb(p, data)
        ext = os.path.splitext(source_path)[1].lower() or ".glb"
        if os.path.abspath(source_path) != os.path.abspath(os.path.join(keep, "source" + ext)):
            shutil.copyfile(source_path, os.path.join(keep, "source" + ext))
        with open(os.path.join(keep, "port.json"), "w", encoding="utf-8") as f:
            json.dump({"options": options, "mount": mount, "meta": ported.meta, "warnings": ported.warnings,
                       "info": ported.info}, f, indent=2)
        self.save()
        self.build()
        return entry

    def remove(self, name):
        e = self.reg["models"].pop(name, None)
        if not e:
            return False
        game = os.path.join(self.dir, name, "game")  # the source and settings stay, to add it back
        if os.path.isdir(game):
            shutil.rmtree(game)
        self.save()
        self.build()
        return True

    # ---- the tables -----------------------------------------------------------------------

    def rows(self):
        """Every DBC row the library adds: {table: [row, ...]} with strings as ('s', text)."""
        cmd = self.stock("CreatureModelData")
        cdi = self.stock("CreatureDisplayInfo")
        paths = {}
        for i in range(cmd.n):
            r = cmd.row(i)
            paths[cmd.string(r[2]).lower()] = r
        out = {"CreatureModelData": [], "CreatureDisplayInfo": [], "Spell": []}
        spell = None
        for e in self.reg["models"].values():
            donor = None
            for p in SOUND_FAMILIES.get(e["sound"], []) + SOUND_FAMILIES["horse"]:
                if p.lower() in paths:
                    donor = paths[p.lower()]
                    break
            r = list(donor)
            r[0] = e["model"]
            r[2] = ("s", e["model_path"])
            r[14] = f2u(max(0.4, e["width"] / 2))      # collision width
            r[15] = f2u(max(0.5, e["height"]))         # collision height
            out["CreatureModelData"].append(r)
            dr = None
            for i in range(cdi.n):
                x = cdi.row(i)
                if x[1] == donor[0]:
                    dr = x
                    break
            d = list(dr) if dr else [0, 0, 0, 0, f2u(1.0), 255, 0, 0, 0, 1, 0, 0]
            d[0], d[1] = e["display"], e["model"]
            d[4], d[5] = f2u(1.0), 255
            d[6], d[7], d[8] = ("s", e["texture_variation"]), 0, 0
            out["CreatureDisplayInfo"].append(d)
            m = e.get("mount")
            if m:
                if spell is None:
                    spell = self.stock("Spell")
                src = spell.find(MOUNT_SPELL.get(m["speed"], 458))
                s = spell.row(src)
                s[SP_ID] = m["spell"]
                aura_slot = next((k for k, c in enumerate(SP_AURA) if s[c] == 78), 0)
                s[SP_MISC1 + aura_slot] = e["creature"]
                s[SP_NAME] = ("s", e["title"])
                s[SP_DESC] = ("s", f"Summons and dismisses a rideable {e['title']}."
                              + ("  This is a very fast mount." if m["speed"] == "epic" else ""))
                out["Spell"].append(s)
        return out

    def build(self):
        """Write Data/ClassicPlusDBC/*.dbc, classicplus_world_models.sql and classicplus_world_models.json."""
        rows = self.rows()
        dbc_dir = os.path.join(self.root, "Data", "ClassicPlusDBC")
        os.makedirs(dbc_dir, exist_ok=True)
        for table, rs in rows.items():
            path = os.path.join(dbc_dir, table + ".dbc")
            if not rs:
                if os.path.exists(path):
                    os.remove(path)
                continue
            d = self.stock(table)
            for r in rs:
                d.put([d.add_string(v[1]) if isinstance(v, tuple) else v for v in r])
            _writeb(path, d.bytes())
        cp = os.path.join(self.root, "realm", "classicplus")
        if os.path.isdir(cp):
            with open(os.path.join(cp, "classicplus_world_models.json"), "w") as f:
                json.dump({t: rs for t, rs in rows.items() if t != "Spell"}, f, indent=0)
            with open(os.path.join(cp, "classicplus_world_models.sql"), "w", encoding="utf-8", newline="\n") as f:
                f.write(self.sql())
        return rows

    def sql(self):
        out = ["-- Open Vanilla ported models (generated by the model porter; edit content/models, not this file).",
               "-- Creatures for every model; for mounts, the summon spell and the reins item.", ""]
        for e in sorted(self.reg["models"].values(), key=lambda x: x["creature"]):
            c, title = e["creature"], e["title"].replace("'", "''")
            out += [f"-- {e['name']}: display {e['display']}",
                    f"DELETE FROM creature_template WHERE Entry = {c};",
                    "DROP TEMPORARY TABLE IF EXISTS ow_tmp;",
                    "CREATE TEMPORARY TABLE ow_tmp SELECT * FROM creature_template WHERE Entry IN (308, 284, 305) ORDER BY Entry DESC LIMIT 1;",
                    f"UPDATE ow_tmp SET Entry = {c}, Name = '{title}', SubName = NULL, DisplayId1 = {e['display']}, "
                    "DisplayId2 = 0, DisplayId3 = 0, DisplayId4 = 0, DisplayIdProbability1 = 100, "
                    "DisplayIdProbability2 = 0, DisplayIdProbability3 = 0, DisplayIdProbability4 = 0, Scale = 1;",
                    "INSERT INTO creature_template SELECT * FROM ow_tmp;",
                    "DROP TEMPORARY TABLE ow_tmp;"]
            m = e.get("mount")
            if m:
                src = MOUNT_SPELL.get(m["speed"], 458)
                sp, it = m["spell"], m["item"]
                iname = m["item_name"].replace("'", "''")
                desc = f"Summons and dismisses a rideable {title}." + ("  This is a very fast mount." if m["speed"] == "epic" else "")
                out += [f"DELETE FROM spell_template WHERE Id = {sp};",
                        "DROP TEMPORARY TABLE IF EXISTS ow_tmp;",
                        f"CREATE TEMPORARY TABLE ow_tmp SELECT * FROM spell_template WHERE Id = {src};",
                        f"UPDATE ow_tmp SET Id = {sp}, SpellName = '{title}',",
                        f"  EffectMiscValue1 = IF(EffectApplyAuraName1 = 78, {c}, EffectMiscValue1),",
                        f"  EffectMiscValue2 = IF(EffectApplyAuraName2 = 78, {c}, EffectMiscValue2),",
                        f"  EffectMiscValue3 = IF(EffectApplyAuraName3 = 78, {c}, EffectMiscValue3);",
                        "INSERT INTO spell_template SELECT * FROM ow_tmp;",
                        "DROP TEMPORARY TABLE ow_tmp;",
                        f"DELETE FROM item_template WHERE entry = {it};",
                        "DROP TEMPORARY TABLE IF EXISTS ow_tmp;",
                        f"CREATE TEMPORARY TABLE ow_tmp SELECT * FROM item_template WHERE entry = {MOUNT_ITEM.get(m['speed'], 5656)};",
                        f"UPDATE ow_tmp SET entry = {it}, name = '{iname}', spellid_1 = {sp}, "
                        f"Quality = {4 if m['speed'] == 'epic' else 3}, RequiredSkill = 0, RequiredSkillRank = 0, "
                        f"AllowableRace = -1, AllowableClass = -1, RequiredLevel = {60 if m['speed'] == 'epic' else 40}, "
                        f"description = '{desc.replace(chr(39), chr(39) * 2)}';",
                        "INSERT INTO item_template SELECT * FROM ow_tmp;",
                        "DROP TEMPORARY TABLE ow_tmp;"]
            out.append("")
        return "\n".join(out)


MODEL_DBCS = ("creaturemodeldata.dbc", "creaturedisplayinfo.dbc", "spell.dbc")


def patch_files(root):
    """archive path (lower-case key) → (archive path, source file) for the model library."""
    w = {}
    lib = os.path.join(root, "content", "models")
    reg = {}
    if os.path.exists(os.path.join(lib, "registry.json")):
        with open(os.path.join(lib, "registry.json"), encoding="utf-8") as f:
            reg = json.load(f).get("models", {})
    for name in reg:
        base = os.path.join(lib, name, "game")
        for r, _, names in os.walk(base):
            for n in names:
                if n.lower().endswith((".m2", ".blp", ".skin")):
                    full = os.path.join(r, n)
                    arc = os.path.relpath(full, base).replace(os.sep, "\\")
                    w[arc.lower()] = (arc, full)
    dbc = os.path.join(root, "Data", "ClassicPlusDBC")
    if os.path.isdir(dbc):
        for n in os.listdir(dbc):
            if n.lower() in MODEL_DBCS:
                arc = "DBFilesClient\\" + n
                w[arc.lower()] = (arc, os.path.join(dbc, n))
    return w


def is_model_managed(key):
    return key.startswith("creature\\openvanilla\\") or key in {"dbfilesclient\\" + d for d in MODEL_DBCS}


def update_patch(root):
    """Put the library into realm/classicplus/patch-Z.MPQ (pure Python; keeps every other file)."""
    from . import mpq
    path = os.path.join(root, "realm", "classicplus", "patch-Z.MPQ")
    files = {}
    if os.path.exists(path):
        a = mpq.Archive(path)
        for n in a.names():
            if not is_model_managed(n.lower()):
                data = a.read(n)
                if data is not None:
                    files[n] = data
    for _, (arc, full) in patch_files(root).items():
        files[arc] = _readb(full)
    before = os.path.getsize(path) if os.path.exists(path) else 0
    size = mpq.write(path, files)
    return before, size
