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
    "help|h"      => \$help
) or usage();

# Show usage if requested
usage() if $help;

# Create a hash for faster DGN lookup
my %dgn_filter_map;
if (@dgn_filters) {
    %dgn_filter_map = map { uc($_) => 1 } @dgn_filters;
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
    
    # Extract DGN name from topic
    my ($dgn_name) = $topic =~ m|^RVC/([^/]+)|;
    
    # Skip if we're filtering and this DGN is not in our filter list
    if (@dgn_filters && !$dgn_filter_map{uc($dgn_name || '')}) {
        return;
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
  --help, -h          Show this help message

Examples:
  $0                                      # Monitor all RVC topics
  $0 --dgn=DC_DIMMER                      # Monitor only DC_DIMMER related messages
  $0 --dgn=DC_DIMMER --dgn=THERMOSTAT     # Monitor multiple DGNs
  $0 --host=192.168.1.100 --dgn=LOCK      # Use a different MQTT broker

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