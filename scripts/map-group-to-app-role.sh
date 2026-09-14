#!/bin/bash
# map-group-to-app-role.sh
#
# Maps an AD security group (already synced as a Keycloak group — see
# setup-group-restriction.sh, which sets up the LDAP group mapper) onto a
# realm role, and ensures the target client includes a "roles" claim (all
# of the user's realm roles) in its tokens so the application itself can
# read it — e.g. for OIDC-based admin-role promotion (Open WebUI's
# OAUTH_ADMIN_ROLES, LiteLLM's role claim, etc).
#
# This does NOT gate login (see setup-group-restriction.sh for that) — it's
# for mapping group membership onto an application-level permission/role
# once the user is already allowed to log in.
#
# Run on the Keycloak host (talks to https://127.0.0.1:8443).
#
# Usage:
#   ./map-group-to-app-role.sh \
#     --realm internal \
#     --group-name AI-Admins \
#     --role ai-stack-admin \
#     --client open-webui
#
# The client's "realm roles" protocol mapper is shared across every role
# mapped this way — running this again for a different --role against the
# same --client is safe and just adds another value to the same list.

set -euo pipefail

KC_BASE="https://127.0.0.1:8443"
CACERT="/opt/keycloak-docker/certs/ca-bundle.crt"
ENV_FILE="/opt/keycloak-docker/.env"

REALM=""
GROUP_NAME=""
ROLE=""
CLIENT_ID=""
CLAIM_NAME="roles"

while [ $# -gt 0 ]; do
  case "$1" in
    --realm) REALM="$2"; shift 2 ;;
    --group-name) GROUP_NAME="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --client) CLIENT_ID="$2"; shift 2 ;;
    --claim-name) CLAIM_NAME="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -z "$REALM" ] && { echo "ERROR: --realm is required." >&2; exit 1; }
[ -z "$GROUP_NAME" ] && { echo "ERROR: --group-name is required." >&2; exit 1; }
[ -z "$ROLE" ] && { echo "ERROR: --role is required." >&2; exit 1; }
[ -z "$CLIENT_ID" ] && { echo "ERROR: --client is required." >&2; exit 1; }

ADMIN_PASS=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD "$ENV_FILE" | cut -d= -f2)
TOKEN=$(curl -s --cacert "$CACERT" -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" -d "username=admin" -d "password=${ADMIN_PASS}" \
  | jq -r .access_token)
kc_api() { curl -s --cacert "$CACERT" -H "Authorization: Bearer ${TOKEN}" "$@"; }

echo "==> Ensuring realm role '${ROLE}'"
ROLE_STATUS=$(kc_api -o /dev/null -w "%{http_code}" "${KC_BASE}/admin/realms/${REALM}/roles/${ROLE}")
if [ "$ROLE_STATUS" = "404" ]; then
  kc_api -o /dev/null -w "  create: HTTP %{http_code}\n" -X POST "${KC_BASE}/admin/realms/${REALM}/roles" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${ROLE}\",\"description\":\"App-level role, gated by AD group ${GROUP_NAME}\"}"
fi

GROUP_ID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/groups" | jq -r --arg n "$GROUP_NAME" '.[] | select(.name==$n) | .id')
[ -z "$GROUP_ID" ] && { echo "ERROR: group '${GROUP_NAME}' not found — synced yet? (see setup-group-restriction.sh)" >&2; exit 1; }
ROLE_JSON=$(kc_api "${KC_BASE}/admin/realms/${REALM}/roles/${ROLE}")
echo "==> Mapping role onto group ${GROUP_NAME} (${GROUP_ID})"
kc_api -o /dev/null -w "  HTTP %{http_code}\n" -X POST \
  "${KC_BASE}/admin/realms/${REALM}/groups/${GROUP_ID}/role-mappings/realm" \
  -H "Content-Type: application/json" -d "[$ROLE_JSON]"

echo "==> Ensuring '${CLAIM_NAME}' claim (realm roles) protocol mapper on client '${CLIENT_ID}'"
CLIENT_UUID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id')
[ -z "$CLIENT_UUID" ] || [ "$CLIENT_UUID" = "null" ] && { echo "ERROR: client '${CLIENT_ID}' not found." >&2; exit 1; }
EXISTING_MAPPER=$(kc_api "${KC_BASE}/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" | jq -r --arg n "realm roles" '.[] | select(.name==$n) | .id')
MAPPER_JSON=$(jq -n --arg claim "$CLAIM_NAME" '{
  name: "realm roles", protocol: "openid-connect", protocolMapper: "oidc-usermodel-realm-role-mapper",
  config: {
    "claim.name": $claim, "jsonType.label": "String", "multivalued": "true",
    "id.token.claim": "true", "access.token.claim": "true", "userinfo.token.claim": "true"
  }
}')
if [ -n "$EXISTING_MAPPER" ]; then
  kc_api -o /dev/null -w "  update mapper: HTTP %{http_code}\n" -X PUT \
    "${KC_BASE}/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models/${EXISTING_MAPPER}" \
    -H "Content-Type: application/json" -d "$(echo "$MAPPER_JSON" | jq --arg id "$EXISTING_MAPPER" '. + {id: $id}')"
else
  kc_api -o /dev/null -w "  create mapper: HTTP %{http_code}\n" -X POST \
    "${KC_BASE}/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" \
    -H "Content-Type: application/json" -d "$MAPPER_JSON"
fi

echo "==> Done. The '${CLAIM_NAME}' claim in tokens issued to '${CLIENT_ID}' now includes ALL of the"
echo "    user's realm roles (default ones like 'offline_access' too — harmless noise for most apps"
echo "    that just check whether a specific value is present)."
echo "    Configure the app itself to read this claim (e.g. Open WebUI's OAUTH_ROLES_CLAIM/OAUTH_ADMIN_ROLES)."
