#!/usr/bin/perl -w
#
# MQTT Monitor script for RVC
# This script subscribes to all RVC related topics and displays incoming messages
# Useful for debugging the mqtt2rvc.pl script and Home Assistant integration
#
# Usage:
#   ./mqtt_monitor.pl                     # Monitor all RVC topics
#   ./mqtt_monitor.pl --dgn=DC_DIMMER     # Monitor only DC_DIMMER DGNs
#   ./mqtt_monitor.pl --dgn=DC_DIMMER --dgn=THERMOSTAT  # Monitor multiple DGNs
#   ./mqtt_monitor.pl --host=192.168.1.100 --dgn=LOCK   # Use a different MQTT broker

use strict;
use warnings;
use Net::MQTT::Simple;
use JSON;
use Time::HiRes qw(gettimeofday);
use Getopt::Long;

# ANSI colors for better readability
my $color_reset = "\033[0m";
my $color_green = "\033[32m";
my $color_yellow = "\033[33m";
my $color_blue = "\033[34m";
my $color_red = "\033[31m";
my $color_cyan = "\033[36m";
my $color_magenta = "\033[35m";

# Configuration with defaults
my $mqtt_host = "localhost";
my $debug = 1;
my $json_pretty = 1;  # Set to 0 to output compact JSON
my @dgn_filters;      # DGNs to monitor (empty = all)
my $help = 0;

# Parse command-line options
GetOptions(
    "host=s"      => \$mqtt_host,
    "dgn=s"       => \@dgn_filters,
    "pretty!"     => \$json_pretty,
    "raw"         => \my $show_raw,  # Add option to show raw data for unrecognized DGNs
    "help|h"      => \$help
) or usage();

# Show usage if requested
usage() if $help;
# Create a hash for faster DGN lookup
my %dgn_filter_map;
my %instance_filter_map;  # New hash for instance filters

if (@dgn_filters) {
    foreach my $filter (@dgn_filters) {
        # Check if the filter includes a specific instance (e.g., "DIGITAL_INPUT_STATUS/70")
        if ($filter =~ m|^([^/]+)/(\d+)$|) {
            my $dgn = uc($1);
            my $instance = $2;
            $dgn_filter_map{$dgn} = 1;
            $instance_filter_map{"$dgn/$instance"} = 1;
        } else {
            # Standard DGN filter without instance
            $dgn_filter_map{uc($filter)} = 1;
        }
    }
    
    my $dgn_list = join(", ", @dgn_filters);
    print "${color_magenta}Filtering for specific DGNs: $dgn_list${color_reset}\n";
} else {
    print "${color_magenta}No DGN filters applied - showing all messages${color_reset}\n";
}

# Create JSON handler
my $json = JSON->new->utf8->canonical(1);  # Sort keys alphabetically
$json->pretty if $json_pretty;

# Connect to MQTT broker
print "${color_green}Connecting to MQTT broker: $mqtt_host${color_reset}\n";
my $mqtt = Net::MQTT::Simple->new($mqtt_host);

# Subscribe to all RVC topics
print "${color_green}Subscribing to RVC topics...${color_reset}\n";
$mqtt->subscribe("RVC/#", \&message_callback);

# Message handler
sub message_callback {
    my ($topic, $message) = @_;
    
    # Extract DGN name and instance from topic (e.g., "RVC/DIGITAL_INPUT_STATUS/70")
    my ($dgn_name, $instance) = $topic =~ m|^RVC/([^/]+)(?:/(\d+))?|;
    
    # Skip if we're filtering and this message doesn't match our filters
    if (@dgn_filters) {
        # Convert to uppercase for case-insensitive matching
        my $uc_dgn = uc($dgn_name || '');
        
        # Check if we have an instance-specific filter
        if ($instance && $instance_filter_map{"$uc_dgn/$instance"}) {
            # This specific instance is allowed
        }
        # Check if we have a general DGN filter
        elsif ($dgn_filter_map{$uc_dgn}) {
            # This DGN is allowed (any instance)
        }
        else {
            # No match, skip this message
            return;
        }
    }
    
    my ($sec, $usec) = gettimeofday();
    my $timestamp = scalar(localtime($sec));
    
    print "\n${color_yellow}[$timestamp]${color_reset} ";
    
    # Highlight different topic types with different colors
    if ($topic =~ /\/set$/) {
        # Command topics
        print "${color_red}COMMAND${color_reset} ";
    } else {
        # Status topics
        print "${color_green}STATUS${color_reset} ";
    }
    
    print "${color_blue}$topic${color_reset}";
    
    # If we have a DGN, highlight it
    if ($dgn_name) {
        print " ${color_magenta}[DGN: $dgn_name]${color_reset}";
    }
    print "\n";
    
    # Try to parse as JSON
    my $parsed;
    eval {
        $parsed = $json->decode($message);
    };
    
    if ($@) {
        # Not valid JSON, just print the raw message
        print "${color_yellow}Message (raw):${color_reset} $message\n";
    } else {
        # Valid JSON, pretty print
        print "${color_yellow}Message (JSON):${color_reset}\n";
        
        # Check if this is an unrecognized DGN (contains UNKNOWN in the topic)
        my $is_unknown = ($topic =~ /UNKNOWN/i);
        
        # If we're showing raw data bytes or this is an unrecognized DGN
        if ($show_raw || $is_unknown) {
            # Always show the DGN number prominently for unknown DGNs
            if (exists $parsed->{dgn}) {
                print "${color_yellow}  DGN: ${color_reset}${color_red}" . $parsed->{dgn} . "${color_reset}\n";
            }
            
            # Make sure we display the data field prominently if it exists
            if (exists $parsed->{data}) {
                print "${color_yellow}  Raw Data: ${color_reset}${color_cyan}" . $parsed->{data} . "${color_reset}\n";
                
                # Attempt to decode hexadecimal data for better analysis
                if ($parsed->{data} =~ /^[0-9A-Fa-f]+$/) {
                    my $hex_data = $parsed->{data};
                    my $byte_str = "";
                    
                    # Format as byte pairs with spaces
                    while ($hex_data =~ s/^(..)//i) {
                        $byte_str .= "$1 ";
                    }
                    
                    print "${color_yellow}  Bytes: ${color_reset}${color_cyan}" . $byte_str . "${color_reset}\n";
                }
            }
        }
        
        if ($json_pretty) {
            my $formatted = $json->encode($parsed);
            # Indent each line
            $formatted =~ s/^/  /mg;
            print "${color_cyan}$formatted${color_reset}\n";
        } else {
            print "  ${color_cyan}" . $json->encode($parsed) . "${color_reset}\n";
        }
    }
}

# Usage information
sub usage {
    print <<EOF;
MQTT Monitor for RVC

Usage:
  $0 [options]

Options:
  --host=SERVER       MQTT broker hostname or IP (default: localhost)
  --dgn=NAME          Filter for specific DGN name (can be used multiple times)
  --pretty            Format JSON with pretty printing (default: enabled)
  --no-pretty         Disable JSON pretty printing
  --raw               Always show raw data bytes for unrecognized DGNs
  --help, -h          Show this help message

Examples:
  $0                                      # Monitor all RVC topics
  $0 --dgn=DC_DIMMER                      # Monitor only DC_DIMMER related messages
  $0 --dgn=DC_DIMMER --dgn=THERMOSTAT     # Monitor multiple DGNs
  $0 --dgn=DIGITAL_INPUT_STATUS/70        # Monitor only instance 70 of DIGITAL_INPUT_STATUS
  $0 --host=192.168.1.100 --dgn=LOCK      # Use a different MQTT broker
  $0 --raw                                # Show raw data bytes for all messages

EOF
    exit(0);
}

# Main loop
print "${color_green}MQTT Monitor running. Press Ctrl+C to exit.${color_reset}\n";
print "${color_green}Waiting for messages...${color_reset}\n\n";

# Keep the event loop running
while (1) {
    # Process messages
    $mqtt->tick(1);  # Process for 1 second
}