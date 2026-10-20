#!/usr/bin/env bash
# Turn on "Sign in with Google" on the realm (realm patch 0027), next to Discord and guest play.
#
#   bash hetzner/google_signin.sh        asks for the client id and secret once, stores them in .env
#                                        (never printed), restarts the realm web service (~5 s)
#
# Make the client first, in Google Cloud Console (console.cloud.google.com), signed in as the owner:
#   1. APIs & Services > OAuth consent screen: External; app name Open Vanilla; support e-mail;
#      authorised domain openvanilla.app; scopes: openid and profile only (no e-mail). Publish it
#      ("In production"), so anyone can sign in, not just test users.
#   2. APIs & Services > Credentials > Create credentials > OAuth client ID > Web application.
#      Authorised redirect URI: https://play.openvanilla.app/auth/google/callback
#      (and https://<warfront domain>/auth/google/callback if Warfront should have it too).
#   3. Copy the client ID (ends in .apps.googleusercontent.com) and the client secret.
set -euo pipefail
REALM_DIR=${OW_REALM_DIR:-/opt/wenilla-realm}
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cd "$REALM_DIR"
grep -q 'GOOGLE_CLIENT_ID' compose.override.yaml 2>/dev/null || {
  echo "This realm's compose.override.yaml predates Google sign-in: run Server.bat option 1 (openvanilla_realm_up.sh) first."; exit 1; }
read -r -p "Google client ID: " ID
[[ "$ID" == *.apps.googleusercontent.com ]] || { echo "That doesn't look like a Google client ID."; exit 1; }
read -r -s -p "Google client secret (hidden): " SECRET; echo
[ -n "$SECRET" ] || { echo "No secret given."; exit 1; }
for kv in "GOOGLE_CLIENT_ID=$ID" "GOOGLE_CLIENT_SECRET=$SECRET"; do
  k=${kv%%=*}
  if grep -q "^$k=" .env; then python3 - "$k" "${kv#*=}" <<'PY'
import sys
k, v = sys.argv[1], sys.argv[2]
lines = open(".env").read().splitlines()
open(".env", "w").write("\n".join(f"{k}={v}" if l.startswith(k + "=") else l for l in lines) + "\n")
PY
  else printf '%s\n' "$kv" >> .env; fi
done
chmod 600 .env
docker compose up -d --no-deps --force-recreate realm
sleep 8
docker compose logs --since 1m realm 2>&1 | grep -i -E 'google|sign-in enabled' | tail -3
echo "Done. The sign-in page shows Sign in with Google once the realm image with patch 0027 is running."
