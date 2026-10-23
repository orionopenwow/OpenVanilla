#!/usr/bin/env bash
# Boss Fights: raids at level 60 by queue, a fresh copy of the raid for every group. An add-on to the Duels
# stack (duels_up.sh): the same world server and the same hangout, Gurubashi Arena, where duelers and raiders
# stand together in two separate modes. realm/mangos/0050-openvanilla-bossfights.patch, realm/bossfights/README.md.
#
#   bash bossfights_up.sh enable      once, on the Duels stack: the raids' spawns back from the live world,
#                                     Boss Fights' SQL, OpenVanilla.BossFights = 1 in its mangosd.conf, a restart,
#                                     the website timer
#   bash bossfights_up.sh update      the same again; run it after every duels_up.sh update (that one empties
#                                     the raids again with duels_lean.sql and rewrites the config); restarts
#   bash bossfights_up.sh site        its address (https://bossfights.openvanilla.app) and no realm list: the
#                                     website's realm name set to the realm list's (no restart)
#   bash bossfights_up.sh off         OpenVanilla.BossFights = 0 and a restart (the tables stay)
#   bash bossfights_up.sh status | live
#   bash bossfights_up.sh selftest on | off | now
#                                     the self-test (hetzner/bossfights_check.sh, realm/mangos/0051): two test
#                                     accounts (BFTEST*) play the whole mode every 2 hours and after every update;
#                                     the report: https://<live domain>/community/bossfights_selftest.json.
#                                     on: OpenVanilla.BossFights.SelfTest = 1 (test accounts only: their own queue,
#                                     test commands, never on the website), a restart, the timer, a first run
#   bash bossfights_up.sh testbots on [ACCOUNT...] | off
#                                     playtesting with bots: the bot AI on with no random-bot pool, each ACCOUNT a
#                                     GM (".rndbot group size=5 temporary=1" in game fills your party with level-60
#                                     bots); off deletes those bots and puts the AI settings and GM levels back.
#                                     The live realm is never touched: only the Duels stack's config and databases.
#
# The hangout is Duels' own (OpenVanilla.Duels.Hub, .Hub.Fence in the stack's mangosd.conf): Boss Fights reads
# those settings itself and defines no second fence. "status" prints the hangout the server will use.
# The player's path: Fight now (Boss Fights) on the site -> https://<duels domain>/ with the mode -> sign in ->
# the character screen (kept: realm patch 0035 skipped it and was removed, 47566a9) -> in the world the Boss
# Fights addon opens and sends ".wnl wf bf go" -> in Boss Fights, in the hangout -> queue -> the raid.
# Website: https://<live domain>/community/bossfights_live.json (counts, runs now, boards, latest runs).
set -euo pipefail
LIVE=/opt/wenilla-realm
LIVE_CP=/opt/openvanilla-classicplus
S=/opt/wenilla-duels                   # the Duels stack (duels_up.sh)
DCP=/opt/openvanilla-duels
BCP=/opt/openvanilla-bossfights        # Boss Fights' files
PUB=/opt/openvanilla-herald/public     # the live Caddy serves it at /community/
RAW=${OW_RAW:-https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable}
RAID_MAPS="249, 409, 469, 309, 509, 531, 533"
say() { printf '\n\033[1;36m== bossfights: %s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cmd=${1:-status}; shift || true

livevol() { docker volume ls -q --filter "label=com.docker.compose.project=wenilla-realm" --filter "label=com.docker.compose.volume=$1" | head -1; }
dvol() { docker volume ls -q --filter "label=com.docker.compose.project=owduels" --filter "label=com.docker.compose.volume=$1" | head -1; }
wait_healthy() {  # wait_healthy SERVICE MAX_SECONDS
  local s=starting
  for _ in $(seq 1 $(($2 / 10))); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$S" && docker compose ps -q "$1")" 2>/dev/null || echo starting)
    [ "$s" = healthy ] && return 0; sleep 10
  done
  echo "$1: $s after $2 s"; return 1
}
# The world server's own database login (mangosd.conf WorldDatabaseInfo), as duels_up.sh keeps it in
# $DCP/.dbinfo (mode 600). Never printed.
dbinfo() {
  if [ ! -s "$DCP/.dbinfo" ]; then
    local CFG; CFG=$(dvol config); [ -n "$CFG" ] || return 1
    ( umask 077; docker run --rm -v "$CFG":/c:ro debian:bookworm-slim sh -c 'grep -i "^WorldDatabaseInfo" /c/mangosd.conf' | cut -d'"' -f2 > "$DCP/.dbinfo" )
  fi
  cat "$DCP/.dbinfo"
}
# The live realm's, read the same way from live's config volume (kept in $BCP/.livedbinfo, mode 600).
livedbinfo() {
  if [ ! -s "$BCP/.livedbinfo" ]; then
    local CFG; CFG=$(livevol config); [ -n "$CFG" ] || return 1
    ( umask 077; docker run --rm -v "$CFG":/c:ro debian:bookworm-slim sh -c 'grep -i "^WorldDatabaseInfo" /c/mangosd.conf' | cut -d'"' -f2 > "$BCP/.livedbinfo" )
  fi
  cat "$BCP/.livedbinfo"
}
sql() {  # sql DATABASE FILE   (the Duels stack)
  (cd "$S" && docker compose exec -T -e C="$(dbinfo)" mariadb sh -c 'U=$(echo "$C" | cut -d";" -f3); W=$(echo "$C" | cut -d";" -f4); MYSQL_PWD="$W" exec mariadb -u"$U" "$@"' sh "$1") < "$2"
}
sqle() {  # sqle DATABASE "STATEMENT"
  (cd "$S" && docker compose exec -T -e C="$(dbinfo)" mariadb sh -c 'U=$(echo "$C" | cut -d";" -f3); W=$(echo "$C" | cut -d";" -f4); MYSQL_PWD="$W" exec mariadb -u"$U" "$@"' sh "$1" -e "$2")
}

CONF_KEYS=(
  "OpenVanilla.BossFights=1"                       # patch 0050
  "OpenVanilla.BossFights.Only=0"                  # Duels' realm: a character is a dueler until "go" or "q"
  "OpenVanilla.BossFights.Raids=\"onyxia mc\""     # the first raids; later: onyxia mc bwl zg aq20 aq40 naxx
  # no OpenVanilla.BossFights.Lobby: the lobby is Duels' hangout (OpenVanilla.Duels.Hub, .Hub.Fence)
  "OpenVanilla.BossFights.RaidSize=${RAIDSIZE:-10}"         # RAIDSIZE=5 bash bossfights_up.sh update: playtests
  "OpenVanilla.BossFights.MinTanks=2"
  "OpenVanilla.BossFights.MinHealers=2"
  "OpenVanilla.BossFights.RelaxRolesSeconds=${RELAX:-120}"  # RELAX=0: roles never wait (playtests)
  "OpenVanilla.BossFights.MaxTier=5"
  "OpenVanilla.BossFights.PortSeconds=60"
  "OpenVanilla.BossFights.RunMinutes=120"
  "OpenVanilla.BossFights.LeaverMinutes=10"
  "Instance.UnloadDelay=60000"                     # a finished run's raid copy goes after a minute (as Duels)
)
# The self-test's settings (selftest on), kept through every update while $BCP/selftest.on exists
SELFTEST_KEYS=(
  "OpenVanilla.BossFights.SelfTest=1"              # patch 0051: test accounts, their own queue, test commands
  "OpenVanilla.BossFights.TestAccounts=\"BFTEST*\""  # the accounts hetzner/bossfights_check.sh makes
)
[ -e "$BCP/selftest.on" ] && CONF_KEYS+=("${SELFTEST_KEYS[@]}")

fetch() {
  mkdir -p "$BCP"
  local REPO; REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  get() {
    if [ -f "$REPO/$1" ]; then cp "$REPO/$1" "$2.new" && mv "$2.new" "$2"
    else curl -fsSL "$RAW/$1" -o "$2.new" && mv "$2.new" "$2"; fi
  }
  for f in bossfights_world.sql bossfights_lean.sql bossfights_characters.sql; do get "realm/bossfights/$f" "$BCP/$f"; done
}

# duels_lean.sql emptied the world but the hangout: the raids' spawns are copied back from the live realm's
# world database (stock spawns, same guids: REPLACE). Then bossfights_lean.sql keeps exactly the hangout (as
# duels_lean.sql does) and the raids.
restore_spawns() {
  local W="\`map\` IN ($RAID_MAPS)"
  local C="\`guid\` IN (SELECT \`guid\` FROM \`creature\` WHERE $W)"
  local G="\`guid\` IN (SELECT \`guid\` FROM \`gameobject\` WHERE $W)"
  local OUT="$BCP/spawns.sql"
  livedbinfo >/dev/null || { echo "   no live config volume: cannot copy the raids' spawns"; return 1; }
  dump() {  # dump TABLE WHERE
    (cd "$LIVE" && docker compose exec -T -e C="$(livedbinfo)" mariadb sh -c 'U=$(echo "$C" | cut -d";" -f3); W=$(echo "$C" | cut -d";" -f4); D=$(echo "$C" | cut -d";" -f5); MYSQL_PWD="$W" exec mariadb-dump -u"$U" --single-transaction --skip-lock-tables --no-create-info --replace --compact --skip-triggers "$D" "$@"' sh "$1" --where="$2")
  }
  ( umask 077
    {
      dump creature "$W"; dump gameobject "$W"
      dump creature_addon "$C"; dump creature_movement "\`Id\` IN (SELECT \`guid\` FROM \`creature\` WHERE $W)"
      dump creature_linking "$C"; dump creature_spawn_data "\`Guid\` IN (SELECT \`guid\` FROM \`creature\` WHERE $W)"
      dump creature_conditional_spawn "\`Guid\` IN (SELECT \`guid\` FROM \`creature\` WHERE $W)"
      dump game_event_creature "$C"; dump pool_creature "$C"
      dump gameobject_addon "$G"; dump game_event_gameobject "$G"; dump pool_gameobject "$G"
      dump spawn_group_spawn "\`Guid\` IN (SELECT \`guid\` FROM \`creature\` WHERE $W) OR \`Guid\` IN (SELECT \`guid\` FROM \`gameobject\` WHERE $W)"
    } > "$OUT" )
  echo "   $(grep -c '^REPLACE' "$OUT") statements from the live world"
  sql classicmangos "$OUT"
  rm -f "$OUT"
}

apply_sql() {
  echo "   classicmangos < bossfights_world.sql"; sql classicmangos "$BCP/bossfights_world.sql"
  echo "   classicmangos < bossfights_lean.sql"; sql classicmangos "$BCP/bossfights_lean.sql"
  echo "   classiccharacters < bossfights_characters.sql"; sql classiccharacters "$BCP/bossfights_characters.sql"
}

write_conf() {
  local CFG; CFG=$(dvol config)
  [ -n "$CFG" ] || { echo "no Duels config volume (bash duels_up.sh install first)"; return 1; }
  printf '%s\n' "${CONF_KEYS[@]}" | sed 's/ *# .*$//' > "$BCP/bossfights.conf.keys"
  docker run --rm -v "$CFG":/config -v "$BCP/bossfights.conf.keys":/keys:ro debian:bookworm-slim sh -c '
    f=/config/mangosd.conf
    [ -e $f.before-bossfights ] || cp $f $f.before-bossfights
    while read -r kv; do
      k=${kv%%=*}; v=${kv#*=}
      [ -n "$k" ] || continue
      if grep -q "^$k *=" $f; then sed -i "s|^$k *=.*|$k = $v|" $f; else printf "%s = %s\n" "$k" "$v" >> $f; fi
    done < /keys
    grep -c "^OpenVanilla\.BossFights" $f | sed "s/^/   boss fights settings: /"'
  # raid copies on top of the inn and the arena: give the world server more room (only ever raised)
  local mem; mem=$(grep '^MANGOSD_MEM=' "$S/.env" | cut -d= -f2 | tr -dc 0-9)
  if [ -n "$mem" ] && [ "$mem" -lt 2600 ]; then sed -i 's/^MANGOSD_MEM=.*/MANGOSD_MEM=2600m/' "$S/.env"; echo "   MANGOSD_MEM 2600m"; fi
}

# The hangout this world server uses for both modes (Duels' settings), and a warning when it is not Gurubashi
hub() {
  local CFG; CFG=$(dvol config); [ -n "$CFG" ] || return 0
  docker run --rm -v "$CFG":/c:ro debian:bookworm-slim sh -c 'grep -h "^OpenVanilla\.Duels\.Hub\|^OpenVanilla\.BossFights\.Lobby" /c/mangosd.conf' \
    | sed 's/^/   /' | tee "$BCP/hub.txt"
  if ! grep -q "Duels.Hub *= *\"0 -132" "$BCP/hub.txt" 2>/dev/null; then
    echo "   NOTE: the Duels hangout is not Gurubashi Arena (map 0, x -132xx). Boss Fights uses the same hangout;"
    echo "         duels_world.sql starts characters in Gurubashi and duels_lean.sql keeps only Gurubashi's spawns."
  fi
}

restart() {
  cd "$S"; docker compose up -d --no-deps --force-recreate mangosd
  wait_healthy mangosd 900 && echo "the Modes world server is up"
}

# The website's Boss Fights page: counts, runs now, the fastest clears per raid and tier, the latest runs.
write_live() {
  local live now board feed out=$PUB/bossfights_live.json
  mkdir -p "$PUB"
  live=$(sqle classiccharacters "SELECT line, updated, UNIX_TIMESTAMP() FROM warfront_live WHERE id = 2" 2>/dev/null | tail -n +2 | head -1) || live=""
  now=$(sqle classiccharacters "SELECT run, raid, tier, size, started, bosses, encounters FROM bossfights_now" 2>/dev/null | tail -n +2) || now=""
  # runs with bots rank on their own boards; self-test runs (test = 1, patch 0051) are never shown
  board=$(sqle classiccharacters "SELECT raid, tier, length_ms, members, size, ended, bots FROM (
        SELECT raid, tier, length_ms, members, size, ended, bots,
               ROW_NUMBER() OVER (PARTITION BY raid, tier, bots > 0 ORDER BY length_ms) AS n
        FROM bossfights_result WHERE cleared = 1 AND length_ms > 0 AND test = 0) b WHERE n <= 10 ORDER BY raid, tier, length_ms" 2>/dev/null | tail -n +2) || board=""
  feed=$(sqle classiccharacters "SELECT raid, tier, size, affixes, ended, length_ms, cleared, wipes, deaths, members, bots
      FROM bossfights_result WHERE test = 0 ORDER BY id DESC LIMIT 25" 2>/dev/null | tail -n +2) || feed=""
  LIVE_ROW="$live" NOW="$now" BOARD="$board" FEED="$feed" python3 - "$out" <<'PY'
import json, os, sys, time
NAMES = {"onyxia": "Onyxia's Lair", "mc": "Molten Core", "bwl": "Blackwing Lair", "zg": "Zul'Gurub",
         "aq20": "Ruins of Ahn'Qiraj", "aq40": "Temple of Ahn'Qiraj", "naxx": "Naxxramas"}
CLASS = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}
def num(x):
    try: return int(x)
    except Exception: return 0
def members(text):
    out = []
    for m in text.split(","):
        f = (m.split(":") + ["", "0", "", ""])[:4]
        if f[0]: out.append({"name": f[0], "class": CLASS.get(num(f[1]), ""), "role": f[2], "bot": f[3] == "bot"})
    return out
now = int(time.time())
# boards: the fastest clears per raid and tier by people only; boards_bots: runs that had bots in them
out = {"updated": 0, "stale": True, "runs": 0, "raiding": 0, "queued": 0, "raids": NAMES, "now": [],
       "boards": {}, "boards_bots": {}, "feed": []}
row = os.environ.get("LIVE_ROW", "").split("\t")
if len(row) == 3:
    n = [num(x) for x in row[0].split(",")] + [0] * 3
    out["updated"], now = num(row[1]), num(row[2]) or now
    out["stale"] = now - out["updated"] > 90
    out["runs"], out["raiding"], out["queued"] = n[0], n[1], n[2]
for l in os.environ.get("NOW", "").splitlines():
    f = l.split("\t")
    if len(f) < 7: continue
    out["now"].append({"run": num(f[0]), "raid": f[1], "tier": num(f[2]), "size": num(f[3]),
                       "seconds": max(0, now - num(f[4])), "bosses": num(f[5]), "of": num(f[6])})
for l in os.environ.get("BOARD", "").splitlines():
    f = l.split("\t")
    if len(f) < 7: continue
    m = members(f[3])
    out["boards_bots" if num(f[6]) > 0 else "boards"].setdefault(f[0], {}).setdefault(f[1], []).append(
        {"ms": num(f[2]), "leader": m[0]["name"] if m else "", "size": num(f[4]), "t": num(f[5]), "members": m})
for l in os.environ.get("FEED", "").splitlines():
    f = l.split("\t")
    if len(f) < 11: continue
    out["feed"].append({"raid": f[0], "tier": num(f[1]), "size": num(f[2]), "bots": num(f[10]), "affixes": num(f[3]), "t": num(f[4]),
                        "ms": num(f[5]), "cleared": f[6] == "1", "wipes": num(f[7]), "deaths": num(f[8]),
                        "members": members(f[9])})
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as fh:
    json.dump(out, fh, separators=(",", ":"))
os.replace(tmp, sys.argv[1])
PY
}

timer() {
  local name=openvanilla-bossfights-live
  cat > /etc/systemd/system/$name.service <<UNIT
[Unit]
Description=Open Vanilla Boss Fights: live for the website
[Service]
Type=oneshot
ExecStart=/bin/bash $LIVE_CP/repo/hetzner/bossfights_up.sh live
UNIT
  cat > /etc/systemd/system/$name.timer <<UNIT
[Unit]
Description=Open Vanilla Boss Fights: live, every 20 s
[Timer]
OnBootSec=90
OnUnitActiveSec=20
AccuracySec=5
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now $name.timer >/dev/null
  echo "   website: $PUB/bossfights_live.json every 20 s"
}

# Its own address (owner, 23 Oct): https://bossfights.openvanilla.app is the same realm service and world
# server as Duels (one sign-in, one realm), but its front page always opens in Boss Fights: "/" without a
# mode goes to "/?mode=boss&raid=any", which openvanilla.js hands to the Boss Fights addon after the
# character screen. The live Caddy serves it: Caddyfile.site here is appended to the live Caddyfile now, and
# by the live realm_up on every later update (it adds every /opt/openvanilla-*/Caddyfile.site).
# Sign-in with Google there finishes on the Duels address (the realm service has one public address).
BF_DOMAIN=${BOSSFIGHTS_DOMAIN:-bossfights.openvanilla.app}
caddy_site() {
  cat > "$BCP/Caddyfile.site" <<CADDY

# Boss Fights (hetzner/bossfights_up.sh): the Duels realm service, opening in Boss Fights.
$BF_DOMAIN {
	encode zstd gzip
	@owsw path /ow/sw.js
	header @owsw Service-Worker-Allowed "/"
	@shared path /data/* /wenilla_bg.wasm
	header @shared >Vary "Accept-Encoding"
	@front {
		path /
		not query mode=*
	}
	redir @front /?mode=boss&raid=any 302
	handle {
		reverse_proxy owduels-realm:8090 {
			# the player's own address, never one it sent: guest limits and rated matchmaking key on it
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
		}
	}
	header -Server
}
CADDY
  if ! grep -q "^$BF_DOMAIN {" "$LIVE_CP/Caddyfile" 2>/dev/null; then cat "$BCP/Caddyfile.site" >> "$LIVE_CP/Caddyfile"; fi
  (cd "$LIVE" && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile) >/dev/null 2>&1 \
    && echo "   https://$BF_DOMAIN (DNS: an A record to this server, like the Duels one)" \
    || echo "   (reload Caddy by hand: cd $LIVE && docker compose restart caddy)"
}

# No realm list: the game skips it when the realm the website names (its "realm_name", typed at /setup) is
# the realm the realm list shows. duels_up.sh renames the realm list's realm ("Duels") but not the website's,
# so the two drifted ("Our Realm") and every new player saw the list. Copy the realm list's name over.
realm_name_sync() {
  local name st
  name=$(sqle classicrealmd "SELECT name FROM realmlist WHERE id = 1" | tail -n 1)
  [ -n "$name" ] || { echo "   (no realm in the realm list yet)"; return 0; }
  st=$(cd "$S" && docker inspect -f '{{range .Mounts}}{{if eq .Destination "/state"}}{{.Source}}{{end}}{{end}}' "$(docker compose ps -q realm)" 2>/dev/null)
  [ -n "$st" ] && [ -f "$st/realm.sqlite" ] || { echo "   (the realm service's state not found: realm name left as it is)"; return 0; }
  python3 - "$st/realm.sqlite" "$name" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=10)
c.execute("INSERT INTO meta (key, value) VALUES ('realm_name', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", (sys.argv[2],))
c.commit()
PY
  echo "   the website's realm name is now \"$name\" (the realm list's): players go straight to their characters"
}

# Playtesting with bots (the pinned playerbots, 31e0f32). Cheapest way to fill a raid: ".rndbot group size=N"
# (GM only) makes N-1 bots at the leader's level with classes that fit the roles, on RNDBOT accounts made on
# demand (a GM's own account holds at most 9 characters, too few for ".bot create"), logs them in where the
# leader stands and puts them in the leader's party. "temporary=1" marks them: the bot AI deletes them (and
# their emptied accounts) at its next start. RandomBotAutologin must be on (it is what logs created bots in),
# with no random-bot pool (Min/Max 0) and no accounts made ahead (AutoCreate 0). Gear: the bot factory's
# level-60 pick (the hangout's Duels outfitting does not touch Boss Fights characters, bots in a raid party
# included once queued). Duels' own practice and hangout bots (patches 0033, 0035) are kept: nothing here
# deletes bot accounts wholesale.
BOT_KEYS_TOUCHED="AiPlayerbot.Enabled AiPlayerbot.RandomBotAutologin AiPlayerbot.MinRandomBots AiPlayerbot.MaxRandomBots AiPlayerbot.RandomBotAutoCreate AiPlayerbot.RandomBotLoginWithPlayer"
TESTBOT_ON=(
  "AiPlayerbot.Enabled=1"
  "AiPlayerbot.RandomBotAutologin=1"
  "AiPlayerbot.MinRandomBots=0"
  "AiPlayerbot.MaxRandomBots=0"
  "AiPlayerbot.RandomBotAutoCreate=0"
  "AiPlayerbot.RandomBotLoginWithPlayer=0"
)
bot_conf() {  # bot_conf KEY=VALUE...   (aiplayerbot.conf on the Duels stack); a key set to "-" is removed
  local CFG; CFG=$(dvol config); [ -n "$CFG" ] || { echo "no Duels config volume"; return 1; }
  printf '%s\n' "$@" > "$BCP/bots.conf.keys"
  docker run --rm -v "$CFG":/config -v "$BCP/bots.conf.keys":/keys:ro debian:bookworm-slim sh -c '
    f=/config/aiplayerbot.conf
    [ -e $f ] || { echo "   no aiplayerbot.conf"; exit 1; }
    while read -r kv; do
      k=${kv%%=*}; v=${kv#*=}
      [ -n "$k" ] || continue
      if [ "$v" = "-" ]; then sed -i "/^$k *=/d" $f
      elif grep -q "^$k *=" $f; then sed -i "s|^$k *=.*|$k = $v|" $f; else printf "%s = %s\n" "$k" "$v" >> $f; fi
    done < /keys
    grep "^AiPlayerbot\.\(Enabled\|RandomBotAutologin\|MaxRandomBots\)" $f | sed "s/^/   /"'
}
bot_conf_now() {  # the touched keys as they are now, KEY=VALUE (or KEY=- when absent)
  local CFG; CFG=$(dvol config)
  docker run --rm -v "$CFG":/c:ro -e KEYS="$BOT_KEYS_TOUCHED" debian:bookworm-slim sh -c '
    for k in $KEYS; do v=$(grep "^$k *=" /c/aiplayerbot.conf 2>/dev/null | tail -1 | sed "s/^[^=]*= *//"); echo "$k=${v:--}"; done'
}
testbots() {
  case "${1:-}" in
  on)
    shift
    local acct was
    for acct in "$@"; do
      case "$acct" in *[!A-Za-z0-9_]*|"") echo "   an account name is letters, digits and _"; return 1 ;; esac
      # the tester's account becomes a GM (.rndbot, .die); the old level is kept to put back
      was=$(sqle classicrealmd "SELECT gmlevel FROM account WHERE username = UPPER('$acct')" | tail -n +2 | head -1)
      [ -n "$was" ] || { echo "   no account $acct"; return 1; }
      grep -qi "^$acct " "$BCP/testbots.gm" 2>/dev/null || printf '%s %s\n' "$acct" "$was" >> "$BCP/testbots.gm"
      sqle classicrealmd "UPDATE account SET gmlevel = 3 WHERE username = UPPER('$acct')"
      echo "   $acct is a GM until testbots off"
    done
    [ -s "$BCP/testbots.before" ] || bot_conf_now > "$BCP/testbots.before"     # put back by "off"
    bot_conf "${TESTBOT_ON[@]}"; restart
    cat <<TXT
Bots on. In game (a GM, in the hangout, in Boss Fights: .wnl wf bf go, your role set):
  .rndbot group size=5 temporary=1      four level-60 bots in your party (size=10: nine)
  .wnl wf bf q onyxia                   your party queues; the bots count as members and the run is marked
Off again: bash $0 testbots off
TXT
    ;;
  off)
    # one start with the AI on deletes the temporary bots, then the settings as they were before "on"
    say "bots: the temporary bots go at this start, then the bot AI as it was"
    bot_conf "${TESTBOT_ON[@]}" "AiPlayerbot.RandomBotAutologin=0"; restart || true
    if [ -s "$BCP/testbots.before" ]; then
      mapfile -t before < "$BCP/testbots.before"
      bot_conf "${before[@]}" && rm -f "$BCP/testbots.before"
    fi
    restart || true
    if [ -s "$BCP/testbots.gm" ]; then
      while read -r acct was; do
        sqle classicrealmd "UPDATE account SET gmlevel = $was WHERE username = UPPER('$acct')" </dev/null && echo "   $acct: GM level $was again"
      done < "$BCP/testbots.gm"
      rm -f "$BCP/testbots.gm"
    fi
    sqle classiccharacters "SELECT COUNT(*) AS temporary_bots_left FROM ai_playerbot_random_bots WHERE event = 'temporary'" 2>/dev/null || true ;;
  *) echo "usage: $0 testbots on [ACCOUNT...] | off"; return 2 ;;
  esac
}

need_duels() { [ -e "$S/.env" ] || { echo "no Duels stack at $S: bash duels_up.sh install first"; exit 1; }; }

case "$cmd" in
enable)
  need_duels; mkdir -p "$BCP"
  avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  if [ "$avail" -lt 900 ] && [ "${FORCE:-0}" != 1 ]; then
    echo "Only ${avail} MB free; raid copies need ~800 MB more on the Modes world server. FORCE=1 to try anyway."; exit 1
  fi
  say "1/5 files"; fetch
  say "2/5 the raids' and Gurubashi Arena's spawns, from the live world"; restore_spawns
  say "3/5 SQL"; apply_sql
  say "4/5 settings (the hangout: Duels')"; write_conf; hub
  say "5/5 restart and the website timer"; restart || true; timer
  say "its address, and no realm list"; caddy_site; realm_name_sync
  cat <<TXT
Boss Fights is on (the Modes realm, with Duels). Try it:
  1. https://$(grep '^REALM_DOMAIN=' "$S/.env" | cut -d= -f2) -> a level 60 -> in the world: .wnl wf bf go   (Gurubashi Arena)
  2. .wnl wf bf role tank, then .wnl wf bf q onyxia    (OpenVanilla.BossFights.RaidSize=1 in mangosd.conf to test alone)
  3. When it works: BOSSFIGHTS_OPEN = 1 in www/downloads/links.txt shows the BOSS FIGHTS button.
TXT
  ;;
update)
  need_duels
  say "1/3 files"; fetch
  # duels_up.sh update runs duels_lean.sql again, which empties the raids: copy them back every time
  say "2/3 spawns, SQL and settings"; restore_spawns; apply_sql; write_conf; hub; timer
  say "3/3 restart"; restart
  caddy_site; realm_name_sync
  # the self-test once more on the new build (in the background; the report shows it)
  if [ -e "$BCP/selftest.on" ] && systemctl list-unit-files openvanilla-bossfights-selftest.service >/dev/null 2>&1; then
    systemctl start --no-block openvanilla-bossfights-selftest.service && echo "   self-test started (report in about 5 minutes)"
  fi ;;
selftest)
  need_duels; mkdir -p "$BCP"
  CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bossfights_check.sh"
  case "${1:-}" in
  on)
    touch "$BCP/selftest.on"
    say "self-test: settings, a restart, the timer and a first run"
    CONF_KEYS=("${SELFTEST_KEYS[@]}"); write_conf; restart
    bash "$CHECK" --watch on
    systemctl start --no-block openvanilla-bossfights-selftest.service
    echo "   first run started: journalctl -fu openvanilla-bossfights-selftest   (report: $PUB/bossfights_selftest.json)" ;;
  off)
    rm -f "$BCP/selftest.on"
    CONF_KEYS=("OpenVanilla.BossFights.SelfTest=0"); write_conf; restart
    bash "$CHECK" --watch off ;;
  now)
    bash "$CHECK" ;;
  *) echo "usage: $0 selftest on|off|now"; exit 2 ;;
  esac ;;
site)
  need_duels; mkdir -p "$BCP"; caddy_site; realm_name_sync ;;
off)
  need_duels
  CONF_KEYS=("OpenVanilla.BossFights=0"); mkdir -p "$BCP"; write_conf; restart ;;
status)
  need_duels
  hub
  sqle classiccharacters "SELECT line, FROM_UNIXTIME(updated) AS at FROM warfront_live WHERE id = 2;
    SELECT COUNT(*) AS runs, SUM(cleared) AS clears, SUM(ended > UNIX_TIMESTAMP() - 86400) AS today FROM bossfights_result;
    SELECT raid, MAX(best_tier) AS top_tier, COUNT(*) AS accounts FROM bossfights_progress GROUP BY raid" 2>/dev/null || true
  sqle classicmangos "SELECT map, COUNT(*) AS creatures FROM creature WHERE map IN ($RAID_MAPS) GROUP BY map" 2>/dev/null || true
  ls -la "$PUB/bossfights_live.json" 2>/dev/null || true ;;
live)
  [ -e "$S/.env" ] || exit 0
  write_live ;;
testbots)
  need_duels; mkdir -p "$BCP"; testbots "$@" ;;
*) echo "usage: $0 enable | update | site | off | status | live | selftest on|off|now | testbots on [ACCOUNT...]|off"; exit 2 ;;
esac
