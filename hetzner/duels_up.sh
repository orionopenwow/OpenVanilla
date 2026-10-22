#!/usr/bin/env bash
# Duels: quick 1v1 matches (best of 3, rated or practice) on a realm of their own, next to the live one
# (like Warfront). A Warfront world server with OpenVanilla.Duels = 1 (realm/mangos/0021-openvanilla-duels.patch):
# Warfront's kits, gear picker and enchants with every tier open, the arena's 1v1 modes, guests welcome.
#
#   bash duels_up.sh install [duels.openvanilla.app]   once (~15 min: the world database installs)
#   bash duels_up.sh update                          new Duels/Warfront files, SQL and config; restarts the world server
#   bash duels_up.sh start | stop | status
#   bash duels_up.sh live                            write duels_live.json once (a timer runs it every 20 s)
#   bash duels_up.sh arena                           Gurubashi Arena's map 900 again (dbc, map links, client patch); restart after
#   bash duels_up.sh legend                          sign the duelists' Legends once (a timer runs it every 2 min)
#
# Layout:  /opt/wenilla-duels       the stack (compose project "owduels", its own databases and accounts)
#          /opt/openvanilla-duels   its Open Vanilla files, the Legend signing key (legend/duels.key, mode 600)
# Shared with live, read-only: the extracted maps (linked file by file, plus map 900 = map 0's files);
# the client's base MPQs (hard links).
# The player's path (realm/duels/README.md): DUELS on the site -> https://<duels domain>/?duel=1 -> sign in or
# play as a guest -> straight into the world (realm patch 0035) -> the Lion's Pride Inn, the hangout ->
# queued by itself -> the match in Gurubashi Arena (map 900, mangos patch 0024) -> back to the inn.
# The live Caddy serves it: Caddyfile.site here is appended to the live Caddyfile now, and by the live
# realm_up on every later update (it adds every /opt/openvanilla-*/Caddyfile.site).
# Website: https://<live domain>/community/duels_live.json (live counts, ladder, feed);
#          https://<duels domain>/.well-known/openvanilla-legend.json and /legend/<guid>.json (Legend, legend/SPEC.md).
set -euo pipefail
LIVE=/opt/wenilla-realm
LIVE_CP=/opt/openvanilla-classicplus
S=/opt/wenilla-duels
DCP=/opt/openvanilla-duels
PUB=/opt/openvanilla-herald/public     # the live Caddy serves it at /community/
RAW=${OW_RAW:-https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable}
say() { printf '\n\033[1;36m== duels: %s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cmd=${1:-status}; shift || true

livevol() { docker volume ls -q --filter "label=com.docker.compose.project=wenilla-realm" --filter "label=com.docker.compose.volume=$1" | head -1; }
dvol() { docker volume ls -q --filter "label=com.docker.compose.project=owduels" --filter "label=com.docker.compose.volume=$1" | head -1; }
wait_healthy() {  # wait_healthy SERVICE MAX_SECONDS
  local s=starting
  for _ in $(seq 1 $(($2 / 10))); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$S" && docker compose ps -q "$1")" 2>/dev/null || echo starting)
    [ "$s" = healthy ] && return 0; sleep 10
  done
  echo "$1: $s after $2 s"; return 1
}
# SQL as the world server's own database user (mangosd.conf WorldDatabaseInfo, "host;port;user;pass;db"),
# kept in $DCP/.dbinfo (mode 600). Not root: on the first install the database's root password stopped
# matching both .env and the container (2026-10-21); the world server's login is the one that works.
dbinfo() {
  if [ ! -s "$DCP/.dbinfo" ]; then
    local CFG; CFG=$(dvol config)
    [ -n "$CFG" ] || return 1
    ( umask 077; docker run --rm -v "$CFG":/c:ro debian:bookworm-slim sh -c 'grep -i "^WorldDatabaseInfo" /c/mangosd.conf' | cut -d'"' -f2 > "$DCP/.dbinfo" )
  fi
  cat "$DCP/.dbinfo"
}
sql() {  # sql DATABASE FILE
  (cd "$S" && docker compose exec -T -e C="$(dbinfo)" mariadb sh -c 'U=$(echo "$C" | cut -d";" -f3); W=$(echo "$C" | cut -d";" -f4); MYSQL_PWD="$W" exec mariadb -u"$U" "$@"' sh "$1") < "$2"
}
sqle() {  # sqle DATABASE "STATEMENT"   (tab-separated, with a header line)
  (cd "$S" && docker compose exec -T -e C="$(dbinfo)" mariadb sh -c 'U=$(echo "$C" | cut -d";" -f3); W=$(echo "$C" | cut -d";" -f4); MYSQL_PWD="$W" exec mariadb -u"$U" "$@"' sh "$1" -e "$2")
}
domain() { grep '^REALM_DOMAIN=' "$S/.env" | cut -d= -f2; }

# mangosd.conf keys for Duels (replace the line, or add it at the end)
CONF_KEYS=(
  "OpenVanilla.Warfront=1"             # the kits, gear picker, enchants and arena (patch 0010)
  "OpenVanilla.Duels=1"                # 1v1 best of 3, practice duels, the results log (patch 0021)
  "OpenVanilla.Duels.Rounds=3"
  "OpenVanilla.Duels.PrepSeconds=15"
  "OpenVanilla.Duels.RoundPrepSeconds=5"
  "OpenVanilla.Duels.RoundMinutes=5"
  "OpenVanilla.Duels.SuddenDeathSeconds=180"     # then 10% more damage, 15% less healing taken per stack, a stack every 15 s
  "OpenVanilla.Duels.Arena=gurubashi"            # Gurubashi Arena on map 900 (patch 0024; arena_map below)
  "OpenVanilla.Duels.Arena.Map=900"
  "OpenVanilla.Duels.Hub=\"0 -9467.1 24.9 56.7 5.18\""      # the Lion's Pride Inn, Goldshire: the hangout
  "OpenVanilla.Duels.Hub.Fence=\"-9464 14 84\""             # kept within 84 yards of the inn's middle (the yard and the road)
  "OpenVanilla.Duels.PracticeBot=8"              # a practice duel alone for 8 s gets a bot (patch 0026)
  "OpenVanilla.Duels.AutoQueue=d1"               # queued from the inn after 4 idle seconds (rated)
  "OpenVanilla.Duels.Consumables=\"13446:3 13444:3 14530:2\""  # healing and mana potions, bandages every round
  "OpenVanilla.Duels.Glicko=1"
  "OpenVanilla.Warfront.Mall=\"0 -9464 14 30\""            # a /duel inside the inn resets both
  "Instance.UnloadDelay=60000"                   # a finished match's arena copy goes after a minute
  "AllowTwoSide.Interaction.Chat=1"              # the inn is for everyone: talk, group, trade, whisper across factions
  "AllowTwoSide.Interaction.Channel=1"
  "AllowTwoSide.Interaction.Group=1"
  "AllowTwoSide.Interaction.Trade=1"
  "AllowTwoSide.WhoList=1"
  "AllowTwoSide.AddFriend=1"
  "OpenVanilla.Warfront.Tier2.Rating=0" # every kit, item and enchant open from the start
  "OpenVanilla.Warfront.Tier3.Rating=0"
  "OpenVanilla.Warfront.BotFill=0"     # no realm bots: everyone on the ladder is a person
  "OpenVanilla.Warfront.Arena.SameAddressRated=0"  # rated duels never pit one network address against itself
  "OpenVanilla.AutoLearn=1"
  "OpenVanilla.FreeRespec=1"
  "OpenVanilla.DualSpec=1"
  "OpenVanilla.StarterPet=0"
  "OpenVanilla.InstantAccountMail=1"
  "OpenVanilla.ClosedCombos=0"
  "OpenVanilla.Transmog=1"
  "OpenVanilla.Transmog.PriceScale=0.01"
  "StartPlayerLevel=60"
  "StartPlayerMoney=0"
  "GameType=1"
  "SkipCinematics=2"
  "AlwaysMaxSkillForLevel=1"
)
# no bots and no auction-house bot on Duels: everyone in the inn is a person, and the world stays small
BOT_KEYS=(
  "AiPlayerbot.Enabled=0"
  "AiPlayerbot.RandomBotAutologin=0"
  "AiPlayerbot.MinRandomBots=0"
  "AiPlayerbot.MaxRandomBots=0"
)
AHBOT_KEYS=(
  "AuctionHouseBot.Chance.Sell=0"
  "AuctionHouseBot.Chance.Buy=0"
)

write_conf() {
  local CFG; CFG=$(dvol config)
  [ -n "$CFG" ] || { echo "no config volume yet"; return 1; }
  {
    printf 'mangosd.conf|%s\n' "${CONF_KEYS[@]}"
    printf 'aiplayerbot.conf|%s\n' "${BOT_KEYS[@]}"
    printf 'ahbot.conf|%s\n' "${AHBOT_KEYS[@]}"
  } | sed 's/ *# .*$//' > "$DCP/duels.conf.keys"
  docker run --rm -v "$CFG":/config -v "$DCP/duels.conf.keys":/keys:ro debian:bookworm-slim sh -c '
    for c in mangosd.conf aiplayerbot.conf ahbot.conf; do
      [ -e /config/$c ] && [ ! -e /config/$c.before-duels ] && cp /config/$c /config/$c.before-duels
    done
    while IFS="|" read -r c kv; do
      f=/config/$c; k=${kv%%=*}; v=${kv#*=}
      [ -n "$k" ] && [ -e $f ] || continue
      if grep -q "^$k *=" $f; then sed -i "s|^$k *=.*|$k = $v|" $f; else printf "%s = %s\n" "$k" "$v" >> $f; fi
    done < /keys
    grep -c "^OpenVanilla\.\(Duels\|Warfront\)" /config/mangosd.conf | sed "s/^/   duels and warfront settings: /"
    grep -h "^AiPlayerbot\.Enabled\|^AuctionHouseBot\.Chance" /config/aiplayerbot.conf /config/ahbot.conf 2>/dev/null | sed "s/^/   /"'
}

fetch() {  # the Duels and Warfront files from the repo
  mkdir -p "$DCP/legend"
  # from this checkout (what "git pull" brought) when the file is in it; else from the stable branch.
  # 2026-10-21: update took stable's older duels_lean.sql while the checkout had the fix, and the
  # world server crashed at start again.
  local REPO; REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  get() {
    if [ -f "$REPO/$1" ]; then cp "$REPO/$1" "$2.new" && mv "$2.new" "$2"
    else curl -fsSL "$RAW/$1" -o "$2.new" && mv "$2.new" "$2"; fi
  }
  get realm/duels/patch-Z.MPQ "$DCP/patch-Z.MPQ"
  get realm/duels/duels_characters.sql "$DCP/duels_characters.sql"
  get realm/duels/duels_world.sql "$DCP/duels_world.sql"
  get realm/duels/duels_lean.sql "$DCP/duels_lean.sql"
  mkdir -p "$DCP/tools/duels" "$DCP/tools/modelport"
  get tools/duels/arena_map.py "$DCP/tools/duels/arena_map.py"
  get tools/modelport/mpq.py "$DCP/tools/modelport/mpq.py"
  for f in warfront_kits.sql warfront_item_pool.sql warfront_world.sql warfront_characters.sql; do get "realm/warfront/$f" "$DCP/$f"; done
  for f in transmog_world.sql transmog_characters.sql; do get "realm/transmog/$f" "$DCP/$f"; done
  for f in legend.py legend_issue.py; do get "legend/$f" "$DCP/legend/$f"; done
  ls -la "$DCP"
}

apply_sql() {
  for f in warfront_kits.sql warfront_item_pool.sql warfront_world.sql transmog_world.sql duels_world.sql; do
    echo "   classicmangos < $f"; sql classicmangos "$DCP/$f"
  done
  # the lean world: only the inn's spawns (LEAN=0 keeps the whole world)
  if [ "${LEAN:-1}" = 1 ]; then echo "   classicmangos < duels_lean.sql"; sql classicmangos "$DCP/duels_lean.sql"; fi
  for f in warfront_characters.sql transmog_characters.sql duels_characters.sql; do
    echo "   classiccharacters < $f"; sql classiccharacters "$DCP/$f"
  done
  sqle classicrealmd "UPDATE realmlist SET name = 'Duels', icon = 1 WHERE id = 1"
  sqle classicmangos "SELECT COUNT(DISTINCT kit) AS kits FROM warfront_kit"
}

# The page keys its saved patch-Z files on /ow/data-version.json (realm/www/syncread.js). /ow/ is the
# live realm's folder, whose version names LIVE's patch-Z, not this realm's: a new patch-Z here kept
# the version, so browsers went on reading saved files of the old one next to new ones (Meters' new
# Window.lua over an old toc without Chrome.lua: "Window.lua:31: ... ROW_X (a nil value)",
# 2026-10-21). This realm publishes its own version over that one file. Written in place (the file is
# bind-mounted; a new inode would not be seen), and after the realm restarts on the new patch-Z.
write_version() {
  local sw
  sw=$(python3 -c "import json;print(json.load(open('$LIVE_CP/www/data-version.json')).get('sw','on'))" 2>/dev/null || echo on)
  mkdir -p "$DCP"
  local served=$DCP/client-data/patch-Z.MPQ     # the one the realm serves (with map 900's tables)
  [ -f "$served" ] || served=$DCP/patch-Z.MPQ
  if [ -f "$served" ]; then
    printf '{"patchZ":"%s","sw":"%s"}\n' "$(sha256sum "$served" | cut -c1-16)" "$sw" > "$DCP/data-version.json"
  else
    printf '{"sw":"%s"}\n' "$sw" > "$DCP/data-version.json"     # no version: the page keeps nothing
  fi
  chmod 644 "$DCP/data-version.json"
}

install_patch() {
  # copy then rename: the client data is hard-linked to live's, never write into the old file
  cp "$DCP/patch-Z.MPQ" "$DCP/client-data/patch-Z.MPQ.new" && mv -f "$DCP/client-data/patch-Z.MPQ.new" "$DCP/client-data/patch-Z.MPQ"
}

# Gurubashi Arena as map 900 (mangos patch 0024): a party-instance copy of Eastern Kingdoms, so every
# duel has its own copy of the pit. Three parts, all made here from this server's own files (they are
# Blizzard's tables and maps: never committed, never published but in this realm's client patch):
#   1. the server's Map.dbc gets the row (tools/duels/arena_map.py server)
#   2. maps, vmaps, mmaps: live's files linked one by one, and map 0's again under map 900's names
#   3. the client patch: Duels' patch-Z plus Map.dbc and Light.dbc with map 900 (arena_map.py client)
# The world server reads 1 and 2 at start; the realm's web service reads 3 at start: restart both after.
arena_map() {
  local DG LG DGP
  DG=$(dvol gamedata); LG=$(livevol gamedata)
  [ -n "$DG" ] && [ -n "$LG" ] || { echo "   no game data volumes yet"; return 1; }
  DGP=$(docker volume inspect -f '{{ .Mountpoint }}' "$DG")
  [ -d "$DGP/dbc" ] || { echo "   no dbc in $DGP"; return 1; }
  python3 "$DCP/tools/duels/arena_map.py" server "$DGP/dbc"
  docker run --rm -v "$DG":/data -v "$LG":/live:ro debian:bookworm-slim sh -c '
    for d in maps vmaps mmaps; do
      [ -d /live/$d ] || continue
      [ -L /data/$d ] && rm /data/$d
      mkdir -p /data/$d
      for f in /live/$d/*; do b=${f##*/}; [ -e /data/$d/$b ] || ln -s "$f" /data/$d/$b; done
      for f in /live/$d/000*; do [ -e "$f" ] || continue; b=${f##*/}; ln -sfn "$f" /data/$d/900${b#000}; done
      echo "   $d: $(ls /data/$d | grep -c "^900") files for map 900"
    done'
  python3 "$DCP/tools/duels/arena_map.py" client "$DGP/dbc" "$DCP/patch-Z.MPQ" "$DCP/client-data/patch-Z.MPQ"
}

# The website's Duels page: live counts, the ladder, the latest results and class win rates.
write_live() {
  local live ladder feed now out=$PUB/duels_live.json
  mkdir -p "$PUB"
  live=$(sqle classiccharacters "SELECT line, updated, UNIX_TIMESTAMP() FROM warfront_live WHERE id = 1" 2>/dev/null | tail -n +2 | head -1) || live=""
  ladder=$(sqle classiccharacters "SELECT c.guid, c.name, c.race, c.class, r.rating, r.best, r.wins, r.losses,
        COALESCE(p.points, 0), COALESCE(p.streak, 0), COALESCE(p.best_streak, 0)
      FROM warfront_arena_rating r JOIN characters c ON c.guid = r.guid LEFT JOIN duels_player p ON p.guid = r.guid
      WHERE r.bracket = 4 AND (r.wins + r.losses) > 0
        AND c.account NOT IN (SELECT id FROM classicrealmd.account WHERE username LIKE 'RNDBOT%')
      ORDER BY r.rating DESC, r.wins DESC LIMIT 200" 2>/dev/null | tail -n +2) || ladder=""
  now=$(sqle classiccharacters "SELECT body, updated FROM duels_now WHERE id = 1" 2>/dev/null | tail -n +2 | head -1) || now=""
  feed=$(sqle classiccharacters "SELECT ended, mode, winner, score0, score1, team0, team1, delta0, delta1, rated, seconds
      FROM warfront_arena_result ORDER BY id DESC LIMIT 400" 2>/dev/null | tail -n +2) || feed=""
  LIVE_ROW="$live" LADDER="$ladder" FEED="$feed" NOW_ROW="$now" python3 - "$out" <<'PY'
import json, os, sys, time
CLASS = {1: "Warrior", 2: "Paladin", 3: "Hunter", 4: "Rogue", 5: "Priest", 7: "Shaman", 8: "Mage", 9: "Warlock", 11: "Druid"}
RACE = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "Night Elf", 5: "Undead", 6: "Tauren", 7: "Gnome", 8: "Troll"}
def num(x):
    try: return int(x)
    except Exception: return 0
now = int(time.time())
out = {"updated": 0, "stale": True, "queued": {"d1": 0, "u1": 0}, "fights": 0, "today": 0,
       "ladder": [], "feed": [], "classes": [], "now": [], "by_class": {}}
row = os.environ.get("LIVE_ROW", "").split("\t")
if len(row) == 3:
    n = [num(x) for x in row[0].split(",")] + [0] * 10
    out["updated"], now = num(row[1]), num(row[2]) or now
    out["stale"] = now - out["updated"] > 90
    out["queued"] = {"d1": n[4], "u1": n[9]}
    out["fights"] = n[5]
for l in os.environ.get("LADDER", "").splitlines():
    f = l.split("\t")
    if len(f) < 8: continue
    f += ["0"] * 3
    e = {"name": f[1], "race": RACE.get(num(f[2]), ""), "class": CLASS.get(num(f[3]), ""),
         "rating": num(f[4]), "best": num(f[5]), "wins": num(f[6]), "losses": num(f[7]),
         "points": num(f[8]), "streak": num(f[9]), "best_streak": num(f[10]),
         "legend": "%d.json" % num(f[0])}
    if len(out["ladder"]) < 50:
        out["ladder"].append(e)
    top = out["by_class"].setdefault(e["class"] or "?", [])
    if len(top) < 5:
        top.append(e)
# the fights now (the world server's duels_now, every 15 s), for "Fights now" and spectating
nrow = os.environ.get("NOW_ROW", "").split("\t")
if len(nrow) == 2 and now - num(nrow[1]) < 90:
    for part in nrow[0].split(";")[1:]:
        f = part.split(",")
        if len(f) < 9: continue
        sides = []
        for s in f[6:8]:
            x = (s.split(":") + ["", "0", "0"])[:3]
            sides.append({"name": x[0], "class": CLASS.get(num(x[1]), ""), "rating": num(x[2])})
        out["now"].append({"id": num(f[0]), "mode": f[1], "phase": f[2], "round": num(f[3]),
                           "score": [num(f[4]), num(f[5])], "sides": sides, "watchers": num(f[8])})
def side(team):
    first = (team.split(";") or [""])[0].split(":")
    return {"name": first[0] if first else "", "class": CLASS.get(num(first[1]) if len(first) > 1 else 0, ""),
            "left": len(first) > 3 and first[3] == "left"}
stats = {}
for l in os.environ.get("FEED", "").splitlines():
    f = l.split("\t")
    if len(f) < 11: continue
    ended, mode, winner = num(f[0]), f[1], num(f[2])
    if now - ended < 86400: out["today"] += 1
    if winner not in (0, 1): continue
    w, lo = side(f[5 + winner]), side(f[6 - winner])
    if now - ended < 7 * 86400 and mode in ("d1", "u1"):
        for who, key in ((w, "wins"), (lo, "losses")):
            if who["class"]:
                stats.setdefault(who["class"], {"class": who["class"], "wins": 0, "losses": 0})[key] += 1
    if len(out["feed"]) < 25:
        sw, sl = num(f[3 + winner]), num(f[4 - winner])
        out["feed"].append({"t": ended, "mode": mode, "rated": f[9] == "1", "seconds": num(f[10]),
                            "winner": w, "loser": lo, "score": "%d-%d" % (sw, sl) if sw + sl else "",
                            "delta": num(f[7 + winner])})
out["classes"] = sorted(stats.values(), key=lambda c: -(c["wins"] + c["losses"]))
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as fh:
    json.dump(out, fh, separators=(",", ":"))
os.replace(tmp, sys.argv[1])
PY
}

# Legend (legend/SPEC.md): every duelist's record, signed with this realm's key, verifiable by anyone.
write_legend() {
  local D; D=$(domain)
  local OUT=$PUB/legend/duels
  mkdir -p "$OUT" "$DCP/legend"
  [ -e "$DCP/legend/legend_issue.py" ] || { echo "no Legend issuer yet (bash $0 update)"; return 0; }
  sqle classiccharacters "SELECT c.guid, c.name, c.race, c.class, c.gender, c.level, c.account,
      r.rating AS rating, r.best AS best, r.wins AS wins, r.losses AS losses
      FROM warfront_arena_rating r JOIN characters c ON c.guid = r.guid
      WHERE r.bracket = 4 AND (r.wins + r.losses) > 0
        AND c.account NOT IN (SELECT id FROM classicrealmd.account WHERE username LIKE 'RNDBOT%')" \
    > "$DCP/legend/rows.tsv" 2>/dev/null || return 0
  # players who chose to show their Hero ID (the realm's /api/heroes.json, patch 0031); none is fine
  curl -fsS --max-time 10 "https://$D/api/heroes.json" -o "$DCP/legend/heroes.json.new" 2>/dev/null \
    && mv "$DCP/legend/heroes.json.new" "$DCP/legend/heroes.json" || rm -f "$DCP/legend/heroes.json.new"
  local H=(); [ -s "$DCP/legend/heroes.json" ] && H=(--heroes "$DCP/legend/heroes.json")
  python3 "$DCP/legend/legend_issue.py" --host "$D" --name Duels --key "$DCP/legend/duels.key" \
    --rows "$DCP/legend/rows.tsv" "${H[@]}" --out "$OUT" --wellknown "$OUT/keys.json"
}

timers() {
  local name every what
  for spec in "live 20" "legend 120"; do
    set -- $spec; what=$1; every=$2; name=openvanilla-duels-$what
    cat > /etc/systemd/system/$name.service <<UNIT
[Unit]
Description=Open Vanilla Duels: $what for the website
[Service]
Type=oneshot
ExecStart=/bin/bash $LIVE_CP/repo/hetzner/duels_up.sh $what
UNIT
    cat > /etc/systemd/system/$name.timer <<UNIT
[Unit]
Description=Open Vanilla Duels: $what, every $every s
[Timer]
OnBootSec=90
OnUnitActiveSec=$every
AccuracySec=5
[Install]
WantedBy=timers.target
UNIT
  done
  systemctl daemon-reload
  systemctl enable --now openvanilla-duels-live.timer openvanilla-duels-legend.timer >/dev/null
  echo "   website: $PUB/duels_live.json every 20 s, Legends in $PUB/legend/duels every 2 min"
}

caddy_site() {
  local D; D=$(domain)
  cat > "$DCP/Caddyfile.site" <<CADDY

# Duels (hetzner/duels_up.sh): its own realm service, and its Legends (legend/SPEC.md).
$D {
	encode zstd gzip
	@owsw path /ow/sw.js
	header @owsw Service-Worker-Allowed "/"
	@shared path /data/* /wenilla_bg.wasm
	header @shared >Vary "Accept-Encoding"
	handle /.well-known/openvanilla-legend.json {
		root * /srv/community/legend/duels
		rewrite * /keys.json
		header Access-Control-Allow-Origin *
		header Cache-Control "public, max-age=300"
		file_server
	}
	handle_path /legend/* {
		root * /srv/community/legend/duels
		header Access-Control-Allow-Origin *
		header Cache-Control "public, max-age=60"
		header Content-Security-Policy "default-src 'none'; sandbox"
		file_server
	}
	handle {
		reverse_proxy owduels-realm:8090 {
			# the player's own address, never one it sent: guest limits and rated matchmaking key on it
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
		}
	}
	header -Server
}
CADDY
  if ! grep -q "owduels-realm" "$LIVE_CP/Caddyfile"; then cat "$DCP/Caddyfile.site" >> "$LIVE_CP/Caddyfile"; fi
  (cd "$LIVE" && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile) || echo "   (reload Caddy by hand: cd $LIVE && docker compose restart caddy)"
}

override() {
  local REALM_IMAGE MANGOS_IMAGE LG
  REALM_IMAGE=$(awk '/^  realm:/{f=1;next} f&&/image:/{print $2;exit}' "$LIVE/compose.override.yaml" 2>/dev/null)
  [ -n "$REALM_IMAGE" ] || REALM_IMAGE="ghcr.io/arnesen/wenilla-realm:latest"
  MANGOS_IMAGE=ghcr.io/orionopenwow/openvanilla-mangos:latest
  LG=$(livevol gamedata)
  [ -f "$DCP/data-version.json" ] || write_version   # the mount needs the file
  cat > "$S/compose.override.yaml" <<YAML
# Written by hetzner/duels_up.sh — re-run it instead of editing by hand.
services:
  realm:
    image: $REALM_IMAGE
    environment:
      OPENVANILLA_GUESTS: "1"        # play free as a guest, straight from the website
      DISCORD_SIGNIN: "off"          # Hero Key, Google or a password; Discord stays the community
      # This service is also on the live realm's network (for the live Caddy), where "mariadb",
      # "mangosd" and "realmd" are LIVE's: it must reach its own by names only this stack has.
      # (2026-10-21: it reached live's, so its database and console logins were refused.)
      MARIADB_URL: "mysql://realmweb:\${DB_REALMWEB_PASSWORD}@owduels-mariadb:3306/classicrealmd"
      SOAP_URL: "http://owduels-mangosd:7878/"
      REALMD_HOST: "owduels-realmd"
      MANGOSD_HOST: "owduels-mangosd"
    volumes:
      - $LIVE_CP/bridge.js:/app/www/bridge.js:ro
      - $LIVE_CP/bridge.js.br:/app/www/bridge.js.br:ro
      - $LIVE_CP/bridge.js.gz:/app/www/bridge.js.gz:ro
      - $LIVE_CP/addons-loader.js:/app/www/addons-loader.js:ro
      - $LIVE_CP/www:/app/www/ow:ro
      - $DCP/data-version.json:/app/www/ow/data-version.json:ro
    networks:
      default: {}
      live:
        aliases: [owduels-realm]
  mangosd:
    image: $MANGOS_IMAGE
    networks:
      default:
        aliases: [owduels-mangosd]
    volumes:
      - $LG:/live:ro      # the live realm's maps, shared read-only
  mariadb:
    networks:
      default:
        aliases: [owduels-mariadb]
  realmd:
    networks:
      default:
        aliases: [owduels-realmd]
networks:
  live:
    external: true
    name: wenilla-realm_default
volumes:
  $LG:                  # the live realm's game data volume: compose needs it declared (external)
    external: true
YAML
}

mem_check() {
  local avail; avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  if [ "$avail" -lt 2300 ] && [ "${FORCE:-0}" != 1 ]; then
    echo "Only ${avail} MB of memory free. Duels' world server needs about 1.8 GB on top of what runs now."
    echo "Resize the server first (Hetzner: CX33, 8 GB), or run again with FORCE=1 to try anyway."
    exit 1
  fi
}

case "$cmd" in
install)
  DOMAIN=${1:-duels.openvanilla.app}
  [ -e "$LIVE/.env" ] || { echo "No live realm at $LIVE"; exit 1; }
  mem_check
  set -a; . "$LIVE/.env"; set +a
  LIVE_DATA=$CLIENT_DATA
  say "1/8 stack files ($S)"
  mkdir -p "$S" "$DCP"
  cp -r "$LIVE/compose.yaml" "$LIVE/docker" "$LIVE/caddy" "$S/"
  if [ ! -e "$S/.env" ]; then
    rnd() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
    {
      echo "# Open Vanilla Duels (hetzner/duels_up.sh). Its own databases and passwords."
      echo "COMPOSE_PROJECT_NAME=owduels"
      echo "REALM_DOMAIN=$DOMAIN"
      echo "DB_ROOT_PASSWORD=$(rnd)"
      echo "DB_MANGOS_PASSWORD=$(rnd)"
      echo "DB_REALMWEB_PASSWORD=$(rnd)"
      echo "CLIENT_DATA=$DCP/client-data"
      echo "MANGOSD_MEM=${MANGOSD_MEM:-1800m}"
      echo "REALM_TAG=${REALM_TAG:-latest}"
      echo "MANGOS_TAG=${MANGOS_TAG:-latest}"
    } > "$S/.env"
    chmod 600 "$S/.env"
  fi
  say "2/8 Duels files"
  fetch
  say "3/8 client data: hard links to live's MPQs, Duels' own patch-Z"
  mkdir -p "$DCP/client-data"
  if ! cp -al "$LIVE_DATA/." "$DCP/client-data/" 2>/dev/null; then
    echo "   (not on the same disk as $LIVE_DATA: copying instead)"; cp -a "$LIVE_DATA/." "$DCP/client-data/"
  fi
  rm -f "$DCP/client-data/patch-Z.MPQ"; install_patch
  say "4/8 databases (the stock world database installs once, ~10 minutes)"
  cd "$S"
  docker compose up -d mariadb
  docker compose run --rm db-init
  say "5/8 world data: stock dbc (live's, with any Open Vanilla server copies put back), live's maps shared"
  docker compose create mangosd >/dev/null 2>&1 || true
  DG=$(dvol gamedata); LG=$(livevol gamedata)
  [ -n "$DG" ] || { docker volume create --label com.docker.compose.project=owduels --label com.docker.compose.volume=gamedata owduels_gamedata >/dev/null; DG=owduels_gamedata; }
  docker run --rm -v "$DG":/data -v "$LG":/live:ro debian:bookworm-slim sh -c '
    rm -rf /data/dbc && cp -a /live/dbc /data/dbc
    for o in /data/dbc/*.orig; do [ -e "$o" ] && mv -f "$o" "${o%.orig}"; done
    ls /data'
  arena_map
  say "6/8 Duels SQL and mangosd.conf"
  apply_sql
  write_conf
  say "7/8 images; the live Caddy serves https://$DOMAIN"
  override
  docker compose up -d --force-recreate realm realmd mangosd && write_version
  caddy_site; timers
  say "8/8 starting the world server"
  wait_healthy mangosd 900 || true
  TOKEN=$(docker compose exec -T realm cat /state/setup-token 2>/dev/null || true)
  cat <<TXT
Duels is up. What only you can do:
  1. DNS: an A record for $DOMAIN pointing at this server (same IP as the live realm).
  2. Open https://$DOMAIN/setup${TOKEN:+ (setup token: $TOKEN)} and make the admin login.
  3. Try it: https://$DOMAIN -> Play free as a guest -> make a level 60 -> the Duels window -> Practice duel
     (a second browser or a private window is your opponent).
  4. When it works: DUELS_OPEN = 1 in www/downloads/links.txt shows Duels on the website.
TXT
  ;;
update)
  [ -e "$S/.env" ] || { echo "no Duels stack (bash $0 install)"; exit 1; }
  say "1/4 Duels files"; fetch
  say "2/4 client patch and Gurubashi Arena (map 900)"; install_patch; arena_map
  say "3/4 SQL and config"; apply_sql; write_conf; timers
  say "4/4 restart (the web service reads the patch's file table at start)"
  # --no-deps: the one-off db-init job is for the first install only
  cd "$S"; override; docker compose pull -q realm mangosd || echo "   (could not pull new images: starting the ones here)"
  docker compose up -d --no-deps realmd && docker compose up -d --no-deps --force-recreate realm mangosd && write_version
  caddy_site
  wait_healthy mangosd 900 && echo "Duels is up"
  TOKEN=$(docker compose exec -T realm cat /state/setup-token 2>/dev/null || true)
  [ -z "$TOKEN" ] || echo "Admin setup (if not done yet): https://$(domain)/setup  token: $TOKEN" ;;
arena)
  [ -e "$S/.env" ] || { echo "no Duels stack (bash $0 install)"; exit 1; }
  arena_map && echo "   now: bash $0 update (or restart realm and mangosd)" ;;
start)
  cd "$S"; docker compose up -d mariadb && docker compose up -d --no-deps realmd mangosd realm
  wait_healthy mangosd 900 && echo "Duels is up" ;;
stop)
  cd "$S"; docker compose stop; echo "Duels is stopped" ;;
status)
  [ -e "$S/.env" ] || { echo "no Duels stack (bash $0 install)"; exit 0; }
  cd "$S"; docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}'
  sqle classiccharacters "SELECT COUNT(*) AS matches, SUM(ended > UNIX_TIMESTAMP() - 86400) AS today FROM warfront_arena_result;
    SELECT COUNT(*) AS duelists, MAX(rating) AS top FROM warfront_arena_rating WHERE bracket = 4" 2>/dev/null || true
  ls -la "$PUB/duels_live.json" "$PUB/legend/duels/keys.json" 2>/dev/null || true ;;
live)
  [ -e "$S/.env" ] || exit 0
  write_live ;;
legend)
  [ -e "$S/.env" ] || exit 0
  write_legend ;;
*) echo "usage: $0 install [domain] | update | start | stop | status | live | legend | arena"; exit 2 ;;
esac
