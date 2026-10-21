#!/bin/sh
# Builds and runs the Duels round tests (no server needed). DuelsLogic.h is a new file in
# realm/mangos/0021-openvanilla-duels.patch, so it is taken whole from the patch's "+" lines.
#   sh realm/duels/tests/run.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=$(mktemp -d)
mkdir -p "$OUT/OpenVanilla"
python3 - "$ROOT/realm/mangos/0021-openvanilla-duels.patch" "$OUT/OpenVanilla/DuelsLogic.h" <<'PY'
import sys
patch, out = sys.argv[1], sys.argv[2]
cur, lines = False, []
for l in open(patch, encoding="utf-8"):
    if l.startswith("diff --git"):
        cur = l.rstrip().endswith("/DuelsLogic.h")
    elif cur and l.startswith("+") and not l.startswith("+++"):
        lines.append(l[1:])
open(out, "w").write("".join(lines))
PY
${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/test_rounds.cpp" -o "$OUT/test_rounds"
"$OUT/test_rounds"
