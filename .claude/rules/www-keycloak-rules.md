# WWW-Keycloak House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Perl client for Keycloak identity management (OIDC + Admin REST API). Read first: the callers
and the sibling module (`WWW::Keycloak::OIDC` ↔ `WWW::Keycloak::Admin`).

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `www-keycloak-worker` (default) |
| Write/extend tests | `www-keycloak-test-writer` |
| Write/maintain POD | `www-keycloak-doc-writer` |
| Commits, `Changes`, card → done, pre-release audit | `www-keycloak-release-manager` |
| Read-only research, audit, gap analysis | `www-keycloak-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, the public API (`WWW::Keycloak`, `::OIDC`, `::Admin`),
the sync/async sibling invariant, error handling, tests, performance. Pure prose docs and
`Changes` notes are not.

## Hazards

- **Live tests hit a real Keycloak.** Opt-in via `KEYCLOAK_LIVE_TEST=1 KEYCLOAK_URL=…`, off by
  default. Never run them uncontrolled or fanned out; a default `prove -lr t` must pass with
  them skipped.
- **Admin calls change a real identity system.** Realm, client and user mutations are not
  test fixtures on a shared instance; live tests create and remove their own throwaway realm.
- **Sync/async twin.** `p5-net-async-keycloak` mirrors this repo's public API with `_f`
  suffixes and Futures. An API change here is incomplete until the twin matches — ticket the
  twin, never edit it.
- **Keycloak facts come from a running instance or its documentation,** never from memory.
  Endpoint paths and claim contents differ between versions.
- **Test runner trap.** Plain `prove -l t/` is non-recursive; always use `prove -lr t` so
  subdir tests are never silently skipped.

## Perl specifics — reference, don't restate

Module loading, Moo patterns, dependency pinning, `[@Author::GETTY]` release metadata, POD
directives and house style live in skills `getty-perl-core`, `getty-perl-moo`,
`perl-release-dist-ini`, `getty-perl-release-author-getty` and `www-keycloak-core`
(force-loaded for `www-keycloak-*` agents).
