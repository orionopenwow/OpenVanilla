#!/usr/bin/env bash
# Server copies of CreatureModelData.dbc and CreatureDisplayInfo.dbc with the ported models
# (tools/modelport → realm/classicplus/classicplus_world_models.json), so mangosd accepts their
# display ids. Called by openvanilla_realm_up.sh and openvanilla_hotpatch.sh. Works from the stock files
# (kept as .orig in the gamedata volume), so it is idempotent. Exit 0 = a file changed (a world
# restart picks it up), 1 = already up to date.
set -euo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
CP=${OW_CP:-/opt/openvanilla-classicplus}
cd "$REALM_DIR"
set -a; . ./.env; set +a
[ -s "$CP/classicplus_world_models.json" ] || { echo "no ported models"; exit 1; }
PROJECT=${COMPOSE_PROJECT_NAME:-$(basename "$REALM_DIR")}
VOL=$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.volume=gamedata" | head -1)
[ -n "$VOL" ] || { echo "No gamedata volume found"; exit 2; }
mkdir -p "$CP/dbc"
changed=1
for T in CreatureModelData CreatureDisplayInfo; do
  docker run --rm -e T="$T" -v "$VOL":/data -v "$CP/dbc":/out debian:bookworm-slim sh -c '
    low=$(echo "$T" | tr A-Z a-z)
    f=$(ls /data/dbc | grep -i "^$low.dbc$" | head -1); f=${f:-$T.dbc}
    [ -f "/data/dbc/$f.orig" ] || cp "/data/dbc/$f" "/data/dbc/$f.orig"
    cp "/data/dbc/$f.orig" "/out/$T-stock.dbc" && cp "/data/dbc/$f" "/out/$T-live.dbc" && echo "$f" > "/out/$T-name"'
  python3 "$CP/apply_models_dbc.py" "$CP/classicplus_world_models.json" "$T" "$CP/dbc/$T-stock.dbc" "$CP/dbc/$T.dbc"
  if ! cmp -s "$CP/dbc/$T.dbc" "$CP/dbc/$T-live.dbc"; then
    docker run --rm -e T="$T" -v "$VOL":/data -v "$CP/dbc":/in:ro debian:bookworm-slim sh -c '
      cp "/in/$T.dbc" "/data/dbc/$(cat /in/$T-name)" && echo "server dbc/$(cat /in/$T-name) updated (original kept as .orig)"'
    changed=0
  fi
done
[ $changed = 0 ] || echo "server model tables already up to date"
exit $changed
