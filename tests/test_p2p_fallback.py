"""Host for friends ships without the Open Vanilla relay: "Through Open Vanilla" falls back to Direct (after the
IP/privacy explainer) when the relay is switched off in live.json or the directory doesn't answer;
Direct and LAN start as asked and never touch central. Also: Realms\\Hosted via OPENVANILLA_HOST_DIR.

    python -m unittest tests.test_p2p_fallback -v
"""
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "launcher"))
sys.path.insert(0, ROOT)

from p2p import host as H  # noqa: E402


class FallbackTests(unittest.TestCase):
    def test_relay_only_when_enabled_and_reachable(self):
        calls = []

        def probe():
            calls.append(1)
            return True

        self.assertEqual(H.plan_connection("relay", True, probe), ("relay", False))
        self.assertEqual(H.plan_connection("relay", True, lambda: False), ("direct", True))
        self.assertEqual(H.plan_connection("relay", False, probe), ("direct", True))
        self.assertEqual(len(calls), 1, "no probe when the relay is switched off")

    def test_direct_and_lan_never_probe(self):
        def probe():
            raise AssertionError("must not contact central")
        self.assertEqual(H.plan_connection("direct", True, probe), ("direct", False))
        self.assertEqual(H.plan_connection("lan", False, probe), ("lan", False))
        self.assertEqual(H.plan_connection("bogus", False, probe), ("direct", False))

    def test_relay_available_probe(self):
        self.assertTrue(H.relay_available("https://c.test", get=lambda url, t: 200))
        self.assertFalse(H.relay_available("https://c.test", get=lambda url, t: 503))

        def down(url, t):
            raise OSError("getaddrinfo failed")
        self.assertFalse(H.relay_available("https://c.test", get=down))
        seen = []
        H.relay_available("https://c.test/", get=lambda url, t: seen.append(url) or 200)
        self.assertEqual(seen, ["https://c.test/api/directory"])

    def test_direct_config_validates_and_binds_publicly(self):
        cfg = H.HostConfig(name="Friends Realm", connection="direct").validate()
        sess = H.HostSession.__new__(H.HostSession)
        sess.cfg, sess.lan_ip, sess.external_ip = cfg, "192.168.1.5", None
        self.assertTrue(sess.open_ports())
        self.assertEqual(sess.bind_address(), "0.0.0.0")
        self.assertEqual(sess.realm_address(), "192.168.1.5")
        lan = H.HostConfig(name="Friends Realm", connection="lan").validate()
        sess.cfg = lan
        self.assertEqual(sess.bind_address(), "192.168.1.5")

    def test_hosted_folder_from_env(self):
        with mock.patch.dict(os.environ, {"OPENVANILLA_HOST_DIR": os.path.join("X", "Realms", "Hosted")}):
            self.assertEqual(H.default_host_root(), os.path.abspath(os.path.join("X", "Realms", "Hosted")))


if __name__ == "__main__":
    unittest.main()
