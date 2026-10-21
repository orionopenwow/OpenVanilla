#!/usr/bin/env bash
# Herald's pull-decision numbers (realm/mangos/0020: playerbot/HeraldMath.h). Applies the patch series to a
# CMaNGOS + PlayerBots checkout first, or point PB at a PlayerBots tree that already has 0020:
#   PB=/path/to/mangos-classic/src/modules/PlayerBots bash realm/mangos/tests/herald_math/run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PB=${PB:?set PB to a PlayerBots tree with patch 0020 applied}
g++ -std=c++17 -Wall -I "$PB" "$HERE/test.cpp" -o /tmp/herald_math_test
/tmp/herald_math_test
