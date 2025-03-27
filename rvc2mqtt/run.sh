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
/coachproxy/rv-c/mqtt2rvc.pl --debug --mqtt="localhost" --user "$MQTT_USER" --password "$MQTT_PASSWORD" &
MQTT2RVC_PID=$!

# Function to clean up processes
cleanup() {
    kill $HEALTHCHECK_PID 2>/dev/null
    exit 0
}

# Trap SIGTERM and SIGINT
trap cleanup SIGTERM SIGINT

# Monitor and restart any process that exits
while true; do
  # Wait for any process to exit
  wait -n
  EXIT_STATUS=$?
  
  echo "A process has exited with status $EXIT_STATUS"
  
  # Check which process exited and restart it
  if ! kill -0 $HEALTHCHECK_PID 2>/dev/null; then
    echo "Healthcheck process exited. Restarting in 5 seconds..."
    sleep 5
    /coachproxy/rv-c/healthcheck.pl &
    HEALTHCHECK_PID=$!
    echo "Healthcheck restarted with PID $HEALTHCHECK_PID"
  fi
  
  if ! kill -0 $RVC2MQTT_PID 2>/dev/null; then
    echo "RVC2MQTT process exited. Restarting in 5 seconds..."
    sleep 5
    /coachproxy/rv-c/rvc2mqtt.pl &
    RVC2MQTT_PID=$!
    echo "RVC2MQTT restarted with PID $RVC2MQTT_PID"
  fi
  
  if ! kill -0 $MQTT_RVC_SET_PID 2>/dev/null; then
    echo "MQTT_RVC_SET process exited. Restarting in 5 seconds..."
    sleep 5
    /coachproxy/rv-c/mqtt_rvc_set.pl --user "$MQTT_USER" --password "$MQTT_PASSWORD" --debug &
    MQTT_RVC_SET_PID=$!
    echo "MQTT_RVC_SET restarted with PID $MQTT_RVC_SET_PID"
  fi
  
  if ! kill -0 $MQTT2RVC_PID 2>/dev/null; then
    echo "MQTT2RVC process exited. Restarting in 5 seconds..."
    sleep 5
    /coachproxy/rv-c/mqtt2rvc.pl --debug --mqtt="localhost" --user "$MQTT_USER" --password "$MQTT_PASSWORD" &
    MQTT2RVC_PID=$!
    echo "MQTT2RVC restarted with PID $MQTT2RVC_PID"
  fi
done
