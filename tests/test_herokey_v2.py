"""Tests for Open Vanilla Hero Key v2 & key rotation."""
import unittest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "launcher"))
import herokey_v2


class TestHeroKeyV2(unittest.TestCase):
    def test_test_vector_compatibility(self):
        # Matches wenilla-realm patch 0031 test vector exactly:
        secret = bytes(range(32))
        seed = herokey_v2.hkdf_derive_seed(secret)
        self.assertEqual(len(seed), 32)
        
        # Test loading from ovk1
        ovk1_str = "ovk1.testuser01." + herokey_v2._b64url_encode(secret)
        k = herokey_v2.HeroKeyV2.from_string(ovk1_str)
        self.assertTrue(k.is_migrated)
        self.assertEqual(k.hero_id, "ovh1.GVSN6lA0SzCD8nQfZIyrChuVy5ERLpDJNQT1xssI-Sg")

        # Test challenge vector
        sig = herokey_v2.ed25519.sign(seed, b"openvanilla-hero-v1\nchallenge:abc")
        self.assertEqual(
            herokey_v2._b64url_encode(sig),
            "N-HLEYmR5g_4FCo_me8yAcKGnFyzI2zaH9K0paTp1zG4itrnvcjtF9CtCh1do9HWOQXvKT81o2C7K0mE3usdCA"
        )

    def test_generate_and_challenge_response(self):
        k = herokey_v2.HeroKeyV2.generate()
        self.assertFalse(k.is_migrated)
        self.assertTrue(k.hero_id.startswith("ovh1."))
        self.assertEqual(len(k.hero_id), 48)

        # Sign challenge
        sig_b64, msg = k.sign_challenge("nonce123", "realm-alpha")
        self.assertIn("challenge:nonce123", msg)
        self.assertIn("realm:realm-alpha", msg)

        # Verify challenge
        self.assertTrue(herokey_v2.verify_challenge(k.hero_id, msg, sig_b64))

        # Tampered message fails
        tampered_msg = msg.replace("nonce123", "nonce999")
        self.assertFalse(herokey_v2.verify_challenge(k.hero_id, tampered_msg, sig_b64))

        # Tampered signature fails
        bad_sig = "A" + sig_b64[1:]
        self.assertFalse(herokey_v2.verify_challenge(k.hero_id, msg, bad_sig))

    def test_key_rotation(self):
        k1 = herokey_v2.HeroKeyV2.generate()
        k2 = herokey_v2.HeroKeyV2.generate()

        rot = k1.rotate_to(k2)
        self.assertEqual(rot["from_hero_id"], k1.hero_id)
        self.assertEqual(rot["to_hero_id"], k2.hero_id)
        self.assertTrue(herokey_v2.verify_rotation(rot))

        # Tampered rotation fails
        k3 = herokey_v2.HeroKeyV2.generate()
        rot["to_hero_id"] = k3.hero_id
        self.assertFalse(herokey_v2.verify_rotation(rot))

    def test_armor_roundtrip(self):
        k = herokey_v2.HeroKeyV2.generate()
        armor = k.to_armor()
        self.assertIn(herokey_v2.ARMOR_BEGIN, armor)
        self.assertIn(herokey_v2.ARMOR_END, armor)
        self.assertIn(k.hero_id, armor)

        k_loaded = herokey_v2.HeroKeyV2.from_armor(armor)
        self.assertEqual(k.hero_id, k_loaded.hero_id)
        self.assertEqual(k.seed, k_loaded.seed)


if __name__ == "__main__":
    unittest.main()
