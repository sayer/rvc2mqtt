#!/usr/bin/perl -w
#
use strict;
use warnings;
use AnyEvent;
use AnyEvent::MQTT;

my $broker = 'localhost';
my $port = 1883;
my $username = 'sayer';
my $password = 'bmw540xi';
my $topic = 'RVCSET/#';

my $mqtt = AnyEvent::MQTT->new(
    host => $broker,
    port => $port,
    user_name => $username,
    password => $password,
);

my $cv = AnyEvent->condvar;

my $subscription = $mqtt->subscribe(
    topic => $topic,
    callback => sub {
        my ($topic, $message) = @_;
        print "Received message: $message on topic $topic\n";
        my @topics = split('/', $topic);
        my $script = "/coachproxy/rv-c/$topics[1].sh";
        my $exit_code = system($script, $topic, $message);
        if ($exit_code != 0) {
          print "Script execution failed with exit code $exit_code.\n";
}
    },
    qos => 0,
    on_success => sub {
        print "Connected to MQTT broker and subscribed to topic $topic\n";
    },
    on_error => sub {
        my $error = shift;
        print "Failed to subscribe to topic $topic: $error\n";
        $cv->send;
    },
);

$cv->recv;
``

