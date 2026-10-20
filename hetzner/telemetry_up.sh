#!/usr/bin/env bash
# Realm telemetry as an always-on service (tools/telemetry/realm_telemetry.py): once a minute, the online
# characters' level, XP, zone and position and their quest progress, under pseudonyms, for balancing and
# bug hunting. Disclosed on the site's privacy page. Read with: bash telemetry_up.sh report
#
#   bash hetzner/telemetry_up.sh            install or update, and start
#   bash hetzner/telemetry_up.sh report     the findings of the last 7 days (stuck spots, deaths, quests, pace)
#   bash hetzner/telemetry_up.sh off        stop it (the data stays in /var/lib/openvanilla-telemetry)
#
# Also sets PlayerSave.Interval = 60000 in mangosd.conf (characters saved every minute instead of 15,
# so positions are fresh and a crash loses at most a minute). It applies at the next world-server
# restart; nothing is restarted here.
set -euo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
RAW=${RAW:-https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable}
APP=/opt/openvanilla-telemetry
DATA=/var/lib/openvanilla-telemetry
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
case "${1:-up}" in
  report)
    python3 "$APP/report.py" --db "$DATA/realm.db" --days "${2:-7}"; exit 0 ;;
  off)
    systemctl disable --now openvanilla-telemetry 2>/dev/null || true; echo "Telemetry stopped."; exit 0 ;;
esac
mkdir -p "$APP" "$DATA"; chmod 700 "$DATA"
curl -fsSL "$RAW/tools/telemetry/realm_telemetry.py" -o "$APP/realm_telemetry.py"
curl -fsSL "$RAW/tools/telemetry/report.py" -o "$APP/report.py"
cat > /etc/systemd/system/openvanilla-telemetry.service <<UNIT
[Unit]
Description=Open Vanilla realm telemetry (gameplay data for balancing; see the privacy page)
After=docker.service
[Service]
ExecStart=/usr/bin/python3 $APP/realm_telemetry.py --realm-dir $REALM_DIR --db $DATA/realm.db --every 60 --keep-days 30
Restart=on-failure
RestartSec=30
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now openvanilla-telemetry
systemctl restart openvanilla-telemetry
cd "$REALM_DIR"
docker compose exec -T -u 0 mangosd sh -c 'f=/config/mangosd.conf; if grep -q "^PlayerSave.Interval *=" $f; then sed -i "s/^PlayerSave.Interval *=.*/PlayerSave.Interval = 60000/" $f; else echo "PlayerSave.Interval = 60000" >> $f; fi; grep "^PlayerSave.Interval" $f'
sleep 5
journalctl -u openvanilla-telemetry -n 3 --no-pager -o cat || true
echo "Telemetry on. PlayerSave.Interval applies at the next world-server restart. Findings: bash $0 report"
