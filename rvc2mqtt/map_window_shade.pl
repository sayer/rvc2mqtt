#!/usr/bin/perl -w
#
# Window Shade Correlator for RVC
# This script correlates various DC_COMPONENT_DRIVER_STATUS DGNs 
# into a unified 1FEDE-compatible JSON payload for window shades.
#
# Usage:
#   ./map_window_shade.pl                     # Use default MQTT broker (localhost)
#   ./map_window_shade.pl --host=192.168.1.100   # Use a specific MQTT broker
#   ./map_window_shade.pl --debug               # Enable verbose output
#

use strict;
use warnings;
use Net::MQTT::Simple;
use JSON;
use Storable qw(dclone); # For deep copying hashes
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(gettimeofday);

# ANSI colors for better readability when debug is enabled
my $color_reset = "\033[0m";
my $color_green = "\033[32m";
my $color_yellow = "\033[33m";
my $color_blue = "\033[34m";
my $color_red = "\033[31m";
my $color_cyan = "\033[36m";
my $color_magenta = "\033[35m";

# Configuration with defaults
my $mqtt_host = "localhost";
my $mqtt_port = 1883; # Default MQTT port
my $output_topic_base = "RVC/WINDOW_SHADE_CONTROL_STATUS"; # Base topic for publishing window shade status
my $debug = 0;
my $help = 0;

# Parse command-line options
GetOptions(
    "host=s"      => \$mqtt_host,
    "port=i"      => \$mqtt_port,
    "topic=s"     => \$output_topic_base,
    "debug"       => \$debug,
    "help|h"      => \$help
) or usage();

# Show usage if requested
usage() if $help;

# Hash to store the latest state for each shade index and DGN type
# Structure: %shade_state = { driver_index => { dgn_name => { parsed_payload }, ... }, ... }
my %shade_state;

# Hash to store the last comparison JSON (without timestamp) for each shade index
# Used for change detection
my %last_comparison_jsons;

# For backwards compatibility (not used in new code)
my %last_published_json;

# Create JSON handler
my $json = JSON->new->utf8->canonical(1); # Sort keys alphabetically

# Connect to MQTT broker
print "${color_green}Connecting to MQTT broker: $mqtt_host:$mqtt_port${color_reset}\n" if $debug;
my $mqtt = Net::MQTT::Simple->new("$mqtt_host:$mqtt_port");

# Subscribe to relevant topics using wildcards
# We only need to subscribe to the DGNs we are using for correlation
my @topics = (
    "RVC/DC_COMPONENT_DRIVER_STATUS_1/#",
    "RVC/DC_COMPONENT_DRIVER_STATUS_2/#",
    "RVC/DC_COMPONENT_DRIVER_STATUS_4/#",
    "RVC/DC_COMPONENT_DRIVER_STATUS_6/#",
);

print "${color_green}Subscribing to topics: @topics${color_reset}\n" if $debug;
$mqtt->subscribe($_ => \&handle_message) for @topics;
print "${color_green}Subscribed. Monitoring...${color_reset}\n" if $debug;

# Message handler
sub handle_message {
    my ($topic, $payload) = @_;
    
    # Extract DGN name from topic (assuming format RVC/DGN_NAME/...)
    my @parts = split('/', $topic);
    unless ($#parts >= 1 && $parts[0] =~ /^RVC$/i) {
        # Not an RVC topic, ignore
        print "${color_yellow}Ignoring message on non-RVC topic: $topic${color_reset}\n" if $debug;
        return;
    }
    print "${color_cyan}Processing message on topic: $topic${color_reset}\n" if $debug;
    my $dgn_name = $parts[1]; # e.g., DC_COMPONENT_DRIVER_STATUS_1
    
    # Filter for the DGNs we care about
    unless ($dgn_name =~ /^DC_COMPONENT_DRIVER_STATUS_[1246]$/i) {
        # Not one of the DGNs we care about, ignore
        print "${color_yellow}Ignoring message with unsupported DGN: $dgn_name${color_reset}\n" if $debug;
        return;
    }
    print "${color_green}Found supported DGN: $dgn_name${color_reset}\n" if $debug;
    
    # Parse JSON payload
    my $data;
    eval {
        $data = $json->decode($payload);
    };
    if ($@) {
        warn "Failed to parse JSON payload from topic $topic: $@\nPayload: $payload\n";
        return;
    }
    
    # Extract driver_index - crucial for correlation
    my $driver_index = $data->{'driver_index'};
    unless (defined $driver_index) {
        warn "Received message on $topic with no driver_index in payload: $payload\n";
        return;
    }
    
    # Always log received message for troubleshooting
    my ($sec, $usec) = gettimeofday();
    my $timestamp = scalar(localtime($sec));
    print "\n${color_yellow}[$timestamp]${color_reset} ";
    print "${color_green}RECEIVED${color_reset} ${color_blue}$topic${color_reset}";
    print " ${color_magenta}[DGN: $dgn_name]${color_reset} ${color_cyan}[Index: $driver_index]${color_reset}\n";
    print "${color_cyan}Payload: $payload${color_reset}\n";
    
    # Store the latest data for this shade and DGN
    # Use dclone to make a deep copy of the payload data
    $shade_state{$driver_index}{$dgn_name} = dclone($data);
    
    # Process shade status whenever we receive any relevant DGN
    # This ensures more responsive updates when any component changes
    print "${color_green}Processing shade status for driver $driver_index due to $dgn_name update${color_reset}\n";
    
    # Check if we have received all needed status messages for this component
    my @required_dgns = qw(DC_COMPONENT_DRIVER_STATUS_1 DC_COMPONENT_DRIVER_STATUS_6);
    my $missing_dgns = 0;
    foreach my $required_dgn (@required_dgns) {
        unless (exists $shade_state{$driver_index}{$required_dgn}) {
            print "${color_yellow}Missing required DGN $required_dgn for driver $driver_index${color_reset}\n";
            $missing_dgns++;
        }
    }
    
    if ($missing_dgns) {
        print "${color_yellow}Will process $driver_index but some required DGNs are missing${color_reset}\n";
    }
    
    # Process the shade status
    process_shade_status($driver_index);
}

# Function to process and publish combined status for a specific shade
sub process_shade_status {
    my ($driver_index) = @_;
    
    my $shade_data = $shade_state{$driver_index};
    unless ($shade_data) {
        # Should not happen if called from handle_message, but safety check
        warn "No shade data found for driver index $driver_index\n";
        return;
    }
    
    # Debug: Print what data we have for this driver
    print "${color_green}Processing shade for driver_index $driver_index${color_reset}\n";
    foreach my $dgn (sort keys %$shade_data) {
        print "${color_cyan}  Found DGN: $dgn${color_reset}\n";
    }
    
    # --- Correlate Data and Construct 1FEDE JSON ---
    # Initialize with defaults or unknown states
    my %output_1fede_payload = (
        instance => 255, # Default instance based on logs
        group => "01111101",  # Default group from example logs
        'motor duty' => 0, # Default 0 for inactive
        'lock status' => "00", # "00" for unlocked (default)
        'lock status definition' => "unlocked",
        'motor status' => "00", # "00" for inactive
        'motor status definition' => "inactive",
        'forward status' => "00", # "00" for inactive
        'forward status definition' => "inactive",
        'reverse status' => "00", # "00" for inactive
        'reverse status definition' => "inactive",
        duration => 255, # 255 for N/A or unknown
        'last command' => 4, # 4 (stop) as a default inference (numeric for mqtt2rvc)
        'last command definition' => "stop",
        'overcurrent status' => "11", # "11" for unavailable
        'overcurrent status definition' => "overcurrent status unavailable",
        'override status' => "11", # "11" for unavailable
        'override status definition' => "override status unavailable",
        'disable1 status' => "00", # "00" for inactive
        'disable1 status definition' => "inactive",
        'disable2 status' => "00", # "00" for inactive
        'disable2 status definition' => "inactive",
        'name' => "WINDOW_SHADE_CONTROL_STATUS",
        'dgn' => "1FEDE",
        'data' => "",  # Will be populated later if available
        'timestamp' => sprintf("%.6f", Time::HiRes::time()),
        'command' => 4, # Numeric for mqtt2rvc.pl compatibility
    );
    
    # Map data from received DGNs
    if (exists $shade_data->{'DC_COMPONENT_DRIVER_STATUS_1'}) {
        my $status1 = $shade_data->{'DC_COMPONENT_DRIVER_STATUS_1'};
        if (defined $status1->{'device_instance'}) {
            $output_1fede_payload{'instance'} = $status1->{'device_instance'};
        }
        # Map motor status from output_status
        if (defined $status1->{'output_status definition'}) {
            if ($status1->{'output_status definition'} eq 'on') {
                $output_1fede_payload{'motor status'} = "01"; # "01" for active
                $output_1fede_payload{'motor status definition'} = "active";
            } elsif ($status1->{'output_status definition'} eq 'off') {
                $output_1fede_payload{'motor status'} = "00"; # "00" for inactive
                $output_1fede_payload{'motor status definition'} = "inactive";
            }
            # Handle other states if necessary
        }
        # Note: Current and Voltage are not directly in 1FEDE, but valuable for other sensors
    }
    
    if (exists $shade_data->{'DC_COMPONENT_DRIVER_STATUS_2'}) {
        my $status2 = $shade_data->{'DC_COMPONENT_DRIVER_STATUS_2'};
        # Map overcurrent status from undercurrent status (using the DGN's name for the parameter)
        if (defined $status2->{'undercurrent definition'}) {
            if ($status2->{'undercurrent definition'} eq 'normal') {
                $output_1fede_payload{'overcurrent status'} = "00"; # "00" for not in overcurrent
                $output_1fede_payload{'overcurrent status definition'} = "not in overcurrent";
            } elsif ($status2->{'undercurrent definition'} eq 'undercurrent_condition') {
                $output_1fede_payload{'overcurrent status'} = "01"; # "01" for has drawn overcurrent
                $output_1fede_payload{'overcurrent status definition'} = "has drawn overcurrent";
            } else {
                $output_1fede_payload{'overcurrent status'} = "11"; # "11" for unavailable
                $output_1fede_payload{'overcurrent status definition'} = "overcurrent status unavailable";
            }
        }
        # Note: Temperature is not directly in 1FEDE
    }
    
    if (exists $shade_data->{'DC_COMPONENT_DRIVER_STATUS_6'}) {
        my $status6 = $shade_data->{'DC_COMPONENT_DRIVER_STATUS_6'};
        
        # Map motor duty
        if (defined $status6->{'pwm_duty'} && $status6->{'pwm_duty'} ne 'n/a') {
            $output_1fede_payload{'motor duty'} = $status6->{'pwm_duty'};
        } elsif (defined $status6->{'pwm_duty definition'} && $status6->{'pwm_duty definition'} ne 'not_applicable') {
            # Attempt to map definition if raw value is n/a, though pwm_duty is a direct number in logs
            # This case might not be strictly necessary based on sample logs
        } else {
            $output_1fede_payload{'motor duty'} = 255; # Default 255 if unavailable/n/a
        }
        
        # Map lock status
        if (defined $status6->{'lock_status definition'}) {
            if ($status6->{'lock_status definition'} eq 'unlocked' || $status6->{'lock_status definition'} eq 'not_locked') {
                $output_1fede_payload{'lock status'} = "00"; # "00" for unlocked
                $output_1fede_payload{'lock status definition'} = "unlocked";
            } elsif ($status6->{'lock_status definition'} eq 'locked') {
                $output_1fede_payload{'lock status'} = "01"; # "01" for locked
                $output_1fede_payload{'lock status definition'} = "locked";
            } else {
                $output_1fede_payload{'lock status'} = "11"; # "11" for not supported
                $output_1fede_payload{'lock status definition'} = "lock command not supported";
            }
        }
        
        # Map forward and reverse status from driver_direction
        if (defined $status6->{'driver_direction definition'}) {
            if ($status6->{'driver_direction definition'} eq 'forward') {
                $output_1fede_payload{'forward status'} = "01"; # "01" for active
                $output_1fede_payload{'forward status definition'} = "active";
                $output_1fede_payload{'reverse status'} = "00"; # "00" for inactive
                $output_1fede_payload{'reverse status definition'} = "inactive";
                # Infer last command (forward movement implies this was the command)
                $output_1fede_payload{'last command'} = 129; # 129 for forward
                $output_1fede_payload{'last command definition'} = "forward";
                $output_1fede_payload{'command'} = 129; # Duplicate for mqtt2rvc compatibility
            } elsif ($status6->{'driver_direction definition'} eq 'reverse') {
                $output_1fede_payload{'forward status'} = "00"; # "00" for inactive
                $output_1fede_payload{'forward status definition'} = "inactive";
                $output_1fede_payload{'reverse status'} = "01"; # "01" for active
                $output_1fede_payload{'reverse status definition'} = "active";
                # Infer last command (reverse movement implies this was the command)
                $output_1fede_payload{'last command'} = 65; # 65 for reverse
                $output_1fede_payload{'last command definition'} = "reverse";
                $output_1fede_payload{'command'} = 65; # Duplicate for mqtt2rvc compatibility
            } elsif ($status6->{'driver_direction definition'} eq 'toggle_forward') {
                $output_1fede_payload{'forward status'} = "01"; # "01" for active
                $output_1fede_payload{'forward status definition'} = "active";
                $output_1fede_payload{'reverse status'} = "00"; # "00" for inactive
                $output_1fede_payload{'reverse status definition'} = "inactive";
                $output_1fede_payload{'last command'} = 133; # 133 for toggle forward
                $output_1fede_payload{'last command definition'} = "toggle forward";
                $output_1fede_payload{'command'} = 133; # Duplicate for mqtt2rvc compatibility
            } else { # 'not_active' (3) or other states
                $output_1fede_payload{'forward status'} = "00"; # "00" for inactive
                $output_1fede_payload{'forward status definition'} = "inactive";
                $output_1fede_payload{'reverse status'} = "00"; # "00" for inactive
                $output_1fede_payload{'reverse status definition'} = "inactive";
                # If motor is inactive and it was previously moving, infer stop
                # This is an oversimplification. True "last command" needs command PGNs.
                # Sticking to simple inference from current state: if not moving, assume stop command was last.
                $output_1fede_payload{'last command'} = 4; # 4 for stop
                $output_1fede_payload{'last command definition'} = "stop";
                $output_1fede_payload{'command'} = 4; # Duplicate for mqtt2rvc compatibility
            }
        }
        
        # Map duration
        if (defined $status6->{'duration_remaining'}) {
            # 255 typically means "not applicable" or no active timed command
            $output_1fede_payload{'duration'} = $status6->{'duration_remaining'};
        }
        
        # Map override status
        if (defined $status6->{'override_input definition'}) {
            if ($status6->{'override_input definition'} eq 'inactive') {
                $output_1fede_payload{'override status'} = "00"; # "00" for inactive
                $output_1fede_payload{'override status definition'} = "external override inactive";
            } elsif ($status6->{'override_input definition'} eq 'active') {
                $output_1fede_payload{'override status'} = "01"; # "01" for active
                $output_1fede_payload{'override status definition'} = "external override active";
            } else {
                $output_1fede_payload{'override status'} = "11"; # "11" for unavailable
                $output_1fede_payload{'override status definition'} = "override status unavailable";
            }
        }
        
        # Map disable1/disable2 status - using default values from examples
        # These values are consistent across all example messages
        $output_1fede_payload{'disable1 status'} = "00"; # "00" for inactive
        $output_1fede_payload{'disable1 status definition'} = "inactive";
        $output_1fede_payload{'disable2 status'} = "00"; # "00" for inactive
        $output_1fede_payload{'disable2 status definition'} = "inactive";
        
        # Extract data field if available
        if (defined $status6->{'data'}) {
            $output_1fede_payload{'data'} = $status6->{'data'};
        }
        
    } # End of STATUS_6 mapping
    
    if (exists $shade_data->{'DC_COMPONENT_DRIVER_STATUS_4'}) {
        my $status4 = $shade_data->{'DC_COMPONENT_DRIVER_STATUS_4'};
        # Note: channel_on_time and on_cycle_count are not part of 1FEDE structure
        # but are available in the source data. We won't include them in the
        # 1FEDE output JSON, but could potentially use them for other purposes
        # or include them as separate attributes if we weren't strictly mapping to 1FEDE.
    }
    
    # --- Prepare and Publish JSON if Different ---
    
    # Use the actual driver_index as instance
    if ($output_1fede_payload{'instance'} == 255) {
        # Use driver_index as instance
        print "${color_yellow}Using driver_index $driver_index as instance for shade${color_reset}\n" if $debug;
        $output_1fede_payload{'instance'} = $driver_index;
    }
    
    # Don't update timestamp until right before publishing - it's done later
    
    # Ensure command value is synchronized with last_command for mqtt2rvc.pl compatibility
    if (defined $output_1fede_payload{'last command'}) {
        $output_1fede_payload{'command'} = $output_1fede_payload{'last command'};
    }
    
    # Create a deep copy of the payload without timestamp for comparison
    my %comparison_payload = %output_1fede_payload;
    delete $comparison_payload{'timestamp'};
    
    # Convert the payload (excluding timestamp) to JSON for comparison
    # Need to sort keys to ensure consistent JSON string for comparison
    my $comparison_json_string = $json->encode({ # Encode the hash reference
        map { $_ => $comparison_payload{$_} } sort keys %comparison_payload # Sort keys
    });
    
    # Get the last published comparison JSON string for this driver_index
    my $last_comparison_json = $last_comparison_jsons{$driver_index}; # Will be undef if not set
    
    # Skip publishing if driver_index is 255 (reserved value)
    if ($driver_index == 255) {
        print "${color_yellow}Skipping publish for driver_index 255 (reserved value)${color_reset}\n" if $debug;
        return;
    }
    
    # Compare new JSON (without timestamp) with the last published comparison JSON
    if (!defined $last_comparison_json || $comparison_json_string ne $last_comparison_json) {
        # Add timestamp right before publishing
        $output_1fede_payload{'timestamp'} = sprintf("%.6f", Time::HiRes::time());
        
        # Create the final JSON with timestamp included
        my $publish_json_string = $json->encode({ # Encode the hash reference
            map { $_ => $output_1fede_payload{$_} } sort keys %output_1fede_payload # Sort keys
        });
        
        # JSON has changed, publish it
        
        # Use instance from the payload, not driver_index
        my $output_topic = "$output_topic_base/" . $output_1fede_payload{'instance'};
        if ($debug) {
            print "${color_green}Publishing 1FEDE status for driver $driver_index to $output_topic:${color_reset}\n";
            print "${color_cyan}$publish_json_string${color_reset}\n";
        }
        
        print "${color_green}======= PUBLISHING WINDOW_SHADE_CONTROL_STATUS ========${color_reset}\n";
        print "${color_blue}Topic: $output_topic${color_reset}\n";
        print "${color_cyan}Payload: $publish_json_string${color_reset}\n";
        
        eval {
            # Use retain => 1 so the last state is available on broker/client restarts
            $mqtt->retain($output_topic => $publish_json_string);
            print "${color_green}Successfully published to $output_topic${color_reset}\n";
        };
        if ($@) {
            warn "Failed to publish WINDOW_SHADE_CONTROL_STATUS to $output_topic: $@\n";
        }
        
        # Update the last published comparison JSON for this driver_index
        $last_comparison_jsons{$driver_index} = $comparison_json_string;
    } else {
        # JSON has not changed, do not publish
        # print "${color_yellow}Status for driver $driver_index is unchanged, skipping publish.${color_reset}\n" if $debug;
    }
}

# Usage information
sub usage {
    print <<EOF;
Window Shade Correlator for RVC

Usage:
  $0 [options]

Options:
  --host=SERVER       MQTT broker hostname or IP (default: localhost)
  --port=PORT         MQTT broker port (default: 1883)
  --topic=TOPIC       Base topic for publishing 1FEDE JSON (default: rvc/output/1FEDE)
  --debug             Enable verbose output
  --help, -h          Show this help message

Examples:
  $0                             # Use default settings
  $0 --host=192.168.1.100        # Use a specific MQTT broker
  $0 --debug                     # Enable verbose output
  $0 --topic=home/rvc/shades     # Use a custom output topic base

EOF
    exit(0);
}

# Start the MQTT client loop - process messages in a non-blocking way
print "${color_green}Window Shade Correlator running. Press Ctrl+C to exit.${color_reset}\n";
print "${color_green}Waiting for messages...${color_reset}\n\n";

# Keep the event loop running
while (1) {
    # Process messages
    $mqtt->tick(1);  # Process for 1 second
}

# This will only be reached if the loop exits (e.g., on SIGINT)
print "Script shutting down.\n";
exit;