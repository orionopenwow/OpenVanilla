#!/usr/bin/env bash
# One-time move of a server set up under the project's old name (OLD below) to the Open Vanilla names:
# systemd services, /opt /etc /var folders, their settings (paths, service names, OPENVANILLA_* keys,
# image names), cron lines and named containers. Database tables move separately, per realm stack
# (openvanilla_rename_tables.sh, run by openvanilla_realm_up.sh). Safe to re-run; it does nothing once
# everything is moved. dev\Server.bat runs it before every realm update.
#   curl -fsSL https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable/hetzner/openvanilla_migrate.sh -o /root/openvanilla_migrate.sh
#   bash /root/openvanilla_migrate.sh
set -euo pipefail
OLD=openwow; NEW=openvanilla; OLDU=OPENWOW; NEWU=OPENVANILLA
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
SD=/etc/systemd/system
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/root/openvanilla-migrate-$STAMP
did=0

# Text rewrite for settings files: the old name becomes the new one, except the GitHub account
# (orionopenwow) and the old web addresses (*.$OLD.app), which still answer as aliases.
rewrite() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  grep -q -i "$OLD" "$1" || return 0
  mkdir -p "$BACKUP$(dirname "$1")"; cp -p "$1" "$BACKUP$1"
  sed -i -e "s/orion$OLD/\x01/g; s/\.$OLD\.app/\x02/g" \
         -e "s/$OLD/$NEW/g; s/$OLDU/$NEWU/g" \
         -e "s/\x01/orion$OLD/g; s/\x02/.$OLD.app/g" "$1"
  did=1
}

# 1. services: note which ran, stop and disable them under the old names
#    The list is kept in $STATE until the end, so a run that stops half-way still knows on the next run
#    which services to bring back. A unit that is off now but was stopped in the last day by an earlier
#    run of this script (from before $STATE existed) counts as running and enabled.
STATE=/root/openvanilla-migrate-units.txt
units=$(cd "$SD" && ls -1 2>/dev/null | grep -E "^$OLD-.*\.(service|timer)$" || true)
was_active=(); was_enabled=()
if [ -f "$STATE" ]; then
  while read -r kind u; do
    case "$kind" in active) was_active+=("$u") ;; enabled) was_enabled+=("$u") ;; esac
  done < "$STATE"
fi
for u in $units; do
  n=${u/$OLD-/$NEW-}
  if systemctl is-active -q "$u"; then was_active+=("$n")
  elif ! systemctl is-enabled -q "$u" 2>/dev/null && journalctl -q -u "$u" --since "-1 day" 2>/dev/null | grep -q "Stopped"; then
    was_active+=("$n"); was_enabled+=("$n"); echo "bring back $u (an earlier run stopped it)"
  fi
  systemctl is-enabled -q "$u" 2>/dev/null && was_enabled+=("$n") || true
  { printf 'active %s\n' "${was_active[@]}"; printf 'enabled %s\n' "${was_enabled[@]}"; } | { grep -v ' $' || true; } | sort -u > "$STATE"
  systemctl stop "$u" 2>/dev/null || true
  systemctl disable "$u" 2>/dev/null || true
done

# 2. the relay's compose project and the support containers carry the old name
if docker ps -a --format '{{.Names}}' >/dev/null 2>&1; then
  if [ -f "/opt/$OLD-relay/compose.yml" ]; then
    docker image inspect "$OLD-relay:latest" >/dev/null 2>&1 && docker tag "$OLD-relay:latest" "$NEW-relay:latest"
    docker compose -p "$OLD-relay" -f "/opt/$OLD-relay/compose.yml" down 2>/dev/null || true
    relay_was_up=1
  fi
  for c in $(docker ps -a --format '{{.Names}}' | grep -E "^$OLD-" || true); do
    [ -n "$(docker ps -a -q -f name="^${c/$OLD-/$NEW-}\$")" ] && { echo "keep $c (${c/$OLD-/$NEW-} exists)"; continue; }
    docker rename "$c" "${c/$OLD-/$NEW-}" && did=1
  done
fi

# 3. folders and files named with the old name
shopt -s nullglob
for p in /opt/$OLD /opt/$OLD-* /opt/${OLD}_* /etc/$OLD-* /etc/$OLD.* /var/lib/$OLD-* /var/log/$OLD-* /var/log/$OLD.* /root/${OLD}_* "$SD"/$OLD-*; do
  [ -e "$p" ] || [ -L "$p" ] || continue   # the plain names (like /opt/$OLD) aren't globs: skip them when absent
  n=${p//$OLD/$NEW}
  if [ -e "$n" ]; then echo "keep $p ($n exists)"; continue; fi
  mv "$p" "$n"; echo "moved $p -> $n"; did=1
done

# 4. settings that point at the old names
for f in "$SD"/$NEW-* /etc/$NEW-* /etc/$NEW-*/* /opt/wenilla-realm/.env /opt/wenilla-realm/*.yml /opt/wenilla-realm/*.yaml \
         /opt/wenilla-staging/.env /opt/wenilla-staging/*.yml /opt/wenilla-staging/*.yaml \
         /opt/wenilla-warfront/.env /opt/wenilla-warfront/*.yml /opt/wenilla-warfront/*.yaml \
         /opt/$NEW-*/*.env /opt/$NEW-*/*.yml /opt/$NEW-*/*.yaml /opt/$NEW-*/*.sh /opt/$NEW-*/Caddyfile* /opt/$NEW-*/*.conf; do
  rewrite "$f"
done
# the GitHub deploy key runs a fixed command under /opt (dev\Deploy_Key.bat): only that path changes
AK=/root/.ssh/authorized_keys
if [ -f "$AK" ] && grep -q "/opt/$OLD-" "$AK"; then
  mkdir -p "$BACKUP/root/.ssh"; cp -p "$AK" "$BACKUP$AK"
  sed -i "s#/opt/$OLD-#/opt/$NEW-#g" "$AK"; echo "deploy key command updated"; did=1
fi
if crontab -l >/dev/null 2>&1 && crontab -l | grep -q -i "$OLD"; then
  mkdir -p "$BACKUP"; crontab -l > "$BACKUP/crontab"
  crontab -l | sed -e "s/orion$OLD/\x01/g; s/$OLD/$NEW/g; s/$OLDU/$NEWU/g; s/\x01/orion$OLD/g" | crontab -
  echo "cron lines updated"; did=1
fi

# 5. services back under the new names
systemctl daemon-reload
for u in "${was_enabled[@]}"; do [ -e "$SD/$u" ] && systemctl enable "$u" 2>/dev/null || true; done
for u in "${was_active[@]}"; do [ -e "$SD/$u" ] && systemctl start "$u" || echo "!! $u didn't start: journalctl -u $u"; done
rm -f "$STATE"
if [ "${relay_was_up:-0}" = 1 ] && [ -f "/opt/$NEW-relay/compose.yml" ]; then
  NET=$(docker network ls --format '{{.Name}}' | grep -x 'wenilla-realm_default' || true)
  OW_REALM_NET=${NET:-wenilla-realm_default} docker compose -p "$NEW-relay" -f "/opt/$NEW-relay/compose.yml" up -d
fi

# 6. web names: staging, Warfront and the relay move from *.$OLD.app to *.$NEW.app once that name
#    points at this server (DNS first; the next realm update, dev\Server.bat 1, rebuilds Caddy with them)
HERE_IP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
points_here() { [ -n "$HERE_IP" ] && [ "$(getent ahostsv4 "$1" | awk 'NR==1{print $1}')" = "$HERE_IP" ]; }
for envf in /opt/wenilla-staging/.env /opt/wenilla-warfront/.env; do
  [ -f "$envf" ] || continue
  cur=$(grep '^REALM_DOMAIN=' "$envf" | tail -1 | cut -d= -f2)
  case "$cur" in *.$OLD.app) ;; *) continue ;; esac
  new=${cur%.$OLD.app}.$NEW.app
  if points_here "$new"; then
    mkdir -p "$BACKUP$(dirname "$envf")"; cp -p "$envf" "$BACKUP$envf"
    sed -i "s/^REALM_DOMAIN=.*/REALM_DOMAIN=$new/" "$envf"; echo "web name: $cur -> $new"; did=1
  else
    echo "!! $new doesn't point at this server yet ($HERE_IP): $(dirname "$envf") stays on $cur. Add the DNS record and run this again."
  fi
done
for f in /opt/$NEW-relay/Caddyfile.relay /opt/$NEW-relay/relay.env; do
  [ -f "$f" ] && grep -q "relay\.$OLD\.app" "$f" || continue
  if points_here "relay.$NEW.app"; then
    mkdir -p "$BACKUP$(dirname "$f")"; cp -p "$f" "$BACKUP$f"
    sed -i "s/relay\.$OLD\.app/relay.$NEW.app/g" "$f"; echo "web name: relay.$NEW.app in $f"; did=1
  else
    echo "!! relay.$NEW.app doesn't point at this server yet: the relay stays on relay.$OLD.app"
  fi
done

if [ "$did" = 1 ]; then
  echo "Moved to the Open Vanilla names. The old settings are kept in $BACKUP"
else
  echo "Server names: already Open Vanilla"
fi
