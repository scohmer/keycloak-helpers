# Phase 3 Runbook: Registering OIDC Clients

**Status**: ✅ Working pattern established; two real clients registered and
one (Open WebUI) verified end-to-end with a live browser login.
**Date**: 2026-09-06

This covers registering applications as OIDC clients against the `internal`
realm (the LDAP-backed realm from Phase 2), using `scripts/register-oidc-client.sh`.

---

## The script

```bash
./scripts/register-oidc-client.sh --realm internal --client-id <app-name> \
  --redirect-uri 'https://<app-host>:<port>/<callback-path>' \
  --web-origin 'https://<app-host>:<port>'
```

Creates (or updates, idempotently) a confidential client — standard flow
enabled, direct access grants and implicit flow off, no service account —
and prints the generated client secret plus the realm's discovery URL.
Run it on the Keycloak host (talks to `https://127.0.0.1:8443`).

**The redirect URI is app-specific** — it's whatever callback path that
app's own OIDC library expects, not something Keycloak dictates. Check the
app's own docs for this before registering; getting it wrong is the single
most common OIDC integration failure (see "Lessons learned" below).

## Clients registered so far

| Client ID | App | Redirect URI | Registered |
|---|---|---|---|
| `open-webui` | Open WebUI (on the separate `/var/ai` AI-stack host, `192.168.10.121`) | `https://192.168.10.121:8443/oauth/oidc/callback` | ✅, verified with a real browser login as `scohmer` |
| `litellm` | LiteLLM Proxy Admin UI (same AI-stack host) | `https://192.168.10.121:8443/litellm/sso/callback` | ✅ registered, integration steps written, not yet tested live |

Client secrets are **not** recorded in this repo — see the AI-stack
project's own `oidc-open-webui/secrets.env` and `oidc-litellm/secrets.env`
(on the `192.168.10.121` host, not this one) for those. Re-run the register
script and read its output again if a secret needs recovering; it's
retrievable via the Admin REST API's `/clients/{id}/client-secret` endpoint
at any time, not just at creation.

## Lessons learned from the real Open WebUI integration

These apply to registering **any** new OIDC client against this realm, not
just Open WebUI — worth checking each one for the next app:

1. **`email` claim may be missing** — see `docs/02-ldap-federation.md` §6.
   Any client that requires an `email` claim (many do, for account
   matching) will fail with a claim-missing error, not an auth failure,
   if this hasn't been accounted for. Already fixed at the realm level
   (email mapper now sources `userPrincipalName`), so this should no
   longer bite new clients — but worth knowing why, if something similar
   crops up with a different missing claim.
2. **Client-side CA trust for outbound calls to Keycloak** — if the client
   app is Python-based (or anything else that ships its own CA bundle
   rather than using the OS trust store), it needs the ADCS CA
   (`SEANCOHMER-DC01-CA`, in this project's own `certs/ca-bundle.crt`)
   added to *its* trust store, not just the host's. This bit Open WebUI and
   LiteLLM both — see their integration docs on the AI-stack host for the
   specific fix (mounting a combined CA bundle over the app's bundled
   `certifi` store).
3. **A typo in an env var name fails silently** — Open WebUI's SSO button
   simply didn't appear (no error) because `OAUTH_CLIENT_ID` had been
   typo'd as `OATH_CLIENT_ID` in the consuming app's compose file. If a
   client integration "does nothing" rather than erroring, check the
   client app's actual running environment (`docker exec <container> env`)
   against what it expects — don't assume a compose file edit landed
   correctly.
4. **Reverse proxies must preserve the port in the `Host` header** — nginx's
   `$host` variable strips a non-default port; use `$http_host` instead.
   Otherwise a client app that builds absolute redirect/error URLs from the
   incoming `Host` header will drop the port, producing broken links to the
   wrong port (e.g. bare `:443` when everything actually runs on `:8443`).
   This is a client-side/proxy-side fix, not a Keycloak-side one, but worth
   checking for every new app sitting behind a reverse proxy on a
   non-standard port.
5. **A one-off `mismatching_state` CSRF error** occurred once during
   testing and did not recur on retry — most likely a stale browser cookie
   from an earlier attempt. Not chased further since it wasn't
   reproducible; worth keeping in mind if it recurs.

## Mapping AD groups to application-level roles (not just login access)

Login access is gated realm-wide by `docs/04-group-based-access-restriction.md`
(the `AI-Users` group). Separately, `scripts/map-group-to-app-role.sh` maps
any AD group onto a realm role AND exposes it in a specific client's tokens
via a `roles` claim (a "realm roles" protocol mapper) — for
application-level permissions once a user is already allowed to log in.
First real use: `AI-Admins` → realm role `ai-stack-admin` → Open WebUI's
`OAUTH_ADMIN_ROLES`, promoting members to Open WebUI's own internal admin
role. Verified via Open WebUI's own API (`GET /api/v1/auths/` returning
`"role": "admin"`) after a real login, not just inferred Keycloak-side.
Reusable for any future app/role pairing (`--client`, `--group-name`,
`--role` are all parameters).

## Next steps (not started)

1. Verify LiteLLM's SSO integration live (registered, documented, untested).
2. Decide whether `OU=Service Accounts` should be excluded from the LDAP
   search base — currently `ldapread`/`svc_certificates` can also SSO into
   any client using this realm (see `docs/02-ldap-federation.md`).
