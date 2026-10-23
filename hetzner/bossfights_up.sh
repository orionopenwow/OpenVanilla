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
#   bash bossfights_up.sh selftest real on | off | now
#                                     the REAL Onyxia fight (mangos 0059): one test account watches, nine fill bots
#                                     fight with their Onyxia strategy, no test kill; once a day when on. Report:
#                                     https://<live domain>/community/bossfights_selftest_real.json (needs botfill on).
#   bash bossfights_up.sh botfill on | off | status
#                                     bot fill (realm/mangos/0054): a raid nobody else joins is filled with level-60
#                                     bots after 30 s (BOTFILL_AFTER), at most 18 logged in (BOTFILL_MAX), none below
#                                     600 MB free (BOTFILL_MINMB). on: the bot AI's tables on the Duels stack (once),
#                                     the bot AI on with no random bots, the settings, a restart. Kept through every
#                                     update while $BCP/botfill.on exists. off: no new bots (the AI goes off too unless
#                                     testbots is on). status: the settings, the kept bots, the ones online, memory.
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
# Bot fill's (botfill on), kept through every update while $BCP/botfill.on exists
# shellcheck disable=SC1091
[ -f "$BCP/botraid.env" ] && . "$BCP/botraid.env"
BOTFILL_KEYS=(
  "OpenVanilla.BossFights.BotFill=1"                         # patch 0054: bots fill the seats nobody takes
  "OpenVanilla.BossFights.BotFill.After=${BOTFILL_AFTER:-30}"  # seconds the oldest ticket waits first (0: at once)
  # mangos 0059: a raid that is at least half bots, at tier 1, softer (owner's call; 1.0 = as hard as with people).
  # Kept in $BCP/botraid.env (BOTRAID_HEALTH=0.75 and BOTRAID_DAMAGE=0.75, say), read on every update.
  "OpenVanilla.BossFights.BotRaid.Health=${BOTRAID_HEALTH:-1.0}"
  "OpenVanilla.BossFights.BotRaid.Damage=${BOTRAID_DAMAGE:-1.0}"
  "OpenVanilla.BossFights.BotFill.Max=${BOTFILL_MAX:-18}"      # most fill bots logged in at once
  "OpenVanilla.BossFights.BotFill.MinFreeMB=${BOTFILL_MINMB:-600}"   # no new bots below this much free memory
)
# The bot AI as bot fill needs it, and no more: on, no random bots at all (none made, none logged in), and none
# of the parts that load big tables at start for bots that roam the world: quest travel (the travel nodes, most
# of the ~1 GB the AI took on Duels, 2026-10-23), battlegrounds, LFG, guilds.
BOTFILL_BOTS=(
  "AiPlayerbot.Enabled=1"
  "AiPlayerbot.RandomBotAutologin=0"
  "AiPlayerbot.MinRandomBots=0"
  "AiPlayerbot.MaxRandomBots=0"
  "AiPlayerbot.RandomBotAutoCreate=0"
  "AiPlayerbot.RandomBotLoginWithPlayer=0"
  "AiPlayerbot.AutoDoQuests=0"
  "AiPlayerbot.RandomBotJoinBG=0"
  "AiPlayerbot.RandomBotJoinLfg=0"
  "AiPlayerbot.RandomBotGuildCount=0"
  # never a word in any channel (owner, 2026-10-23); each chance 0 (EnableBroadcasts=0 trips an urand(1,0)), no
  # AI chat, no talking without a master (the world server also drops any bot line in a channel: mangos 0057)
  "AiPlayerbot.BroadcastToSayGlobalChance=0" "AiPlayerbot.BroadcastToYellGlobalChance=0"
  "AiPlayerbot.BroadcastToGuildGlobalChance=0" "AiPlayerbot.BroadcastToWorldGlobalChance=0"
  "AiPlayerbot.BroadcastToGeneralGlobalChance=0" "AiPlayerbot.BroadcastToTradeGlobalChance=0"
  "AiPlayerbot.BroadcastToLFGGlobalChance=0" "AiPlayerbot.BroadcastToLocalDefenseGlobalChance=0"
  "AiPlayerbot.BroadcastToWorldDefenseGlobalChance=0" "AiPlayerbot.BroadcastToGuildRecruitmentGlobalChance=0"
  "AiPlayerbot.RandomBotSayWithoutMaster=0" "AiPlayerbot.LLMEnabled=0"
)
if [ -e "$BCP/botfill.on" ]; then CONF_KEYS+=("${BOTFILL_KEYS[@]}"); else CONF_KEYS+=("OpenVanilla.BossFights.BotFill=0"); fi

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
  if [ -n "$mem" ] && [ "$mem" -lt 2600 ]; then sed -i 's/^MANGOSD_MEM=.*/MANGOSD_MEM=2600m/' "$S/.env"; echo "   MANGOSD_MEM 2600m"; mem=2600; fi
  # bot fill: the bot AI's tables and the bots themselves (about 10-15 MB each logged in) on top. A limit, not a
  # reservation: 0054 stops asking for bots when the room under it falls below .BotFill.MinFreeMB
  local want=${BOTFILL_MEM:-3200}
  if [ -e "$BCP/botfill.on" ] && [ -n "$mem" ] && [ "$mem" -lt "$want" ]; then
    sed -i "s/^MANGOSD_MEM=.*/MANGOSD_MEM=${want}m/" "$S/.env"; echo "   MANGOSD_MEM ${want}m (bot fill)"
  fi
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
  # the newest world server image first (0050-0052 are compiled in by the realm-prebuild workflow)
  cd "$S"; docker compose pull -q mangosd || echo "   (could not pull a new world server image: starting the one here)"
  docker compose up -d --no-deps --force-recreate mangosd
  wait_healthy mangosd 900 && echo "the Modes world server is up"
}

# The website's Boss Fights data, every 20 s (the openvanilla-bossfights-live timer), from the characters database:
#   $PUB/bossfights_live.json          www/bossfights.html: counts, raids now, boards (people, with bots, hardcore),
#                                      the latest runs, this week's twist and fastest, the first clears; and
#                                      "recent", the finished runs Herald's recap cards read (bot/herald_bossfights.py)
#   $PUB/bossfights_runs/<id>.json     www/bossfights-run.html?id=<id>: one finished run (bossfights_result.id)
# Character names, classes and roles only: no accounts, no addresses. Self-test runs (test = 1) never appear, and
# practice or story runs (a later patch's `mode`) never rank. Columns a later patch adds (bossfights_result: mode,
# twist, feats, stats; bossfights_now: phase, bots, mode, twist, pulled; the bossfights_week table) are used when
# they are there, looked up every 10 minutes.
live_has() { grep -q "^$1	$2\$" "$BCP/.live_cols" 2>/dev/null; }
write_live() {
  local out=$PUB/bossfights_live.json runs=$PUB/bossfights_runs cols=$BCP/.live_cols raw week kind ok ropt nopt c q
  mkdir -p "$PUB" "$runs" "$BCP"
  if [ ! -s "$cols" ] || [ -n "$(find "$cols" -mmin +10 2>/dev/null)" ]; then
    sqle classiccharacters "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'bossfights%'" 2>/dev/null | tail -n +2 > "$cols.tmp" \
      && mv -f "$cols.tmp" "$cols"
  fi
  ropt=""; for c in mode twist feats stats; do live_has bossfights_result "$c" && ropt="$ropt, $c"; done
  nopt=""; for c in phase bots mode twist pulled; do live_has bossfights_now "$c" && nopt="$nopt, $c"; done
  if live_has bossfights_result mode; then
    kind="CASE WHEN mode = 'hardcore' THEN 'hardcore' WHEN bots > 0 THEN 'bots' ELSE 'people' END"
    ok="AND mode IN ('', 'normal', 'hardcore')"     # practice and story runs never rank
  else
    kind="IF(bots > 0, 'bots', 'people')"; ok=""
  fi
  # this week: from Monday 00:00 UTC
  week=$(date -u -d "$(date -u +%F) -$(( $(date -u +%u) - 1 )) days" +%s)
  local k="WITH k AS (SELECT *, $kind AS kind FROM bossfights_result WHERE test = 0 $ok),
    c AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY raid, tier, kind ORDER BY length_ms, id) AS n FROM k WHERE cleared = 1 AND length_ms > 0)"
  q="SELECT 'S:live' AS s; SELECT line, updated, UNIX_TIMESTAMP() AS now FROM warfront_live WHERE id = 2;
     SELECT 'S:now' AS s; SELECT run, raid, tier, size, started, bosses, encounters$nopt FROM bossfights_now;
     SELECT 'S:board' AS s; $k SELECT id, raid, tier, kind, length_ms, members, size, ended, bots FROM c WHERE n <= 10 ORDER BY raid, tier, kind, length_ms, id;
     SELECT 'S:first' AS s; WITH k AS (SELECT *, $kind AS kind FROM bossfights_result WHERE test = 0 $ok AND cleared = 1)
       SELECT k.id, k.raid, k.tier, k.kind, k.ended, k.length_ms, k.members, k.bots FROM k
       JOIN (SELECT MIN(id) AS id FROM k GROUP BY raid, tier, kind) f ON f.id = k.id ORDER BY k.id;
     SELECT 'S:week' AS s; WITH k AS (SELECT *, $kind AS kind FROM bossfights_result WHERE test = 0 $ok AND ended >= $week),
       c AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY raid, tier, kind ORDER BY length_ms, id) AS n FROM k WHERE cleared = 1 AND length_ms > 0)
       SELECT id, raid, tier, kind, length_ms, members, size, ended, bots FROM c WHERE n = 1 ORDER BY raid, tier, kind;
     SELECT 'S:runs' AS s; $k SELECT id, raid, tier, size, bots, affixes, ended, length_ms, cleared, wipes, deaths, members, splits$ropt
       FROM bossfights_result WHERE test = 0 AND (id > (SELECT COALESCE(MAX(id), 0) - 300 FROM bossfights_result)
         OR id IN (SELECT id FROM c WHERE n <= 10)) ORDER BY id DESC;"
  if live_has bossfights_week twist; then
    q="$q SELECT 'S:twist' AS s; SELECT twist FROM bossfights_week WHERE week_start <= UNIX_TIMESTAMP() ORDER BY week_start DESC LIMIT 1;"
  fi
  raw=$(mktemp)
  sqle classiccharacters "$q" > "$raw" 2>/dev/null || true
  python3 - "$out" "$raw" "$runs" "$week" <<'PY'
import json, os, sys, time
out_path, raw_path, runs_dir, week_start = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
NAMES = {"onyxia": "Onyxia's Lair", "mc": "Molten Core", "bwl": "Blackwing Lair", "zg": "Zul'Gurub",
         "aq20": "Ruins of Ahn'Qiraj", "aq40": "Temple of Ahn'Qiraj", "naxx": "Naxxramas"}
CLASS = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}
ROLE = {"0": "dps", "1": "tank", "2": "healer"}
ENCOUNTERS = {"onyxia": ["Onyxia"]}
TWISTS = {"bloodmoon": ["Blood Moon", "More critical strikes, both ways."],
          "shortfuse": ["Short Fuse", "Bosses enrage at 6 minutes."],
          "whelpswarm": ["Whelp Swarm", "Twice the whelps."],
          "ironwill": ["Iron Will", "No consumables, and a bigger tier aura for the clear."]}
BOARD = {"people": "boards", "bots": "boards_bots", "hardcore": "boards_hardcore"}


def num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return 0


def sections(text):
    """mariadb -e output of several statements: each section starts with a one-column 's' result 'S:<name>',
    then that statement's header and rows (a statement with no rows prints nothing)."""
    secs, cur, hdr = {}, None, None
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if line == "s" and i + 1 < len(lines) and lines[i + 1].startswith("S:"):
            cur, hdr = lines[i + 1][2:], None
            secs[cur] = []
            i += 2
            continue
        if cur is not None and line:
            cells = line.split("\t")
            if hdr is None:
                hdr = cells
            else:
                secs[cur].append(dict(zip(hdr, cells)))
        i += 1
    return secs


def stats_of(text):
    out = {}
    for m in (text or "").split(","):
        f = m.split(":")
        if len(f) >= 4 and f[0]:
            out[f[0]] = {"damage": num(f[1]), "healing": num(f[2]), "deaths": num(f[3])}
    return out


def members(text, stats=""):
    st, out = stats_of(stats), []
    for m in (text or "").split(","):
        f = (m.split(":") + ["", "0", "", ""])[:4]
        if not f[0]:
            continue
        row = {"name": f[0], "class": CLASS.get(num(f[1]), ""), "role": ROLE.get(f[2], f[2]), "bot": f[3] == "bot"}
        row.update(st.get(f[0], {}))
        out.append(row)
    return out


def splits(raid, text):
    names, out = ENCOUNTERS.get(raid, []), []
    for s in (text or "").split(","):
        f = s.split(":")
        if len(f) == 2 and f[1].isdigit():
            i = num(f[0])
            out.append({"boss": names[i] if 0 <= i < len(names) else "Boss %d" % (i + 1), "ms": num(f[1])})
    return out


def kind_of(r):
    if r.get("mode") == "hardcore":
        return "hardcore"
    return "bots" if num(r.get("bots")) > 0 else "people"


def ranked(r):
    return r.get("mode", "") in ("", "normal", "hardcore", "NULL")


raw = ""
try:
    with open(raw_path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
finally:
    try:
        os.unlink(raw_path)
    except OSError:
        pass
secs = sections(raw)
now = int(time.time())
out = {"version": 2, "updated": 0, "stale": True, "runs": 0, "raiding": 0, "queued": 0, "raids": NAMES, "now": [],
       "boards": {}, "boards_bots": {}, "boards_hardcore": {}, "feed": [], "recent": [],
       "week": {"start": week_start, "twist": "", "name": "", "text": "", "fastest": []}, "firsts": [], "twists": TWISTS}
for row in secs.get("live", [])[:1]:
    n = [num(x) for x in row.get("line", "").split(",")] + [0] * 3
    out["updated"], now = num(row.get("updated")), num(row.get("now")) or now
    out["stale"] = now - out["updated"] > 90
    out["runs"], out["raiding"], out["queued"] = n[0], n[1], n[2]
for r in secs.get("now", []):
    e = {"run": num(r.get("run")), "raid": r.get("raid", ""), "tier": num(r.get("tier")), "size": num(r.get("size")),
         "seconds": max(0, now - num(r.get("started"))), "bosses": num(r.get("bosses")), "of": num(r.get("encounters"))}
    if "phase" in r: e["phase"] = num(r["phase"])
    if "bots" in r: e["bots"] = num(r["bots"])
    if r.get("mode") not in (None, "", "NULL"): e["mode"] = r["mode"]
    if r.get("twist") not in (None, "", "NULL"): e["twist"] = r["twist"]
    if num(r.get("pulled")) > 0: e["fighting"] = max(0, now - num(r["pulled"]))
    out["now"].append(e)
records = set()
for r in secs.get("board", []):
    m = members(r.get("members"))
    key = BOARD.get(r.get("kind"), "boards")
    rows = out[key].setdefault(r.get("raid", ""), {}).setdefault(r.get("tier", "0"), [])
    if not rows:
        records.add(num(r.get("id")))
    rows.append({"id": num(r.get("id")), "ms": num(r.get("length_ms")), "leader": m[0]["name"] if m else "",
                 "size": max(0, num(r.get("size")) - num(r.get("bots"))), "bots": num(r.get("bots")), "t": num(r.get("ended")),
                 "members": m})
firsts = set()
for r in secs.get("first", []):
    m = members(r.get("members"))
    firsts.add(num(r.get("id")))
    out["firsts"].append({"id": num(r.get("id")), "raid": r.get("raid", ""), "tier": num(r.get("tier")), "kind": r.get("kind", ""),
                          "t": num(r.get("ended")), "ms": num(r.get("length_ms")), "leader": m[0]["name"] if m else "",
                          "bots": num(r.get("bots"))})
for r in secs.get("week", []):
    m = members(r.get("members"))
    out["week"]["fastest"].append({"id": num(r.get("id")), "raid": r.get("raid", ""), "tier": num(r.get("tier")), "kind": r.get("kind", ""),
                                   "ms": num(r.get("length_ms")), "t": num(r.get("ended")), "leader": m[0]["name"] if m else "",
                                   "size": max(0, num(r.get("size")) - num(r.get("bots"))), "bots": num(r.get("bots")), "members": m})
for r in secs.get("twist", [])[:1]:
    t = r.get("twist", "")
    if t in TWISTS:
        out["week"]["twist"], out["week"]["name"], out["week"]["text"] = t, TWISTS[t][0], TWISTS[t][1]
os.makedirs(runs_dir, exist_ok=True)
for r in secs.get("runs", []):
    rid = num(r.get("id"))
    if rid <= 0:
        continue
    m = members(r.get("members"), r.get("stats", ""))
    bots = num(r.get("bots"))
    mode = "" if r.get("mode") in (None, "NULL") else r.get("mode", "")
    twist = "" if r.get("twist") in (None, "NULL") else r.get("twist", "")
    feats = [f for f in (r.get("feats") or "").split(",") if f and f != "NULL"]
    run = {"id": rid, "raid": r.get("raid", ""), "raid_name": NAMES.get(r.get("raid", ""), r.get("raid", "")),
           "tier": num(r.get("tier")), "size": max(0, num(r.get("size")) - bots), "bots": bots, "affixes": num(r.get("affixes")),
           "mode": mode, "twist": twist, "t": num(r.get("ended")), "ms": num(r.get("length_ms")), "cleared": r.get("cleared") == "1",
           "wipes": num(r.get("wipes")), "deaths": num(r.get("deaths")), "members": m, "splits": splits(r.get("raid", ""), r.get("splits")),
           "feats": feats, "kind": kind_of({"mode": mode, "bots": bots}), "ranked": ranked({"mode": mode}),
           "first": rid in firsts, "record": rid in records}
    body = json.dumps(run, separators=(",", ":"))
    path = os.path.join(runs_dir, "%d.json" % rid)
    try:
        with open(path, encoding="utf-8") as fh:
            same = fh.read() == body
    except OSError:
        same = False
    if not same:
        with open(path + ".tmp", "w", encoding="utf-8") as fh:
            fh.write(body)
        os.replace(path + ".tmp", path)
    if len(out["recent"]) < 100:
        out["recent"].append({k: run[k] for k in ("id", "raid", "tier", "size", "bots", "mode", "kind", "ranked", "t", "ms",
                                                  "cleared", "wipes", "deaths", "first", "record", "feats")}
                             | {"members": [{"name": x["name"], "class": x["class"], "role": x["role"], "bot": x["bot"]} for x in m]})
    if len(out["feed"]) < 25:
        out["feed"].append({"id": rid, "raid": run["raid"], "tier": run["tier"], "size": run["size"], "bots": bots, "affixes": run["affixes"],
                            "t": run["t"], "ms": run["ms"], "cleared": run["cleared"], "wipes": run["wipes"], "deaths": run["deaths"],
                            "members": m, "mode": mode, "twist": twist, "feats": feats, "first": run["first"], "record": run["record"]})
tmp = out_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(out, fh, separators=(",", ":"))
os.replace(tmp, out_path)
PY
  chmod 644 "$out" 2>/dev/null; chmod 755 "$runs" 2>/dev/null; find "$runs" -name '*.json' ! -perm 644 -exec chmod 644 {} + 2>/dev/null
  return 0
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
    [ -e "$BCP/botfill.on" ] && bot_conf "${BOTFILL_BOTS[@]}"    # bot fill keeps the AI on
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

# Bot fill (realm/mangos/0054). The bot AI's own tables go on the Duels stack once (hetzner/playerbots_db.sh with
# this stack's directory: without them no bot could log in, 2026-10-23), then the AI as bot fill needs it.
botfill() {
  case "${1:-}" in
  on)
    touch "$BCP/botfill.on"
    say "bot fill: the bot AI's tables (once), the bot AI, the settings, a restart"
    OW_REALM_DIR="$S" NO_RESTART=1 bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/playerbots_db.sh" || { echo "   the bot AI's tables could not be put in"; return 1; }
    fetch; sql classiccharacters "$BCP/bossfights_characters.sql"     # bossfights_fill_bot (0054)
    bot_conf "${BOTFILL_BOTS[@]}"
    CONF_KEYS=("${BOTFILL_KEYS[@]}"); write_conf; restart
    cat <<TXT
Bot fill on: a raid nobody else joins gets bots after ${BOTFILL_AFTER:-30} s (at most ${BOTFILL_MAX:-18} logged in, none below ${BOTFILL_MINMB:-600} MB free).
The first raids make the bots (a few seconds each, once); later ones reuse them. bash $0 botfill status
TXT
    ;;
  off)
    rm -f "$BCP/botfill.on"
    say "bot fill off"
    CONF_KEYS=("OpenVanilla.BossFights.BotFill=0"); write_conf
    if [ ! -s "$BCP/testbots.before" ]; then bot_conf "AiPlayerbot.Enabled=0"; else echo "   (testbots is on: the bot AI stays on until testbots off)"; fi
    restart ;;
  status)
    [ -e "$BCP/botfill.on" ] && echo "bot fill: on" || echo "bot fill: off"
    local CFG; CFG=$(dvol config)
    docker run --rm -v "$CFG":/c:ro debian:bookworm-slim sh -c 'grep -h "^OpenVanilla\.BossFights\.BotFill\|^AiPlayerbot\.\(Enabled\|RandomBotAutologin\|MaxRandomBots\|AutoDoQuests\)" /c/mangosd.conf /c/aiplayerbot.conf' | sed 's/^/   /'
    sqle classiccharacters "SELECT COUNT(*) AS kept_bots, SUM(b.prepared) AS geared, SUM(c.online) AS online_now
      FROM bossfights_fill_bot b JOIN characters c ON c.guid = b.guid" 2>/dev/null || echo "   (no bossfights_fill_bot table yet)"
    (cd "$S" && docker stats --no-stream --format '   world server memory: {{.MemUsage}}' "$(docker compose ps -q mangosd)") 2>/dev/null || true
    awk '/MemAvailable/ {printf "   host MemAvailable: %d MB\n", $2/1024}' /proc/meminfo ;;
  *) echo "usage: $0 botfill on|off|status"; return 2 ;;
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
  # Duels first: the client patch (the Boss Fights addon is in it), the play page and both images. Its
  # duels_lean.sql empties the raids, so Boss Fights copies them back below. SKIP_DUELS=1 skips it.
  if [ "${SKIP_DUELS:-0}" != 1 ]; then
    say "0/3 the Duels stack (client patch, play page, images)"
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/duels_up.sh" update || echo "   (duels_up.sh update failed: going on with Boss Fights)"
  fi
  say "1/3 files"; fetch
  # duels_up.sh update runs duels_lean.sql again, which empties the raids: copy them back every time
  say "2/3 spawns, SQL and settings"; restore_spawns; apply_sql; write_conf; hub; timer
  # duels_up.sh update puts AiPlayerbot.Enabled = 0 back: bot fill's AI settings again while it is on
  [ -e "$BCP/botfill.on" ] && bot_conf "${BOTFILL_BOTS[@]}"
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
    bash "$CHECK" --watch off
    bash "$CHECK" --watch-real off ;;
  now)
    bash "$CHECK" ;;
  real)
    # the real Onyxia fight (mangos 0059): one test account watching, nine fill bots fighting; needs bot fill on
    case "${2:-now}" in
      on)  bash "$CHECK" --watch-real on ;;
      off) bash "$CHECK" --watch-real off ;;
      now) bash "$CHECK" --real ;;
      *) echo "usage: $0 selftest real on|off|now"; exit 2 ;;
    esac ;;
  *) echo "usage: $0 selftest on|off|now|real [on|off|now]"; exit 2 ;;
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
botfill)
  need_duels; mkdir -p "$BCP"; botfill "$@" ;;
*) echo "usage: $0 enable | update | site | off | status | live | selftest on|off|now|real [on|off|now] | testbots on [ACCOUNT...]|off | botfill on|off|status"; exit 2 ;;
esac
