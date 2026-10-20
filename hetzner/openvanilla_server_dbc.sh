#!/usr/bin/env bash
# Server copy of SkillRaceClassInfo.dbc: let every Classic+ race/class pair keep its class's
# weapon skills (otherwise mangosd drops e.g. a Human Hunter's Axes/Guns/Daggers at login).
# Called by openvanilla_realm_up.sh and openvanilla_hotpatch.sh. Works from the stock file (kept as
# .orig in the gamedata volume), so it is idempotent. Exit 0 = the file changed (a world restart
# picks it up), 1 = already up to date.
set -euo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
CP=${OW_CP:-/opt/openvanilla-classicplus}
cd "$REALM_DIR"
set -a; . ./.env; set +a
PROJECT=${COMPOSE_PROJECT_NAME:-$(basename "$REALM_DIR")}
VOL=$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.volume=gamedata" | head -1)
[ -n "$VOL" ] || { echo "No gamedata volume found"; exit 2; }
mkdir -p "$CP/dbc"
docker run --rm -v "$VOL":/data -v "$CP/dbc":/out debian:bookworm-slim sh -c '
  f=$(ls /data/dbc | grep -i "^skillraceclassinfo.dbc$" | head -1); f=${f:-SkillRaceClassInfo.dbc}
  [ -f "/data/dbc/$f.orig" ] || cp "/data/dbc/$f" "/data/dbc/$f.orig"
  cp "/data/dbc/$f.orig" /out/srci-stock.dbc && cp "/data/dbc/$f" /out/srci-live.dbc && echo "$f" > /out/srci-name'
MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N classicmangos \
  -e "SELECT DISTINCT race, class FROM playercreateinfo" > "$CP/dbc/pairs.txt"
python3 "$CP/fix_skillraceclassinfo.py" "$CP/dbc/srci-stock.dbc" "$CP/dbc/SkillRaceClassInfo.dbc" \
  --combos "$CP/dbc/pairs.txt" --sql "$CP/classicplus_weapons.sql"
if cmp -s "$CP/dbc/SkillRaceClassInfo.dbc" "$CP/dbc/srci-live.dbc"; then
  echo "server SkillRaceClassInfo.dbc already up to date"; exit 1
fi
docker run --rm -v "$VOL":/data -v "$CP/dbc":/in:ro debian:bookworm-slim sh -c '
  cp /in/SkillRaceClassInfo.dbc "/data/dbc/$(cat /in/srci-name)" && echo "server dbc/$(cat /in/srci-name) updated (original kept as .orig)"'
exit 0
