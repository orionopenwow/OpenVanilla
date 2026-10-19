#!/bin/sh
# Builds and runs transmog's rule tests (no server needed).
#   run_logic_tests.sh                    take the sources from realm/mangos/0011-openvanilla-transmog.patch
#   run_logic_tests.sh <mangos-classic>   or from a patched CMaNGOS tree
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=$(mktemp -d)
mkdir -p "$OUT/OpenVanilla"
if [ -n "$1" ]; then
  cp "$1/src/game/OpenVanilla/Transmog.h" "$1/src/game/OpenVanilla/TransmogLogic.cpp" "$OUT/OpenVanilla/"
else
  python3 - "$ROOT/realm/mangos/0011-openvanilla-transmog.patch" "$OUT/OpenVanilla" <<'PY'
import os, sys
patch, out = sys.argv[1], sys.argv[2]
want = {"Transmog.h", "TransmogLogic.cpp"}
cur, lines = None, []
def flush():
    if cur:
        open(os.path.join(out, cur), "w").write("".join(lines))
for line in open(patch, encoding="utf-8"):
    if line.startswith("diff --git"):
        flush()
        name = line.split()[-1].split("/")[-1]
        cur, lines = (name if name in want else None), []
    elif cur and line.startswith("+") and not line.startswith("+++"):
        lines.append(line[1:])
flush()
PY
fi
mkdir -p "$OUT/stub"
printf '#pragma once\n#include <cstdint>\ntypedef uint64_t uint64; typedef uint32_t uint32; typedef uint16_t uint16; typedef uint8_t uint8; typedef int32_t int32; typedef int64_t int64;\n' > "$OUT/stub/Common.h"
${CXX:-g++} -std=c++17 -O1 -I"$OUT/stub" -I"$OUT" "$HERE/test_logic.cpp" "$OUT/OpenVanilla/TransmogLogic.cpp" -o "$OUT/t"
"$OUT/t"
