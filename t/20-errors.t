#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';

use HTTP::Response;
use Scalar::Util qw( blessed );
use FakeKeycloak;
use WWW::Keycloak;

my $fake = FakeKeycloak->new;
my $kc   = WWW::Keycloak->new( base_url => $fake->base, realm => 'master', username => 'admin', password => 'admin', ua => $fake );

sub error_of (&) { my ( $code ) = @_; eval { $code->(); 1 } ? undef : $@ }

subtest 'classes and stringification' => sub {
  my $e = WWW::Keycloak::Error::API->new( message => 'boom', http_status => 409 );
  isa_ok( $e, 'WWW::Keycloak::Error' );
  is( "$e", 'boom', 'stringifies to the message' );
  ok( $e->is_conflict && !$e->is_not_found && !$e->is_unauthorized, 'predicates' );
  isa_ok( WWW::Keycloak::Error::Validation->new( message => 'x' ), 'WWW::Keycloak::Error' );
  isa_ok( WWW::Keycloak::Error::Network->new( message => 'x' ), 'WWW::Keycloak::Error' );
  my $thrown = error_of { WWW::Keycloak::Error::Validation->throw( message => 'thrown' ) };
  isa_ok( $thrown, 'WWW::Keycloak::Error::Validation', 'throw' );
};

subtest 'the three shapes Keycloak answers errors in' => sub {
  my $conflict = error_of { $kc->admin->create_realm };
  isa_ok( $conflict, 'WWW::Keycloak::Error::API' );
  is( $conflict->http_status, 409, 'status as a number' );
  is( $conflict->api_message, 'Realm master already exists', 'errorMessage' );
  ok( $conflict->is_conflict, 'is_conflict' );
  like( "$conflict", qr{POST http://kc.test/admin/realms failed: 409 .* - Realm master already exists}, 'message names the request' );

  my $missing = error_of { $kc->admin->get_client('nope') };
  ok( $missing->is_not_found, 'is_not_found' );
  is( $missing->api_message, 'Could not find client', 'error' );
  is( $missing->oauth_error, undef, 'an admin error is no OAuth error' );

  my $oauth = error_of { $kc->oidc->password_token( client_id => 'cli', username => 'x', password => 'y' ) };
  is( $oauth->oauth_error, 'invalid_grant', 'oauth_error from the token endpoint' );
  is( $oauth->api_message, 'invalid_grant: Invalid user credentials', 'with the description' );
};

subtest 'no answer at all' => sub {
  my $down = WWW::Keycloak->new( base_url => 'http://127.0.0.1:9', realm => 'x', ua => LWP::UserAgent->new( timeout => 2 ) );
  my $error = error_of { $down->oidc->discovery };
  isa_ok( $error, 'WWW::Keycloak::Error::Network' );
  like( "$error", qr{GET http://127.0.0.1:9/realms/x/.well-known/openid-configuration: 500}, 'names the request' );
};

subtest 'the error carries the body' => sub {
  my $answer = HTTP::Response->new( 502, 'Bad Gateway' );
  $answer->content( '<html><body>502 Bad Gateway</body></html>' );
  my $error = error_of { $kc->oidc->read_response( $answer, GET => 'http://kc.test/x' ) };
  isa_ok( $error, 'WWW::Keycloak::Error::API' );
  is( $error->http_status, 502, 'status' );
  like( "$error", qr{GET http://kc.test/x failed: 502 Bad Gateway}, 'the message names the request' );
  my $body = $error->can('body') ? $error->body : undef;
  is( $body, '<html><body>502 Bad Gateway</body></html>', 'the body came with it' );

  my $long = HTTP::Response->new( 504, 'Gateway Timeout' );
  $long->content( 'x' x 900 );
  my $cut = error_of { $kc->oidc->read_response( $long, GET => 'http://kc.test/x' ) };
  my $snippet = $cut->can('body') ? $cut->body : undef;
  is( length( $snippet // '' ), 500, 'a long body is cut at 500 characters' );
};

subtest 'a compressed answer is read like a plain one' => sub {
  require IO::Compress::Gzip;
  # one character as a JSON escape, one as the two bytes of its UTF-8 form
  my $json = '{"clientId":"my-cli","name":"Caf\u00e9 '."\xc3\xa9".'"}';
  IO::Compress::Gzip::gzip( \$json => \my $gzipped ) or die 'gzip failed';
  my %answer = (
    plain => HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ], $json ),
    gzip  => HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json', 'Content-Encoding' => 'gzip' ], $gzipped )
  );
  for my $kind ( sort keys %answer ) {
    my $read = $kc->oidc->read_response( $answer{$kind}, GET => 'http://kc.test/x' );
    is( $read->{data}{clientId}, 'my-cli', $kind.': the body is decoded' );
    is( $read->{data}{name}, "Caf\x{e9} \x{e9}", $kind.': and its characters once' );
  }
};

done_testing;
