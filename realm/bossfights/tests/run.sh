#!/bin/sh
# Builds and runs the Boss Fights tests (no server needed): raid forming, scaling, tiers, affixes, unlocks and
# the clock (test_logic.cpp), the self-test's rules: test accounts, the queue's words, the state line
# (test_selftest.cpp), and the ready raider's talent builds, gear sets, bars, consumables and ready line
# (test_ready.cpp), bot fill's roles, classes, limits and queue fields (test_botfill.cpp), and the bots' Onyxia geometry
# and the bot-raid softening rule (test_onyxia.cpp: OnyxiaGeometry.h, new in 0059-openvanilla-bots-onyxia.patch,
# whose change to BossFightsLogic.h is applied on top too). BossFightsLogic.h,
# BossFightsSelfTest.h, BossFightsReadyLogic.h and BossFightsBotFillLogic.h are new files in
# realm/mangos/0050-openvanilla-bossfights.patch, 0051-openvanilla-bossfights-selftest.patch,
# 0052-openvanilla-bossfights-ready.patch and 0054-openvanilla-bossfights-bot-fill.patch, so each is taken whole
# from its patch's "+" lines; 0054's change to BossFightsSelfTest.h (the queue's bots= word) is applied on top.
#   sh realm/bossfights/tests/run.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=$(mktemp -d)
mkdir -p "$OUT/OpenVanilla"
extract() {  # extract PATCH FILE
  python3 - "$ROOT/realm/mangos/$1" "$OUT/OpenVanilla/$2" "$2" <<'PY'
import sys
patch, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
cur, lines = False, []
for l in open(patch, encoding="utf-8"):
    if l.startswith("diff --git"):
        cur = l.rstrip().endswith("/" + name)
    elif cur and l.startswith("+") and not l.startswith("+++"):
        lines.append(l[1:])
if not lines:
    sys.exit("no " + name + " in " + patch)
open(out, "w").write("".join(lines))
PY
}
extract 0050-openvanilla-bossfights.patch BossFightsLogic.h
extract 0051-openvanilla-bossfights-selftest.patch BossFightsSelfTest.h
extract 0052-openvanilla-bossfights-ready.patch BossFightsReadyLogic.h
extract 0054-openvanilla-bossfights-bot-fill.patch BossFightsBotFillLogic.h
# 0054's hunks for BossFightsSelfTest.h, on the file 0051 made
python3 - "$ROOT/realm/mangos/0054-openvanilla-bossfights-bot-fill.patch" > "$OUT/selftest.diff" <<'PY'
import sys, re
text = open(sys.argv[1], encoding="utf-8").read()
for part in re.split(r"(?m)^(?=diff --git )", text):
    if part.startswith("diff --git") and part.split("\n", 1)[0].endswith("/BossFightsSelfTest.h"):
        sys.stdout.write(part)
PY
(cd "$OUT/OpenVanilla" && patch -s -p4 BossFightsSelfTest.h < "$OUT/selftest.diff")
# 0059: the bots' Onyxia geometry (a new file) and its change to BossFightsLogic.h (BotRaidSofter)
extract 0059-openvanilla-bots-onyxia.patch OnyxiaGeometry.h
python3 - "$ROOT/realm/mangos/0059-openvanilla-bots-onyxia.patch" > "$OUT/logic.diff" <<'PY'
import sys, re
text = open(sys.argv[1], encoding="utf-8").read()
for part in re.split(r"(?m)^(?=diff --git )", text):
    if part.startswith("diff --git") and part.split("\n", 1)[0].endswith("/BossFightsLogic.h"):
        sys.stdout.write(part)
PY
(cd "$OUT/OpenVanilla" && patch -s -p4 BossFightsLogic.h < "$OUT/logic.diff")
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_logic.cpp" -o "$OUT/test_logic"
"$OUT/test_logic"
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_selftest.cpp" -o "$OUT/test_selftest"
"$OUT/test_selftest"
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_ready.cpp" -o "$OUT/test_ready"
"$OUT/test_ready"
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_botfill.cpp" -o "$OUT/test_botfill"
"$OUT/test_botfill"
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_onyxia.cpp" -o "$OUT/test_onyxia"
"$OUT/test_onyxia"
rm -rf "$OUT"
