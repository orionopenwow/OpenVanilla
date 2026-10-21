"""Tests for Realm Composer: recipes, conflict detection, and realm cloning."""
import unittest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import realm_composer


class TestRealmComposer(unittest.TestCase):
    def setUp(self):
        self.sample_recipe_data = {
            "version": 1,
            "id": "ironforge-nights",
            "name": "Ironforge Nights",
            "template": "classicplus",
            "packs": [
                {
                    "id": "emberwing-mounts",
                    "file": "packs/emberwing-1.0.ovpack",
                    "hash": "a" * 64,
                },
                {
                    "id": "silvermoon-guard",
                    "file": "packs/silvermoon-1.0.ovpack",
                    "hash": "b" * 64,
                }
            ],
            "rates": {"xp_quest": 1.5, "xp_kill": 1.0},
            "bot_policy": {
                "enabled": True,
                "count": 20,
                "labelled_always": True,
            },
            "import_policy": {
                "allowed_modes": ["legacy", "cosmetic"]
            }
        }

    def test_recipe_validation_and_badge_hash(self):
        recipe = realm_composer.RealmRecipe(self.sample_recipe_data)
        badge = recipe.forge_built_badge_hash()
        self.assertEqual(len(badge), 64)

        # Modifying recipe changes hash
        recipe.data["rates"]["xp_quest"] = 2.0
        badge2 = recipe.forge_built_badge_hash()
        self.assertNotEqual(badge, badge2)

    def test_covenant_violation_caught(self):
        bad_data = dict(self.sample_recipe_data)
        bad_data["bot_policy"] = {"enabled": True, "labelled_always": False}
        with self.assertRaises(ValueError):
            realm_composer.RealmRecipe(bad_data)

    def test_lint_conflicts_and_resolution(self):
        recipe = realm_composer.RealmRecipe(self.sample_recipe_data)

        # Simulate pack content metadata
        pack_meta = {
            "emberwing-mounts": {
                "creatures": [50001, 50002],
                "items": [60001],
                "tiles": ["(0, 32, 48)"],
                "dbc_rows": {"Spell": [80001]},
            },
            "silvermoon-guard": {
                "creatures": [50002, 50003],  # Overlaps creature 50002!
                "items": [60002],
                "tiles": ["(0, 32, 48)"],     # Overlaps tile (0, 32, 48)!
                "dbc_rows": {},
            }
        }

        conflicts = recipe.lint_conflicts(pack_meta)
        self.assertEqual(len(conflicts), 2)
        types = {c.resource_type for c in conflicts}
        self.assertIn("creature", types)
        self.assertIn("tile", types)

        # Later pack in recipe order won by default
        creature_conflict = next(c for c in conflicts if c.resource_type == "creature")
        self.assertEqual(creature_conflict.resolution, "silvermoon-guard")

        # Explicit conflict resolution in recipe
        recipe.data["conflict_resolutions"] = {"creature:50002": "emberwing-mounts"}
        conflicts2 = recipe.lint_conflicts(pack_meta)
        creature_conflict2 = next(c for c in conflicts2 if c.resource_type == "creature")
        self.assertEqual(creature_conflict2.resolution, "emberwing-mounts")

    def test_clone_and_pass_the_torch(self):
        recipe = realm_composer.RealmRecipe(self.sample_recipe_data)

        # Clone realm
        cloned = recipe.clone("ironforge-clone", "Ironforge Clone")
        self.assertEqual(cloned.data["id"], "ironforge-clone")
        self.assertEqual(cloned.data["name"], "Ironforge Clone")
        self.assertIn("cloned_from", cloned.data)

        # Pass the torch bundle
        bundle = recipe.pass_the_torch(
            successor_hero_id="ovh1.XYZ123...",
            character_export_manifest=[{"guid": 1, "name": "Valen"}]
        )
        self.assertEqual(bundle["type"], "pass_the_torch_bundle")
        self.assertEqual(bundle["successor_hero_id"], "ovh1.XYZ123...")
        self.assertEqual(bundle["characters_count"], 1)


if __name__ == "__main__":
    unittest.main()
