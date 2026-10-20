#!/usr/bin/env bash
# The name filter (realm/mangos/0019-openvanilla-gm-feed-and-names.patch): builds the patched
# OpenVanilla/NameFilter.cpp against a stand-in Config and checks blocked and harmless names.
#   bash run.sh <patched mangos-classic tree>      (needs g++)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TREE=${1:?usage: run.sh <patched mangos-classic tree>}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r "$HERE"/. "$T"/ && mkdir -p "$T/OpenVanilla" && cp "$TREE/src/game/OpenVanilla/NameFilter."* "$T/OpenVanilla/"
cd "$T" && g++ -std=c++17 -I. test.cpp OpenVanilla/NameFilter.cpp -o t && ./t
