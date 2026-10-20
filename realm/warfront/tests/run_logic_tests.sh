#!/bin/sh
# Builds and runs the Warfront rule tests (no server needed).
#   run_logic_tests.sh                    take the sources from realm/mangos/0010-openvanilla-warfront.patch
#   run_logic_tests.sh <mangos-classic>   or from a patched CMaNGOS tree
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=$(mktemp -d)
mkdir -p "$OUT/OpenVanilla"
if [ -n "$1" ]; then
  cp "$1/src/game/OpenVanilla/Warfront.h" "$1/src/game/OpenVanilla/WarfrontArena.h" "$1/src/game/OpenVanilla/WarfrontLogic.cpp" "$OUT/OpenVanilla/"
else
  # the new files are whole in the patch: take their "+" lines
  python3 - "$ROOT/realm/mangos/0010-openvanilla-warfront.patch" "$OUT/OpenVanilla" <<'PY'
import os, sys
patch, out = sys.argv[1], sys.argv[2]
want = {"Warfront.h", "WarfrontArena.h", "WarfrontLogic.cpp"}
cur, lines = None, []
def flush():
    if cur:
        open(os.path.join(out, cur), "w").write("".join(lines))
for l in open(patch, encoding="utf-8"):
    if l.startswith("diff --git"):
        flush(); cur, lines = None, []
        name = l.split(" b/")[-1].strip().split("/")[-1]
        if name in want:
            cur = name
    elif cur and l.startswith("+") and not l.startswith("+++"):
        lines.append(l[1:])
flush()
PY
fi
g++ -std=c++17 -Wall -Wextra -I"$HERE/stub" -I"$OUT" "$HERE/test_logic.cpp" "$OUT/OpenVanilla/WarfrontLogic.cpp" -o "$OUT/test_logic"
"$OUT/test_logic"
