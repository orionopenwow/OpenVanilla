#!/usr/bin/env bash
# Warfront: the instant-60 PvP realm, a separate realm stack on the same server as the live one
# (like devkit/staging). Pure 1.12.1 world (a stock world database), the Open Vanilla world server with
# OpenVanilla.Warfront = 1, the Classic+ addons without Classic+'s client tables (realm/warfront/patch-Z.MPQ).
#
#   bash warfront_up.sh install [warfront.openvanilla.app]   once (~15 min: the world database installs)
#   bash warfront_up.sh update                           new Warfront files, SQL and config; restarts the world server
#   bash warfront_up.sh start | stop | status
#   bash warfront_up.sh herald [scenario.txt ...]         Herald Lite against Warfront (uses staging's build)
#   bash warfront_up.sh live                             write the live counts JSON once (a timer runs it every 20 s)
#
# Layout:  /opt/wenilla-warfront    the stack (compose project "owwarfront", its own databases and accounts)
#          /opt/openvanilla-warfront    its Open Vanilla files
# Shared with live, read-only: the extracted maps; the client's base MPQs (hard links).
# The live Caddy serves it: the live realm_up adds the site block when this stack exists (step 7 here
# adds it too, so it works before the next live update).
set -euo pipefail
LIVE=/opt/wenilla-realm
LIVE_CP=/opt/openvanilla-classicplus
S=/opt/wenilla-warfront
WCP=/opt/openvanilla-warfront
RAW=${OW_RAW:-https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable}
say() { printf '\n\033[1;31m== warfront: %s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cmd=${1:-status}; shift || true

livevol() { docker volume ls -q --filter "label=com.docker.compose.project=wenilla-realm" --filter "label=com.docker.compose.volume=$1" | head -1; }
wvol() { docker volume ls -q --filter "label=com.docker.compose.project=owwarfront" --filter "label=com.docker.compose.volume=$1" | head -1; }
wait_healthy() {  # wait_healthy SERVICE MAX_SECONDS
  local s=starting
  for _ in $(seq 1 $(($2 / 10))); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$S" && docker compose ps -q "$1")" 2>/dev/null || echo starting)
    [ "$s" = healthy ] && return 0; sleep 10
  done
  echo "$1: $s after $2 s"; return 1
}
sql() {  # sql DATABASE FILE
  (cd "$S" && set -a && . ./.env && set +a && MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot "$1") < "$2"
}
sqle() {  # sqle DATABASE "STATEMENT"
  (cd "$S" && set -a && . ./.env && set +a && MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot "$1" -e "$2")
}

# mangosd.conf keys for Warfront (replace the line, or add it at the end)
CONF_KEYS=(
  "OpenVanilla.Warfront=1"
  "OpenVanilla.AutoLearn=1"            # every class spell at creation (level 60), weapon skills included
  "OpenVanilla.FreeRespec=1"
  "OpenVanilla.DualSpec=1"
  "OpenVanilla.StarterPet=0"
  "OpenVanilla.AoeLoot=1"
  "OpenVanilla.InstantAccountMail=1"
  "OpenVanilla.ClosedCombos=0"
  "StartPlayerLevel=60"
  "StartPlayerMoney=0"             # Warfront gives its welcome gold itself (OpenVanilla.Warfront.WelcomeGold)
  "GameType=1"                     # PvP rules, "PvP" in the realm list
  "SkipCinematics=2"
  "AlwaysMaxSkillForLevel=1"
  "Battleground.QueueAnnouncer.Enable=1"
  "Rate.Honor=1"
  "OpenVanilla.Warfront.CrossFactionBG=1"   # battleground queues mix factions, sides kept even (patch 0010)
  "OpenVanilla.Warfront.BotFill=1"          # realm bots may fill battlegrounds, labelled in game and in /wf
  "OpenVanilla.Warfront.BotFill.Hours=0-24" # UTC hours they may; e.g. 2-14 for the European night only
  "OpenVanilla.Warfront.BotFill.Below=10"   # and only while fewer real players than this are queued
  "OpenVanilla.Warfront.Arena.SameAddressRated=0"  # rated arena never pits one network address against itself
  "OpenVanilla.Transmog=1"                    # retail transmog: appearances, outfits, the Transmogrifiers (patch 0011)
  "OpenVanilla.Transmog.PriceScale=0.01"     # retail's gold prices x this (100 gold there = 1 gold here)
)

# Setting names: OpenVanilla.* from realm/mangos/0012-openvanilla-names.patch on. An older world server
# image only reads the Open Vanilla.* spelling, so on one of those the old names are written (they keep
# working after the image update too); the next run on the new image switches the lines over.
# Never a stop: a deploy that brings the new image runs this before that image is up.
names_prefix() {  # names_prefix COMPOSE_DIR -> OpenVanilla or Open Vanilla
  local cid labels
  cid=$(cd "$1" && docker compose ps -aq mangosd 2>/dev/null | head -1)
  labels=$( [ -n "$cid" ] && docker inspect -f '{{ index .Config.Labels "dev.openvanilla.patches" }}' "$cid" 2>/dev/null || true)
  case "$labels" in *openvanilla-names*) echo OpenVanilla ;; *) echo Open Vanilla ;; esac
}
write_conf() {
  local P; P=$(names_prefix "$S")
  local CFG; CFG=$(wvol config)
  [ -n "$CFG" ] || { echo "no config volume yet"; return 1; }
  printf '%s\n' "${CONF_KEYS[@]}" | sed 's/ *#.*$//' | sed "s/^OpenVanilla\./$P./" > "$WCP/warfront.conf.keys"
  docker run --rm -v "$CFG":/config -v "$WCP/warfront.conf.keys":/keys:ro debian:bookworm-slim sh -c '
    f=/config/mangosd.conf
    [ -e $f.before-warfront ] || cp $f $f.before-warfront
    grep -q "^OpenVanilla\." /keys && sed -i "s/^OpenWoW\./OpenVanilla./" $f   # older lines, new spelling
    while IFS="=" read -r k v; do
      [ -n "$k" ] || continue
      if grep -q "^$k *=" $f; then sed -i "s|^$k *=.*|$k = $v|" $f; else printf "%s = %s\n" "$k" "$v" >> $f; fi
      grep "^$k *=" $f
    done < /keys'
}

fetch() {  # the Warfront files from the repo
  mkdir -p "$WCP"
  for f in patch-Z.MPQ warfront_kits.sql warfront_item_pool.sql warfront_world.sql warfront_characters.sql; do
    curl -fsSL "$RAW/realm/warfront/$f" -o "$WCP/$f.new" && mv "$WCP/$f.new" "$WCP/$f"
  done
  for f in transmog_world.sql transmog_characters.sql; do
    curl -fsSL "$RAW/realm/transmog/$f" -o "$WCP/$f.new" && mv "$WCP/$f.new" "$WCP/$f"
  done
  ls -la "$WCP"
}

apply_sql() {
  for f in warfront_kits.sql warfront_item_pool.sql warfront_world.sql; do
    echo "   classicmangos < $f"; sql classicmangos "$WCP/$f"
  done
  echo "   classiccharacters < warfront_characters.sql"; sql classiccharacters "$WCP/warfront_characters.sql"
  echo "   classicmangos < transmog_world.sql"; sql classicmangos "$WCP/transmog_world.sql"
  echo "   classiccharacters < transmog_characters.sql"; sql classiccharacters "$WCP/transmog_characters.sql"
  sqle classicrealmd "UPDATE realmlist SET name = 'Warfront', icon = 1 WHERE id = 1"
  sqle classicmangos "SELECT COUNT(DISTINCT kit) AS kits FROM warfront_kit; SELECT COUNT(*) AS pool FROM warfront_item_pool"
}

# The page keys its saved patch-Z files on /ow/data-version.json (realm/www/syncread.js). /ow/ is the
# live realm's folder, whose version names LIVE's patch-Z, not this realm's: a new patch-Z here kept
# the version, so browsers went on reading saved files of the old one next to new ones (Meters' new
# Window.lua over an old toc without Chrome.lua: "Window.lua:31: ... ROW_X (a nil value)",
# 2026-10-21). This realm publishes its own version over that one file. Written in place (the file is
# bind-mounted; a new inode would not be seen), and after the realm restarts on the new patch-Z.
write_version() {
  local sw
  sw=$(python3 -c "import json;print(json.load(open('$LIVE_CP/www/data-version.json')).get('sw','on'))" 2>/dev/null || echo on)
  mkdir -p "$WCP"
  if [ -f "$WCP/patch-Z.MPQ" ]; then
    printf '{"patchZ":"%s","sw":"%s"}\n' "$(sha256sum "$WCP/patch-Z.MPQ" | cut -c1-16)" "$sw" > "$WCP/data-version.json"
  else
    printf '{"sw":"%s"}\n' "$sw" > "$WCP/data-version.json"     # no version: the page keeps nothing
  fi
  chmod 644 "$WCP/data-version.json"
}

install_patch() {
  # copy then rename: the client data is hard-linked to live's, never write into the old file
  cp "$WCP/patch-Z.MPQ" "$WCP/client-data/patch-Z.MPQ.new" && mv -f "$WCP/client-data/patch-Z.MPQ.new" "$WCP/client-data/patch-Z.MPQ"
}

# The live counts (queues, matches, battles, bots) for the website: mangosd writes one row to
# warfront_live every 15 s; this turns it into JSON in the Herald's public folder, which the live
# Caddy already serves with CORS at https://<live domain>/community/warfront_live.json.
LIVE_JSON=/opt/openvanilla-herald/public/warfront_live.json
write_live() {
  local row; row=$(sqle classiccharacters "SELECT line, updated, UNIX_TIMESTAMP() FROM warfront_live WHERE id = 1" 2>/dev/null | tail -n +2 | head -1) || row=""
  mkdir -p "$(dirname "$LIVE_JSON")"
  python3 - "$row" "$LIVE_JSON" <<'PY'
import json, os, sys, time
row, path = sys.argv[1].split("\t") if sys.argv[1] else [], sys.argv[2]
out = {"updated": 0, "stale": True}
if len(row) == 3:
    nums = [int(x) if x.isdigit() else 0 for x in row[0].split(",")] + [0] * 9
    updated, now = int(row[1] or 0), int(row[2] or time.time())
    out = {
        "updated": updated,
        "stale": now - updated > 90,     # mangosd writes every 15 s: older means the world server is down
        "arena": dict(zip(["s2", "s3", "r2", "r3", "d1", "matches"], nums[:6])),
        "battlegrounds": {"queued": nums[6], "playing": nums[7], "bots": nums[8]},
    }
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(out, f, separators=(",", ":"))
os.replace(tmp, path)
PY
}
live_timer() {
  cat > /etc/systemd/system/openvanilla-warfront-live.service <<UNIT
[Unit]
Description=Open Vanilla Warfront live counts for the website
[Service]
Type=oneshot
ExecStart=/bin/bash $LIVE_CP/repo/hetzner/warfront_up.sh live
UNIT
  cat > /etc/systemd/system/openvanilla-warfront-live.timer <<UNIT
[Unit]
Description=Open Vanilla Warfront live counts, every 20 s
[Timer]
OnBootSec=60
OnUnitActiveSec=20
AccuracySec=5
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload && systemctl enable --now openvanilla-warfront-live.timer >/dev/null && echo "   live counts: $LIVE_JSON every 20 s"
}

caddy_block() {
  local DOMAIN; DOMAIN=$(grep '^REALM_DOMAIN=' "$S/.env" | cut -d= -f2)
  if ! grep -q "owwarfront-realm" "$LIVE_CP/Caddyfile"; then
    cat >> "$LIVE_CP/Caddyfile" <<CADDY

# Warfront (hetzner/warfront_up.sh): its own realm service.
$DOMAIN {
	encode zstd gzip
	@owsw path /ow/sw.js
	header @owsw Service-Worker-Allowed "/"
	reverse_proxy owwarfront-realm:8090
	header -Server
}
CADDY
  fi
  (cd "$LIVE" && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile) || echo "   (reload Caddy by hand: cd $LIVE && docker compose restart caddy)"
}

override() {
  # the Open Vanilla images, the live page layer (shared, read-only) and live's maps
  local REALM_IMAGE MANGOS_IMAGE LG
  # the same web service image as live (openvanilla_realm_up.sh wrote it into live's override)
  REALM_IMAGE=$(awk '/^  realm:/{f=1;next} f&&/image:/{print $2;exit}' "$LIVE/compose.override.yaml" 2>/dev/null)
  [ -n "$REALM_IMAGE" ] || REALM_IMAGE="ghcr.io/arnesen/wenilla-realm:latest"
  MANGOS_IMAGE=ghcr.io/orionopenwow/openvanilla-mangos:latest
  LG=$(livevol gamedata)
  [ -f "$WCP/data-version.json" ] || write_version   # the mount needs the file
  cat > "$S/compose.override.yaml" <<YAML
# Written by hetzner/warfront_up.sh — re-run it instead of editing by hand.
services:
  realm:
    image: $REALM_IMAGE
    environment:
      DISCORD_CLIENT_ID: \${DISCORD_CLIENT_ID:-}
      DISCORD_CLIENT_SECRET: \${DISCORD_CLIENT_SECRET:-}
      DISCORD_GUILD_ID: \${DISCORD_GUILD_ID:-}
      DISCORD_BOT_TOKEN: \${DISCORD_BOT_TOKEN:-}
      DISCORD_REQUIRE_ROLE_IDS: \${DISCORD_REQUIRE_ROLE_IDS:-}
      DISCORD_INVITE_URL: \${DISCORD_INVITE_URL:-}
    volumes:
      - $LIVE_CP/bridge.js:/app/www/bridge.js:ro
      - $LIVE_CP/bridge.js.br:/app/www/bridge.js.br:ro
      - $LIVE_CP/bridge.js.gz:/app/www/bridge.js.gz:ro
      - $LIVE_CP/addons-loader.js:/app/www/addons-loader.js:ro
      - $LIVE_CP/www:/app/www/ow:ro
      - $WCP/data-version.json:/app/www/ow/data-version.json:ro
    networks:
      default: {}
      live:
        aliases: [owwarfront-realm]
  mangosd:
    image: $MANGOS_IMAGE
    volumes:
      - $LG:/live:ro      # the live realm's maps, shared read-only
networks:
  live:
    external: true
    name: wenilla-realm_default
YAML
}

case "$cmd" in
install)
  DOMAIN=${1:-warfront.openvanilla.app}
  [ -e "$LIVE/.env" ] || { echo "No live realm at $LIVE"; exit 1; }
  set -a; . "$LIVE/.env"; set +a
  LIVE_DATA=$CLIENT_DATA
  say "1/8 stack files ($S)"
  mkdir -p "$S" "$WCP"
  cp -r "$LIVE/compose.yaml" "$LIVE/docker" "$LIVE/caddy" "$S/"
  if [ ! -e "$S/.env" ]; then
    rnd() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
    {
      echo "# Open Vanilla Warfront (hetzner/warfront_up.sh). Its own databases and passwords."
      echo "COMPOSE_PROJECT_NAME=owwarfront"
      echo "REALM_DOMAIN=$DOMAIN"
      echo "DB_ROOT_PASSWORD=$(rnd)"
      echo "DB_MANGOS_PASSWORD=$(rnd)"
      echo "DB_REALMWEB_PASSWORD=$(rnd)"
      echo "CLIENT_DATA=$WCP/client-data"
      echo "MANGOSD_MEM=2500m"
      echo "REALM_TAG=${REALM_TAG:-latest}"
      echo "MANGOS_TAG=${MANGOS_TAG:-latest}"
      # Discord sign-in: the same app as live (add https://$DOMAIN/auth/discord/callback as a redirect)
      for k in DISCORD_CLIENT_ID DISCORD_CLIENT_SECRET DISCORD_GUILD_ID DISCORD_BOT_TOKEN DISCORD_REQUIRE_ROLE_IDS DISCORD_INVITE_URL; do
        v=$(grep "^$k=" "$LIVE/.env" | cut -d= -f2- || true); [ -n "$v" ] && echo "$k=$v"
      done
    } > "$S/.env"
    chmod 600 "$S/.env"
  fi
  say "2/8 Warfront files"
  fetch
  say "3/8 client data: hard links to live's MPQs, Warfront's own patch-Z"
  mkdir -p "$WCP/client-data"
  if ! cp -al "$LIVE_DATA/." "$WCP/client-data/" 2>/dev/null; then
    echo "   (not on the same disk as $LIVE_DATA: copying instead)"; cp -a "$LIVE_DATA/." "$WCP/client-data/"
  fi
  rm -f "$WCP/client-data/patch-Z.MPQ"; install_patch
  say "4/8 databases (the stock world database installs once, ~10 minutes)"
  cd "$S"
  docker compose up -d mariadb
  docker compose run --rm db-init
  say "5/8 world data: stock dbc (live's, with any Open Vanilla server copies put back), live's maps shared"
  docker compose create mangosd >/dev/null 2>&1 || true
  WG=$(wvol gamedata); LG=$(livevol gamedata)
  [ -n "$WG" ] || { docker volume create --label com.docker.compose.project=owwarfront --label com.docker.compose.volume=gamedata owwarfront_gamedata >/dev/null; WG=owwarfront_gamedata; }
  docker run --rm -v "$WG":/data -v "$LG":/live:ro debian:bookworm-slim sh -c '
    rm -rf /data/dbc && cp -a /live/dbc /data/dbc
    for o in /data/dbc/*.orig; do [ -e "$o" ] && mv -f "$o" "${o%.orig}"; done
    for d in maps vmaps mmaps; do [ -e /live/$d ] && ln -sfn /live/$d /data/$d; done
    ls /data'
  say "6/8 Warfront SQL and mangosd.conf"
  apply_sql
  write_conf
  say "7/8 images, the live Caddy serves https://$DOMAIN"
  override
  docker compose up -d --force-recreate realm realmd mangosd && write_version
  caddy_block; live_timer
  say "8/8 starting the world server"
  wait_healthy mangosd 900 || true
  TOKEN=$(docker compose exec -T realm cat /state/setup-token 2>/dev/null || true)
  cat <<TXT
Warfront is up. What only you can do:
  1. DNS: an A record for $DOMAIN pointing at this server (same IP as the live realm).
  2. Open https://$DOMAIN/setup${TOKEN:+ (setup token: $TOKEN)} and make the admin login.
  3. Discord Developer Portal -> OAuth2 -> Redirects -> add https://$DOMAIN/auth/discord/callback
  4. For the smoke test: make a login for Herald, sign in once, create Herald (Dwarf Hunter; 1.12 Humans cannot be Hunters), then
       printf 'HL_WEB=https://$DOMAIN\nHL_USER=herald\nHL_PASS=...\n' > $S/heraldlite.env; chmod 600 $S/heraldlite.env
       bash $0 herald
  5. When the smoke test passes (realm/warfront/LAUNCH.md, section 4): WARFRONT_OPEN = 1 in
     www/downloads/links.txt turns Warfront from SOON™ to Online in the website's realm list.
TXT
  ;;
update)
  [ -e "$S/.env" ] || { echo "no Warfront stack (bash $0 install)"; exit 1; }
  say "1/4 Warfront files"; fetch
  say "2/4 client patch"; install_patch
  say "3/4 SQL and config"; apply_sql; write_conf; live_timer
  say "4/4 restart (the web service reads the patch's file table at start)"
  cd "$S"; override; docker compose up -d --force-recreate realm mangosd && write_version
  wait_healthy mangosd 900 && echo "Warfront is up" ;;
start)
  cd "$S"; docker compose up -d mariadb realmd mangosd realm
  wait_healthy mangosd 900 && echo "Warfront is up" ;;
stop)
  cd "$S"; docker compose stop; echo "Warfront is stopped" ;;
status)
  [ -e "$S/.env" ] || { echo "no Warfront stack (bash $0 install)"; exit 0; }
  cd "$S"; docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}'
  sqle classicmangos "SELECT COUNT(DISTINCT kit) AS kits FROM warfront_kit" 2>/dev/null || true
  sqle classiccharacters "SELECT COUNT(*) AS warfront_characters FROM warfront_character; SELECT bracket, COUNT(*) AS rated, MAX(rating) AS top FROM warfront_arena_rating GROUP BY bracket" 2>/dev/null || true ;;
live)
  [ -e "$S/.env" ] || exit 0
  write_live ;;
herald)
  BIN=/opt/openvanilla-staging/bin/heraldlite
  [ -x "$BIN" ] || { echo "build Herald Lite first: bash devkit/staging/staging_up.sh build-heraldlite"; exit 1; }
  [ -e "$S/heraldlite.env" ] || { echo "no $S/heraldlite.env (see install, step 4)"; exit 1; }
  set -a; . "$S/heraldlite.env"; set +a
  SCN=$LIVE_CP/repo/devkit/heraldlite/scenarios
  [ $# -gt 0 ] || set -- "$SCN/smoke.txt" "$SCN/warfront_smoke.txt"
  args=(); for f in "$@"; do args+=(-s "$f"); done
  set +e; "$BIN" "${args[@]}" > "$WCP/last-herald.json"; rc=$?; set -e
  cat "$WCP/last-herald.json"; echo; exit $rc ;;
*) echo "usage: $0 install [domain] | update | start | stop | status | live | herald [scenarios]"; exit 2 ;;
esac
