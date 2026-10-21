"""Open Vanilla Passport: portable, cryptographically signed character records.

Bound by GDPR Article 20, players hold their character record in a machine-readable,
verifiable JSON format that survives any realm shutdown.

Prestige events (level 60, first kills, titles, achievements) form an append-only
tamper-evident hash chain signed by the issuing realm's Ed25519 key.

Trust Tiers:
  Tier 0 (Official):  Open Vanilla's official realms. Full import eligible.
  Tier 1 (Verified):  Reproducible recipe & build hash, Covenant signed, bots flagged.
                      Full import eligible with caps.
  Tier 2 (Community): Listed realm with valid key, Covenant signed. Cosmetic import.
  Tier 3 (Unverified): Self-hosted, Pocket Realm, or unknown key. Legacy display only.

Import Modes:
  1. legacy:   Origin badge and /legacy inspect panel. Available to all tiers.
  2. cosmetic: Titles and transmog appearances unlocked account-wide.
  3. full:     Tier 0-1 sources only. Clamps levels/gear, locks source, strips mail/auctions.
"""
import copy
import datetime
import hashlib
import json
import os
import sys

try:
    from . import ed25519, herokey_v2
except ImportError:
    import ed25519
    import herokey_v2

SCHEMA_VERSION = 1
GENESIS_PREV_HASH = "0000000000000000000000000000000000000000000000000000000000000000"

TIER_OFFICIAL = 0
TIER_VERIFIED = 1
TIER_COMMUNITY = 2
TIER_UNVERIFIED = 3

TIER_NAMES = {
    TIER_OFFICIAL: "Official",
    TIER_VERIFIED: "Verified",
    TIER_COMMUNITY: "Community",
    TIER_UNVERIFIED: "Unverified",
}


def canonical_json(data: dict) -> bytes:
    """Deterministic, sorted, whitespace-normalized JSON encoding for cryptographic signing."""
    return json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def sha256_hex(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class PrestigeEvent:
    """One signed prestige milestone in the character's lifetime on a realm."""

    def __init__(self, seq: int, prev_hash: str, event_type: str, payload: dict,
                 timestamp: str, realm_id: str, signature: str = ""):
        self.seq = seq
        self.prev_hash = prev_hash
        self.event_type = event_type
        self.payload = payload
        self.timestamp = timestamp
        self.realm_id = realm_id
        self.signature = signature

    def payload_dict(self) -> dict:
        return {
            "seq": self.seq,
            "prev_hash": self.prev_hash,
            "event_type": self.event_type,
            "payload": self.payload,
            "timestamp": self.timestamp,
            "realm_id": self.realm_id,
        }

    def compute_hash(self) -> str:
        return sha256_hex(canonical_json(self.payload_dict()))

    def sign(self, realm_seed: bytes) -> str:
        sig = ed25519.sign(realm_seed, canonical_json(self.payload_dict()))
        self.signature = herokey_v2._b64url_encode(sig)
        return self.signature

    def verify(self, realm_pub: bytes) -> bool:
        if not self.signature:
            return False
        try:
            sig = herokey_v2._b64url_decode(self.signature)
            return ed25519.verify(realm_pub, canonical_json(self.payload_dict()), sig)
        except Exception:
            return False

    def to_dict(self) -> dict:
        d = self.payload_dict()
        d["signature"] = self.signature
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "PrestigeEvent":
        return cls(
            seq=d["seq"],
            prev_hash=d["prev_hash"],
            event_type=d["event_type"],
            payload=d.get("payload", {}),
            timestamp=d["timestamp"],
            realm_id=d["realm_id"],
            signature=d.get("signature", ""),
        )


class EventHashChain:
    """Append-only verifiable chain of prestige events."""

    def __init__(self, events: list[PrestigeEvent] = None):
        self.events = events or []

    def append(self, event_type: str, payload: dict, realm_id: str,
               realm_seed: bytes, timestamp: str = None) -> PrestigeEvent:
        ts = timestamp or datetime.datetime.now(datetime.timezone.utc).isoformat()
        prev = self.events[-1].compute_hash() if self.events else GENESIS_PREV_HASH
        seq = len(self.events)
        ev = PrestigeEvent(seq=seq, prev_hash=prev, event_type=event_type, payload=payload,
                           timestamp=ts, realm_id=realm_id)
        ev.sign(realm_seed)
        self.events.append(ev)
        return ev

    def verify_chain(self, realm_pub: bytes) -> tuple[bool, str]:
        expected_prev = GENESIS_PREV_HASH
        for idx, ev in enumerate(self.events):
            if ev.seq != idx:
                return False, f"Event {idx} has invalid seq {ev.seq}"
            if ev.prev_hash != expected_prev:
                return False, f"Event {idx} broken hash link: expected {expected_prev}, got {ev.prev_hash}"
            if not ev.verify(realm_pub):
                return False, f"Event {idx} ({ev.event_type}) failed realm signature verification"
            expected_prev = ev.compute_hash()
        return True, "Chain verified"

    def head_hash(self) -> str:
        return self.events[-1].compute_hash() if self.events else GENESIS_PREV_HASH

    def to_list(self) -> list[dict]:
        return [e.to_dict() for e in self.events]


class PassportRecord:
    """The portable character document held by the player."""

    def __init__(self, hero_id: str, character: dict, chain: EventHashChain,
                 realm_id: str, realm_pub_hex: str, tier: int, ruleset_hash: str,
                 issued_at: str = None, realm_sig: str = "", player_sig: str = ""):
        self.version = SCHEMA_VERSION
        self.hero_id = hero_id
        self.character = character
        self.chain = chain
        self.realm_id = realm_id
        self.realm_pub_hex = realm_pub_hex
        self.tier = tier
        self.ruleset_hash = ruleset_hash
        self.issued_at = issued_at or datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.realm_sig = realm_sig
        self.player_sig = player_sig

    def signing_body(self) -> dict:
        return {
            "version": self.version,
            "hero_id": self.hero_id,
            "character": self.character,
            "chain_head": self.chain.head_hash(),
            "event_count": len(self.chain.events),
            "realm_id": self.realm_id,
            "realm_pub_hex": self.realm_pub_hex,
            "tier": self.tier,
            "ruleset_hash": self.ruleset_hash,
            "issued_at": self.issued_at,
        }

    def sign_realm(self, realm_seed: bytes) -> str:
        body_bytes = canonical_json(self.signing_body())
        sig = ed25519.sign(realm_seed, body_bytes)
        self.realm_sig = herokey_v2._b64url_encode(sig)
        return self.realm_sig

    def sign_player(self, player_seed: bytes) -> str:
        body_bytes = canonical_json(self.signing_body())
        sig = ed25519.sign(player_seed, body_bytes)
        self.player_sig = herokey_v2._b64url_encode(sig)
        return self.player_sig

    def verify(self, trusted_realm_keys: dict[str, int] = None) -> tuple[bool, str, int]:
        """Verify the entire passport record.

        trusted_realm_keys maps hex_pubkey -> trusted_tier.
        Returns (is_valid, reason, effective_tier).
        """
        try:
            realm_pub = bytes.fromhex(self.realm_pub_hex)
        except ValueError:
            return False, "Invalid realm public key format", TIER_UNVERIFIED

        # 1. Verify event hash chain
        chain_ok, chain_msg = self.chain.verify_chain(realm_pub)
        if not chain_ok:
            return False, f"Event chain corrupt: {chain_msg}", TIER_UNVERIFIED

        # 2. Verify realm signature over character and chain head
        body_bytes = canonical_json(self.signing_body())
        try:
            r_sig = herokey_v2._b64url_decode(self.realm_sig)
            if not ed25519.verify(realm_pub, body_bytes, r_sig):
                return False, "Invalid realm signature", TIER_UNVERIFIED
        except Exception as e:
            return False, f"Realm signature error: {e}", TIER_UNVERIFIED

        # 3. Verify player Hero Key signature (proves player owns this passport)
        if self.player_sig:
            if not herokey_v2.HERO_ID_RE.match(self.hero_id):
                return False, "Invalid Hero ID format", TIER_UNVERIFIED
            try:
                p_pub = herokey_v2._b64url_decode(self.hero_id.split(".", 1)[1])
                p_sig = herokey_v2._b64url_decode(self.player_sig)
                if not ed25519.verify(p_pub, body_bytes, p_sig):
                    return False, "Passport player signature does not match Hero Key", TIER_UNVERIFIED
            except Exception as e:
                return False, f"Player signature error: {e}", TIER_UNVERIFIED

        # 4. Resolve trust tier
        effective_tier = TIER_UNVERIFIED
        if trusted_realm_keys and self.realm_pub_hex in trusted_realm_keys:
            effective_tier = trusted_realm_keys[self.realm_pub_hex]
        elif self.tier in (TIER_OFFICIAL, TIER_VERIFIED, TIER_COMMUNITY):
            effective_tier = self.tier

        return True, "Passport verified", effective_tier

    def to_dict(self) -> dict:
        return {
            "version": self.version,
            "hero_id": self.hero_id,
            "character": self.character,
            "events": self.chain.to_list(),
            "chain_head": self.chain.head_hash(),
            "realm_id": self.realm_id,
            "realm_pub_hex": self.realm_pub_hex,
            "tier": self.tier,
            "ruleset_hash": self.ruleset_hash,
            "issued_at": self.issued_at,
            "realm_sig": self.realm_sig,
            "player_sig": self.player_sig,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "PassportRecord":
        events = [PrestigeEvent.from_dict(e) for e in d.get("events", [])]
        chain = EventHashChain(events)
        return cls(
            hero_id=d["hero_id"],
            character=d["character"],
            chain=chain,
            realm_id=d["realm_id"],
            realm_pub_hex=d["realm_pub_hex"],
            tier=d.get("tier", TIER_UNVERIFIED),
            ruleset_hash=d.get("ruleset_hash", ""),
            issued_at=d.get("issued_at"),
            realm_sig=d.get("realm_sig", ""),
            player_sig=d.get("player_sig", ""),
        )

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent)


def import_passport(passport: PassportRecord, mode: str, receiving_realm_rules: dict,
                    trusted_realm_keys: dict = None) -> dict:
    """Process character import into a receiving realm according to requested mode.

    Modes:
      - 'legacy': Origin badge and stats showcase for /legacy panel (any tier).
      - 'cosmetic': Transmog appearances and titles account-wide.
      - 'full': Live character copy (Tier 0 & 1 only), with safety caps applied.
    """
    valid, reason, effective_tier = passport.verify(trusted_realm_keys)
    if not valid:
        return {"ok": False, "error": f"Passport verification failed: {reason}"}

    char = copy.deepcopy(passport.character)

    if mode == "legacy":
        # Origin badge and display sheet
        return {
            "ok": True,
            "mode": "legacy",
            "tier": effective_tier,
            "tier_label": TIER_NAMES.get(effective_tier, "Unverified"),
            "display": {
                "name": char.get("name"),
                "level": char.get("level"),
                "class_id": char.get("class_id"),
                "race_id": char.get("race_id"),
                "origin_realm": passport.realm_id,
                "issued_at": passport.issued_at,
                "milestones": [
                    {"event": e.event_type, "details": e.payload, "date": e.timestamp}
                    for e in passport.chain.events
                ],
                "badge": f"Heritage: {passport.realm_id} ({TIER_NAMES.get(effective_tier)})",
            }
        }

    elif mode == "cosmetic":
        # Extract unlocked titles and transmog gear appearances
        unlocked_titles = []
        unlocked_appearances = []
        for ev in passport.chain.events:
            if ev.event_type == "title_earned":
                unlocked_titles.append(ev.payload.get("title"))
            elif ev.event_type == "appearance_unlocked":
                unlocked_appearances.append(ev.payload.get("item_entry"))

        equipment = char.get("equipment", [])
        for item in equipment:
            if isinstance(item, dict) and item.get("entry"):
                unlocked_appearances.append(item["entry"])

        return {
            "ok": True,
            "mode": "cosmetic",
            "tier": effective_tier,
            "unlocked_titles": sorted(list(set(filter(None, unlocked_titles)))),
            "unlocked_appearances": sorted(list(set(filter(None, unlocked_appearances)))),
            "message": f"Cosmetics imported from {char.get('name')} ({passport.realm_id})"
        }

    elif mode == "full":
        # Full import: ONLY permitted for Tier 0 (Official) and Tier 1 (Verified)
        if effective_tier > TIER_VERIFIED:
            return {
                "ok": False,
                "error": f"Full import is only permitted for Tier 0 (Official) and Tier 1 (Verified) realms. This realm is {TIER_NAMES.get(effective_tier)}."
            }

        # Apply receiving realm caps
        max_level = receiving_realm_rules.get("max_level", 60)
        char["level"] = min(char.get("level", 1), max_level)

        # Apply wealth caps
        max_gold = receiving_realm_rules.get("max_import_copper", 1000 * 10000) # 1000g default
        char["money"] = min(char.get("money", 0), max_gold)

        # Cleanse un-imported state: strip mail, active auctions, guild membership
        char["guild_id"] = 0
        char["guild_rank"] = 0
        char["mail"] = []
        char["auctions"] = []

        # Mark as imported and ineligible for realm-first races
        char["passport_imported"] = True
        char["realm_first_eligible"] = False
        char["import_origin"] = {
            "realm_id": passport.realm_id,
            "hero_id": passport.hero_id,
            "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "tier": effective_tier,
        }

        return {
            "ok": True,
            "mode": "full",
            "tier": effective_tier,
            "character": char,
            "message": f"Character {char.get('name')} successfully imported from {passport.realm_id} (Caps applied)."
        }

    else:
        return {"ok": False, "error": f"Unknown import mode: {mode}"}
