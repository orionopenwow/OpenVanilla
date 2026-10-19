"""
orion_receipts.py  (Open Vanilla / Orion Network)

Proof-of-Uptime receipts: a peer that was helped (relayed traffic, seeded patch chunks) signs a
5-minute receipt for the host that helped it. The host keeps receipts in its wallet file and
uploads them when it logs in; the realm verifies them offline and turns them into Guardian hours.

Keys
  wallet key   Ed25519, one per player client
  realm key    Ed25519, one per realm; signs a certificate binding a wallet key to an account
  federation   a list of trusted realm public keys (realm_id -> pub)

Everything signed is canonical JSON: sorted keys, no spaces, UTF-8.
Requires: cryptography
"""

import base64
import hashlib
import json
import os
import sqlite3
import time

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization

VERSION = 1
WINDOW = 300                     # seconds per receipt bucket
MAX_AGE = 30 * 86400             # receipts older than this are refused
MIN_BYTES = {"relay": 64 * 1024, "seed": 256 * 1024}
HOURS_PER_RECEIPT = WINDOW / 3600.0
CAP_PEER_HOST_DAY = 2.0          # one peer can give one host at most this many hours a day
CAP_PEER_DAY = 6.0               # one peer can give all hosts together at most this a day
FULL_CREDIT_SIGNERS = 5          # distinct signers in a day for full credit
REJECTS_TO_PAUSE = 3             # bad receipts in a day before redemption pauses
PAUSE_SECONDS = 86400


# -- encoding ---------------------------------------------------------------------------------
def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def pub_of(priv):
    return b64(priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))


def new_key():
    return Ed25519PrivateKey.generate()


def key_to_text(priv):
    return b64(priv.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                  serialization.NoEncryption()))


def key_from_text(s):
    return Ed25519PrivateKey.from_private_bytes(unb64(s))


def sign(priv, body):
    return b64(priv.sign(canon(body)))


def verify(pub, body, sig):
    try:
        Ed25519PublicKey.from_public_bytes(unb64(pub)).verify(unb64(sig), canon(body))
        return True
    except (InvalidSignature, ValueError):
        return False


# -- certificates -----------------------------------------------------------------------------
def issue_cert(realm_priv, realm_id, account_id, wallet_pub, now=None):
    body = {"v": VERSION, "realm": realm_id, "account": int(account_id), "key": wallet_pub,
            "issued": int(now if now is not None else time.time())}
    return {"body": body, "sig": sign(realm_priv, body)}


def check_cert(cert, federation):
    """federation: {realm_id: realm_pub}. Returns the body or None."""
    try:
        body = cert["body"]
        pub = federation.get(body["realm"])
        return body if pub and verify(pub, body, cert["sig"]) else None
    except (KeyError, TypeError):
        return None


# -- receipts ---------------------------------------------------------------------------------
def window_of(t):
    return int(t) - int(t) % WINDOW


def make_receipt(peer_priv, peer_cert, kind, host_pub, realm_id, window, nbytes):
    if kind not in MIN_BYTES:
        raise ValueError("kind must be relay or seed")
    body = {"v": VERSION, "type": kind, "host": host_pub, "peer": pub_of(peer_priv),
            "realm": realm_id, "window": window_of(window), "bytes": int(nbytes),
            "nonce": b64(os.urandom(8))}
    return {"body": body, "sig": sign(peer_priv, body), "cert": peer_cert}


def receipt_hash(r):
    # Hash covers (host, peer, realm, window, type) only: the same peer cannot be re-signed for
    # the same host and window with a fresh nonce to double-count.
    b = r["body"]
    key = {"type": b["type"], "host": b["host"], "peer": b["peer"], "realm": b["realm"], "window": b["window"]}
    return hashlib.sha256(canon(key)).hexdigest()


# -- wallet file (the host's side) ------------------------------------------------------------
class Wallet:
    def __init__(self, path):
        self.path = path
        if os.path.exists(path):
            with open(path) as f:
                d = json.load(f)
        else:
            d = {"v": VERSION, "key": key_to_text(new_key()), "certs": {}, "receipts": []}
        self.d = d
        self.priv = key_from_text(d["key"])
        self.pub = pub_of(self.priv)

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.d, f)
        os.replace(tmp, self.path)

    def set_cert(self, realm_id, cert):
        self.d["certs"][realm_id] = cert
        self.save()

    def cert(self, realm_id):
        return self.d["certs"].get(realm_id)

    def add(self, receipt):
        if receipt["body"].get("host") != self.pub:
            return False
        self.d["receipts"].append(receipt)
        self.save()
        return True

    def pending(self, realm_id=None):
        return [r for r in self.d["receipts"] if realm_id is None or r["body"]["realm"] == realm_id]

    def forget(self, hashes):
        hs = set(hashes)
        self.d["receipts"] = [r for r in self.d["receipts"] if receipt_hash(r) not in hs]
        self.save()


# -- realm ledger (the server's side) ---------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS orion_keys (
  key TEXT PRIMARY KEY, account INTEGER NOT NULL, realm TEXT NOT NULL,
  net TEXT, issued INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS orion_receipts (
  hash TEXT PRIMARY KEY, host_account INTEGER NOT NULL, peer_account INTEGER NOT NULL,
  realm TEXT NOT NULL, kind TEXT NOT NULL, win INTEGER NOT NULL, day INTEGER NOT NULL,
  hours REAL NOT NULL, redeemed INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS orion_receipts_day ON orion_receipts(day, peer_account);
CREATE TABLE IF NOT EXISTS orion_rejects (
  account INTEGER NOT NULL, at INTEGER NOT NULL, reason TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS orion_presence (
  account INTEGER NOT NULL, win INTEGER NOT NULL, PRIMARY KEY (account, win));
CREATE TABLE IF NOT EXISTS orion_paid (
  account INTEGER NOT NULL, perk TEXT NOT NULL, amount REAL NOT NULL, at INTEGER NOT NULL);
"""

DEFAULT_PERKS = {
    # perk: (threshold hours, window days) or rate for paid perks
    "badge": {"hours": 10, "days": 30},
    "queue_skip": {"hours": 20, "days": 7},
    "rested": {"pct_per_hour": 5, "cap_pct": 150},
}
PURE_PERKS = {k: DEFAULT_PERKS[k] for k in ("badge",)}


class Ledger:
    """
    realm_id   this realm's id
    federation {realm_id: pub} of realms whose certificates are trusted (includes this one)
    account_ok callable(account) -> bool: old enough to sign (level 10 or 7 days), not banned
    """

    def __init__(self, db_path, realm_id, federation, account_ok=None, perks=None):
        self.db = sqlite3.connect(db_path)
        self.db.executescript(SCHEMA)
        self.realm_id = realm_id
        self.federation = dict(federation)
        self.account_ok = account_ok or (lambda a: True)
        self.perks = perks if perks is not None else DEFAULT_PERKS

    # The realm issues a certificate the first time a client presents a wallet key at login.
    def register_key(self, realm_priv, account, wallet_pub, net=None, now=None):
        now = int(now if now is not None else time.time())
        row = self.db.execute("SELECT account FROM orion_keys WHERE key=?", (wallet_pub,)).fetchone()
        if row and row[0] != account:
            raise ValueError("wallet key already bound to another account")
        self.db.execute("INSERT OR IGNORE INTO orion_keys VALUES (?,?,?,?,?)",
                        (wallet_pub, account, self.realm_id, net, now))
        self.db.commit()
        return issue_cert(realm_priv, self.realm_id, account, wallet_pub, now)

    def mark_presence(self, account, t):
        self.db.execute("INSERT OR IGNORE INTO orion_presence VALUES (?,?)", (account, window_of(t)))
        self.db.commit()

    def _present(self, account, win):
        return self.db.execute("SELECT 1 FROM orion_presence WHERE account=? AND win=?",
                               (account, win)).fetchone() is not None

    def _net(self, key):
        r = self.db.execute("SELECT net FROM orion_keys WHERE key=?", (key,)).fetchone()
        return r[0] if r else None

    def paused(self, account, now):
        n = self.db.execute("SELECT COUNT(*) FROM orion_rejects WHERE account=? AND at>?",
                            (account, now - PAUSE_SECONDS)).fetchone()[0]
        return n >= REJECTS_TO_PAUSE

    def _reject(self, account, now, reason):
        self.db.execute("INSERT INTO orion_rejects VALUES (?,?,?)", (account, now, reason))

    def _given(self, peer_account, day, host_account=None):
        q = "SELECT COALESCE(SUM(hours),0) FROM orion_receipts WHERE peer_account=? AND day=?"
        a = [peer_account, day]
        if host_account is not None:
            q += " AND host_account=?"
            a.append(host_account)
        return self.db.execute(q, a).fetchone()[0]

    def redeem(self, host_account, host_cert, receipts, now=None):
        """Verify a host's uploaded receipts. Returns a report with accepted/rejected hashes."""
        now = int(now if now is not None else time.time())
        report = {"accepted": [], "rejected": [], "hours": 0.0, "paused": False}
        if self.paused(host_account, now):
            report["paused"] = True
            return report
        hc = check_cert(host_cert, self.federation)
        if not hc or hc["account"] != host_account:
            self._reject(host_account, now, "host certificate")
            self.db.commit()
            report["rejected"].append(("*", "host certificate"))
            return report
        host_key = hc["key"]
        host_net = self._net(host_key)

        for r in receipts:
            reason = self._check(r, host_account, host_key, host_net, now)
            h = receipt_hash(r) if isinstance(r, dict) and "body" in r else "?"
            if reason:
                report["rejected"].append((h, reason))
                if reason not in ("duplicate", "too old"):     # honest leftovers aren't punished
                    self._reject(host_account, now, reason)
                continue
            b = r["body"]
            peer_account = check_cert(r["cert"], self.federation)["account"]
            day = b["window"] // 86400
            room = min(CAP_PEER_HOST_DAY - self._given(peer_account, day, host_account),
                       CAP_PEER_DAY - self._given(peer_account, day))
            hours = max(0.0, min(HOURS_PER_RECEIPT, room))
            self.db.execute("INSERT INTO orion_receipts VALUES (?,?,?,?,?,?,?,?,?)",
                            (h, host_account, peer_account, b["realm"], b["type"], b["window"], day,
                             hours, now))
            report["accepted"].append(h)
            report["hours"] += hours
        self.db.commit()
        report["hours"] = round(report["hours"], 4)
        return report

    def _check(self, r, host_account, host_key, host_net, now):
        try:
            b, sig, cert = r["body"], r["sig"], r["cert"]
            if b.get("v") != VERSION or b.get("type") not in MIN_BYTES:
                return "format"
        except (KeyError, TypeError):
            return "format"
        if b["host"] != host_key:
            return "not this host"
        pc = check_cert(cert, self.federation)
        if not pc or pc["key"] != b["peer"]:
            return "peer certificate"
        if not verify(b["peer"], b, sig):
            return "signature"
        if pc["account"] == host_account:
            return "self-signed"
        if host_net and self._net(b["peer"]) == host_net:
            return "same network"
        if b["window"] % WINDOW or b["window"] > now:
            return "bad window"
        if now - b["window"] > MAX_AGE:
            return "too old"
        if b["bytes"] < MIN_BYTES[b["type"]]:
            return "too small"
        if self.db.execute("SELECT 1 FROM orion_receipts WHERE hash=?", (receipt_hash(r),)).fetchone():
            return "duplicate"
        if b["realm"] == self.realm_id and not self._present(pc["account"], b["window"]):
            return "peer not online"
        if not self.account_ok(pc["account"]):
            return "peer too new"
        return None

    # -- Guardian hours and perks ---------------------------------------------------------------
    def guardian_hours(self, account, days, now=None):
        """Hours over the last `days`, each day scaled by distinct signers (full at 5)."""
        now = int(now if now is not None else time.time())
        since = (now - days * 86400) // 86400
        rows = self.db.execute(
            "SELECT day, SUM(hours), COUNT(DISTINCT peer_account) FROM orion_receipts "
            "WHERE host_account=? AND day>? GROUP BY day", (account, since)).fetchall()
        total = 0.0
        for _day, hours, signers in rows:
            total += hours * min(1.0, signers / float(FULL_CREDIT_SIGNERS))
        return round(total, 4)

    def perks_for(self, account, now=None):
        now = int(now if now is not None else time.time())
        out = {}
        p = self.perks
        if "badge" in p:
            out["badge"] = self.guardian_hours(account, p["badge"]["days"], now) >= p["badge"]["hours"]
        if "queue_skip" in p:
            out["queue_skip"] = (self.guardian_hours(account, p["queue_skip"]["days"], now)
                                 >= p["queue_skip"]["hours"])
        unpaid = self.guardian_hours(account, 30, now) - self._paid(account, "hours")
        unpaid = max(0.0, unpaid)
        if "rested" in p:
            out["rested_pct"] = min(p["rested"]["cap_pct"], round(unpaid * p["rested"]["pct_per_hour"], 1))
        out["unpaid_hours"] = round(unpaid, 4)
        return out

    def _paid(self, account, perk):
        return self.db.execute("SELECT COALESCE(SUM(amount),0) FROM orion_paid WHERE account=? AND perk=?",
                               (account, perk)).fetchone()[0]

    def mark_paid(self, account, hours, now=None):
        """Call after rested XP was granted so the same hours aren't paid twice."""
        self.db.execute("INSERT INTO orion_paid VALUES (?,?,?,?)",
                        (account, "hours", float(hours), int(now if now is not None else time.time())))
        self.db.commit()
