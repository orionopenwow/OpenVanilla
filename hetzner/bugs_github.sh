#!/usr/bin/env bash
# Bug reports from the game -> also a GitHub issue each (bot/herald_bugs.py), so fixes can be suggested
# and made from there. Issues are public: character name, level, class and place; never the account.
#
#   bash hetzner/bugs_github.sh          asks for the token once (hidden, never printed), restarts Herald
#   bash hetzner/bugs_github.sh off      stops filing issues (Discord posts carry on)
#
# Make the token first, on github.com signed in as the owner:
#   Settings > Developer settings > Personal access tokens > Fine-grained tokens > Generate new token
#   - Repository access: Only select repositories > orionopenwow/OpenVanilla
#   - Permissions > Repository permissions > Issues: Read and write (nothing else)
#   - Expiration: 1 year (put a reminder in your calendar to renew it)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
ENVF=/etc/openvanilla-herald.env
REPO=${BUGS_GITHUB_REPO:-orionopenwow/OpenVanilla}
[ -f "$ENVF" ] || { echo "No $ENVF: run hetzner/herald_up.sh first."; exit 1; }
setenv() {  # setenv KEY VALUE (replaces the line, or adds it)
  python3 - "$ENVF" "$1" "$2" <<'PY'
import sys
f, k, v = sys.argv[1:4]
lines = [l for l in open(f).read().splitlines() if not l.startswith(k + "=")]
if v:
    lines.append(f"{k}={v}")
open(f, "w").write("\n".join(lines) + "\n")
PY
}
if [ "${1:-}" = off ]; then
  setenv BUGS_GITHUB_TOKEN ""
  echo "Bug reports no longer open GitHub issues."
else
  read -r -s -p "GitHub fine-grained token (Issues: read and write on $REPO; hidden): " TOKEN; echo
  [ -n "$TOKEN" ] || { echo "No token given."; exit 1; }
  # check it before saving: can it see the repo's issues?
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
         "https://api.github.com/repos/$REPO/issues?per_page=1")
  [ "$code" = 200 ] || { echo "GitHub answered $code for that token on $REPO: check its repository and Issues permission."; exit 1; }
  setenv BUGS_GITHUB_REPO "$REPO"
  setenv BUGS_GITHUB_TOKEN "$TOKEN"
  echo "Saved. New bug reports also open an issue on $REPO (label bug-report)."
fi
chmod 600 "$ENVF"
systemctl restart openvanilla-herald && echo "Herald restarted."
