#!/usr/bin/perl -w
#
# Copyright (C) 2019 Wandertech LLC
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use strict;
no strict 'refs';
use Scalar::Util qw(looks_like_number);

our $debug=0;

our %deccommands=(0=>'Set Level(delay)',1=>'On (Duration)',2=>'On (Delay)',3=>'Off (Delay)',
    5=>'Toggle',6=>'Memory Off',17=>'Ramp Brightness',18=>'Ramp Toggle',19=>'Ramp Up',
    20=>'Ramp Down',21=>'Ramp Down/Up');

if ( scalar(@ARGV) < 2 ) {
	print "ERR: Insufficient command line data provided.\n";
	usage();
}

if(!exists($deccommands{$ARGV[1]})) {
    print "ERR: Command not allowed.  Please see command list below.\n";
    usage();
}

my $instance = $ARGV[0];
my $command  = $ARGV[1];
my $brightness_arg = $ARGV[2];
my $duration_arg   = $ARGV[3];
my $bypass_arg     = $ARGV[4];

validate_numeric($instance, "instance", 0, 255);
validate_numeric($command,  "command",  0, 255);
$instance = int($instance + 0);
$command  = int($command + 0);

my $brightness = defined $brightness_arg
    ? resolve_brightness($brightness_arg)
    : percentage_to_byte(100);

my $duration = defined $duration_arg ? $duration_arg : 255;
validate_numeric($duration, "duration", 0, 255) if defined $duration_arg;
$duration = int($duration + 0);

my $bypass = defined $bypass_arg ? $bypass_arg : 0;
validate_numeric($bypass, "bypass", 0, 255) if defined $bypass_arg;
$bypass = int($bypass + 0);

our ($prio,$dgnhi,$dgnlo,$srcAD)=(6,'1FE','DB',99);
our $binCanId=sprintf("%b0%b%b%b",hex($prio),hex($dgnhi),hex($dgnlo),hex($srcAD));

our $hexData=sprintf("%02XFF%02X%02X%02X00FFFF",$instance,$brightness,$command,$duration);
our $hexCanId=sprintf("%08X",oct("0b$binCanId"));

system('cansend can0 '.$hexCanId."#".$hexData) if (!$debug);
print 'cansend can0 '.$hexCanId."#".$hexData."\n" if ($debug);
if($command==0 || $command==17) {
	sleep 5 if($command==17 && $bypass==0);
	$brightness=0;
	$command=21;
	$duration=0;
	$hexData=sprintf("%02XFF%02X%02X%02X00FFFF",$instance,$brightness,$command,$duration);
	system('cansend can0 '.$hexCanId."#".$hexData) if (!$debug);
	print 'cansend can0 '.$hexCanId."#".$hexData."\n" if ($debug);
	$command=4;
	$hexData=sprintf("%02XFF%02X%02X%02X00FFFF",$instance,$brightness,$command,$duration);
	system('cansend can0 '.$hexCanId."#".$hexData) if (!$debug);
	print 'cansend can0 '.$hexCanId."#".$hexData."\n" if ($debug);
}


sub usage {
	print "Usage: \n";
	print "\tdimmer_RV-C.pl <load-id> <command> {brightness} {time}\n";
	print "\n\t<load-id> is required and one of:\n";
	print "\t\t {1..99} (check the *.dc_loads.txt files for a list)\n";
	print "\n\t<command> is required and one of:\n";
	foreach my $key ( sort {$a <=> $b} keys %deccommands ) {
		print "\t\t".$key." = ".$deccommands{$key} . "\n";
	}
	print "\n";
	print "\t{brightness}	- 0 to 100 (percentage) or 0 to 200 (raw)	- Optional\n";
	print "\t{time}		- 0 to 240 (seconds)	- Optional\n";
	print "\n";
    exit(1);
}

sub resolve_brightness {
    my ($value) = @_;

    if (!defined $value) {
        return percentage_to_byte(100);
    }

    if (!looks_like_number($value)) {
        print "ERR: Brightness must be numeric (received '$value').\n";
        exit(1);
    }

    my $numeric = 0 + $value;
    if ($numeric < 0) {
        print "ERR: Brightness must be >= 0 (received $numeric).\n";
        exit(1);
    }

    if ($numeric <= 100) {
        return percentage_to_byte($numeric);
    }

    if ($numeric <= 200) {
        return clamp_raw_level($numeric);
    }

    print "ERR: Brightness must be 0-100 (percentage) or 0-200 (raw). Received $numeric.\n";
    exit(1);
}

sub percentage_to_byte {
    my ($percentage) = @_;
    $percentage = 0 if $percentage < 0;
    $percentage = 100 if $percentage > 100;
    return int(($percentage * 2) + 0.5);
}

sub clamp_raw_level {
    my ($level) = @_;
    $level = 0 if $level < 0;
    $level = 200 if $level > 200;
    return int($level + 0.5);
}

sub validate_numeric {
    my ($value, $label, $min, $max) = @_;
    return unless defined $value;

    if (!looks_like_number($value)) {
        print "ERR: $label must be numeric (received '$value').\n";
        exit(1);
    }

    my $numeric = 0 + $value;
    if ($numeric < $min || $numeric > $max) {
        print "ERR: $label must be between $min and $max (received $numeric).\n";
        exit(1);
    }
}
