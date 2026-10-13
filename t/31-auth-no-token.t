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
  [ 'an HTML page'             => 'text/html',        '<html>please log in</html>' ],
  [ 'JSON without a token'     => 'application/json', '{"expires_in":300}' ],
  [ 'JSON with an empty token' => 'application/json', '{"access_token":"","expires_in":300}' ],
) {
  my ( $name, $type, $body ) = @$case;
  subtest "2xx with $name is a failed login" => sub {
    my $ua = CaptivePortal->new;
    @$ua{qw( type body )} = ( $type, $body );
    my $auth = WWW::Keycloak::Auth->new(
      ua => $ua, username => 'admin', password => 'admin',
      token_endpoint => 'http://kc.test/realms/master/protocol/openid-connect/token'
    );
    my $error = do { local $@; eval { $auth->token }; $@ };
    isa_ok( $error, 'WWW::Keycloak::Error::API', 'thrown' );
    like( ref $error ? $error->message : '', qr/admin login failed: the token endpoint answered 200 without an access_token/, 'says no token was issued' );
    is( $ua->{count}, 1, 'one request, no retry loop' );
  };
}

done_testing;
