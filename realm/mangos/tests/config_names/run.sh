#!/usr/bin/env bash
# OpenVanilla.* setting names (realm/mangos/0012-openvanilla-names.patch): builds the patched
# Config.cpp against small stand-ins and checks the new spelling, the old one, and which wins.
#   bash run.sh <patched mangos-classic tree>      (needs g++ and the boost headers)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TREE=${1:?usage: run.sh <patched mangos-classic tree>}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r "$HERE"/. "$T"/ && cp "$TREE/src/shared/Config/Config.cpp" "$TREE/src/shared/Config/Config.h" "$T"/
cd "$T" && g++ -std=c++17 -I. -include Common.h test.cpp Config.cpp -o t && ./t
