requires 'perl', '5.020';
requires 'Crypt::JWT';
requires 'HTTP::Message';
requires 'JSON::MaybeXS';
requires 'LWP::Protocol::https';
requires 'LWP::UserAgent';
requires 'Moo';
requires 'Type::Tiny';
requires 'Types::Standard';
requires 'URI';
requires 'namespace::autoclean', '0.16';

on test => sub {
    requires 'CryptX';
    requires 'IO::Compress::Gzip';
    requires 'Test::More', '0.96';
};
