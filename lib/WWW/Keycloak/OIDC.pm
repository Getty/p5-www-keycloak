package WWW::Keycloak::OIDC;

# ABSTRACT: OpenID Connect against one Keycloak realm

use Moo;
with 'WWW::Keycloak::Role::HTTP';
use Crypt::JWT qw( decode_jwt );
use Scalar::Util qw( blessed );
use Types::Standard qw( ArrayRef CodeRef InstanceOf Int Str );
use WWW::Keycloak::Error::Validation;
use namespace::autoclean;

our $VERSION = '0.001';

=synopsis

    my $oidc = WWW::Keycloak->new( base_url => $url, realm => 'main' )->oidc;

    my $claims = $oidc->verify_token( $jwt, audience => 'my-api' );
    my $tokens = $oidc->password_token( client_id => 'cli', username => 'alice', password => $pw, totp => '123456' );

=description

The OpenID Connect side of a realm: discovery, the signing keys, token
verification, and the token endpoint in all the grant types Keycloak offers.

Endpoints come from the realm's discovery document, fetched once and kept.
An error from the token endpoint is a L<WWW::Keycloak::Error::API> whose
C<oauth_error> carries the OAuth code, so a device-flow poll can tell
C<authorization_pending> from a real failure.

=cut

has issuer => (
  is       => 'ro',
  isa      => Str,
  required => 1
);

=attr issuer

Required. C<< <base_url>/realms/<realm> >>.

=cut

has ua => (
  is       => 'ro',
  isa      => InstanceOf['LWP::UserAgent'],
  required => 1
);

=attr ua

Required. The L<LWP::UserAgent> to use.

=cut

has algorithms => (
  is      => 'ro',
  isa     => ArrayRef[Str],
  default => sub { [qw( RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 )] }
);

=attr algorithms

Signature algorithms L</verify_token> accepts. Never C<none>, never HMAC.

=cut

has jwks_min_age => (
  is      => 'ro',
  isa     => Int,
  default => 60
);

=attr jwks_min_age

Seconds that have to pass before L</verify_token> fetches the keys again for a
token signed with an unknown key. Default 60, so that a stream of forged tokens
does not become a stream of requests to Keycloak.

=cut

has now => (
  is      => 'ro',
  isa     => CodeRef,
  default => sub { sub { time } }
);

=attr now

Coderef returning the current epoch. For tests.

=cut

has _jwks_fetched => (
  is       => 'rw',
  init_arg => undef
);

has discovery => (
  is       => 'lazy',
  init_arg => undef
);

sub _build_discovery {
  my ( $self ) = @_;
  my $data = $self->send_request( GET => $self->issuer.'/.well-known/openid-configuration' )->{data};
  WWW::Keycloak::Error::Validation->throw( message => 'discovery for '.$self->issuer.' returned no JSON object' ) unless ref $data eq 'HASH';
  return $data;
}

=attr discovery

The discovery document, fetched on first use.

=cut

has _jwks => (
  is       => 'rw',
  init_arg => undef
);

sub endpoint {
  my ( $self, $name ) = @_;
  my $url = $self->discovery->{$name};
  WWW::Keycloak::Error::Validation->throw( message => 'the discovery document of '.$self->issuer.' has no '.$name ) unless defined $url;
  return $url;
}

=method endpoint

    my $url = $oidc->endpoint('device_authorization_endpoint');

A URL from the discovery document. Throws when it is missing.

=cut

sub token_endpoint         { $_[0]->endpoint('token_endpoint') }
sub userinfo_endpoint      { $_[0]->endpoint('userinfo_endpoint') }
sub introspection_endpoint { $_[0]->endpoint('introspection_endpoint') }
sub end_session_endpoint   { $_[0]->endpoint('end_session_endpoint') }
sub device_endpoint        { $_[0]->endpoint('device_authorization_endpoint') }
sub jwks_uri               { $_[0]->endpoint('jwks_uri') }

sub jwks {
  my ( $self, %opt ) = @_;
  if ( $opt{force_refresh} || !$self->_jwks ) {
    $self->_jwks( $self->send_request( GET => $self->jwks_uri )->{data} );
    $self->_jwks_fetched( $self->now->() );
  }
  return $self->_jwks;
}

=method jwks

    my $keys = $oidc->jwks;
    my $keys = $oidc->jwks( force_refresh => 1 );

The realm's public signing keys, kept after the first fetch.

=cut

sub verify_token {
  my ( $self, $token, %opt ) = @_;
  WWW::Keycloak::Error::Validation->throw( message => 'verify_token needs a token' ) unless defined $token && length $token;
  my %check = (
    token          => $token,
    verify_iss     => $self->issuer,
    verify_exp     => 1,
    accepted_alg   => $self->algorithms,
    decode_payload => 1,
    defined $opt{audience} ? ( verify_aud => $opt{audience} ) : ()
  );
  my $claims = eval { decode_jwt( %check, kid_keys => $self->jwks ) };
  my $error  = $@;
  # A key Keycloak rotated in since the keys were fetched: fetch them again,
  # but only for that reason and not more often than jwks_min_age allows.
  if ( !$claims && $error =~ /kid_keys lookup failed/ && $self->now->() - ( $self->_jwks_fetched // 0 ) >= $self->jwks_min_age ) {
    $claims = eval { decode_jwt( %check, kid_keys => $self->jwks( force_refresh => 1 ) ) };
    $error  = $@;
  }
  $self->_reject( $error =~ s/ at \S+ line \d+.*//sr ) unless $claims;
  if ( defined $opt{type} && ( $claims->{typ} // '' ) ne $opt{type} ) {
    $self->_reject( 'typ is '.( $claims->{typ} // 'missing' ).', expected '.$opt{type} );
  }
  return $claims;
}

sub _reject {
  my ( $self, $why ) = @_;
  WWW::Keycloak::Error::Validation->throw( message => 'token rejected: '.$why );
}

=method verify_token

    my $claims = $oidc->verify_token( $jwt, audience => 'my-api', type => 'Bearer' );

Checks signature, issuer and expiry, the audience when one is given, and the
C<typ> claim when C<type> is given. Keycloak puts C<Bearer> into access tokens
and C<ID> into ID tokens; an API that accepts access tokens should say
C<< type => 'Bearer' >>, or an ID token issued to any client of the realm
passes as well. When the signing key is unknown the keys are fetched again,
at most once per L</jwks_min_age>. Returns the claims, or throws a validation
error saying why the token was rejected.

=cut

sub userinfo {
  my ( $self, $access_token ) = @_;
  return $self->send_request( GET => $self->userinfo_endpoint, bearer => $access_token )->{data};
}

=method userinfo

    my $info = $oidc->userinfo($access_token);

=cut

sub introspect {
  my ( $self, $token, %client ) = @_;
  return $self->_token_call( $self->introspection_endpoint, { token => $token }, %client );
}

=method introspect

    my $state = $oidc->introspect( $token, client_id => 'api', client_secret => $secret );

Needs a confidential client.

=cut

sub password_token {
  my ( $self, %arg ) = @_;
  return $self->_grant( password => [qw( username password totp scope )], %arg );
}

sub client_credentials_token {
  my ( $self, %arg ) = @_;
  return $self->_grant( client_credentials => ['scope'], %arg );
}

sub refresh_token {
  my ( $self, $refresh, %arg ) = @_;
  return $self->_grant( refresh_token => [qw( refresh_token scope )], %arg, refresh_token => $refresh );
}

sub exchange_authorization_code {
  my ( $self, %arg ) = @_;
  return $self->_grant( authorization_code => [qw( code redirect_uri code_verifier )], %arg );
}

sub device_token {
  my ( $self, %arg ) = @_;
  return $self->_grant( 'urn:ietf:params:oauth:grant-type:device_code' => ['device_code'], %arg );
}

=method password_token

    my $tokens = $oidc->password_token( client_id => 'cli', username => 'alice', password => $pw, totp => '123456', scope => 'openid' );

The direct grant. C<totp> is needed for users with a one-time password.

=method client_credentials_token

    my $tokens = $oidc->client_credentials_token( client_id => 'svc', client_secret => $secret );

=method refresh_token

    my $tokens = $oidc->refresh_token( $refresh, client_id => 'cli' );

=method exchange_authorization_code

    my $tokens = $oidc->exchange_authorization_code( code => $code, redirect_uri => $uri, client_id => 'web', client_secret => $secret );

=method device_token

    my $tokens = eval { $oidc->device_token( device_code => $start->{device_code}, client_id => 'cli' ) };
    # $@->oauth_error eq 'authorization_pending' while nobody has approved

One poll of the device flow. The loop is the caller's, or L<Airlock::Client>'s.

=cut

sub device_authorization {
  my ( $self, %arg ) = @_;
  return $self->_token_call( $self->device_endpoint, { defined $arg{scope} ? ( scope => $arg{scope} ) : () }, %arg );
}

=method device_authorization

    my $start = $oidc->device_authorization( client_id => 'cli', scope => 'openid' );

Starts a device flow: C<device_code>, C<user_code>, C<verification_uri>,
C<verification_uri_complete>, C<expires_in>, C<interval>.

=cut

sub logout {
  my ( $self, %arg ) = @_;
  $self->_token_call( $self->end_session_endpoint, { refresh_token => $arg{refresh_token} }, %arg );
  return 1;
}

=method logout

    $oidc->logout( refresh_token => $refresh, client_id => 'cli' );

Ends the session the refresh token belongs to.

=cut

sub _grant {
  my ( $self, $type, $fields, %arg ) = @_;
  return $self->_token_call( $self->token_endpoint, { grant_type => $type, map { $_ => $arg{$_} } grep { defined $arg{$_} } @$fields }, %arg );
}

sub _token_call {
  my ( $self, $url, $form, %arg ) = @_;
  WWW::Keycloak::Error::Validation->throw( message => 'a client_id is needed' ) unless defined $arg{client_id};
  my %form = ( %$form, client_id => $arg{client_id}, defined $arg{client_secret} ? ( client_secret => $arg{client_secret} ) : () );
  return $self->send_request( POST => $url, form => \%form )->{data} // {};
}

1;
