"""HOME's decisions without Tk (launcher/home_logic.py): play modes, Solo's next step, the update pill
and the client button.

    python3 -m unittest tests.test_home_logic -v
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "launcher"))

import home_logic as H  # noqa: E402
import live_content  # noqa: E402

ALL_ON = dict(live_content.DEFAULT_FLAGS)


class PlayModeTests(unittest.TestCase):
    def test_all_three_by_default(self):
        self.assertEqual([k for k, _ in H.play_modes(ALL_ON)], ["online", "solo", "browser"])

    def test_flags_hide_modes(self):
        self.assertEqual([k for k, _ in H.play_modes(dict(ALL_ON, solo=False))], ["online", "browser"])
        self.assertEqual([k for k, _ in H.play_modes(dict(ALL_ON, browser_play=False))], ["online", "solo"])

    def test_solo_needs_spp_or_the_enabled_pack(self):
        self.assertNotIn("solo", dict(H.play_modes(ALL_ON, have_spp=False, have_solo_pack=True)))
        self.assertIn("solo", dict(H.play_modes(dict(ALL_ON, solo_pack=True), have_spp=False, have_solo_pack=True)))

    def test_never_empty(self):
        off = {k: False for k in ALL_ON}
        self.assertEqual(H.play_modes(off), [("online", "ONLINE")])

    def test_pick_mode_falls_back_to_the_first(self):
        modes = H.play_modes(dict(ALL_ON, solo=False))
        self.assertEqual(H.pick_mode("solo", modes), "online")
        self.assertEqual(H.pick_mode("browser", modes), "browser")
        self.assertEqual(H.pick_mode(None, modes), "online")


class SoloStepTests(unittest.TestCase):
    def test_walks_the_states(self):
        ok, head, _, _, action = H.solo_step("missing", True, size=114902146)
        self.assertTrue(ok)
        self.assertIn("DOWNLOAD SPP CLASSICS (110 MB)", head)
        self.assertEqual(action, "solo_install")
        self.assertEqual(H.solo_step("downloaded", True)[4], "solo_install")
        self.assertEqual(H.solo_step("unpacked", True)[4], "solo_install")
        self.assertEqual(H.solo_step("base", True)[4], "solo_vanilla")
        self.assertEqual(H.solo_step("ready", True)[4], "solo_play")
        self.assertEqual(H.solo_step("ready", True)[0:2], (True, "READY · SOLO ON THIS PC"))

    def test_ready_without_a_game_asks_for_the_folder(self):
        ok, _, _, _, action = H.solo_step("ready", False)
        self.assertFalse(ok)
        self.assertEqual(action, "choose_install")

    def test_running_disables_play(self):
        self.assertFalse(H.solo_step("ready", True, running=True)[0])

    def test_no_module(self):
        self.assertEqual(H.solo_step(None, False)[0], False)

    def test_checklist(self):
        self.assertEqual([(d, c) for _, d, c in H.solo_checklist("missing")],
                         [(False, True), (False, False), (False, False), (False, False)])
        self.assertEqual([(d, c) for _, d, c in H.solo_checklist("base")],
                         [(True, False), (True, False), (False, True), (False, False)])
        self.assertEqual([(d, c) for _, d, c in H.solo_checklist("ready")],
                         [(True, False), (True, False), (True, False), (False, True)])


class UpdatePillTests(unittest.TestCase):
    M = {"version": "1.17.0"}

    def test_nothing(self):
        self.assertEqual(H.update_pill(None, None, None, True), (None, None))

    def test_ready_wins(self):
        self.assertEqual(H.update_pill(self.M, {"version": "1.17.0"}, {"done": True}, True),
                         ("Update 1.17.0 ready · restart", "apply"))

    def test_downloading_shows_progress(self):
        self.assertEqual(H.update_pill(self.M, None, {"progress": 0.426}, True), ("Downloading update 42%", None))

    def test_failed_offers_retry(self):
        self.assertEqual(H.update_pill(self.M, None, {"done": True, "error": "x"}, True)[1], "retry")

    def test_source_copy_opens_the_page(self):
        self.assertEqual(H.update_pill(self.M, None, None, False), ("Update 1.17.0 available", "page"))

    def test_auto_update_off_offers_the_download(self):
        self.assertEqual(H.update_pill(self.M, None, None, True, auto_update=False)[1], "download")
        self.assertEqual(H.update_pill(self.M, None, None, True, auto_update=True), (None, None))


class ClientButtonTests(unittest.TestCase):
    """HOME's client button (left column, under the account card), as it was before the redesign."""

    def test_stock_1121_client(self):
        self.assertIsNone(H.client_button("exe", False, True))      # hidden for now (HIDE_GET_VANILLA_CLIENT)
        try:
            H.HIDE_GET_VANILLA_CLIENT = False
            self.assertEqual(H.client_button("exe", False, True), ("GET VANILLA CLIENT V1.3", "gold", "install"))
        finally:
            H.HIDE_GET_VANILLA_CLIENT = True
        self.assertEqual(H.client_button("exe", False, False), ("CHOOSE GAME DATA FOLDER", "gold", "install"))
        self.assertEqual(H.client_button("exe", True, True), ("CHANGE WOW FOLDER", "ghost", "get"))
        self.assertEqual(H.client_button("exe", False, True, build=12340), ("SET UP CLIENT", "gold", "get"))

    def test_engine_client(self):
        self.assertEqual(H.client_button("engine", False, True), ("GET CLIENT", "gold", "get"))
        self.assertEqual(H.client_button("engine", False, False), ("SET UP CLIENT", "gold", "get"))
        self.assertEqual(H.client_button("engine", True, True), ("CLIENT DOWNLOAD", "ghost", "get"))

    def test_busy_and_web(self):
        self.assertEqual(H.client_button("exe", False, True, busy=True), ("CANCEL DOWNLOAD", "danger", "cancel"))
        self.assertEqual(H.client_button("engine", False, True, busy=True)[2], "cancel")
        self.assertEqual(H.client_button("exe", True, True, busy=True)[0], "CHANGE WOW FOLDER")   # installed: no cancel
        self.assertEqual(H.client_button("web", False, False), ("OPEN IN BROWSER", "ghost", "web"))

    def test_no_home_cards_any_more(self):
        self.assertFalse(hasattr(H, "home_cards"))

    def test_human_size(self):
        self.assertEqual(H.human_size(114902146), "110 MB")
        self.assertEqual(H.human_size(5 * 1024 * 1024), "5.0 MB")


if __name__ == "__main__":
    unittest.main()
