#!/bin/bash
# register-oidc-client.sh
#
# Registers (or updates) a confidential OIDC client in a Keycloak realm via
# the Admin REST API, and prints its client secret. Run on the Keycloak host
# itself (talks to https://127.0.0.1:8443).
#
# Usage:
#   ./register-oidc-client.sh --realm internal --client-id open-webui \
#     --redirect-uri 'https://192.168.10.121:8443/oauth/oidc/callback' \
#     --web-origin 'https://192.168.10.121:8443'

set -euo pipefail

KC_BASE="https://127.0.0.1:8443"
CACERT="/opt/keycloak-docker/certs/ca-bundle.crt"
ENV_FILE="/opt/keycloak-docker/.env"

REALM=""
CLIENT_ID=""
REDIRECT_URI=""
WEB_ORIGIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --realm) REALM="$2"; shift 2 ;;
    --client-id) CLIENT_ID="$2"; shift 2 ;;
    --redirect-uri) REDIRECT_URI="$2"; shift 2 ;;
    --web-origin) WEB_ORIGIN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
for v in REALM CLIENT_ID REDIRECT_URI WEB_ORIGIN; do
  [ -z "${!v}" ] && { echo "ERROR: --${v,,} is required." >&2; exit 1; }
done

ADMIN_PASS=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD "$ENV_FILE" | cut -d= -f2)
TOKEN=$(curl -s --cacert "$CACERT" -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" -d "username=admin" -d "password=${ADMIN_PASS}" \
  | jq -r .access_token)

kc_api() { curl -s --cacert "$CACERT" -H "Authorization: Bearer ${TOKEN}" "$@"; }

EXISTING_UUID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id // empty')

CLIENT_CONFIG=$(jq -n --arg cid "$CLIENT_ID" --arg redirect "$REDIRECT_URI" --arg origin "$WEB_ORIGIN" '{
  clientId: $cid, enabled: true, protocol: "openid-connect",
  publicClient: false, standardFlowEnabled: true, directAccessGrantsEnabled: false,
  implicitFlowEnabled: false, serviceAccountsEnabled: false,
  redirectUris: [$redirect], webOrigins: [$origin]
}')

if [ -n "$EXISTING_UUID" ]; then
  echo "==> Updating existing client '${CLIENT_ID}' (${EXISTING_UUID})"
  kc_api -o /dev/null -w "update: HTTP %{http_code}\n" -X PUT \
    "${KC_BASE}/admin/realms/${REALM}/clients/${EXISTING_UUID}" -H "Content-Type: application/json" \
    -d "$CLIENT_CONFIG"
  UUID="$EXISTING_UUID"
else
  echo "==> Creating client '${CLIENT_ID}'"
  kc_api -o /dev/null -w "create: HTTP %{http_code}\n" -X POST \
    "${KC_BASE}/admin/realms/${REALM}/clients" -H "Content-Type: application/json" \
    -d "$CLIENT_CONFIG"
  UUID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id')
fi

SECRET=$(kc_api "${KC_BASE}/admin/realms/${REALM}/clients/${UUID}/client-secret" | jq -r .value)

echo "==> Client:       ${CLIENT_ID}"
echo "==> Realm:        ${REALM}"
echo "==> Redirect URI: ${REDIRECT_URI}"
echo "==> Web origin:   ${WEB_ORIGIN}"
echo "==> Secret:       ${SECRET}"
echo "==> Discovery:    ${KC_BASE/127.0.0.1/keycloak.seancohmer.com}/realms/${REALM}/.well-known/openid-configuration"
