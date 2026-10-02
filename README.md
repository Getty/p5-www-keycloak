# WWW-Keycloak

Perl client for [Keycloak](https://www.keycloak.org/): OpenID Connect against a
realm, and the Admin REST API to bring a realm into a wanted state from Perl,
repeatably.

```perl
use WWW::Keycloak;

my $kc = WWW::Keycloak->new(
  base_url => 'https://id.example.org',
  realm    => 'main',
  username => 'admin',            # or client_id + client_secret, or token
  password => $ENV{KEYCLOAK_ADMIN_PASSWORD},
);

# OpenID Connect
my $claims = $kc->oidc->verify_token( $jwt, audience => 'my-api' );
my $tokens = $kc->oidc->password_token( client_id => 'cli', username => 'alice', password => $pw, totp => $code );

# Admin REST API: wanted state, as often as you like
my $admin = $kc->admin;
$admin->ensure_client( clientId => 'cli', publicClient => \1,
  attributes => { 'oauth2.device.authorization.grant.enabled' => 'true' } );
$admin->ensure_protocol_mapper( client => 'cli', name => 'amr', protocolMapper => 'oidc-amr-mapper',
  config => { 'id.token.claim' => 'true', 'access.token.claim' => 'true' } );
$admin->ensure_user( username => 'alice', enabled => \1,
  credentials => [ { type => 'password', value => $pw, temporary => \0 } ] );
$admin->ensure_execution_config( flow => 'browser', authenticator => 'auth-otp-form',
  config => { 'default.reference.value' => 'otp', 'default.reference.maxAge' => 3600 } );
```

Every `ensure_*` method looks the object up by its readable key, creates it
when it is missing, otherwise writes only what differs, and returns
`{ id => ..., changed => 'created' | 'updated' | '' }`. Nothing is deleted.

The admin login is managed: the token is fetched on first use, renewed before
it runs out, and renewed once more when Keycloak refuses it (as after a
restart).

Developed and live-tested against Keycloak 26.8.0. The async twin is
`Net::Async::Keycloak`.

## Live tests

```bash
KEYCLOAK_LIVE_TEST=1 KEYCLOAK_URL=http://localhost:8080 prove -lv t/90-live-keycloak.t
```

The test creates a realm with a random name and deletes it again. A throwaway
Keycloak on Kubernetes: `t/keycloak/k8s.yaml`.

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
