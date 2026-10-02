package WWW::Keycloak::Error;

# ABSTRACT: Exception base class for WWW::Keycloak

use Moo;

# No namespace::autoclean here: it would remove the overload stub.
use overload '""' => sub { $_[0]->message }, fallback => 1;

our $VERSION = '0.001';

=synopsis

    use Scalar::Util qw( blessed );

    my $client = eval { $admin->get_client($id) };
    if ( blessed $@ && $@->isa('WWW::Keycloak::Error::API') && $@->is_not_found ) { ... }

=description

Every error WWW::Keycloak raises is an object of one of three subclasses:
L<WWW::Keycloak::Error::Validation> for wrong arguments,
L<WWW::Keycloak::Error::Network> when no HTTP answer arrived, and
L<WWW::Keycloak::Error::API> when Keycloak answered with an error. All of them
stringify to their message, so plain C<$@> matching keeps working.

=cut

has message => (
  is       => 'ro',
  required => 1
);

=attr message

The human-readable description. The object stringifies to it.

=cut

sub throw {
  my ( $class, %arg ) = @_;
  die $class->new(%arg);
}

=method throw

    WWW::Keycloak::Error::Validation->throw( message => 'realm is required' );

Builds the exception and dies with it.

=cut

1;
