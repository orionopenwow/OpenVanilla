#!/usr/bin/env bash
# Herald on the live realm: let players hand their own character to the realm's bot AI and watch it
# play (the Herald button by the minimap, or .bot self). Any race, any class.
#   bash herald_selfbot.sh on      AiPlayerbot.SelfBotLevel = 2, and Herald Autopilot's API allows autoplay
#   bash herald_selfbot.sh off     back to 0 (nobody can hand over), API autoplay off
#   bash herald_selfbot.sh status
# Get it:  curl -fsSL https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable/hetzner/herald_selfbot.sh -o herald_selfbot.sh
# on and off restart the world server (about a minute; anyone online is disconnected).
set -euo pipefail
REALM_DIR=${REALM_DIR:-/opt/wenilla-realm}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cd "$REALM_DIR"
conf_get() { docker compose exec -T -u 0 mangosd cat "/config/$1"; }
conf_put() { docker compose exec -T -u 0 mangosd sh -c "cat > /config/$1"; }   # in place: keeps owner and mode
conf_set() {   # conf_set FILE KEY=VALUE...  (replaces an existing or commented-out key, else appends)
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
print("\n".join(text))' "$@" > "$TMP/$f.new"
  [ -s "$TMP/$f.new" ] || { echo "Could not read /config/$f"; exit 1; }
  conf_put "$f" < "$TMP/$f.new"
}
api_allowed() {
  local env=/etc/openvanilla-herald.env
  [ -f "$env" ] || return 0
  if grep -q '^AUTOPILOT_ALLOWED=' "$env"; then sed -i "s/^AUTOPILOT_ALLOWED=.*/AUTOPILOT_ALLOWED=$1/" "$env"
  else printf 'AUTOPILOT_ALLOWED=%s\n' "$1" >> "$env"; fi
  systemctl restart openvanilla-herald-autopilot 2>/dev/null || true
}
case "${1:-status}" in
  on)
    conf_set aiplayerbot.conf AiPlayerbot.SelfBotLevel=2
    api_allowed 1
    docker compose restart mangosd
    echo "Herald is on: players can hand their character over in game (Herald button by the minimap, or .bot self)." ;;
  off)
    conf_set aiplayerbot.conf AiPlayerbot.SelfBotLevel=0
    api_allowed 0
    docker compose restart mangosd
    echo "Herald is off: nobody can hand their character to the bot AI." ;;
  status)
    conf_get aiplayerbot.conf | grep -E '^\s*#?\s*AiPlayerbot\.SelfBotLevel' || echo "SelfBotLevel not set (the core's default: GMs only)"
    grep '^AUTOPILOT_ALLOWED=' /etc/openvanilla-herald.env 2>/dev/null || true ;;
  *) echo "usage: bash herald_selfbot.sh on|off|status"; exit 1 ;;
esac
