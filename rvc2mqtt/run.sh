#!/bin/bash

# Ensure CAN interface is up
ip link set can0 up 2>/dev/null || true

# Start healthcheck in the background
/coachproxy/rv-c/healthcheck.pl &
HEALTHCHECK_PID=$!

# Start rvc2mqtt in the foreground
/coachproxy/rv-c/rvc2mqtt.pl

#Start mqtt_rvc_set in the foreground
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
