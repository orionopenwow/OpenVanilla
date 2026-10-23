#!/usr/bin/env bash
# Open Vanilla: Discord off (or back on). Run as root on the realm server.
#
#   bash discord_off.sh            Discord off: no "Sign in with Discord" on the realm (guest, Google and
#                                  password sign-in stay, and so does the launcher's sign-in through the
#                                  website), and Herald's Discord bot stopped (no gate, no #world bridge,
#                                  no ticket cards, no bug posts). The realm service restarts: browser
#                                  players reconnect in a few seconds (a 2-minute warning first; OW_WARN_MIN=0
#                                  skips it). Nothing is deleted; every Discord setting stays in .env.
#   bash discord_off.sh on         back on: Discord sign-in and the bot (when Discord has cleared the app)
#   bash discord_off.sh status     what is on
#
# While it is off, openvanilla_realm_up.sh and herald_up.sh keep it off (DISCORD_SIGNIN=off in the realm's
# .env, and /etc/openvanilla-discord-off). Herald Autopilot (the in-game bot) is not touched.
# In-game bug reports and GM tickets are still stored: the GM console shows them (Server.bat option G).
set -uo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
FLAG=/etc/openvanilla-discord-off
CP=${CP:-/root}
cd "$REALM_DIR" || { echo "No realm at $REALM_DIR"; exit 1; }
[ -f .env ] || { echo "No .env in $REALM_DIR"; exit 1; }

setenv() {  # setenv KEY VALUE -> .env (replace or append), never echoed
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi
}
compose_ids() {  # compose_ids off|on: the realm service's Discord app id and secret, blank or from .env
  [ -f compose.override.yaml ] || { echo "No compose.override.yaml: run openvanilla_realm_up.sh once first."; return 1; }
  cp compose.override.yaml "compose.override.yaml.bak.$(date +%s)"
  if [ "$1" = off ]; then
    sed -i -E 's|^( +DISCORD_CLIENT_ID:).*|\1 ""   # Discord sign-in off (discord_off.sh)|;
               s|^( +DISCORD_CLIENT_SECRET:).*|\1 ""|' compose.override.yaml
  else
    sed -i -E 's|^( +DISCORD_CLIENT_ID:).*|\1 ${DISCORD_CLIENT_ID:-}|;
               s|^( +DISCORD_CLIENT_SECRET:).*|\1 ${DISCORD_CLIENT_SECRET:-}|' compose.override.yaml
  fi
}
restart_realm() {
  if [ "${OW_WARN_MIN:-2}" != 0 ] && [ -f "$CP/ov_gm.sh" ]; then
    OW_REALM_DIR="$REALM_DIR" bash "$CP/ov_gm.sh" warn "${OW_WARN_MIN:-2}" "a quick sign-in change" \
      || { echo "Called off: nothing restarted (the setting is saved; run this again to apply it)."; exit 1; }
  fi
  docker compose up -d realm >/dev/null && echo "Realm service restarted."
}
status() {
  local ids=""
  local cid
  cid=$(docker compose ps -q realm 2>/dev/null | head -1)
  [ -n "$cid" ] && ids=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" |
    grep -q '^DISCORD_CLIENT_ID=.' && echo on || echo off)
  echo "Discord sign-in on the realm: ${ids:-unknown (realm service down?)}"
  echo "DISCORD_SIGNIN in .env:       $(sed -n 's/^DISCORD_SIGNIN=//p' .env | tail -1 | grep . || echo on)"
  echo "Herald Discord bot:           $(systemctl is-active openvanilla-herald 2>/dev/null) ($(systemctl is-enabled openvanilla-herald 2>/dev/null))"
  echo "Kept off by flag:             $([ -e $FLAG ] && echo yes || echo no)"
}

# The current Discord invite (the realm's Join our Discord button and footer): set on every run.
setenv DISCORD_INVITE_URL "${OV_DISCORD_INVITE:-https://discord.gg/hVeUxYwbkr}"

case "${1:-off}" in
  off)
    setenv DISCORD_SIGNIN off
    touch "$FLAG"
    systemctl disable --now openvanilla-herald 2>/dev/null && echo "Herald's Discord bot stopped (and won't start at boot)."
    compose_ids off || exit 1
    restart_realm
    status ;;
  on)
    setenv DISCORD_SIGNIN on
    rm -f "$FLAG"
    compose_ids on || exit 1
    restart_realm
    systemctl enable --now openvanilla-herald 2>/dev/null && echo "Herald's Discord bot started."
    status ;;
  status) status ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
