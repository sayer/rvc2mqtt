#!/bin/bash
set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <topic/load> <payload>"
  exit 1
fi

topic="$1"
payload="$2"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN=$(command -v python3)
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN=$(command -v python)
else
  echo "Error: python3 or python is required for JSON parsing."
  exit 1
fi

normalize_numeric() {
  local value="$1"
  perl -e 'use strict; use warnings; use Scalar::Util qw(looks_like_number);
           my $v = shift;
           die "non-numeric" unless defined $v && looks_like_number($v);
           if ($v < 0) { $v = 0; }
           my $raw;
           if ($v <= 100) { $raw = $v * 2; }
           elsif ($v <= 200) { $raw = $v; }
           else { $raw = 200; }
           my $pct = $raw / 2.0;
           print int($pct + 0.5);
  ' "$value"
}

parse_json_brightness() {
  local json_payload="$1"
  "$PYTHON_BIN" - "$json_payload" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)

if isinstance(data, dict):
    for key in ("desired level", "desired level pct", "brightness_pct", "brightness", "level"):
        if key in data:
            value = data[key]
            try:
                print(float(value))
                sys.exit(0)
            except (TypeError, ValueError):
                pass

    for key in ("command", "command definition", "state"):
        value = data.get(key)
        if isinstance(value, str):
            lowered = value.strip().lower()
            if lowered == "on":
                print(100)
                sys.exit(0)
            if lowered == "off":
                print(0)
                sys.exit(0)

sys.exit(2)
PY
}

oldIFS="$IFS"
IFS='/'
read -ra topics <<< "$topic"
IFS="$oldIFS"
load="${topics[-1]}"

if ! perl -e 'use Scalar::Util qw(looks_like_number); exit(!looks_like_number($ARGV[0]) || $ARGV[0] < 0 || $ARGV[0] > 255);' "$load"; then
  echo "Error: Load must be an integer between 0 and 255."
  exit 1
fi

brightness_input=""
if [[ "$payload" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
  brightness_input="$payload"
else
  lower=$(echo "$payload" | tr 'A-Z' 'a-z')
  if [[ "$lower" == "on" ]]; then
    brightness_input="100"
  elif [[ "$lower" == "off" ]]; then
    brightness_input="0"
  else
    json_value=$(parse_json_brightness "$payload" 2>/dev/null || true)
    if [ -n "$json_value" ]; then
      brightness_input="$json_value"
    fi
  fi
fi

if [ -z "$brightness_input" ]; then
  echo "Error: Unable to determine brightness from payload '$payload'."
  exit 1
fi

if ! brightness_pct=$(normalize_numeric "$brightness_input" 2>/dev/null); then
  echo "Error: Brightness must be numeric (payload '$payload')."
  exit 1
fi

if [ "$brightness_pct" -le 0 ]; then
  /coachproxy/rv-c/dc_dimmer.pl "$load" 3
else
  /coachproxy/rv-c/dc_dimmer.pl "$load" 0 "$brightness_pct"
fi

echo "$topic" "$payload" >> "setrvc.log.txt"
