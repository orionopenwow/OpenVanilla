#!/usr/bin/env bash
# Rebuild devkit/db/fixtures from a STOCK CMaNGOS classic-db (before any Open Vanilla SQL ran on it).
#   bash devkit/db/make_fixtures.sh <mangos db name> [characters db name]
# Run it where the mariadb client can reach that database (e.g. on the server:
#   docker compose exec -T mariadb ... or with -h/-u flags in MYSQL_ARGS).
set -euo pipefail
SRC=${1:?stock world database name}; CHARS=${2:-classiccharacters}
HERE=$(cd "$(dirname "$0")" && pwd); SQL=$HERE/../../realm/classicplus; OUT=$HERE/fixtures
ARGS=${MYSQL_ARGS:-}
# 6548 and 21591: the stock vendor and firework test_sql.py copies for the retired NPC 990001 and item 990101
IDS=$({ grep -ohE '\b[0-9]{4,6}\b' "$SQL"/classicplus_{starpouch,weapons,races}.sql; echo 6548; echo 21591; } | sort -un | grep -v -E '^99[0-9]{4}$' | paste -sd, )
O="--skip-comments --skip-dump-date --compact --skip-extended-insert --single-transaction $ARGS"
{
  echo "-- devkit/db fixtures: the stock classic-db rows and tables Open Vanilla's SQL reads or changes."
  echo "-- Made by devkit/db/make_fixtures.sh from a stock CMaNGOS classic-db. Not game client data."
  echo "SET FOREIGN_KEY_CHECKS=0;"
  mysqldump $O --no-data "$SRC" playercreateinfo playercreateinfo_spell playercreateinfo_action playercreateinfo_skills player_levelstats item_template item_loot_template creature_template creature npc_vendor
  mysqldump $O --no-create-info "$SRC" playercreateinfo playercreateinfo_spell playercreateinfo_action playercreateinfo_skills player_levelstats
  mysqldump $O --no-create-info "$SRC" item_template --where="entry IN ($IDS)"
  mysqldump $O --no-create-info "$SRC" item_loot_template --where="entry IN ($IDS)"
  mysqldump $O --no-create-info "$SRC" creature_template --where="entry IN ($IDS)"
} > "$OUT/classicmangos.sql"
mysqldump $O --no-data "$CHARS" characters > "$OUT/classiccharacters.sql"
echo "fixtures written to $OUT"
