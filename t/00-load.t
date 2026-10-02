#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

for (qw(
  WWW::Keycloak
  WWW::Keycloak::Diff
)) {
  use_ok($_);
}

done_testing;
