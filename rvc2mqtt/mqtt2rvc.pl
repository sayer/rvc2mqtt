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
use IO::Socket::INET;
use IO::Select;
use Getopt::Long qw(GetOptions);
use YAML::Tiny;
use JSON;
use Switch;
use POSIX;
use Time::HiRes qw(time sleep);

my $debug;
my $spec_file = '/coachproxy/etc/rvc-spec.yml';
my $can_interface = 'can0';
my $source_address = 'A0';  # Default source address, configurable
my $priority = '6';         # Default priority, configurable
my $mqtt_server = 'localhost';  # Default MQTT server, configurable
my $mqtt_port = 1883;           # Default MQTT port, configurable

GetOptions(
  'debug' => \$debug,
  'specfile=s' => \$spec_file,
  'interface=s' => \$can_interface,
  'source=s' => \$source_address,
  'priority=s' => \$priority,
  'mqtt=s' => \$mqtt_server,
  'mqttport=i' => \$mqtt_port,
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

# MQTT client implementation using basic sockets
# This avoids issues with Net::MQTT::Simple callback handling
my $mqtt_socket = IO::Socket::INET->new(
  PeerAddr => $mqtt_server,
  PeerPort => $mqtt_port,
  Proto => 'tcp',
) or die "Cannot connect to MQTT broker at $mqtt_server:$mqtt_port: $!\n";

print "Connected to MQTT broker at $mqtt_server:$mqtt_port\n" if $debug;

# Send MQTT CONNECT packet
my $client_id = "mqtt2rvc_".int(rand(1000000));
send_mqtt_connect($mqtt_socket, $client_id);

# Subscribe to topics
print "Subscribing to MQTT topics\n" if $debug;
mqtt_subscribe($mqtt_socket, "RVC/+/set");
mqtt_subscribe($mqtt_socket, "RVC/+/+/set");

# Print status
print "Using CAN interface: $can_interface\n" if $debug;
print "MQTT to RV-C bridge started. Waiting for commands...\n";

# Main event loop with automatic reconnection
while (1) {
  eval {
    # Set up select for reading from socket
    my $select = IO::Select->new($mqtt_socket);
    
    # Loop until an error occurs
    while (1) {
      my @ready = $select->can_read(1);
      foreach my $fh (@ready) {
        if ($fh == $mqtt_socket) {
          process_mqtt_data($mqtt_socket);
        }
      }
      
      # Send PINGREQ every 30 seconds to keep the connection alive
      if (time() % 30 == 0) {
        send_mqtt_pingreq($mqtt_socket);
        sleep(0.1);  # Short sleep to avoid sending multiple pings in the same second
      }
    }
  };
  
  # Handle connection errors
  if ($@) {
    print "MQTT error: $@\n";
    print "Reconnecting in 5 seconds...\n";
    
    # Close socket if it exists
    if (defined $mqtt_socket) {
      close($mqtt_socket);
      undef $mqtt_socket;
    }
    
    # Wait before reconnecting
    sleep(5);
    
    # Try to reconnect
    eval {
      $mqtt_socket = IO::Socket::INET->new(
        PeerAddr => $mqtt_server,
        PeerPort => $mqtt_port,
        Proto => 'tcp',
      );
      
      if (!$mqtt_socket) {
        die "Cannot reconnect to MQTT broker: $!\n";
      }
      
      print "Reconnected to MQTT broker\n" if $debug;
      
      # Re-establish MQTT connection
      send_mqtt_connect($mqtt_socket, $client_id);
      
      # Resubscribe to topics
      mqtt_subscribe($mqtt_socket, "RVC/+/set");
      mqtt_subscribe($mqtt_socket, "RVC/+/+/set");
    };
    
    if ($@) {
      print "Reconnection failed: $@\n";
    }
  }
}

# --------------------------------------------------------------
# MQTT Basic Protocol Implementation
# --------------------------------------------------------------

# Send MQTT CONNECT packet
sub send_mqtt_connect {
  my ($socket, $client_id) = @_;
  my $protocol_name = "\x00\x04MQTT";
  my $protocol_level = "\x04";  # MQTT 3.1.1
  my $connect_flags = "\x02";   # Clean session
  my $keep_alive = "\x00\x3c";  # 60 seconds
  
  my $client_id_len = pack("n", length($client_id));
  my $client_id_bytes = $client_id_len . $client_id;
  
  my $variable_header = $protocol_name . $protocol_level . $connect_flags . $keep_alive;
  my $payload = $client_id_bytes;
  
  my $remaining_length = length($variable_header) + length($payload);
  my $rl_bytes = encode_remaining_length($remaining_length);
  
  my $packet = "\x10" . $rl_bytes . $variable_header . $payload;
  
  $socket->send($packet);
  
  # Wait for CONNACK
  my $buffer;
  $socket->recv($buffer, 4);
  if (ord(substr($buffer, 0, 1)) != 0x20) {
    die "MQTT: Expected CONNACK but received something else\n";
  }
  my $return_code = ord(substr($buffer, 3, 1));
  if ($return_code != 0) {
    die "MQTT: Connection failed with return code $return_code\n";
  }
  
  print "MQTT: Connected successfully\n" if $debug;
}

# MQTT SUBSCRIBE packet
sub mqtt_subscribe {
  my ($socket, $topic) = @_;
  my $packet_id = pack("n", int(rand(65535)));
  
  my $topic_len = pack("n", length($topic));
  my $topic_filter = $topic_len . $topic . "\x00";  # QoS 0
  
  my $variable_header = $packet_id;
  my $payload = $topic_filter;
  
  my $remaining_length = length($variable_header) + length($payload);
  my $rl_bytes = encode_remaining_length($remaining_length);
  
  my $packet = "\x82" . $rl_bytes . $variable_header . $payload;
  
  $socket->send($packet);
  
  print "MQTT: Subscribed to topic: $topic\n" if $debug;
}

# MQTT PINGREQ packet
sub send_mqtt_pingreq {
  my ($socket) = @_;
  my $packet = "\xc0\x00";
  $socket->send($packet);
}

# Encode MQTT remaining length
sub encode_remaining_length {
  my ($length) = @_;
  my $bytes = '';
  
  do {
    my $digit = $length % 128;
    $length = int($length / 128);
    if ($length > 0) {
      $digit |= 0x80;
    }
    $bytes .= chr($digit);
  } while ($length > 0);
  
  return $bytes;
}

# Process incoming MQTT data
sub process_mqtt_data {
  my ($socket) = @_;
  my $buffer;
  my $bytes_read = $socket->recv($buffer, 2);
  
  if (!$bytes_read) {
    die "MQTT: Connection closed by broker\n";
  }
  
  my $packet_type = ord(substr($buffer, 0, 1)) >> 4;
  
  # Handle different packet types
  if ($packet_type == 3) {  # PUBLISH
    # Read the remaining length
    my $multiplier = 1;
    my $remaining_length = 0;
    my $pos = 1;
    my $byte;
    
    do {
      $socket->recv($byte, 1);
      my $byte_val = ord($byte);
      $remaining_length += ($byte_val & 0x7F) * $multiplier;
      $multiplier *= 128;
      $pos++;
    } while (ord($byte) & 0x80);
    
    # Read the topic
    my $topic_len_bytes;
    $socket->recv($topic_len_bytes, 2);
    my $topic_len = unpack("n", $topic_len_bytes);
    
    my $topic;
    $socket->recv($topic, $topic_len);
    
    # Calculate message length
    my $message_len = $remaining_length - 2 - $topic_len;
    
    # Read the message
    my $message;
    $socket->recv($message, $message_len);
    
    # Process the message
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
  elsif ($packet_type == 13) {  # PINGRESP
    # Just acknowledge the ping response
    print "MQTT: Received PINGRESP\n" if $debug;
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
      --mqtt=SERVER       MQTT server address (default: localhost)
      --mqttport=PORT     MQTT server port (default: 1883)
  };
  print "\n";
  
  exit(1);
}