#!/bin/sh
# Builds and runs the Boss Fights tests (no server needed): raid forming, scaling, tiers, affixes, unlocks and
# the clock (test_logic.cpp). BossFightsLogic.h is a new file in realm/mangos/0050-openvanilla-bossfights.patch,
# so it is taken whole from the patch's "+" lines.
#   sh realm/bossfights/tests/run.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=$(mktemp -d)
mkdir -p "$OUT/OpenVanilla"
python3 - "$ROOT/realm/mangos/0050-openvanilla-bossfights.patch" "$OUT/OpenVanilla/BossFightsLogic.h" <<'PY'
import sys
patch, out = sys.argv[1], sys.argv[2]
cur, lines = False, []
for l in open(patch, encoding="utf-8"):
    if l.startswith("diff --git"):
        cur = l.rstrip().endswith("/BossFightsLogic.h")
    elif cur and l.startswith("+") and not l.startswith("+++"):
        lines.append(l[1:])
if not lines:
    sys.exit("no BossFightsLogic.h in " + patch)
open(out, "w").write("".join(lines))
PY
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_logic.cpp" -o "$OUT/test_logic"
"$OUT/test_logic"
