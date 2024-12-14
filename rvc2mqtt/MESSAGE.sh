#!/bin/bash

topic=$1

# Save the original IFS value and set IFS to '/'
old_ifs="$IFS"
IFS='/'

echo "Topics: $topic"

# Split the input string using the '/' delimiter
read -ra topics <<< "$topic"

# Restore the original IFS value
IFS="$old_ifs"

# Get the last topic and print it
DGN="${topics[-1]}"

/coachproxy/rv-c/MESSAGE.pl "$DGN" "$2"
