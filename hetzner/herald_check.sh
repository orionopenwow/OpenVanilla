#!/usr/bin/env bash
# Is Herald working on the live realm? Herald Lite logs in as its own bot account's character,
# hands it to Herald (.bot self), gives Herald the "Level up" goal, watches for 90 s, takes it back
# and logs out (devkit/heraldlite/scenarios/herald_selfbot.txt). Then the database must show the
# character somewhere else than before.
#
#   bash hetzner/herald_check.sh          (as root on the server; HL_PLAY=3m for a longer watch)
#   bash hetzner/herald_check.sh --score  the scorecard: 15 minutes of play (HL_PLAY to change), then
#                                         XP/hour, money, items picked up, distance, alive at the end,
#                                         saved to herald-history.tsv and compared with the last run.
#                                         Run it after every world server or Herald change.
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
SCORE=0; [ "${1:-}" = "--score" ] && { SCORE=1; export HL_PLAY=${HL_PLAY:-15m}; }
HIST=$LIVE_CP/herald-history.tsv
fails=0
ok()  { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
sql() { MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N classiccharacters -e "$1" 2>/dev/null; }
pos() { sql "SELECT CONCAT(ROUND(position_x,1),' ',ROUND(position_y,1),' ',map) FROM characters WHERE name = '$CHAR'"; }
# everything the scorecard compares, in one row: level xp money x y map items dead(0/1)
snap() { sql "SELECT c.level, c.xp, c.money, ROUND(c.position_x,1), ROUND(c.position_y,1), c.map,
  (SELECT COUNT(*) FROM character_inventory i WHERE i.guid = c.guid),
  IF(c.health = 0 OR (c.playerFlags & 16) <> 0, 1, 0)
  FROM characters c WHERE c.name = '$CHAR'" | tr '\t' ' '; }

echo "== Realm settings"
CONF=$(docker compose exec -T -u 0 mangosd cat /config/aiplayerbot.conf 2>/dev/null)
echo "$CONF" | grep -Eq '^\s*AiPlayerbot\.Enabled\s*=\s*1' && ok "bot AI on" || bad "AiPlayerbot.Enabled isn't 1 (bash hetzner/herald_selfbot.sh on)"
echo "$CONF" | grep -Eq '^\s*AiPlayerbot\.SelfBotLevel\s*=\s*[2-5]' && ok "players may hand over (SelfBotLevel 2+)" || bad "SelfBotLevel isn't 2 (bash hetzner/herald_selfbot.sh on)"

echo "== Herald plays $CHAR for ${HL_PLAY:-90s}"
BEFORE=$(pos); S0=$(snap); T0=$(date +%s)
OUT=$LIVE_CP/last-herald-check.json
"$BIN" -s "$SCN" > "$OUT"; rc=$?
if [ $rc -eq 0 ]; then ok "handed over (Enable player ai), took the goal (Sending command), handed back (Disable player ai)"
else bad "Herald Lite scenario (report: $OUT)"; tail -c 1500 "$OUT"; echo; fi
AFTER=$(pos)
if [ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ]; then ok "$CHAR moved while Herald played ($BEFORE -> $AFTER)"
else bad "$CHAR is where it was ($AFTER): Herald didn't move it"; fi

if [ "$SCORE" = 1 ] && [ -n "$S0" ]; then
  S1=$(snap); T1=$(date +%s)
fi
if [ "$SCORE" = 1 ] && [ -n "$S0" ] && [ -z "$S1" ]; then
  bad "no scorecard: $CHAR couldn't be read at the end of the run"
elif [ "$SCORE" = 1 ] && [ -n "$S0" ]; then
  echo "== Scorecard ($CHAR, $(( (T1 - T0) / 60 )) min)"
  # XP across a level-up needs the level's XP table: player_xp_for_level (CMaNGOS world database)
  XPT=$(MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N classicmangos \
        -e "SELECT GROUP_CONCAT(CONCAT(lvl,':',xp_for_next_level)) FROM player_xp_for_level" 2>/dev/null)
  ROW=$(python3 - "$S0" "$S1" "$T0" "$T1" "$XPT" <<'PY'
import math, sys
a, b = [list(map(float, x.split())) for x in sys.argv[1:3]]
t = max(1, int(sys.argv[4]) - int(sys.argv[3]))
table = dict(tuple(map(int, p.split(":"))) for p in sys.argv[5].split(",") if ":" in p)
lv0, xp0, m0, x0, y0, map0, it0, _ = a
lv1, xp1, m1, x1, y1, map1, it1, dead = b
gained = xp1 - xp0
for lv in range(int(lv0), int(lv1)):
    gained += table.get(lv, 0)
dist = math.hypot(x1 - x0, y1 - y0) if map0 == map1 else float("nan")
row = dict(xp_per_hour=round(gained * 3600 / t), money=int(m1 - m0), items=int(it1 - it0),
           yards=round(dist), levels=int(lv1 - lv0), alive=int(not dead))
print("\t".join(f"{k}={v}" for k, v in row.items()))
PY
)
  printf '  %s\n' $ROW
  PREV=$(tail -1 "$HIST" 2>/dev/null | cut -f3-)
  # only a whole scorecard goes in the history (a half one would break the next comparison)
  echo "$ROW" | grep -q "xp_per_hour=" && printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$CHAR" "$ROW" >> "$HIST"
  if [ -n "$PREV" ]; then
    echo "  last run: $PREV"
    python3 - "$PREV" "$ROW" <<'PY'
import sys
p, c = [dict(kv.split("=") for kv in x.split("\t")) for x in sys.argv[1:3]]
worse = []
if int(c["alive"]) < int(p["alive"]): worse.append("died this time")
if float(c["xp_per_hour"]) < 0.85 * float(p["xp_per_hour"]): worse.append("XP/hour down more than 15%")
if int(c["items"]) < int(p["items"]) and int(p["items"]) > 0: worse.append("picked up fewer items")
print("  " + ("WORSE than last run: " + "; ".join(worse) if worse else "no worse than last run"))
PY
  fi
  echo "$ROW" | grep -q "alive=1" && ok "$CHAR ended the run alive" || bad "$CHAR was dead at the end"
fi

[ $fails -eq 0 ] && echo "Herald works." || { echo "$fails check(s) failed."; exit 1; }
