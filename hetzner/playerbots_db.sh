#!/usr/bin/env bash
# Install the bot AI's own database tables (cmangos/playerbots sql/) on the live realm, once.
# The realm's databases were installed without them, so with the bot AI on (Herald) mangosd logs
# "Table 'classiccharacters.ai_playerbot_tele_cache' doesn't exist" and the like.
#
#   bash hetzner/playerbots_db.sh            (as root on the server; restarts the world server at the end)
#
# Takes the scripts from the playerbots commit the world server is built from (upstreams.env pin).
# A script is applied only when NONE of its tables exist yet: these scripts start with DROP TABLE,
# so one that would replace an existing table is skipped and reported instead. Safe to run twice.
set -euo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
BOTS=${PLAYERBOTS_COMMIT:-31e0f32b543fee46941db51225bb7b432eace236}
RAW=https://raw.githubusercontent.com/cmangos/playerbots/$BOTS/sql
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cd "$REALM_DIR"
set -a; . ./.env; set +a
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sql() { local db=$1; shift; MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N "$db" "$@"; }
has() { [ "$(sql "$1" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1' AND table_name='$2'")" = 1 ]; }

applied=0
for item in \
  classiccharacters:characters/ai_playerbot_cache.sql \
  classiccharacters:characters/ai_playerbot_custom_strategy.sql \
  classiccharacters:characters/ai_playerbot_db_store.sql \
  classiccharacters:characters/ai_playerbot_names.sql \
  classiccharacters:characters/ai_playerbot_random_bots.sql \
  classiccharacters:characters/ai_playerbot_ahbot.sql \
  classicmangos:world/ai_playerbot_texts.sql \
  classicmangos:world/ai_playerbot_rpg_races.sql \
  classicmangos:world/classic/ai_playerbot_enchants.sql \
  classicmangos:world/classic/ai_playerbot_named_location.sql \
  classicmangos:world/classic/ai_playerbot_travel_nodes.sql \
  classicmangos:world/classic/ai_playerbot_weightscales.sql \
  classicmangos:world/classic/ai_playerbot_zone_level.sql; do
  db=${item%%:*}; f=${item#*:}
  curl -fsSL "$RAW/$f" -o "$TMP/x.sql" || { echo "  ! couldn't download $f"; exit 1; }
  tables=$(grep -oiE 'CREATE TABLE (IF NOT EXISTS )?`[a-z_]+`' "$TMP/x.sql" | sed 's/.*`\(.*\)`/\1/' | sort -u)
  present=""; missing=""
  for t in $tables; do if has "$db" "$t"; then present="$present $t"; else missing="$missing $t"; fi; done
  if [ -z "$missing" ]; then echo "  = $f: already there"; continue; fi
  if [ -n "$present" ]; then echo "  ! $f: skipped, it would replace existing tables:$present (missing:$missing)"; continue; fi
  echo "  + $f -> $db ($(du -k "$TMP/x.sql" | cut -f1) KB)"
  sql "$db" < "$TMP/x.sql"
  applied=$((applied + 1))
done
# the world indexes script is plain ALTERs; errors there only mean an index already exists
curl -fsSL "$RAW/world/ai_playerbot_indexes.sql" -o "$TMP/i.sql" && sql classicmangos -f < "$TMP/i.sql" >/dev/null 2>&1 || true
echo "$applied script(s) applied."
if [ "$applied" -gt 0 ]; then
  echo "Restarting the world server (about a minute; the first start with the bot AI builds its caches)."
  docker compose restart mangosd
fi
