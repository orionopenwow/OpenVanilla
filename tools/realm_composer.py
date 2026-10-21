"""Realm Composer: recipe-based realm creation, pack conflict resolution, and continuity.

A realm is defined as a deterministic recipe (realm.json):
  - Base template (Blizzlike, Classic+-light, Hardcore, Instant-60, Creative, Solo)
  - Rates and rules
  - Ordered list of pinned .ovpack content hashes
  - Bot policy (with mandatory labelling)
  - Phase calendar (dated progression milestones)
  - Character Passport import policy

Provides:
  - Recipe validation
  - Pack conflict linter (creatures, items, DBC rows, ADT tiles) with explicit 'which wins'
  - 'Clone this realm' export
  - 'Pass the torch' succession bundle
  - Verifiable 'Forge-built' badge hash
"""
import copy
import hashlib
import json
import os
import re
import sys

VALID_TEMPLATES = {
    "blizzlike",
    "classicplus",
    "hardcore",
    "instant60_pvp",
    "creative_sandbox",
    "solo_companion",
}

ID_RE = re.compile(r"^[a-z0-9_-]{3,32}$")


class PackConflict:
    def __init__(self, resource_type: str, resource_id: str, pack_a: str, pack_b: str, resolution: str = None):
        self.resource_type = resource_type  # 'creature', 'item', 'dbc_row', 'tile'
        self.resource_id = str(resource_id)
        self.pack_a = pack_a
        self.pack_b = pack_b
        self.resolution = resolution or pack_b  # Default later pack in order wins

    def to_dict(self) -> dict:
        return {
            "resource_type": self.resource_type,
            "resource_id": self.resource_id,
            "conflicting_packs": [self.pack_a, self.pack_b],
            "winner": self.resolution,
        }


class RealmRecipe:
    def __init__(self, data: dict):
        self.data = data
        self.validate()

    def validate(self):
        d = self.data
        if d.get("version") != 1:
            raise ValueError("Recipe version must be 1")
        if not ID_RE.match(d.get("id", "")):
            raise ValueError(f"Invalid realm id: {d.get('id')}")
        if not d.get("name") or len(d["name"]) < 3 or len(d["name"]) > 40:
            raise ValueError("Realm name must be between 3 and 40 characters")
        if d.get("template") not in VALID_TEMPLATES:
            raise ValueError(f"Unknown template: {d.get('template')}")
        if not isinstance(d.get("packs"), list):
            raise ValueError("packs must be an array")

        # Bot policy verification: bots are ALWAYS labelled
        bots = d.get("bot_policy", {})
        if bots.get("enabled"):
            if not bots.get("labelled_always", True):
                raise ValueError("Covenant violation: bot_policy.labelled_always must be True")

    @classmethod
    def load_file(cls, path: str) -> "RealmRecipe":
        with open(path, "r", encoding="utf-8") as f:
            return cls(json.load(f))

    def save_file(self, path: str):
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.data, f, indent=2, sort_keys=True)

    def forge_built_badge_hash(self) -> str:
        """Deterministic SHA256 of the recipe data, granting the directory 'Forge-built' badge."""
        canonical = json.dumps(self.data, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        return hashlib.sha256(canonical).hexdigest()

    def lint_conflicts(self, pack_metadata: dict[str, dict]) -> list[PackConflict]:
        """Detect conflicts between packs specified in the recipe.

        pack_metadata maps pack_id -> dict with keys:
          'creatures': set/list of creature IDs
          'items': set/list of item IDs
          'dbc_rows': dict of {dbc_name: [record_ids]}
          'tiles': set/list of map tile coords '(map, x, y)'
        """
        conflicts = []
        resolutions = self.data.get("conflict_resolutions", {})

        seen_creatures = {}
        seen_items = {}
        seen_tiles = {}
        seen_dbc = {}

        for p in self.data.get("packs", []):
            pid = p.get("id") or p.get("file")
            meta = pack_metadata.get(pid, {})

            # Creatures
            for c in meta.get("creatures", []):
                key = f"creature:{c}"
                if c in seen_creatures:
                    winner = resolutions.get(key, pid)
                    conflicts.append(PackConflict("creature", c, seen_creatures[c], pid, winner))
                seen_creatures[c] = pid

            # Items
            for item in meta.get("items", []):
                key = f"item:{item}"
                if item in seen_items:
                    winner = resolutions.get(key, pid)
                    conflicts.append(PackConflict("item", item, seen_items[item], pid, winner))
                seen_items[item] = pid

            # Tiles
            for tile in meta.get("tiles", []):
                key = f"tile:{tile}"
                if tile in seen_tiles:
                    winner = resolutions.get(key, pid)
                    conflicts.append(PackConflict("tile", str(tile), seen_tiles[tile], pid, winner))
                seen_tiles[tile] = pid

            # DBC rows
            for dbc_name, rows in meta.get("dbc_rows", {}).items():
                for row_id in rows:
                    key = f"dbc:{dbc_name}:{row_id}"
                    if key in seen_dbc:
                        winner = resolutions.get(key, pid)
                        conflicts.append(PackConflict(f"dbc:{dbc_name}", row_id, seen_dbc[key], pid, winner))
                    seen_dbc[key] = pid

        return conflicts

    def clone(self, new_id: str, new_name: str) -> "RealmRecipe":
        """Generate a clean clone recipe from this realm."""
        cloned = copy.deepcopy(self.data)
        cloned["id"] = new_id
        cloned["name"] = new_name
        cloned["cloned_from"] = {
            "original_id": self.data["id"],
            "badge_hash": self.forge_built_badge_hash(),
        }
        return RealmRecipe(cloned)

    def pass_the_torch(self, successor_hero_id: str, character_export_manifest: list = None) -> dict:
        """Create a complete realm handover succession bundle for a new host."""
        return {
            "version": 1,
            "type": "pass_the_torch_bundle",
            "realm_id": self.data["id"],
            "realm_name": self.data["name"],
            "recipe": self.data,
            "badge_hash": self.forge_built_badge_hash(),
            "successor_hero_id": successor_hero_id,
            "characters_count": len(character_export_manifest or []),
            "characters_manifest": character_export_manifest or [],
            "instructions": (
                "1. Place this bundle and the accompanying encrypted DB backup on the successor host.\n"
                "2. Run 'ovhost restore' or 'python -m tools.realm_composer import-torch'.\n"
                "3. The realm will boot with the exact same pinned recipe and character progression intact."
            ),
        }
