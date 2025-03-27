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
use Net::MQTT::Simple;
use Socket;
use Getopt::Long qw(GetOptions);
use YAML::Tiny;
use JSON;
use Switch;
use Time::HiRes qw(time sleep);

my $debug;
my $spec_file = '/coachproxy/etc/rvc-spec.yml';
my $can_interface = 'can0';
my $source_address = 'A0';  # Default source address, configurable
my $priority = '6';         # Default priority, configurable
my $mqtt_server = 'localhost';  # Default MQTT server, configurable
my $mqtt_port = 1883;           # Default MQTT port, configurable
my $mqtt_user = '';             # MQTT username if required
my $mqtt_password = '';         # MQTT password if required

GetOptions(
  'debug' => \$debug,
  'specfile=s' => \$spec_file,
  'interface=s' => \$can_interface,
  'source=s' => \$source_address,
  'priority=s' => \$priority,
  'mqtt=s' => \$mqtt_server,
  'mqttport=i' => \$mqtt_port,
  'user=s' => \$mqtt_user,
  'password=s' => \$mqtt_password,
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

# Create MQTT client using Net::MQTT::Simple
print "Connecting to MQTT broker at $mqtt_server:$mqtt_port\n" if $debug;
my $mqtt = Net::MQTT::Simple->new("$mqtt_server:$mqtt_port");

# Set up authentication if username is provided
if ($mqtt_user) {
  print "Using MQTT authentication with username: $mqtt_user\n" if $debug;
  $mqtt->login($mqtt_user, $mqtt_password);
}

# Subscribe to RVC topics with callbacks
print "Subscribing to MQTT topics\n" if $debug;
$mqtt->subscribe("RVC/+/set" => \&handle_mqtt_message);
$mqtt->subscribe("RVC/+/+/set" => \&handle_mqtt_message);

# Print status
print "Using CAN interface: $can_interface\n" if $debug;
print "MQTT to RV-C bridge started. Waiting for commands...\n";

# Start the MQTT event loop - this will handle callbacks automatically
$mqtt->run();

# MQTT message callback handler
sub handle_mqtt_message {
  my ($topic, $message) = @_;
  
  print "MQTT: Received message on topic $topic: $message\n" if $debug;
  
  # Process based on topic patterns
  if ($topic =~ m|^RVC/(.+?)/set$|) {
    # Simple topic pattern: RVC/name/set
    my $dgn_name = $1;
    my $instance;
    
    # Check if name includes an instance
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
  elsif ($topic =~ m|^RVC/(.+?)/(.+?)/set$|) {
    # Instance topic pattern: RVC/name/instance/set
    my $dgn_name = $1;
    my $instance = $2;
    
    # Process the message
    eval {
      process_mqtt_message($dgn_name, $instance, $message);
    };
    
    if ($@) {
      print "Error processing message: $@\n";
    }
  }
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
  
  # Apply RV-C specific formatting rules based on DGN
  $data = format_rvc_message($dgn, $data);
  
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
# Encode a value according to unit and data type
# --------------------------------------------------------------
# --------------------------------------------------------------
# --------------------------------------------------------------
# Format RV-C message according to the specification
# --------------------------------------------------------------
sub format_rvc_message {
  my ($dgn, $data) = @_;
  
  # Return data as-is if no special formatting is needed or no spec exists
  return $data unless (defined $dgn && defined $encoders->{$dgn});
  
  print "Formatting message for DGN $dgn using specification\n" if $debug;
  print "Original data: $data\n" if $debug;
  
  # Convert hex string to bytes for safer handling
  my @bytes = unpack("(A2)*", $data);
  
  # Ensure we have 8 bytes (pad if needed)
  while (scalar(@bytes) < 8) {
    push(@bytes, "00");
  }
  
  # Get the encoder parameters for this DGN
  my $encoder = $encoders->{$dgn};
  my @parameters;
  
  # Handle aliases - if this is an alias, get the original parameters
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
  
  # Create a map of defined bytes and bits
  my %defined_bytes;
  my %defined_bits;
  
  # Mark which bytes and bits are defined in the spec
  foreach my $param (@parameters) {
    next unless defined $param->{byte};
    
    my $byte_spec = $param->{byte};
    my ($start_byte, $end_byte) = split(/-/, $byte_spec);
    $end_byte = $start_byte if !defined $end_byte;
    
    # Mark these bytes as defined
    for my $b ($start_byte..$end_byte) {
      $defined_bytes{$b} = 1;
      
      # If bit field is specified, mark which bits are defined
      if (defined $param->{bit}) {
        my $bit_spec = $param->{bit};
        my ($start_bit, $end_bit) = split(/-/, $bit_spec);
        $end_bit = $start_bit if !defined $end_bit;
        
        # Create a mask for the defined bits
        my $mask = 0;
        for my $bit ($start_bit..$end_bit) {
          $mask |= (1 << $bit);
        }
        
        # Initialize bit mask for this byte if not already set
        $defined_bits{$b} = 0 unless exists $defined_bits{$b};
        
        # Add these bits to the mask
        $defined_bits{$b} |= $mask;
      }
    }
  }
  
  # Process each byte according to spec
  for my $b (0..7) {
    # If byte is not defined in spec, set to FF
    if (!exists $defined_bytes{$b}) {
      $bytes[$b] = "FF";
      print "  Byte $b not defined in spec, setting to FF\n" if $debug;
    }
    # If byte has bit definitions, set undefined bits to 1
    elsif (exists $defined_bits{$b}) {
      my $mask = $defined_bits{$b};
      my $byte_value = hex($bytes[$b]);
      
      # Keep defined bits as is, set undefined bits to 1
      # ~mask gives 1s for undefined bits, & 0xFF keeps within byte range
      $byte_value = ($byte_value & $mask) | (~$mask & 0xFF);
      $bytes[$b] = sprintf("%02X", $byte_value);
      
      print "  Byte $b has bit mask " . sprintf("%08b", $mask) .
            ", setting undefined bits to 1\n" if $debug;
    }
  }
  
  # Special handling for unit-specific values
  foreach my $param (@parameters) {
    next unless (defined $param->{byte} && defined $param->{unit});
    
    my $byte_spec = $param->{byte};
    my ($start_byte, $end_byte) = split(/-/, $byte_spec);
    $end_byte = $start_byte if !defined $end_byte;
    
    # Special handling for temperature Dead band fields
    if ($param->{unit} =~ /deg c/i && $param->{name} eq "Dead band") {
      # Force Dead band to be "n/a" (0xFF) for certain messages
      for my $b ($start_byte..$end_byte) {
        $bytes[$b] = "FF";
        print "  Setting $param->{name} (byte $b) to FF (n/a)\n" if $debug;
      }
    }
  }
  
  # Special case for FLOOR_HEAT_COMMAND byte 1
  if ($dgn eq "1FEFB") {
    # For FLOOR_HEAT_COMMAND, byte 1 needs to have specific bit pattern
    # Extract the operating mode bits (0-1) which are the only defined bits
    my $byte_value = hex($bytes[1]);
    my $operating_mode = $byte_value & 0x03;  # Keep bits 0-1
    
    # Set byte 1 to D4 pattern but preserve operating mode bits
    $bytes[1] = sprintf("%02X", 0xD4 | $operating_mode);
    
    print "  Special handling for FLOOR_HEAT_COMMAND byte 1\n" if $debug;
    print "  Original value: " . sprintf("%02X", $byte_value) .
          ", Operating mode: " . sprintf("%02X", $operating_mode) .
          ", Final value: " . $bytes[1] . "\n" if $debug;
  }
  
  # Rebuild the data string
  my $formatted_data = join("", @bytes);
  
  print "Formatted data: $formatted_data\n" if $debug;
  return $formatted_data;
}

# --------------------------------------------------------------
# Encode a value according to unit and data type
# --------------------------------------------------------------
sub encode_value {
  my ($value, $unit, $type) = @_;
  
  # Only return early if no unit is defined
  return $value if (!defined $unit);
  # n/a values will be handled in the unit-specific code below
  
  my $encoded_value = $value;
  
  switch (lc($unit)) {
    case 'pct' {
      $encoded_value = $value * 2;
      $encoded_value = 255 if ($value eq 'n/a');
    }
    case 'deg c' {
      switch ($type) {
        case 'uint8'  {
          if ($value eq 'n/a') {
            $encoded_value = 255;  # Special value for n/a
          } else {
            $encoded_value = $value + 40;
          }
        }
        case 'uint16' {
          if ($value eq 'n/a') {
            $encoded_value = 65535;  # Special value for n/a
          } else {
            $encoded_value = int(($value + 273) / 0.03125);
          }
        }
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
  
  # Combine to form 29-bit CAN ID
  my $can_id_bin = $prio_bin . $dgn_bin . $source_bin;
  my $can_id_hex = sprintf("%08X", oct("0b$can_id_bin"));
  
  # Build cansend command
  my $cmd = "cansend $can_interface $can_id_hex#$data";
  
  print "CAN command: $cmd\n" if $debug;
  
  # Execute the command
  system($cmd);
  
  if ($? != 0) {
    print "Error sending CAN message: $?\n";
  }
}

# Display usage information
sub usage {
  print "Usage: $0 [options]\n";
  print "Options:\n";
  print "  --debug               Enable debug output\n";
  print "  --specfile=<file>     Path to RV-C specification file (default: /coachproxy/etc/rvc-spec.yml)\n";
  print "  --interface=<if>      CAN interface to use (default: can0)\n";
  print "  --source=<addr>       Source address in hex (default: A0)\n";
  print "  --priority=<prio>     Message priority in hex (default: 6)\n";
  print "  --mqtt=<server>       MQTT broker address (default: localhost)\n";
  print "  --mqttport=<port>     MQTT broker port (default: 1883)\n";
  print "  --user=<username>     MQTT username if required\n";
  print "  --password=<pass>     MQTT password if required\n";
  exit(1);
}