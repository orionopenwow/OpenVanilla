#!/usr/bin/env bash
# Open Vanilla: Discord sign-in doctor. Run as root on the realm server (Hetzner):
#
#   bash discord_doctor.sh          check the Discord settings, restart Herald, smoke-test
#                                   "Sign in with Discord", list every Discord-linked account
#   bash discord_doctor.sh --mint   the same, then give every Discord-linked account the
#                                   Adventurer role (Herald sees it and records the account)
#
# It never prints a token or secret, only whether each one works.
set -uo pipefail
REALM=${REALM:-/opt/wenilla-realm}
HENV=/etc/openvanilla-herald.env
API=https://discord.com/api/v10
MINT=0; [ "${1:-}" = "--mint" ] && MINT=1
FAILS=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

cd "$REALM" 2>/dev/null || { echo "No realm at $REALM"; exit 1; }
set -a; . ./.env; set +a

# GET/PUT on the Discord API as the bot; prints "<http code> <body>" (token passed on stdin, not argv)
bot() {  # bot METHOD PATH
  printf 'Authorization: Bot %s\n' "$DISCORD_BOT_TOKEN" |
    curl -s -m 15 -X "$1" -H @- -H 'Content-Length: 0' -w '\n%{http_code}' "$API$2" |
    python3 -c 'import sys; b=sys.stdin.read().rsplit("\n",1); print(b[-1], b[0] if len(b)>1 else "")'
}
js() { python3 -c "import sys,json; d=json.loads(sys.stdin.read() or 'null'); $1"; }

say "1/6  Discord settings in $REALM/.env"
for k in DISCORD_CLIENT_ID DISCORD_CLIENT_SECRET DISCORD_GUILD_ID DISCORD_BOT_TOKEN; do
  if [ -n "${!k:-}" ]; then ok "$k is set"; else bad "$k is empty (re-run openvanilla_realm_up.sh, step 4 asks for it)"; fi
done
[ -n "${DISCORD_INVITE_URL:-}" ] && ok "invite: $DISCORD_INVITE_URL" || warn "DISCORD_INVITE_URL is empty"
STARTED=$(docker inspect -f '{{.State.StartedAt}}' "$(docker compose ps -q realm)" 2>/dev/null)
if [ -z "$STARTED" ]; then bad "the realm container is not running (docker compose up -d realm)"
elif [ "$(date -d "$STARTED" +%s)" -lt "$(stat -c %Y .env)" ]; then
  bad ".env changed after the realm started, so it runs on old settings: docker compose up -d --force-recreate realm"
else ok "the realm container started after the last .env change"; fi

say "2/6  Bot token, client secret, server and roles"
read -r CODE BODY <<<"$(bot GET /users/@me)"
BOTID=""
if [ "$CODE" = 200 ]; then
  BOTID=$(echo "$BODY" | js 'print(d["id"])')
  ok "bot token works: $(echo "$BODY" | js 'print(d["username"])')"
  [ "$BOTID" = "${DISCORD_CLIENT_ID:-}" ] && ok "bot and sign-in are the same Discord app" \
    || bad "DISCORD_CLIENT_ID is not this bot's app id ($BOTID): the client id and token come from different apps"
else
  bad "bot token refused (HTTP $CODE): it was reset in the Developer Portal. Put the new one in .env (DISCORD_BOT_TOKEN) and $HENV"
fi
SC=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -u "${DISCORD_CLIENT_ID:-x}:${DISCORD_CLIENT_SECRET:-x}" \
  -d grant_type=client_credentials -d scope=identify "$API/oauth2/token")
[ "$SC" = 200 ] && ok "client secret works" \
  || bad "client secret refused (HTTP $SC): Developer Portal -> OAuth2 -> Reset Secret, then DISCORD_CLIENT_SECRET in .env"

ROLE=${DISCORD_GRANT_ROLE_ID:-}
if [ -n "$BOTID" ] && [ -n "${DISCORD_GUILD_ID:-}" ]; then
  read -r CODE ME <<<"$(bot GET "/guilds/$DISCORD_GUILD_ID/members/$BOTID")"
  read -r RC ROLES <<<"$(bot GET "/guilds/$DISCORD_GUILD_ID/roles")"
  if [ "$CODE" != 200 ] || [ "$RC" != 200 ]; then
    bad "the bot is not in server $DISCORD_GUILD_ID (HTTP $CODE): check DISCORD_GUILD_ID or invite the bot"
  else
    ok "the bot is in the Discord server"
    [ -z "$ROLE" ] && ROLE=$(echo "$ROLES" | js 'print(next((r["id"] for r in d if r["name"].lower()=="adventurer"), ""))')
    printf '%s\n%s\n%s\n' "$ME" "$ROLES" "$ROLE" | python3 -c '
import sys, json
me, roles, grant = json.loads(sys.stdin.readline()), json.loads(sys.stdin.readline()), sys.stdin.readline().strip()
byid = {r["id"]: r for r in roles}
mine = [byid[i] for i in me["roles"] if i in byid]
everyone = next((r for r in roles if r["position"] == 0), None)
perms = int(everyone["permissions"]) if everyone else 0
for r in mine: perms |= int(r["permissions"])
admin = perms & (1 << 3)
def say(okay, text): print(("  \033[32mOK\033[0m    " if okay else "  \033[31mFAIL\033[0m  ") + text)
say(admin or perms & 1, "the bot may add players to the server (Create Invite)")
say(admin or perms & (1 << 28), "the bot may give roles (Manage Roles)")
if grant in byid:
    top = max([r["position"] for r in mine] or [0])
    say(top > byid[grant]["position"], "the bot role is above %s (else Discord refuses to grant it: drag the bot role higher)" % byid[grant]["name"])
else:
    print("  \033[33mWARN\033[0m  no role to grant on sign-in (DISCORD_GRANT_ROLE_ID empty, no Adventurer role)")
' | tee /tmp/ov_doctor_roles.txt
    FAILS=$((FAILS + $(grep -c FAIL /tmp/ov_doctor_roles.txt)))
  fi
fi

PUB=$(docker compose exec -T realm printenv REALM_PUBLIC_URL 2>/dev/null | tr -d '\r'); PUB=${PUB%/}
[ -n "$PUB" ] || PUB="https://${REALM_DOMAIN:-play.openvanilla.app}"
echo "  ..    Developer Portal -> OAuth2 -> Redirects must list exactly: $PUB/auth/discord/callback"

say "3/6  Herald"
if [ -s "$HENV" ]; then
  HT=$(sed -n 's/^DISCORD_BOT_TOKEN=//p' "$HENV" | tail -1)
  if [ "$HT" = "${DISCORD_BOT_TOKEN:-}" ]; then ok "Herald uses the same bot token as the realm"
  else bad "Herald's bot token differs from the realm's: put the working one in $HENV (DISCORD_BOT_TOKEN=...)"; fi
else bad "$HENV is missing: run herald_up.sh"; fi
systemctl restart openvanilla-herald 2>/dev/null; systemctl restart openvanilla-herald-autopilot 2>/dev/null
sleep 8
if systemctl is-active --quiet openvanilla-herald; then ok "Herald restarted and running"
else bad "Herald did not stay up:"; journalctl -u openvanilla-herald -n 12 --no-pager | sed 's/^/        /'; fi
journalctl -u openvanilla-herald --since "-1min" --no-pager 2>/dev/null | grep -iE "logged in|ready|error|traceback" | tail -4 | sed 's/^/        /'

say "4/6  Sign-in smoke test ($PUB)"
H=$(curl -s -m 15 -o /dev/null -D - "$PUB/auth/discord/start")
LOC=$(printf '%s' "$H" | sed -n 's/^[Ll]ocation: //p' | tr -d '\r')
printf '%s\n%s\n%s\n' "$LOC" "${DISCORD_CLIENT_ID:-}" "$PUB/auth/discord/callback" | python3 -c '
import sys, urllib.parse as u
loc, cid, cb = [sys.stdin.readline().strip() for _ in range(3)]
q = dict(u.parse_qsl(u.urlsplit(loc).query))
def say(okay, text): print(("  \033[32mOK\033[0m    " if okay else "  \033[31mFAIL\033[0m  ") + text)
say("discord.com" in loc, "the sign-in button sends players to Discord" + ("" if loc else " (no redirect: is Discord sign-in on?)"))
if loc:
    say(q.get("client_id") == cid, "with this app id")
    say(q.get("redirect_uri") == cb, "and comes back to " + q.get("redirect_uri", "?"))
' | tee /tmp/ov_doctor_smoke.txt
FAILS=$((FAILS + $(grep -c FAIL /tmp/ov_doctor_smoke.txt)))
CB=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$PUB/auth/discord/callback?code=smoketest&state=smoketest")
[ "${CB:0:1}" != 5 ] && [ "$CB" != 000 ] && ok "a bad callback is turned away cleanly (HTTP $CB)" \
  || bad "the callback page breaks (HTTP $CB): see the realm log below"
LP=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$PUB/login")
[ "$LP" = 200 ] && ok "the sign-in page loads" || bad "the sign-in page answers HTTP $LP"
echo "  ..    Discord problems in the realm log, last 24 h:"
docker compose logs --since 24h realm 2>/dev/null | grep -iE "discord|oauth|provision" | grep -iE "warn|error|fail" | tail -8 | cut -c1-240 | sed 's/^/        /'

say "5/6  Discord-linked accounts and their characters"
STATE=$(docker compose exec -T realm printenv REALM_STATE_DIR 2>/dev/null | tr -d '\r'); STATE=${STATE:-/state}
T=$(mktemp -d)
for f in realm.sqlite realm.sqlite-wal realm.sqlite-shm; do docker compose cp "realm:$STATE/$f" "$T/$f" >/dev/null 2>&1; done
if [ ! -s "$T/realm.sqlite" ]; then bad "could not copy $STATE/realm.sqlite out of the realm container"; else
  python3 - "$T/realm.sqlite" > "$T/links.tsv" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
for sub, name, uid, acct in con.execute(
        "SELECT i.subject, COALESCE(i.display_name, u.display_name), u.id, g.game_username "
        "FROM identities i JOIN users u ON u.id = i.user_id LEFT JOIN game_accounts g ON g.user_id = u.id "
        "WHERE i.provider = 'discord' ORDER BY u.id"):
    print("\t".join([sub, (name or "?").replace("\t", " "), str(uid), acct or ""]))
PY
  sql() { MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N "$@"; }
  NAMES=$(cut -f4 "$T/links.tsv" | grep . | sed "s/.*/'&'/" | paste -sd, -)
  : > "$T/chars.tsv"
  [ -n "$NAMES" ] && sql -e "SELECT a.username, COUNT(c.guid), COALESCE(GROUP_CONCAT(CONCAT(c.name,' ',c.level) ORDER BY c.level DESC SEPARATOR ', '),'')
    FROM classicrealmd.account a LEFT JOIN classiccharacters.characters c ON c.account = a.id
    WHERE a.username IN ($NAMES) GROUP BY a.username" > "$T/chars.tsv" 2>/dev/null
  python3 - "$T/links.tsv" "$T/chars.tsv" <<'PY'
import sys
chars = {}
for line in open(sys.argv[2]):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 2: chars[p[0].upper()] = (int(p[1]), p[2] if len(p) > 2 else "")
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
noacct = sum(1 for r in rows if not r[3]); withc = 0
print("        %-22s %-10s %s" % ("Discord", "Account", "Characters"))
for sub, name, uid, acct in rows:
    n, names = chars.get(acct.upper(), (0, "")) if acct else (0, "")
    withc += n > 0
    print("        %-22s %-10s %s" % (name[:22], acct or "(none yet)", (str(n) + "  " + names)[:90] if acct else "gets an account on first Play"))
print("\n  ..    %d Discord-linked players, %d with characters, %d without a game account yet" % (len(rows), withc, noacct))
PY
fi

say "6/6  Adventurer role for every linked player"
if [ "$MINT" != 1 ]; then
  echo "  ..    skipped (run again with --mint to give each linked player the Adventurer role)"
elif [ -z "$ROLE" ] || [ -z "$BOTID" ] || [ ! -s "$T/links.tsv" ]; then
  bad "can't mint: needs a working bot token, a grant role and the account list above"
else
  G=0; GONE=0; ERR=0
  while IFS=$'\t' read -r sub name uid acct; do
    read -r C _ <<<"$(bot PUT "/guilds/$DISCORD_GUILD_ID/members/$sub/roles/$ROLE")"
    case "$C" in 204) G=$((G + 1));; 404) GONE=$((GONE + 1));; *) ERR=$((ERR + 1)); echo "        $name: HTTP $C";; esac
    sleep 0.4
  done < "$T/links.tsv"
  ok "Adventurer given or confirmed for $G players ($GONE are no longer in the Discord server)"
  [ "$ERR" = 0 ] || bad "$ERR players could not be given the role (see above)"
  echo "  ..    Herald records each one as it sees the role (Adventurer number, the Hall opens)."
fi
rm -rf "$T"

say "Done: $FAILS problem(s)"
[ "$FAILS" = 0 ] && echo "  Sign in with Discord should work. Try it yourself in a private window." || echo "  Fix the FAIL lines from the top down, then run this again."
