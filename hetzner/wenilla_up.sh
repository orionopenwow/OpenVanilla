#!/usr/bin/env bash
# Open Vanilla dedicated realm in one command, using wenilla-realm (CMaNGOS classic + browser client + Caddy HTTPS).
# Run as root on a fresh Ubuntu 22.04/24.04 x86-64 VM (Hetzner CPX31 or CX32 recommended):
#
#   curl -fsSL https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable/hetzner/wenilla_up.sh -o wenilla_up.sh
#   bash wenilla_up.sh play.yourname.duckdns.org
#
# It installs Docker, adds swap, locks down the firewall (22/80/443 only), downloads the WoW 1.12.1 client
# data straight to the VM, then runs wenilla-realm's own init / extract / up. Safe to re-run.
set -euo pipefail

DOMAIN="${1:-}"
CLIENT_URL="${CLIENT_URL:-https://archive.org/download/nostalrius-wow-classic/Nostalrius-WoW-Classic.zip}"
CLIENT_DIR="/srv/client"
REALM_DIR="/opt/wenilla-realm"
say() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo bash $0 $DOMAIN)"; exit 1; }
[ -n "$DOMAIN" ] || { echo "Usage: bash $0 your.domain.name   (the A record must point at this server)"; exit 1; }

say "1/7 Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git unzip ufw fail2ban python3 ca-certificates
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
docker compose version >/dev/null

say "2/7 Swap (2 GB) and firewall"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
ufw default deny incoming && ufw default allow outgoing
ufw limit 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp
ufw --force enable
systemctl enable --now fail2ban
if [ -s /root/.ssh/authorized_keys ]; then  # key-only SSH, only once a key exists (can't lock you out)
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/10-openvanilla.conf
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi

say "3/7 Checking that $DOMAIN points at this server"
MYIP="$(curl -fsS https://api.ipify.org || true)"
DNSIP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
echo "this server: ${MYIP:-?}   $DOMAIN: ${DNSIP:-not found}"
if [ -z "$DNSIP" ] || [ "$DNSIP" != "$MYIP" ]; then
  echo "The domain doesn't point here yet. Set its A record to $MYIP, wait a minute and run this again."
  exit 1
fi

say "4/7 WoW 1.12.1 client data -> $CLIENT_DIR/Data"
if [ ! -d "$CLIENT_DIR/Data" ]; then
  mkdir -p "$CLIENT_DIR" && cd /root
  # archive.org's /download/ redirector often fails on big files: try its storage servers first
  MIRRORS="$(python3 - "$CLIENT_URL" <<'PY'
import json, re, sys, urllib.request
url = sys.argv[1]
m = re.match(r"https?://(?:www\.)?archive\.org/download/([^/]+)/(.+)$", url)
out = []
if m:
    try:
        meta = json.load(urllib.request.urlopen(f"https://archive.org/metadata/{m.group(1)}", timeout=20))
        for k in ("d1", "d2"):
            if meta.get(k):
                out.append(f"https://{meta[k]}{meta['dir']}/{m.group(2)}")
        md5 = next((f.get("md5") for f in meta.get("files", []) if f.get("name") == m.group(2)), "")
        open("/root/client.md5", "w").write(md5 or "")
    except Exception:
        pass
print("\n".join(out + [url]))
PY
)"
  ok=""
  for u in $MIRRORS; do
    echo "downloading from $u"
    if curl -fL --retry 5 --retry-delay 5 -C - -o client.zip "$u"; then ok=1; break; fi
  done
  [ -n "$ok" ] || { echo "Client download failed; re-run to resume."; exit 1; }
  if [ -s /root/client.md5 ]; then
    echo "$(cat /root/client.md5)  client.zip" | md5sum -c - || { echo "Checksum mismatch: deleting the download, re-run."; rm -f client.zip; exit 1; }
  fi
  rm -rf /root/client_unpack && mkdir /root/client_unpack
  unzip -q client.zip -d /root/client_unpack
  # the Data folder that actually holds the .MPQ files, at any depth
  DATA="$(find /root/client_unpack -type d -iname data -exec sh -c 'ls "$1"/*.[Mm][Pp][Qq] >/dev/null 2>&1' _ {} \; -print | head -1)"
  [ -n "$DATA" ] || { echo "No Data folder in the client zip."; exit 1; }
  mv "$DATA" "$CLIENT_DIR/Data"
  rm -rf /root/client_unpack client.zip
fi
ls "$CLIENT_DIR/Data" | head

say "5/7 wenilla-realm"
if [ -d "$REALM_DIR/.git" ]; then git -C "$REALM_DIR" pull --ff-only; else git clone https://github.com/Arnesen/wenilla-realm "$REALM_DIR"; fi
cd "$REALM_DIR"
if [ ! -f .env ]; then
  echo
  echo "realmctl init asks a few questions. Answer:"
  echo "   hostname / domain ........ $DOMAIN"
  echo "   client Data folder ....... $CLIENT_DIR/Data"
  echo "   build movement maps ...... no (tonight; they take hours, can be added later)"
  echo
  ./realmctl init
fi

say "6/7 Extracting server map data from the client (one time, can take a while)"
if [ ! -f /root/.openvanilla_extracted ]; then ./realmctl extract && touch /root/.openvanilla_extracted; fi

say "7/7 Starting the realm"
./realmctl up
echo
echo "Done. Open https://$DOMAIN/setup in your browser, paste the setup token shown above,"
echo "name the realm Vanilla Remastered and create your admin login. Invite players from the panel."
