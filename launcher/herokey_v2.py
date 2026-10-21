"""Open Vanilla Passport & Hero Key v2.

Upgrades Hero Keys from a single-realm shared secret (ovk1) to an Ed25519 keypair
(ovk2) that signs portable character records, logs into any community realm via
challenge-response, and supports key rotation without a central authority.

Format:
  Hero Key v2:   ovk2.<10-char key_id>.<32-byte seed base64url>
  Legacy v1:     ovk1.<10-char key_id>.<32-byte secret base64url>
                 (Migrates cleanly: seed derived via HKDF-SHA256)
  Hero ID:       ovh1.<32-byte public key base64url>

Challenge-Response:
  Message: "openvanilla-hero-v1\\nchallenge:<nonce>\\nrealm:<realm_id>\\ntime:<iso8601>"
  Signature: 64-byte Ed25519 signature in base64url.
"""
import base64
import datetime
import hashlib
import hmac
import os
import re
import secrets
import sys

try:
    from . import ed25519
except ImportError:
    import ed25519

KEY_ID_RE = re.compile(r"^[A-Za-z0-9_-]{10}$")
HERO_ID_RE = re.compile(r"^ovh1\.[A-Za-z0-9_-]{43}$")
OVK2_RE = re.compile(r"^ovk2\.([A-Za-z0-9_-]{10})\.([A-Za-z0-9_-]{43})$")
OVK1_RE = re.compile(r"^ovk1\.([A-Za-z0-9_-]{10})\.([A-Za-z0-9_-]{43})$")

HKDF_SALT = b"openvanilla-hero-v1"
HKDF_INFO = b"ed25519-seed"

ARMOR_BEGIN = "-----BEGIN OPEN VANILLA HERO KEY-----"
ARMOR_END = "-----END OPEN VANILLA HERO KEY-----"


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _b64url_decode(s: str) -> bytes:
    pad = (4 - (len(s) % 4)) % 4
    return base64.urlsafe_b64decode((s + "=" * pad).encode("ascii"))


def hkdf_derive_seed(ikm: bytes, salt: bytes = HKDF_SALT, info: bytes = HKDF_INFO) -> bytes:
    """Derive a 32-byte Ed25519 seed from arbitrary input key material via HKDF-SHA256."""
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    t = hmac.new(prk, info + b"\x01", hashlib.sha256).digest()
    return t[:32]


class HeroKeyV2:
    """Ed25519 Hero Key with challenge-response auth and key rotation."""

    def __init__(self, key_id: str, seed: bytes, is_migrated: bool = False):
        if len(seed) != 32:
            raise ValueError("Ed25519 seed must be exactly 32 bytes")
        self.key_id = key_id
        self.seed = seed
        self.is_migrated = is_migrated
        self.public_key = ed25519.public_key(seed)
        self.hero_id = "ovh1." + _b64url_encode(self.public_key)

    @classmethod
    def generate(cls, key_id: str = None) -> "HeroKeyV2":
        """Generate a fresh v2 Hero Key with a cryptographically secure 32-byte seed."""
        kid = key_id or secrets.token_urlsafe(8)[:10].replace("-", "x").replace("_", "y")
        if len(kid) < 10:
            kid = kid.ljust(10, "0")
        seed = os.urandom(32)
        return cls(kid, seed, is_migrated=False)

    @classmethod
    def from_string(cls, raw: str) -> "HeroKeyV2":
        """Parse an ovk2 or legacy ovk1 string."""
        raw = raw.strip()
        m2 = OVK2_RE.match(raw)
        if m2:
            kid, seed_b64 = m2.groups()
            seed = _b64url_decode(seed_b64)
            if len(seed) != 32:
                raise ValueError("Invalid seed length in ovk2 key")
            return cls(kid, seed, is_migrated=False)

        m1 = OVK1_RE.match(raw)
        if m1:
            kid, secret_b64 = m1.groups()
            secret = _b64url_decode(secret_b64)
            if len(secret) != 32:
                raise ValueError("Invalid secret length in ovk1 key")
            seed = hkdf_derive_seed(secret)
            return cls(kid, seed, is_migrated=True)

        raise ValueError("Key must start with 'ovk2.' or 'ovk1.' followed by 10-char ID and base64 payload")

    @classmethod
    def from_armor(cls, text: str) -> "HeroKeyV2":
        """Parse key from an armored file block."""
        lines = [ln.strip() for ln in text.strip().splitlines() if ln.strip()]
        for ln in lines:
            if ln.startswith("ovk2.") or ln.startswith("ovk1."):
                return cls.from_string(ln)
        raise ValueError("No Hero Key found in armored text")

    def to_string(self) -> str:
        """Serialize as an ovk2 key string."""
        return f"ovk2.{self.key_id}.{_b64url_encode(self.seed)}"

    def to_armor(self) -> str:
        """Render a formatted, user-downloadable .ovkey file text."""
        return (
            f"# Open Vanilla Hero Key\n"
            f"# Keep this file safe. It signs your portable character Passport\n"
            f"# and lets you sign in on any Open Vanilla realm without a password.\n"
            f"# Hero ID: {self.hero_id}\n\n"
            f"{ARMOR_BEGIN}\n"
            f"{self.to_string()}\n"
            f"{ARMOR_END}\n"
        )

    def sign_challenge(self, nonce: str, realm_id: str, timestamp: str = None) -> tuple[str, str]:
        """Sign a sign-in challenge. Returns (signature_b64, challenge_message)."""
        ts = timestamp or datetime.datetime.now(datetime.timezone.utc).isoformat()
        message = f"openvanilla-hero-v1\nchallenge:{nonce}\nrealm:{realm_id}\ntime:{ts}"
        sig = ed25519.sign(self.seed, message.encode("utf-8"))
        return _b64url_encode(sig), message

    def sign_message(self, message_bytes: bytes) -> str:
        """Sign arbitrary bytes."""
        sig = ed25519.sign(self.seed, message_bytes)
        return _b64url_encode(sig)

    def rotate_to(self, new_key: "HeroKeyV2", timestamp: str = None) -> dict:
        """Generate a cryptographically signed rotation notice from this key to new_key."""
        ts = timestamp or datetime.datetime.now(datetime.timezone.utc).isoformat()
        statement = (
            f"openvanilla-hero-v1\n"
            f"rotate\n"
            f"from:{self.hero_id}\n"
            f"to:{new_key.hero_id}\n"
            f"time:{ts}"
        )
        sig = ed25519.sign(self.seed, statement.encode("utf-8"))
        return {
            "version": 1,
            "statement": statement,
            "from_hero_id": self.hero_id,
            "to_hero_id": new_key.hero_id,
            "timestamp": ts,
            "signature": _b64url_encode(sig),
        }


def verify_challenge(hero_id: str, challenge_message: str, sig_b64: str) -> bool:
    """Verify challenge response using only the public Hero ID (no secret needed!)."""
    if not HERO_ID_RE.match(hero_id):
        return False
    pub_b64 = hero_id.split(".", 1)[1]
    try:
        pub = _b64url_decode(pub_b64)
        sig = _b64url_decode(sig_b64)
        return ed25519.verify(pub, challenge_message.encode("utf-8"), sig)
    except Exception:
        return False


def verify_rotation(rotation: dict) -> bool:
    """Verify a successor rotation proof."""
    try:
        from_id = rotation["from_hero_id"]
        to_id = rotation["to_hero_id"]
        ts = rotation["timestamp"]
        expected_statement = (
            f"openvanilla-hero-v1\n"
            f"rotate\n"
            f"from:{from_id}\n"
            f"to:{to_id}\n"
            f"time:{ts}"
        )
        if rotation.get("statement") != expected_statement:
            return False
        return verify_challenge(from_id, expected_statement, rotation["signature"])
    except (KeyError, TypeError, ValueError):
        return False
