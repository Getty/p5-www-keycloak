package WWW::Keycloak::Role::HTTP;

# ABSTRACT: Sending requests to Keycloak and turning failures into exceptions

use HTTP::Request;
use JSON::MaybeXS;
use URI;
use WWW::Keycloak::Error::API;
use WWW::Keycloak::Error::Network;
use Moo::Role;

our $VERSION = '0.001';

=description

What L<WWW::Keycloak::Admin>, L<WWW::Keycloak::OIDC> and
L<WWW::Keycloak::Auth> share: one L<LWP::UserAgent>, JSON in and out, and the
mapping of Keycloak's three error shapes onto L<WWW::Keycloak::Error::API>.

=cut

sub json_codec { JSON::MaybeXS->new( utf8 => 1, canonical => 1, convert_blessed => 1 ) }

sub send_request {
  my ( $self, $method, $url, %arg ) = @_;
  my $request = HTTP::Request->new( $method => $url );
  $request->header( Accept => 'application/json' );
  $request->header( Authorization => 'Bearer '.$arg{bearer} ) if defined $arg{bearer};
  if ( exists $arg{json} ) {
    $request->header( 'Content-Type' => 'application/json' );
    $request->content( $self->json_codec->encode( $arg{json} ) );
  }
  elsif ( $arg{form} ) {
    my $uri = URI->new('http:');
    $uri->query_form( map { $_ => $arg{form}{$_} } grep { defined $arg{form}{$_} } sort keys %{ $arg{form} } );
    $request->header( 'Content-Type' => 'application/x-www-form-urlencoded' );
    $request->content( $uri->query // '' );
  }
  my $response = $self->ua->request($request);
  WWW::Keycloak::Error::Network->throw( message => $method.' '.$url.': '.$response->status_line )
    if $response->code == 500 && ( $response->header('Client-Warning') // '' ) eq 'Internal response';
  my $content = $response->decoded_content // '';
  my $data    = length $content ? eval { $self->json_codec->decode( $response->content ) } : undef;
  return { status => $response->code, data => $data, location => scalar $response->header('Location') }
    if $response->is_success;
  my ( $message, $oauth );
  if ( ref $data eq 'HASH' ) {
    $message = $data->{errorMessage} // $data->{error};
    if ( defined $data->{error} && defined $data->{error_description} || $arg{form} ) {
      $oauth = $data->{error};
      $message = $data->{error}.( defined $data->{error_description} ? ': '.$data->{error_description} : '' )
        if defined $data->{error};
    }
  }
  WWW::Keycloak::Error::API->throw(
    message     => $method.' '.$url.' failed: '.$response->status_line.( defined $message ? ' - '.$message : '' ),
    http_status => $response->code,
    api_message => $message,
    oauth_error => $oauth
  );
}

=method send_request

    my $result = $self->send_request( POST => $url, json => \%body, bearer => $token );
    my $result = $self->send_request( POST => $url, form => \%fields );

Sends one request. Returns C<status>, the decoded C<data> and the C<location>
header. Throws L<WWW::Keycloak::Error::Network> when no answer came back and
L<WWW::Keycloak::Error::API> for any status of 400 and above.

=cut

1;
