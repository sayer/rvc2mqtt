#!/usr/bin/perl -w
#
# Copyright (C) 2025 Stephen D Ayers
#

use strict;
use warnings;
use Net::MQTT::Simple;
use Socket;
use Getopt::Long qw(GetOptions);
use YAML::Tiny;
use JSON;
use Switch;
use Time::HiRes qw(time sleep);
use Scalar::Util qw(looks_like_number);

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
  
  # Apply standard RVC formatting to all commands, with exceptions for special cases
  my $apply_standard_formatting = 1;
  
  # Hard-coded fix for FLOOR_HEAT_COMMAND data format
  if ($dgn eq "1FEFB") {
    # 1. Extract instance from first byte
    my $instance = substr($data, 0, 2);
    
    # 2. Determine if heat is being turned off
    my $is_off = ($json->{'Set point'} == 0);
    
    # 3. Format data according to known working pattern
    if ($is_off) {
      # OFF format for all instances: xxC00000FFFFFFFF
      $data = $instance . "C00000FFFFFFFF";
    } else {
      # ON format for all instances: xxD43025FFFFFFFF
      # 3025 is the encoded temperature for 24.5°C
      $data = $instance . "D43025FFFFFFFF";
    }
    
    print "Fixed FLOOR_HEAT_COMMAND for instance $instance. State: " .
          ($is_off ? "OFF" : "ON") . "\n" if $debug;
    $apply_standard_formatting = 0;  # Skip standard formatting since we have a custom format
  }
  # Special handling for WINDOW_SHADE_CONTROL_COMMAND
  elsif ($dgn eq "1FEDF") {
    print "Window Shade Control Command JSON payload: " if $debug;
    if ($debug) {
      foreach my $key (sort keys %$json) {
        print "$key => " . (defined $json->{$key} ? $json->{$key} : "undef") . ", ";
      }
      print "\n";
    }
    
    # Extract instance byte
    my $instance_byte = substr($data, 0, 2);
    
    # Define command mappings
    my %cmd_map = (
      'toggle forward' => 133,
      'toggle reverse' => 69,
      'forward' => 129,
      'reverse' => 65,
      'stop' => 4,
      'open' => 133,    # Map 'open' to 'toggle forward' (not 'forward')
      'close' => 69     # Map 'close' to 'toggle reverse' (not 'reverse')
    );
    
    # Log the input values for debugging
    if ($debug) {
      print "  Input command definition: " . (defined $json->{'command definition'} ? $json->{'command definition'} : "undef") . "\n";
      print "  Input command value: " . (defined $json->{'command'} ? $json->{'command'} : "undef") . "\n";
      print "  Input motor duty: " . (defined $json->{'motor duty'} ? $json->{'motor duty'} : "undef") . "\n";
    }
    
    # Get command from JSON - check both fields regardless of order
    # Initialize to 4 (stop) to ensure a valid default
    my $command_value = 4;
    
    # First check command definition if it exists and isn't "undefined"
    if (defined $json->{'command definition'} && $json->{'command definition'} ne "undefined") {
      $command_value = $cmd_map{lc($json->{'command definition'})} // 4; # Default to stop if not in map
      print "  Using command from 'command definition': " .
            $json->{'command definition'} . " -> $command_value\n" if $debug;
    }
    # Check if command value is a string - map it to a command code if possible
    elsif (defined $json->{'command'} && !looks_like_number($json->{'command'})) {
      my $cmd_str = lc($json->{'command'});
      if (exists $cmd_map{$cmd_str}) {
        $command_value = $cmd_map{$cmd_str};
        print "  Mapped string command '$cmd_str' to value $command_value\n" if $debug;
      } else {
        print "  Unknown string command '$cmd_str', defaulting to stop (4)\n" if $debug;
      }
    }
    # Otherwise use numeric command value if it's valid (non-zero)
    elsif (defined $json->{'command'} && looks_like_number($json->{'command'}) && $json->{'command'} != 0) {
      $command_value = $json->{'command'};
      print "  Using numeric command value directly: $command_value\n" if $debug;
    }
    # Default to stop command (4) if we have motor duty specified
    elsif (defined $json->{'motor duty'}) {
      $command_value = 4; # stop
      print "  No valid command but motor duty specified, defaulting to stop (4)\n" if $debug;
    }
    # For any other condition, ensure we have a valid command (stop = 4)
    else {
      print "  No valid command information found, defaulting to stop (4)\n" if $debug;
    }
    
    # Sanity check - never allow command value of 0 (not valid in RVC spec)
    if (looks_like_number($command_value) && $command_value == 0) {
      $command_value = 4; # Force to stop if somehow still 0
      print "  Corrected invalid command value 0 to stop (4)\n" if $debug;
    }
    
    print "  Final command value: $command_value\n" if $debug;
    
    # Get motor duty - handle 'n/a' and defaults
    my $motor_duty = 200; # default to 100% (which is 200 in protocol format)
    if (defined $json->{'motor duty'}) {
      if ($json->{'motor duty'} eq 'n/a') {
        $motor_duty = 200; # 100% duty
      } else {
        # Motor duty in JSON is in percentage (0-100)
        # Protocol requires this to be stored as percentage * 2 (0-200)
        $motor_duty = $json->{'motor duty'} * 2;
      }
    }
    print "  Motor duty: " . ($motor_duty/2) . "%\n" if $debug;
    
    # Get duration - handle 'n/a' and defaults
    my $duration = 30; # default to 30 seconds
    if (defined $json->{'duration'}) {
      if ($json->{'duration'} eq 'n/a') {
        $duration = 30;
      } else {
        $duration = $json->{'duration'};
      }
    }
    print "  Duration: $duration\n" if $debug;
    
    # Format data using known working pattern - command 0 should still produce valid format
    $data = sprintf("%02XFF%02X%02X%02X00FFFF",
      $json->{'instance'} || 1,  # instance
      $motor_duty,               # motor duty
      $command_value,            # command
      $duration                  # duration
    );
    
    print "Fixed WINDOW_SHADE_CONTROL_COMMAND: $data\n" if $debug;
    $apply_standard_formatting = 0;  # Skip standard formatting since we've manually formatted
  }
  # Hard-coded fix for AUTOFILL_COMMAND data format - RVC standard needs undefined bits set to 1
  elsif ($dgn eq "1FFB0") {
    # Print JSON payload for debugging
    print "AUTOFILL_COMMAND JSON payload: " if $debug;
    if ($debug) {
      foreach my $key (sort keys %$json) {
        print "$key => " . (defined $json->{$key} ? $json->{$key} : "undef") . ", ";
      }
      print "\n";
    }
    print "Command field: " . (defined $json->{'command'} ? $json->{'command'} : "undefined") . "\n" if $debug;
    print "Command definition field: " . (defined $json->{'command definition'} ? $json->{'command definition'} : "undefined") . "\n" if $debug;
    
    # Check which fields are present in the JSON
    my $cmd_value = undef;
    my $cmd_def = undef;
    
    if (defined $json->{'command'}) {
      $cmd_value = $json->{'command'};
      print "Found command value: $cmd_value\n" if $debug;
    }
    
    if (defined $json->{'command definition'}) {
      $cmd_def = $json->{'command definition'};
      print "Found command definition: $cmd_def\n" if $debug;
    }
    
    # Determine if command is off or on - be very explicit
    my $is_off = 0;  # Default to ON if we can't determine
    
    # Check command field first
    if (defined $cmd_value) {
      if ($cmd_value eq "0" || $cmd_value == 0) {
        $is_off = 1;
        print "Command is OFF based on command field\n" if $debug;
      }
    }
    
    # Then check command definition field
    if (defined $cmd_def) {
      if (lc($cmd_def) eq "off") {
        $is_off = 1;
        print "Command is OFF based on command definition field\n" if $debug;
      }
    }
    
    # Format data according to RVC convention
    if ($is_off) {
      $data = "FCFFFFFFFFFFFFFF"; # OFF (command=0)
      print "Using OFF format for AUTOFILL_COMMAND\n" if $debug;
    } else {
      $data = "FDFFFFFFFFFFFFFF"; # ON (command=1)
      print "Using ON format for AUTOFILL_COMMAND\n" if $debug;
    }
    
    print "Fixed AUTOFILL_COMMAND. Command: " . ($is_off ? "OFF" : "ON") . "\n" if $debug;
    print "Final AUTOFILL_COMMAND data: $data\n" if $debug;
    $apply_standard_formatting = 0;  # Skip standard formatting since we have a custom format
  }
  
  # Apply standard RVC formatting if needed (set undefined bytes to FF)
  if ($apply_standard_formatting) {
    my $original_data = $data;
    
    # Use the format_rvc_message function which sets undefined bits/bytes to FF
    # according to the RVC specification for this DGN
    $data = format_rvc_message($dgn, $data);
    
    print "Applied standard RVC formatting for DGN $dgn\n" if $debug;
    print "  Original data: $original_data\n" if $debug;
    print "  Formatted data: $data\n" if $debug;
    
    # Special debug for light commands (DC_DIMMER_COMMAND_2)
    if ($dgn eq "1FEDB" && $debug) {
      print "  DC_DIMMER_COMMAND_2 - This is a light control command\n";
      print "  Instance: " . substr($data, 0, 2) . "\n";
      print "  Group: " . substr($data, 2, 2) . "\n";
      print "  Level: " . substr($data, 4, 2) . "\n";
      print "  Command: " . substr($data, 6, 2) . "\n";
      print "  Duration: " . substr($data, 8, 2) . "\n";
    }
  }
  
  # Validate data before sending
  $data = validate_rvc_data($dgn, $data, $json);
  
  # Send to CAN bus
  send_can_message($dgn, $data);
  
  print "Sent message to CAN: DGN=$dgn, Data=$data\n" if $debug;
}

# --------------------------------------------------------------
# Build a data packet from parameters and JSON values
# --------------------------------------------------------------
sub build_data_packet {
  my ($parameters, $json, $instance) = @_;
  
  # Initialize 8-byte data array with FF (undefined bytes in RVC should be FF, not zeros)
  my @bytes = (0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
  
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
    
    # More robust checking for JSON parameters
    # Check for direct name match first
    if (defined $json->{$name}) {
      $value = $json->{$name};
      print "  Found parameter '$name' with value '$value'\n" if $debug;
    }
    # Check for case-insensitive match
    else {
      my $found = 0;
      foreach my $key (keys %$json) {
        if (lc($key) eq lc($name)) {
          $value = $json->{$key};
          print "  Found parameter '$name' via case-insensitive match on '$key' with value '$value'\n" if $debug;
          $found = 1;
          last;
        }
      }
      
      # If parameter is still not found, skip this parameter
      if (!$found) {
        print "  Parameter '$name' not found in JSON, skipping\n" if $debug;
        next;
      }
    }
    
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
      if ($bit_value =~ /^[01]+$/) {
        # Binary string - convert to numeric
        $bit_value = oct("0b$bit_value");
      } elsif (!looks_like_number($bit_value)) {
        # Non-numeric, non-binary string - convert to 0 to avoid errors
        print "  Warning: Non-numeric value '$bit_value' for bit field, defaulting to 0\n" if $debug;
        $bit_value = 0;
      } else {
        # Numeric string or number - convert to integer
        $bit_value = int($bit_value);
      }
      
      # Create a mask for these bits
      my $mask = ((1 << $num_bits) - 1) << $bit_start;
      
      # Make sure the byte value is numeric before bitwise operations
      my $byte_value = hex($bytes[$start_byte]);
      
      # Clear bits in byte
      $byte_value &= ~$mask;
      
      # Set bits with new value
      $byte_value |= ($bit_value << $bit_start) & $mask;
      
      # Convert back to hex string
      $bytes[$start_byte] = sprintf("%02X", $byte_value);
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
  
  # Ensure we have 8 bytes (pad with FF if needed as per RVC convention)
  while (scalar(@bytes) < 8) {
    push(@bytes, "FF");
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
  
  # Special case for FLOOR_HEAT_COMMAND
  if ($dgn eq "1FEFB") {
    # Make a copy of the original data for debugging
    my $original_data = join("", @bytes);
    
    # For FLOOR_HEAT_COMMAND, we need to reproduce the exact known working patterns
    # based on the instance and whether heat is on or off
    
    # Get instance number from byte 0 (keep as-is)
    my $instance = $bytes[0];
    
    # Check if heat is being turned off (set point bytes are 0000)
    my $is_heat_off = ($bytes[2] eq "00" && $bytes[3] eq "00");
    
    # Simple approach: reproduce exact known working patterns
    if ($is_heat_off) {
      # Heat OFF pattern: xxC00000FFFFFFFF (where xx is the instance)
      $bytes[1] = "C0";
      $bytes[2] = "00";
      $bytes[3] = "00";
      $bytes[4] = "FF";
      $bytes[5] = "FF";
      $bytes[6] = "FF";
      $bytes[7] = "FF";
      print "  FLOOR_HEAT_COMMAND instance $instance is OFF\n" if $debug;
    } else {
      # Heat ON pattern: xxD4yy25FFFFFFFF (where xx is the instance, yy are bytes 2-3 from input)
      $bytes[1] = "D4";
      # Keep bytes 2-3 (set point) from the original data
      $bytes[4] = "FF";
      $bytes[5] = "FF";
      $bytes[6] = "FF";
      $bytes[7] = "FF";
      print "  FLOOR_HEAT_COMMAND instance $instance is ON\n" if $debug;
    }
    
    print "  Original data: $original_data\n" if $debug;
    print "  Modified data: " . join("", @bytes) . "\n" if $debug;
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
  
  # Handle binary string representations (convert "11111111" to numeric)
  if (defined $value && $value =~ /^[01]+$/ && length($value) == 8) {
    print "  Converting binary string '$value' to numeric\n" if $debug;
    return oct("0b$value");
  }
  
  # Handle string command values regardless of the type - use a standard command map
  if (defined $value && !looks_like_number($value)) {
    # Map command textual definitions to their numeric values
    my %command_map = (
      'toggle reverse' => 69,
      'forward' => 129,
      'reverse' => 65,
      'toggle forward' => 133,
      'stop' => 4,
      'tilt' => 16,
      'lock' => 33,
      'unlock' => 34,
      'open' => 133,      # Map open to toggle forward (133)
      'close' => 69       # Map close to toggle reverse (69)
    );
    
    my $lc_value = lc($value);
    if (exists $command_map{$lc_value}) {
      print "  Mapped command text '$value' to numeric value " . $command_map{$lc_value} . "\n" if $debug;
      return $command_map{$lc_value};
    }
    
    # If command string not found in map, default to stop (4)
    if ($type eq 'command' || $value =~ /^(open|close|stop|forward|reverse|toggle)/) {
      print "  Unknown command text '$value', defaulting to stop (4)\n" if $debug;
      return 4; # Default to stop for unknown command strings
    }
  }
  
  # Only return early if no unit is defined and value is numeric
  return $value if (!defined $unit && looks_like_number($value));
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

# --------------------------------------------------------------
# Validate RVC data to ensure it follows protocol requirements
# --------------------------------------------------------------
sub validate_rvc_data {
  my ($dgn, $data, $json) = @_;
  
  print "Validating data for DGN $dgn: $data\n" if $debug;
  
  # Get expected data structure from spec
  return $data unless (defined $dgn && defined $encoders->{$dgn});
  
  # Extract bytes from data string
  my @bytes = unpack("(A2)*", $data);
  
  # Ensure we have 8 bytes
  while (scalar(@bytes) < 8) {
    push(@bytes, "FF");
  }
  
  # Get parameters from the RVC specification
  my $encoder = $encoders->{$dgn};
  my @parameters;
  
  # Handle aliases
  if (defined $encoder->{alias}) {
    my $alias_dgn = $encoder->{alias};
    if (defined $encoders->{$alias_dgn}->{parameters}) {
      push(@parameters, @{$encoders->{$alias_dgn}->{parameters}});
    }
  }
  
  # Add parameters from this DGN
  if (defined $encoder->{parameters}) {
    push(@parameters, @{$encoder->{parameters}});
  }
  
  # Create a map of which bytes are defined
  my %defined_bytes;
  
  # Check which bytes are defined in the specification
  if ($debug) {
    print "  Checking parameters:\n";
  }
  
  foreach my $param (@parameters) {
    next unless defined $param->{byte};
    
    my $byte_spec = $param->{byte};
    my ($start_byte, $end_byte) = split(/-/, $byte_spec);
    $end_byte = $start_byte if !defined $end_byte;
    
    for my $b ($start_byte..$end_byte) {
      $defined_bytes{$b} = 1;
      if ($debug) {
        print "    Byte $b is defined by parameter '$param->{name}'\n";
      }
    }
  }
  
  # Ensure all undefined bytes are set to FF per RVC spec
  for my $b (0..7) {
    if (!exists $defined_bytes{$b}) {
      if ($bytes[$b] ne "FF") {
        print "  Correcting undefined byte $b from $bytes[$b] to FF\n" if $debug;
        $bytes[$b] = "FF";
      }
    }
  }
  
  # Rebuild data string
  my $new_data = join('', @bytes);
  
  # Return original data if no changes were made
  return $new_data;
}