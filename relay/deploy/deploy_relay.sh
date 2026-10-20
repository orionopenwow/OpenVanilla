#!/usr/bin/env bash
# Fresh Ubuntu 22.04+/Debian 12 VM -> relay.openvanilla.app. Run as root ON THE VM. Not run by CI.
# Prereq: DNS A/AAAA for relay.openvanilla.app points at this VM; copy this repo's relay/ dir here.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DST=/opt/openvanilla-relay

apt-get update
apt-get install -y ca-certificates curl rsync ufw unattended-upgrades
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

ufw default deny incoming
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

mkdir -p "$DST"
rsync -a --delete --exclude target "$SRC/" "$DST/src/"
cp -n "$DST/src/deploy/compose.yml" "$DST/src/deploy/Caddyfile" "$DST/" 2>/dev/null || true
sed -i "s#build: ..#build: ./src#" "$DST/compose.yml"
[ -f "$DST/relay.env" ] || { cp "$DST/src/deploy/relay.env.example" "$DST/relay.env";
  sed -i "s#change-me-shared-with-central#$(head -c 32 /dev/urandom | base64 | tr -d '/+=')#" "$DST/relay.env";
  echo ">> set the same RELAY_VERIFY_SECRET on central: $(grep VERIFY_SECRET "$DST/relay.env")"; }
[ -f "$DST/allow.txt" ] || echo "# host_id token_sha256 [public|private]" > "$DST/allow.txt"
chmod 600 "$DST/relay.env"

cd "$DST"
docker compose up -d --build
sleep 3
docker compose ps
curl -fsS https://relay.openvanilla.app/healthz && echo " relay up"
