#!/usr/bin/env bash
# Vanilla Agents browser access (V-054): the relay at agents.openvanilla.app, on the realm server you already run, behind the
# realm's Caddy. Safe to re-run (it also updates the relay). Not run by CI.
#
#   Prereq: DNS A (and AAAA if the box has IPv6) for agents.openvanilla.app -> this server.
#           The realm is up (openvanilla_realm_up.sh): its Docker network and Caddy are used.
#   Run as root ON THE REALM SERVER from a checkout of this repo:
#       bash hetzner/agents_relay_up.sh
#   Undo:   docker compose -p vanilla-agents-relay down && rm -r /opt/vanilla-agents-relay
#           (then re-run openvanilla_realm_up.sh, which drops the site from Caddy)
#
# What it does: builds hetzner/agents-relay into a small image (Python standard library, no packages), runs it with no
# published ports on the realm's Docker network (CPU/RAM/PID limits, read-only), adds an agents.openvanilla.app site to
# the realm's Caddyfile (TLS, no access log) and reloads Caddy. Only 443 is used, which the realm already opens.
# The relay cannot read what it forwards; it keeps pairs.json (pair id -> sha256 of that PC's token) in $DST/data.
set -euo pipefail
SRC=${OW_SRC:-$(cd "$(dirname "$0")/.." && pwd)}
DST=${VA_RELAY_DIR:-/opt/vanilla-agents-relay}
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
CP=${OW_CP:-/opt/openvanilla-classicplus}
DOMAIN=${AGENTS_DOMAIN:-agents.openvanilla.app}
NET=${OW_REALM_NET:-wenilla-realm_default}
say() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root on the realm server."
command -v docker >/dev/null || die "Docker isn't installed: this script adds the relay to the existing realm server."
[ -f "$SRC/hetzner/agents-relay/varelay/relay.py" ] || die "Run it from a checkout of the Open Vanilla repo (hetzner/agents-relay not found under $SRC)."
docker network inspect "$NET" >/dev/null 2>&1 || die "The realm's Docker network $NET isn't there. Run openvanilla_realm_up.sh first."
[ -f "$CP/Caddyfile" ] || die "$CP/Caddyfile is missing. Run openvanilla_realm_up.sh first."

say "DNS"
want=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
mine=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
if [ -z "$want" ]; then
  die "$DOMAIN doesn't resolve yet. Add an A record pointing at this server ($mine) and try again."
elif ! echo " $mine " | grep -q " $want "; then
  echo "!! $DOMAIN points at $want, but this server has: $mine"
  echo "   (fine behind a floating IP; otherwise fix DNS before Caddy asks Let's Encrypt for a certificate)"
else
  echo "$DOMAIN -> $want (this server)"
fi

say "Relay files in $DST"
mkdir -p "$DST/src" "$DST/data"
rsync -a --delete "$SRC/hetzner/agents-relay/" "$DST/src/"
install -m 644 "$SRC/hetzner/agents-relay/compose.yml" "$DST/compose.yml"
sed "s#AGENTS_DOMAIN#$DOMAIN#" "$SRC/hetzner/agents-relay/Caddyfile.agents" > "$DST/Caddyfile.agents"
chown 65534:65534 "$DST/data"
chmod 700 "$DST/data"

say "Build and start the relay (no published ports; half a CPU, 128 MB)"
docker build -q -t vanilla-agents-relay:latest "$DST/src"
OW_REALM_NET="$NET" docker compose -p vanilla-agents-relay -f "$DST/compose.yml" up -d --force-recreate
sleep 2
docker compose -p vanilla-agents-relay -f "$DST/compose.yml" ps

say "Caddy: add $DOMAIN to the realm's site list"
if ! grep -q "^# vanilla-agents-relay:" "$CP/Caddyfile"; then
  cat "$DST/Caddyfile.agents" >> "$CP/Caddyfile"     # append keeps the inode, so Caddy's bind mount sees it
  echo "added (openvanilla_realm_up.sh keeps it on every re-run while $DST/Caddyfile.agents exists)"
else
  echo "already there"
fi
(cd "$REALM_DIR" && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile)

say "Check"
ok=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 "https://$DOMAIN/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ "$ok" = 1 ]; then echo "https://$DOMAIN/healthz -> ok"; else
  echo "!! https://$DOMAIN/healthz didn't answer yet (certificate still being issued?). Check: docker compose -p vanilla-agents-relay logs --tail 50"
fi

cat <<EOT

Done. Browser access can now use wss://$DOMAIN/ws (Vanilla Agents' default) and Claude connectors https://$DOMAIN/mcp/...
Watch it: docker stats vanilla-agents-relay-relay-1 ;  docker compose -p vanilla-agents-relay logs -f
EOT
