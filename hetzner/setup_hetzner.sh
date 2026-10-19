#!/usr/bin/env bash
# ==============================================================================
# Open Vanilla Hetzner Cloud VPS - Automated 1-Command Deployment Script
# ==============================================================================
# Tested on: Ubuntu 24.04 LTS / Ubuntu 22.04 LTS / Debian 12
# Prepares: openvanilla.app custom domain, MariaDB, Caddy TLS, backend, and realm services
#
# Usage:
#   sudo bash setup_hetzner.sh
# ==============================================================================

set -euo pipefail

# ANSI color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GOLD='\033[38;5;220m'
NC='\033[0m'

echo -e "${GOLD}"
echo "=============================================================================="
echo "    Open Vanilla Cloud Server Bootstrap & Deployment Kit (openvanilla.app)"
echo "=============================================================================="
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run this script as root (sudo bash setup_hetzner.sh)${NC}"
  exit 1
fi

APP_DIR="/opt/openvanilla"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# 1. Update Packages & Install System Prerequisites
# ------------------------------------------------------------------------------
echo -e "${BLUE}[1/8] Updating package lists and installing dependencies...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
    curl wget git unzip tar build-essential libssl-dev libffi-dev \
    python3 python3-pip python3-venv \
    mariadb-server mariadb-client \
    ufw fail2ban debian-keyring debian-archive-keyring apt-transport-https

# Install official Caddy web server
if ! command -v caddy &> /dev/null; then
    echo -e "${BLUE}[*] Installing Caddy Web Server...${NC}"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y
    apt-get install -y caddy
fi

# ------------------------------------------------------------------------------
# 2. Configure Firewall (UFW)
# ------------------------------------------------------------------------------
echo -e "${BLUE}[2/8] Configuring UFW firewall rules...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH (rate limited)'
ufw allow 80/tcp comment 'HTTP (Caddy Let Encrypt)'
ufw allow 443/tcp comment 'HTTPS (openvanilla.app)'
ufw allow 443/udp comment 'HTTP3 / QUIC'
ufw allow 3724/tcp comment 'Open Vanilla Auth realmd'
ufw allow 8085/tcp comment 'Open Vanilla World mangosd'
# Note: 3306 (MariaDB) and 18090 (Internal Web Relay) stay restricted to localhost
ufw --force enable
# Key-only SSH, but only once a key is installed, so this can't lock you out.
if [ -s /root/.ssh/authorized_keys ]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/10-openvanilla.conf
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
    echo -e "${YELLOW}[!] No SSH key in /root/.ssh/authorized_keys: password login left on. Add a key and re-run.${NC}"
fi
systemctl enable --now fail2ban

# ------------------------------------------------------------------------------
# 3. Create Dedicated User & Setup App Directory
# ------------------------------------------------------------------------------
echo -e "${BLUE}[3/8] Setting up openvanilla system user and directory structure...${NC}"
if ! id -u openvanilla &>/dev/null; then
    useradd -r -m -s /bin/bash openvanilla
fi

mkdir -p "${APP_DIR}"/{www,launcher,backups,server/bin,server/etc,logs}

# Copy files if running from uploaded AdventureWorld repository
if [ -f "${SCRIPT_DIR}/../asset_server.py" ]; then
    echo -e "${BLUE}[*] Copying project files to ${APP_DIR}...${NC}"
    cp -r "${SCRIPT_DIR}/../www" "${APP_DIR}/"
    cp -r "${SCRIPT_DIR}/../launcher" "${APP_DIR}/"
    cp "${SCRIPT_DIR}/../asset_server.py" "${SCRIPT_DIR}/../authcheck.py" "${SCRIPT_DIR}/../server_control.py" "${APP_DIR}/"
    cp "${SCRIPT_DIR}/../archive/discord_bot.py" "${APP_DIR}/"
    cp "${SCRIPT_DIR}/../links.txt" "${APP_DIR}/"
    [ -f "${SCRIPT_DIR}/../requirements.txt" ] && cp "${SCRIPT_DIR}/../requirements.txt" "${APP_DIR}/"
fi

# ------------------------------------------------------------------------------
# 4. Setup Python Environment & Dependencies
# ------------------------------------------------------------------------------
echo -e "${BLUE}[4/8] Configuring Python 3 virtual environment...${NC}"
if [ ! -d "${APP_DIR}/venv" ]; then
    python3 -m venv "${APP_DIR}/venv"
fi
"${APP_DIR}/venv/bin/pip" install --upgrade pip
"${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"

# ------------------------------------------------------------------------------
# 5. Initialize MariaDB Database
# ------------------------------------------------------------------------------
echo -e "${BLUE}[5/8] Initializing MariaDB and realm database tables...${NC}"
systemctl enable mariadb
systemctl start mariadb

# Run base initialization
# One random DB password per server, kept in /opt/openvanilla/.env (mode 600), never in the repo.
touch "${APP_DIR}/.env" && chmod 600 "${APP_DIR}/.env"
if ! grep -q '^OPENVANILLA_DB_PASSWORD=' "${APP_DIR}/.env"; then
    echo "OPENVANILLA_DB_PASSWORD=$(openssl rand -hex 24)" >> "${APP_DIR}/.env"
fi
. "${APP_DIR}/.env"
# What asset_server.py / server_control.py read (the backend never uses root).
grep -q '^MYSQL_USER=' "${APP_DIR}/.env" || cat >> "${APP_DIR}/.env" <<ENVEOF
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_USER=openvanilla
MYSQL_PASSWORD=${OPENVANILLA_DB_PASSWORD}
MYSQL_BIN=/usr/bin/mariadb
ENVEOF
if [ -f "${SCRIPT_DIR}/database/init_db.sql" ]; then
    sed "s/CHANGE_ME_DB_PASSWORD/${OPENVANILLA_DB_PASSWORD}/" "${SCRIPT_DIR}/database/init_db.sql" | mariadb
    echo -e "${GREEN}[+] Base database structure and openvanilla DB user created.${NC}"
fi

# Check if database dump files exist to import
DUMPS_DIR="${SCRIPT_DIR}/database/dumps"
if [ -d "${DUMPS_DIR}" ]; then
    for db in classicrealmd classiccharacters classicmangos; do
        if [ -f "${DUMPS_DIR}/${db}.sql" ]; then
            echo -e "${BLUE}[*] Importing exported ${db}.sql snapshot...${NC}"
            mariadb "${db}" < "${DUMPS_DIR}/${db}.sql"
        fi
    done
    # Re-apply realmlist domain pointer to openvanilla.app after importing dumps
    mariadb -e "USE classicrealmd; UPDATE realmlist SET address='openvanilla.app', name='Vanilla Remastered', icon=0 WHERE id=1;"
    echo -e "${GREEN}[+] Database dumps imported and realmlist synced to openvanilla.app.${NC}"
fi

# ------------------------------------------------------------------------------
# 6. Configure Production Caddy Web Server
# ------------------------------------------------------------------------------
echo -e "${BLUE}[6/8] Configuring Caddy for openvanilla.app with automatic TLS...${NC}"
if [ -f "${SCRIPT_DIR}/Caddyfile.production" ]; then
    cp "${SCRIPT_DIR}/Caddyfile.production" /etc/caddy/Caddyfile
    systemctl reload caddy || systemctl restart caddy
    echo -e "${GREEN}[+] Caddyfile deployed and reloaded.${NC}"
fi

# ------------------------------------------------------------------------------
# 7. Install Systemd Services
# ------------------------------------------------------------------------------
echo -e "${BLUE}[7/8] Installing systemd daemon service units...${NC}"
cp "${SCRIPT_DIR}"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload

# Enable backend and discord bot
systemctl enable openvanilla-backend.service
systemctl restart openvanilla-backend.service

# Setup automated backup cron
cp "${SCRIPT_DIR}/backup_cron.sh" "${APP_DIR}/backup_cron.sh"
chmod +x "${APP_DIR}/backup_cron.sh"
(crontab -l 2>/dev/null | grep -v "backup_cron.sh"; echo "0 4 * * * /opt/openvanilla/backup_cron.sh >> /var/log/openvanilla-backup.log 2>&1") | crontab -

chown -R openvanilla:openvanilla "${APP_DIR}"
# root's cron runs the backup and it reads .env: neither may be writable by the service user,
# or code running as openvanilla (mangosd, realmd, the bot) could get root at 04:00.
chown root:root "${APP_DIR}/backup_cron.sh" && chmod 700 "${APP_DIR}/backup_cron.sh"
[ -f "${APP_DIR}/.env" ] && chown root:openvanilla "${APP_DIR}/.env" && chmod 640 "${APP_DIR}/.env"

# ------------------------------------------------------------------------------
# 8. Final Status & Verification
# ------------------------------------------------------------------------------
echo -e "${BLUE}[8/8] Verifying running services...${NC}"
sleep 2

echo -e "\n${GOLD}==============================================================================${NC}"
echo -e "${GREEN}  Open Vanilla Hetzner Cloud Server Setup Complete!${NC}"
echo -e "${GOLD}==============================================================================${NC}"
echo -e "Web & Asset Backend : $(systemctl is-active openvanilla-backend.service)"
echo -e "Caddy HTTPS Gateway : $(systemctl is-active caddy)"
echo -e "MariaDB Database    : $(systemctl is-active mariadb)"
echo -e "Backup Cron Job     : Active daily at 04:00 UTC"
echo -e "------------------------------------------------------------------------------"
echo -e "Domain Status:"
echo -e "  Ensure your DNS A record for ${YELLOW}openvanilla.app${NC} points to this server IP."
echo -e "  Once DNS propagates, Caddy automatically provisions your Let's Encrypt SSL certificate."
echo -e "  Website:     ${GOLD}https://openvanilla.app/${NC}"
echo -e "  Realmlist:   ${GOLD}openvanilla.app:8085 (PvE)${NC}"
echo -e "==============================================================================\n"
