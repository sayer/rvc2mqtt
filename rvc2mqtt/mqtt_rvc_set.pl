#!/usr/bin/perl -w
#
use strict;
use warnings;
use AnyEvent;
use AnyEvent::MQTT;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

# Default values
my $broker = 'localhost';
my $port = 1883;
my $username = '';
my $password = '';
my $topic = 'RVCSET/#';
my $debug = 0;
my $script_timeout = 30;  # Timeout for script execution in seconds
my $max_children = 10;    # Limit concurrent child processes
my %active_children = (); # Track active child processes

# Parse command line arguments
GetOptions(
    'debug' => \$debug,
    'mqtt=s' => \$broker,
    'mqttport=i' => \$port,
    'user=s' => \$username,
    'password=s' => \$password,
    'topic=s' => \$topic,
) or die "Usage: $0 [--debug] [--mqtt=hostname] [--mqttport=port] [--user=username] [--password=password] [--topic=topic]\n";

print "Connecting to MQTT broker at $broker:$port\n" if $debug;
if ($username) {
    print "Using MQTT authentication with username: $username\n" if $debug;
}

# Add signal handlers to catch exits
$SIG{TERM} = sub { 
    print "mqtt_rvc_set received TERM signal, shutting down gracefully\n";
    # Kill any remaining child processes
    foreach my $pid (keys %active_children) {
        kill('TERM', $pid);
    }
    exit 0; 
};
$SIG{INT} = sub { 
    print "mqtt_rvc_set received INT signal, shutting down gracefully\n";
    # Kill any remaining child processes
    foreach my $pid (keys %active_children) {
        kill('TERM', $pid);
    }
    exit 0; 
};

# Reap child processes to prevent zombies
$SIG{CHLD} = sub {
    while ((waitpid(-1, WNOHANG)) > 0) {}
};

# Create MQTT client
my $mqtt_options = {
    host => $broker,
    port => $port,
    keep_alive_timer => 60,  # Add keepalive to detect disconnections
    connect_timeout => 10,   # Add connection timeout
};

# Add authentication if provided
if ($username) {
    $mqtt_options->{user_name} = $username;
    $mqtt_options->{password} = $password;
}

my $mqtt;
my $connected = 0;
my $reconnect_timer;
my $reconnect_count = 0;
my $max_reconnect_attempts = 5;

sub create_mqtt_connection {
    print "Creating MQTT connection to $broker:$port\n" if $debug;
    
    # Cancel any existing reconnect timer
    undef $reconnect_timer if $reconnect_timer;
    
    # Clean up any existing connection
    undef $mqtt if $mqtt;
    $connected = 0;
    
    eval {
        $mqtt = AnyEvent::MQTT->new(%$mqtt_options);
        setup_subscription();
    };
    
    if ($@) {
        print "Failed to create MQTT connection: $@\n";
        schedule_reconnect();
    }
}

sub schedule_reconnect {
    return if $reconnect_timer;  # Already scheduled
    
    $reconnect_count++;
    my $delay = ($reconnect_count <= $max_reconnect_attempts) ? 10 : 60;
    
    print "Scheduling reconnection in $delay seconds... (attempt $reconnect_count)\n";
    
    $reconnect_timer = AnyEvent->timer(
        after => $delay,
        cb => sub {
            undef $reconnect_timer;
            if ($reconnect_count <= $max_reconnect_attempts) {
                create_mqtt_connection();
            } else {
                print "Max reconnection attempts reached. Exiting.\n";
                exit 1;
            }
        },
    );
}

# Track last message time for monitoring
my $lastmsg_file = "/var/run/mqtt_rvc_set.lastmsg";

sub update_lastmsg_time {
    eval {
        if (open(my $fh, '>', $lastmsg_file)) {
            print $fh time();
            close($fh);
        }
    };
    # Don't let file I/O errors crash the script
}

sub setup_subscription {
    $mqtt->subscribe(
        topic => $topic,
        callback => sub {
            # Use eval to catch any errors in the callback that might block the event loop
            eval {
        my ($topic, $message) = @_;
        my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
        print "[$timestamp] Received message: $message on topic $topic\n";
        
        # Update last message time for monitoring
        update_lastmsg_time();
        my @topics = split('/', $topic);
        
        # Check if we have enough topic parts
        if (scalar(@topics) < 2) {
            print "Invalid topic format: $topic (need at least 2 parts)\n";
            return;
        }
        
        my $script = "/coachproxy/rv-c/$topics[1].sh";
        
        # Check if script exists before executing
        if (! -f $script) {
            print "Script not found: $script\n";
            return;
        }
        
        # Check if script is executable
        if (! -x $script) {
            print "Script not executable: $script\n";
            return;
        }
        
        # Check if we have too many active children
        if (scalar(keys %active_children) >= $max_children) {
            print "[$timestamp] Too many active child processes, skipping execution of $script\n";
            return;
        }
        
        # Execute in background with timeout protection
        my $pid = fork();
        if (!defined $pid) {
            print "[$timestamp] Failed to fork: $!\n";
            return;
        }
        
        if ($pid == 0) {
            # Child process
            eval {
                # Set a timeout for the script execution
                local $SIG{ALRM} = sub { 
                    print "[$timestamp] Script $script timed out after $script_timeout seconds\n";
                    exit(1); 
                };
                alarm($script_timeout);
                
                my $exit_code = system($script, $topic, $message);
                alarm(0);  # Cancel the alarm
                
                if ($exit_code != 0) {
                    print "[$timestamp] Script execution failed with exit code $exit_code.\n";
                }
                exit($exit_code >> 8);
            };
            if ($@) {
                print "[$timestamp] Error in child process: $@\n";
                exit(1);
            }
        } else {
            # Parent process - track the child
            $active_children{$pid} = {
                script => $script,
                start_time => time(),
                topic => $topic
            };
            
            # Set up a watcher to clean up when child exits
            my $child_start_time = $active_children{$pid}{start_time};
            my $watcher = AnyEvent->child(
                pid => $pid,
                cb => sub {
                    my ($pid, $status) = @_;
                    my $duration = time() - $child_start_time;
                    delete $active_children{$pid};
                    print "[$timestamp] Child process $pid exited with status $status after ${duration}s\n" if $debug;
                }
            );
        }
            };
            if ($@) {
                my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
                print "[$timestamp] Error in MQTT callback: $@\n";
            }
        },
        qos => 1,  # Use QoS 1 for better reliability
        on_success => sub {
            print "Connected to MQTT broker and subscribed to topic $topic\n";
            $connected = 1;
            $reconnect_count = 0;  # Reset reconnect count on successful connection
        },
        on_error => sub {
            my $error = shift;
            my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
            print "[$timestamp] Failed to subscribe to topic $topic: $error\n";
            $connected = 0;
            schedule_reconnect();
        },
    );
}

# Main event loop
my $cv = AnyEvent->condvar;

# Create a watchdog timer to detect if the event loop is blocked
my $watchdog_timer = AnyEvent->timer(
    after => 5,
    interval => 5,
    cb => sub {
        # This timer should fire every 5 seconds if the event loop is working
        # If it doesn't fire, the event loop is blocked
    }
);

# Create a periodic timer to log status and clean up stale children
my $status_timer = AnyEvent->timer(
    after => 60,
    interval => 60,
    cb => sub {
        my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
        print "[$timestamp] mqtt_rvc_set is alive and monitoring $topic\n";
        print "[$timestamp] Connected: " . ($connected ? "YES" : "NO") . "\n" if $debug;
        print "[$timestamp] Active child processes: " . scalar(keys %active_children) . "\n" if $debug;
        
        # Check if we're still connected to MQTT broker
        if ($connected && $mqtt) {
            eval {
                # Try to ping the MQTT connection to see if it's still alive
                $mqtt->ping();
            };
            if ($@) {
                print "[$timestamp] MQTT connection appears to be dead, scheduling reconnect\n";
                $connected = 0;
                schedule_reconnect();
            }
        }
        
        # Clean up any stale child processes
        my $current_time = time();
        foreach my $pid (keys %active_children) {
            my $duration = $current_time - $active_children{$pid}{start_time};
            if ($duration > $script_timeout * 2) {
                print "[$timestamp] Killing stale child process $pid (running for ${duration}s)\n";
                kill('TERM', $pid);
                delete $active_children{$pid};
            }
        }
    }
);

# Start the connection
create_mqtt_connection();

# Run the event loop
$cv->recv;
``
