# Phase 1 Runbook: Keycloak + PostgreSQL Deployment

**Status**: ✅ Complete and verified
**Date**: 2026-09-06
**Target host (test env)**: `192.168.10.81` (`keycloak.seancohmer.com`), Rocky Linux 10.2

This covers deployment steps only. LDAPS user federation (Phase 2) is not yet
started — it needs real LDAP/AD server details, which haven't been provided.

---

## Decisions made (and why)

| Decision | Choice | Reason |
|---|---|---|
| Container engine | **Docker Compose** (not Podman) | Both engines were present on the host; user chose Docker to match the compose file already sketched in CLAUDE.md verbatim. |
| Image sourcing | **Pulled directly** from quay.io/docker.io | This test box has internet access, unlike the real air-gapped target. Steps below are written so the "pull → save → transfer → load" substitution for a real disconnected host is a straight swap (see "Air-gapped substitution" section). |
| Keycloak version | `quay.io/keycloak/keycloak:26.4.0` (pinned, not `:latest`) | Reproducibility — CLAUDE.md's own reasoning for using containers at all (immutable, reproducible snapshots) argues against floating `:latest`. |
| Postgres version | `postgres:16-alpine` (CLAUDE.md sketch said `:15`) | 16 is the current supported LTS-track version compatible with Keycloak 26; alpine keeps the image small for transfer to an air-gapped host. |
| Admin bootstrap env vars | `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` (not `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` from the CLAUDE.md sketch) | The old vars are deprecated as of Keycloak 26 (still work with a warning, but the new ones are correct going forward). |
| Hostname config | `KC_HOSTNAME=https://<host>:8443` (single combined value) | Keycloak 26 "hostname v2" syntax. Using the old split `KC_HOSTNAME` + `KC_HOSTNAME_PORT` (as in the CLAUDE.md sketch) triggers a `Hostname v1 options` deprecation warning at startup. |
| Management interface scheme | `KC_HTTP_MANAGEMENT_SCHEME: http` | Health/metrics (port 9000) default to inheriting HTTPS. Since port 9000 is never published to the host (container-internal only), plain HTTP there is safe and lets the healthcheck avoid needing a TLS client inside the container image (which has neither `curl` nor `openssl`). |
| Container healthcheck | `bash /dev/tcp` raw HTTP GET | The official Keycloak image (26.x) ships no `curl`/`wget`/`openssl` — only `bash`. This is the same workaround Keycloak's own docs use. |
| TLS certs | **ADCS-issued**, via `certs/adcs-request-cert.sh` (originally self-signed via `certs/generate-certs.sh` during initial bring-up) | A real ADCS server (`dc01.seancohmer.com`) is available. Cut over 2026-09-06 — see the "Switching to ADCS-signed certificates" section below for the full story, including an IIS Extended Protection issue that had to be fixed on the CA first. |
| Reverse proxy | None yet | CLAUDE.md's nginx example is deferred until Phase 3 (client app integration); Keycloak currently terminates TLS itself on 8443 directly. |

---

## Steps performed

### 1. Surveyed the target host
```bash
ssh admin@192.168.10.81
cat /etc/os-release          # Rocky Linux 10.2
nproc; free -h; df -h /      # 4 vCPU / 16GB RAM / 35GB free
which podman docker          # both present
systemctl is-active docker   # active
docker compose version       # v5.5.1 plugin present
getenforce                   # Enforcing
systemctl is-active firewalld # active
```
Found a **pre-existing bare-metal Keycloak 26.7.3 tarball distribution** at
`/opt/keycloak` (owned by a `keycloak` system user, part of the VM template).
Confirmed it was inert — no systemd unit, no running process, no listening
ports, empty config, and `docker ps -a` was empty. Left it untouched and
built the container stack in a separate directory (`/opt/keycloak-docker`) to
avoid any confusion between the two.

### 2. Created the deployment directory
```bash
sudo mkdir -p /opt/keycloak-docker/certs
sudo chown -R admin:admin /opt/keycloak-docker
```

### 3. Generated the internal CA and Keycloak TLS certificate
Copied `certs/generate-certs.sh` (in this repo) to the host and ran:
```bash
cd /opt/keycloak-docker
./certs/generate-certs.sh keycloak.seancohmer.com 192.168.10.81
```
This produces (in `certs/`):
- `ca.key` / `ca.crt` — internal root CA (10-year validity)
- `keycloak-tls.key` / `keycloak-tls.crt` — leaf cert for Keycloak (825-day
  validity), SAN covers the DNS hostname, `localhost`, `127.0.0.1`, and the
  host's LAN IP
- `ca-bundle.crt` — copy of `ca.crt`, named for the trust-bundle mount point

Verified the SAN:
```bash
openssl x509 -in certs/keycloak-tls.crt -noout -text | grep -A1 'Subject Alternative Name'
# DNS:keycloak.seancohmer.com, DNS:localhost, IP:127.0.0.1, IP:192.168.10.81
```

**Real deployment**: replace this script's output with certs issued by the
actual internal CA/PKI, keeping the same three file names so the compose
file needs no changes.

### 4. Generated secrets
```bash
cd /opt/keycloak-docker
PG_PASS=$(openssl rand -base64 24)
ADMIN_PASS=$(openssl rand -base64 18)
cat > .env <<EOF
POSTGRES_PASSWORD=${PG_PASS}
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=${ADMIN_PASS}
KC_HOSTNAME=keycloak.seancohmer.com
EOF
chmod 600 .env
```
`.env` never leaves the host and is not checked into this repo — see
`.env.example` here for the variable names it needs.

### 5. Opened the firewall
```bash
sudo firewall-cmd --permanent --add-port=8443/tcp
sudo firewall-cmd --reload
```

### 6. Deployed the stack
Copied `docker-compose.yml` (in this repo) to `/opt/keycloak-docker/` and:
```bash
cd /opt/keycloak-docker
sudo docker compose up -d
```
Docker pulled `quay.io/keycloak/keycloak:26.4.0` and `postgres:16-alpine`
from quay.io/docker.io (see "Air-gapped substitution" below for the
disconnected-environment equivalent), created the network/volume, started
Postgres, waited for its healthcheck, then started Keycloak.

### 7. Verified

| Check | Result |
|---|---|
| Both containers report `healthy` | ✅ `docker ps` |
| No `Hostname v1` deprecation warning | ✅ clean logs |
| TLS handshake on 8443 serves our cert | ✅ subject=CN=keycloak.seancohmer.com, issuer=CN=Internal Test Lab Root CA |
| OIDC discovery endpoint | ✅ `GET /realms/master/.well-known/openid-configuration` → 200, correct issuer URL |
| Admin bootstrap credentials work | ✅ password grant against `/realms/master/protocol/openid-connect/token` with `client_id=admin-cli` returned an `access_token` |
| Reachable from outside the host (LAN, through firewalld) | ✅ `curl -k https://192.168.10.81:8443/...` → 200 |

---

## Access

- **Admin console**: `https://keycloak.seancohmer.com:8443/admin/` (add a
  `hosts` entry or DNS record for `keycloak.seancohmer.com` → `192.168.10.81`
  on any machine that needs to reach it by name; by IP it will fail Keycloak's
  strict hostname check since the console redirects to the configured
  hostname)
- **Username**: `admin`
- **Password**: generated into `/opt/keycloak-docker/.env` on the host
  (`KC_BOOTSTRAP_ADMIN_PASSWORD`) — not reproduced in this repo. Retrieve
  with `sudo grep KC_BOOTSTRAP_ADMIN_PASSWORD /opt/keycloak-docker/.env` on
  the host, or rotate it via the admin console once logged in.
- Trust the CA (`certs/ca.crt`) in your browser/OS to avoid a self-signed
  warning, or accept the browser exception for now (test environment only).

---

## Air-gapped substitution (for the real deployment)

Everything above works unchanged on a disconnected host except step 6's
image acquisition. Replace the `docker compose up -d` pull with:

```bash
# On an internet-connected staging system:
docker pull quay.io/keycloak/keycloak:26.4.0
docker pull postgres:16-alpine
docker save quay.io/keycloak/keycloak:26.4.0 -o keycloak-26.4.0.tar
docker save postgres:16-alpine -o postgres-16-alpine.tar
# Transfer both tarballs across the air gap (approved media / internal registry)

# On the air-gapped target:
docker load -i keycloak-26.4.0.tar
docker load -i postgres-16-alpine.tar
cd /opt/keycloak-docker
docker compose up -d   # will use the already-loaded images, no pull needed
```
Or push both images to an internal registry (Nexus/Harbor) reachable from
the air-gapped network and change the `image:` lines in `docker-compose.yml`
to reference that registry instead.

---

## Switching to ADCS-signed certificates

`certs/adcs-request-cert.sh` generates a key + CSR (with SANs for whatever
DNS names/IPs you give it), submits it to a Microsoft ADCS server's Web
Enrollment site (`/certsrv`), and retrieves the signed cert plus CA chain —
writing `keycloak-tls.key`, `keycloak-tls.crt`, and `ca-bundle.crt`, the same
names `generate-certs.sh` produces, so no other file needs to change.

```bash
./certs/adcs-request-cert.sh \
  --cn keycloak.internal.domain \
  --dns localhost \
  --ip 192.168.10.81,127.0.0.1 \
  --ca-server <ADCS-hostname-or-IP> \
  --template WebServer \
  --auth ntlm --user 'DOMAIN\svc-keycloak-enroll' \
  --scheme https --insecure   # --insecure only until the CA web site's own
                               # cert is trusted; drop it once it is
```
Run with no flags for an interactive prompt walkthrough instead. If the
template requires manager approval, the script prints the request ID and the
exact command to re-run later once it's approved.

After swapping in ADCS-signed certs:
```bash
cd /opt/keycloak-docker
sudo docker compose restart keycloak
```

**Status: done.** Tested and cut over against the real ADCS server
`dc01.seancohmer.com` on 2026-09-06. Keycloak now serves a cert issued by
`CN=SEANCOHMER-DC01-CA` (template `WebServer`, ReqID 24, valid 2 years,
SANs `keycloak` / `keycloak.seancohmer.com` / `192.168.10.81` / `127.0.0.1`)
instead of the self-signed one. Verified: TLS handshake, OIDC discovery,
admin bootstrap login, and full chain validation against `ca-bundle.crt`
with no `-k` — all still pass post-cutover. The original self-signed
key/cert are kept at `certs/selfsigned-backup/` on the host (not deleted).

`certs/ca-bundle.crt` now holds `SEANCOHMER-DC01-CA` instead of the old
self-signed CA — this is also very likely the CA that will end up signing
the AD/LDAP server's cert for Phase 2, so this file may already be the
correct LDAPS trust bundle once that's confirmed.

#### Troubleshooting hit along the way: `Extended Protection` on `CertSrv`

Both NTLM and Kerberos/Negotiate auth against `/certsrv/` initially failed
with a fresh 401 on every attempt, **despite verified-correct credentials**
(confirmed via a successful LDAP simple bind and a successful Kerberos TGT +
service-ticket acquisition for `HTTP/dc01.seancohmer.com`). The IIS log
(`C:\inetpub\logs\LogFiles\W3SVC1\`) showed `sc-win32-status` `3221226331` =
`0xC000035B` = `STATUS_BAD_BINDINGS` — a channel-binding (Extended
Protection for Authentication) rejection, not a credentials problem.

Root cause: the ADCS Web Enrollment role installer bakes an **explicit,
locked** `extendedProtection.tokenChecking = Required` directly onto the
`CertSrv` IIS application in `applicationHost.config` — a `<location>`-level
override, not inherited from the server default. Setting the value at the
IIS server root (`IIS:\`) does nothing for `CertSrv` specifically, since its
own explicit value takes precedence and the section is locked against
override at that path.

Fix (on the CA, elevated PowerShell):
```powershell
& "$env:windir\system32\inetsrv\appcmd.exe" unlock config -section:system.webServer/security/authentication/windowsAuthentication

Set-WebConfigurationProperty -Filter '/system.webServer/security/authentication/windowsAuthentication' `
  -Name extendedProtection.tokenChecking -Value None -PSPath 'IIS:\Sites\Default Web Site\CertSrv'

iisreset
```
Curl/GSSAPI on Linux doesn't send the SSPI channel-binding token IIS wants
when Extended Protection is `Required`, so this needs to be relaxed at the
`CertSrv` location specifically for a non-Windows client to enroll this way.
**If this same ADCS role is freshly installed in the air-gapped environment,
expect to hit this exact issue again** — apply the same fix there.

## Next steps (not started)

1. **LDAPS federation** — needs: LDAP/AD server hostname or IP, LDAPS port
   (assumed 636), bind DN + service account credentials, user search base,
   and the LDAP server's CA cert (or its own self-signed cert) to add to the
   trust bundle. Ask the user for these before proceeding.
2. Register a test realm and OIDC client once LDAP federation is confirmed
   working, to validate the full SSO flow end-to-end.
3. Reverse proxy (nginx/haproxy) in front of Keycloak, if desired, per
   CLAUDE.md's example — currently deferred since Keycloak terminates TLS
   itself.
