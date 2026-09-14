# Phase 4 Runbook: Restrict Login to an AD Security Group

**Status**: ✅ Complete and verified (both ALLOW and DENY paths, live browser
login simulation) on realm `internal`, gated by AD group `AI-Users`.
**Date**: 2026-09-07

---

## What this does

Any account in the `internal` realm (synced from AD via Phase 2's LDAP
federation) can now only complete an interactive browser login if they're a
member of the `AI-Users` AD security group. This is realm-wide — it applies
to every client (Open WebUI, LiteLLM, anything else registered later), not
just one app.

Direct-access-grant (password grant, e.g. `admin-cli`) is **not** affected
by this — only the interactive browser flow. That's fine for this use case
(the AI-stack apps use browser-based OIDC login), but worth knowing if
something else relies on password-grant auth against this realm.

## Setup

```bash
./scripts/setup-group-restriction.sh \
  --realm internal \
  --groups-dn 'OU=HomelabSecurityGroups,DC=SEANCOHMER,DC=COM' \
  --group-name AI-Users \
  --role ai-stack-access
```

This is idempotent — safe to re-run after the initial setup (e.g. to point
at a different group, or after fixing something). It:
1. Adds/updates an LDAP group mapper so AD security groups sync as Keycloak
   groups (from `OU=HomelabSecurityGroups`).
2. Creates realm role `ai-stack-access` and maps it onto the `AI-Users`
   group — so any member inherits the role automatically.
3. Builds a custom copy of the `browser` flow with a conditional subflow
   that denies login if the role is missing.
4. Binds the new flow realm-wide.

Verify with `scripts/test-browser-login.sh <username> <password>` — this
simulates a **real interactive browser login** (GET the login page, extract
the form, POST credentials, check the result). This matters: a
password-grant token request (`grant_type=password` against `admin-cli`)
does **not** exercise the browser flow at all, so it can't be used to test
this restriction — it'll succeed for everyone regardless of group
membership, giving a false sense that the restriction works (or is broken)
when it's actually just not being tested.

## The two real problems hit along the way (both confirmed empirically, not guessed)

### 1. A hard Keycloak constraint: `ALTERNATIVE` can't mix with anything else at the same level

The first attempt added the conditional subflow at the **top level** of the
copied `browser` flow — as a sibling of `Cookie` / `Identity Provider
Redirector` / `forms`, all of which are `ALTERNATIVE`. This broke login
for **everyone**, not just non-members — the login form never even
appeared; Keycloak returned "Access denied" (or later, "Invalid username or
password") on the very first request.

The container logs contained the actual explanation, which the API never
surfaces:
```
WARN [org.keycloak.authentication.DefaultAuthenticationFlow] REQUIRED and
ALTERNATIVE elements at same level! Those alternative executions will be
ignored: [auth-cookie, identity-provider-redirector, null, null]
```
Keycloak silently drops every `ALTERNATIVE` execution at a level that also
contains a `REQUIRED` or `CONDITIONAL` one — it doesn't reject the config
at save time, it just breaks at request time with no useful error from the
Admin API. **If a from-scratch flow change ever seems to break login
entirely, check `docker logs keycloak` for this exact warning before
anything else.**

**Fix**: the conditional subflow goes **inside** the `forms` subflow
(sibling of `Username Password Form`, which is already `REQUIRED`, and
`Browser - Conditional 2FA`, which is already `CONDITIONAL` — proving
`REQUIRED` + `CONDITIONAL` coexist fine at one level; it's specifically
`ALTERNATIVE` that can't join them). This runs the check *after* the user
has actually authenticated, which is also the only point where checking
their roles makes sense.

### 2. `negate=true` looked broken — it wasn't; the test methodology was

First real test: pointed the condition at `nobody-has-this-role` (a name I
typed into the config, never actually created via the Roles API), with
`negate=true`. Expected: deny (user lacks the role). Actual: **allowed**.
This matches a widely-reported "Keycloak negate bug" (see e.g. [GitHub
issue #38385](https://github.com/keycloak/keycloak/issues/38385)) closely
enough that it was tempting to conclude the same thing and build an
elaborate two-branch `ALTERNATIVE` workaround to avoid `negate` entirely.

That workaround also failed (`ConditionalRoleAuthenticator` only functions
via its `matchCondition()` method, which Keycloak's engine only calls for
executions whose *direct parent flow* is typed `CONDITIONAL` — placed
inside a plain `ALTERNATIVE` branch instead, it's a no-op, so the branch
never "succeeds" even when the role matches).

Before going further down that path, tested the actual hypothesis directly:
created a **real** realm role via the Roles API (`test-decoy-role`, never
assigned to anyone), pointed the same simple structure at it with
`negate=true`, and tested again. **This correctly denied.** The original
"bug" was testing against a role name that was never created — Keycloak's
role lookup for a nonexistent name most likely short-circuits to `false`
before `negateOutput` is ever applied, which looks identical to "negate is
broken" but isn't.

**Lesson**: `negate=true` on `Condition - user role` works correctly, but
only ever test it against a role that actually exists (`GET
/admin/realms/{realm}/roles/{name}` → 200), even if unassigned.

## The final, correct structure

```
browser - AI-Users restricted        (copy of the built-in "browser" flow)
├── Cookie                            ALTERNATIVE
├── Kerberos                          DISABLED
├── Identity Provider Redirector      ALTERNATIVE
├── ...Organization                   ALTERNATIVE
└── ...forms                          ALTERNATIVE
    ├── Username Password Form        REQUIRED
    ├── ...Conditional 2FA            CONDITIONAL
    └── ai-users-check                CONDITIONAL   <- added, level 1 (not top-level)
        ├── Condition - user role     REQUIRED       (role: ai-stack-access, negate: true)
        └── Deny access               REQUIRED
```

## Another sharp edge: clearing a client's flow binding override

While testing, the flow was temporarily bound to just the `open-webui`
client (`authenticationFlowBindingOverrides.browser`) rather than
realm-wide, to avoid repeatedly breaking login for the whole realm while
iterating. Clearing that override to allow deleting/rebuilding the flow
turned out to need a specific, non-obvious value:

- Removing the `browser` key from the map: **doesn't work** — old binding
  stays in place.
- Setting the whole map to `{}`: **doesn't work** — same.
- Setting `authenticationFlowBindingOverrides.browser = ""` (empty
  **string**): **works** — confirmed via `Cannot remove authentication
  flow, it is currently in use` disappearing only after this.

`setup-group-restriction.sh` already handles this correctly.

## One more gotcha the script handles: authenticator config alias collisions

Authenticator config aliases (e.g. `require-ai-stack-access`) are unique
**per realm**, not per-flow, and are **not** cleaned up when the owning
flow/execution is deleted. Re-running a script that deletes and rebuilds
the flow each time (for idempotency) will hit a `409` on the second+ run if
it reuses a fixed alias — the orphaned config from the previous run is
still sitting there. Fixed by suffixing the alias with a timestamp on every
run; the orphaned old ones are harmless unused rows.

## Known limitation

Direct-access-grant / password-grant token requests are **not** covered by
this restriction (only the interactive browser flow is). If any app or
script authenticates via `grant_type=password` against this realm, it will
succeed regardless of group membership. None of the current apps
(Open WebUI, LiteLLM) use password grant for end-user login, so this
doesn't matter today — worth revisiting if that changes.
