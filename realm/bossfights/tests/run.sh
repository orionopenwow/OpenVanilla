#!/bin/sh
# Builds and runs the Boss Fights tests (no server needed): raid forming, scaling, tiers, affixes, unlocks and
# the clock (test_logic.cpp), and the self-test's rules: test accounts, the queue's words, the state line
# (test_selftest.cpp). BossFightsLogic.h and BossFightsSelfTest.h are new files in
# realm/mangos/0050-openvanilla-bossfights.patch and 0051-openvanilla-bossfights-selftest.patch, so each is taken
# whole from its patch's "+" lines.
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
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_logic.cpp" -o "$OUT/test_logic"
"$OUT/test_logic"
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_selftest.cpp" -o "$OUT/test_selftest"
"$OUT/test_selftest"
rm -rf "$OUT"
