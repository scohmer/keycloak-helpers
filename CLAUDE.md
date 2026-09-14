# Keycloak Air-Gapped LDAPS SSO Deployment

## Project Overview

Deploying Keycloak as a centralized identity provider in a disconnected (air-gapped) environment to provide single sign-on via LDAPS integration with existing Active Directory/LDAP infrastructure. Applications within the disconnected network will authenticate users through Keycloak instead of directly against AD. I am currently working in a test environment with a machine that i want to run keycloak on. I'd like you to deploy keycloak on that machine as part of this project and document step-by-step what we do so that I can reproduce the outcome in an air-gapped environment. The credentials to connect to that machine are Username: admin Password: Pa$$w0rd -- we can use those credentials to connect. The machine is on a local network IPv4 address: 192.168.10.81 and we can connect to it via SSH.

**Environment**: Air-gapped network, STIG-hardened, no internet access, self-signed certificates only

---

## Architecture Decisions

### Deployment Method: Container-Based (Podman/Docker)
- **Reasoning**: Reproducibility critical in disconnected environments; container images are immutable snapshots; enables HA/clustering if needed later
- **Alternative considered**: tar.gz deployment—rejected due to complexity in maintenance, scaling, and dependency management
- **Database**: PostgreSQL (containerized), not H2 (single-file DB insufficient for enterprise)

### LDAPS Protocol
- **Port**: 636 (LDAP over TLS)
- **Certificate**: Self-signed or internal CA; Keycloak configured to trust internal CA bundle
- **Service Account**: Read-only LDAP bind account for user sync and queries
- **Direction**: One-way authentication only (Keycloak → LDAP; no LDAP → Keycloak callbacks)

### SSO Flow: OpenID Connect
- **Rationale**: Modern standard, better for application integration, JWT validation entirely local
- **Alternative**: SAML available but heavier-weight
- **Token Validation**: Keycloak public key cached client-side; no external validation calls needed

---

## Pre-Deployment Checklist

### Image Staging
- [ ] Pull `quay.io/keycloak/keycloak:latest` (or pin specific version) on internet-connected system
- [ ] Pull `postgres:15` (or target version)
- [ ] Load both images into internal container registry (Nexus/Harbor/etc.)
- [ ] Verify images can be pulled from internal registry in disconnected environment

### Certificates & PKI
- [ ] Generate or obtain internal CA certificate for self-signed certs
- [ ] Create certificate for Keycloak server (hostname: keycloak.internal.domain)
- [ ] Create certificate for LDAP server (if self-signed; otherwise obtain from existing PKI)
- [ ] Export CA cert bundle for Keycloak to trust LDAP connection
- [ ] Export Keycloak cert + key for TLS termination (nginx/haproxy reverse proxy)

### LDAP/AD Preparation
- [ ] Identify LDAP server(s) and LDAPS port (typically 636)
- [ ] Create read-only service account in AD for Keycloak bind
  - Account name: `svc-keycloak-ldap` or similar
  - Permissions: Read user objects, group membership (no write needed)
  - Password: Strong, stored securely (will be in Keycloak config)
- [ ] Identify LDAP search base (e.g., `cn=users,dc=company,dc=internal`)
- [ ] Map LDAP object classes to Keycloak attributes:
  - User object class: `person` or `inetOrgPerson`
  - User unique ID: `uid` or `sAMAccountName`
  - Email attribute: `mail`
  - Full name: `cn` or `displayName`

### Network & Connectivity
- [ ] Ensure Keycloak container network can reach LDAP server on port 636
- [ ] Plan DNS resolution (internal DNS or /etc/hosts entries)
- [ ] Verify NTP sync across all systems (critical for JWT validation; max 5min skew tolerance)
- [ ] Plan reverse proxy (nginx/haproxy) for external HTTPS access to Keycloak

### Persistent Storage
- [ ] Prepare PostgreSQL data volume (persistent, not ephemeral)
- [ ] Plan backup strategy for PostgreSQL (no cloud options available)
- [ ] Prepare Keycloak config volume for custom realm/client configs

---

## Deployment Steps

### 1. Prepare docker-compose.yml

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15
    container_name: keycloak-db
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: <SECURE_PASSWORD>
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - keycloak-network
    restart: unless-stopped

  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: keycloak
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: <SECURE_PASSWORD>
      KC_HOSTNAME: keycloak.internal.domain
      KC_HTTPS_CERTIFICATE_FILE: /etc/x509/https/tls.crt
      KC_HTTPS_CERTIFICATE_KEY_FILE: /etc/x509/https/tls.key
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: <SECURE_PASSWORD>
      # Disable automatic schema migration if managing separately
      # KC_DB_SCHEMA: public
    volumes:
      - ./certs/keycloak-tls.crt:/etc/x509/https/tls.crt:ro
      - ./certs/keycloak-tls.key:/etc/x509/https/tls.key:ro
      - ./certs/ca-bundle.crt:/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem:ro
    depends_on:
      - postgres
    networks:
      - keycloak-network
    restart: unless-stopped
    ports:
      - "8443:8443"

volumes:
  postgres_data:

networks:
  keycloak-network:
    driver: bridge
```

### 2. Configure LDAPS User Federation

**In Keycloak UI**:
1. Create new Realm (or use default `master` if testing)
2. Navigate to **Realm Settings → User Federation**
3. Add provider → **LDAP**
4. Fill in connection details:
   - **Console Display Name**: `LDAP - Active Directory`
   - **LDAP URL**: `ldaps://ldap.internal.domain:636`
   - **Enable StartTLS**: No (using ldaps:// directly)
   - **Use Truststore SPI**: Enable (if using custom CA bundle)
   - **Connection Pooling**: Enable
   - **Bind DN**: `cn=svc-keycloak-ldap,cn=users,dc=company,dc=internal`
   - **Bind Credential**: [password for service account]
   - **User Object Classes**: `inetOrgPerson`
   - **User Search Base**: `cn=users,dc=company,dc=internal`
   - **Username LDAP attribute**: `uid` (or `sAMAccountName` for AD)
   - **RDN LDAP attribute**: `uid`
   - **UUID LDAP attribute**: `objectGUID` (for AD)
   - **Import Users**: ON

5. **Mappers** (map LDAP attributes to Keycloak):
   - Add mapper: `email` → LDAP attribute `mail`
   - Add mapper: `firstName` → LDAP attribute `givenName`
   - Add mapper: `lastName` → LDAP attribute `sn`
   - Add mapper: `fullName` → LDAP attribute `displayName`

### 3. Configure Client Application for SSO

For each application needing SSO:

1. **Create Client**:
   - Realm → Clients → Create
   - Client ID: `myapp-oidc`
   - Client Type: OpenID Connect
   - Name: `My Application`

2. **Capability Config**:
   - Standard Flow Enabled: ON
   - Direct Access Grants: OFF (unless legacy apps need password flow)
   - Implicit Flow: OFF (use auth code flow)

3. **Access Settings**:
   - Valid Redirect URIs: `https://myapp.internal.domain/callback`
   - Valid Post Logout Redirect URIs: `https://myapp.internal.domain/`
   - Web Origins: `https://myapp.internal.domain`

4. **Credentials** (for confidential clients):
   - Go to **Credentials** tab
   - Copy Client Secret (store securely in app config)

5. **Generate Metadata/JWKS**:
   - Keycloak exposes OpenID metadata at:
     ```
     https://keycloak.internal.domain/realms/{realm-name}/.well-known/openid-configuration
     ```
   - JWKS (public keys) available at:
     ```
     https://keycloak.internal.domain/realms/{realm-name}/protocol/openid-connect/certs
     ```

---

## Configuration Specifics

### LDAPS Certificate Trust

**Option A: System Certificate Store**
Place internal CA certificate in Keycloak container:
```bash
COPY ./certs/ca-bundle.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
```
Keycloak (Java) will automatically trust it.

**Option B: Keycloak-Specific Truststore**
Generate PKCS#12 truststore:
```bash
keytool -import -alias ldap-ca -file ca.crt -keystore truststore.p12 \
  -storetype PKCS12 -storepass changeit -noprompt
```
Mount in container and reference via `KC_TRUSTSTORE_PATHS`.

### Clock Skew Tolerance

Critical in disconnected environments. Configure:
```yaml
# In docker-compose environment
KC_SPI_OPENID_CONNECT_TOKEN_MANAGER_DEFAULT_TOKEN_EXPIRATION_SECONDS: 300
KC_SPI_OPENID_CONNECT_TOKEN_MANAGER_DEFAULT_ACCESS_TOKEN_LIFESPAN: 600
```

Ensure NTP is running on all systems (max 5-minute skew before JWT validation fails).

### Reverse Proxy Configuration (nginx example)

```nginx
server {
    listen 443 ssl http2;
    server_name keycloak.internal.domain;

    ssl_certificate /etc/nginx/certs/keycloak-tls.crt;
    ssl_certificate_key /etc/nginx/certs/keycloak-tls.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass https://keycloak:8443;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_verify off;  # Trust self-signed cert from Keycloak container
    }
}
```

---

## Troubleshooting

### LDAPS Connection Failures

**Symptom**: "Could not connect to LDAP server"

1. Verify connectivity from Keycloak container:
   ```bash
   docker exec keycloak openssl s_client -connect ldap.internal.domain:636 -showcerts
   ```

2. Check certificate trust:
   - Ensure CA bundle mounted in container
   - Verify LDAP server cert is signed by trusted CA

3. Review Keycloak logs:
   ```bash
   docker logs keycloak | grep -i ldap
   ```

### User Sync Issues

**Symptom**: LDAP users not appearing in Keycloak

1. Test LDAP bind credentials manually
2. Verify search base and object classes match your LDAP structure
3. Check attribute mappings (email, firstName, etc.)
4. Manual sync: Realm → User Federation → LDAP → Sync Users

### JWT Validation Failures

**Symptom**: Applications report "invalid token" despite successful login

1. Check clock sync across all systems:
   ```bash
   ntpstat
   ```

2. Verify token expiration hasn't passed:
   ```bash
   # Decode JWT at jwt.io (internal air-gapped? use offline tool)
   ```

3. Ensure application has Keycloak's public key (JWKS endpoint accessible)

### Certificate Issues

**Symptom**: HTTPS errors, "self-signed certificate not trusted"

1. Export CA certificate used to sign both Keycloak and LDAP certs
2. Ensure all applications have CA in their trust store
3. For testing: Temporarily disable cert verification (NOT for production)

---

## Security Hardening Notes

- **LDAP Bind Account**: Read-only, no AD admin privileges
- **Keycloak Admin Console**: Restrict access by IP/network
- **HTTPS Only**: No HTTP fallback in production
- **Password Policies**: Configure in Keycloak Realm → Security
- **Session Timeouts**: Set appropriate inactivity timeouts
- **Audit Logging**: Enable in Realm Events configuration
- **Backup**: Regular encrypted backups of PostgreSQL data

---

## Key References

- **Keycloak Docs**: https://www.keycloak.org/documentation
- **LDAP User Federation**: https://www.keycloak.org/docs/latest/server_admin/#_ldap
- **Container Deployment**: https://www.keycloak.org/server/containers
- **OpenID Connect**: https://openid.net/specs/openid-connect-core-1_0.html

---

## Status

**Current Phase**: Phases 1–4 all complete and verified on the test host
`192.168.10.81` (`keycloak.seancohmer.com`), against AD/CA server
`dc01.seancohmer.com`. Runbooks:
[`docs/01-keycloak-deployment.md`](docs/01-keycloak-deployment.md),
[`docs/02-ldap-federation.md`](docs/02-ldap-federation.md),
[`docs/03-oidc-client-registration.md`](docs/03-oidc-client-registration.md),
[`docs/04-group-based-access-restriction.md`](docs/04-group-based-access-restriction.md).
All deployment, federation, client-registration, and access-restriction
scripts live alongside this file in the same repo, and are mirrored onto
the Keycloak VM itself at `/opt/keycloak-docker/` (docs included) so the VM
is self-documenting.

Realm-wide login restriction is live: only members of AD security group
`AI-Users` (`OU=HomelabSecurityGroups`) can complete an interactive browser
login against the `internal` realm — enforced via a custom copy of the
`browser` authentication flow with a conditional deny, gated on realm role
`ai-stack-access` (auto-inherited via `AI-Users` group membership). Verified
both directions with a real simulated browser login
(`scripts/test-browser-login.sh`), not just password-grant (which doesn't
exercise this restriction at all — see `docs/04-group-based-access-restriction.md`'s
"Known limitation"). Getting this right took real trial and error —
that doc also covers two confirmed Keycloak gotchas worth knowing before
touching authentication flows again: `ALTERNATIVE` executions can't mix
with `REQUIRED`/`CONDITIONAL` ones at the same flow level (breaks silently,
only visible in container logs), and `negate=true` on `Condition - user
role` only appears broken when tested against a role name that was never
actually created.

On top of the login gate, a second AD group (`AI-Admins`) now maps to
Open WebUI's own internal `admin` role (not just Keycloak login access) —
via realm role `ai-stack-admin`, a "realm roles" protocol mapper on the
`open-webui` client (adds a `roles` claim to its tokens), and Open WebUI's
own `OAUTH_ADMIN_ROLES` env var. Reusable script:
`scripts/map-group-to-app-role.sh` (generic — maps any AD group to any
realm role and exposes it in any client's token, for whatever
application-level permission a future app needs, not just "admin").
Verified against Open WebUI's own API (`GET /api/v1/auths/` →
`"role": "admin"`) after a complete real login, not just inferred from the
Keycloak side.

A real OIDC client (Open WebUI, on a separate AI-stack host,
`192.168.10.121`) has been registered against the `internal` realm and
**verified working end-to-end with a live browser SSO login** as `scohmer`.
A second client (LiteLLM Admin UI, same host) is registered and documented
but not yet tested live. Along the way, fixed a real gap: AD's `mail`
attribute is empty on every synced user, so the realm's `email` mapper now
sources `userPrincipalName` instead (see
`docs/02-ldap-federation.md` §6) — this fix benefits any future OIDC client
against this realm, not just Open WebUI.

**Next Steps**:
1. ~~Stage container images to internal registry~~ — pulled directly on this
   internet-connected test box; air-gapped substitution steps documented in
   `docs/01-keycloak-deployment.md`.
2. ~~Generate TLS certificates for Keycloak~~ — done, cut over to a real
   ADCS-issued cert from `dc01.seancohmer.com` (`certs/adcs-request-cert.sh`).
3. ~~Get LDAP/AD server details~~ — done: `dc01.seancohmer.com:636`, bind
   account `ldapread` (pre-existing service account), search base
   `OU=HomelabUsers,DC=SEANCOHMER,DC=COM`.
4. ~~Deploy PostgreSQL and Keycloak containers~~ — done, both healthy.
5. ~~Configure LDAPS user federation~~ — done via
   `scripts/setup-ldap-federation.sh`. 11 AD users imported into the new
   `internal` realm; verified a real AD user (`scohmer`) can authenticate
   through Keycloak with their actual AD password (live pass-through, not
   cached). Hit and fixed one real issue: `KC_TRUSTSTORE_PATHS` must be set
   explicitly — mounting the CA bundle into the system trust-extraction path
   alone is not enough for the JVM's outbound LDAPS connections.
6. Register first test application client (not started)
7. Verify SSO flow end-to-end via a real OIDC client + browser login (not
   started — so far only tested via direct password-grant against
   `admin-cli`)
8. Revisit whether `OU=Service Accounts` (holding `ldapread` and
   `svc_Certificates`) should be excluded from the user search base, since
   currently those service accounts are also regular SSO-capable Keycloak
   users — user's explicit choice for now, flagged for later review.
