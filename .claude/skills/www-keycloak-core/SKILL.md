---
name: www-keycloak-core
description: Use when working on WWW::Keycloak — the synchronous Perl client for Keycloak's OIDC endpoints and Admin REST API, its module layout, error classes, or its tests.
---

# WWW::Keycloak core

Synchronous Perl client for Keycloak, modelled on `WWW::Zitadel` (`~/dev/p5-www-zitadel`).
Phase 1 is built (2026-10-03). Section 12 of the design lists what the real Keycloak
forced on the implementation; read it before changing any `ensure_*` method.

**The design is `docs/superpowers/specs/2026-10-02-www-keycloak-design.md`** (draft, awaiting
review). It carries the API surface, the `ensure_*` rules and a table of Admin REST calls
observed against Keycloak 26.8.0. Read the section you work in; the spec wins over this
skill.

## Module map

- `WWW::Keycloak` — facade: `base_url`, `realm`, optional credentials; lazy `oidc` and
  `admin` sub-clients sharing one `LWP::UserAgent` (injectable via `ua`).
- `WWW::Keycloak::OIDC` — discovery, JWKS, token verification, userinfo, introspection,
  token endpoint helpers, device authorization endpoint.
- `WWW::Keycloak::Admin` — Admin REST API: realms, clients, users, credentials. Direct
  methods (`list_users`, `create_client`), no nested sub-client objects.
- `WWW::Keycloak::Auth` — the admin token: logs in when one is first needed, keeps it,
  renews it shortly before it runs out (refresh token while it is valid, otherwise a
  fresh login) and forgets it when it was refused. Three ways in: username and password
  through the `admin-cli` client, a service-account client with its secret, or a fixed
  token that is used as it is and never renewed.
- `WWW::Keycloak::Diff` — compare a current object with the wanted state, without I/O.
- `WWW::Keycloak::Role::HTTP` — `build_request` and `read_response` split from sending,
  so the async twin reuses them.
- `WWW::Keycloak::Error` — base; `::Validation`, `::Network`, `::API` (with
  `http_status`, `api_message`), one package per file.

## Invariants

- **Shape follows `WWW::Zitadel`.** Same facade, same error hierarchy, same test layout
  (`t/00-load.t`, construction, one file per concern, mocked HTTP, opt-in live suite).
- **Sync/async twin.** `Net::Async::Keycloak` (`~/dev/p5-net-async-keycloak`) mirrors the
  public API with `_f` suffixes returning Futures. This repo leads; an API change here is
  incomplete until the twin has a ticket for it.
- **Keycloak facts are verified, not remembered.** Endpoint paths, payload shapes and
  claim contents differ between Keycloak versions. Before encoding one, check the
  documentation of the targeted version or a running instance, and say which version in
  the POD.
- **The realm is part of the address.** OIDC lives under the realm's issuer; the Admin
  API is addressed per realm. Do not hide the realm in a global.
- **Live tests are opt-in** (`KEYCLOAK_LIVE_TEST=1 KEYCLOAK_URL=…`) and create and remove
  their own throwaway realm. A default `prove -lr t` passes with them skipped.

## Key files

- `lib/WWW/Keycloak.pm` — facade, the lazy `oidc` / `admin` accessors, one shared UA
- `lib/WWW/Keycloak/OIDC.pm` — the OIDC side: discovery, JWKS, token, userinfo, device
- `lib/WWW/Keycloak/Admin.pm` — the Admin side: realms, clients, scopes, mappers, users,
  the `ensure_*` methods
- `lib/WWW/Keycloak/Auth.pm` — the admin token: login, renewal, invalidation
- `lib/WWW/Keycloak/Diff.pm` — the comparison without I/O
- `lib/WWW/Keycloak/Role/HTTP.pm` — `build_request` / `read_response` / `send_request`
- `lib/WWW/Keycloak/Error.pm`, `lib/WWW/Keycloak/Error/{Validation,Network,API}.pm`
- `t/lib/FakeKeycloak.pm` — the in-memory Keycloak (see below)
- `t/keycloak/k8s.yaml` — a Keycloak for Kubernetes to run the live suite against
- `docs/superpowers/specs/2026-10-02-www-keycloak-design.md` — the design, with the
  observed Admin REST calls
- `docs/superpowers/plans/2026-10-03-www-keycloak-phase-1.md` — the plan

## Test layout

| File | Covers |
|---|---|
| `t/00-load.t` | `all_uses_ok` over the `WWW::Keycloak` namespace |
| `t/10-diff.t` | `Diff` — comparison without I/O |
| `t/20-errors.t` | the error classes and the fields they carry |
| `t/30-auth.t` | the admin token — login, renewal, invalidation |
| `t/31-auth-no-token.t` | the paths that work without a token |
| `t/40-facade.t` | the facade — lazy sub-clients, one shared UA |
| `t/50-admin.t` | the Admin REST API — realms, clients, users |
| `t/51-admin-ensure.t` | the `ensure_*` methods — `{ object, changed }` |
| `t/60-oidc.t` | discovery, JWKS, userinfo, introspection, token |
| `t/90-live-keycloak.t` | the live suite — off unless the env vars are set |
| `t/cpanfile.t` | every module used in `lib/` and `t/` is declared in the `cpanfile` |

`t/lib/FakeKeycloak.pm` is an in-memory stand-in for the parts of Keycloak 26 that the
client talks to, answering the way the real one was observed to answer: 201 with a
`Location` header and no body on a create, 409 with `errorMessage` for a duplicate, 404
with `error` for something missing, 401 for a token it does not know, and masked values
when an authenticator configuration is read. The test files load it themselves with
`use lib 't/lib'`.

The live suite needs `KEYCLOAK_LIVE_TEST=1` and `KEYCLOAK_URL`; `KEYCLOAK_ADMIN` and
`KEYCLOAK_ADMIN_PASSWORD` name the admin it logs in as (both default to `admin`).

## Hazards

- **The live suite talks to a real identity system.** `t/90-live-keycloak.t` skips unless
  `KEYCLOAK_LIVE_TEST=1` and `KEYCLOAK_URL` are set. It creates its own throwaway realm
  and deletes it again at the end; an aborted run leaves the realm behind on the instance.
- **`prove` must be recursive** (`prove -lr t`). A non-recursive run (`prove -l t/`) only
  picks up `t/*.t` — a test that lands in a subdirectory later is silently skipped and
  the run still reports green.
- **A duplicate is 409, not 400.** The Admin API answers a second `create_client`,
  `create_user` or `create_realm` with 409 and an `errorMessage`; `is_conflict` in
  `WWW::Keycloak::Error::API` is the predicate for it. The basic operations are not
  repeatable — that is the point of the `ensure_*` methods.
- **Passwords and secrets never appear in an exception.** `Auth` catches them in the
  error it throws — keep it that way when you add a login path.
- **The realm belongs in the URL.** `Admin` builds `/admin/realms/<realm>` from the
  facade's `realm` attribute; a hidden realm in a global breaks every Admin call.

## Purpose beyond the client

This dist is the basis for an automatic Keycloak setup (realm, clients, users from Perl)
and gives `Airlock` (`~/dev/p5-airlock`) a real Keycloak to be tested against. Airlock
does not depend on this dist at runtime.
