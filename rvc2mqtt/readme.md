# RVC to MQTT Bridge Add-on

This add-on bridges your RV's RVC (Recreational Vehicle Control) CAN bus data to MQTT for use in Home Assistant.

## Configuration

The following options can be configured:

-   **MQTT User:** The username for your MQTT broker.
-   **MQTT Password:** The password for your MQTT broker.
-   **MQTT Topic Prefix:** The base MQTT topic to publish under.
-   **CAN Interface:** The name of the CAN interface (e.g., `can0`).

## Usage

The add-on will publish RVC data to MQTT topics based on the configured prefix.

## Logging

Logs are available in the add-on logs in Home Assistant.

## Reporting Issues

Please report any issues at [https://github.com/stephenayers/rvc2mqtt](https://github.com/stephenayers/rvc2mqtt)
