#!/usr/bin/env bash
# One-time, after the 2026-10-15 history rewrite (release zips, videos and old patch-Z versions were
# removed from git history, so every commit got a new ID). The hotpatch remembers the last commit it
# applied in $CP/.hotpatch-applied; this swaps that old ID for its rewritten twin, so the next
# hotpatch applies only what really changed instead of re-running everything.
#   bash /opt/openvanilla-classicplus/repo/hetzner/remap_hotpatch_state.sh
set -euo pipefail
CP=${OW_CP:-/opt/openvanilla-classicplus}
STATE=$CP/.hotpatch-applied
[ -f "$STATE" ] || { echo "No $STATE: nothing to remap (the next hotpatch applies everything)."; exit 0; }
OLD=$(tr -d ' \r\n' < "$STATE")
NEW=$(awk -v o="$OLD" '$1==o {print $2}' <<'MAP'
00de19a0c403e5efea887864f156a832f19cb561 891342684eafd1600b0908f60934b4c230ad1e43
118784aa4a2a323093f7ba0b74c649389a2c2445 0c85f2e6fa3131bc457e6240fc4747973fc829b5
24cfd80e1505ac1d7d2e84d566e2fc1a98bf9a84 9c17906f9a6f2cb7605d0e3d828dbccfcedbc9db
270a33cc8dff3329028e466522fd72690956e30d 89a4478263cdf287e3606cf3a410602f658fb9cd
29162dc2c2b11bf97f1adde66fdffeea99f1e96f 7663abb27a7bc686aac73844318ad4c07b34ce70
310c9725b46d36c97c6d217f0d4f925205715ada b452b4cda3a0a27b78d5b84bd4ab9ac892b94101
4e3288e6483899029f434b9e2ac2c314ca0507b1 30bedebfb5e81b94c8971609d186b3bc972415a2
53de32fc47a0cc58af0c0244f5ea00aea78142a7 9b0a4724ef17fe1aa8619edb94695d247059ed88
54c935cafec57386a0cac4dec5c2b6338a42a4cd cbbcd6ee19d8a2f46b29cc4df423ec882c725c55
5ccec6bd58fc03fae8aa71fa81ac9c3b28a32b92 cf49a948b63347ddc23ef433fcfad2555766ddd8
63a4224d998d096a20349896f62f801a99293f3a ea165e5edc236a19866c23c140f27bd58faca376
64d54441e7912a9db7b1f6ae402081efe1fe3310 4320b011e6f6bc08f25443c224cae5027de91b7b
6a8369c3cf6258fa94ba48ba0f88cbe0eeacfffc 8b101579f23848b3e02e2beafc8e7d5ee929a59f
739342817ddcc34f1679b3ae6c0fbb234316188d a57b6159df136cb51945a9cff738743c796bfa54
74e8c8b3fb4b96c9fd53cd570c0edb7483db8ae2 0d74c61d91012e5b8d0b88e5685c5bec969ac334
75e77851b7c346dbc2ed4f1f0c49923268ca98f0 ed4daa468127a5c7613096e9b4b80bc6e0887149
7cd25e7c0e3bc600e7d4541b328459a26cd2f2b1 ad5ecaea461fd299146ccbcc60b6ea360c20cf44
7eaec91616ef785453bbd54d5546364b9b6d2a9e e07ec76ea2e39df3803e1581241f92fede31be2b
80decf09541ff7a7a8f28b529a1073f9a3a2ecc8 ba5df55680f1bc9972630f42beffbe3f81565f7d
88419f5c7271719f9b1690be7e5e7a614fe53f24 8793c12ba0be057a8e0e86752a05597ac34e2117
93079c50549f380916a887403d9ae68f57dd12cc 6eb7eb9ad6d4f666d830c43f0e45ab5116c07128
9a3ee11dc87d34b768f7240593668451986bcad4 216b763d99fe1236d33d88a2a512f30a1d939939
a009ba6aeeddc138dba48cd0133715811c689f03 fa87d55a791d227466a7bd062d77c4235fe34a05
adc3556693ddb9f7865ff66b6ba16bb9fb7994cc c2afb48b9d0b0d350790d725a6ef1309b255691f
adc520ec427565901ef5831084a7f19daa2980d3 3303eea2ee8c616dc92481aea541a13577c12a46
b49a7ce825cc54714dd0739a0a2228ad78c21373 b7462fc43f6dd126a52c4429bf8a8c32f9081de0
cc7df22d2c40e8d57bd502c9afc36165b3fbfd0b 0733d3ca9deded4af942e1656af9a4caafcdd9e0
ddc4780e5042831058718bd7a193cfde3a2c90c3 4980bbd8a4922054fa5d151cf57e1bc9435cc150
e7cbe910885e62d3891c07f8b0044fa44eb0ca49 a88faed96eb92f1113244080a29a9f34936f53f1
ec9d4a54d40e261c9bf9244a1243b4914893f044 22d25a2f1fe74b5cee564ee80a2690d7db8caed0
ed3922807e45c11d12954579eea7c360f779c860 d426960e9d9943905674cfcd84daf25f78258516
ee5dcd9583523f47a64518cc9444a131201f0e14 1804307e6eb4fc041a5359deeaa909cae2e4ca84
fbb69b5dd5628675f76ed18ba2229a31675964d9 ea1073827db11d30d529eeae1998752bba86a5f3
MAP
)
if [ -z "$NEW" ]; then
  echo "$OLD is not in the map (already rewritten, or newer than the rewrite): left as it is."
  exit 0
fi
cp "$STATE" "$STATE.before-rewrite"
echo "$NEW" > "$STATE"
echo "hotpatch state: ${OLD:0:8} -> ${NEW:0:8} (old value kept in $STATE.before-rewrite)"
