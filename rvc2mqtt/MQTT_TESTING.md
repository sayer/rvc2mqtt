# RVC to MQTT Bridge Testing Guide

This document explains how to test and troubleshoot the RVC-MQTT bridge (mqtt2rvc.pl).

## Issue Fixes

### 1. Fixed MQTT Implementation

The original error "Can't locate object method 'run_client'" has been fixed in mqtt2rvc.pl by:
- Properly defining callback functions outside the subscription loop
- Using correct callback registration syntax for Net::MQTT::Simple
- Implementing a proper event loop with optimal CPU usage

### 2. YAML Duplicate Key Issue

The error about duplicate key '1FEA6' in rvc-spec.yml needs to be fixed manually:

1. Make a backup of the file:
   ```
   cp /coachproxy/etc/rvc-spec.yml /coachproxy/etc/rvc-spec.yml.bak
   ```

2. Edit the file to find and remove the duplicate entry for '1FEA6':
   ```
   nano /coachproxy/etc/rvc-spec.yml
   ```
   
   Search for '1FEA6' and ensure only one instance exists. If two are found, remove the second one and its associated content.

## Testing Tools

### 1. MQTT Light Configuration for Home Assistant

The `home_assistant_mqtt_lights.yaml` file contains example MQTT light configurations for use with Home Assistant. Add these to your Home Assistant configuration.yaml file.

### 2. Perl Test Script

The `test_lights.pl` script sends MQTT commands to test the lights:

```
chmod +x test_lights.pl
./test_lights.pl
```

This script doesn't require any external tools as it uses the same Perl MQTT library as mqtt2rvc.pl.

### 3. MQTT Monitor

The `mqtt_monitor.pl` script helps you debug by monitoring all RVC-related MQTT topics:

```
chmod +x mqtt_monitor.pl
./mqtt_monitor.pl
```

This tool will display all MQTT traffic related to RVC, showing both status updates and commands.

## How to Test

1. Fix the duplicate key issue in rvc-spec.yml as described above.

2. In one terminal, start the mqtt2rvc.pl script with debug mode:
   ```
   ./mqtt2rvc.pl --debug
   ```

3. In another terminal, start the MQTT monitor:
   ```
   ./mqtt_monitor.pl
   ```

4. In a third terminal, run the test script:
   ```
   ./test_lights.pl
   ```

5. Watch the output in all terminals to verify:
   - mqtt2rvc.pl properly receives the MQTT messages and converts them to CAN messages
   - The MQTT monitor shows all message traffic
   - No errors occur during the process

## Troubleshooting

If you encounter issues:

1. Verify the MQTT broker is running:
   ```
   systemctl status mosquitto
   ```

2. Check that the mqtt2rvc.pl script has the correct permissions:
   ```
   chmod +x mqtt2rvc.pl
   ```

3. Make sure the CAN interface is properly configured:
   ```
   ip link show can0
   ```

4. Test a simple MQTT publication from Perl:
   ```perl
   perl -MNet::MQTT::Simple=localhost -e '$mqtt->publish("test/topic", "test message");'
   ```

5. If needed, restart the MQTT broker:
   ```
   systemctl restart mosquitto