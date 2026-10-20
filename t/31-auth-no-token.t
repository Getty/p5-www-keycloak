#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use HTTP::Response;
use WWW::Keycloak::Auth;

{
  package CaptivePortal;
  use parent 'LWP::UserAgent';
  sub request {
    my ( $self, $request ) = @_;
    $self->{count}++;
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->header( 'Content-Type' => $self->{type} );
    $response->content( $self->{body} );
    return $response;
  }
}

for my $case (
  # an answer that is no JSON at all never reaches the login check: the
  # transport throws it, and the reason is the one of the transport
  [ 'an HTML page'             => 'text/html',        '<html>please log in</html>', qr/the answer is no JSON object/, '<html>please log in</html>' ],
  [ 'JSON without a token'     => 'application/json', '{"expires_in":300}',         qr/admin login failed: the token endpoint answered 200 without an access_token/, undef ],
  [ 'JSON with an empty token' => 'application/json', '{"access_token":"","expires_in":300}', qr/admin login failed: the token endpoint answered 200 without an access_token/, undef ],
) {
  my ( $name, $type, $body, $why, $expected_body ) = @$case;
  subtest "2xx with $name is a failed login" => sub {
    my $ua = CaptivePortal->new;
    @$ua{qw( type body )} = ( $type, $body );
    my $auth = WWW::Keycloak::Auth->new(
      ua => $ua, username => 'admin', password => 'admin',
      token_endpoint => 'http://kc.test/realms/master/protocol/openid-connect/token'
    );
    my $error = do { local $@; eval { $auth->token }; $@ };
    isa_ok( $error, 'WWW::Keycloak::Error::API', 'thrown' );
    like( ref $error ? $error->message : '', $why, 'says why' );
    is( ref $error ? $error->http_status : undef, 200, 'with the status' );
    my $carried = ref $error && $error->can('body') ? $error->body : undef;
    is( $carried, $expected_body, 'and the body that came' );
    is( $ua->{count}, 1, 'one request, no retry loop' );
  };
}

done_testing;
