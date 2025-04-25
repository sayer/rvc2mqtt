#!/usr/bin/perl

use strict;
use warnings;
use Net::MQTT::Client;
use JSON;
use Storable qw(dclone); # For deep copying hashes
# use Data::Dumper; # Uncomment for debugging output

my $mqtt_host = "localhost";
my $mqtt_port = 1883; # Default MQTT port
my $client_id = "rvc_shade_correlator_$$"; # Unique client ID
my $output_topic_base = "rvc/output/1FEDE"; # Base topic for publishing 1FEDE JSON

# Hash to store the latest state for each shade index and DGN type
# Structure: %shade_state = { driver_index => { dgn_name => { parsed_payload }, ... }, ... }
my %shade_state;

# Hash to store the last JSON output published for each shade index
# Used for change detection
my %last_published_json;

my $json = JSON->new;
$json->allow_nonref(1); # Allow decoding scalar values if necessary

# Create MQTT client
my $mqtt = Net::MQTT::Client->new(
    host     => $mqtt_host,
    port     => $mqtt_port,
    clientid => $client_id,
    clean    => 1, # Start fresh session
    # Add username/password if needed:
    # user => 'your_mqtt_user',
    # password => 'your_mqtt_password',
);

# Define callback for incoming messages
$mqtt->on_message( sub {
    my ($topic, $payload) = @_;
    handle_message($topic, $payload);
});

# Connect to broker
print "Connecting to MQTT broker: $mqtt_host:$mqtt_port\n";
eval {
    $mqtt->connect();
};
if ($@) {
    die "Failed to connect to MQTT broker: $@\n";
}
print "Connected.\n";

# Subscribe to relevant topics using wildcards
# We only need to subscribe to the DGNs we are using for correlation
my @topics = (
    "RVC/DC_COMPONENT_DRIVER_STATUS_1/#",
    "RVC/DC_COMPONENT_DRIVER_STATUS_2/#",
    "RVC/DC_COMPONENT_DRIVER_STATUS_4/#",
    "RVC/DC_COMPONENT_DRIVER_STATUS_6/#",
);

print "Subscribing to topics: @topics\n";
eval {
    # Use QoS 0 for simplicity, retain => 1 on published messages is more important for HA
    $mqtt->subscribe({ $_ => 0 } for @topics);
};
if ($@) {
     die "Failed to subscribe: $@\n";
}
print "Subscribed. Monitoring...\n";

# Main message handling logic
sub handle_message {
    my ($topic, $payload) = @_;

    # Extract DGN name from topic (assuming format RVC/DGN_NAME/...)
    my @parts = split('/', $topic);
    unless ($#parts >= 1 && $parts[0] eq 'RVC') {
        # Not an RVC topic, ignore
        # print "Ignoring message on non-RVC topic: $topic\n"; # Uncomment for debugging
        return;
    }
    my $dgn_name = $parts[1]; # e.g., DC_COMPONENT_DRIVER_STATUS_1

    # Filter for the DGNs we care about
    unless ($dgn_name =~ /^DC_COMPONENT_DRIVER_STATUS_[1246]$/) {
        # Not one of the DGNs we care about, ignore
        return;
    }

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

    # Store the latest data for this shade and DGN
    # Use dclone to make a deep copy of the payload data
    $shade_state{$driver_index}{$dgn_name} = dclone($data);

    # Trigger processing only when a STATUS_6 message is received for a shade
    # This ensures we process with potentially updated direction/duration
    if ($dgn_name eq 'DC_COMPONENT_DRIVER_STATUS_6') {
        process_shade_status($driver_index);
    } else {
        # For other DGNs, we just update the state and wait for a STATUS_6 trigger.
        # If you need real-time updates on other changes (like temperature),
        # you would call process_shade_status here too, but the user requested
        # specifically to trigger on STATUS_6.
    }
}

# Function to process and publish combined status for a specific shade
sub process_shade_status {
    my ($driver_index) = @_;

    my $shade_data = $shade_state{$driver_index};
    unless ($shade_data) {
        # Should not happen if called from handle_message, but safety check
        return;
    }

    # --- Correlate Data and Construct 1FEDE JSON ---
    # Initialize with defaults or unknown states
    my %output_1fede_payload = (
        instance => 255, # Default instance based on logs
        group => 0,       # Default, not in input
        'motor duty' => 255, # 255 typically means "N/A" or unknown for uint8, or map from 6.pwm_duty
        'lock status' => 3, # 3 (11) for unavailable
        'motor status' => 0, # 00 for inactive
        'forward status' => 0, # 00 for inactive
        'reverse status' => 0, # 00 for inactive
        duration => 255, # 255 for N/A or unknown
        'last command' => 4, # 4 (stop) as a default inference
        'overcurrent status' => 3, # 3 (11) for unavailable (using DGN name, mapping from undercurrent)
        'override status' => 3, # 3 (11) for unavailable
        'disable1 status' => 3, # 3 (11) for not supported/unavailable
        'disable2 status' => 3, # 3 (11) for not supported/unavailable
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
                 $output_1fede_payload{'motor status'} = 1; # 01 for active
             } elsif ($status1->{'output_status definition'} eq 'off') {
                  $output_1fede_payload{'motor status'} = 0; # 00 for inactive
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
                 $output_1fede_payload{'overcurrent status'} = 0; # 00 for not in overcurrent
             } elsif ($status2->{'undercurrent definition'} eq 'undercurrent_condition') {
                 $output_1fede_payload{'overcurrent status'} = 1; # 01 for has drawn overcurrent (re-purposing as "not normal")
             } else {
                 $output_1fede_payload{'overcurrent status'} = 3; # 11 for unavailable
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
                $output_1fede_payload{'lock status'} = 0; # 00 for unlocked
            } elsif ($status6->{'lock_status definition'} eq 'locked') {
                $output_1fede_payload{'lock status'} = 1; # 01 for locked
            } else {
                 $output_1fede_payload{'lock status'} = 3; # 11 for not supported/unavailable
            }
        }

        # Map forward and reverse status from driver_direction
        if (defined $status6->{'driver_direction definition'}) {
            if ($status6->{'driver_direction definition'} eq 'forward') {
                $output_1fede_payload{'forward status'} = 1; # 01 for active
                $output_1fede_payload{'reverse status'} = 0; # 00 for inactive
                 # Infer last command (forward movement implies this was the command)
                 $output_1fede_payload{'last command'} = 129; # 129 for forward
            } elsif ($status6->{'driver_direction definition'} eq 'reverse') {
                 $output_1fede_payload{'forward status'} = 0; # 00 for inactive
                 $output_1fede_payload{'reverse status'} = 1; # 01 for active
                 # Infer last command (reverse movement implies this was the command)
                 $output_1fede_payload{'last command'} = 65; # 65 for reverse
            } else { # 'not_active' (3) or other states
                 $output_1fede_payload{'forward status'} = 0; # 00 for inactive
                 $output_1fede_payload{'reverse status'} = 0; # 00 for inactive
                 # If motor is inactive and it was previously moving, infer stop
                 # This is an oversimplification. True "last command" needs command PGNs.
                 # Sticking to simple inference from current state: if not moving, assume stop command was last.
                 $output_1fede_payload{'last command'} = 4; # 4 for stop
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
                 $output_1fede_payload{'override status'} = 0; # 00 for inactive
             } elsif ($status6->{'override_input definition'} eq 'active') {
                  $output_1fede_payload{'override status'} = 1; # 01 for active
             } else {
                  $output_1fede_payload{'override status'} = 3; # 11 for unavailable
             }
        }

        # disable1/disable2 status are not directly available in these DGNs
        # They are part of 1FEDE but not directly reported by 1/2/4/6.
        # Keeping them as 3 (unavailable) as per initialization.

    } # End of STATUS_6 mapping


     if (exists $shade_data->{'DC_COMPONENT_DRIVER_STATUS_4'}) {
         my $status4 = $shade_data->{'DC_COMPONENT_DRIVER_STATUS_4'};
         # Note: channel_on_time and on_cycle_count are not part of 1FEDE structure
         # but are available in the source data. We won't include them in the
         # 1FEDE output JSON, but could potentially use them for other purposes
         # or include them as separate attributes if we weren't strictly mapping to 1FEDE.
     }


    # --- Prepare and Publish JSON if Different ---

    # Convert the new correlated data to a JSON string
    # Need to sort keys to ensure consistent JSON string for comparison
    my $new_json_string = $json->encode({ # Encode the hash reference
         map { $_ => $output_1fede_payload{$_} } sort keys %output_1fede_payload # Sort keys
    });

    # Get the last published JSON string for this driver_index
    my $last_json_string = $last_published_json{$driver_index}; # Will be undef if not set

    # Compare new JSON with the last published JSON
    if (!defined $last_json_string || $new_json_string ne $last_json_string) {
        # JSON has changed, publish it

        my $output_topic = "$output_topic_base/$driver_index";
        # print "Publishing 1FEDE status for driver $driver_index to $output_topic:\n$new_json_string\n"; # Uncomment for debugging

        eval {
            # Use retain => 1 so the last state is available on broker/client restarts
            $mqtt->publish($output_topic, $new_json_string, { qos => 0, retain => 1 });
        };
        if ($@) {
            warn "Failed to publish 1FEDE status to $output_topic: $@\n";
        }

        # Update the last published JSON for this driver_index
        $last_published_json{$driver_index} = $new_json_string;
    } else {
        # JSON has not changed, do not publish
        # print "Status for driver $driver_index is unchanged, skipping publish.\n"; # Uncomment for debugging
    }
}


# Start the MQTT client loop - blocks forever
print "Starting MQTT loop...\n";
$mqtt->loop_forever();

# Disconnect on exit (usually not reached in loop_forever unless interrupted)
# $mqtt->disconnect(); # loop_forever handles graceful disconnect on signal
print "Script shutting down.\n";

exit;