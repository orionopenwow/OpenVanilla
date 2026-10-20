#!/usr/bin/env bash
# The Open Vanilla staging realm: a second, small copy of the live realm on the same server, so
# every update is tried there (by Herald Lite) before players get it. See devkit/staging/README.md.
#
#   bash staging_up.sh install [staging.openvanilla.app]   once: make it (world DB install takes ~10 min)
#   bash staging_up.sh start | stop | status            it sleeps when stopped (no RAM used)
#   bash staging_up.sh build-heraldlite                 build the test bot on this server (Docker)
#   bash staging_up.sh herald [scenario.txt ...]        run Herald Lite against staging now
#
# Layout:  /opt/wenilla-staging     the realm stack (compose project "owstaging", own databases)
#          /opt/openvanilla-staging     its Open Vanilla files (like /opt/openvanilla-classicplus for live)
# Shared with live, read-only: the extracted maps (no copy), the client's base MPQs (hard links).
set -euo pipefail
LIVE=/opt/wenilla-realm
LIVE_CP=/opt/openvanilla-classicplus
S=/opt/wenilla-staging
SCP=/opt/openvanilla-staging
RAW=https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable
say() { printf '\n\033[1;36m== staging: %s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cmd=${1:-status}; shift || true

livevol() { docker volume ls -q --filter "label=com.docker.compose.project=wenilla-realm" --filter "label=com.docker.compose.volume=$1" | head -1; }
svol() { docker volume ls -q --filter "label=com.docker.compose.project=owstaging" --filter "label=com.docker.compose.volume=$1" | head -1; }
wait_healthy() {  # wait_healthy SERVICE MAX_SECONDS
  local s=starting
  for _ in $(seq 1 $(($2 / 10))); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$S" && docker compose ps -q "$1")" 2>/dev/null || echo starting)
    [ "$s" = healthy ] && return 0; sleep 10
  done
  echo "$1: $s after $2 s"; return 1
}

case "$cmd" in
install)
  DOMAIN=${1:-staging.openvanilla.app}
  [ -e "$LIVE/.env" ] || { echo "No live realm at $LIVE"; exit 1; }
  set -a; . "$LIVE/.env"; set +a
  LIVE_DATA=$CLIENT_DATA
  say "1/7 stack files ($S)"
  mkdir -p "$S" "$SCP"
  cp -r "$LIVE/compose.yaml" "$LIVE/docker" "$LIVE/caddy" "$S/"
  if [ ! -e "$S/.env" ]; then
    rnd() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
    cat > "$S/.env" <<ENV
# Open Vanilla staging realm (devkit/staging/staging_up.sh). Its own databases and passwords.
COMPOSE_PROJECT_NAME=owstaging
REALM_DOMAIN=$DOMAIN
DB_ROOT_PASSWORD=$(rnd)
DB_MANGOS_PASSWORD=$(rnd)
DB_REALMWEB_PASSWORD=$(rnd)
CLIENT_DATA=$SCP/client-data
MANGOSD_MEM=1500m
REALM_TAG=${REALM_TAG:-latest}
MANGOS_TAG=${MANGOS_TAG:-latest}
ENV
    chmod 600 "$S/.env"
  fi
  say "2/7 client data: hard links to live's MPQs (no extra disk), staging's own patch-Z"
  mkdir -p "$SCP/client-data"
  if ! cp -al "$LIVE_DATA/." "$SCP/client-data/" 2>/dev/null; then
    echo "   (not on the same disk as $LIVE_DATA: copying instead)"; cp -a "$LIVE_DATA/." "$SCP/client-data/"
  fi
  rm -f "$SCP/client-data/patch-Z.MPQ"   # unlink: staging writes its own
  say "3/7 databases (the world database installs once, ~10 minutes)"
  cd "$S"
  docker compose up -d mariadb
  docker compose run --rm db-init
  say "4/7 world data: staging's own dbc, live's maps shared read-only"
  docker compose create mangosd >/dev/null 2>&1 || true
  SG=$(svol gamedata); LG=$(livevol gamedata)
  [ -n "$SG" ] || { docker volume create --label com.docker.compose.project=owstaging --label com.docker.compose.volume=gamedata owstaging_gamedata >/dev/null; SG=owstaging_gamedata; }
  docker run --rm -v "$SG":/data -v "$LG":/live:ro debian:bookworm-slim sh -c '
    rm -rf /data/dbc && cp -a /live/dbc /data/dbc
    for d in maps vmaps mmaps; do [ -e /live/$d ] && ln -sfn /live/$d /data/$d; done
    ls -la /data'
  say "5/7 Open Vanilla files, SQL and the world server (openvanilla_realm_up.sh in staging mode)"
  curl -fsSL "$RAW/hetzner/openvanilla_realm_up.sh" -o "$SCP/openvanilla_realm_up.sh"
  OW_REALM_DIR=$S OW_CP=$SCP OW_STAGING=1 bash "$SCP/openvanilla_realm_up.sh"
  say "6/7 the live Caddy serves https://$DOMAIN"
  if ! grep -q "owstaging-realm" "$LIVE_CP/Caddyfile"; then
    cat >> "$LIVE_CP/Caddyfile" <<CADDY

# The staging realm (devkit/staging): same site layout, its own realm service.
$DOMAIN {
	encode zstd gzip
	@owsw path /ow/sw.js
	header @owsw Service-Worker-Allowed "/"
	reverse_proxy owstaging-realm:8090
	header -Server
}
CADDY
  fi
  (cd "$LIVE" && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile) || echo "   (reload Caddy by hand: cd $LIVE && docker compose restart caddy)"
  say "7/7 first sign-in"
  TOKEN=$(docker compose exec -T realm cat /state/setup-token 2>/dev/null || true)
  cat <<TXT
Staging is up. Three things only you can do:
  1. DNS: an A record for $DOMAIN pointing at this server (same IP as the live realm).
  2. Open https://$DOMAIN/setup${TOKEN:+ (setup token: $TOKEN)} and make the admin login.
  3. In the admin panel, make a login for Herald, sign in as it once in a browser, and create its
     character: Herald, a Human Hunter. Then save its login for the bot:
       printf 'HL_WEB=https://$DOMAIN\nHL_USER=herald\nHL_PASS=...\n' > $S/heraldlite.env; chmod 600 $S/heraldlite.env
Then: bash $0 build-heraldlite && bash $0 herald
TXT
  ;;
start)
  cd "$S"; docker compose up -d mariadb realmd mangosd realm
  wait_healthy mangosd 600 && echo "staging is up" ;;
stop)
  cd "$S"; docker compose stop; echo "staging is asleep (docker compose stop)" ;;
status)
  [ -e "$S/.env" ] || { echo "no staging realm (bash $0 install)"; exit 0; }
  cd "$S"; docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}'
  echo "applied commit: $(cat "$SCP/.hotpatch-applied" 2>/dev/null || echo none)"
  [ -e "$SCP/last-herald.json" ] && echo "last Herald Lite run: $(head -c 300 "$SCP/last-herald.json")" ;;
build-heraldlite)
  SRC=$SCP/repo/devkit/heraldlite
  [ -d "$SRC" ] || SRC=$LIVE_CP/repo/devkit/heraldlite
  [ -d "$SRC" ] || { echo "no devkit/heraldlite checkout yet: run a hot update first"; exit 1; }
  mkdir -p "$SCP/bin" "$SCP/cargo"
  docker run --rm -v "$SRC":/src:ro -v "$SCP/cargo":/usr/local/cargo/registry -v "$SCP/bin":/out \
    -e CARGO_TARGET_DIR=/tmp/t rust:1-bookworm sh -c 'cd /src && cargo build --release -q && cp /tmp/t/release/heraldlite /out/'
  ls -la "$SCP/bin/heraldlite" ;;
herald)
  [ -x "$SCP/bin/heraldlite" ] || { echo "build it first: bash $0 build-heraldlite"; exit 1; }
  [ -e "$S/heraldlite.env" ] || { echo "no $S/heraldlite.env (see: bash $0 install, step 7)"; exit 1; }
  set -a; . "$S/heraldlite.env"; set +a
  SCN=$SCP/repo/devkit/heraldlite/scenarios
  [ $# -gt 0 ] || set -- "$SCN/smoke.txt" "$SCN/wallet.txt" "$SCN/skills.txt"
  args=(); for f in "$@"; do args+=(-s "$f"); done
  set +e; "$SCP/bin/heraldlite" "${args[@]}" > "$SCP/last-herald.json"; rc=$?; set -e
  cat "$SCP/last-herald.json"; echo; exit $rc ;;
*) echo "usage: $0 install [domain] | start | stop | status | build-heraldlite | herald [scenarios]"; exit 2 ;;
esac
