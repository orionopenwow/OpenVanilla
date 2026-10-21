#!/usr/bin/env bash
# Open Vanilla: the realm's playerbots stop talking: no lines in World, General, Trade, LFG, say, yell
# or guild about their loot, kills, quests and level-ups, no canned or AI chatter, no attack emotes.
# They still play, group and answer their master's commands. (Owner, 2026-10-21: "turn off the
# talking playerbots in world chat".)
#   bash bots_quiet.sh          set it and restart the world server (about a minute; anyone online is disconnected)
#   bash bots_quiet.sh status   what the realm has now
# Get it:  curl -fsSL https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable/hetzner/bots_quiet.sh -o bots_quiet.sh
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

# Every broadcast channel at chance 0 (EnableBroadcasts=0 itself trips an urand(1,0) in the bot AI, so
# it stays on and nothing passes), the random bots' canned lines (custom::say) and AI chat off.
QUIET=(
  AiPlayerbot.BroadcastToSayGlobalChance=0 AiPlayerbot.BroadcastToYellGlobalChance=0
  AiPlayerbot.BroadcastToGuildGlobalChance=0 AiPlayerbot.BroadcastToWorldGlobalChance=0
  AiPlayerbot.BroadcastToGeneralGlobalChance=0 AiPlayerbot.BroadcastToTradeGlobalChance=0
  AiPlayerbot.BroadcastToLFGGlobalChance=0 AiPlayerbot.BroadcastToLocalDefenseGlobalChance=0
  AiPlayerbot.BroadcastToWorldDefenseGlobalChance=0 AiPlayerbot.BroadcastToGuildRecruitmentGlobalChance=0
  AiPlayerbot.RandomBotSayWithoutMaster=0 AiPlayerbot.AttackEmoteChance=0 AiPlayerbot.LLMEnabled=0
  "AiPlayerbot.RandomBotCombatStrategies=-threat,-custom::say"
  "AiPlayerbot.RandomBotNonCombatStrategies=-custom::say,-ai chat"
)
case "${1:-on}" in
  on)
    conf_set aiplayerbot.conf "${QUIET[@]}"
    docker compose stop -t 120 mangosd && docker compose up -d mangosd
    echo "The realm's bots are quiet: no World, General, Trade, say, yell or guild chatter." ;;
  status)
    conf_get aiplayerbot.conf | grep -E '^\s*AiPlayerbot\.(Broadcast[A-Za-z]*GlobalChance|RandomBotSayWithoutMaster|AttackEmoteChance|LLMEnabled|RandomBot(Non)?CombatStrategies|MaxRandomBots)\s*=' || echo "none of these set (the bot AI's defaults: they talk)" ;;
  *) echo "usage: bash bots_quiet.sh [on|status]"; exit 1 ;;
esac
