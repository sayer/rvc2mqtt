# RV-C Integration for Home Assistant

This example demonstrates how to integrate RV-C data into Home Assistant using MQTT.

## Overview

This integration connects to the MQTT broker used by the RV-C system, allowing Home Assistant to:

* Monitor battery status (voltage, current, state of charge, temperature)
* Control and monitor water heater settings
* Track power status (AC/DC availability)
* Synchronize date and time between systems
* Create automations based on RV-C data

## Components

1. **rvc2mqtt.pl** - Existing script that reads RV-C CAN messages and publishes them to MQTT
2. **mqtt2rvc.pl** - New script that listens for MQTT commands and sends them to the RV-C CAN bus
3. **Home Assistant configuration** - YAML files for integrating with MQTT

## Installation

### 1. Set up the MQTT Bridge

First, ensure the `rvc2mqtt.pl` script is running to send RV-C data to MQTT:

```bash
cd /coachproxy
./rvc2mqtt.pl
```

Then, set up the `mqtt2rvc.pl` script to send commands from MQTT to RV-C:

1. Copy the `mqtt2rvc.pl` script to your system
2. Make it executable:
   ```bash
   chmod +x mqtt2rvc.pl
   ```
3. Run it (adjust paths as needed):
   ```bash
   ./mqtt2rvc.pl --specfile=/coachproxy/etc/rvc-spec.yml --interface=can0
   ```

### 2. Set up Home Assistant

1. Copy these files to your Home Assistant configuration directory:
   * `configuration.yaml` - Contains the MQTT configuration
   * `automations.yaml` - Example automations
   * `scripts.yaml` - Scripts for controlling RV-C devices

   Add the following to your existing Home Assistant configuration to include these files:
   ```yaml
   # Include RV-C configuration files
   automation: !include automations.yaml
   script: !include scripts.yaml
   ```

2. Add the dashboard to your Lovelace configuration:
   * Go to your dashboard, click the three dots in the upper right
   * Click "Edit Dashboard"
   * Click the three dots again, then "Raw configuration editor"
   * Paste the contents of `lovelace-dashboard.yaml` or create a new dashboard

3. Restart Home Assistant to apply changes:
   ```bash
   ha core restart
   ```

4. Verify MQTT connection:
   * Navigate to **Configuration → Integrations**
   * Confirm MQTT is connected
   * Check that entities are being created with data from RV-C

## Usage

### Dashboard

The included dashboard provides:

* **Main Tab**:
  * Battery status monitoring with gauges
  * Water heater controls
  * System information
  * Quick actions (emergency stop, reset)

* **History Tab**:
  * Historical graphs for battery voltage, current, and temperature
  * Water heater temperature history

* **Settings Tab**:
  * Water heater configuration
  * Mode selection buttons

### Automations

Several automations are included:

1. **Low Battery Warning**: Notification when battery level drops below 20%
2. **Auto-switch Water Heater**: Changes to gas mode when AC power is lost
3. **Safety Shutdown**: Turns off water heater when battery is critically low
4. **System Time Update**: Updates RV-C system time daily

### Scripts

Use these scripts to control RV-C devices:

1. **Set Water Heater Mode**: Choose between off, gas, electric, gas+electric, or auto
2. **Set RV-C Date/Time**: Synchronize time from Home Assistant
3. **Emergency Stop**: Turn off all major devices in an emergency

## Customization

### Adding More Sensors

To add additional RV-C data points:

1. Identify the MQTT topic and JSON structure from `rvc2mqtt.pl` output
2. Add a new sensor definition to the MQTT configuration
3. Update the dashboard to display the new sensor

Example:
```yaml
- name: "Your Sensor Name"
  state_topic: "RVC/MESSAGE_NAME/INSTANCE"
  value_template: "{{ value_json['parameter name'] }}"
  unit_of_measurement: "Unit"
  device_class: appropriate_class
```

### Adding Controls

To add control for another RV-C device:

1. Find the command DGN in the RV-C spec (rvc-spec.yml)
2. Add a switch, input_number, or other control entity
3. Create an automation or script that publishes to the appropriate set topic
4. Update the dashboard to include the new control

Example switch configuration:
```yaml
- name: "Device Control"
  command_topic: "RVC/COMMAND_NAME/set"
  state_topic: "RVC/STATUS_NAME/INSTANCE"
  value_template: "{{ value_json['parameter'] != 0 }}"
  payload_on: '{"instance":1,"parameter":1}'
  payload_off: '{"instance":1,"parameter":0}'
```

## Troubleshooting

1. **Check MQTT Connection**:
   * Verify MQTT broker is running
   * Check Home Assistant MQTT integration status
   * Try manually publishing/subscribing with `mosquitto_pub` and `mosquitto_sub`

2. **Debug RV-C Messages**:
   * Run `rvc2mqtt.pl` with the `--debug` flag
   * Monitor MQTT messages with `mosquitto_sub -v -t 'RVC/#'`

3. **Test Commands**:
   * Use `mosquitto_pub` to manually send commands:
     ```
     mosquitto_pub -t "RVC/WATERHEATER_COMMAND/set" -m '{"instance":1,"operating modes":0}'
     ```

4. **Check Log Files**:
   * Review Home Assistant logs for errors
   * Check for errors in `mqtt2rvc.pl` output

## Resources

* [Home Assistant MQTT Integration Documentation](https://www.home-assistant.io/integrations/mqtt/)
* [RV-C Specification](https://www.rv-c.com/)
* [MQTT Documentation](https://mosquitto.org/documentation/)