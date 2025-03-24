#!/usr/bin/perl -w
#
# Simple test script for RVC-MQTT lights using Perl
# This doesn't require mosquitto_pub to be installed

use strict;
use warnings;
use Net::MQTT::Simple;
use Time::HiRes qw(sleep);

# Set the MQTT broker details
my $mqtt_host = "localhost";

print "== Testing RVC lights with Perl MQTT client ==\n";

# Create MQTT client
print "Connecting to MQTT broker: $mqtt_host\n";
my $mqtt = Net::MQTT::Simple->new($mqtt_host);

# Turn on light 1
print "Turning on Main Cabin Light (instance 1)...\n";
$mqtt->publish("RVC/DC_DIMMER_COMMAND_2/1/set", '{"instance": 1, "desired level": 100, "command": 0}');
sleep(2);

# Turn on light 2
print "Turning on Bedroom Light (instance 2)...\n";
$mqtt->publish("RVC/DC_DIMMER_COMMAND_2/2/set", '{"instance": 2, "desired level": 100, "command": 0}');
sleep(2);

# Turn on light 3
print "Turning on Bathroom Light (instance 3)...\n";
$mqtt->publish("RVC/DC_DIMMER_COMMAND_2/3/set", '{"instance": 3, "desired level": 100, "command": 0}');
sleep(2);

# Turn on light 4
print "Turning on Kitchen Light (instance 4)...\n";
$mqtt->publish("RVC/DC_DIMMER_COMMAND_2/4/set", '{"instance": 4, "desired level": 100, "command": 0}');
sleep(2);

# Turn off all lights
print "Turning off all lights...\n";
$mqtt->publish("RVC/DC_DIMMER_COMMAND_2/1/set", '{"instance": 1, "desired level": 0, "command": 3}');
$mqtt->publish("RVC/DC_DIMMER_COMMAND_2/2/set", '{"instance": 2, "desired level": 0, "command": 3}');
$mqtt->publish("RVC/DC_DIMMER_COMMAND_2/3/set", '{"instance": 3, "desired level": 0, "command": 3}');
$mqtt->publish("RVC/DC_DIMMER_COMMAND_2/4/set", '{"instance": 4, "desired level": 0, "command": 3}');

# Ensure messages are sent
sleep(0.5);

print "== Test completed ==\n";
print "Check mqtt2rvc.pl output for any errors or CAN messages\n";