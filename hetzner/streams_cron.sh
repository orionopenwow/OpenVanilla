#!/usr/bin/env bash
# Open Vanilla streams & creators: one pass of tools/streams_fetch.py (who is live, recent videos, the
# monthly creator leaderboard) -> the Herald's public folder, served as /community/streams.json.
#
#   bash streams_cron.sh install     (root) fetch the code, write /etc/openvanilla-streams.env, enable the
#                                    systemd timer (hetzner/systemd/openvanilla-streams.timer: every 5 min)
#   bash streams_cron.sh             one pass (what the timer runs; also fine from cron:
#                                    */5 * * * * herald /opt/openvanilla-streams/streams_cron.sh)
#
# Keys live in /etc/openvanilla-streams.env (root:herald 640), never in the site folder:
#   TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET    dev.twitch.tv/console -> Register Your Application
#                                             (category "Website Integration"; no redirect needed:
#                                             the fetcher uses an app token, client credentials)
#   YOUTUBE_API_KEY                           console.cloud.google.com -> YouTube Data API v3 -> API key
#                                             (restrict it to that API; 10,000 units/day fits ~15 channels)
#   TIKTOK_TOKENS_FILE                        optional: tokens of creators who connected TikTok (Display
#                                             API) in /var/lib/openvanilla-streams (600), refreshed by the fetcher with
#   TIKTOK_CLIENT_KEY, TIKTOK_CLIENT_SECRET,  the TikTok app's keys; connect a creator with
#   TIKTOK_REDIRECT_URI                       streams_fetch.py --tiktok-connect HANDLE; see docs/STREAMS.md
#   REALM_URL, CREATOR_EXPORT_TOKEN           the realm service and its staff export token, for the
#                                             channels players linked (GET /api/creator/links)
# Any missing key just skips that source.
set -euo pipefail
DIR=/opt/openvanilla-streams
RAW=${OPENVANILLA_RAW:-https://raw.githubusercontent.com/orionopenwow/OpenVanilla/stable}
ENVF=/etc/openvanilla-streams.env
OUT=${STREAMS_OUT:-/opt/openvanilla-herald/public/streams.json}
STATE=${STREAMS_STATE:-/var/lib/openvanilla-streams/state.json}

if [ "${1:-}" = install ]; then
  [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
  id herald >/dev/null 2>&1 || useradd --system --home /opt/openvanilla-herald --shell /usr/sbin/nologin herald
  mkdir -p "$DIR" /var/lib/openvanilla-streams "$(dirname "$OUT")"
  curl -fsSL "$RAW/tools/streams_fetch.py" -o "$DIR/streams_fetch.py"
  curl -fsSL "$RAW/hetzner/streams_cron.sh" -o "$DIR/streams_cron.sh"
  [ -s "$DIR/creators.yml" ] || curl -fsSL "$RAW/www/community/creators.yml" -o "$DIR/creators.yml"
  for u in openvanilla-streams.service openvanilla-streams.timer; do
    curl -fsSL "$RAW/hetzner/systemd/$u" -o "/etc/systemd/system/$u"
  done
  chmod 755 "$DIR/streams_cron.sh"
  chown -R herald:herald "$DIR" /var/lib/openvanilla-streams
  if [ ! -s "$ENVF" ]; then
    umask 027
    cat > "$ENVF" <<ENV
# Open Vanilla streams fetcher (hetzner/streams_cron.sh). Empty = that source is skipped.
TWITCH_CLIENT_ID=
TWITCH_CLIENT_SECRET=
YOUTUBE_API_KEY=
YT_SEARCH_MINUTES=60
TIKTOK_TOKENS_FILE=/var/lib/openvanilla-streams/tiktok.json
TIKTOK_CLIENT_KEY=
TIKTOK_CLIENT_SECRET=
TIKTOK_REDIRECT_URI=
REALM_URL=https://play.openvanilla.app
CREATOR_EXPORT_TOKEN=
STREAMS_OUT=$OUT
STREAMS_STATE=$STATE
ENV
    echo "Fill in $ENVF (Twitch / YouTube keys, the realm's CREATOR_EXPORT_TOKEN)."
  fi
  chown root:herald "$ENVF"; chmod 640 "$ENVF"
  systemctl daemon-reload
  systemctl enable --now openvanilla-streams.timer
  echo "Streams: every 5 minutes -> $OUT (https://<realm>/community/streams.json)."
  echo "Logs: journalctl -u openvanilla-streams"
  exit 0
fi

# ---- one pass
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/streams_fetch.py" ]; then DIR=$HERE                   # installed: /opt/openvanilla-streams
elif [ -f "$HERE/../tools/streams_fetch.py" ]; then                  # a checkout: hetzner/ beside tools/
  DIR=${STREAMS_DIR:-$HOME/.local/state/openvanilla}; mkdir -p "$DIR"
  cp -n "$HERE/../www/community/creators.yml" "$DIR/creators.yml" 2>/dev/null || true
  cp "$HERE/../tools/streams_fetch.py" "$DIR/streams_fetch.py"
fi
FETCH="$DIR/streams_fetch.py"
CREATORS=${CREATORS_YML:-$DIR/creators.yml}
# The curated list follows the repo (hourly); the linked part is rewritten from the realm every pass.
FRESH=""
if [ ! -f "$DIR/.curated_at" ] || [ -n "$(find "$DIR/.curated_at" -mmin +60 2>/dev/null)" ]; then
  TMP=$(mktemp)
  if curl -fsSL --max-time 20 "$RAW/www/community/creators.yml" -o "$TMP" 2>/dev/null; then FRESH=$TMP; fi
  touch "$DIR/.curated_at" 2>/dev/null || true
fi
python3 "$FETCH" --out "$OUT" --creators "$CREATORS" --state "$STATE" ${FRESH:+--curated-from "$FRESH"}
[ -n "$FRESH" ] && rm -f "$FRESH"
exit 0
