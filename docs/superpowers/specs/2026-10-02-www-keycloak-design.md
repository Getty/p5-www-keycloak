# WWW::Keycloak – Design

Date: 2026-10-02
Status: approved on 2026-10-03; the decisions from section 11 have been made.
Distribution: `WWW-Keycloak` (repo `p5-www-keycloak`), CPAN-ready, `[@Author::GETTY]`
Twin: `Net-Async-Keycloak` (repo `p5-net-async-keycloak`), follows this design with `_f` methods.

## 1. What WWW::Keycloak is

**WWW::Keycloak is the Perl client for Keycloak: OIDC against a realm and the
Admin REST API, with which you bring a realm into a desired state from Perl.**

The second part is the real reason for the dist. A Keycloak clicked together by hand in
the admin console is not repeatable. The trigger was concrete: for Keycloak to report in
the token whether a second factor was used, a realm needs a protocol mapper and reference
values on four steps of two authentication flows. Today that lives as an 80-line script
with raw `HTTP::Tiny` in `p5-airlock/t/keycloak/setup.pl`. With this dist it should look
like this:

```perl
my $kc = WWW::Keycloak->new(
  base_url => 'http://pichu.cihq:30523',
  realm    => 'airlock-test',
  username => 'admin',
  password => 'admin',
);

$kc->admin->ensure_execution_config(
  flow          => 'browser',
  authenticator => 'auth-otp-form',
  config        => { 'default.reference.value' => 'otp', 'default.reference.maxAge' => 3600 },
);
```

### What WWW::Keycloak is not

- **Not a deployment tool.** Starting Keycloak, database, ingress, certificates belong to
  the cluster (OCP). This dist talks to a Keycloak that is already running.
- **Not a replacement for the realm import.** What can be imported and never changes
  again may still be imported as JSON. The dist is for what comes after and has to be
  repeatable.
- **Not a browser.** Clicking through login pages is not part of the API (the Airlock live
  test does that for itself).
- **No complete coverage of the Admin API in phase 1.** Roles, groups, identity providers,
  events and user federation come when they are needed.

## 2. Structure

```
WWW::Keycloak                   facade: base_url, realm, credentials, ua
  ├─ ->oidc    WWW::Keycloak::OIDC     discovery, JWKS, verify token, fetch token
  ├─ ->admin   WWW::Keycloak::Admin    Admin REST API of the realm
  └─ ->for_realm('x')                  the same facade for another realm

WWW::Keycloak::Auth             fetch admin token, renew, retry once on 401
WWW::Keycloak::Error            ::Validation, ::Network, ::API (one package per file)
```

Shape and names follow `WWW::Zitadel`: Moo, one class per concern, one shared
`LWP::UserAgent` instance (injectable via `ua`), direct methods instead of nested
sub-clients (`$admin->list_users`, not `$admin->users->list`).

Two things are different in Keycloak than in Zitadel and shape the structure:

1. **The realm is part of the address.** OIDC lives under `<base_url>/realms/<realm>`, the
   Admin API under `<base_url>/admin/realms/<realm>`. The realm is therefore a
   required attribute of the facade, not a parameter of every method. `->for_realm('other')`
   returns a second facade with the same `ua` and the same login.
2. **Admin tokens are short-lived.** There is no personal access token. The admin token
   comes from an OIDC login and expires after a short time (a new realm has
   `accessTokenLifespan` 300 seconds). The dist has to renew it
   itself (section 4).

## 3. Facade

```perl
my $kc = WWW::Keycloak->new(
  base_url => 'https://id.example.org',   # required, without /realms/...
  realm    => 'main',                     # required

  # login to the Admin API, one of three forms:
  username => 'admin', password => '...',                    # password grant via admin-cli
  client_id => 'provisioner', client_secret => '...',        # service account
  token => $bearer,                                          # ready-made token, not renewed

  auth_realm => 'master',   # where the admin logs in; default: 'master' for
                            # username/password, otherwise the own realm
  ua         => $lwp,       # optional
);

$kc->issuer;        # https://id.example.org/realms/main
$kc->oidc;          # WWW::Keycloak::OIDC
$kc->admin;         # WWW::Keycloak::Admin
$kc->realm;             # 'main'
$kc->for_realm('dev');  # facade for another realm, same login
```

`base_url` and `realm` empty or missing: `WWW::Keycloak::Error::Validation`. Without
credentials `oidc` works; `admin` throws a validation exception on the first call.

## 4. Login to the Admin API (`WWW::Keycloak::Auth`)

A small class with one job: deliver a valid bearer token.

- Fetches the token on first need from the token endpoint of `auth_realm`.
- Remembers `expires_in` and renews 30 seconds before expiry; with `refresh_token` if
  there is one and it is still valid, otherwise by logging in again.
- `Admin` repeats a request exactly once with a fresh token when it is answered with 401
  (observed: a Keycloak restart invalidates all tokens).
- Time is injectable (`now`), so tests check expiry without `sleep`.
- Password and client secret appear in no exception and in no log.

## 5. Admin API (`WWW::Keycloak::Admin`)

### 5.1 Basic operations

Each method is a thin call of one endpoint. Return values: `get_*` and `find_*`
return the representation as a hash (or nothing for `find_*` without a match), `list_*`
an array reference, `create_*` the ID of the new object, `update_*` and `delete_*` true.

Keycloak answers a `POST` to create with `201`, an empty body and the address of the
new object in the `Location` header. `create_*` reads the ID from there.

| Area | Methods |
|---|---|
| Server | `server_info` |
| Realm | `get_realm`, `create_realm(\%rep)`, `update_realm(\%changes)`, `delete_realm`, `export_realm(%opt)`, `partial_import(\%rep, if_exists => 'SKIP')` |
| Clients | `list_clients(%query)`, `find_client($client_id)`, `get_client($id)`, `create_client(\%rep)`, `update_client($id, \%rep)`, `delete_client($id)`, `get_client_secret($id)`, `regenerate_client_secret($id)`, `get_service_account_user($id)` |
| Client scopes | `list_client_scopes`, `find_client_scope($name)`, `create_client_scope(\%rep)`, `update_client_scope($id, \%rep)`, `delete_client_scope($id)`, `add_default_client_scope($client_id_uuid, $scope_id)`, `add_realm_default_client_scope($scope_id)` |
| Protocol mappers | `list_protocol_mappers(client => $id \| client_scope => $id)`, `create_protocol_mapper(client => $id, \%rep)`, `update_protocol_mapper(...)`, `delete_protocol_mapper(...)` |
| Users | `list_users(%query)`, `find_user($username)`, `get_user($id)`, `create_user(\%rep)`, `update_user($id, \%rep)`, `delete_user($id)`, `set_password($id, $password, temporary => 0)`, `list_credentials($id)`, `delete_credential($id, $credential_id)`, `list_sessions($id)`, `logout_user($id)` |
| Authentication | `list_flows`, `list_executions($flow_alias)`, `copy_flow($alias, $new_name)`, `get_execution_config($config_id)`, `create_execution_config($execution_id, \%rep)`, `update_execution_config($config_id, \%rep)`, `describe_authenticator($provider_id)` |

`find_client` searches by `clientId` (the human-readable identifier), `get_client` takes the
internal UUID. This duplication is Keycloak's data model and is not hidden, but the
`ensure_*` methods take the human-readable identifier everywhere.

### 5.2 `ensure_*`: desired state instead of a single step

The basic operations are not repeatable: a second `create_client` gives 409. For
a setup you can run as often as you like, there is an `ensure_*` method for every
object. It looks up the object, creates it or reconciles it, and says what it
did.

```perl
my $r = $admin->ensure_client(
  clientId     => 'my-cli',
  publicClient => \1,
  attributes   => { 'oauth2.device.authorization.grant.enabled' => 'true' },
);
$r->{id};        # internal UUID
$r->{changed};   # 'created', 'updated' or '' (nothing to do)
```

| Method | Key used for the lookup |
|---|---|
| `ensure_realm(%rep)` | the facade's realm |
| `ensure_client(%rep)` | `clientId` |
| `ensure_client_scope(%rep)` | `name` |
| `ensure_protocol_mapper(client => $client_id \| client_scope => $name, %rep)` | `name` within the client or scope |
| `ensure_user(%rep)` | `username` |
| `ensure_execution_config(flow => $alias, authenticator => $provider_id, config => \%c)` | the step with this authenticator in the flow |

Rules that apply to all of them:

- **Only what is given is reconciled.** Keys the caller does not name stay as they are.
  `attributes` and `config` are merged key by key, not replaced.
- **Compare first, then write.** If the state is already right, there is no
  writing call and `changed` is empty. A setup run that changes nothing is thus
  recognizable as such.
- **`ensure_user` touches credentials only on creation.** A password is not reset on
  every run. Whoever wants that calls `set_password`.
- **Nothing is deleted.** `ensure_*` removes no objects and no keys.

### 5.3 What cannot be created through the user API

Keycloak masks the values of the authenticator configuration in exports
(`"default.reference.value": "**********"`), and a realm import with custom flows has to
spell out all 21 built-in flows. That is why `ensure_execution_config` is the way
for flow settings, not the import.

An OTP credential with a known secret, on the other hand, can be set via `update_user` and
via `partial_import` (both observed). `ensure_user` accepts `credentials` on
creation and passes them through.

## 6. OIDC (`WWW::Keycloak::OIDC`)

Like `WWW::Zitadel::OIDC`, extended by what is typically needed for Keycloak:

| Method | Purpose |
|---|---|
| `discovery`, `jwks`, `*_endpoint` | metadata, cached; `jwks(force_refresh => 1)` |
| `verify_token($jwt, audience => ...)` | signature, `iss`, `exp`, optional `aud`; on an unknown key reload JWKS once |
| `userinfo($access_token)`, `introspect($token, client_id =>, client_secret =>)` | |
| `password_token(client_id =>, username =>, password =>, totp =>, scope =>)` | direct grant; `totp` for users with OTP |
| `client_credentials_token(client_id =>, client_secret =>, scope =>)` | |
| `refresh_token($refresh_token, client_id => ...)` | |
| `exchange_authorization_code(code =>, redirect_uri =>, client_id => ...)` | |
| `device_authorization(client_id =>, scope =>)`, `device_token(device_code =>, client_id =>)` | one step of the device flow; the poll loop is up to the caller or `Airlock::Client` |
| `logout(refresh_token =>, client_id => ...)` | end the session |

`verify_token` accepts only `RS*`, `PS*` and `ES*` by default and never `none` or HMAC.
With `type => 'Bearer'` it additionally checks `typ`, so an ID token does not pass as an
access token. On an unknown key it reloads the JWKS, but only for that reason and
at most once per `jwks_min_age` (60 seconds).

## 7. Errors

As in `WWW::Zitadel`, one package per file:

- `WWW::Keycloak::Error` — base with `message`, stringifies to it.
- `WWW::Keycloak::Error::Validation` — wrong arguments, missing credentials.
- `WWW::Keycloak::Error::Network` — no response.
- `WWW::Keycloak::Error::API` — HTTP 4xx/5xx, with `http_status` (number), `api_message` and
  the predicates `is_not_found` (404), `is_conflict` (409), `is_unauthorized` (401).

Keycloak reports Admin API errors in two forms, both become `api_message`:
`{"errorMessage":"Client probe-cli already exists"}` and `{"error":"Could not find client"}`.
The token endpoint uses the OAuth form `{"error":"invalid_grant","error_description":"..."}`.

## 8. Observed on a running Keycloak

Keycloak 26.8.0, 2026-10-02, throwaway realm. Every row is a call that was actually
made. Paths relative to `<base_url>/admin`, `{r}` is the realm.

| Call | Response |
|---|---|
| `POST /realms` | 201, `Location`; second time 409 `errorMessage` |
| `GET /realms/{r}`, `PUT /realms/{r}`, `DELETE /realms/{r}` | 200 / 204 / 204; afterwards `GET` 404 `{"error":"Realm not found."}` |
| `POST /realms/{r}/partial-export?exportClients=true` | 200; authenticator config values masked |
| `POST /realms/{r}/partialImport` | 200 `{added, skipped, overwritten}`; creates users with password and OTP |
| `POST /realms/{r}/clients` | 201, `Location` ends in the UUID; second time 409 |
| `GET /realms/{r}/clients?clientId=x` | 200, list with one entry |
| `GET`/`PUT`/`DELETE /realms/{r}/clients/{id}` | 200 / 204 / 204; afterwards 404 `{"error":"Could not find client"}` |
| `GET`/`POST /realms/{r}/clients/{id}/client-secret` | 200 |
| `GET /realms/{r}/clients/{id}/service-account-user` | 200, `service-account-<clientId>` |
| `GET`/`POST /realms/{r}/clients/{id}/protocol-mappers/models` | 200 / 201; same name 409 |
| `GET`/`POST /realms/{r}/client-scopes`, `POST .../client-scopes/{id}/protocol-mappers/models` | 200 / 201 / 201 |
| `PUT /realms/{r}/default-default-client-scopes/{id}`, `PUT /realms/{r}/clients/{id}/default-client-scopes/{scopeId}` | 204 / 204 |
| `POST /realms/{r}/users` (with `credentials`) | 201, `Location`; second time 409 |
| `GET /realms/{r}/users?username=x&exact=true` | 200, list |
| `PUT /realms/{r}/users/{id}` | 204; also sets an OTP credential (`secretData`, `credentialData`) |
| `PUT /realms/{r}/users/{id}/reset-password` | 204 |
| `GET /realms/{r}/users/{id}/credentials`, `GET .../sessions`, `POST .../logout`, `DELETE /realms/{r}/users/{id}` | 200 / 200 / 204 / 204 |
| `GET /realms/{r}/authentication/flows` | 200; 7 built-in top-level flows |
| `GET /realms/{r}/authentication/flows/{alias}/executions` | 200; flat list with `level`, `providerId`, `authenticationConfig` |
| `POST /realms/{r}/authentication/executions/{id}/config` | 201, also on built-in flows |
| `PUT /realms/{r}/authentication/config/{configId}` | 204 |
| `POST /realms/{r}/authentication/flows/{alias}/copy` | 201 |
| `GET /realms/{r}/authentication/config-description/{providerId}` | 200; for `auth-otp-form` without properties, the reference values are not listed there |
| `GET /serverinfo` | 200; version, `protocolMapperTypes` (including `oidc-amr-mapper`) |
| any call with an invalid token | 401 `{"error":"HTTP 401 Unauthorized"}` |

In addition, from the Airlock live test, for `oidc`:

- Admin login: `POST /realms/master/protocol/openid-connect/token` with `grant_type=password`,
  `client_id=admin-cli`.
- The direct grant takes the parameter `totp`; a user with OTP gets `invalid_grant`
  without it.
- Discovery lists `device_authorization_endpoint`; the device response contains
  `verification_uri_complete`.
- `amr` appears in the token only with the mapper `oidc-amr-mapper` and the keys
  `default.reference.value` / `default.reference.maxAge` on the flow steps. `acr`
  stays `1`.
- The bootstrap admin comes via `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`.

Not observed and therefore to be checked in the plan before building: `GET /realms/{r}/authentication/config/{configId}`,
updating protocol mappers and client scopes via `PUT`, service-account login
to the Admin API (which `realm-management` roles are needed), `introspect`, `logout`
via the end-session or revocation endpoint, and the behavior of older
Keycloak versions (before 17 everything lived under `/auth`).

## 9. Twin

`Net::Async::Keycloak` mirrors the public API with an `_f` suffix and futures, following the
pattern of `Net::Async::Zitadel`: same classes, same methods, same
error hierarchy. This dist leads; the twin follows per phase.

The logic of the `ensure_*` methods (look up, compare, create or reconcile) thus exists
twice. So that it does not drift apart, the comparison lives in a pure
function without I/O: `WWW::Keycloak::Diff->changes(\%current, \%wanted)` returns the keys to
write. Both dists use the same function; `Net-Async-Keycloak` depends
on `WWW-Keycloak` for that. Everything with I/O is written independently in the twin.

## 10. Tests and phases

- **Unit tests** with mocked HTTP following the pattern of `p5-www-zitadel/t/02-oidc.t` and
  `t/03-management.t`: every method against the responses observed in section 8.
- **`WWW::Keycloak::Diff`** pure, without HTTP: nested hashes, merging `attributes`/`config`,
  booleans (`\1`, `JSON->true`, `"true"`), nothing to do.
- **`WWW::Keycloak::Auth`** with a fake clock: renewal before expiry, refresh token,
  retry after 401 exactly once.
- **Live suite** (`t/90-live-keycloak.t`, only with `KEYCLOAK_LIVE_TEST=1 KEYCLOAK_URL=...`):
  creates a realm with a random name, runs every `ensure_*` method twice (first
  `created`, then empty), checks OIDC against this realm and deletes it again. The manifest
  for a throwaway Keycloak on Kubernetes lives in `p5-airlock/t/keycloak/k8s.yaml` and
  is taken over.

| Phase | Content |
|---|---|
| 1 | Facade, errors, `Auth`, `Admin` basic operations from 5.1, `ensure_*` from 5.2, `Diff`, `OIDC`, unit tests, live suite. First user: `p5-airlock/t/keycloak/setup.pl` is switched to this dist. |
| 2 | Declarative setup (section 11, point 1), roles and role assignment, groups |
| 3 | Identity providers, events, user federation, step-up flows with ACR-to-LoA mapping |

The twin catches up after each phase.

Dependencies: `Moo`, `LWP::UserAgent`, `HTTP::Request`, `JSON::MaybeXS`, `Crypt::JWT`,
`URI`, `Types::Standard`, `namespace::autoclean`. HTTPS via `LWP::Protocol::https`.

## 11. Decisions (made 2026-10-03, each as proposed)

1. **What does the "automatic setup" look like?** Two ways that do not exclude each other:
   - *In code:* a Perl script calls `ensure_*` in order. That is done with phase 1.
   - *Declarative:* a file (YAML or a Perl hash) describes realm, clients, scopes,
     users and flow settings; `WWW::Keycloak::Setup->new( keycloak => $kc )->apply($spec)`
     runs the `ensure_*` in the right order and reports what changed.
     Plus a `bin/keycloak-setup`. Proposal: phase 2, as soon as the first real setup
     (Mothership or the lab) shows which fields the file really needs.
2. **What does the setup log in with?** For tests the bootstrap admin is enough. For
   permanent operation a service-account client with `realm-management` roles is the
   usual way; the first setup would have to create it itself. Proposal: phase 1 supports both
   login forms, creating the service account including roles comes with roles in
   phase 2.
3. **Where does the Keycloak run that development targets?** Today: namespace `airlock-test`
   on `cihq`, without persistence, via NodePort, pinned to pichu because raichu's
   VM CPU model cannot do x86-64-v2. For more than tests the cluster needs a
   StorageClass and a programmed gateway.
4. **Shared `Diff` function or full duplication in the twin?** Section 9 proposes
   the shared function; the price is a dependency of `Net-Async-Keycloak`
   on `WWW-Keycloak` that does not exist between the Zitadel twins.

## 12. Clarified after the build (2026-10-03)

An independent review with probes against the real Keycloak 26.8.0 found points that
unit and live tests had not covered. They are fixed and pinned by tests against both
the emulated and the real Keycloak; where they contradict the text above, they win.

- **`ensure_user` sends the whole user.** A `PUT` with `attributes` makes Keycloak's
  user profile delete the fields not named (`email`, `firstName`, `lastName`).
  Attribute values are compared as lists; a single value may come as a string.
  Attributes the user profile does not know are discarded by Keycloak unless it
  allows unmanaged attributes; they then report `updated` on every run.
- **Lists of plain values are sets.** Keycloak returns `redirectUris` and `webOrigins`
  sorted; an order-sensitive comparison would never have converged.
- **`ensure_client` refuses `defaultClientScopes`, `optionalClientScopes` and
  `protocolMappers`.** Keycloak takes them on creation but ignores them on
  update. For that there are `add_default_client_scope` and `ensure_protocol_mapper`.
- **`ensure_execution_config` replaces instead of merging** and reports `updated` on every
  run: Keycloak returns these values as `**********` when read. Section 5.2
  ("compare first, then write") does not apply to this one method.
- **A failed admin login is not retried as a rejected token**; the
  secret goes to Keycloak exactly once. Keycloak answers a wrong password with 400
  `invalid_grant`, not with 401.
- **The default `ua` follows no redirects,** so the admin token is not passed on
  anywhere. The realm is URI-encoded in all addresses.
