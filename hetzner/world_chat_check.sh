#!/usr/bin/env bash
# After a realm update: is World chat live, does it reach Discord, does the bug button reach #bug-reports?
#
#   bash hetzner/world_chat_check.sh          (as root on the server, after Server.bat 1 and herald_up.sh)
#
# 1. Herald Lite logs in on the live realm (devkit/heraldlite/scenarios/world_chat.txt): checks it is in
#    World (WO 1), says a line with a fresh nonce in World and sees it come back, sends one bug report
#    (BG ok).
# 2. The database: the World line is in classiccharacters.openvanilla_world_log (Herald's #world feed) and
#    the report in openvanilla_bug_report.
# 3. Herald: within 60 s the bug report is marked posted (it is in #bug-reports) and the bridge has read
#    past the World line (it went to #world).
# Prints PASS/FAIL per check; exits 1 if any failed. Needs Herald Lite (devkit/staging/staging_up.sh
# build-heraldlite) and /opt/wenilla-realm/heraldlite.env with a LIVE login:
#   HL_WEB=https://play.openvanilla.app  HL_USER=herald  HL_PASS=...  (HL_CHAR=Herald optional)
set -uo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
LIVE_CP=${OW_CP:-/opt/openvanilla-classicplus}
BIN=${HL_BIN:-/opt/openvanilla-staging/bin/heraldlite}
HERALD_DB=${HERALD_DB:-/opt/openvanilla-herald/herald.db}
ENVF=$REALM_DIR/heraldlite.env
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCN=$LIVE_CP/repo/devkit/heraldlite/scenarios/world_chat.txt
[ -f "$SCN" ] || SCN=$HERE/devkit/heraldlite/scenarios/world_chat.txt
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
[ -x "$BIN" ] || { echo "Herald Lite isn't built: bash devkit/staging/staging_up.sh build-heraldlite"; exit 1; }
[ -f "$ENVF" ] || { printf 'No %s. Make it with a live login (chmod 600):\n  HL_WEB=https://play.openvanilla.app\n  HL_USER=herald\n  HL_PASS=...\n' "$ENVF"; exit 1; }
cd "$REALM_DIR" || exit 1
set -a; . ./.env; . "$ENVF"; set +a
export HL_NONCE="$(date +%s)$RANDOM"
fails=0
ok()  { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
sql() { MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N classiccharacters -e "$1" 2>/dev/null; }

echo "== Herald Lite in game (nonce $HL_NONCE)"
OUT=$LIVE_CP/last-world-check.json
"$BIN" -s "$SCN" > "$OUT"; rc=$?
if [ $rc -eq 0 ]; then ok "in World (WO 1), the World line came back, the bug report was taken (BG ok)"
else bad "Herald Lite scenario (report: $OUT)"; tail -c 1500 "$OUT"; echo; fi

echo "== Database"
WID=$(sql "SELECT MAX(id) FROM openvanilla_world_log WHERE text LIKE '%world check $HL_NONCE%'")
if [ -n "$WID" ] && [ "$WID" != NULL ]; then ok "World line logged for the bridge (openvanilla_world_log id $WID)"
else bad "no World line with the nonce in openvanilla_world_log (is patch 0007 in the running mangosd and classicplus_world.sql applied?)"; WID=""; fi
BID=$(sql "SELECT MAX(id) FROM openvanilla_bug_report WHERE text LIKE '%bug check $HL_NONCE%'")
if [ -n "$BID" ] && [ "$BID" != NULL ]; then ok "bug report stored (openvanilla_bug_report id $BID)"
else bad "no bug report with the nonce in openvanilla_bug_report"; BID=""; fi

echo "== Herald (Discord)"
posted=""; seen=""
for _ in $(seq 1 12); do
  [ -n "$BID" ] && [ -z "$posted" ] && [ "$(sql "SELECT posted FROM openvanilla_bug_report WHERE id = $BID")" = 1 ] && posted=1
  if [ -n "$WID" ] && [ -z "$seen" ] && [ -f "$HERALD_DB" ]; then
    last=$(python3 -c "import sqlite3,sys;c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True);r=c.execute(\"SELECT value FROM bridge_state WHERE key='last_id'\").fetchone();print(r[0] if r else 0)" "$HERALD_DB" 2>/dev/null || echo 0)
    [ "${last:-0}" -ge "$WID" ] 2>/dev/null && seen=1
  fi
  { [ -n "$posted" ] || [ -z "$BID" ]; } && { [ -n "$seen" ] || [ -z "$WID" ]; } && break
  sleep 5
done
[ -n "$BID" ] && { [ -n "$posted" ] && ok "bug report posted to #bug-reports" || bad "bug report not posted after 60 s (journalctl -u openvanilla-herald | grep -i bugs; did herald_up.sh grant the table?)"; }
if [ -n "$WID" ]; then
  if [ -n "$seen" ]; then ok "the bridge read the World line (it is in #world)"
  elif [ ! -f "$HERALD_DB" ]; then bad "no $HERALD_DB: is Herald installed (hetzner/herald_up.sh)?"
  else bad "the bridge hasn't read the World line after 60 s (journalctl -u openvanilla-herald | grep -i bridge; BRIDGE_ENABLED=1?)"; fi
fi
echo
[ $fails -eq 0 ] && { echo "All checks passed: World chat and the bug button reach Discord."; exit 0; }
echo "$fails check(s) failed."; exit 1
