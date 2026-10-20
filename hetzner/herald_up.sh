#!/usr/bin/env bash
# Open Vanilla Herald (Discord bot) as an always-on service on the realm server.
#   curl -fsSL https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable/hetzner/herald_up.sh -o herald_up.sh
#   bash herald_up.sh
# Asks for the bot token and server ID once (stored root-only in /etc/openvanilla-herald.env).
# Re-run any time to update the bot to the latest version on GitHub.
# Herald needs the SERVER MEMBERS INTENT: Developer Portal -> your app -> Bot -> Privileged Gateway Intents.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
DIR=/opt/openvanilla-herald
RAW=https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable
apt-get install -y python3-venv >/dev/null
id herald >/dev/null 2>&1 || useradd --system --home "$DIR" --shell /usr/sbin/nologin herald
mkdir -p "$DIR/public"   # feed.json for the website (served by the realm's Caddy at /community/)
curl -fsSL "$RAW/bot/herald.py" -o "$DIR/herald.py"
curl -fsSL "$RAW/bot/herald_support.py" -o "$DIR/herald_support.py"
curl -fsSL "$RAW/bot/herald_mod.py" -o "$DIR/herald_mod.py"
curl -fsSL "$RAW/bot/herald_streams.py" -o "$DIR/herald_streams.py"
curl -fsSL "$RAW/bot/herald_bridge.py" -o "$DIR/herald_bridge.py"
curl -fsSL "$RAW/bot/herald_bugs.py" -o "$DIR/herald_bugs.py"       # the bug desk (#bug-reports)
curl -fsSL "$RAW/bot/herald_quiet.py" -o "$DIR/herald_quiet.py"
curl -fsSL "$RAW/bot/herald_art.py" -o "$DIR/herald_art.py"
curl -fsSL "$RAW/bot/herald_autopilot_api.py" -o "$DIR/herald_autopilot_api.py"   # Herald Autopilot + learning
# the Discord images: herald_art.py keeps them current from ART_URL by itself after this
mkdir -p "$DIR/discord_assets/banners"
curl -fsSL "$RAW/bot/discord_assets/manifest.json" -o "$DIR/discord_assets/manifest.json" || true
curl -fsSL "$RAW/www/mod.html" -o "$DIR/mod.html" || true
[ -x "$DIR/venv/bin/python" ] || python3 -m venv "$DIR/venv"
"$DIR/venv/bin/pip" install --quiet --upgrade "discord.py>=2.3" "pymysql>=1.0" "aiohttp>=3.8"
chown -R herald:herald "$DIR"
if [ ! -s /etc/openvanilla-herald.env ]; then
  read -rsp "Bot token (hidden): " TOKEN; echo
  read -rp  "Discord server ID: " GID
  umask 077
  printf 'DISCORD_BOT_TOKEN=%s\nDISCORD_GUILD_ID=%s\nHERALD_DB=%s/herald.db\n' "$TOKEN" "$GID" "$DIR" > /etc/openvanilla-herald.env
fi
# Settings added since the first install (kept if already there). SIGNUP_MODE follows the realm's.
addenv() { grep -q "^$1=" /etc/openvanilla-herald.env || printf '%s=%s\n' "$1" "$2" >> /etc/openvanilla-herald.env; }
REALM_ENV=/opt/wenilla-realm/.env
REALM_MODE=$( [ -f "$REALM_ENV" ] && sed -n 's/^SIGNUP_MODE=//p' "$REALM_ENV" | tail -1 )
REALM_INVITE=$( [ -f "$REALM_ENV" ] && sed -n 's/^DISCORD_INVITE_URL=//p' "$REALM_ENV" | tail -1 )
addenv HERALD_PUBLIC_DIR "$DIR/public"
addenv SIGNUP_MODE "${REALM_MODE:-open}"
[ -n "$REALM_INVITE" ] && addenv DISCORD_INVITE_URL "$REALM_INVITE"
if [ -n "$REALM_MODE" ] && ! grep -q "^SIGNUP_MODE=$REALM_MODE$" /etc/openvanilla-herald.env; then
  sed -i "s/^SIGNUP_MODE=.*/SIGNUP_MODE=$REALM_MODE/" /etc/openvanilla-herald.env
fi
# ---- The support desk (herald_support.py): in-game tickets, read from the realm's database and fixed
# through the world server's console. Both stay on this machine: two tiny relays publish them on
# 127.0.0.1 only. Herald gets its own database login (read, plus closing tickets) and its own GM
# console account, HELPDESK, with random passwords kept in /etc/openvanilla-herald.env.
REALM=/opt/wenilla-realm
if [ -d "$REALM" ] && docker info >/dev/null 2>&1; then
  (
    cd "$REALM"
    set -a; . ./.env; set +a
    sql() { MYSQL_PWD="$DB_ROOT_PASSWORD" docker compose exec -T -e MYSQL_PWD mariadb mariadb -uroot -N "$@"; }
    NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(docker compose ps -q mariadb)" | awk '{print $1}')
    for pair in "13306 mariadb 3306" "17878 mangosd 7878"; do
      set -- $pair
      docker rm -f "openvanilla-support-$2" >/dev/null 2>&1 || true
      docker run -d --name "openvanilla-support-$2" --restart unless-stopped --network "$NET" -p "127.0.0.1:$1:$3" \
        alpine/socat "tcp-listen:$3,fork,reuseaddr" "tcp-connect:$2:$3" >/dev/null
    done
    if ! grep -q '^SUPPORT_DB_PASS=' /etc/openvanilla-herald.env; then
      DBP=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
      SOAPP=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)
      sql -e "CREATE USER IF NOT EXISTS 'herald'@'%' IDENTIFIED BY '$DBP'; ALTER USER 'herald'@'%' IDENTIFIED BY '$DBP';
              GRANT SELECT ON classiccharacters.* TO 'herald'@'%';"
      for t in gm_tickets character_ticket; do
        [ "$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='classiccharacters' AND table_name='$t'")" = 1 ] &&
          sql -e "GRANT UPDATE, DELETE ON classiccharacters.$t TO 'herald'@'%';"
      done
      read -r S V < <(python3 - "$SOAPP" <<'PY'
import hashlib, os, sys
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
salt = os.urandom(32)
h1 = hashlib.sha1(f"HELPDESK:{sys.argv[1].upper()}".encode()).digest()
x = int.from_bytes(hashlib.sha1(salt[::-1] + h1).digest(), "little")
print(salt.hex().upper(), pow(7, x, N).to_bytes(32, "big").hex().upper())
PY
)
      sql classicrealmd -e "INSERT INTO account (username, gmlevel, v, s) VALUES ('HELPDESK', 3, '$V', '$S')
                            ON DUPLICATE KEY UPDATE gmlevel = 3, v = VALUES(v), s = VALUES(s)"
      printf 'SUPPORT_DB_HOST=127.0.0.1\nSUPPORT_DB_PORT=13306\nSUPPORT_DB_USER=herald\nSUPPORT_DB_PASS=%s\nCHARACTERS_DATABASE=classiccharacters\nSOAP_URL=http://127.0.0.1:17878/\nSOAP_USER=HELPDESK\nSOAP_PASS=%s\n' \
        "$DBP" "$SOAPP" >> /etc/openvanilla-herald.env
      echo "Support desk: database login and HELPDESK console account made."
    fi
    # Herald Autopilot lists a signed-in player's characters: account id and name only.
    sql -e "GRANT SELECT (id, username) ON classicrealmd.account TO 'herald'@'%';" 2>/dev/null || true
    # Moderation desk (herald_mod.py): reports, appeals and the spam filter's log, once their tables exist
    # (realm/classicplus/pending/classicplus_reports.sql). Re-run this script after adding them.
    if [ "$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='classiccharacters' AND table_name='openvanilla_report'")" = 1 ]; then
      sql -e "GRANT SELECT, UPDATE, DELETE ON classiccharacters.openvanilla_report TO 'herald'@'%';
              GRANT SELECT, UPDATE ON classiccharacters.openvanilla_appeal TO 'herald'@'%';
              GRANT SELECT ON classiccharacters.openvanilla_mod_log TO 'herald'@'%';
              GRANT SELECT ON classiccharacters.openvanilla_mod_note TO 'herald'@'%';" && echo "Moderation desk: report tables granted."
    fi
    # Bug desk (herald_bugs.py): reports from the game's bug button, once realm/classicplus/classicplus_bugs.sql has run.
    if [ "$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='classiccharacters' AND table_name='openvanilla_bug_report'")" = 1 ]; then
      sql -e "GRANT SELECT, UPDATE ON classiccharacters.openvanilla_bug_report TO 'herald'@'%';" && echo "Bug desk: bug report table granted."
    fi
    # World bridge (herald_bridge.py, docs/DISCORD_BRIDGE.md): guild links, once
    # realm/classicplus/pending/classicplus_world.sql has run (the World log itself is covered by SELECT above).
    if [ "$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='classiccharacters' AND table_name='openvanilla_guild_bridge'")" = 1 ]; then
      sql -e "GRANT SELECT, INSERT, UPDATE, DELETE ON classiccharacters.openvanilla_guild_bridge TO 'herald'@'%';
              GRANT SELECT, DELETE ON classiccharacters.openvanilla_guild_link_code TO 'herald'@'%';" && echo "World bridge: guild link tables granted."
    fi
  )
else
  echo "Support desk: no realm at $REALM (or no Docker); in-game tickets stay off."
fi
if ! grep -q '^OWNER_DISCORD_ID=' /etc/openvanilla-herald.env && [ -t 0 ]; then
  read -rp "Your Discord user ID (approvals and ticket DMs; Enter to skip): " OWNER
  [ -n "$OWNER" ] && printf 'OWNER_DISCORD_ID=%s\n' "$OWNER" >> /etc/openvanilla-herald.env
fi
addenv SUPPORT_CHANNEL support-queue
addenv SUPPORT_DM_OWNER 1
addenv OWNER_APPROVAL talents
addenv AUTO_UNSTUCK 0
addenv MOD_CHANNEL moderation
addenv ART_DIR "$DIR/discord_assets"
addenv ART_URL "$RAW/bot"
addenv ART_POLL_SEC 300
addenv MOD_AUTO 1
# Herald Autopilot's realm side (bot/herald_autopilot_api.py): learning from opted-in players, and the
# autopilot API. Autoplay stays OFF until AUTOPILOT_ALLOWED=1 (it needs the .wnl autopilot command).
REALM_DOMAIN=$( [ -f "$REALM_ENV" ] && sed -n 's/^REALM_DOMAIN=//p' "$REALM_ENV" | tail -1 )
DOCKER_IP=$(ip -4 addr show docker0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
addenv AUTOPILOT_ALLOWED 0
addenv AUTOPILOT_HOST "${DOCKER_IP:-127.0.0.1}"
addenv AUTOPILOT_PORT 17890
addenv HERALD_LEARN_DB "$DIR/herald_learn.db"
[ -n "$REALM_DOMAIN" ] && addenv PORTAL_URL "https://$REALM_DOMAIN"
addenv MOD_DASH_PORT 8787
addenv MOD_HTML "$DIR/mod.html"
if ! grep -q '^MOD_STAFF_TOKENS=' /etc/openvanilla-herald.env; then
  # one staff token for the web dashboard (/mod/); add more as Name:token,Name2:token2
  printf 'MOD_STAFF_TOKENS=owner:%s\n' "$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)" >> /etc/openvanilla-herald.env
  echo "Moderation dashboard token: see MOD_STAFF_TOKENS in /etc/openvanilla-herald.env"
fi
chmod 600 /etc/openvanilla-herald.env
cat > /etc/systemd/system/openvanilla-herald.service <<UNIT
[Unit]
Description=Open Vanilla Herald Discord bot
After=network-online.target
Wants=network-online.target
[Service]
User=herald
EnvironmentFile=/etc/openvanilla-herald.env
WorkingDirectory=$DIR
ExecStart=$DIR/venv/bin/python $DIR/herald.py
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$DIR
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/openvanilla-herald-autopilot.service <<UNIT
[Unit]
Description=Open Vanilla Herald Autopilot API and learning
After=network-online.target docker.service
Wants=network-online.target
[Service]
User=herald
EnvironmentFile=/etc/openvanilla-herald.env
WorkingDirectory=$DIR
ExecStart=$DIR/venv/bin/python $DIR/herald_autopilot_api.py
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$DIR
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now openvanilla-herald
systemctl restart openvanilla-herald
systemctl enable --now openvanilla-herald-autopilot
systemctl restart openvanilla-herald-autopilot
sleep 5; systemctl --no-pager --lines=5 status openvanilla-herald || true
echo "Herald is running. Logs: journalctl -u openvanilla-herald -f"
echo "Herald Autopilot API: journalctl -u openvanilla-herald-autopilot -f  (re-run openvanilla_realm_up.sh once so the site routes /api/autopilot and /api/herald to it)"
echo "If it keeps restarting with 'Server Members Intent': turn that on in the Developer Portal (Bot page)."
