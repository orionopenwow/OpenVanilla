#!/usr/bin/env bash
# ==============================================================================
# Open Vanilla Automated Daily Database & State Backup for Hetzner VPS
# ==============================================================================
# Recommended cron setup: run every day at 04:00 UTC
# 0 4 * * * /opt/openvanilla/hetzner/backup_cron.sh >> /var/log/openvanilla-backup.log 2>&1
# ==============================================================================

set -euo pipefail

BACKUP_DIR="/opt/openvanilla/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DEST="${BACKUP_DIR}/backup_${TIMESTAMP}"

# backups hold password verifiers: readable by root only
umask 077
mkdir -p "${DEST}"

echo "[$(date)] Starting Open Vanilla automated backup..."

# Dump MySQL/MariaDB databases
DB_USER="openvanilla"
# The password lives in /opt/openvanilla/.env (written by setup_hetzner.sh), never in the repo.
[ -f /opt/openvanilla/.env ] && . /opt/openvanilla/.env
DB_PASS="${OPENVANILLA_DB_PASSWORD:?OPENVANILLA_DB_PASSWORD missing from /opt/openvanilla/.env}"

for db in classicrealmd classiccharacters classicmangos; do
    echo "[$(date)] Dumping database: ${db}..."
    MYSQL_PWD="${DB_PASS}" mysqldump -u "${DB_USER}" --single-transaction --routines --triggers "${db}" | gzip > "${DEST}/${db}.sql.gz"
done

# Copy master links.txt config
if [ -f "/opt/openvanilla/links.txt" ]; then
    cp "/opt/openvanilla/links.txt" "${DEST}/links.txt"
fi

# Package into single tarball
tar -czf "${BACKUP_DIR}/openvanilla_backup_${TIMESTAMP}.tar.gz" -C "${BACKUP_DIR}" "backup_${TIMESTAMP}"
rm -rf "${DEST}"

echo "[$(date)] Backup completed: ${BACKUP_DIR}/openvanilla_backup_${TIMESTAMP}.tar.gz"

# Retain backups for 14 days, delete older
find "${BACKUP_DIR}" -type f -name "openvanilla_backup_*.tar.gz" -mtime +14 -delete
echo "[$(date)] Old backups purged (14-day retention)."
