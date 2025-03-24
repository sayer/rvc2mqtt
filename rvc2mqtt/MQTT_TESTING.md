# RVC to MQTT Bridge Testing Guide

This document explains how to test and troubleshoot the RVC-MQTT bridge.

## Issue Fixes

### 1. MQTT Implementation Issues

We have created two different implementations to handle MQTT:

1. **mqtt2rvc.pl (Updated)**:
   - Fixed MQTT callback implementation
   - Improved event loop handling

2. **mqtt2rvc_simple.pl (New)**:
   - Completely new implementation
   - Uses raw socket communication instead of Net::MQTT::Simple callbacks
   - Doesn't depend on problematic callback features
   - **Try this if the updated mqtt2rvc.pl still has issues**

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

This script doesn't require any external tools as it uses the same Perl MQTT library.

### 3. MQTT Monitor

The `mqtt_monitor.pl` script helps you debug by monitoring all RVC-related MQTT topics:

```
chmod +x mqtt_monitor.pl
./mqtt_monitor.pl
```

This tool will display all MQTT traffic related to RVC, showing both status updates and commands.

## How to Test

1. Fix the duplicate key issue in rvc-spec.yml as described above.

2. Choose which implementation to use:
   - Original (updated): `mqtt2rvc.pl`
   - New socket-based version: `mqtt2rvc_simple.pl`

3. In one terminal, start your chosen script with debug mode:
   ```
   ./mqtt2rvc.pl --debug
   ```
   or
   ```
   ./mqtt2rvc_simple.pl --debug
   ```

4. In another terminal, start the MQTT monitor:
   ```
   ./mqtt_monitor.pl
   ```

5. In a third terminal, run the test script:
   ```
   ./test_lights.pl
   ```

6. Watch the output in all terminals to verify:
   - The bridge script properly receives the MQTT messages and converts them to CAN messages
   - The MQTT monitor shows all message traffic
   - No errors occur during the process

## Troubleshooting

If you encounter issues:

1. **Try the alternate implementation**: If one version doesn't work, try the other!

2. Verify the MQTT broker is running:
   ```
   systemctl status mosquitto
   ```

3. Check script permissions:
   ```
   chmod +x mqtt2rvc.pl mqtt2rvc_simple.pl
   ```

4. Make sure the CAN interface is properly configured:
   ```
   ip link show can0
   ```

5. Test a simple MQTT publication manually:
   ```
   mosquitto_pub -h localhost -t "test/topic" -m "test message"
   ```

6. Fix duplicate keys in rvc-spec.yml:
   ```
   grep -n "^[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]:" /coachproxy/etc/rvc-spec.yml | sort | uniq -d
   ```

7. If needed, restart the MQTT broker:
   ```
   systemctl restart mosquitto