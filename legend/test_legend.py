#!/usr/bin/env python3
"""Tests for legend.py and legend_issue.py.

    python3 test_legend.py                  # run tests
    python3 test_legend.py --write-vectors  # regenerate vectors.json
"""

import json
import os
import shutil
import stat
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import legend  # noqa: E402
import legend_issue  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
VECTORS = os.path.join(HERE, "vectors.json")

# ---------------------------------------------------------------- fixed vectors

HERO_SECRET = bytes(range(32))
HERO_LINE = "ovk1.TESTKEY001." + legend.b64u_encode(HERO_SECRET)
REALM_SEED = bytes(range(32, 64))
REALM_HOST = "duels.openvanilla.app"
SINCE = 1760000000
ISSUED = 1760900000


def build_vectors():
    pub = legend.ed25519_public_key(REALM_SEED)
    kid = legend.kid_for(pub)
    keyfile = {"legend": 1, "realm": {"host": REALM_HOST, "name": "Duels"},
               "keys": [{"kid": kid, "alg": "Ed25519", "pub": legend.b64u_encode(pub),
                         "since": SINCE, "until": None}], "revoked": []}
    hero = legend.hero_from_key(HERO_LINE)
    body = {"legend": 1, "kind": "character", "realm": REALM_HOST, "issued": ISSUED,
            "serial": 1, "prev": None,
            "subject": {"id": REALM_HOST + "/4242", "name": "Elúne", "race": "Night Elf",
                        "class": "Druid", "gender": "female", "level": 60},
            "hero": hero,
            "records": {"duels": {"rating": 1712, "best": 1740, "wins": 31, "losses": 12}}}
    doc1 = legend.sign_document(body, REALM_SEED, kid)
    body2 = json.loads(json.dumps(body))
    body2.update(serial=2, issued=ISSUED + 3600, prev=legend.doc_hash(doc1))
    body2["records"]["duels"].update(rating=1730, wins=32)
    doc2 = legend.sign_document(body2, REALM_SEED, kid)
    tampered = json.loads(json.dumps(doc1))
    tampered["records"]["duels"]["rating"] = 2400
    msg = "challenge:abc"
    return {
        "_note": "Open Vanilla Legend v1 test vectors. All base64url is unpadded.",
        "hero": {
            "secret_hex": HERO_SECRET.hex(),
            "key_line": HERO_LINE,
            "seed_hex": legend._hero_seed(HERO_LINE).hex(),
            "hero_id": hero,
            "message": msg,
            "signature": legend.hero_sign(HERO_LINE, msg),
        },
        "realm": {"seed_hex": REALM_SEED.hex(), "pub": legend.b64u_encode(pub), "kid": kid,
                  "keyfile": keyfile},
        "documents": {
            "valid": [doc1, doc2],
            "signing_bytes_utf8": [legend.signing_bytes(doc1).decode("utf-8")],
            "prev_of_second": legend.doc_hash(doc1),
            "invalid": [{"doc": tampered, "reason": "signature does not match"}],
        },
        "canonical": [
            {"value": {"b": 1, "a": [True, False, None], "A": "x"}, "text": '{"A":"x","a":[true,false,null],"b":1}'},
            {"value": {"￿": 1, "\U0001F600": 2, "é": 3}, "text": '{"é":3,"￿":1,"\U0001F600":2}'},
            {"value": "q\"b\\n\n\r\t\b\f\u0001\u001f\u007f/é😀", "text": '"q\\"b\\\\n\\n\\r\\t\\b\\f\\u0001\\u001f\u007f/é😀"'},
            {"value": [-9007199254740991, 0, 9007199254740991], "text": "[-9007199254740991,0,9007199254740991]"},
            {"value": {"nested": {"z": {}, "y": []}}, "text": '{"nested":{"y":[],"z":{}}}'},
        ],
    }


# ---------------------------------------------------------------- tests

class Ed25519Vectors(unittest.TestCase):
    CASES = [  # RFC 8032 section 7.1, tests 1-3
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e0652249015"
         "55fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
         "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
         "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
         "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ]

    def test_rfc8032(self):
        for sk, pk, msg, sig in self.CASES:
            sk, pk, msg, sig = map(bytes.fromhex, (sk, pk, msg, sig))
            self.assertEqual(legend.ed25519_public_key(sk), pk)
            self.assertEqual(legend.ed25519_sign(sk, msg), sig)
            self.assertTrue(legend.ed25519_verify(pk, msg, sig))
            bad = bytearray(sig)
            bad[0] ^= 1
            self.assertFalse(legend.ed25519_verify(pk, msg, bytes(bad)))
            self.assertFalse(legend.ed25519_verify(pk, msg + b"x", sig))

    def test_rejects_large_s(self):
        sk, pk, msg, sig = map(bytes.fromhex, self.CASES[0])
        s = int.from_bytes(sig[32:], "little") + legend._L
        self.assertFalse(legend.ed25519_verify(pk, msg, sig[:32] + s.to_bytes(32, "little")))


class HKDF(unittest.TestCase):
    def test_rfc5869_case1(self):
        okm = legend.hkdf_sha256(b"\x0b" * 22, bytes(range(13)), bytes(range(0xf0, 0xfa)), 42)
        self.assertEqual(okm.hex(), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c"
                                    "5db02d56ecc4c5bf34007208d5b887185865")


class Canonical(unittest.TestCase):
    def test_cases(self):
        for c in build_vectors()["canonical"]:
            self.assertEqual(legend.canonical(c["value"]).decode("utf-8"), c["text"])

    def test_rejects(self):
        for bad in (1.5, 1.0, 2 ** 53, -(2 ** 53), {1: 2}, "\ud800", float("nan"), b"x", {"a": {1, 2}}):
            with self.assertRaises(ValueError):
                legend.canonical(bad)

    def test_bools_not_ints(self):
        self.assertEqual(legend.canonical([True, 1, False, 0]), b"[true,1,false,0]")

    def test_empty(self):
        self.assertEqual(legend.canonical({}), b"{}")
        self.assertEqual(legend.canonical(""), b'""')


class Base64Url(unittest.TestCase):
    def test_strict(self):
        self.assertEqual(legend.b64u_decode("AAEC"), b"\x00\x01\x02")
        self.assertEqual(legend.b64u_decode("AA=="), b"\x00")
        for bad in ("A", "AA+/", "AB", "A A"):
            with self.assertRaises(ValueError):
                legend.b64u_decode(bad)


class Hero(unittest.TestCase):
    def test_vector_file_matches(self):
        with open(VECTORS, encoding="utf-8") as f:
            self.assertEqual(json.load(f), build_vectors(), "vectors.json is stale")

    def test_sign_verify(self):
        hero = legend.hero_from_key(HERO_LINE)
        self.assertTrue(hero.startswith("ovh1.") and len(hero) == 48)
        sig = legend.hero_sign(HERO_LINE, "challenge:xyz")
        self.assertTrue(legend.hero_verify(hero, "challenge:xyz", sig))
        self.assertFalse(legend.hero_verify(hero, "challenge:xyZ", sig))
        self.assertFalse(legend.hero_verify("ovh1.nope", "challenge:xyz", sig))
        self.assertFalse(legend.hero_verify(hero, "challenge:xyz", "garbage"))

    def test_key_line_forms(self):
        hero = legend.hero_from_key(HERO_LINE)
        self.assertEqual(legend.hero_from_key("  " + HERO_LINE + "=\n"), hero)
        self.assertEqual(legend.hero_from_key(HERO_LINE.replace("TESTKEY001", "other.id")), hero)
        for bad in ("ovk2.X." + HERO_LINE.split(".")[-1], "ovk1..AAAA", "ovk1.X.AAAA"):
            with self.assertRaises(ValueError):
                legend.hero_from_key(bad)


class Documents(unittest.TestCase):
    def setUp(self):
        self.v = build_vectors()
        self.kf = self.v["realm"]["keyfile"]

    def test_valid(self):
        for d in self.v["documents"]["valid"]:
            r = legend.verify_document(d, self.kf)
            self.assertTrue(r["valid"], r["reason"])
            self.assertEqual(r["realm"], REALM_HOST)
            self.assertTrue(r["hero"])
        # round trip through text, key order shuffled, pretty-printed
        d = self.v["documents"]["valid"][0]
        text = json.dumps(dict(reversed(list(d.items()))), indent=4, ensure_ascii=True)
        self.assertTrue(legend.verify_document(text, json.dumps(self.kf))["valid"])

    def test_no_hero(self):
        seed, pub, kid = legend.make_realm_key()
        kf = {"legend": 1, "realm": {"host": "x.example.org", "name": "X"},
              "keys": [{"kid": kid, "alg": "Ed25519", "pub": legend.b64u_encode(pub),
                        "since": 0, "until": None}], "revoked": []}
        doc = legend.sign_document({"legend": 1, "kind": "character", "realm": "x.example.org",
                                    "issued": 5, "serial": 1, "prev": None, "hero": None,
                                    "subject": {"id": "x.example.org/1"}, "records": {}}, seed, kid)
        r = legend.verify_document(doc, kf)
        self.assertTrue(r["valid"], r["reason"])
        self.assertFalse(r["hero"])
        with self.assertRaises(ValueError):
            legend.sign_document(doc, seed, "wrongkid")

    def tamper(self, fn, reason, kf=None):
        d = json.loads(json.dumps(self.v["documents"]["valid"][0]))
        k = json.loads(json.dumps(kf or self.kf))
        fn(d, k)
        r = legend.verify_document(d, k)
        self.assertFalse(r["valid"])
        self.assertIn(reason, r["reason"])

    def test_tamper(self):
        self.tamper(lambda d, k: d["records"]["duels"].__setitem__("wins", 99), "signature")
        self.tamper(lambda d, k: d["records"].__setitem__("extra", {"x": 1}), "signature")
        self.tamper(lambda d, k: d["subject"].__setitem__("name", "Elune"), "signature")
        self.tamper(lambda d, k: d.__setitem__("hero", None), "signature")
        self.tamper(lambda d, k: d.__setitem__("issued", d["issued"] + 1), "signature")
        self.tamper(lambda d, k: d.__setitem__("sig", d["sig"][:-2] + "AA"), "signature")
        self.tamper(lambda d, k: d.__setitem__("realm", "evil.example.com"), "subject id")
        self.tamper(lambda d, k: d["subject"].__setitem__("id", "evil.example.com/1"), "subject id")
        self.tamper(lambda d, k: d.__setitem__("legend", 2), "version")
        self.tamper(lambda d, k: d.__setitem__("issued", 1.5), "issued")
        self.tamper(lambda d, k: d["records"].__setitem__("f", 1.5), "canonical")
        self.tamper(lambda d, k: k["realm"].__setitem__("host", "other.example.org"), "different realm")
        self.tamper(lambda d, k: d.__setitem__("kid", "AAAAAAAAAAAAAAAA"), "not published")
        self.tamper(lambda d, k: k["keys"][0].__setitem__("pub", legend.b64u_encode(bytes(32))), "kid does not match")
        self.assertEqual(self.v["documents"]["invalid"][0]["reason"],
                         legend.verify_document(self.v["documents"]["invalid"][0]["doc"], self.kf)["reason"])

    def test_revoked_and_expired(self):
        kid = self.v["realm"]["kid"]
        self.tamper(lambda d, k: k.__setitem__("revoked", [kid]), "revoked")
        self.tamper(lambda d, k: k["keys"][0].__setitem__("until", ISSUED), "expired")
        self.tamper(lambda d, k: k["keys"][0].__setitem__("since", ISSUED + 1), "before the key")
        d = self.v["documents"]["valid"][0]
        k = json.loads(json.dumps(self.kf))
        k["keys"][0]["until"] = ISSUED + 1
        self.assertTrue(legend.verify_document(d, k)["valid"])

    def test_prev_chain(self):
        d1, d2 = self.v["documents"]["valid"]
        self.assertIsNone(d1["prev"])
        self.assertEqual(d2["prev"], legend.doc_hash(d1))


class Issuer(unittest.TestCase):
    HOST = "duels.openvanilla.app"
    HEADER = "guid\tname\trace\tclass\tgender\tlevel\taccount\trating\tbest\twins\tlosses\n"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.p = lambda *a: os.path.join(self.tmp, *a)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def write(self, name, text):
        with open(self.p(name), "w", encoding="utf-8") as f:
            f.write(text)

    def run_issue(self, now):
        return legend_issue.issue(self.HOST, "Duels", self.p("keys", "duels.key"), self.p("rows.tsv"),
                                  self.p("heroes.json"), self.p("out"),
                                  self.p("www", ".well-known", "openvanilla-legend.json"), now)

    def load(self, *a):
        with open(self.p(*a), encoding="utf-8") as f:
            return json.load(f)

    def test_end_to_end(self):
        hero = legend.hero_from_key(HERO_LINE)
        self.write("rows.tsv", self.HEADER +
                   "11\tThrall\t2\t7\t0\t60\t500\t1600\t1650\t10\t4\n"
                   "12\tJaina\t1\t8\t1\t60\t501\t1800\t1800\t20\t2\n"
                   "13\tBad\tx\t1\t0\t60\t502\t1\t1\t1\t1\n")
        self.write("heroes.json", json.dumps({"heroes": [{"account": 501, "hero": hero},
                                                         {"account": 999, "hero": "bogus"}]}))
        r = self.run_issue(1761000000)
        self.assertEqual((r["signed"], r["unchanged"]), (2, 0))
        mode = stat.S_IMODE(os.stat(self.p("keys", "duels.key")).st_mode)
        self.assertEqual(mode, 0o600)
        wk = self.load("www", ".well-known", "openvanilla-legend.json")
        self.assertEqual(wk["realm"], {"host": self.HOST, "name": "Duels"})
        self.assertEqual(wk["keys"][0]["kid"], r["kid"])
        self.assertEqual(wk["keys"][0]["since"], 1761000000)

        j = self.load("out", "12.json")
        self.assertTrue(legend.verify_document(j, wk)["valid"])
        self.assertEqual(j["hero"], hero)
        self.assertEqual(j["subject"], {"id": self.HOST + "/12", "name": "Jaina", "race": "Human",
                                        "class": "Mage", "gender": "female", "level": 60})
        self.assertEqual(j["records"]["duels"], {"rating": 1800, "best": 1800, "wins": 20, "losses": 2})
        self.assertEqual((j["serial"], j["prev"]), (1, None))
        t = self.load("out", "11.json")
        self.assertIsNone(t["hero"])
        self.assertEqual((t["subject"]["race"], t["subject"]["class"]), ("Orc", "Shaman"))
        for name in os.listdir(self.p("out")):
            with open(self.p("out", name), encoding="utf-8") as f:
                text = f.read()
            self.assertNotIn("500", text.replace("1500", ""))
            self.assertNotIn("account", text)

        idx = self.load("out", "index.json")
        self.assertEqual([c["name"] for c in idx["characters"]], ["Jaina", "Thrall"])
        self.assertEqual(idx["characters"][0]["hero"], True)
        self.assertEqual(idx["characters"][1]["file"], "11.json")

        # second run: nothing changed
        r = self.run_issue(1761000100)
        self.assertEqual((r["signed"], r["unchanged"]), (0, 2))
        self.assertEqual(self.load("out", "12.json"), j)

        # third run: Thrall wins a duel
        self.write("rows.tsv", self.HEADER +
                   "11\tThrall\t2\t7\t0\t60\t500\t1616\t1650\t11\t4\n"
                   "12\tJaina\t1\t8\t1\t60\t501\t1800\t1800\t20\t2\n")
        r = self.run_issue(1761000200)
        self.assertEqual((r["signed"], r["unchanged"]), (1, 1))
        t2 = self.load("out", "11.json")
        self.assertEqual((t2["serial"], t2["prev"], t2["issued"]), (2, legend.doc_hash(t), 1761000200))
        self.assertTrue(legend.verify_document(t2, wk)["valid"])

        # fourth run: Thrall opts in to a Hero ID -> re-signed again
        self.write("heroes.json", json.dumps({"heroes": [{"account": 500, "hero": hero}]}))
        r = self.run_issue(1761000300)
        self.assertEqual(r["signed"], 2)  # Jaina loses her hero, Thrall gains one
        t3 = self.load("out", "11.json")
        self.assertEqual((t3["serial"], t3["prev"], t3["hero"]), (3, legend.doc_hash(t2), hero))
        self.assertIsNone(self.load("out", "12.json")["hero"])
        self.assertFalse(any(n.startswith(".tmp-") for n in os.listdir(self.p("out"))))

    def test_wellknown_keeps_old_keys(self):
        self.write("rows.tsv", self.HEADER + "1\tA\t1\t1\t0\t1\t1\t1\t1\t0\t0\n")
        self.write("heroes.json", '{"heroes":[]}')
        wk_path = self.p("www", ".well-known", "openvanilla-legend.json")
        os.makedirs(os.path.dirname(wk_path))
        old = {"kid": "OLDKEYOLDKEYOLDK", "alg": "Ed25519", "pub": "x", "since": 1, "until": 2}
        with open(wk_path, "w") as f:
            json.dump({"legend": 1, "realm": {"host": self.HOST, "name": "Duels"},
                       "keys": [old], "revoked": ["BADKEYBADKEYBADK"]}, f)
        r = self.run_issue(1000)
        wk = self.load("www", ".well-known", "openvanilla-legend.json")
        self.assertEqual([k["kid"] for k in wk["keys"]], [r["kid"], "OLDKEYOLDKEYOLDK"])
        self.assertEqual(wk["revoked"], ["BADKEYBADKEYBADK"])

    def test_speed_300(self):
        seed, pub, kid = legend.make_realm_key()
        t = time.time()
        for i in range(300):
            legend.sign_document({"legend": 1, "kind": "character", "realm": self.HOST, "issued": 1,
                                  "serial": 1, "prev": None, "hero": None,
                                  "subject": {"id": "%s/%d" % (self.HOST, i), "name": "N%d" % i},
                                  "records": {"duels": {"rating": i}}}, seed, kid, pub)
        dt = time.time() - t
        print("\n  signed 300 docs in %.2fs" % dt, file=sys.stderr)
        self.assertLess(dt, 30)


if __name__ == "__main__":
    if sys.argv[1:] == ["--write-vectors"]:
        with open(VECTORS, "w", encoding="utf-8") as f:
            f.write(json.dumps(build_vectors(), indent=2, ensure_ascii=False) + "\n")
        print("wrote", VECTORS)
    else:
        unittest.main()
