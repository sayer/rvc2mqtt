#!/usr/bin/env bash

# Configuration
MQTT_BROKER="localhost"
MQTT_PORT="1883"
MQTT_TOPIC="test/topic"
TEST_MESSAGE="Hello from MQTT test!"

# Check for mosquitto_pub and mosquitto_sub
if ! command -v mosquitto_pub &> /dev/null || ! command -v mosquitto_sub &> /dev/null; then
    echo "mosquitto_pub or mosquitto_sub not found. Please install mosquitto-clients."
    echo "For Debian/Ubuntu: sudo apt install -y mosquitto-clients"
    exit 1
fi

# Test publishing and subscribing
echo "Testing MQTT connection to $MQTT_BROKER on port $MQTT_PORT..."
echo "Subscribing to topic: $MQTT_TOPIC and publishing a test message."

# We’ll run mosquitto_sub in the background and wait for the message
mosquitto_sub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$MQTT_TOPIC" -C 1 | (
    # The first (and only) message we get should be from the test publish
    read RECEIVED_MSG
    if [ "$RECEIVED_MSG" = "$TEST_MESSAGE" ]; then
        echo "Success: Received test message on $MQTT_TOPIC."
        exit 0
    else
        echo "Error: Did not receive the expected test message."
        exit 1
    fi
) &

SUB_PID=$!

# Give a moment for the subscriber to connect
sleep 1

# Publish the test message
mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$MQTT_TOPIC" -m "$TEST_MESSAGE"

# Wait for subscriber to finish
wait $SUB_PID
RESULT=$?

if [ $RESULT -eq 0 ]; then
    echo "MQTT test completed successfully."
else
    echo "MQTT test failed."
fi

exit $RESULT
