#!/usr/bin/env bash
# Open Vanilla Classic+ gameplay settings in the world server's mangosd.conf (PENDING: launch day, with
# realm/mangos/pending 0003/0004). Safe to re-run; the world server reads mangosd.conf at start-up.
#   bash openvanilla_gameplay_conf.sh            apply: the Vanilla Remastered pace (below) + the OpenVanilla.* switches
#                                            (all on except OpenVanilla.StarterPet: hunters tame their first pet at 10, as stock)
#   bash openvanilla_gameplay_conf.sh rollback   stock rates, every OpenVanilla.* switch off
# Pace (rollback value in brackets):
#   Rate.XP.Kill 1.5 [1], Rate.XP.Quest 1.5 [1]         x1.5 XP from kills and from quest turn-ins
#   Rate.Rest.InGame / .Offline.InTavernOrCity 5 [1]     a full rested bar in about 2 days at an inn or capital
#   Rate.Rest.Offline.InWilderness 1.25 [1]              logged out in the wild, as before
#   GM.Chat 1 [2]                                       staff accounts wear the <GM> chat tag from login
#   SkillGain.Weapon 4 [1]                               weapon skill rises 4 points a step: a new weapon type
#                                                        is usable in minutes, not half an hour of misses
#   OpenVanilla.Pace.* (patch 0013, src/game/OpenVanilla/Pace.h): FlightSpeed 2 [1], FlightUnlockStep 10 [0],
#     CampfireRest 1 [0], MentorBonus 0.20 [0], MentorMax 3, ExploreXpPct 1 [0], AbandonReturnsItem 1 [0]
# Switch one feature off later by editing its line (0 = off) and restarting the world server:
#   OpenVanilla.AutoLearn, OpenVanilla.FreeRespec, OpenVanilla.DualSpec, OpenVanilla.StarterPet, OpenVanilla.AoeLoot,
#   OpenVanilla.AoeLoot.Range (yards), OpenVanilla.InstantAccountMail, OpenVanilla.ClosedCombos
set -euo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
MODE=${1:-apply}
cd "$REALM_DIR"
# Setting names: OpenVanilla.* from realm/mangos/0012-openvanilla-names.patch on. An older world server
# image only reads the Open Vanilla.* spelling, so on one of those the old names are written (they keep
# working after the image update too); the next run on the new image switches the lines over.
# Never a stop: a deploy that brings the new image runs this before that image is up.
names_prefix() {  # names_prefix COMPOSE_DIR -> OpenVanilla or Open Vanilla
  local cid labels
  cid=$(cd "$1" && docker compose ps -aq mangosd 2>/dev/null | head -1)
  labels=$( [ -n "$cid" ] && docker inspect -f '{{ index .Config.Labels "dev.openvanilla.patches" }}' "$cid" 2>/dev/null || true)
  case "$labels" in *openvanilla-names*) echo OpenVanilla ;; *) echo Open Vanilla ;; esac
}
PROJECT=${COMPOSE_PROJECT_NAME:-$(basename "$REALM_DIR")}
P=$(names_prefix "$REALM_DIR")
[ "$P" = OpenVanilla ] || echo "(this world server image predates the OpenVanilla.* names: writing Open Vanilla.* lines for now)"
CFGVOL=$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.volume=config" | head -1)
[ -n "$CFGVOL" ] || { echo "No config volume found for $PROJECT"; exit 1; }
if [ "$MODE" = rollback ]; then INN=1; WILD=1; QXP=1; KXP=1; WSKILL=1; ON=0
  FLY=1; FSTEP=0; CAMP=0; MENTOR=0; EXPLORE=0; ABANDON=0; GMCHAT=2
else INN=5; WILD=1.25; QXP=1.5; KXP=1.5; WSKILL=4; ON=1
  FLY=2; FSTEP=10; CAMP=1; MENTOR=0.20; EXPLORE=1; ABANDON=1; GMCHAT=1; fi
docker run --rm -e INN="$INN" -e WILD="$WILD" -e QXP="$QXP" -e KXP="$KXP" -e WSKILL="$WSKILL" -e ON="$ON" -e P="$P" \
  -e FLY="$FLY" -e FSTEP="$FSTEP" -e CAMP="$CAMP" -e MENTOR="$MENTOR" -e EXPLORE="$EXPLORE" -e ABANDON="$ABANDON" -e GMCHAT="$GMCHAT" -v "$CFGVOL":/config debian:bookworm-slim sh -c '
  set -e; f=/config/mangosd.conf
  [ -f "$f.openvanilla-orig" ] || cp "$f" "$f.openvanilla-orig"
  for k in Rate.Rest.InGame Rate.Rest.Offline.InTavernOrCity; do
    sed -i "s/^$k *=.*/$k = $INN/" "$f"
  done
  sed -i "s/^Rate.Rest.Offline.InWilderness *=.*/Rate.Rest.Offline.InWilderness = $WILD/" "$f"
  [ "$P" = OpenVanilla ] && sed -i "s/^OpenWoW\./OpenVanilla./" "$f"   # older lines, under the new spelling
  setkey() { if grep -q "^$1 *=" "$f"; then sed -i "s/^$1 *=.*/$1 = $2/" "$f"; else
    grep -q "^# Open Vanilla Classic+ gameplay" "$f" || printf "\n# Open Vanilla Classic+ gameplay (realm/classicplus/pending/openvanilla_gameplay_conf.sh)\n" >> "$f"
    printf "%s = %s\n" "$1" "$2" >> "$f"; fi; }
  for k in AutoLearn FreeRespec DualSpec AoeLoot InstantAccountMail ClosedCombos; do
    setkey "$P.$k" "$ON"
  done
  # Above QUEUE_WORLD of the login queue (80, hetzner/openvanilla_realm_up.sh): the queue is the gate, not mangosd.
  setkey PlayerLimit 100
  # Off in both modes, and written out: the server defaults it to on when the line is missing.
  setkey "$P.StarterPet" 0
  setkey "$P.AoeLoot.Range" 30
  # the pace: XP rates, weapon skill, and patch 0013 (only that image reads the Pace keys)
  setkey Rate.XP.Kill "$KXP"
  setkey Rate.XP.Quest "$QXP"
  setkey SkillGain.Weapon "$WSKILL"
  setkey OpenVanilla.Pace.FlightSpeed "$FLY"
  setkey OpenVanilla.Pace.FlightUnlockStep "$FSTEP"
  setkey OpenVanilla.Pace.CampfireRest "$CAMP"
  setkey OpenVanilla.Pace.MentorBonus "$MENTOR"
  setkey OpenVanilla.Pace.MentorMax 3
  setkey OpenVanilla.Pace.ExploreXpPct "$EXPLORE"
  setkey OpenVanilla.Pace.AbandonReturnsItem "$ABANDON"
  # Staff wear the GM chat tag from login (shown as a blue <GM> by the Chat addon); stock: the last state.
  setkey GM.Chat "$GMCHAT"
  grep -E "^(Rate\.(Rest|XP\.(Kill|Quest))|SkillGain\.Weapon|GM\.Chat |OpenVanilla\.)" "$f"'
# A quiet World channel: the random bots' broadcasts (level ups, loot, quests, small talk) off in
# aiplayerbot.conf. The World channel also drops random bots' lines itself (mangos patch 0019,
# OpenVanilla.WorldChannel.BotChatter = 1 lets them back). Rollback turns the broadcasts back on.
if [ "$MODE" = rollback ]; then BC=1; else BC=0; fi
docker run --rm -e BC="$BC" -v "$CFGVOL":/config debian:bookworm-slim sh -c '
  f=/config/aiplayerbot.conf
  [ -f "$f" ] || { echo "(no aiplayerbot.conf yet: bot broadcasts left as they are)"; exit 0; }
  setkey() { if grep -q "^$1 *=" "$f"; then sed -i "s/^$1 *=.*/$1 = $2/" "$f"; else printf "%s = %s\n" "$1" "$2" >> "$f"; fi; }
  setkey AiPlayerbot.EnableBroadcasts "$BC"
  setkey AiPlayerbot.RandomBotSayWithoutMaster 0
  grep -E "^AiPlayerbot\.(EnableBroadcasts|RandomBotSayWithoutMaster)" "$f"'
echo "mangosd.conf updated ($MODE); restart the world server to apply."
