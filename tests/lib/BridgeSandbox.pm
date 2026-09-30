package BridgeSandbox;
use strict;
use warnings;
use JSON::PP qw(encode_json);
use YAML::Tiny;

sub record {
  my ($event) = @_;
  CORE::open(my $trace, '>>', $ENV{RVC_TEST_TRACE}) or die $!;
  print {$trace} encode_json($event), "\n";
  close $trace;
}

BEGIN {
  # Install before the production script is compiled. No process can escape
  # this harness, including the receiver's hard-coded candump pipe.
  *CORE::GLOBAL::system = sub {
    die 'Unexpected system command' unless @_ == 1 && $_[0] =~ /^cansend can0 [0-9A-F]{8}#[0-9A-F]{16}$/;
    record({ kind => 'can', command => $_[0] });
    $? = 0;
    return 0;
  };
  *CORE::GLOBAL::exec = sub { die 'exec is forbidden in offline tests' };
  *CORE::GLOBAL::readpipe = sub { die 'readpipe is forbidden in offline tests' };
  *CORE::GLOBAL::open = sub (*;$@) {
    if (@_ == 2 && $_[1] eq 'candump -ta can0 |') {
      no strict 'refs';
      my $handle = caller() . '::' . $_[0];
      return CORE::open(*{$handle}, '<', \$ENV{RVC_TEST_FRAMES});
    }
    die 'Unexpected process pipe' if @_ == 2 && $_[1] =~ /\|/;
    return @_ == 2 ? CORE::open($_[0], $_[1]) : CORE::open($_[0], $_[1], $_[2]);
  };
}

# Preserve the real YAML decoder and actual repository specification, while
# redirecting the appliance-only default path in the receive bridge.
my $read = YAML::Tiny->can('read');
{
  no warnings 'redefine';
  *YAML::Tiny::read = sub {
    my ($class, $path) = @_;
    $path = $ENV{RVC_TEST_SPEC} if $path eq '/coachproxy/etc/rvc-spec.yml';
    return $read->($class, $path);
  };
}
1;
