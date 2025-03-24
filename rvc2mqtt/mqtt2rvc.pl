#!/usr/bin/perl -w
#
# Copyright (C) 2025
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
use POSIX;
use IO::Handle;

my $debug;
my $spec_file = '/coachproxy/etc/rvc-spec.yml';
my $can_interface = 'can0';
my $source_address = 'A0';  # Default source address, configurable
my $priority = '6';         # Default priority, configurable

GetOptions(
  'debug' => \$debug,
  'specfile=s' => \$spec_file,
  'interface=s' => \$can_interface,
  'source=s' => \$source_address,
  'priority=s' => \$priority,
) or usage();

# Load the RV-C specification
print "Loading RV-C specification from $spec_file\n" if $debug;
my $yaml = YAML::Tiny->read($spec_file);
our $encoders = $yaml->[0];

# Map of known DGNs to their names for reverse lookup
my %dgn_map;
foreach my $dgn (keys %$encoders) {
  # Skip non-DGN entries like API_VERSION
  next if $dgn !~ /^[0-9A-F]+$/;
  
  my $name = $encoders->{$dgn}->{name};
  $dgn_map{$name} = $dgn if defined $name;
}

# Subscribe to all SET topics
print "Subscribing to MQTT SET topics\n" if $debug;
subscribe_topic("RVC/+/set");
subscribe_topic("RVC/+/+/set");

# Open a pipe to cansend
print "Using CAN interface: $can_interface\n" if $debug;

# Start the MQTT event loop
print "MQTT to RV-C bridge started. Waiting for commands...\n";
mqtt_loop();

# --------------------------------------------------------------
# MQTT Callback - Process incoming SET commands
# --------------------------------------------------------------
sub mqtt_loop {
  Net::MQTT::Simple->run_client(
    on_publish => sub {
      my ($topic, $message) = @_;
      
      # Skip if not a set topic
      return unless $topic =~ m|^RVC/(.+?)/set$|;
      
      my $dgn_name = $1;
      my $instance;
      
      # Check if topic includes an instance
      if ($dgn_name =~ m|^(.+?)/(\d+)$|) {
        $dgn_name = $1;
        $instance = $2;
      }
      
      # Process the message
      eval {
        process_mqtt_message($dgn_name, $instance, $message);
      };
      
      if ($@) {
        print "Error processing message: $@\n";
      }
    }
  );
}

# --------------------------------------------------------------
# Process an incoming MQTT message and send to CAN
# --------------------------------------------------------------
sub process_mqtt_message {
  my ($dgn_name, $instance, $message) = @_;
  my $json;
  
  # Parse JSON payload
  eval {
    $json = decode_json($message);
  };
  
  if ($@) {
    die "Invalid JSON payload: $@\n";
  }
  
  # Get instance from JSON if not in topic
  $instance = $json->{instance} if (!defined $instance && defined $json->{instance});
  
  # Look up DGN code from name
  my $dgn = $dgn_map{$dgn_name};
  if (!defined $dgn) {
    die "Unknown DGN name: $dgn_name\n";
  }
  
  # Get the encoder for this DGN
  my $encoder = $encoders->{$dgn};
  if (!defined $encoder) {
    die "No encoder found for DGN: $dgn ($dgn_name)\n";
  }
  
  # Handle aliases - if this is an alias, get the original parameters
  my @parameters;
  if (defined $encoder->{alias}) {
    my $alias_dgn = $encoder->{alias};
    if (defined $encoders->{$alias_dgn}->{parameters}) {
      push(@parameters, @{$encoders->{$alias_dgn}->{parameters}});
    }
  }
  
  # Add the parameters from this DGN
  if (defined $encoder->{parameters}) {
    push(@parameters, @{$encoder->{parameters}});
  }
  
  # Build the data packet
  my $data = build_data_packet(\@parameters, $json, $instance);
  
  # Send to CAN bus
  send_can_message($dgn, $data);
  
  print "Sent message to CAN: DGN=$dgn, Data=$data\n" if $debug;
}

# --------------------------------------------------------------
# Build a data packet from parameters and JSON values
# --------------------------------------------------------------
sub build_data_packet {
  my ($parameters, $json, $instance) = @_;
  
  # Initialize 8-byte data array with zeros
  my @bytes = (0, 0, 0, 0, 0, 0, 0, 0);
  
  # Set instance if needed
  foreach my $param (@$parameters) {
    if ($param->{name} eq 'instance' && defined $instance) {
      $json->{instance} = $instance;
    }
  }
  
  # Process each parameter
  foreach my $param (@$parameters) {
    my $name = $param->{name};
    my $value;
    
    # Skip if parameter is not in JSON
    next unless defined $json->{$name};
    
    $value = $json->{$name};
    
    # Get byte range
    my $byte_spec = $param->{byte};
    my ($start_byte, $end_byte) = split(/-/, $byte_spec);
    $end_byte = $start_byte if !defined $end_byte;
    
    # Get bit range if specified
    my $bit_start = 0;
    my $bit_end = 7;
    if (defined $param->{bit}) {
      my $bit_spec = $param->{bit};
      ($bit_start, $bit_end) = split(/-/, $bit_spec);
      $bit_end = $bit_start if !defined $bit_end;
    }
    
    # Convert value according to unit and type
    my $type = $param->{type} // 'uint';
    my $unit = $param->{unit};
    my $encoded_value = encode_value($value, $unit, $type);
    
    # Handle bit fields
    if (defined $param->{bit}) {
      # Get number of bits
      my $num_bits = $bit_end - $bit_start + 1;
      
      # Convert to binary
      my $bit_value;
      
      # Check for defined values
      if (defined $param->{values}) {
        # Look up value definition
        foreach my $key (keys %{$param->{values}}) {
          if ($param->{values}->{$key} eq $value) {
            $bit_value = $key;
            last;
          }
        }
        
        # If not found, try direct match (numeric values)
        if (!defined $bit_value) {
          $bit_value = $value;
        }
      } else {
        # No defined values, use direct value
        $bit_value = $encoded_value;
      }
      
      # Ensure bit_value is numeric
      $bit_value = ($bit_value =~ /^[01]+$/) ? oct("0b$bit_value") : int($bit_value);
      
      # Create a mask for these bits
      my $mask = ((1 << $num_bits) - 1) << $bit_start;
      
      # Clear bits in byte
      $bytes[$start_byte] &= ~$mask;
      
      # Set bits with new value
      $bytes[$start_byte] |= ($bit_value << $bit_start) & $mask;
    } 
    # Handle multi-byte values
    elsif ($start_byte != $end_byte) {
      # Calculate number of bytes
      my $num_bytes = $end_byte - $start_byte + 1;
      
      # Split the value into bytes - LSB first per RV-C spec
      for (my $i = 0; $i < $num_bytes; $i++) {
        $bytes[$start_byte + $i] = ($encoded_value >> (8 * $i)) & 0xFF;
      }
    } 
    # Handle single byte values
    else {
      $bytes[$start_byte] = $encoded_value & 0xFF;
    }
  }
  
  # Convert byte array to hex string
  my $data = '';
  foreach my $byte (@bytes) {
    $data .= sprintf("%02X", $byte);
  }
  
  return $data;
}

# --------------------------------------------------------------
# Encode a value according to unit and data type (reverse of convert_unit)
# --------------------------------------------------------------
sub encode_value {
  my ($value, $unit, $type) = @_;
  
  return $value if (!defined $unit || $value eq 'n/a');
  
  my $encoded_value = $value;
  
  switch (lc($unit)) {
    case 'pct' {
      $encoded_value = $value * 2;
      $encoded_value = 255 if ($value eq 'n/a');
    }
    case 'deg c' {
      switch ($type) {
        case 'uint8'  { $encoded_value = $value + 40; $encoded_value = 255 if ($value eq 'n/a'); }
        case 'uint16' { $encoded_value = int(($value + 273) / 0.03125); $encoded_value = 65535 if ($value eq 'n/a'); }
      }
    }
    case "v" {
      switch ($type) {
        case 'uint8'  { $encoded_value = $value; $encoded_value = 255 if ($value eq 'n/a'); }
        case 'uint16' { $encoded_value = int($value / 0.05); $encoded_value = 65535 if ($value eq 'n/a'); }
      }
    }
    case "a" {
      switch ($type) {
        case 'uint8'  { $encoded_value = $value; }
        case 'uint16' { $encoded_value = int(($value + 1600) / 0.05); $encoded_value = 65535 if ($value eq 'n/a'); }
        case 'uint32' { $encoded_value = int(($value + 2000000) / 0.001); $encoded_value = 4294967295 if ($value eq 'n/a'); }
      }
    }
    case "hz" {
      switch ($type) {
        case 'uint8'  { $encoded_value = $value; }
        case 'uint16' { $encoded_value = int($value * 128); }
      }
    }
    case "sec" {
      switch ($type) {
        case 'uint8' {
          # If duration is between 5 and 15 minutes, encode in special range
          if ($value >= 300 && $value <= 900) {
            $encoded_value = int($value / 60) - 4 + 240;
          } else {
            $encoded_value = $value;
          }
        }
        case 'uint16' { $encoded_value = int($value / 2); }
      }
    }
    case "bitmap" {
      $encoded_value = oct("0b$value") if ($value =~ /^[01]+$/);
    }
  }
  
  return $encoded_value;
}

# --------------------------------------------------------------
# Send a CAN message using cansend
# --------------------------------------------------------------
sub send_can_message {
  my ($dgn, $data) = @_;
  
  # Calculate CAN ID from DGN, priority, and source address
  # CAN ID format: PPP DD DDDDDDDDDDDDDDD SSS
  # P = Priority bits (3), D = Data Group Number (18), S = Source Address (8)
  
  # Convert hex DGN to binary
  my $dgn_bin = sprintf("%018b", hex($dgn));
  
  # Convert priority to binary (3 bits)
  my $prio_bin = sprintf("%03b", hex($priority));
  
  # Convert source address to binary (8 bits)
  my $source_bin = sprintf("%08b", hex($source_address));
  
  # Combine to form CAN ID
  my $can_id_bin = $prio_bin . "0" . $dgn_bin . $source_bin;
  
  # Convert binary CAN ID to hex
  my $can_id = sprintf("%08X", oct("0b$can_id_bin"));
  
  # Build cansend command
  my $command = "cansend $can_interface $can_id#$data";
  
  # Execute command
  if ($debug) {
    print "Executing: $command\n";
  } else {
    system($command);
  }
}

# --------------------------------------------------------------
# Print usage information
# --------------------------------------------------------------
sub usage {
  print q{
    Usage: mqtt2rvc.pl [options]
    
    This script subscribes to MQTT topics and sends commands to the RV-C CAN bus.
    
    Options:
      --debug             Enable debug output
      --specfile=FILE     Path to RV-C spec YAML file (default: /coachproxy/etc/rvc-spec.yml)
      --interface=IF      CAN interface to use (default: can0)
      --source=ADDR       Source address to use in hex (default: A0)
      --priority=PRIO     Priority to use in hex (default: 6)
  };
  print "\n";
  
  exit(1);
}