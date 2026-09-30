package Net::MQTT::Simple;
use strict;
use warnings;
use JSON::PP qw(decode_json);

# Test double: this module deliberately contains no socket implementation.
sub import {
  my $caller = caller;
  no strict 'refs';
  *{"${caller}::publish"} = \&publish;
  *{"${caller}::retain"} = \&retain;
}
sub new { bless { subscriptions => {} }, shift }
sub login { die 'Authentication is forbidden in offline tests' }
sub subscribe {
  my ($self, $topic, $callback) = @_;
  $self->{subscriptions}{$topic} = $callback;
}
sub publish {
  shift if ref $_[0];
  BridgeSandbox::record({ kind => 'publish', topic => $_[0], payload => decode_json($_[1]) });
}
sub retain {
  BridgeSandbox::record({ kind => 'retain', topic => $_[0], payload => $_[1] });
}
sub run {
  my ($self) = @_;
  my $messages = decode_json($ENV{RVC_TEST_MESSAGES} // '[]');
  for my $message (@$messages) {
    my ($pattern) = grep {
      my $regex = join '/', map { $_ eq '+' ? '[^/]+' : quotemeta($_) } split '/', $_;
      $message->{topic} =~ /^$regex$/;
    } keys %{$self->{subscriptions}};
    die "No subscription for $message->{topic}" unless defined $pattern;
    $self->{subscriptions}{$pattern}->($message->{topic}, $message->{payload});
  }
}
1;
