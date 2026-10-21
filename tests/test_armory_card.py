"""Tests for Armory Card, OpenGraph metadata, and oEmbed responses."""
import unittest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import armory_card


class TestArmoryCard(unittest.TestCase):
    def setUp(self):
        self.char = {
            "name": "Aethelgard",
            "level": 60,
            "race_id": 1,   # Human
            "class_id": 2,  # Paladin
            "top_title": "Grand Marshal",
        }

    def test_svg_card_rendering(self):
        svg = armory_card.render_card_svg(self.char, "Stormwind Nights", "Verified", True)
        self.assertIn("Aethelgard", svg)
        self.assertIn("Level 60 Human Paladin", svg)
        self.assertIn("Stormwind Nights", svg)
        self.assertIn("★ Grand Marshal", svg)
        self.assertIn("VERIFIED", svg)
        self.assertTrue(svg.startswith("<svg"))
        self.assertTrue(svg.endswith("</svg>"))

    def test_opengraph_html(self):
        og = armory_card.render_opengraph_html(
            self.char, "Stormwind Nights",
            "https://openvanilla.app/c/stormwind/aethelgard/card.png",
            "https://openvanilla.app/c/stormwind/aethelgard"
        )
        self.assertIn("og:title", og)
        self.assertIn("Aethelgard · Stormwind Nights", og)
        self.assertIn("og:image", og)

    def test_oembed_json(self):
        oembed = armory_card.render_oembed_json(
            self.char, "Stormwind Nights",
            "https://openvanilla.app/c/stormwind/aethelgard",
            "https://openvanilla.app/c/stormwind/aethelgard/card.png",
            maxwidth=400
        )
        self.assertEqual(oembed["version"], "1.0")
        self.assertEqual(oembed["type"], "rich")
        self.assertEqual(oembed["width"], 400)
        self.assertIn("<iframe", oembed["html"])


if __name__ == "__main__":
    unittest.main()
