"""Tests for Workshop asset validation, licence allowlist, and provenance sidecars."""
import unittest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import workshop_validator


class TestWorkshopValidator(unittest.TestCase):
    def test_permissive_licenses_accepted(self):
        valid_asset = {
            "version": 1,
            "id": "emberwing-mount",
            "name": "Emberwing Drake",
            "role": "mount",
            "license": "CC-BY-4.0",
            "authors": ["Arnesen", "Poly Haven"],
            "budgets": {"triangle_count": 2800}
        }
        ok, msgs = workshop_validator.validate_workshop_sidecar(valid_asset)
        self.assertTrue(ok, msgs)

    def test_banned_no_derivatives_rejected(self):
        nd_asset = {
            "version": 1,
            "id": "restricted-model",
            "name": "Restricted Model",
            "role": "doodad",
            "license": "CC-BY-ND-4.0",
            "authors": ["SomeCreator"]
        }
        ok, msgs = workshop_validator.validate_workshop_sidecar(nd_asset)
        self.assertFalse(ok)
        self.assertTrue(any("not permitted" in m for m in msgs))

    def test_sketchfab_and_hunyuan_rejected(self):
        sk_asset = {
            "version": 1,
            "id": "sketchfab-mesh",
            "name": "Sketchfab Sword",
            "role": "item_weapon",
            "license": "Sketchfab-Standard",
            "authors": ["Uploader"]
        }
        ok, msgs = workshop_validator.validate_workshop_sidecar(sk_asset)
        self.assertFalse(ok)

        hy_asset = {
            "version": 1,
            "id": "ai-mesh",
            "name": "AI Beast",
            "role": "creature",
            "license": "MIT",
            "authors": ["Prompter"],
            "ai_disclosure": {"used_ai": True, "tool": "hunyuan3d"}
        }
        ok, msgs = workshop_validator.validate_workshop_sidecar(hy_asset)
        self.assertFalse(ok)
        self.assertTrue(any("Hunyuan3D" in m for m in msgs))

    def test_excessive_triangles_flagged(self):
        heavy_asset = {
            "version": 1,
            "id": "ultra-rock",
            "name": "Ultra Heavy Rock",
            "role": "doodad", # Budget is 1200, max is 2400
            "license": "CC0-1.0",
            "authors": ["Modeler"],
            "budgets": {"triangle_count": 10000}
        }
        ok, msgs = workshop_validator.validate_workshop_sidecar(heavy_asset)
        self.assertFalse(ok)
        self.assertTrue(any("exceeds maximum budget" in m for m in msgs))


if __name__ == "__main__":
    unittest.main()
