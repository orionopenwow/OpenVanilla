#!/usr/bin/env bash
# A push, the safe way: hot-update STAGING, let Herald Lite play it, and only when it passes
# hot-update LIVE to exactly the commit staging tested. The hotpatch GitHub Action runs this.
#
#   bash promote.sh [--force-web] [--world-restart] [--dry-run]    (flags go to the live update)
#
# Without a staging realm (devkit/staging/staging_up.sh install) it updates live directly, as
# before. With staging but no Herald Lite set up yet, it says so loudly and promotes anyway.
set -euo pipefail
LIVE_CP=/opt/openvanilla-classicplus
S=/opt/wenilla-staging
SCP=/opt/openvanilla-staging
HERE=$(cd "$(dirname "$0")" && pwd)
HOT=$LIVE_CP/repo/hetzner/openvanilla_hotpatch.sh
[ -f "$HOT" ] || HOT=$LIVE_CP/openvanilla_hotpatch.sh
say() { printf '\n\033[1;35m== promote: %s\033[0m\n' "$*"; }

if [ ! -e "$S/.env" ]; then
  say "no staging realm: hot-updating live directly"
  exec bash "$HOT" "$@"
fi
for a in "$@"; do [ "$a" = --dry-run ] && { OW_REALM_DIR=$S OW_CP=$SCP bash "$HOT" --dry-run; exec bash "$HOT" "$@"; }; done

ASLEEP=0
(cd "$S" && docker compose ps --status running -q mangosd | grep -q .) || ASLEEP=1
[ $ASLEEP = 1 ] && { say "waking staging"; bash "$HERE/staging_up.sh" start; }

say "1/3 staging: hot update to the newest commit"
OW_REALM_DIR=$S OW_CP=$SCP bash "$HOT" --force-web
if [ -e "$SCP/.hotpatch-queued-world-restart" ]; then   # nobody plays staging: restart now, no countdown
  (cd "$S" && docker compose restart mangosd) && rm -f "$SCP/.hotpatch-queued-world-restart"
  bash "$HERE/staging_up.sh" start >/dev/null
fi
COMMIT=$(cat "$SCP/.hotpatch-applied")

say "2/3 Herald Lite on staging (${COMMIT:0:8})"
if [ -x "$SCP/bin/heraldlite" ] && [ -e "$S/heraldlite.env" ]; then
  if ! bash "$HERE/staging_up.sh" herald; then
    say "Herald Lite FAILED on staging: live stays as it is. Report: $SCP/last-herald.json"
    [ $ASLEEP = 1 ] && bash "$HERE/staging_up.sh" stop
    exit 1
  fi
else
  echo "!! Herald Lite isn't set up on this server yet (staging_up.sh build-heraldlite + heraldlite.env)."
  echo "!! Promoting WITHOUT a test run. Set it up to make this gate real."
fi

say "3/3 live: hot update to ${COMMIT:0:8}"
bash "$HOT" --to "$COMMIT" "$@"
[ $ASLEEP = 1 ] && bash "$HERE/staging_up.sh" stop
say "done"
