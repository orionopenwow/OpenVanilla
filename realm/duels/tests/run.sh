#!/bin/sh
# Builds and runs the Duels tests (no server needed): the round rules (test_rounds.cpp) and the
# Glicko-2 rating, sudden death and Duel Points (test_rating.cpp). DuelsLogic.h is a new file in
# realm/mangos/0021-openvanilla-duels.patch and DuelsRating.h one in 0024-openvanilla-duels-arena.patch,
# so each is taken whole from its patch's "+" lines.
#   sh realm/duels/tests/run.sh
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
    sys.exit("no new file %s in %s" % (name, patch))
open(out, "w").write("".join(lines))
PY
}
extract 0021-openvanilla-duels.patch DuelsLogic.h
extract 0024-openvanilla-duels-arena.patch DuelsRating.h
for t in test_rounds test_rating; do
  ${CXX:-g++} -std=c++17 -Wall -I"$OUT" "$HERE/$t.cpp" -o "$OUT/$t"
  "$OUT/$t"
done
