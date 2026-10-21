"""Tests for Open Vanilla Passport, prestige event hash chain and import modes."""
import unittest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "launcher"))
import herokey_v2
import passport


class TestPassport(unittest.TestCase):
    def setUp(self):
        self.player_key = herokey_v2.HeroKeyV2.generate()
        # Create a mock realm key
        self.realm_seed = os.urandom(32)
        self.realm_pub = herokey_v2.ed25519.public_key(self.realm_seed)
        self.realm_pub_hex = self.realm_pub.hex()

        self.character = {
            "name": "Elysia",
            "level": 60,
            "race_id": 1,   # Human
            "class_id": 2,  # Paladin
            "gender": 1,
            "money": 50000000, # 5000 gold
            "equipment": [
                {"slot": 16, "entry": 19019, "name": "Thunderfury, Blessed Blade of the Windseeker"}
            ]
        }

    def test_event_hash_chain_and_passport_flow(self):
        chain = passport.EventHashChain()
        # Event 0: Level 60
        chain.append("level_milestone", {"level": 60, "zone": "Eastern Plaguelands"},
                     "realm-elysium", self.realm_seed)
        # Event 1: First Kill
        chain.append("first_kill", {"boss": "Ragnaros", "raid": "Molten Core"},
                     "realm-elysium", self.realm_seed)
        # Event 2: Title Earned
        chain.append("title_earned", {"title": "Grand Marshal"},
                     "realm-elysium", self.realm_seed)

        self.assertEqual(len(chain.events), 3)
        ok, msg = chain.verify_chain(self.realm_pub)
        self.assertTrue(ok, msg)

        # Create passport
        p = passport.PassportRecord(
            hero_id=self.player_key.hero_id,
            character=self.character,
            chain=chain,
            realm_id="realm-elysium",
            realm_pub_hex=self.realm_pub_hex,
            tier=passport.TIER_VERIFIED,
            ruleset_hash="a1b2c3d4"
        )
        p.sign_realm(self.realm_seed)
        p.sign_player(self.player_key.seed)

        # Verify passport
        trusted_keys = {self.realm_pub_hex: passport.TIER_VERIFIED}
        valid, reason, tier = p.verify(trusted_keys)
        self.assertTrue(valid, reason)
        self.assertEqual(tier, passport.TIER_VERIFIED)

        # Serialization roundtrip
        json_str = p.to_json()
        p2 = passport.PassportRecord.from_dict(passport.json.loads(json_str))
        valid2, reason2, tier2 = p2.verify(trusted_keys)
        self.assertTrue(valid2, reason2)

    def test_tampered_event_chain_fails(self):
        chain = passport.EventHashChain()
        chain.append("level_milestone", {"level": 60}, "realm-elysium", self.realm_seed)
        chain.append("title_earned", {"title": "Champion"}, "realm-elysium", self.realm_seed)

        # Tamper payload of event 0
        chain.events[0].payload["level"] = 99
        ok, msg = chain.verify_chain(self.realm_pub)
        self.assertFalse(ok)

    def test_import_modes(self):
        chain = passport.EventHashChain()
        chain.append("title_earned", {"title": "Justiciar"}, "realm-alpha", self.realm_seed)
        p = passport.PassportRecord(
            hero_id=self.player_key.hero_id,
            character=self.character,
            chain=chain,
            realm_id="realm-alpha",
            realm_pub_hex=self.realm_pub_hex,
            tier=passport.TIER_VERIFIED,
            ruleset_hash="hash123"
        )
        p.sign_realm(self.realm_seed)
        p.sign_player(self.player_key.seed)
        trusted = {self.realm_pub_hex: passport.TIER_VERIFIED}

        # 1. Legacy mode
        res_legacy = passport.import_passport(p, "legacy", {}, trusted)
        self.assertTrue(res_legacy["ok"])
        self.assertEqual(res_legacy["mode"], "legacy")
        self.assertIn("Heritage: realm-alpha", res_legacy["display"]["badge"])

        # 2. Cosmetic mode
        res_cosmetic = passport.import_passport(p, "cosmetic", {}, trusted)
        self.assertTrue(res_cosmetic["ok"])
        self.assertIn("Justiciar", res_cosmetic["unlocked_titles"])
        self.assertIn(19019, res_cosmetic["unlocked_appearances"])

        # 3. Full mode (with caps applied)
        receiving_rules = {"max_level": 60, "max_import_copper": 1000 * 10000}
        res_full = passport.import_passport(p, "full", receiving_rules, trusted)
        self.assertTrue(res_full["ok"])
        imported_char = res_full["character"]
        self.assertEqual(imported_char["money"], 1000 * 10000) # capped from 5000g to 1000g
        self.assertTrue(imported_char["passport_imported"])
        self.assertFalse(imported_char["realm_first_eligible"])

    def test_unverified_tier_full_import_rejected(self):
        # Unknown/Unverified realm
        chain = passport.EventHashChain()
        p = passport.PassportRecord(
            hero_id=self.player_key.hero_id,
            character=self.character,
            chain=chain,
            realm_id="rogue-realm",
            realm_pub_hex=self.realm_pub_hex,
            tier=passport.TIER_UNVERIFIED,
            ruleset_hash="bad"
        )
        p.sign_realm(self.realm_seed)
        p.sign_player(self.player_key.seed)

        trusted = {} # empty trust list -> becomes Tier 3
        res = passport.import_passport(p, "full", {}, trusted)
        self.assertFalse(res["ok"])
        self.assertIn("only permitted for Tier 0", res["error"])

        # But legacy import works for all tiers!
        res_legacy = passport.import_passport(p, "legacy", {}, trusted)
        self.assertTrue(res_legacy["ok"])


if __name__ == "__main__":
    unittest.main()
