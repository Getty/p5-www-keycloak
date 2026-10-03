package WWW::Keycloak::Auth;

# ABSTRACT: Get and keep a valid admin token for the Keycloak Admin API

use Moo;
with 'WWW::Keycloak::Role::HTTP';
use Types::Standard qw( CodeRef InstanceOf Int Str );
use WWW::Keycloak::Error::Validation;
use namespace::autoclean;

our $VERSION = '0.001';

=synopsis

    my $auth = WWW::Keycloak::Auth->new(
      token_endpoint => 'https://id.example.org/realms/master/protocol/openid-connect/token',
      username       => 'admin',
      password       => $password,
      ua             => $lwp,
    );
    my $bearer = $auth->token;

=description

Keycloak has no long-lived admin tokens. This class logs in when a token is
first needed, keeps it, renews it shortly before it runs out (with the refresh
token while that is valid, otherwise by logging in again), and forgets it when
told the token was refused. Three ways to log in: a username and password
through the C<admin-cli> client, a service-account client with its secret, or
a fixed token that is used as it is and never renewed.

Passwords and secrets never appear in an exception.

=cut

has ua => (
  is       => 'ro',
  isa      => InstanceOf['LWP::UserAgent'],
  required => 1
);

=attr ua

Required. The L<LWP::UserAgent> to use.

=cut

has token_endpoint => (
  is  => 'ro',
  isa => Str
);

=attr token_endpoint

The token endpoint of the realm the admin logs in to. Required unless
C<token> is given.

=cut

has username      => ( is => 'ro', isa => Str, predicate => 'has_username' );
has password      => ( is => 'ro', isa => Str );
has client_id     => ( is => 'ro', isa => Str, predicate => 'has_client_id' );
has client_secret => ( is => 'ro', isa => Str );
has fixed_token   => ( is => 'ro', isa => Str, init_arg => 'token', predicate => 'has_fixed_token' );

=attr username

=attr password

Log in with the password grant through C<admin-cli>, or through C<client_id>
when that is given too.

=attr client_id

=attr client_secret

Log in with the client credentials grant of a service-account client.

=attr token

A ready token. Used as it is; when it runs out, requests fail.

=cut

has margin => (
  is      => 'ro',
  isa     => Int,
  default => 30
);

=attr margin

Seconds before expiry at which a token is renewed. Default 30.

=cut

has now => (
  is      => 'ro',
  isa     => CodeRef,
  default => sub { sub { time } }
);

=attr now

Coderef returning the current epoch. For tests.

=cut

has _access          => ( is => 'rw' );
has _access_expires  => ( is => 'rw' );
has _refresh         => ( is => 'rw' );
has _refresh_expires => ( is => 'rw' );

sub BUILD {
  my ( $self ) = @_;
  return if $self->has_fixed_token;
  WWW::Keycloak::Error::Validation->throw( message => __PACKAGE__.' needs username and password, client_id and client_secret, or token' )
    unless ( $self->has_username && defined $self->password ) || ( $self->has_client_id && defined $self->client_secret );
  WWW::Keycloak::Error::Validation->throw( message => __PACKAGE__.' needs a token_endpoint' )
    unless defined $self->token_endpoint && length $self->token_endpoint;
  return;
}

sub renewable { $_[0]->has_fixed_token ? 0 : 1 }

=method renewable

False for a fixed token, which this class cannot replace.

=cut

sub token {
  my ( $self ) = @_;
  return $self->fixed_token if $self->has_fixed_token;
  my $now = $self->now->();
  return $self->_access if defined $self->_access && $now < $self->_access_expires - $self->margin;
  if ( defined $self->_refresh && $now < $self->_refresh_expires - $self->margin ) {
    my $renewed = eval {
      $self->_grant( { grant_type => 'refresh_token', refresh_token => $self->_refresh, $self->_client } );
      1;
    };
    return $self->_access if $renewed;
  }
  $self->_grant( $self->has_username
    ? { grant_type => 'password', username => $self->username, password => $self->password, $self->_client }
    : { grant_type => 'client_credentials', $self->_client } );
  return $self->_access;
}

=method token

    my $bearer = $auth->token;

A token that is valid for at least C<margin> more seconds.

=cut

sub invalidate {
  my ( $self ) = @_;
  $self->_access(undef);
  $self->_refresh(undef);
  return;
}

=method invalidate

    $auth->invalidate;

Forgets the current token, so the next L</token> logs in afresh. Called when
Keycloak refused a token, for example after a restart.

=cut

sub _client {
  my ( $self ) = @_;
  return (
    client_id => $self->has_client_id ? $self->client_id : 'admin-cli',
    defined $self->client_secret ? ( client_secret => $self->client_secret ) : ()
  );
}

sub _grant {
  my ( $self, $form ) = @_;
  my $now  = $self->now->();
  my $data = eval { $self->send_request( POST => $self->token_endpoint, form => $form )->{data} };
  if ( my $error = $@ ) {
    die $error unless ref $error && $error->isa('WWW::Keycloak::Error::API');
    $self->api_error_class->throw(
      message     => 'admin login failed: '.$error->http_status.( defined $error->api_message ? ' - '.$error->api_message : '' ),
      http_status => $error->http_status,
      api_message => $error->api_message,
      oauth_error => $error->oauth_error
    );
  }
  $self->_access( $data->{access_token} );
  $self->_access_expires( $now + ( $data->{expires_in} || 60 ) );
  $self->_refresh( $data->{refresh_token} );
  $self->_refresh_expires( $now + ( $data->{refresh_expires_in} || 0 ) );
  return;
}

1;
