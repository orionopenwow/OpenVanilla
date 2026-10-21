"""Tests for Host API contract and status serialization."""
import unittest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import host_api


class TestHostApi(unittest.TestCase):
    def setUp(self):
        self.state = host_api.RealmState("Test Haven", "classicplus")

    def test_status_contract(self):
        st = self.state.to_status_dict()
        self.assertEqual(st["name"], "Test Haven")
        self.assertEqual(st["status"], "running")
        self.assertEqual(st["players"]["human_count"], 2)
        self.assertEqual(st["players"]["bot_count"], 2)
        self.assertEqual(st["players"]["total"], 4)
        self.assertTrue(st["sleep_wake_enabled"])
        self.assertTrue(st["covenant"]["signed"])
        self.assertTrue(st["covenant"]["bots_labelled"])

    def test_state_lifecycle(self):
        self.state.status = "asleep"
        st = self.state.to_status_dict()
        self.assertEqual(st["status"], "asleep")

        self.state.status = "running"
        self.assertEqual(self.state.to_status_dict()["status"], "running")


if __name__ == "__main__":
    unittest.main()
