"""JS wallet (WebCrypto) -> Python realm verifier, end to end. Run: python3 test_cross.py"""
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orion_receipts as orx  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
NOW = 1_800_000_000 - 1_800_000_000 % 86400 + 20 * 3600
d = tempfile.mkdtemp()


def node(*a):
    subprocess.run(["node", os.path.join(HERE, "cross_test.mjs")] + list(a), check=True)


node("keys", d)
pubs = json.load(open(os.path.join(d, "pubs.json")))
realm = orx.new_key()
L = orx.Ledger(":memory:", "classicplus", {"classicplus": orx.pub_of(realm)})
host_cert = L.register_key(realm, 1, pubs["host"], "10.0.1", NOW)
peer_certs = [L.register_key(realm, 100 + i, p, "10.9.%d" % i, NOW) for i, p in enumerate(pubs["peers"])]
for i in range(5):
    for w in range(24):
        L.mark_presence(100 + i, NOW - 3 * 3600 + w * 300)
json.dump({"peers": peer_certs}, open(os.path.join(d, "certs.json"), "w"))

node("sign", d, str(NOW))
out = json.load(open(os.path.join(d, "host_receipts.json")))
rep = L.redeem(1, host_cert, out["receipts"], NOW)

assert out["refused"], "host stored a forged receipt"
assert out["stored"] == 120, out["stored"]
assert len(rep["accepted"]) == 120 and not rep["rejected"], rep["rejected"][:3]
assert sorted(rep["accepted"]) == sorted(out["hashes"]), "JS and Python hashes differ"
assert abs(rep["hours"] - 10.0) < 1e-6, rep["hours"]
perks = L.perks_for(1, NOW)
assert perks["badge"] and perks["rested_pct"] == 50.0, perks
print("cross-check OK: 120 JS-signed receipts verified in Python, 10.0 Guardian hours,", perks)
