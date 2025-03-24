#!/bin/bash

# Ensure CAN interface is up
echo "\nChecking if can0 is available and up\n"
#ip link set can0 up 2>/dev/null || true
ip link set can0 up type can bitrate 500000
ip link show can0
echo
ifconfig -a | grep can0
ip link | grep can0
sleep 5

echo "set baud rate"
ip link set can0 down
ip link set can0 type can bitrate 250000
ip link set can0 up

# Start healthcheck in the background
echo "starting health check..."
/coachproxy/rv-c/healthcheck.pl &
HEALTHCHECK_PID=$!

# Start rvc2mqtt in the background with MQTT credentials
echo "starting rvc2mqtt..."
# Get MQTT credentials from Home Assistant config if available
MQTT_USER=$(jq --raw-output ".mqtt_user // empty" /data/options.json 2>/dev/null || echo "")
MQTT_PASSWORD=$(jq --raw-output ".mqtt_password // empty" /data/options.json 2>/dev/null || echo "")

# Start mqtt2rvc without authentication since Net::MQTT::Simple doesn't support
# password authentication on non-TLS connections
echo "Starting mqtt2rvc without authentication (Net::MQTT::Simple limitation)"
/coachproxy/rv-c/mqtt2rvc.pl &

sleep 5
jobs

#Start mqtt_rvc_set in the foreground
echo "starting mqtt_rvc_set..."
/coachproxy/rv-c/mqtt_rvc_set.pl

# Function to clean up processes
cleanup() {
    kill $HEALTHCHECK_PID 2>/dev/null
    exit 0
}

# Trap SIGTERM and SIGINT
trap cleanup SIGTERM SIGINT

#Wait for any process to exit
wait -n

# Exit with status of process that exited first
exit $?
