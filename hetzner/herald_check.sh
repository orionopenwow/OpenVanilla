#!/usr/bin/env bash
# Is Herald working on the live realm? Herald Lite logs in as its own bot account's character,
# hands it to Herald (.bot self), gives Herald the "Level up" goal, watches for 90 s, takes it back
# and logs out (devkit/heraldlite/scenarios/herald_selfbot.txt). Then the database must show the
# character somewhere else than before.
#
#   bash hetzner/herald_check.sh          (as root on the server; HL_PLAY=3m for a longer watch)
#
# Needs Herald Lite (bash devkit/staging/staging_up.sh build-heraldlite) and
# /opt/wenilla-realm/heraldlite.env with a LIVE login (chmod 600):
#   HL_WEB=https://play.openvanilla.app  HL_USER=herald  HL_PASS=...  (HL_CHAR=Herald optional)
set -uo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
LIVE_CP=${OW_CP:-/opt/openvanilla-classicplus}
BIN=${HL_BIN:-/opt/openvanilla-staging/bin/heraldlite}
ENVF=$REALM_DIR/heraldlite.env
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCN=$LIVE_CP/repo/devkit/heraldlite/scenarios/herald_selfbot.txt
[ -f "$SCN" ] || SCN=$HERE/devkit/heraldlite/scenarios/herald_selfbot.txt
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
[ -x "$BIN" ] || { echo "Herald Lite isn't built: bash $LIVE_CP/repo/devkit/staging/staging_up.sh build-heraldlite"; exit 1; }
[ -f "$ENVF" ] || { printf 'No %s. Make it with a live login (chmod 600):\n  HL_WEB=https://play.openvanilla.app\n  HL_USER=herald\n  HL_PASS=...\n' "$ENVF"; exit 1; }
cd "$REALM_DIR" || exit 1
set -a; . ./.env; . "$ENVF"; set +a
CHAR=${HL_CHAR:-Herald}
fails=0
ok()  { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
sql() { MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N classiccharacters -e "$1" 2>/dev/null; }
pos() { sql "SELECT CONCAT(ROUND(position_x,1),' ',ROUND(position_y,1),' ',map) FROM characters WHERE name = '$CHAR'"; }

echo "== Realm settings"
CONF=$(docker compose exec -T -u 0 mangosd cat /config/aiplayerbot.conf 2>/dev/null)
echo "$CONF" | grep -Eq '^\s*AiPlayerbot\.Enabled\s*=\s*1' && ok "bot AI on" || bad "AiPlayerbot.Enabled isn't 1 (bash hetzner/herald_selfbot.sh on)"
echo "$CONF" | grep -Eq '^\s*AiPlayerbot\.SelfBotLevel\s*=\s*[2-5]' && ok "players may hand over (SelfBotLevel 2+)" || bad "SelfBotLevel isn't 2 (bash hetzner/herald_selfbot.sh on)"

echo "== Herald plays $CHAR for ${HL_PLAY:-90s}"
BEFORE=$(pos)
OUT=$LIVE_CP/last-herald-check.json
"$BIN" -s "$SCN" > "$OUT"; rc=$?
if [ $rc -eq 0 ]; then ok "handed over (Enable player ai), took the goal (Sending command), handed back (Disable player ai)"
else bad "Herald Lite scenario (report: $OUT)"; tail -c 1500 "$OUT"; echo; fi
AFTER=$(pos)
if [ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ]; then ok "$CHAR moved while Herald played ($BEFORE -> $AFTER)"
else bad "$CHAR is where it was ($AFTER): Herald didn't move it"; fi

[ $fails -eq 0 ] && echo "Herald works." || { echo "$fails check(s) failed."; exit 1; }
