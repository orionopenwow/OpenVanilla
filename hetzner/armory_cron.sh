#!/usr/bin/env bash
# Open Vanilla armory: one pass of tools/armory_export.py (characters, guilds, rankings as static JSON) ->
# the Herald's public folder, served by the realm as /community/armory/ (docs/ARMORY.md).
#
#   bash armory_cron.sh install      (root) fetch the code, make the read-only 'armory' database login,
#                                    copy the server's DBC files, write /etc/openvanilla-armory.env and enable
#                                    the systemd timer (hetzner/systemd/openvanilla-armory.timer: every 10 min)
#   bash armory_cron.sh              one pass (what the timer runs; also fine from cron:
#                                    */10 * * * * herald /opt/openvanilla-armory/armory_cron.sh)
#
# /etc/openvanilla-armory.env (root:herald 640):
#   ARMORY_DB_HOST/PORT/USER/PASSWORD   the 'armory' login (SELECT only), through 127.0.0.1:13306
#                                       (the Herald's database relay; made here when missing)
#   ARMORY_OUT                          where the JSON goes (default /opt/openvanilla-herald/public/armory)
#   ARMORY_REALM, ARMORY_REALM_NAME     folder name and display name (default classicplus / the realmlist name)
#   ARMORY_DBC_DIR                      a copy of the server's dbc/ (icons, talents, reputations)
#   ARMORY_UPLOAD_DIR                   the realm service's community uploads (ARMORY_UPLOAD_DIR in its .env,
#                                       on the host side of its /state volume); empty = none
#   ARMORY_PUBLISH                      empty (default: the realm serves the folder), git or r2 (see docs/ARMORY.md)
#   ARMORY_TORRENT_DIR                  empty (default) or a folder for the daily snapshot + .torrent
set -euo pipefail
DIR=/opt/openvanilla-armory
RAW=${OPENVANILLA_RAW:-https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable}
ENVF=/etc/openvanilla-armory.env
STATE_DIR=/var/lib/openvanilla-armory

if [ "${1:-}" = install ]; then
  [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
  id herald >/dev/null 2>&1 || useradd --system --home /opt/openvanilla-herald --shell /usr/sbin/nologin herald
  mkdir -p "$DIR" "$STATE_DIR/dbc" /opt/openvanilla-herald/public/armory
  apt-get install -y python3-pymysql >/dev/null 2>&1 || python3 -m pip install --quiet pymysql || true
  for f in tools/armory_export.py hetzner/armory_cron.sh; do curl -fsSL "$RAW/$f" -o "$DIR/$(basename "$f")"; done
  for f in tools/make_release_torrents.py tools/build_solo_pack.py; do curl -fsSL "$RAW/$f" -o "$DIR/$(basename "$f")" || true; done
  for u in openvanilla-armory.service openvanilla-armory.timer; do
    curl -fsSL "$RAW/hetzner/systemd/$u" -o "/etc/systemd/system/$u"
  done
  chmod 755 "$DIR/armory_cron.sh"
  REALM=/opt/wenilla-realm
  if [ ! -s "$ENVF" ] && [ -d "$REALM" ] && docker info >/dev/null 2>&1; then
    (
      cd "$REALM"
      set -a; . ./.env; set +a
      sql() { MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N "$@"; }
      # the database relay on 127.0.0.1:13306 (herald_up.sh makes the same one; reuse it when it runs)
      if ! docker ps --format '{{.Names}}' | grep -qx openvanilla-support-mariadb; then
        NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(docker compose ps -q mariadb)" | awk '{print $1}')
        docker run -d --name openvanilla-support-mariadb --restart unless-stopped --network "$NET" -p 127.0.0.1:13306:3306 \
          alpine/socat "tcp-listen:3306,fork,reuseaddr" "tcp-connect:mariadb:3306" >/dev/null
      fi
      P=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
      sql -e "CREATE USER IF NOT EXISTS 'armory'@'%' IDENTIFIED BY '$P'; ALTER USER 'armory'@'%' IDENTIFIED BY '$P';
              GRANT SELECT ON classiccharacters.* TO 'armory'@'%';
              GRANT SELECT ON classicmangos.item_template TO 'armory'@'%';
              GRANT SELECT (id, name) ON classicrealmd.realmlist TO 'armory'@'%';
              GRANT SELECT (id, username) ON classicrealmd.account TO 'armory'@'%';"
      for t in spell_template openvanilla_achievement; do
        [ "$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='classicmangos' AND table_name='$t'")" = 1 ] &&
          sql -e "GRANT SELECT ON classicmangos.$t TO 'armory'@'%';"
      done
      # the server's DBC files (read-only copy; refreshed by re-running install after a client data change)
      VOL=$(docker volume ls -q --filter "label=com.docker.compose.project=wenilla-realm" --filter "label=com.docker.compose.volume=gamedata" | head -1)
      [ -n "$VOL" ] && docker run --rm -v "$VOL":/data:ro -v "$STATE_DIR/dbc":/out debian:bookworm-slim sh -c '
        for f in /data/dbc/*; do case "$(basename "$f" | tr A-Z a-z)" in
          itemdisplayinfo.dbc|talent.dbc|talenttab.dbc|spellicon.dbc|faction.dbc|spellitemenchantment.dbc|itemrandomproperties.dbc|itemset.dbc)
            cp "$f" /out/;; esac; done' || echo "No DBC copy (icons/talents/reputations will be missing until it works)."
      umask 027
      cat > "$ENVF" <<ENV
# Open Vanilla armory exporter (hetzner/armory_cron.sh, docs/ARMORY.md)
ARMORY_DB_HOST=127.0.0.1
ARMORY_DB_PORT=13306
ARMORY_DB_USER=armory
ARMORY_DB_PASSWORD=$P
ARMORY_OUT=/opt/openvanilla-herald/public/armory
ARMORY_REALM=classicplus
ARMORY_REALM_NAME=
ARMORY_DBC_DIR=$STATE_DIR/dbc
ARMORY_UPLOAD_DIR=
ARMORY_PUBLISH=
ARMORY_TORRENT_DIR=
ENV
    )
    echo "Database login 'armory' (SELECT only) made; settings in $ENVF."
  fi
  [ -s "$ENVF" ] || { echo "No realm at /opt/wenilla-realm: write $ENVF by hand (see the top of this script)."; }
  chown root:herald "$ENVF" 2>/dev/null || true; chmod 640 "$ENVF" 2>/dev/null || true
  chown -R herald:herald "$DIR" "$STATE_DIR" /opt/openvanilla-herald/public/armory
  systemctl daemon-reload
  systemctl enable --now openvanilla-armory.timer
  echo "Armory: every 10 minutes -> /opt/openvanilla-herald/public/armory (https://<realm>/community/armory/)."
  echo "Logs: journalctl -u openvanilla-armory"
  exit 0
fi

# ---- one pass
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/armory_export.py" ]; then EXPORT="$HERE/armory_export.py"            # installed
else EXPORT="$HERE/../tools/armory_export.py"; fi                                   # a checkout
[ -f "$ENVF" ] && [ -r "$ENVF" ] && { set -a; . "$ENVF"; set +a; }
OUT=${ARMORY_OUT:-/opt/openvanilla-herald/public/armory}
ARGS=(--out "$OUT" --state "${ARMORY_STATE:-$STATE_DIR/state-${ARMORY_REALM:-classicplus}.json}")
[ -n "${ARMORY_REALM:-}" ] && ARGS+=(--realm "$ARMORY_REALM")
[ -n "${ARMORY_REALM_NAME:-}" ] && ARGS+=(--realm-name "$ARMORY_REALM_NAME")
[ -n "${ARMORY_DBC_DIR:-}" ] && ARGS+=(--dbc-dir "$ARMORY_DBC_DIR")
[ -n "${ARMORY_UPLOAD_DIR:-}" ] && ARGS+=(--community-dir "$ARMORY_UPLOAD_DIR")
[ -n "${ARMORY_PUBLISH:-}" ] && ARGS+=(--publish "$ARMORY_PUBLISH")
[ -n "${ARMORY_TORRENT_DIR:-}" ] && ARGS+=(--torrent "$ARMORY_TORRENT_DIR")
mkdir -p "$OUT"
exec python3 "$EXPORT" "${ARGS[@]}" "$@"
