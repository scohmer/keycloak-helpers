#!/bin/bash
# setup-ldap-federation.sh
#
# Configures LDAP (Active Directory) user federation on a Keycloak realm via
# the Admin REST API: creates the realm if needed, creates/updates the LDAP
# component, validates the connection and bind, triggers a full user sync,
# and lists what came in. Run this on the Keycloak host itself (it talks to
# https://127.0.0.1:8443).
#
# Usage:
#   LDAP_BIND_PASSWORD='...' ./setup-ldap-federation.sh \
#     --realm internal \
#     --ldap-url ldaps://dc01.seancohmer.com:636 \
#     --bind-dn 'CN=ldap read,OU=Service Accounts,OU=HomelabUsers,DC=SEANCOHMER,DC=COM' \
#     --search-base 'OU=HomelabUsers,DC=SEANCOHMER,DC=COM'
#
# Requires: KC_TRUSTSTORE_PATHS configured on the Keycloak container pointing
# at a file containing the LDAP server's CA cert (see docker-compose.yml) —
# without it, the connection test fails with SSLHandshakeFailed even though
# the cert chain validates fine from curl/openssl directly.

set -euo pipefail

KC_BASE="https://127.0.0.1:8443"
CACERT="/opt/keycloak-docker/certs/ca-bundle.crt"
ENV_FILE="/opt/keycloak-docker/.env"
COMPONENT_NAME="AD - Federation"
VENDOR="ad"
USERNAME_ATTR="sAMAccountName"
RDN_ATTR="cn"
UUID_ATTR="objectGUID"
OBJECT_CLASSES="person, organizationalPerson, user"
EDIT_MODE="READ_ONLY"

REALM=""
LDAP_URL=""
BIND_DN=""
SEARCH_BASE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --realm) REALM="$2"; shift 2 ;;
    --ldap-url) LDAP_URL="$2"; shift 2 ;;
    --bind-dn) BIND_DN="$2"; shift 2 ;;
    --search-base) SEARCH_BASE="$2"; shift 2 ;;
    --component-name) COMPONENT_NAME="$2"; shift 2 ;;
    --cacert) CACERT="$2"; shift 2 ;;
    -h|--help) echo "See header comment for usage."; exit 1 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for v in REALM LDAP_URL BIND_DN SEARCH_BASE; do
  [ -z "${!v}" ] && { echo "ERROR: --${v,,} is required." >&2; exit 1; }
done
if [ -z "${LDAP_BIND_PASSWORD:-}" ]; then
  read -r -s -p "LDAP bind password for ${BIND_DN}: " LDAP_BIND_PASSWORD; echo
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

echo "==> Getting admin token"
ADMIN_PASS=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD "$ENV_FILE" | cut -d= -f2)
TOKEN=$(curl -s --cacert "$CACERT" -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" -d "username=admin" -d "password=${ADMIN_PASS}" \
  | jq -r .access_token)
[ -z "$TOKEN" ] || [ "$TOKEN" = "null" ] && { echo "ERROR: failed to get admin token" >&2; exit 1; }

kc_api() { curl -s --cacert "$CACERT" -H "Authorization: Bearer ${TOKEN}" "$@"; }

echo "==> Ensuring realm '${REALM}' exists"
STATUS=$(kc_api -o /dev/null -w "%{http_code}" "${KC_BASE}/admin/realms/${REALM}")
if [ "$STATUS" = "404" ]; then
  kc_api -o /dev/null -w "create realm: HTTP %{http_code}\n" \
    -X POST "${KC_BASE}/admin/realms" -H "Content-Type: application/json" \
    -d "{\"realm\": \"${REALM}\", \"enabled\": true}"
fi
REALM_ID=$(kc_api "${KC_BASE}/admin/realms/${REALM}" | jq -r .id)

echo "==> Building LDAP component config"
LDAP_CONFIG=$(jq -n \
  --arg name "$COMPONENT_NAME" --arg parentId "$REALM_ID" --arg vendor "$VENDOR" \
  --arg usernameAttr "$USERNAME_ATTR" --arg rdnAttr "$RDN_ATTR" --arg uuidAttr "$UUID_ATTR" \
  --arg objectClasses "$OBJECT_CLASSES" --arg url "$LDAP_URL" --arg usersDn "$SEARCH_BASE" \
  --arg bindDn "$BIND_DN" --arg bindCred "$LDAP_BIND_PASSWORD" --arg editMode "$EDIT_MODE" \
  '{
    name: $name, providerId: "ldap", providerType: "org.keycloak.storage.UserStorageProvider",
    parentId: $parentId,
    config: {
      enabled: ["true"], priority: ["0"], fullSyncPeriod: ["-1"], changedSyncPeriod: ["-1"],
      cachePolicy: ["DEFAULT"], batchSizeForSync: ["1000"], editMode: [$editMode],
      importEnabled: ["true"], syncRegistrations: ["false"], vendor: [$vendor],
      usernameLDAPAttribute: [$usernameAttr], rdnLDAPAttribute: [$rdnAttr], uuidLDAPAttribute: [$uuidAttr],
      userObjectClasses: [$objectClasses], connectionUrl: [$url], usersDn: [$usersDn],
      authType: ["simple"], bindDn: [$bindDn], bindCredential: [$bindCred],
      searchScope: ["2"], useTruststoreSpi: ["ldapsOnly"], connectionPooling: ["true"],
      pagination: ["true"], allowKerberosAuthentication: ["false"], debug: ["false"]
    }
  }')

EXISTING_ID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/components?parent=${REALM_ID}&type=org.keycloak.storage.UserStorageProvider" \
  | jq -r --arg name "$COMPONENT_NAME" '.[] | select(.name==$name) | .id')

if [ -n "$EXISTING_ID" ]; then
  echo "==> Updating existing component ${EXISTING_ID}"
  kc_api -o /dev/null -w "update: HTTP %{http_code}\n" -X PUT \
    "${KC_BASE}/admin/realms/${REALM}/components/${EXISTING_ID}" -H "Content-Type: application/json" \
    -d "$(echo "$LDAP_CONFIG" | jq --arg id "$EXISTING_ID" '. + {id: $id}')"
  COMPONENT_ID="$EXISTING_ID"
else
  echo "==> Creating LDAP component"
  HEADERS=$(mktemp)
  kc_api -D "$HEADERS" -o /dev/null -w "create: HTTP %{http_code}\n" -X POST \
    "${KC_BASE}/admin/realms/${REALM}/components" -H "Content-Type: application/json" -d "$LDAP_CONFIG"
  COMPONENT_ID=$(grep -i "^location:" "$HEADERS" | sed 's#.*/##' | tr -d '\r')
  rm -f "$HEADERS"
fi
echo "==> Component id: ${COMPONENT_ID}"

test_ldap() { # test_ldap <action>
  kc_api -X POST "${KC_BASE}/admin/realms/${REALM}/testLDAPConnection" -H "Content-Type: application/json" \
    -d "$(jq -n --arg a "$1" --arg url "$LDAP_URL" --arg bindDn "$BIND_DN" --arg cred "$LDAP_BIND_PASSWORD" \
      --arg cid "$COMPONENT_ID" '{action:$a, connectionUrl:$url, bindDn:$bindDn, bindCredential:$cred, useTruststoreSpi:"ldapsOnly", componentId:$cid}')" \
    -w "\n${1}: HTTP %{http_code}\n"
}

echo "==> Testing connection"
test_ldap testConnection
echo "==> Testing bind authentication"
test_ldap testAuthentication

echo "==> Triggering full user sync"
kc_api -X POST "${KC_BASE}/admin/realms/${REALM}/user-storage/${COMPONENT_ID}/sync?action=triggerFullSync" \
  -w "\nHTTP %{http_code}\n"

echo "==> Imported users"
kc_api "${KC_BASE}/admin/realms/${REALM}/users?max=100" \
  | jq -r '.[] | "  \(.username) | \(.email // "no-email") | \(.firstName) \(.lastName)"'
