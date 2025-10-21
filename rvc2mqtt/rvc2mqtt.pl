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
use warnings;
use Net::MQTT::Simple "localhost";
use Getopt::Long qw(GetOptions);
use YAML::Tiny;
use JSON;
use Switch;
use Scalar::Util qw(looks_like_number);

my $json = JSON->new->utf8->canonical;
my $debug;
GetOptions(
  'debug' => \$debug,
) or usage();

my $yaml = YAML::Tiny->read('/coachproxy/etc/rvc-spec.yml');
our $decoders = $yaml->[0];

my $api_version = $decoders->{'API_VERSION'};
retain 'RVC/API_VERSION' => $api_version;

open FILE,'candump -ta can0 |' or die("Cannot start candump " . $! ."\n");

# candump output looks like:
#
# (1550629697.810979)  can0  19FFD442   [8]  01 02 F7 FF FF FF FF FF

while (my $line = <FILE>) {
  chomp($line);
  my @line_parts = split(' ', $line);
  my $pkttime  = $line_parts[0];
  $pkttime     =~ s/[^0-9\.]//g;
  my $binCanId = sprintf("%b", hex($line_parts[2]));
  my $prio     = sprintf(  "%X", oct("0b".substr( $binCanId,  0,  3)));
  my $dgn      = sprintf("%05X", oct("0b".substr( $binCanId,  4, 17)));
  my $srcAD    = sprintf("%02X", oct("0b".substr( $binCanId, 21,  8)));
  my $pckts    = $line_parts[3];
  $pckts       =~ s/[^0-9]//g;

  my $data     = '';
  for (my $i = 4; $i < scalar(@line_parts); $i++) {
    $data .= $line_parts[$i];
  }
  our $char = "$pkttime,$prio,$dgn,$srcAD,$pckts,$data";
  processPacket();
}
close FILE;
exit;


sub processPacket {
	our $char;

	if ($char) {
		$char =~ s/\xd//g;
		our ($pkttime, $prio, $dgn, $src, $pkts, $data) = split(',', $char);
		our $partsec = ($pkttime - int($pkttime)) * 100000;
		our $dgnHi = substr($dgn,0,3) if (defined($dgn));
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime($pkttime);
    $year += 1900;
    $mon++;

    my %result = decode($dgn, $data);
    if (%result) {
      $result{timestamp} = $pkttime;
      my $result_json = $json->encode(\%result);
      my $topic = "RVC/$result{name}";
      if (defined($result{instance})) {
        $topic .= '/' . $result{instance};
      }
      if (!$debug) {
        publish $topic => $result_json;
        publish_synthetic_dimmer_status(\%result);
      }
      printf("%4d-%02d-%02d %02d:%02d:%02d.%05d %s %s %s %s\n", $year, $mon, $mday, $hour, $min, $sec, $partsec, $src, $data, $topic, $result_json);
    }
	}
}

sub publish_synthetic_dimmer_status {
  my ($result_ref) = @_;
  return unless $result_ref;

  my %result = %{$result_ref};

  return unless $result{name} && $result{name} eq 'DC_COMPONENT_DRIVER_STATUS_1';
  return unless defined $result{driver_index};
  return unless looks_like_number($result{driver_index});
  return unless defined $result{'output_status'} && looks_like_number($result{'output_status'});

  my $instance = int($result{driver_index}) & 0xFF;
  my $is_on = int($result{'output_status'}) == 1;
  my $brightness = $is_on ? 100 : 0;
  my $load_status_value = $is_on ? '01' : '00';
  my $load_status_definition = $is_on ? 'operating status is non-zero or flashing' : 'operating status is zero';
  my $data = build_synthetic_dimmer_data($instance, $brightness, $is_on);

  my %payload = (
    dgn => '1FEDA',
    data => $data,
    name => 'DC_DIMMER_STATUS_3',
    instance => $instance,
    group => '11111111',
    'operating status (brightness)' => $brightness,
    'lock status' => '00',
    'lock status definition' => 'load is unlocked',
    'overcurrent status' => '11',
    'overcurrent status definition' => 'overcurrent status is unavailable or not supported',
    'override status' => '11',
    'override status definition' => 'override status is unavailable or not supported',
    'enable status' => '11',
    'enable status definition' => 'enable status is unavailable or not supported',
    'interlock status' => '00',
    'interlock status definition' => 'interlock command is not active',
    'delay/duration' => 255,
    'last command' => 5,
    'last command definition' => 'toggle',
    'load status' => $load_status_value,
    'load status definition' => $load_status_definition,
    timestamp => $result{timestamp},
  );

  publish "RVC/DC_DIMMER_STATUS_3/$instance" => $json->encode(\%payload);
}

sub build_synthetic_dimmer_data {
  my ($instance, $brightness, $is_on) = @_;

  $instance = 0 unless defined $instance && looks_like_number($instance);
  $instance = int($instance) & 0xFF;

  $brightness = 0 unless defined $brightness && looks_like_number($brightness);
  $brightness = 0 if $brightness < 0;
  $brightness = 100 if $brightness > 100;
  my $scaled_brightness = int($brightness * 2);
  $scaled_brightness = 255 if $scaled_brightness > 255;

  my $byte0 = $instance;
  my $byte1 = 0xFF;
  my $byte2 = $scaled_brightness;
  my $byte3 = 0xFC;
  my $byte4 = 0xFF;
  my $byte5 = 0x05;
  my $byte6 = $is_on ? 0x04 : 0x00;
  my $byte7 = 0xFF;

  return sprintf("%02X%02X%02X%02X%02X%02X%02X%02X", $byte0, $byte1, $byte2, $byte3, $byte4, $byte5, $byte6, $byte7);
}


# Params:
#   DGN (hex string)
#   Data (hex string)
sub decode() {
  my $dgn  = shift(@_);
  my $data = shift(@_);
  my %result;
  our $decoders;

  # Locate the decoder for this DGN, supporting DGN ranges
  my $decoder = $decoders->{$dgn};

  # If not found, try to match by DGN range
  if (!defined $decoder) {
    foreach my $key (keys %$decoders) {
      next unless $key =~ /^[0-9A-Fa-f]{5}$/;
      my $entry = $decoders->{$key};
      if (exists $entry->{range}) {
        my ($start, $end) = $entry->{range} =~ /^([0-9A-Fa-f]+)-([0-9A-Fa-f]+)$/;
        if (defined $start && defined $end) {
          my $dgn_num = hex($dgn);
          if ($dgn_num >= hex($start) && $dgn_num <= hex($end)) {
            $decoder = $entry;
            last;
          }
        }
      }
    }
  }

  $result{dgn} = $dgn;
  $result{data} = $data;
  $result{name} = "UNKNOWN-$dgn";
  return %result unless defined $decoder;

  $result{name} = $decoder->{name};

  my @parameters;

  # If this decoder has an alias specified, load the alias's parameters first.
  # If needed, parameters can also be overridden within the base decoder.
  push(@parameters, @{$decoders->{$decoder->{alias}}->{parameters}}) if ($decoder->{alias});

  # Add the parameters from the specified decoder
  push(@parameters, @{$decoder->{parameters}}) if ($decoder->{parameters});

  # Loop through each parameter for the DGN and decode it.
  my $parameter_count = 0;
  foreach my $parameter (@parameters) {
    my $name = $parameter->{name};
    my $type = $parameter->{type} // 'uint';
    my $unit = $parameter->{unit};
    my $values = $parameter->{values};

    # Get the specified byte or byte range, in hex
    my $bytes = get_bytes($data, $parameter->{byte});

    # Store the decoded value in decimal
    my $value = hex($bytes);

    # Get the specified bit or bit range, if applicable
    if (defined $parameter->{bit}) {
      my $bits = get_bits($bytes, $parameter->{bit});
      $value = $bits;

      # Convert from binary to decimal for all bit field types
      if (substr($type, 0, 4) eq 'uint' || $type eq 'bit' || $type eq 'bit2' || $type eq 'bit4') {
        $value = oct('0b' . $bits);
      }
    }

    # Convert units, such as %, V, A, ºC
    if (defined $unit) {
      $value = convert_unit($value, $unit, $type);
    }

    $result{$name} = $value;

    # Also provide temperatures in ºF
    if (defined $unit && lc($unit) eq 'deg c') {
      $result{$name . " F"} = tempC2F($value);
    }

    # Decode value definitions, if provided.
    if ($values) {
      my $value_def = 'undefined';
      
      # Try direct lookup first
      if ($values->{$value}) {
        $value_def = $values->{$value};
      }
      # Then try string conversion lookup - most values in YAML are stored as strings like "0", "1"
      elsif (looks_like_number($value)) {
        # Format single digit values as strings like "0", "1"
        my $key = "$value";
        $value_def = $values->{$key} if ($values->{$key});
        
        # If still undefined, try different formats based on the parameter type
        if ($value_def eq 'undefined') {
          # For simple bit types, try basic formats first
          if ($type eq 'bit' || $type eq 'uint2' || $type eq 'bit2') {
            # Try 2-digit decimal format (00, 01, etc.) for bit2/uint2 types
            if ($type eq 'bit2' || $type eq 'uint2') {
              $key = sprintf("%02d", $value);
              $value_def = $values->{$key} if ($values->{$key});
            }
            
            # Try binary format (00, 01, 10, 11) for 2-bit values
            if ($value_def eq 'undefined' && $value < 4) {
              $key = sprintf("%02b", $value);
              $value_def = $values->{$key} if ($values->{$key});
            }
          }
          # For 4-bit types, try 4-bit formats
          elsif ($type eq 'bit4' || $type eq 'uint4') {
            # Try 4-digit decimal format first
            $key = sprintf("%04d", $value);
            $value_def = $values->{$key} if ($values->{$key});
            
            # Try binary format (0000, 0001, 0010, etc.) for 4-bit values
            if ($value_def eq 'undefined' && $value < 16) {
              $key = sprintf("%04b", $value);
              $value_def = $values->{$key} if ($values->{$key});
            }
          }
          # For other types, try general formats
          else {
            # Try 2-digit decimal format (00, 01, etc.)
            $key = sprintf("%02d", $value);
            $value_def = $values->{$key} if ($values->{$key});
            
            # Try 4-digit decimal format (0000, 0001, etc.)
            if ($value_def eq 'undefined') {
              $key = sprintf("%04d", $value);
              $value_def = $values->{$key} if ($values->{$key});
            }
            
            # Try binary formats as last resort
            if ($value_def eq 'undefined' && $value < 4) {
              $key = sprintf("%02b", $value);
              $value_def = $values->{$key} if ($values->{$key});
            }
            
            if ($value_def eq 'undefined' && $value < 16) {
              $key = sprintf("%04b", $value);
              $value_def = $values->{$key} if ($values->{$key});
            }
          }
        }
      }
      
      $result{"$name definition"} = $value_def;
    }

    $parameter_count++;
  }

  if ($parameter_count == 0) {
    $result{'DECODER PENDING'} = 1;
  }

  return %result;
}


# Given a hex string (e.g. "020064C524C52400") and a byte range (e.g. "2" or
# "2-3"), return the appropriate hex string for those bytes (e.g. "6400"). Per
# RV-C spec, "data consisting of two or more bytes shall be transmitted least
# significant byte first." Thus, the byte order must be swapped if a range is
# requested.
sub get_bytes() {
  my $data = shift(@_);
  my $byterange = shift(@_);
  my $bytes = "";
  my $sub_bytes = "";

  my ($start_byte, $end_byte) = split(/-/, $byterange);
  $end_byte = $start_byte if !defined $end_byte;
  eval {
    if (($start_byte * 2) + ($end_byte - $start_byte + 1) * 2 > length($data)) {
      print "bytes of out range";
      return "";
    }
   $sub_bytes = substr($data, $start_byte * 2, ($end_byte - $start_byte + 1) * 2);
  };

  if ($@) {
   print "sub string error";
   return "";
  }
  
  # Swap the order of bytes
  eval {
    $bytes = join '', reverse split /(..)/, $sub_bytes;
  };
  if ($@) {
    print "An error occured splitting: $sub_bytes";
  }
  return $bytes;
}


# Given a hex string (e.g. "64C5") and a bit range (e.g. "3-4"), return the
# requested binary representation (e.g. "1011").
sub get_bits() {
  my $bytes = shift(@_);
  my $bitrange = shift(@_);
  my $bits = hex2bin($bytes);

  my ($start_bit, $end_bit) = split(/-/, $bitrange);
  $end_bit = $start_bit if !defined $end_bit;

  my $sub_bits = substr($bits, 7 - $end_bit, $end_bit - $start_bit + 1);

  return $sub_bits;
}


# Convert a single hex byte (e.g. "F7") to an 8-character binary string.
# https://www.nntp.perl.org/group/perl.beginners/2003/01/msg40076.html
sub hex2bin() {
  my $hex = shift(@_);
  return unpack("B8", pack("C", hex $hex));
}


# Convert a temperature from C to F, rounded to tenths of a degree.
sub tempC2F() {
    my ($tempC) = @_;

    if ($tempC eq "n/a") {
        return "n/a";  # Return "n/a" directly if input is "n/a"
    } else {
        # Proceed with the calculation only if it's not "n/a"
        return int((($tempC * 9 / 5) + 32) * 10) / 10;
    }
}


# Round numbers (from Math::Round)
sub nearest {
 my $targ = abs(shift);
 my $half = 0.50000000000008;
 my @res  = map {
  if ($_ >= 0) { $targ * int(($_ + $half * $targ) / $targ); }
     else { $targ * POSIX::ceil(($_ - $half * $targ) / $targ); }
 } @_;

 return $res[0];
}


# For a given unit (e.g. "V") and datatype (e.g. "uint16"), compute and
# return the actual value based on RV-C table 5.3.
sub convert_unit() {
  my $value = shift(@_);
  my $unit = shift(@_);
  my $type = shift(@_);

  my $new_value = $value;

  switch (lc($unit)) {
    case 'pct' {
      $new_value = 'n/a';
      $new_value = $value/2 unless ($value == 255);
    }
    case 'deg c' {
      $new_value = 'n/a';
      switch ($type) {
        case 'uint8'  { $new_value = $value - 40 unless ($value == 255) }
        case 'uint16' { $new_value = nearest(.1, $value * 0.03125 - 273) unless ($value == 65535) }
      }
    }
    case "v" {
      $new_value = 'n/a';
      switch ($type) {
        case 'uint8'  { $new_value = $value unless ($value == 255) }
        case 'uint16' { $new_value = nearest(.1, $value * 0.05) unless ($value == 65535) }
      }
    }
    case "a" {
      $new_value = 'n/a';
      switch ($type) {
        case 'uint8'  { $new_value = $value }
        case 'uint16' { $new_value = nearest(.1, $value * 0.05 - 1600) unless ($value == 65535) }
        case 'uint32' { $new_value = nearest(.01, $value * 0.001 - 2000000) unless $value == 4294967295 }
      }
    }
    case "hz" {
      switch ($type) {
        case 'uint8'  { $new_value = $value }
        case 'uint16' { $new_value = nearest(.1, $value / 128) }
      }
    }
    case "sec" {
      switch ($type) {
        case 'uint8' {
          # If duration is between 240 and 251, it's measured in minutes starting at 5 minutes.
          $new_value = (($value - 240) + 4 ) * 60 if ($value > 240 && $value < 251);
        }
        case 'uint16' { $new_value = $value * 2 }
      }
    }
    case "bitmap" {
      $new_value = sprintf('%08b', $value);
    }
  }

  return $new_value;
}

# Print out simple command line usage.
sub usage {
  print qq{
    Usage:

    --debug               print results but do not publish to mqtt
  };
  print "\n";

  exit(1);
}
