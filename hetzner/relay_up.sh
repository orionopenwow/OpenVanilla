#!/usr/bin/env bash
# The node network's test round, step 1: Open Vanilla's own relay (relay.openvanilla.app) on the realm server
# you already run (Hetzner), behind the realm's Caddy. Safe to re-run. Not run by CI.
#
#   Prereq: DNS A (and AAAA if the box has IPv6) for relay.openvanilla.app -> this server.
#           The realm is up (openvanilla_realm_up.sh): its Docker network and Caddy are used.
#   Run as root ON THE REALM SERVER from a checkout of this repo:
#       bash hetzner/relay_up.sh
#   Undo:   docker compose -p openvanilla-relay down && rm /opt/openvanilla-relay/relay.env
#           (then re-run openvanilla_realm_up.sh, which drops the relay site from Caddy)
#
# What it does: builds relay/ into an image, runs it with no published ports on the realm's Docker
# network (CPU/RAM/PID limits), writes relay.env with a fresh verify secret, adds a
# relay.openvanilla.app site to the realm's Caddyfile (TLS, HTTP/3, no access log, /metrics hidden)
# and reloads Caddy. No firewall change: only 443 is used, which the realm already opens.
set -euo pipefail
SRC=${OW_SRC:-$(cd "$(dirname "$0")/.." && pwd)}
DST=${OW_RELAY_DIR:-/opt/openvanilla-relay}
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
CP=${OW_CP:-/opt/openvanilla-classicplus}
DOMAIN=${RELAY_DOMAIN:-relay.openvanilla.app}
NET=${OW_REALM_NET:-wenilla-realm_default}
say() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root on the realm server."
command -v docker >/dev/null || die "Docker isn't installed: this script adds the relay to the existing realm server."
[ -f "$SRC/relay/Cargo.toml" ] || die "Run it from a checkout of the Open Vanilla repo (relay/ not found under $SRC)."
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

say "Relay source and settings in $DST"
mkdir -p "$DST/src"
rsync -a --delete --exclude target "$SRC/relay/" "$DST/src/"
install -m 644 "$SRC/hetzner/relay/compose.yml" "$DST/compose.yml"
sed "s#RELAY_DOMAIN#$DOMAIN#" "$SRC/hetzner/relay/Caddyfile.relay" > "$DST/Caddyfile.relay"
if [ ! -f "$DST/relay.env" ]; then
  cp "$SRC/hetzner/relay/relay.env.example" "$DST/relay.env"
  secret=$(head -c 32 /dev/urandom | base64 | tr -d '/+=')
  sed -i "s#change-me-shared-with-central#$secret#" "$DST/relay.env"
  echo "new relay.env with a fresh RELAY_VERIFY_SECRET"
fi
chmod 600 "$DST/relay.env"
[ -f "$DST/allow.txt" ] || printf '# host_id sha256(token)_hex [public|private]   (tools/relay_smoke.py --gen prints a line)\n' > "$DST/allow.txt"
chmod 644 "$DST/allow.txt"

say "Build and start the relay (no published ports; 1 CPU, 256 MB)"
docker build -q -t openvanilla-relay:latest "$DST/src"
OW_REALM_NET="$NET" docker compose -p openvanilla-relay -f "$DST/compose.yml" up -d --force-recreate
sleep 2
docker compose -p openvanilla-relay -f "$DST/compose.yml" ps

say "Caddy: add $DOMAIN to the realm's site list"
if ! grep -q "^# openvanilla-relay:" "$CP/Caddyfile"; then
  cat "$DST/Caddyfile.relay" >> "$CP/Caddyfile"     # append keeps the inode, so Caddy's bind mount sees it
  echo "added (openvanilla_realm_up.sh keeps it on every re-run while $DST/relay.env exists)"
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
  echo "!! https://$DOMAIN/healthz didn't answer yet (certificate still being issued?). Check: docker compose -p openvanilla-relay logs --tail 50"
fi
command -v ufw >/dev/null && { ufw status | grep -E '^(443|80)' || echo "!! ufw doesn't show 80/443 open: the realm's site would be down too"; }

cat <<EOF

Done. The relay runs; nobody uses it until the launcher's live flags say so.
Next (docs/NODE_NETWORK.md, "Test round"):
  1. From your PC: python tools/relay_smoke.py --gen   -> add the printed line to $DST/allow.txt,
     restart the relay (docker compose -p openvanilla-relay restart), then from your PC:
     python tools/relay_smoke.py --relay wss://$DOMAIN --host-id <id> --token <token>
  2. When patch 0012 (+0016) is deployed: give the realm container the RELAY_VERIFY_SECRET from
     $DST/relay.env, plus RELAY_HOST=$DOMAIN RELAY_PLAYER_URL=wss://$DOMAIN DIRECTORY_ENABLED=1
     IDENTITY_ENABLED=1 (realm/patches/pending/P2P_README.md).
  3. Flip live.json flags.relay to true; later flags.nodes for volunteer nodes.
Watch it: docker stats openvanilla-relay-relay-1 ;  docker compose -p openvanilla-relay logs -f
EOF
