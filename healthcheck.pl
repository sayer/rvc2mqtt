#!/usr/bin/perl

use strict;
use warnings;
use IO::Socket::INET;

my $port = 8123;  # Health check port
my $server = IO::Socket::INET->new(
    LocalPort => $port,
    Proto => 'tcp',
    Listen => 1,
    Reuse => 1,
) or die "Could not create server socket: $!\n";

print "Health check server listening on port $port...\n";

while (my $client = $server->accept()) {
    print $client "HTTP/1.1 200 OK\r\n";
    print $client "Content-Type: text/plain\r\n";
    print $client "\r\n";
    print $client "OK\r\n";
    close $client;
}
