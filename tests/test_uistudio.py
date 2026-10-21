"""devkit/uistudio/server.py: Layout.lua round trip, the image pipeline, shots and the /move import.

    python -m unittest tests.test_uistudio -v      (needs Pillow and lupa or a lua5.1)
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "devkit", "uistudio"))

try:
    import server as U  # noqa: E402
except Exception as e:  # noqa: BLE001
    U = None
    WHY = str(e)

from PIL import Image  # noqa: E402


@unittest.skipIf(U is None or not (U and U.lua.kind), "UI Studio needs Pillow and Lua 5.1 (lupa)")
class UIStudio(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = (U.LAYOUT, U.MEDIA, U.BLP_DIR, U.STATE_DIR)
        U.LAYOUT = os.path.join(self.tmp.name, "Layout.lua")
        U.MEDIA = os.path.join(self.tmp.name, "Media")
        U.BLP_DIR = os.path.join(self.tmp.name, "blp")
        U.STATE_DIR = os.path.join(self.tmp.name, "state")

    def tearDown(self):
        U.LAYOUT, U.MEDIA, U.BLP_DIR, U.STATE_DIR = self.saved
        self.tmp.cleanup()

    def test_layout_round_trip(self):
        lay = {"theme": {"WINDOW_BG": [0.1, 0.2, 0.3, 0.9], "FONT_SCALE": 1.1, "FONT": "Fonts\\ARIALN.TTF"},
               "frames": {"Loot_Recap.rows.2.text": {"color": [1, 0, 0, 1], "point": ["TOPLEFT", "parent", "TOPLEFT", 4.5, -8]},
                          "end": {"hide": True}},
               "tune": {"Loot.recap.offsetX": 40}, "art": {"Chat_Menu": "Studio_Menu"}}
        U.write_layout(lay)
        back = U.read_layout()
        self.assertEqual(back["frames"]["Loot_Recap.rows.2.text"]["point"][3], 4.5)
        self.assertEqual(back["theme"]["FONT"], "Fonts\\ARIALN.TTF")
        self.assertTrue(back["frames"]["end"]["hide"], "Lua keywords are quoted as keys")
        self.assertEqual(back["art"], {"Chat_Menu": "Studio_Menu"})

    def test_nineslice_makes_a_backdrop(self):
        img = Image.new("RGBA", (64, 48), (0, 0, 255, 255))
        for x in range(64):
            img.putpixel((x, 0), (255, 0, 0, 255))      # a red top edge
        r = U.art_nineslice(img, "Studio_T", 8, 0)
        edge = Image.open(os.path.join(U.MEDIA, "Studio_T_Edge.tga"))
        self.assertEqual(edge.size, (64, 8), "8 pieces in a row")
        self.assertTrue(os.path.isfile(os.path.join(U.BLP_DIR, "Studio_T_Bg.blp")))
        top = edge.convert("RGBA").crop((16, 0, 24, 8))     # piece 3, turned on its side: red along the left
        self.assertGreater(top.getpixel((0, 4))[0], 200)
        self.assertEqual(r["backdrop"]["edge"], "Studio_T_Edge")

    def test_texture_is_a_power_of_two(self):
        r = U.art_texture(Image.new("RGBA", (40, 20), (9, 9, 9, 255)), "Studio_P", "pad", 0)
        self.assertEqual(r["size"], [64, 32])

    def test_shot_renders_with_click_boxes(self):
        r = U.do_render("devkit/uistudio/shots/suite.lua", "loot_recap", 1)
        self.assertFalse(r.get("error"))
        paths = {x["path"] for x in r["rects"]}
        self.assertIn("Loot_Recap", paths)
        self.assertIn("Loot_Recap.title", paths)
        self.assertIn("Loot.recap.offsetX", r["tunables"])

    def test_import_positions(self):
        lay = U.import_positions(U.empty_layout(), [{"frame": "PlayerFrame", "left": 40, "top": 700.5, "scale": 1.2}])
        self.assertEqual(lay["frames"]["PlayerFrame"]["point"], ["TOPLEFT", "UIParent", "BOTTOMLEFT", 40.0, 700.5])
        self.assertEqual(lay["frames"]["PlayerFrame"]["scale"], 1.2)

    def test_every_suite_shot_draws(self):
        for f in U.list_shots():
            if f["file"].endswith("uistudio/shots/suite.lua"):
                for s in f["shots"]:
                    r = U.do_render(f["file"], s, 1)
                    self.assertFalse(r.get("error"), s)


if __name__ == "__main__":
    unittest.main()
