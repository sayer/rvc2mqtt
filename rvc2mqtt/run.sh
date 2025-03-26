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

# Start rvc2mqtt in the background
echo "Starting rvc2mqtt without authentication (Net::MQTT::Simple limitation)"
/coachproxy/rv-c/rvc2mqtt.pl &
RVC2MQTT_PID=$!

sleep 5
jobs

# Start mqtt_rvc_set in the background with the credentials
echo "starting mqtt_rvc_set..."
/coachproxy/rv-c/mqtt_rvc_set.pl --user "$MQTT_USER" --password "$MQTT_PASSWORD" --debug &
MQTT_RVC_SET_PID=$!

# Start mqtt2rvc in the background with credentials
echo "starting mqtt2rvc..."
/coachproxy/rv-c/mqtt2rvc.pl --debug &
MQTT2RVC_PID=$!

# Function to clean up all processes
cleanup() {
    echo "Cleaning up all processes..."
    kill $HEALTHCHECK_PID 2>/dev/null
    kill $RVC2MQTT_PID 2>/dev/null
    kill $MQTT_RVC_SET_PID 2>/dev/null
    kill $MQTT2RVC_PID 2>/dev/null
    exit 0
}

# Trap SIGTERM and SIGINT
trap cleanup SIGTERM SIGINT

echo "All services started. Waiting for processes to complete..."

# Keep the script running indefinitely
# Using wait with no arguments will wait for all child processes
wait

# This point should only be reached if all background processes exit on their own
echo "All processes have exited."
