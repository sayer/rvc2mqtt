#!/usr/bin/perl -w
#
# Comprehensive test script for RVC-MQTT components
# Tests lights, water pumps, door locks with various options
#
# Usage:
#   ./test_lights.pl               # Run all tests with default settings
#   ./test_lights.pl --prompt      # Prompt before each action
#   ./test_lights.pl --lights-only # Test only lights
#   ./test_lights.pl --pumps-only  # Test only water pumps
#   ./test_lights.pl --locks-only  # Test only door locks
#   ./test_lights.pl --host=192.168.1.100  # Use a different MQTT broker

use strict;
use warnings;
use Net::MQTT::Simple;
use Time::HiRes qw(sleep);
use Getopt::Long;
# Try to load Term::ReadKey but continue even if not available
eval {
    require Term::ReadKey;
    Term::ReadKey->import();
};
my $has_readkey = $@ ? 0 : 1;

# Set the MQTT broker details
my $mqtt_host = "localhost";
my $prompt_mode = 0;
my $lights_only = 0;
my $pumps_only = 0;
my $locks_only = 0;
my $default_off_delay = 30; # 30 second delay before turning off
my $help = 0;

# Parse command-line options
GetOptions(
    "host=s"      => \$mqtt_host,
    "prompt"      => \$prompt_mode,
    "lights-only" => \$lights_only,
    "pumps-only"  => \$pumps_only,
    "locks-only"  => \$locks_only,
    "delay=i"     => \$default_off_delay,
    "help|h"      => \$help,
) or usage();

# Show usage if requested
usage() if $help;

# If specific tests are selected, make sure others are disabled
if ($lights_only || $pumps_only || $locks_only) {
    # If any are selected, disable the others
    my $test_count = 0;
    $test_count++ if $lights_only;
    $test_count++ if $pumps_only;
    $test_count++ if $locks_only;
    
    # If none were explicitly specified, enable all
    if ($test_count == 0) {
        $lights_only = $pumps_only = $locks_only = 1;
    }
} else {
    # Default - test everything
    $lights_only = $pumps_only = $locks_only = 1;
}

# ANSI Colors for better output
my $RESET = "\033[0m";
my $GREEN = "\033[32m";
my $RED = "\033[31m";
my $YELLOW = "\033[33m";
my $BLUE = "\033[34m";
my $MAGENTA = "\033[35m";
my $CYAN = "\033[36m";

# Light definitions - name, instance
my @lights = (
    # Interior Lights - Front
    { name => "Entry Light", instance => 1 },
    { name => "Cockpit Accents", instance => 2 },
    { name => "Living Room Ceiling", instance => 3 },
    { name => "Living Room Accents", instance => 4 },
    { name => "D/S Front Sofa", instance => 5 },
    { name => "D/S Front Accent", instance => 6 },
    { name => "Living Room Ceiling Recess", instance => 8 },
    { name => "P/S Dinette Ceiling", instance => 9 },
    { name => "P/S Dinette Accent", instance => 10 },
    
    # Interior Lights - Kitchen & Middle Section
    { name => "Kitchen Ceiling", instance => 12 },
    { name => "Kitchen Sink", instance => 13 },
    { name => "Floor Lights", instance => 14 },
    { name => "Mid Batch Ceiling", instance => 15 },
    { name => "Mid Batch Accent", instance => 16 },
    { name => "Hall Ceiling", instance => 17 },
    
    # Interior Lights - Bedroom
    { name => "Bedroom Ceiling", instance => 18 },
    { name => "Bedroom Ceiling Accent", instance => 19 },
    { name => "Bedroom Right Reading", instance => 21 },
    { name => "Bedroom Left Reading", instance => 22 },
    { name => "Bedroom D/S Accent", instance => 23 },
    { name => "Bedroom Dresser Ceiling", instance => 24 },
    { name => "Bedroom Dresser Accent", instance => 25 },
    { name => "Bedroom Recess Ceiling", instance => 31 },
    
    # Interior Lights - Bathroom
    { name => "Rear Bath Shower", instance => 27 },
    { name => "Rear Bath Ceiling", instance => 28 },
    { name => "Rear Bath Accent", instance => 29 },
    { name => "Rear Bath Vanity", instance => 30 },
    
    # Interior Lights - Bunks
    { name => "Top Bunk Reading", instance => 32 },
    { name => "Top Bunk Accent", instance => 33 },
    { name => "Bottom Bunk Reading", instance => 34 },
    { name => "Bottom Bunk Accent", instance => 35 },
    
    # Exterior Lights
    { name => "Docking Lights (2024+ Models)", instance => 43 },
    { name => "Docking Lights (Pre-2024 Models)", instance => 121 },
    { name => "Awning Lights", instance => 44 },
    { name => "Exterior Accents", instance => 45 },
    { name => "Passenger Map Light", instance => 124 },
    { name => "Porch Handle", instance => 127 },
    
);

# Water pump definitions - name, instance
my @pumps = (
    { name => "Fresh Water Pump", instance => 1 }
);

# Lock definitions - name, instance
my @locks = (
    { name => "Main Door Lock", instance => 1 },
    { name => "Storage Compartment Lock 1", instance => 2 },
    { name => "Storage Compartment Lock 2", instance => 3 }
);

print "${GREEN}=== RVC Component Test Utility ===${RESET}\n";
print "${CYAN}Test mode: " . 
    ($prompt_mode ? "Interactive (with prompts)" : "Automatic") . "${RESET}\n";
print "${CYAN}Testing: " . 
    join(", ", 
        ($lights_only ? "Lights" : ()), 
        ($pumps_only ? "Water Pumps" : ()), 
        ($locks_only ? "Door Locks" : ())
    ) . "${RESET}\n";
print "${CYAN}MQTT Broker: $mqtt_host${RESET}\n";
print "${CYAN}Turn-off delay: $default_off_delay seconds${RESET}\n\n";

# Create MQTT client
print "${GREEN}Connecting to MQTT broker: $mqtt_host${RESET}\n";
my $mqtt = Net::MQTT::Simple->new($mqtt_host);

# Function to prompt user for confirmation if in prompt mode
sub prompt_user {
    my ($message) = @_;
    
    return 1 unless $prompt_mode;
    
    print "\n${YELLOW}$message${RESET} (y/n/q): ";
    
    my $key;
    if ($has_readkey) {
        # Use ReadKey if available for single keypress capture
        Term::ReadKey::ReadMode('cbreak');
        $key = Term::ReadKey::ReadKey(0);
        Term::ReadKey::ReadMode('normal');
        print "$key\n";
    } else {
        # Fallback to standard input if Term::ReadKey is not available
        $key = <STDIN>;
        chomp($key);
    }
    
    if (lc($key) eq 'q') {
        print "${RED}Test aborted by user${RESET}\n";
        exit(0);
    }
    
    return lc($key) eq 'y';
}

# Test all lights if enabled
if ($lights_only) {
    print "\n${GREEN}== Testing Lights ==${RESET}\n";
    
    # Test each light individually
    foreach my $light (@lights) {
        # Skip if we can't confirm
        next unless prompt_user("Turn on $light->{name} (instance $light->{instance})?");
        
        print "${BLUE}Turning on $light->{name} (instance $light->{instance})...${RESET}\n";
        $mqtt->publish(
            "RVC/DC_DIMMER_COMMAND_2/$light->{instance}/set", 
            '{"instance": ' . $light->{instance} . ', "desired level": 100, "command": 0}'
        );
        sleep(1);
    }
    
    # Prompt before turning off
    if (prompt_user("Pause for $default_off_delay seconds before turning lights off?")) {
        print "${YELLOW}Waiting $default_off_delay seconds before turning off lights...${RESET}\n";
        
        # Progress bar for the delay
        my $progress_width = 40;
        for (my $i = 0; $i <= $default_off_delay; $i++) {
            my $percent = $i / $default_off_delay;
            my $progress = int($progress_width * $percent);
            printf("\r[%s%s] %d%%", "#" x $progress, " " x ($progress_width - $progress), $percent * 100);
            sleep(1) if $i < $default_off_delay;
        }
        print "\n";
    }
    
    # Turn off all lights if user confirms
    if (prompt_user("Turn off all lights?")) {
        print "${BLUE}Turning off all lights...${RESET}\n";
        foreach my $light (@lights) {
            $mqtt->publish(
                "RVC/DC_DIMMER_COMMAND_2/$light->{instance}/set", 
                '{"instance": ' . $light->{instance} . ', "desired level": 0, "command": 3}'
            );
        }
        sleep(1);
    }
}

# Test water pumps if enabled
if ($pumps_only) {
    print "\n${GREEN}== Testing Water Pumps ==${RESET}\n";
    
    # Test each pump
    foreach my $pump (@pumps) {
        # Skip if we can't confirm
        next unless prompt_user("Turn on $pump->{name} (instance $pump->{instance})?");
        
        print "${BLUE}Turning on $pump->{name} (instance $pump->{instance})...${RESET}\n";
        $mqtt->publish(
            "RVC/WATER_PUMP_COMMAND/set", 
            '{"command": 1}'
        );
        sleep(1);
    }
    
    # Prompt before turning off
    if (prompt_user("Pause for $default_off_delay seconds before turning pumps off?")) {
        print "${YELLOW}Waiting $default_off_delay seconds before turning off pumps...${RESET}\n";
        
        # Progress bar for the delay
        my $progress_width = 40;
        for (my $i = 0; $i <= $default_off_delay; $i++) {
            my $percent = $i / $default_off_delay;
            my $progress = int($progress_width * $percent);
            printf("\r[%s%s] %d%%", "#" x $progress, " " x ($progress_width - $progress), $percent * 100);
            sleep(1) if $i < $default_off_delay;
        }
        print "\n";
    }
    
    # Turn off all pumps if user confirms
    if (prompt_user("Turn off all water pumps?")) {
        print "${BLUE}Turning off all water pumps...${RESET}\n";
        foreach my $pump (@pumps) {
            $mqtt->publish(
                "RVC/WATER_PUMP_COMMAND/set", 
                '{"command": 0}'
            );
        }
        sleep(1);
    }
}

# Test door locks if enabled
if ($locks_only) {
    print "\n${GREEN}== Testing Door Locks ==${RESET}\n";
    
    # Lock each door
    foreach my $lock (@locks) {
        # Skip if we can't confirm
        next unless prompt_user("Lock $lock->{name} (instance $lock->{instance})?");
        
        print "${BLUE}Locking $lock->{name} (instance $lock->{instance})...${RESET}\n";
        $mqtt->publish(
            "RVC/LOCK_COMMAND/$lock->{instance}/set", 
            '{"instance": ' . $lock->{instance} . ', "lock status": 1}'
        );
        sleep(1);
    }
    
    # Prompt before unlocking
    if (prompt_user("Pause for $default_off_delay seconds before unlocking doors?")) {
        print "${YELLOW}Waiting $default_off_delay seconds before unlocking doors...${RESET}\n";
        
        # Progress bar for the delay
        my $progress_width = 40;
        for (my $i = 0; $i <= $default_off_delay; $i++) {
            my $percent = $i / $default_off_delay;
            my $progress = int($progress_width * $percent);
            printf("\r[%s%s] %d%%", "#" x $progress, " " x ($progress_width - $progress), $percent * 100);
            sleep(1) if $i < $default_off_delay;
        }
        print "\n";
    }
    
    # Unlock all doors if user confirms
    if (prompt_user("Unlock all doors?")) {
        print "${BLUE}Unlocking all doors...${RESET}\n";
        foreach my $lock (@locks) {
            $mqtt->publish(
                "RVC/LOCK_COMMAND/$lock->{instance}/set", 
                '{"instance": ' . $lock->{instance} . ', "lock status": 0}'
            );
        }
        sleep(1);
    }
}

# Ensure messages are sent
sleep(0.5);

print "\n${GREEN}=== Test completed ===${RESET}\n";
print "Check mqtt2rvc.pl output for any errors or CAN messages\n";

# Display usage information
sub usage {
    print <<EOF;
RVC Component Test Utility

Usage:
  $0 [options]

Options:
  --host=SERVER      MQTT broker hostname or IP (default: localhost)
  --prompt           Prompt before each action (interactive mode)
  --lights-only      Test only lights
  --pumps-only       Test only water pumps
  --locks-only       Test only door locks
  --delay=SECONDS    Seconds to wait before turning off (default: 30)
  --help, -h         Show this help message

Examples:
  $0                          # Test all components
  $0 --prompt                 # Interactive test with prompts
  $0 --lights-only --delay=10 # Test only lights with 10 second delay
  $0 --host=192.168.1.100     # Use a different MQTT broker

EOF
    exit(0);
}