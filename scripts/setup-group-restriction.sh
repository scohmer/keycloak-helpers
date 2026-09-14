#!/bin/bash
# setup-group-restriction.sh
#
# Restricts login on a Keycloak realm to members of a specific AD security
# group, end to end:
#   1. Adds/updates an LDAP group mapper so AD security groups sync into
#      Keycloak groups.
#   2. Creates a realm role and maps it onto the target Keycloak group (so
#      group members inherit the role).
#   3. Builds a custom browser authentication flow (copy of "browser") with
#      a conditional subflow that denies login if the user lacks that role.
#   4. Binds the new flow as the realm's default browser flow.
#
# Run on the Keycloak host (talks to https://127.0.0.1:8443).
#
# Usage:
#   ./setup-group-restriction.sh \
#     --realm internal \
#     --groups-dn 'OU=HomelabSecurityGroups,DC=SEANCOHMER,DC=COM' \
#     --group-name AI-Users \
#     --role ai-stack-access
#
# IMPORTANT — a real, confirmed Keycloak bug (as of 26.4.0) and how this
# script works around one variant of it:
#
#   "Condition - user role" with "Negate output" DOES work correctly, but
#   only when checked against a role that actually exists as a real realm
#   role. If you test it against a role name that was never created via the
#   Roles API, matchCondition() appears to short-circuit to `false`
#   regardless of the negate setting — which looks exactly like "negate is
#   broken" but isn't. (Confirmed empirically: negate correctly denied a
#   user lacking a real, unassigned decoy role; it did NOT correctly deny
#   the same user when checked against a role name that was never created.)
#   Moral: if this restriction ever seems to let everyone through, first
#   confirm the configured role name is a REAL role (`GET
#   /admin/realms/{realm}/roles/{name}` should be 200, not 404) before
#   suspecting Keycloak itself.
#
#   Separately — a real, hard Keycloak constraint (not a bug, just easy to
#   trip over): an ALTERNATIVE-requirement execution cannot coexist at the
#   same level as a REQUIRED or CONDITIONAL one — Keycloak silently ignores
#   the ALTERNATIVE ones and the whole flow evaluation breaks (visible only
#   in the container logs: "REQUIRED and ALTERNATIVE elements at same
#   level!"). This is why the conditional subflow below gets added as a
#   sibling of "Username Password Form" (REQUIRED) INSIDE the "forms"
#   subflow, not at the flow's top level (where Cookie/IdP-redirector/forms
#   are all ALTERNATIVE siblings of each other).
#
# Also note: clearing a client's authenticationFlowBindingOverrides entry
# requires setting the value to an empty STRING, not removing the key or
# setting the whole map to {} — both of those leave the old binding in
# place (confirmed empirically), which then blocks deleting/rebuilding the
# flow ("Cannot remove authentication flow, it is currently in use").

set -euo pipefail

KC_BASE="https://127.0.0.1:8443"
CACERT="/opt/keycloak-docker/certs/ca-bundle.crt"
ENV_FILE="/opt/keycloak-docker/.env"

REALM=""
GROUPS_DN=""
GROUP_NAME=""
ROLE=""
FLOW_NAME=""
BIND_MODE="realm"   # realm | client
CLIENT_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --realm) REALM="$2"; shift 2 ;;
    --groups-dn) GROUPS_DN="$2"; shift 2 ;;
    --group-name) GROUP_NAME="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --flow-name) FLOW_NAME="$2"; shift 2 ;;
    --bind-client) BIND_MODE="client"; CLIENT_ID="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -z "$REALM" ] && { echo "ERROR: --realm is required." >&2; exit 1; }
[ -z "$GROUPS_DN" ] && { echo "ERROR: --groups-dn is required." >&2; exit 1; }
[ -z "$GROUP_NAME" ] && { echo "ERROR: --group-name is required." >&2; exit 1; }
[ -z "$ROLE" ] && { echo "ERROR: --role is required." >&2; exit 1; }
FLOW_NAME="${FLOW_NAME:-browser - ${GROUP_NAME} restricted}"
SUBFLOW="${GROUP_NAME,,}-check"

ADMIN_PASS=$(grep KC_BOOTSTRAP_ADMIN_PASSWORD "$ENV_FILE" | cut -d= -f2)
TOKEN=$(curl -s --cacert "$CACERT" -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" -d "username=admin" -d "password=${ADMIN_PASS}" \
  | jq -r .access_token)
kc_api() { curl -s --cacert "$CACERT" -H "Authorization: Bearer ${TOKEN}" "$@"; }
enc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"; }

# ---------------------------------------------------------------------------
# 1. LDAP group mapper
# ---------------------------------------------------------------------------
echo "==> Ensuring LDAP group mapper (groups DN: ${GROUPS_DN})"
LDAP_COMPONENT_ID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider" | jq -r '.[0].id')
EXISTING_GM=$(kc_api "${KC_BASE}/admin/realms/${REALM}/components?parent=${LDAP_COMPONENT_ID}&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
  | jq -r '.[] | select(.name=="groups") | .id')
GROUP_MAPPER=$(jq -n --arg parentId "$LDAP_COMPONENT_ID" --arg dn "$GROUPS_DN" '{
  name: "groups", providerId: "group-ldap-mapper",
  providerType: "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
  parentId: $parentId,
  config: {
    "groups.dn": [$dn], "group.name.ldap.attribute": ["cn"], "group.object.classes": ["group"],
    "preserve.group.inheritance": ["true"], "membership.ldap.attribute": ["member"],
    "membership.attribute.type": ["DN"], "membership.user.ldap.attribute": ["cn"],
    "groups.ldap.filter": [""], "mode": ["READ_ONLY"],
    "user.roles.retrieve.strategy": ["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"],
    "mapped.group.attributes": [""], "drop.non.existing.groups.during.sync": ["false"]
  }
}')
if [ -n "$EXISTING_GM" ]; then
  kc_api -o /dev/null -w "  update group mapper: HTTP %{http_code}\n" -X PUT \
    "${KC_BASE}/admin/realms/${REALM}/components/${EXISTING_GM}" -H "Content-Type: application/json" \
    -d "$(echo "$GROUP_MAPPER" | jq --arg id "$EXISTING_GM" '. + {id: $id}')"
else
  kc_api -o /dev/null -w "  create group mapper: HTTP %{http_code}\n" -X POST \
    "${KC_BASE}/admin/realms/${REALM}/components" -H "Content-Type: application/json" -d "$GROUP_MAPPER"
fi

echo "==> Syncing to pull in groups"
kc_api -X POST "${KC_BASE}/admin/realms/${REALM}/user-storage/${LDAP_COMPONENT_ID}/sync?action=triggerFullSync" \
  -o /dev/null -w "  HTTP %{http_code}\n"

# ---------------------------------------------------------------------------
# 2. Realm role, mapped onto the group
# ---------------------------------------------------------------------------
echo "==> Ensuring realm role '${ROLE}'"
ROLE_STATUS=$(kc_api -o /dev/null -w "%{http_code}" "${KC_BASE}/admin/realms/${REALM}/roles/${ROLE}")
if [ "$ROLE_STATUS" = "404" ]; then
  kc_api -o /dev/null -w "  create role: HTTP %{http_code}\n" -X POST \
    "${KC_BASE}/admin/realms/${REALM}/roles" -H "Content-Type: application/json" \
    -d "{\"name\":\"${ROLE}\",\"description\":\"Grants login access, gated by AD group ${GROUP_NAME}\"}"
fi

GROUP_ID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/groups" | jq -r --arg n "$GROUP_NAME" '.[] | select(.name==$n) | .id')
[ -z "$GROUP_ID" ] && { echo "ERROR: group '${GROUP_NAME}' not found after sync — does it exist in AD under ${GROUPS_DN}?" >&2; exit 1; }
ROLE_JSON=$(kc_api "${KC_BASE}/admin/realms/${REALM}/roles/${ROLE}")
echo "==> Mapping role onto group ${GROUP_NAME} (${GROUP_ID})"
kc_api -o /dev/null -w "  HTTP %{http_code}\n" -X POST \
  "${KC_BASE}/admin/realms/${REALM}/groups/${GROUP_ID}/role-mappings/realm" \
  -H "Content-Type: application/json" -d "[$ROLE_JSON]"

# ---------------------------------------------------------------------------
# 3. Browser flow: copy "browser", add conditional deny inside "forms"
# ---------------------------------------------------------------------------
echo "==> Clearing any stale client-level override for '${FLOW_NAME}' (empty string, not {} — see header note)"
for CID in $(kc_api "${KC_BASE}/admin/realms/${REALM}/clients" | jq -r '.[].id'); do
  CJSON=$(kc_api "${KC_BASE}/admin/realms/${REALM}/clients/${CID}")
  if [ "$(echo "$CJSON" | jq -r '.authenticationFlowBindingOverrides.browser // empty')" != "" ]; then
    kc_api -o /dev/null -w "  unbind $(echo "$CJSON" | jq -r .clientId): HTTP %{http_code}\n" -X PUT \
      "${KC_BASE}/admin/realms/${REALM}/clients/${CID}" -H "Content-Type: application/json" \
      -d "$(echo "$CJSON" | jq '.authenticationFlowBindingOverrides.browser = ""')"
  fi
done
REALM_JSON=$(kc_api "${KC_BASE}/admin/realms/${REALM}")
if [ "$(echo "$REALM_JSON" | jq -r '.browserFlow')" = "$FLOW_NAME" ]; then
  kc_api -o /dev/null -w "  unbind realm: HTTP %{http_code}\n" -X PUT "${KC_BASE}/admin/realms/${REALM}" \
    -H "Content-Type: application/json" -d "$(echo "$REALM_JSON" | jq '.browserFlow = "browser"')"
fi

echo "==> (Re)building flow '${FLOW_NAME}'"
EXISTS=$(kc_api "${KC_BASE}/admin/realms/${REALM}/authentication/flows" | jq -r --arg n "$FLOW_NAME" '.[] | select(.alias==$n) | .id')
[ -n "$EXISTS" ] && kc_api -o /dev/null -w "  delete old: HTTP %{http_code}\n" -X DELETE "${KC_BASE}/admin/realms/${REALM}/authentication/flows/${EXISTS}"
kc_api -o /dev/null -w "  copy 'browser': HTTP %{http_code}\n" -X POST \
  "${KC_BASE}/admin/realms/${REALM}/authentication/flows/browser/copy" \
  -H "Content-Type: application/json" -d "{\"newName\": \"${FLOW_NAME}\"}"

FORMS_ALIAS="${FLOW_NAME} forms"
kc_api -o /dev/null -w "  add conditional subflow (inside forms, NOT top-level): HTTP %{http_code}\n" -X POST \
  "${KC_BASE}/admin/realms/${REALM}/authentication/flows/$(enc "$FORMS_ALIAS")/executions/flow" \
  -H "Content-Type: application/json" \
  -d "{\"alias\": \"${SUBFLOW}\", \"description\": \"Deny login if user lacks ${ROLE}\", \"type\": \"basic-flow\"}"
kc_api -o /dev/null -w "  add condition: HTTP %{http_code}\n" -X POST \
  "${KC_BASE}/admin/realms/${REALM}/authentication/flows/${SUBFLOW}/executions/execution" \
  -H "Content-Type: application/json" -d '{"provider": "conditional-user-role"}'
kc_api -o /dev/null -w "  add deny: HTTP %{http_code}\n" -X POST \
  "${KC_BASE}/admin/realms/${REALM}/authentication/flows/${SUBFLOW}/executions/execution" \
  -H "Content-Type: application/json" -d '{"provider": "deny-access-authenticator"}'

EXECUTIONS=$(kc_api "${KC_BASE}/admin/realms/${REALM}/authentication/flows/$(enc "$FLOW_NAME")/executions")
SUBFLOW_EXEC_ID=$(echo "$EXECUTIONS" | jq -r --arg n "$SUBFLOW" '.[] | select(.displayName==$n) | .id')
CONDITION_EXEC_ID=$(echo "$EXECUTIONS" | jq -r '.[] | select(.providerId=="conditional-user-role") | .id')
DENY_EXEC_ID=$(echo "$EXECUTIONS" | jq -r '.[] | select(.providerId=="deny-access-authenticator") | .id')

declare -A REQ=( ["$SUBFLOW_EXEC_ID"]="CONDITIONAL" ["$CONDITION_EXEC_ID"]="REQUIRED" ["$DENY_EXEC_ID"]="REQUIRED" )
for EID in "$SUBFLOW_EXEC_ID" "$CONDITION_EXEC_ID" "$DENY_EXEC_ID"; do
  EXEC_OBJ=$(echo "$EXECUTIONS" | jq --arg id "$EID" '.[] | select(.id==$id)')
  UPDATED=$(echo "$EXEC_OBJ" | jq --arg r "${REQ[$EID]}" '.requirement = $r')
  kc_api -o /dev/null -w "  set ${REQ[$EID]}: HTTP %{http_code}\n" -X PUT \
    "${KC_BASE}/admin/realms/${REALM}/authentication/flows/$(enc "$FLOW_NAME")/executions" \
    -H "Content-Type: application/json" -d "$UPDATED"
done

echo "==> Configuring condition (role=${ROLE}, negate=true)"
# Authenticator config aliases are unique PER REALM (not per-flow) and are
# NOT cleaned up when the owning flow/execution is deleted — confirmed
# empirically: re-running this script with a fixed alias like
# "require-${ROLE}" collides (409) with the orphaned config left behind by
# the previous run's now-deleted flow. Suffix with a timestamp so every run
# gets a fresh alias; the orphaned old ones are harmless unused rows.
CONFIG_ALIAS="require-${ROLE}-$(date +%s)"
kc_api -o /dev/null -w "  HTTP %{http_code}\n" -X POST \
  "${KC_BASE}/admin/realms/${REALM}/authentication/executions/${CONDITION_EXEC_ID}/config" \
  -H "Content-Type: application/json" \
  -d "{\"alias\": \"${CONFIG_ALIAS}\", \"config\": {\"condUserRole\": \"${ROLE}\", \"negate\": \"true\"}}"

# ---------------------------------------------------------------------------
# 4. Bind
# ---------------------------------------------------------------------------
if [ "$BIND_MODE" = "client" ]; then
  echo "==> Binding to client '${CLIENT_ID}' only"
  FLOW_ID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/authentication/flows" | jq -r --arg n "$FLOW_NAME" '.[] | select(.alias==$n) | .id')
  CLIENT_UUID=$(kc_api "${KC_BASE}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id')
  CLIENT_JSON=$(kc_api "${KC_BASE}/admin/realms/${REALM}/clients/${CLIENT_UUID}")
  kc_api -o /dev/null -w "  HTTP %{http_code}\n" -X PUT \
    "${KC_BASE}/admin/realms/${REALM}/clients/${CLIENT_UUID}" -H "Content-Type: application/json" \
    -d "$(echo "$CLIENT_JSON" | jq --arg fid "$FLOW_ID" '.authenticationFlowBindingOverrides.browser = $fid')"
else
  echo "==> Binding realm-wide as the default browser flow"
  REALM_JSON=$(kc_api "${KC_BASE}/admin/realms/${REALM}")
  kc_api -o /dev/null -w "  HTTP %{http_code}\n" -X PUT "${KC_BASE}/admin/realms/${REALM}" \
    -H "Content-Type: application/json" -d "$(echo "$REALM_JSON" | jq --arg f "$FLOW_NAME" '.browserFlow = $f')"
fi

echo "==> Done. Verify with a real login attempt — both a member and (if possible) a non-member of ${GROUP_NAME}."
