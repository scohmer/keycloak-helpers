#!/bin/bash
# test-browser-login.sh
#
# Simulates a REAL browser-based OIDC login (GET the login page, extract the
# form action, POST credentials, follow the result) — not a password-grant
# token request, which bypasses the browser authentication flow entirely and
# so can't be used to test flow restrictions (group/role gating, etc.).
#
# Run on the Keycloak host. Requires the realm's hostname (not 127.0.0.1 —
# Keycloak's hostname-strict redirect will otherwise move the interactive
# part to the real hostname mid-flow, and curl won't carry cookies scoped to
# 127.0.0.1 across that host change, producing a spurious "restart cookie
# not found" error that looks like a real failure but isn't).
#
# Usage:
#   ./test-browser-login.sh <username> <password> [client_id] [redirect_uri]
#
# Defaults to the open-webui client/redirect if not given.

set -euo pipefail

CACERT="/opt/keycloak-docker/certs/ca-bundle.crt"
REALM="internal"
KC_HOST="keycloak.seancohmer.com:8443"
USERNAME="$1"
PASSWORD="$2"
CLIENT_ID="${3:-open-webui}"
REDIRECT_URI="${4:-https://192.168.10.121:8443/oauth/oidc/callback}"
JAR="$(mktemp)"
BODY_FILE="$(mktemp)"

ENCODED_REDIRECT=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$REDIRECT_URI")
AUTH_URL="https://${KC_HOST}/realms/${REALM}/protocol/openid-connect/auth?client_id=${CLIENT_ID}&redirect_uri=${ENCODED_REDIRECT}&response_type=code&scope=openid+email+profile"

echo "=== GET login page ==="
LOGIN_PAGE=$(curl -s --cacert "$CACERT" -c "$JAR" -b "$JAR" -L "$AUTH_URL")
FORM_ACTION=$(echo "$LOGIN_PAGE" | grep -oP '(?<=action=")[^"]+' | head -1 | sed 's/&amp;/\&/g')

if [ -z "$FORM_ACTION" ]; then
  echo "ERROR: could not find login form action. Page snippet:"
  echo "$LOGIN_PAGE" | head -c 1000
  rm -f "$JAR" "$BODY_FILE"
  exit 1
fi
echo "Form action: $FORM_ACTION"

echo "=== POST credentials for user: ${USERNAME} ==="
RESPONSE=$(curl -s --cacert "$CACERT" -c "$JAR" -b "$JAR" -D - -o "$BODY_FILE" \
  --data-urlencode "username=${USERNAME}" --data-urlencode "password=${PASSWORD}" \
  --data-urlencode "credentialId=" \
  "$FORM_ACTION")

echo "--- response headers ---"
echo "$RESPONSE" | head -6

if echo "$RESPONSE" | grep -qi "^location:.*code="; then
  echo ">>> RESULT: LOGIN SUCCEEDED (redirect with authorization code)"
elif grep -qi "access.denied\|not.allowed\|forbidden" "$BODY_FILE"; then
  echo ">>> RESULT: LOGIN DENIED (access-denied page shown)"
elif grep -qi "invalid username or password" "$BODY_FILE"; then
  echo ">>> RESULT: 'Invalid username or password' — could be genuinely wrong creds,"
  echo "    OR a broken flow (mixed REQUIRED/ALTERNATIVE at one level, etc.) causing"
  echo "    Keycloak to silently drop steps. Check container logs for WARN/ERROR."
else
  echo ">>> RESULT: UNCLEAR — inspect body:"
  head -c 1500 "$BODY_FILE"
fi

rm -f "$JAR" "$BODY_FILE"
