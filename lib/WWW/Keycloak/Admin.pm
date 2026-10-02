package WWW::Keycloak::Admin;

# ABSTRACT: Keycloak Admin REST API for one realm, with idempotent ensure methods

use Moo;
with 'WWW::Keycloak::Role::HTTP';
use Scalar::Util qw( blessed );
use Types::Standard qw( InstanceOf Str );
use URI::Escape qw( uri_escape_utf8 );
use WWW::Keycloak::Diff;
use WWW::Keycloak::Error::Validation;
use namespace::autoclean;

our $VERSION = '0.001';

=synopsis

    my $admin = WWW::Keycloak->new( base_url => $url, realm => 'main', username => 'admin', password => $pw )->admin;

    # one call, one endpoint
    my $client = $admin->find_client('my-cli');
    my $id     = $admin->create_user( { username => 'alice', enabled => \1 } );

    # wanted state, as often as you like
    my $r = $admin->ensure_client( clientId => 'my-cli', publicClient => \1 );
    print $r->{changed};   # 'created', 'updated' or ''

=description

The Admin REST API of the realm the L<WWW::Keycloak> facade was made for.

The basic methods are one endpoint each. C<get_*> and C<find_*> return the
representation as a hash (C<find_*> returns nothing when there is no match),
C<list_*> an array reference, C<create_*> the id of the new object, which
Keycloak sends in the C<Location> header, and C<update_*> and C<delete_*> true.
Every failure is a L<WWW::Keycloak::Error::API>; C<is_not_found> and
C<is_conflict> tell the common cases apart.

The C<ensure_*> methods are what makes a setup repeatable. Each looks the
object up by its readable key, creates it when it is missing, otherwise writes
only what differs, and returns C<< { id => ..., changed => 'created' | 'updated' | '' } >>.
Only the keys given are compared; nothing is ever deleted.

When Keycloak refuses the token (HTTP 401), the request is repeated once with
a fresh one.

=cut

has base_url => (
  is       => 'ro',
  isa      => Str,
  required => 1
);

=attr base_url

Required. The Keycloak URL without C</realms/...>.

=cut

has realm => (
  is       => 'ro',
  isa      => Str,
  required => 1
);

=attr realm

Required. The realm every method works on.

=cut

has ua => (
  is       => 'ro',
  isa      => InstanceOf['LWP::UserAgent'],
  required => 1
);

=attr ua

Required. The L<LWP::UserAgent> to use.

=cut

has auth => (
  is        => 'ro',
  isa       => InstanceOf['WWW::Keycloak::Auth'],
  predicate => 'has_auth'
);

=attr auth

The L<WWW::Keycloak::Auth> that supplies the admin token. Without it every
call throws a validation error.

=cut

sub diff_class { 'WWW::Keycloak::Diff' }

####  transport

sub realm_url { $_[0]->base_url.'/admin/realms/'.uri_escape_utf8( $_[0]->realm ) }

sub call {
  my ( $self, $method, $path, $body ) = @_;
  my $url = $path =~ m{\A/admin/} ? $self->base_url.$path : $self->realm_url.$path;
  WWW::Keycloak::Error::Validation->throw( message => 'the Admin API needs credentials: give username and password, client_id and client_secret, or token' )
    unless $self->has_auth;
  my %arg = defined $body ? ( json => $body ) : ();
  my $result = eval { $self->send_request( $method, $url, %arg, bearer => $self->auth->token ) };
  if ( my $error = $@ ) {
    die $error unless blessed $error && $error->isa('WWW::Keycloak::Error::API') && $error->is_unauthorized && $self->auth->renewable;
    $self->auth->invalidate;
    $result = $self->send_request( $method, $url, %arg, bearer => $self->auth->token );
  }
  return $result;
}

=method call

    my $result = $admin->call( GET => '/clients?clientId=x' );
    my $result = $admin->call( POST => '/admin/realms', { realm => 'new' } );

One request against the Admin API. A path starting with C</admin/> is taken
from the server root, anything else from the realm. Returns what
L<WWW::Keycloak::Role::HTTP/send_request> returns. The way to reach an
endpoint this class has no method for.

=cut

sub _data   { $_[0]->call( @_[ 1 .. $#_ ] )->{data} }
sub _done   { $_[0]->call( @_[ 1 .. $#_ ] ); 1 }
sub _create {
  my ( $self, $path, $body ) = @_;
  my $location = $self->call( POST => $path, $body )->{location} // '';
  my ( $id ) = $location =~ m{/([^/]+)\z};
  return $id;
}
sub _esc { uri_escape_utf8( $_[1] ) }

sub _query {
  my ( $self, %query ) = @_;
  return '' unless %query;
  return '?'.join '&', map { $self->_esc($_).'='.$self->_esc( $query{$_} ) } sort keys %query;
}

sub _missing {
  my ( $self, $error ) = @_;
  return 1 if blessed $error && $error->isa('WWW::Keycloak::Error::API') && $error->is_not_found;
  die $error;
}

####  server and realm

sub server_info { $_[0]->_data( GET => '/admin/serverinfo' ) }

sub get_realm    { $_[0]->_data( GET => '' ) }
sub update_realm { $_[0]->_done( PUT => '', $_[1] ) }
sub delete_realm { $_[0]->_done( DELETE => '' ) }

sub create_realm {
  my ( $self, $rep ) = @_;
  $self->call( POST => '/admin/realms', { realm => $self->realm, %{ $rep || {} } } );
  return $self->realm;
}

sub export_realm {
  my ( $self, %opt ) = @_;
  return $self->_data( POST => '/partial-export'.$self->_query(
    exportClients        => $opt{clients} ? 'true' : 'false',
    exportGroupsAndRoles => $opt{groups_and_roles} ? 'true' : 'false'
  ) );
}

sub partial_import {
  my ( $self, $rep, %opt ) = @_;
  return $self->_data( POST => '/partialImport', { ifResourceExists => $opt{if_exists} // 'FAIL', %$rep } );
}

=method server_info

=method get_realm

=method create_realm

    $admin->create_realm( { enabled => \1 } );   # the realm of this object

=method update_realm

    $admin->update_realm( { accessTokenLifespan => 600 } );

Keycloak takes a partial representation here and leaves the rest alone.

=method delete_realm

=method export_realm

    my $rep = $admin->export_realm( clients => 1, groups_and_roles => 0 );

Keycloak masks secrets and authenticator settings in the export.

=method partial_import

    my $summary = $admin->partial_import( { users => [ ... ] }, if_exists => 'SKIP' );

C<if_exists> is C<FAIL> (default), C<SKIP> or C<OVERWRITE>.

=cut

####  clients

sub list_clients  { my ( $self, %q ) = @_; $self->_data( GET => '/clients'.$self->_query(%q) ) }
sub get_client    { $_[0]->_data( GET => '/clients/'.$_[0]->_esc( $_[1] ) ) }
sub create_client { $_[0]->_create( '/clients', $_[1] ) }
sub update_client { $_[0]->_done( PUT => '/clients/'.$_[0]->_esc( $_[1] ), $_[2] ) }
sub delete_client { $_[0]->_done( DELETE => '/clients/'.$_[0]->_esc( $_[1] ) ) }

sub find_client {
  my ( $self, $client_id ) = @_;
  my ( $client ) = grep { $_->{clientId} eq $client_id } @{ $self->list_clients( clientId => $client_id ) };
  return $client;
}

sub get_client_secret        { $_[0]->_data( GET => '/clients/'.$_[0]->_esc( $_[1] ).'/client-secret' ) }
sub regenerate_client_secret { $_[0]->_data( POST => '/clients/'.$_[0]->_esc( $_[1] ).'/client-secret' ) }
sub get_service_account_user { $_[0]->_data( GET => '/clients/'.$_[0]->_esc( $_[1] ).'/service-account-user' ) }

=method list_clients

    my $clients = $admin->list_clients( first => 0, max => 50 );

=method find_client

    my $client = $admin->find_client('my-cli') or die 'no such client';

By C<clientId>, the readable key. Everything else takes the internal C<id>.

=method get_client

=method create_client

=method update_client

    $admin->update_client( $id, { %$client, description => 'new' } );

Send the whole representation; L</ensure_client> does that for you.

=method delete_client

=method get_client_secret

=method regenerate_client_secret

=method get_service_account_user

=cut

####  client scopes

sub list_client_scopes  { $_[0]->_data( GET => '/client-scopes' ) }
sub get_client_scope    { $_[0]->_data( GET => '/client-scopes/'.$_[0]->_esc( $_[1] ) ) }
sub create_client_scope { $_[0]->_create( '/client-scopes', $_[1] ) }
sub update_client_scope { $_[0]->_done( PUT => '/client-scopes/'.$_[0]->_esc( $_[1] ), $_[2] ) }
sub delete_client_scope { $_[0]->_done( DELETE => '/client-scopes/'.$_[0]->_esc( $_[1] ) ) }

sub find_client_scope {
  my ( $self, $name ) = @_;
  my ( $scope ) = grep { $_->{name} eq $name } @{ $self->list_client_scopes };
  return $scope;
}

sub add_default_client_scope {
  my ( $self, $client, $scope ) = @_;
  return $self->_done( PUT => '/clients/'.$self->_esc($client).'/default-client-scopes/'.$self->_esc($scope) );
}

sub add_realm_default_client_scope { $_[0]->_done( PUT => '/default-default-client-scopes/'.$_[0]->_esc( $_[1] ) ) }

=method list_client_scopes

=method find_client_scope

    my $scope = $admin->find_client_scope('amr');

By C<name>.

=method get_client_scope

=method create_client_scope

=method update_client_scope

=method delete_client_scope

=method add_default_client_scope

    $admin->add_default_client_scope( $client_id, $scope_id );   # both internal ids

=method add_realm_default_client_scope

    $admin->add_realm_default_client_scope($scope_id);

New clients of the realm get this scope.

=cut

####  protocol mappers

sub _mapper_path {
  my ( $self, $kind, $owner ) = @_;
  WWW::Keycloak::Error::Validation->throw( message => 'protocol mappers belong to a client or a client_scope, not to '.( $kind // 'nothing' ) )
    unless defined $kind && ( $kind eq 'client' || $kind eq 'client_scope' );
  return ( $kind eq 'client' ? '/clients/' : '/client-scopes/' ).$self->_esc($owner).'/protocol-mappers/models';
}

sub list_protocol_mappers  { my ( $self, $kind, $owner ) = @_; $self->_data( GET => $self->_mapper_path( $kind, $owner ) ) }
sub create_protocol_mapper { my ( $self, $kind, $owner, $rep ) = @_; $self->_create( $self->_mapper_path( $kind, $owner ), $rep ) }

sub update_protocol_mapper {
  my ( $self, $kind, $owner, $id, $rep ) = @_;
  return $self->_done( PUT => $self->_mapper_path( $kind, $owner ).'/'.$self->_esc($id), $rep );
}

sub delete_protocol_mapper {
  my ( $self, $kind, $owner, $id ) = @_;
  return $self->_done( DELETE => $self->_mapper_path( $kind, $owner ).'/'.$self->_esc($id) );
}

=method list_protocol_mappers

    my $mappers = $admin->list_protocol_mappers( client => $client_id );
    my $mappers = $admin->list_protocol_mappers( client_scope => $scope_id );

=method create_protocol_mapper

    my $id = $admin->create_protocol_mapper( client => $client_id, { name => 'amr', protocol => 'openid-connect', protocolMapper => 'oidc-amr-mapper', config => {...} } );

=method update_protocol_mapper

    $admin->update_protocol_mapper( client => $client_id, $mapper_id, \%rep );

=method delete_protocol_mapper

    $admin->delete_protocol_mapper( client_scope => $scope_id, $mapper_id );

=cut

####  users

sub list_users  { my ( $self, %q ) = @_; $self->_data( GET => '/users'.$self->_query(%q) ) }
sub get_user    { $_[0]->_data( GET => '/users/'.$_[0]->_esc( $_[1] ) ) }
sub create_user { $_[0]->_create( '/users', $_[1] ) }
sub update_user { $_[0]->_done( PUT => '/users/'.$_[0]->_esc( $_[1] ), $_[2] ) }
sub delete_user { $_[0]->_done( DELETE => '/users/'.$_[0]->_esc( $_[1] ) ) }

sub find_user {
  my ( $self, $username ) = @_;
  my ( $user ) = grep { lc $_->{username} eq lc $username } @{ $self->list_users( username => $username, exact => 'true' ) };
  return $user;
}

sub set_password {
  my ( $self, $id, $password, %opt ) = @_;
  return $self->_done( PUT => '/users/'.$self->_esc($id).'/reset-password',
    { type => 'password', value => $password, temporary => $opt{temporary} ? \1 : \0 } );
}

sub list_credentials  { $_[0]->_data( GET => '/users/'.$_[0]->_esc( $_[1] ).'/credentials' ) }
sub delete_credential { $_[0]->_done( DELETE => '/users/'.$_[0]->_esc( $_[1] ).'/credentials/'.$_[0]->_esc( $_[2] ) ) }
sub list_sessions     { $_[0]->_data( GET => '/users/'.$_[0]->_esc( $_[1] ).'/sessions' ) }
sub logout_user       { $_[0]->_done( POST => '/users/'.$_[0]->_esc( $_[1] ).'/logout' ) }

=method list_users

    my $users = $admin->list_users( search => 'ali', max => 20 );

=method find_user

    my $user = $admin->find_user('alice');

By C<username>, exactly; Keycloak stores user names in lower case.

=method get_user

=method create_user

    my $id = $admin->create_user( { username => 'alice', enabled => \1, credentials => [ { type => 'password', value => $pw, temporary => \0 } ] } );

=method update_user

=method delete_user

=method set_password

    $admin->set_password( $id, $password, temporary => 0 );

=method list_credentials

=method delete_credential

=method list_sessions

=method logout_user

=cut

####  authentication

sub list_flows       { $_[0]->_data( GET => '/authentication/flows' ) }
sub list_executions  { $_[0]->_data( GET => '/authentication/flows/'.$_[0]->_esc( $_[1] ).'/executions' ) }
sub copy_flow        { $_[0]->_create( '/authentication/flows/'.$_[0]->_esc( $_[1] ).'/copy', { newName => $_[2] } ) }
sub get_execution_config    { $_[0]->_data( GET => '/authentication/config/'.$_[0]->_esc( $_[1] ) ) }
sub create_execution_config { $_[0]->_create( '/authentication/executions/'.$_[0]->_esc( $_[1] ).'/config', $_[2] ) }
sub update_execution_config { $_[0]->_done( PUT => '/authentication/config/'.$_[0]->_esc( $_[1] ), { %{ $_[2] }, id => $_[1] } ) }
sub describe_authenticator  { $_[0]->_data( GET => '/authentication/config-description/'.$_[0]->_esc( $_[1] ) ) }

=method list_flows

=method list_executions

    my $steps = $admin->list_executions('browser');

All steps of a flow and its sub-flows, flat, each with C<level>,
C<providerId> and C<authenticationConfig>.

=method copy_flow

=method get_execution_config

=method create_execution_config

    my $config_id = $admin->create_execution_config( $execution_id, { alias => 'x', config => {...} } );

Works on the built-in flows too.

=method update_execution_config

    $admin->update_execution_config( $config_id, { alias => 'x', config => {...} } );

=method describe_authenticator

=cut

1;
