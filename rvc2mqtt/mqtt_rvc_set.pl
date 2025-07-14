#!/usr/bin/perl -w
#
use strict;
use warnings;
use AnyEvent;
use AnyEvent::MQTT;
use Getopt::Long qw(GetOptions);

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

# Create MQTT client
my $mqtt_options = {
    host => $broker,
    port => $port,
};

# Add authentication if provided
if ($username) {
    $mqtt_options->{user_name} = $username;
    $mqtt_options->{password} = $password;
}

my $mqtt = AnyEvent::MQTT->new(%$mqtt_options);

my $cv = AnyEvent->condvar;

my $subscription = $mqtt->subscribe(
    topic => $topic,
    callback => sub {
        my ($topic, $message) = @_;
        print "Received message: $message on topic $topic\n";
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
        
        my $exit_code = system($script, $topic, $message);
        if ($exit_code != 0) {
            print "Script execution failed with exit code $exit_code.\n";
            # Don't exit the process, just log the error
        }
    },
    qos => 0,
    on_success => sub {
        print "Connected to MQTT broker and subscribed to topic $topic\n";
    },
    on_error => sub {
        my $error = shift;
        print "Failed to subscribe to topic $topic: $error\n";
        # Don't exit immediately, try to reconnect
        print "Attempting to reconnect in 10 seconds...\n";
        sleep 10;
        # The AnyEvent loop will continue, and the MQTT client should reconnect
    },
);

$cv->recv;
``

