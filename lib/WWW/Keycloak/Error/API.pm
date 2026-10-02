package WWW::Keycloak::Error::API;

# ABSTRACT: Raised when Keycloak answers with an HTTP error

use Moo;
extends 'WWW::Keycloak::Error';

our $VERSION = '0.001';

=description

Keycloak reports errors in three shapes, and all of them end up in
L</api_message>: C<{"errorMessage": "..."}> from most of the Admin API,
C<{"error": "..."}> from some of it, and the OAuth form
C<{"error": "...", "error_description": "..."}> from the token endpoint, where
L</oauth_error> also carries the bare code.

=cut

has http_status => (
  is       => 'ro',
  required => 1
);

=attr http_status

The HTTP status code as a number, for example 409.

=cut

has api_message => ( is => 'ro' );

=attr api_message

What Keycloak said, if it said anything.

=cut

has oauth_error => ( is => 'ro' );

=attr oauth_error

The OAuth error code (C<invalid_grant>, C<authorization_pending>, ...) when
the error came from an OAuth endpoint.

=cut

sub is_not_found    { $_[0]->http_status == 404 ? 1 : 0 }
sub is_conflict     { $_[0]->http_status == 409 ? 1 : 0 }
sub is_unauthorized { $_[0]->http_status == 401 ? 1 : 0 }

=method is_not_found

=method is_conflict

=method is_unauthorized

True for status 404, 409 and 401.

=cut

1;
