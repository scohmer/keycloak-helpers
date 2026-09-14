# Phase 2 Runbook: LDAPS User Federation

**Status**: ✅ Complete and verified
**Date**: 2026-09-06
**LDAP/AD server**: `dc01.seancohmer.com` (192.168.10.5), LDAPS port 636 — same
host as the ADCS CA from Phase 1.

---

## Decisions made

| Decision | Choice | Reason |
|---|---|---|
| Realm | New realm `internal`, not `master` | `master` is Keycloak's own administrative realm — federating end-user auth into it is a well-known anti-pattern. LDAP-backed applications should live in a dedicated realm. |
| Bind account | Existing `CN=ldap read,OU=Service Accounts,OU=HomelabUsers,DC=SEANCOHMER,DC=COM` (`sAMAccountName: ldapread`) | Already provisioned for this exact purpose — no need to create a new service account. |
| Search base | `OU=HomelabUsers,DC=SEANCOHMER,DC=COM` (subtree), no exclusion filter | User's explicit choice: sync everything under this OU, including the `Service Accounts` and `Administrators` sub-OUs. Note this means `ldapread` and `svc_Certificates` themselves show up as regular importable Keycloak users, capable of SSO login into any app using this realm — revisit with a filter (e.g. excluding `OU=Service Accounts`) if that's not desired later. |
| Edit mode | `READ_ONLY` | Matches CLAUDE.md's "one-way authentication only" principle — Keycloak never writes back to AD. |
| Username/RDN/UUID attributes | `sAMAccountName` / `cn` / `objectGUID` | Standard AD mapping (CLAUDE.md's own checklist already specified this). |
| LDAPS trust | `KC_TRUSTSTORE_PATHS` pointed at `ca-bundle.crt` | See "Troubleshooting" below — the system CA trust-extraction mount (Option A from CLAUDE.md's own certificate-trust guidance) is **not** sufficient on its own; the JVM needs an explicit truststore path. |
| Config method | Admin REST API via script, not the web UI | Matches the project's reproducibility goal — every step is scripted (`scripts/setup-ldap-federation.sh`) rather than manual clicks that can't be replayed identically in the air-gapped environment. |

---

## Steps performed

### 1. Discovered directory structure (read-only)
Queried the AD schema's PKI templates container and the domain's OU
structure via `ldapsearch` (installed via `dnf install openldap-clients`)
to find the real certificate template name, the actual user OUs, and the
pre-existing LDAP service account — see commands in this repo's session
history / the CLAUDE.md status log. Key finding: real user/service accounts
live under `OU=HomelabUsers`, not the default `CN=Users` container (which
only holds the built-in `Administrator`/`Guest`/`krbtgt` accounts).

### 2. Verified the bind account directly over LDAPS
```bash
ldapsearch -x -H ldaps://dc01.seancohmer.com:636 \
  -D "CN=ldap read,OU=Service Accounts,OU=HomelabUsers,DC=seancohmer,DC=com" \
  -W -b "OU=HomelabUsers,DC=seancohmer,DC=com" "(sAMAccountName=scohmer)" dn
```
Confirmed before touching Keycloak at all — isolates "is this a credentials
problem" from "is this a Keycloak config problem."

### 3. Fixed LDAPS trust for outbound connections from Keycloak
Initial `testLDAPConnection` calls failed with `SSLHandshakeFailed`, even
though `curl`/`openssl` from the host (and even from inside the container)
trusted the chain fine with `--cacert ca-bundle.crt`. CLAUDE.md's own
guidance ("Option A: System Certificate Store... Keycloak (Java) will
automatically trust it") turned out not to hold for this image/version —
mounting the CA bundle at
`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` alone is not picked up
by the JVM for the LDAP federation SPI.

**Fix**: added to `docker-compose.yml`:
```yaml
environment:
  KC_TRUSTSTORE_PATHS: /etc/x509/ca/ca-bundle.crt
volumes:
  - ./certs/ca-bundle.crt:/etc/x509/ca/ca-bundle.crt:ro,Z
```
then `docker compose up -d` to recreate the container. After this,
`testLDAPConnection` (both `testConnection` and `testAuthentication`
actions) returned `204`.

### 4. Ran the federation setup script
```bash
LDAP_BIND_PASSWORD='<ldapread password>' ./scripts/setup-ldap-federation.sh \
  --realm internal \
  --ldap-url ldaps://dc01.seancohmer.com:636 \
  --bind-dn 'CN=ldap read,OU=Service Accounts,OU=HomelabUsers,DC=SEANCOHMER,DC=COM' \
  --search-base 'OU=HomelabUsers,DC=SEANCOHMER,DC=COM'
```
This creates the `internal` realm (if missing), creates/updates the LDAP
`UserStorageProvider` component via the Admin REST API, runs
`testConnection` + `testAuthentication`, triggers a full sync, and lists
the resulting users. It's idempotent — safe to re-run; a second run updates
the existing component and re-syncs rather than duplicating anything.

### 5. Verified

| Check | Result |
|---|---|
| `testConnection` | ✅ HTTP 204 |
| `testAuthentication` (service account bind) | ✅ HTTP 204 |
| Full sync | ✅ 11 users imported, 0 failed |
| Attribute mapping (firstName/lastName from `givenName`/`sn`) | ✅ correct for every user |
| Email attribute | Fixed — see below |
| **Real pass-through authentication** — an actual AD user's own password, validated live against AD (not cached) | ✅ `scohmer` successfully obtained an OIDC access token from `https://.../realms/internal/protocol/openid-connect/token` using their real AD password |

### 6. Fixed the email attribute (found via a real client integration)

Initially `email` came back `None` for every user — confirmed via direct
LDAP query that AD's `mail` attribute simply isn't populated on any of
these accounts. This surfaced as a real, concrete failure once an actual
OIDC client (Open WebUI) was wired up: its login flow requires an `email`
claim and rejected every login with `OAuth callback failed, email is
missing`, visible in the client's own logs.

**Fix**: `userPrincipalName` *is* populated on every account, already in
email-shaped form (`username@SEANCOHMER.COM`) — confirmed via LDAP query
across all 11 users. Repointed the `email` mapper's `ldap.attribute` from
`mail` to `userPrincipalName` and re-triggered a full sync:

```bash
# Find the email mapper's component id under the LDAP provider:
curl -s --cacert "$CACERT" -H "Authorization: Bearer $TOKEN" \
  "$KC_BASE/admin/realms/internal/components?parent=<ldap-component-id>&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
  | jq -r '.[] | "\(.id) | \(.name) | \(.config["ldap.attribute"][0] // "n/a")"'
# -> ... | email | mail

# Patch it to use userPrincipalName instead, then PUT it back:
curl -s --cacert "$CACERT" -H "Authorization: Bearer $TOKEN" \
  "$KC_BASE/admin/realms/internal/components/<mapper-id>" \
  | jq '.config["ldap.attribute"] = ["userPrincipalName"]' \
  | curl -s --cacert "$CACERT" -X PUT "$KC_BASE/admin/realms/internal/components/<mapper-id>" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d @-

# Re-sync so existing imported users pick up the new mapping:
curl -s --cacert "$CACERT" -X POST \
  "$KC_BASE/admin/realms/internal/user-storage/<ldap-component-id>/sync?action=triggerFullSync" \
  -H "Authorization: Bearer $TOKEN"
```
All 11 users now have a real email (`scohmer@seancohmer.com`, etc.).
**If AD's `mail` attribute ever gets populated for real going forward**,
consider switching back to `mail` (more semantically correct) or leave
`userPrincipalName` as-is — either works fine as long as it stays populated.

The last check is the one that actually matters: it proves Keycloak is
delegating credential validation to AD in real time, not just mirroring a
one-time import.

---

## Air-gapped notes

- `openldap-clients` and `jq` (both used for diagnostics/scripting here)
  need to be staged into the internal package repo/mirror for the
  disconnected environment — same idea as the container images from Phase 1.
- The `KC_TRUSTSTORE_PATHS` finding applies regardless of environment — it's
  a Keycloak/JVM behavior, not something specific to this test network.

---

## Next steps (not started)

1. Consider filtering `OU=Service Accounts` out of the search base or
   adding a Keycloak group/role restriction, if service accounts becoming
   SSO-login-capable Keycloak users is not actually desired long-term.
2. Register a test OIDC client in the `internal` realm and verify a full
   browser-based login flow (not just direct password-grant against
   `admin-cli`), per CLAUDE.md's client registration steps.
3. Reverse proxy in front of Keycloak, if still desired.
