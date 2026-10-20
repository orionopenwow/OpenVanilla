#!/usr/bin/env bash
# Open Vanilla GM tool: the realm's console from the server, for running the alpha day to day.
# Run as root on the realm server. It talks to the world server's console (SOAP) as the HELPDESK
# account that herald_up.sh sets up (/etc/openvanilla-herald.env), and reads the database for counts.
#
#   bash ov_gm.sh online                     who is in the world (count and names)
#   bash ov_gm.sh say "text"                 a server announcement in everyone's chat
#   bash ov_gm.sh notify "text"              the same, in the middle of everyone's screen
#   bash ov_gm.sh warn [minutes] [reason]    the restart countdown in chat and on screen: 5, 4, 3, 2, 1
#                                            minutes, 30 and 10 seconds (default 5 minutes). Returns
#                                            when it ends; skipped at once when nobody is online
#   bash ov_gm.sh restart [minutes] [reason] the countdown, then a plain restart of the realm service and
#                                            the world server (every character is saved), then waits
#                                            until the world is back (Server.bat option 2)
#   bash ov_gm.sh cancel                     stop a countdown running in another window
#   bash ov_gm.sh cmd ".any gm command"      any console command, e.g. ".kick Name" or ".server info"
#   bash ov_gm.sh make-admin "Discord name or ID" [level]
#                                            the game account made by that Discord sign-in gets GM
#                                            level 3 (admin; 1 moderator, 2 game master, 0 = back to a
#                                            player). Sign in with Discord once first.
#   bash ov_gm.sh menu                       all of the above as a menu (Server.bat option 9)
#
# The update (openvanilla_realm_up.sh, Server.bat 1) runs "warn" before it disconnects anyone;
# OW_WARN_MIN=0 skips it, OW_WARN_MIN=10 gives ten minutes.
set -uo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
ENVF=/etc/openvanilla-herald.env
CANCEL=/run/ov_gm.cancel

conf() { sed -n "s/^$1=//p" "$ENVF" 2>/dev/null | tail -1; }
SOAP_URL=$(conf SOAP_URL); SOAP_URL=${SOAP_URL:-http://127.0.0.1:17878/}
SOAP_USER=$(conf SOAP_USER); SOAP_PASS=$(conf SOAP_PASS)

console() {   # console ".command" -> the console's answer (exit 1 when the world server refuses or is down)
  [ -n "$SOAP_USER" ] && [ -n "$SOAP_PASS" ] || { echo "No SOAP login in $ENVF: run herald_up.sh once" >&2; return 1; }
  local cmd; cmd=$(printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
  local body='<?xml version="1.0" encoding="utf-8"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:MaNGOS"><SOAP-ENV:Body><ns1:executeCommand><command>'"$cmd"'</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>'
  local out
  # the login goes in on stdin (curl -K -), never on the command line where ps would show it
  out=$(printf 'user = "%s:%s"\n' "$SOAP_USER" "$SOAP_PASS" | curl -s -m 10 -K - -H 'Content-Type: text/xml' --data-binary "$body" "$SOAP_URL") || return 1
  if printf '%s' "$out" | grep -q '<faultstring>'; then
    printf '%s\n' "$out" | sed -n 's:.*<faultstring>\(.*\)</faultstring>.*:\1:p' >&2; return 1
  fi
  printf '%s\n' "$out" | sed -n 's:.*<result>\(.*\)</result>.*:\1:p' | sed 's/&#xD;//g'
}

players() {   # number of real players in the world (random bots don't count); "?" when the database can't be read
  local n
  n=$( cd "$REALM_DIR" 2>/dev/null && set -a && . ./.env && set +a &&
    MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N classiccharacters \
      -e "SELECT COUNT(*) FROM characters c JOIN classicrealmd.account a ON a.id = c.account
          WHERE c.online = 1 AND a.username NOT LIKE 'RNDBOT%'" 2>/dev/null | tr -dc 0-9 )
  echo "${n:-?}"
}

discord_account() {   # discord_account NAME -> "WR000123<TAB>Discord name" lines for that Discord sign-in
  local tmp; tmp=$(mktemp -d)
  ( cd "$REALM_DIR" || exit 1
    st=$(docker compose exec -T realm printenv REALM_STATE_DIR 2>/dev/null | tr -d '\r'); st=${st:-/state}
    for f in realm.sqlite realm.sqlite-wal realm.sqlite-shm; do docker compose cp "realm:$st/$f" "$tmp/$f" >/dev/null 2>&1; done )
  python3 - "$tmp/realm.sqlite" "$1" <<'PY'
import sqlite3, sys
db, who = sys.argv[1], sys.argv[2].strip().lstrip("@").lower()
try:
    con = sqlite3.connect(db)
    rows = con.execute(
        "SELECT g.game_username, COALESCE(i.display_name, u.display_name), u.username, i.subject "
        "FROM identities i JOIN users u ON u.id = i.user_id JOIN game_accounts g ON g.user_id = u.id "
        "WHERE i.provider = 'discord'").fetchall()
except Exception:
    rows = []
for acc, shown, user, sub in rows:
    if who in (str(shown or "").lower(), str(user or "").lower(), str(sub)):
        print(f"{acc}\t{shown}\t{user}\t{sub}")
PY
  rm -rf "$tmp"
}

tell() { console ".announce $1" >/dev/null; console ".notify $1" >/dev/null; echo "  [$(date +%H:%M:%S)] $1"; }

countdown() {   # countdown MINUTES REASON
  local min=${1:-5} why=${2:-an update}
  rm -f "$CANCEL"
  local n; n=$(players)
  if [ "$n" = 0 ]; then echo "Nobody is online: no countdown needed."; return 0; fi
  # "?" (the count couldn't be read): count down anyway rather than restart on people unwarned
  echo "Countdown: $min minute(s), $n player(s) online. 'bash ov_gm.sh cancel' stops it."
  local left=$((min * 60))
  # the marks it speaks at, in seconds left
  for mark in 600 300 240 180 120 60 30 10; do
    [ "$mark" -le "$left" ] || continue
    while [ "$left" -gt "$mark" ]; do
      [ -e "$CANCEL" ] && { tell "The restart is called off. Play on!"; rm -f "$CANCEL"; return 1; }
      sleep 1; left=$((left - 1))
    done
    if [ "$mark" -ge 60 ]; then
      local m=$((mark / 60)); local unit=minutes; [ "$m" = 1 ] && unit=minute
      tell "Realm restart in $m $unit for $why. It takes a minute or two; your progress is saved. Finish your fight and find a safe spot."
    else
      tell "Realm restart in $mark seconds. See you in a minute or two!"
    fi
  done
  while [ "$left" -gt 0 ]; do sleep 1; left=$((left - 1)); done
  tell "Restarting now. Back in a minute or two."
  sleep 3
}

case "${1:-help}" in
  online)
    n=$(players); echo "$n players in the world (random bots not counted)."
    [ "$n" = 0 ] || ( cd "$REALM_DIR" && set -a && . ./.env && set +a &&
      MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N classiccharacters \
        -e "SELECT CONCAT(name, ' (', level, ')') FROM characters WHERE online = 1 ORDER BY name" 2>/dev/null | paste -sd, - ) ;;
  say)    [ -n "${2:-}" ] || { echo 'usage: ov_gm.sh say "text"'; exit 1; }; console ".announce $2" && echo "Announced." ;;
  notify) [ -n "${2:-}" ] || { echo 'usage: ov_gm.sh notify "text"'; exit 1; }; console ".notify $2" && echo "Shown." ;;
  warn)   countdown "${2:-5}" "${3:-an update}" ;;
  restart)
    countdown "${2:-5}" "${3:-a quick restart}" || exit 1
    cd "$REALM_DIR" || exit 1
    docker compose restart -t 120 realm mangosd
    for i in $(seq 1 60); do
      s=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q mangosd)" 2>/dev/null || echo starting)
      [ "$s" = healthy ] && break; sleep 10
    done
    echo "world server: $s" ;;
  make-admin)
    who=${2:-}; lvl=${3:-3}
    [ -n "$who" ] || read -rp "  Your Discord name (as Discord shows it): " who
    [ -n "$who" ] || exit 1
    case "$lvl" in 0|1|2|3) ;; *) echo "The level is 0 (player), 1 (moderator), 2 (game master) or 3 (admin)."; exit 1 ;; esac
    found=$(discord_account "$who")
    if [ -z "$found" ]; then
      echo "No game account for the Discord name '$who' yet. Sign in once at https://play.openvanilla.app with"
      echo "'Sign in with Discord' (and press Play so the game account is made), then run this again."
      exit 1
    fi
    if [ "$(printf '%s\n' "$found" | wc -l)" -gt 1 ]; then
      echo "More than one account matches '$who':"; printf '  %s\n' "$found"; echo "Run it again with the account name, e.g. .account set gmlevel WR000123 3"; exit 1
    fi
    acc=$(printf '%s' "$found" | cut -f1); sub=$(printf '%s' "$found" | cut -f4)
    # Discord display names aren't unique (anyone can call themselves "Orion"): unless the Discord ID
    # itself was given, show who it is and ask before handing out GM powers
    if [ "$who" != "$sub" ] && [ "$lvl" != 0 ]; then
      echo "  Found: $(printf '%s' "$found" | cut -f2) (username $(printf '%s' "$found" | cut -f3), Discord ID $sub, game account $acc)."
      echo "  Check the Discord ID: in Discord, Settings > Advanced > Developer Mode, then right-click your name > Copy User ID."
      read -rp "  Is this you? Type yes to make it GM level $lvl: " ok
      [ "$ok" = yes ] || { echo "Nothing changed."; exit 1; }
    fi
    console ".account set gmlevel $acc $lvl" && echo "$(printf '%s' "$found" | cut -f2) ($acc) is now GM level $lvl. Log out of the game and back in; then .gm on when you help, .gm off when you play." ;;
  cancel) touch "$CANCEL"; echo "The countdown stops within a second." ;;
  cmd)    [ -n "${2:-}" ] || { echo 'usage: ov_gm.sh cmd ".command"'; exit 1; }; console "$2" ;;
  menu)
    while true; do
      printf '\n  Open Vanilla GM tools\n  ---------------------------------------------\n'
      printf '   1  Who is online\n   2  Announce in everyone'"'"'s chat\n   3  Message in the middle of everyone'"'"'s screen\n'
      printf '   4  Restart the realm with a countdown\n   5  Cancel a countdown (from another window)\n'
      printf '   6  Kick a player\n   7  Mute a player\n   8  Server info (uptime, players)\n   9  Any GM command\n'
      printf '  10  Make a Discord account a GM (admin, moderator, or back to player)\n   0  Back\n\n'
      read -rp "  Choose: " c
      case "$c" in
        1) bash "$0" online ;;
        2) read -rp "  Text: " t; [ -n "$t" ] && bash "$0" say "$t" ;;
        3) read -rp "  Text: " t; [ -n "$t" ] && bash "$0" notify "$t" ;;
        4) read -rp "  Minutes [5]: " m; read -rp "  Why (players see it) [a quick restart]: " w
           bash "$0" restart "${m:-5}" "${w:-a quick restart}" ;;
        5) bash "$0" cancel ;;
        6) read -rp "  Character name: " n; [ -n "$n" ] && console ".kick $n" ;;
        7) read -rp "  Character name: " n; read -rp "  Minutes: " m; [ -n "$n" ] && [ -n "$m" ] && console ".mute $n $m" ;;
        8) console ".server info" ;;
        9) read -rp "  Command (starts with a dot): " t; [ -n "$t" ] && console "$t" ;;
        10) read -rp "  Discord name: " n; read -rp "  Level, 3 admin / 2 game master / 1 moderator / 0 player [3]: " l
            [ -n "$n" ] && bash "$0" make-admin "$n" "${l:-3}" ;;
        0|q|"") exit 0 ;;
      esac
    done ;;
  *) sed -n '2,/^set /p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' ;;
esac
