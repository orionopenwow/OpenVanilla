"""Tests for orion_receipts. Run: python3 test_orion_receipts.py"""
import copy
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orion_receipts as orx  # noqa: E402

NOW = 1_800_000_000 - 1_800_000_000 % 86400 + 20 * 3600     # 20:00 on some day


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.realm_priv = orx.new_key()
        self.other_realm = orx.new_key()
        fed = {"classicplus": orx.pub_of(self.realm_priv), "pure": orx.pub_of(self.other_realm)}
        self.L = orx.Ledger(":memory:", "classicplus", fed)
        self.host = orx.Wallet(os.path.join(self.tmp, "host.json"))
        self.host.set_cert("classicplus", self.L.register_key(self.realm_priv, 1, self.host.pub, "10.0.1", NOW))
        self.peers = []
        for i in range(6):
            k = orx.new_key()
            cert = self.L.register_key(self.realm_priv, 100 + i, orx.pub_of(k), "10.9.%d" % i, NOW)
            self.peers.append((k, cert, 100 + i))

    def rc(self, peer=0, win=None, kind="relay", nbytes=200_000, realm="classicplus", online=True):
        k, cert, acct = self.peers[peer]
        win = orx.window_of(win if win is not None else NOW - 3600)
        if online:
            self.L.mark_presence(acct, win)
        return orx.make_receipt(k, cert, kind, self.host.pub, realm, win, nbytes)

    def redeem(self, rs):
        return self.L.redeem(1, self.host.cert("classicplus"), rs, NOW)


class Receipts(Base):
    def test_good_receipt(self):
        r = self.redeem([self.rc()])
        self.assertEqual(len(r["accepted"]), 1)
        self.assertAlmostEqual(r["hours"], 300 / 3600.0, places=4)

    def test_tampered_bytes(self):
        x = self.rc()
        x["body"]["bytes"] = 10**9
        self.assertEqual(self.redeem([x])["rejected"][0][1], "signature")

    def test_replay_and_renonce(self):
        a = self.rc()
        self.redeem([a])
        self.assertEqual(self.redeem([copy.deepcopy(a)])["rejected"][0][1], "duplicate")
        b = self.rc(win=a["body"]["window"], online=False)      # same window, fresh nonce
        self.assertEqual(self.redeem([b])["rejected"][0][1], "duplicate")

    def test_self_signed(self):
        cert = self.host.cert("classicplus")
        r = orx.make_receipt(self.host.priv, cert, "relay", self.host.pub, "classicplus", NOW - 3600, 200_000)
        self.L.mark_presence(1, NOW - 3600)
        self.assertEqual(self.redeem([r])["rejected"][0][1], "self-signed")

    def test_same_network(self):
        k = orx.new_key()
        cert = self.L.register_key(self.realm_priv, 555, orx.pub_of(k), "10.0.1", NOW)   # host's /24
        self.L.mark_presence(555, NOW - 3600)
        r = orx.make_receipt(k, cert, "relay", self.host.pub, "classicplus", NOW - 3600, 200_000)
        self.assertEqual(self.redeem([r])["rejected"][0][1], "same network")

    def test_uncertified_peer(self):
        k = orx.new_key()
        rogue = orx.issue_cert(orx.new_key(), "classicplus", 777, orx.pub_of(k), NOW)
        r = orx.make_receipt(k, rogue, "relay", self.host.pub, "classicplus", NOW - 3600, 200_000)
        self.assertEqual(self.redeem([r])["rejected"][0][1], "peer certificate")

    def test_federated_realm(self):
        k = orx.new_key()
        cert = orx.issue_cert(self.other_realm, "pure", 42, orx.pub_of(k), NOW)
        r = orx.make_receipt(k, cert, "seed", self.host.pub, "pure", NOW - 3600, 300_000)
        self.assertEqual(len(self.redeem([r])["accepted"]), 1)    # presence is the other realm's job

    def test_offline_peer(self):
        self.assertEqual(self.redeem([self.rc(online=False)])["rejected"][0][1], "peer not online")

    def test_small_future_old(self):
        self.assertEqual(self.redeem([self.rc(nbytes=10)])["rejected"][0][1], "too small")
        self.assertEqual(self.redeem([self.rc(win=NOW + 900)])["rejected"][0][1], "bad window")
        self.assertEqual(self.redeem([self.rc(win=NOW - 40 * 86400)])["rejected"][0][1], "too old")

    def test_wrong_host(self):
        other = orx.Wallet(os.path.join(self.tmp, "other.json"))
        k, cert, acct = self.peers[0]
        self.L.mark_presence(acct, NOW - 3600)
        r = orx.make_receipt(k, cert, "relay", other.pub, "classicplus", NOW - 3600, 200_000)
        self.assertEqual(self.redeem([r])["rejected"][0][1], "not this host")

    def test_caps(self):
        rs = [self.rc(peer=0, win=NOW - 19 * 3600 + i * 300) for i in range(36)]  # 3 hours
        r = self.redeem(rs)
        self.assertAlmostEqual(r["hours"], orx.CAP_PEER_HOST_DAY, places=4)

    def test_pause_after_rejects(self):
        bad = []
        for _ in range(3):
            x = self.rc()
            x["body"]["bytes"] += 1
            bad.append(x)
        self.redeem(bad)
        self.assertTrue(self.redeem([self.rc(peer=1)])["paused"])


class Perks(Base):
    def fill(self, peers, hours_each):
        rs = []
        n = int(hours_each * 12)
        for p in peers:
            for i in range(n):
                rs.append(self.rc(peer=p, win=NOW - 19 * 3600 + i * 300))
        return self.redeem(rs)

    def test_diversity(self):
        self.fill([0], 2)                                     # 2 h from one signer -> 1/5 credit
        self.assertAlmostEqual(self.L.guardian_hours(1, 1, NOW), 0.4, places=3)

    def test_badge_and_queue(self):
        self.fill([0, 1, 2, 3, 4], 2)                         # 10 h, 5 signers -> full
        p = self.L.perks_for(1, NOW)
        self.assertTrue(p["badge"])
        self.assertFalse(p["queue_skip"])
        self.assertEqual(p["rested_pct"], 50.0)
        self.L.mark_paid(1, 10, NOW)
        self.assertEqual(self.L.perks_for(1, NOW)["rested_pct"], 0)
        self.assertTrue(self.L.perks_for(1, NOW)["badge"])    # thresholds aren't consumed

    def test_pure_realm_perks(self):
        self.L.perks = orx.PURE_PERKS
        self.fill([0, 1, 2, 3, 4], 2)
        self.assertEqual(set(self.L.perks_for(1, NOW)), {"badge", "unpaid_hours"})


class WalletFile(Base):
    def test_roundtrip_and_forget(self):
        r = self.rc()
        self.assertTrue(self.host.add(r))
        w2 = orx.Wallet(self.host.path)
        self.assertEqual(w2.pub, self.host.pub)
        self.assertEqual(len(w2.pending("classicplus")), 1)
        rep = self.L.redeem(1, w2.cert("classicplus"), w2.pending(), NOW)
        w2.forget(rep["accepted"])
        self.assertEqual(len(orx.Wallet(self.host.path).pending()), 0)

    def test_key_rebind_refused(self):
        with self.assertRaises(ValueError):
            self.L.register_key(self.realm_priv, 999, self.host.pub, None, NOW)


if __name__ == "__main__":
    unittest.main(verbosity=1)
