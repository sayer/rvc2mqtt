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
    exit 0; 
};
$SIG{INT} = sub { 
    print "mqtt_rvc_set received INT signal, shutting down gracefully\n";
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
};

# Add authentication if provided
if ($username) {
    $mqtt_options->{user_name} = $username;
    $mqtt_options->{password} = $password;
}

my $mqtt;
my $connected = 0;
my $reconnect_timer;

sub create_mqtt_connection {
    print "Creating MQTT connection to $broker:$port\n" if $debug;
    
    # Cancel any existing reconnect timer
    undef $reconnect_timer if $reconnect_timer;
    
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
    
    print "Scheduling reconnection in 10 seconds...\n";
    
    $reconnect_timer = AnyEvent->timer(
        after => 10,
        cb => sub {
            undef $reconnect_timer;
            create_mqtt_connection();
        },
    );
}

# Track last message time for monitoring
my $lastmsg_file = "/var/run/mqtt_rvc_set.lastmsg";

sub update_lastmsg_time {
    if (open(my $fh, '>', $lastmsg_file)) {
        print $fh time();
        close($fh);
    }
}

sub setup_subscription {
    $mqtt->subscribe(
        topic => $topic,
        callback => sub {
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
        
        # Execute in background to avoid blocking
        my $pid = fork();
        if (!defined $pid) {
            print "[$timestamp] Failed to fork: $!\n";
            return;
        }
        
        if ($pid == 0) {
            # Child process
            my $exit_code = system($script, $topic, $message);
            if ($exit_code != 0) {
                print "[$timestamp] Script execution failed with exit code $exit_code.\n";
            }
            exit($exit_code >> 8);
        }
        # Parent continues without waiting
        },
        qos => 1,  # Use QoS 1 for better reliability
        on_success => sub {
            print "Connected to MQTT broker and subscribed to topic $topic\n";
            $connected = 1;
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

# Create a periodic timer to log status
my $status_timer = AnyEvent->timer(
    after => 60,
    interval => 60,
    cb => sub {
        my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
        print "[$timestamp] mqtt_rvc_set is alive and monitoring $topic\n";
        print "[$timestamp] Connected: " . ($connected ? "YES" : "NO") . "\n" if $debug;
    }
);

# Start the connection
create_mqtt_connection();

# Run the event loop
$cv->recv;
``
