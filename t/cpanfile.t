#!/usr/bin/env perl

use strict;
use warnings;
use Carp qw( croak );
use File::Spec;
use FindBin;
use Test::More;

my $cpanfile = File::Spec->catfile( $FindBin::Bin, File::Spec->updir, 'cpanfile' );

plan skip_all => 'cpanfile is not part of the distribution' unless -f $cpanfile;

open my $fh, '<', $cpanfile or croak "cannot read $cpanfile: $!";
my %requires;
while ( my $line = <$fh> ) {
  next unless $line =~ /^\s*requires\s+'([^']+)'(?:\s*,\s*'([^']+)')?/;
  $requires{ $1 } = $2;
}
close $fh;

# Everything the code loads has to be a declared prerequisite, otherwise a
# fresh install fails at runtime and not at build time. The core modules
# (strict, warnings, Scalar::Util, MIME::Base64, ...) need no declaration.
my @runtime = qw(
  Crypt::JWT
  HTTP::Message
  JSON::MaybeXS
  LWP::Protocol::https
  LWP::UserAgent
  Moo
  Type::Tiny
  Types::Standard
  URI
  namespace::autoclean
);
my @test = qw(
  CryptX
  IO::Compress::Gzip
  Test::More
);

ok( exists $requires{perl}, 'perl is a declared prerequisite' );
for my $module ( @runtime, @test ) {
  ok( exists $requires{$module}, "$module is a declared prerequisite" );
}

# namespace::autoclean before 0.16 inflates a Moo class to a Moose class
cmp_ok( $requires{'namespace::autoclean'} // 0, '>=', 0.16, 'namespace::autoclean is new enough to keep Moo small' );

done_testing;
