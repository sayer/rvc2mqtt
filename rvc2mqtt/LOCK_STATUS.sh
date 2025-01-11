#!/bin/bash

# Check if two arguments are provided
if [ $# -ne 2 ]; then
  echo "Usage: $0 <topic/load> <payload>"
  exit 1
fi

topic=$1
payload=$2

# Validate that the payload is an integer between 0 and 100
if ! [[ "$payload" =~ ^-?[0-9]+$ ]] || [ "$payload" -lt 0 ] || [ "$payload" -gt 100 ]; then
  echo "Error: Payload must be an integer between 0 and 100."
  exit 1
fi


# Save the original IFS value and set IFS to '/'
old_ifs="$IFS"
IFS='/'

# Split the input string using the '/' delimiter
read -ra topics <<< "$topic"

# Restore the original IFS value
IFS="$old_ifs"

# Get the last topic and print it
load="${topics[-1]}"

# Validate that the load is an integer between 0 and 100
if ! [[ "$load" =~ ^-?[0-9]+$ ]] || [ "$load" -lt 0 ] || [ "$load" -gt 255 ]; then
  echo "Error: Load must be an integer between 0 and 255."
  exit 1
fi

echo "Setting lock $load to value: $payload"

/coachproxy/rv-c/locks.pl "$load" "$payload"

# Example: Saving payload to a file
echo "$topic" "$payload" >> "setrvc.log.txt"

