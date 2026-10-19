#!/usr/bin/env bash
# Open Vanilla bot lab: a night of server-side playerbots on the test realm, logged for analysis.
#   bash botlab.sh start [bots] [hours]   turn on N low-level random bots (default 40) for H hours (default 8),
#                                         log them every minute, and switch everything back after H hours
#   bash botlab.sh status                 is it running, how many bots, last log lines
#   bash botlab.sh report                 one-page summary (prints it; CSVs in /var/lib/botlab/report)
#   bash botlab.sh stop                   stop logging, put the original bot and save settings back
# Get it:  curl -fsSL https://raw.githubusercontent.com/orionopenwow/OpenVanilla/main/hetzner/botlab.sh -o botlab.sh
# start and stop restart the world server (about a minute; anyone online is disconnected).
# Bots are CMaNGOS playerbots on RNDBOT accounts: levels 1-12, Eastern Kingdoms and Kalimdor, extra Human
# Hunters, no bot cheats, no LFG or battlegrounds. Only reads the game databases while logging.
set -euo pipefail
REALM_DIR=${REALM_DIR:-/opt/wenilla-realm}
LAB=/var/lib/botlab
APP=/opt/openvanilla-botlab
RAW=https://raw.githubusercontent.com/orionopenwow/OpenVanilla/main
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cd "$REALM_DIR"
mkdir -p "$LAB" "$APP"
say() { printf '\n\033[1;33m== %s\033[0m\n' "$*"; }
conf_get() { docker compose exec -T -u 0 mangosd cat "/config/$1"; }
conf_put() { docker compose exec -T -u 0 mangosd sh -c "cat > /config/$1"; }   # in place: keeps owner and mode
# conf_set FILE KEY=VALUE...  (replaces an existing or commented-out key, else appends)
conf_set() {
  local f=$1; shift
  conf_get "$f" | python3 -c '
import re, sys
text = sys.stdin.read().splitlines()
for kv in sys.argv[1:]:
    k, v = kv.split("=", 1)
    live = re.compile(r"^\s*" + re.escape(k) + r"\s*=")
    dead = re.compile(r"^#\s*" + re.escape(k) + r"\s*=")
    hits = [i for i, l in enumerate(text) if live.match(l)]
    if not hits:
        hits = [i for i, l in enumerate(text) if dead.match(l)][:1]
    for i in hits:
        text[i] = f"{k} = {v}"
    if not hits:
        text.append(f"{k} = {v}")
print("\n".join(text))' "$@" > "$LAB/$f.new"
  [ -s "$LAB/$f.new" ] || { echo "Could not read /config/$f"; exit 1; }
  conf_put "$f" < "$LAB/$f.new"
}

case "${1:-}" in
  start)
    N=${2:-40}; H=${3:-8}
    [[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le 200 ] || { echo "Bots: 1-200"; exit 1; }
    [[ "$H" =~ ^[0-9]+$ ]] && [ "$H" -ge 1 ] && [ "$H" -le 48 ] || { echo "Hours: 1-48"; exit 1; }
    systemctl is-active --quiet openvanilla-botlab && { echo "Already running. bash botlab.sh status"; exit 1; }
    systemctl reset-failed openvanilla-botlab openvanilla-botlab-stop 2>/dev/null || true
    say "Downloading the logger and report"
    curl -fsSL "$RAW/tools/botlab/botlab_logger.py" -o "$APP/botlab_logger.py"
    curl -fsSL "$RAW/tools/botlab/botlab_report.py" -o "$APP/botlab_report.py"
    cp "$0" "$APP/botlab.sh" 2>/dev/null || curl -fsSL "$RAW/hetzner/botlab.sh" -o "$APP/botlab.sh"
    say "Saving the current settings (put back by stop)"
    [ -s "$LAB/aiplayerbot.conf.orig" ] || conf_get aiplayerbot.conf > "$LAB/aiplayerbot.conf.orig"
    [ -s "$LAB/mangosd.conf.orig" ] || conf_get mangosd.conf > "$LAB/mangosd.conf.orig"
    ACC=$(grep -E '^AiPlayerbot.RandomBotAccountCount' "$LAB/aiplayerbot.conf.orig" | grep -oE '[0-9]+' | head -1)
    ACC=$(( ${ACC:-50} > N ? ${ACC:-50} : N ))
    say "Bot settings: $N bots, levels 1-12, extra Human Hunters"
    conf_set aiplayerbot.conf \
      AiPlayerbot.Enabled=1 AiPlayerbot.MinRandomBots="$N" AiPlayerbot.MaxRandomBots="$N" \
      AiPlayerbot.RandomBotAccountCount="$ACC" AiPlayerbot.RandomBotAutoCreate=1 \
      AiPlayerbot.RandomBotMinLevel=1 AiPlayerbot.RandomBotMaxLevel=12 AiPlayerbot.RandomBotMaxLevelChance=0 \
      AiPlayerbot.RandomBotMaps=0,1 AiPlayerbot.RandomBotTimedLogout=0 AiPlayerbot.RandomBotTimedOffline=0 \
      AiPlayerbot.RandomBotJoinLfg=0 AiPlayerbot.RandomBotAutoJoinBG=0 AiPlayerbot.PreQuests=0 \
      AiPlayerbot.ClassRaceProb.3.1=300 AiPlayerbot.ClassRaceProb.3.3=60
    # no cheats for bots: their numbers have to match a real player's
    conf_get aiplayerbot.conf | sed -E 's/^(AiPlayerbot\.(RndBotCheats|BotCheats) *=)/# \1/' > "$LAB/apb.tmp"
    conf_put aiplayerbot.conf < "$LAB/apb.tmp"
    say "Characters saved every minute (was 15) so the log sees each step"
    conf_set mangosd.conf PlayerSave.Interval=60000
    say "Restarting the world server"
    docker compose restart mangosd
    say "Logging every minute for $H hours"
    systemd-run --unit=openvanilla-botlab --description="Open Vanilla bot lab logger" --property=Restart=on-failure \
      python3 "$APP/botlab_logger.py" --realm-dir "$REALM_DIR" --db "$LAB/lab.db" --hours "$H" --every 60
    systemctl stop openvanilla-botlab-stop.timer 2>/dev/null || true
    systemd-run --unit=openvanilla-botlab-stop --on-active="${H}h" --description="Open Vanilla bot lab: switch back" \
      /bin/bash "$APP/botlab.sh" stop
    echo "Started. Bots log in over the next few minutes. Check: bash botlab.sh status"
    echo "Everything switches back by itself in $H hours (or: bash botlab.sh stop)."
    ;;
  status)
    systemctl is-active openvanilla-botlab || true
    journalctl -u openvanilla-botlab -n 5 --no-pager -o cat || true
    systemctl list-timers openvanilla-botlab-stop.timer --no-pager 2>/dev/null | sed -n 1,2p || true
    ;;
  report)
    python3 "$APP/botlab_report.py" --db "$LAB/lab.db" --out "$LAB/report"
    ;;
  stop)
    systemctl stop openvanilla-botlab 2>/dev/null || true
    systemctl stop openvanilla-botlab-stop.timer 2>/dev/null || true
    say "Putting the original settings back"
    [ -s "$LAB/aiplayerbot.conf.orig" ] && conf_put aiplayerbot.conf < "$LAB/aiplayerbot.conf.orig" && mv "$LAB/aiplayerbot.conf.orig" "$LAB/aiplayerbot.conf.used"
    [ -s "$LAB/mangosd.conf.orig" ] && conf_put mangosd.conf < "$LAB/mangosd.conf.orig" && mv "$LAB/mangosd.conf.orig" "$LAB/mangosd.conf.used"
    say "Restarting the world server (bots off)"
    docker compose restart mangosd
    [ -f "$APP/botlab_report.py" ] && python3 "$APP/botlab_report.py" --db "$LAB/lab.db" --out "$LAB/report" >/dev/null 2>&1 || true
    echo "Stopped. The data stays in $LAB (bash botlab.sh report)."
    ;;
  *) sed -n 2,12p "$0"; exit 1 ;;
esac
