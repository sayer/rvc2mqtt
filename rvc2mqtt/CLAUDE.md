# Claude Instructions for Home Assistant Motorhome Projects

## Project Context - Motorhome Automation

This project is specifically designed for **motorhome automation systems** that use MQTT as the primary communication protocol. Key project characteristics:

- **Motorhome-specific**: Configurations are tailored for RV/motorhome environments with mobile connectivity
- **MQTT-centric**: All device communication uses MQTT protocol for reliability in mobile scenarios
- **Template-based configuration**: Uses `configuration.template.yaml` for generating motorhome-specific configs
- **Variable specifications**: Each motorhome has different equipment, layouts, and requirements

## CRITICAL CONFIGURATION RULES

### Template System Usage
- **NEVER edit `configuration.yaml` directly** - This file is auto-generated
- **ALWAYS edit `configuration.template.yaml`** - This is the source template file
- **Use `%%TOKEN%%` replacement** - All motorhome-specific values use this token format
- **Run `update_config.sh`** - This script processes templates and generates final configuration

### Token Replacement Pattern
```yaml
# Example template usage in configuration.template.yaml
mqtt:
  broker: %%MQTT_BROKER_IP%%
  port: %%MQTT_PORT%%
  username: %%MQTT_USERNAME%%
  password: %%MQTT_PASSWORD%%

sensor:
  - platform: mqtt
    name: "%%MOTORHOME_NAME%% Water Tank"
    state_topic: "%%MOTORHOME_ID%%/water/level"
    unit_of_measurement: "%"
```

## Problem-Solving Approach

Before creating any Home Assistant configuration:
1. **Understand the motorhome automation goal** - What RV system is being automated and desired outcome
2. **Plan the MQTT architecture** - Consider topic structure, QoS levels, and mobile connectivity
3. **Think about mobile reliability** - Handle cellular drops, power cycling, and recovery scenarios
4. **Consider motorhome variations** - Use tokens for different equipment and layouts
5. **Minimize changes** - Work with existing motorhome infrastructure when possible

## Debugging and Template Development

### Debugging Templates for RV-C MQTT
When uncertain about RV-C message structure or token values, provide debugging templates:

```yaml
# Debug template for RV-C shade status - paste into Developer Tools > Template
{% set shade_code = "73" %}  # Replace with actual shade code for model year
{% set topic_data = states.sensor.shade_raw_data %}
{% if topic_data %}
Raw shade data for code {{ shade_code }}:
{{ topic_data.attributes }}

Motor Status: {{ topic_data.attributes['motor status definition'] | default('unknown') }}
Last Command: {{ topic_data.attributes['last command definition'] | default('unknown') }}
Forward Status: {{ topic_data.attributes['forward status definition'] | default('unknown') }}
Reverse Status: {{ topic_data.attributes['reverse status definition'] | default('unknown') }}
Position: {{ topic_data.attributes.position | default('unknown') }}
Motor Duty: {{ topic_data.attributes['motor duty'] | default('unknown') }}

Calculated State:
{% set motor = topic_data.attributes['motor status definition'] | default('inactive') %}
{% set last_cmd = topic_data.attributes['last command definition'] | default('none') %}
{% if motor == 'active' %}
  {% if last_cmd == 'toggle forward' %}OPENING
  {% elif last_cmd == 'toggle reverse' %}CLOSING
  {% else %}UNKNOWN_ACTIVE{% endif %}
{% else %}
  {% if last_cmd == 'toggle forward' %}OPEN
  {% elif last_cmd == 'toggle reverse' %}CLOSED
  {% else %}UNKNOWN_INACTIVE{% endif %}
{% endif %}
{% else %}
No shade data available - check MQTT connection and shade code
{% endif %}
```

```yaml
# Debug template for RV-C light brightness - paste into Developer Tools > Template  
{% set light_code = "43" %}  # Replace with actual light code for model year
{% set light_entity = "sensor.dc_dimmer_operating_status" %}
Light debugging for code {{ light_code }}:

Current brightness: {{ states('sensor.dc_dimmer_operating_status_1') }}
Raw JSON: {{ state_attr('sensor.dc_dimmer_operating_status_1', 'operating status (brightness)') }}

Is light on: {{ states('sensor.dc_dimmer_operating_status_1') | int > 0 }}
Command for ON: {"instance": {{ light_code }}, "desired level": 100, "command": 0}
Command for OFF: {"instance": {{ light_code }}, "desired level": 0, "command": 3}
```

```yaml
# Debug template for RV-C fan status - paste into Developer Tools > Template
{% set fan_code = "1" %}  # Replace with actual fan instance for model year
Fan debugging for instance {{ fan_code }}:

System Status: {{ states('sensor.roof_fan_1_system_status') }}
Fan Mode: {{ states('sensor.roof_fan_1_fan_mode') }}
Speed Mode: {{ states('sensor.roof_fan_1_speed_mode') }}

Command for ON: {"instance": {{ fan_code }}, "System Status": 1, "Fan Mode": 3, "Speed Mode": 3, "Fan Speed Setting": 140}
Command for OFF: {"instance": {{ fan_code }}, "System Status": 0, "Fan Mode": 3, "Speed Mode": 3, "Fan Speed Setting": 0}
```

## RV-C Protocol Integration via MQTT Bridge

### RV-C to MQTT Topic Structure
```yaml
# Standard RV-C MQTT topic hierarchy bridged from CAN bus
# Status topics (RV-C device reporting state)
"RVC/DC_DIMMER_STATUS_3/%%DEVICE_INSTANCE%%"      # Light dimmer status
"RVC/ROOF_FAN_STATUS_1/%%FAN_INSTANCE%%"          # Roof fan status  
"RVC/THERMOSTAT_STATUS_1/%%THERMOSTAT_INSTANCE%%" # HVAC thermostat status
"RVC/GENERATOR_STATUS_1"                           # Generator status
"RVC/TANK_STATUS/%%TANK_INSTANCE%%"                # Tank level status
"RVC/WINDOW_SHADE_CONTROL_STATUS/%%SHADE_INSTANCE%%" # Window shade status

# Command topics (Home Assistant sending commands to RV-C devices)
"RVC/DC_DIMMER_COMMAND_2/%%DEVICE_INSTANCE%%/set"      # Light dimmer commands
"RVC/ROOF_FAN_COMMAND_1/%%FAN_INSTANCE%%/set"          # Roof fan commands
"RVC/THERMOSTAT_COMMAND_1/%%THERMOSTAT_INSTANCE%%/set" # HVAC commands
"RVC/GENERATOR_COMMAND/1/set"                           # Generator commands
"RVC/WINDOW_SHADE_CONTROL_COMMAND/%%SHADE_INSTANCE%%/set" # Window shade commands
```

### RV-C Device Instance Codes by Model Year
```yaml
# RV-C devices use specific instance codes that vary by motorhome model year
# The update_config.sh handles these variations automatically

# Example: Docking lights RV-C instance codes
# 2023+ models: instance 43
# 2020-2022 models: instance 43  
# 2017-2019 models: instance 121
# Pre-2016 models: instance 121

mqtt:
  light:
    - name: "Docking Lights"
      state_topic: "RVC/DC_DIMMER_STATUS_3/%%DOCKING_LIGHTS_CODE%%"
      command_topic: "RVC/DC_DIMMER_COMMAND_2/%%DOCKING_LIGHTS_CODE%%/set"
      command_on_template: '{"instance": %%DOCKING_LIGHTS_CODE%%, "desired level": 100, "command": %%LIGHT_COMMAND_ON%%}'
```

### RV-C Message Structure Examples
```yaml
# RV-C devices send JSON payloads with specific field names
# Light dimmer status message:
{
  "instance": 43,
  "operating status (brightness)": 100,
  "command": 0
}

# Roof fan status message:
{
  "instance": 1, 
  "System Status definition": "On",
  "Fan Mode definition": "Manual",
  "Speed Mode definition": "High",
  "Fan Speed Setting": 140
}

# Window shade status message:
{
  "instance": 73,
  "motor status definition": "active",
  "last command definition": "toggle forward", 
  "forward status definition": "active",
  "reverse status definition": "inactive",
  "position": 50,
  "motor duty": 50
}
```

### Common Motorhome Tokens
```yaml
# Standard tokens used across motorhome configurations
# These are replaced by update_config.sh based on model year

# Lighting Control Codes
%%DOCKING_LIGHTS_CODE%%      # Docking lights instance code (varies by model year)
%%AWNING_LIGHTS%%            # Awning lights instance code 
%%EXTERIOR_ACCENT_LIGHTS%%   # Exterior accent lights instance code
%%PORCH_LIGHT%%              # Porch light instance code
%%UNDER_SLIDE_LIGHTS_1%%     # Under slide lights 1 instance code
%%UNDER_SLIDE_LIGHTS_2%%     # Under slide lights 2 instance code

# Ventilation Fan Codes  
%%VENT_FAN_1%%               # Mid bath fan instance code
%%VENT_FAN_2%%               # Rear bath fan instance code

# System Configuration
%%OPTIMISTIC_MODE%%          # true/false - Use optimistic MQTT mode
%%AMBIANT_TEMP%%             # Ambient temperature sensor instance
%%INDOOR_TEMP%%              # Indoor temperature sensor instance
%%LIGHT_COMMAND_ON%%         # Light on command value (0 or other)
%%LIGHT_COMMAND_OFF%%        # Light off command value (3 or other)

# Window Shade Codes (vary significantly by model year)
%%WINDSHIELD_DAY_CODE%%      # Windshield day shade instance
%%DRIVER_DAY_CODE%%          # Driver day shade instance  
%%PASSENGER_DAY_CODE%%       # Passenger day shade instance
%%ENTRY_DOOR_DAY_CODE%%      # Entry door day shade instance (not all models)
%%WINDSHIELD_NIGHT_CODE%%    # Windshield night shade instance
%%DRIVER_NIGHT_CODE%%        # Driver night shade instance
%%PASSENGER_NIGHT_CODE%%     # Passenger night shade instance
%%ENTRY_DOOR_NIGHT_CODE%%    # Entry door night shade instance
%%DINETTE_DAY_CODE%%         # Dinette day shade instance
%%DINETTE_NIGHT_CODE%%       # Dinette night shade instance
%%MID_BATH_NIGHT_CODE%%      # Mid bath night shade instance
%%REAR_BATH_NIGHT_CODE%%     # Rear bath night shade instance
%%DS_LIVING_DAY_CODE%%       # Driver side living day shade instance
%%DS_LIVING_NIGHT_CODE%%     # Driver side living night shade instance
%%BEDROOM_DRESSER_DAY_CODE%% # Bedroom dresser day shade instance
%%BEDROOM_DRESSER_NIGHT_CODE%% # Bedroom dresser night shade instance
%%BEDROOM_FRONT_DAY_CODE%%   # Bedroom front day shade instance
%%BEDROOM_FRONT_NIGHT_CODE%% # Bedroom front night shade instance
%%BEDROOM_REAR_DAY_CODE%%    # Bedroom rear day shade instance
%%BEDROOM_REAR_NIGHT_CODE%%  # Bedroom rear night shade instance
%%TOP_BUNK_NIGHT_CODE%%      # Top bunk night shade instance
%%BOTTOM_BUNK_NIGHT_CODE%%   # Bottom bunk night shade instance
%%KITCHEN_DAY_CODE%%         # Kitchen day shade instance (2023+ only)
%%KITCHEN_NIGHT_CODE%%       # Kitchen night shade instance (2023+ only)
%%DS_WINDOW1_DAY_CODE%%      # Driver side window 1 day shade (2023+ only)
%%DS_WINDOW1_NIGHT_CODE%%    # Driver side window 1 night shade (2023+ only)
%%DS_WINDOW2_DAY_CODE%%      # Driver side window 2 day shade (2023+ only)
%%DS_WINDOW2_NIGHT_CODE%%    # Driver side window 2 night shade (2023+ only)
```

## Configuration.template.yaml Best Practices

### RV-C MQTT Protocol Patterns
```yaml
# Common RV-C MQTT topic structures used in motorhome configurations
# State topics (receiving data from RV-C network)
state_topic: "RVC/DC_DIMMER_STATUS_3/%%DEVICE_CODE%%"
state_topic: "RVC/ROOF_FAN_STATUS_1/%%FAN_INSTANCE%%"
state_topic: "RVC/THERMOSTAT_STATUS_1/%%THERMOSTAT_INSTANCE%%"
state_topic: "RVC/GENERATOR_STATUS_1"
state_topic: "RVC/TANK_STATUS/%%TANK_INSTANCE%%"

# Command topics (sending commands to RV-C network)
command_topic: "RVC/DC_DIMMER_COMMAND_2/%%DEVICE_CODE%%/set"
command_topic: "RVC/ROOF_FAN_COMMAND_1/%%FAN_INSTANCE%%/set"
command_topic: "RVC/THERMOSTAT_COMMAND_1/%%THERMOSTAT_INSTANCE%%/set"
command_topic: "RVC/GENERATOR_COMMAND/1/set"

# Window shade topics
state_topic: "RVC/WINDOW_SHADE_CONTROL_STATUS/%%SHADE_CODE%%"
command_topic: "RVC/WINDOW_SHADE_CONTROL_COMMAND/%%SHADE_CODE%%/set"
```

### Conditional Equipment Configuration
```yaml
# Use conditional generation in update_config.sh rather than template conditionals
# The script handles model year differences automatically

# Example: Some tokens only exist for certain model years
# 2023+ models have KITCHEN_DAY_CODE and KITCHEN_NIGHT_CODE
# 2020-2022 models do not have these codes
# 2017-2019 models have different VENT_FAN instance codes

# The update_config.sh script will:
# 1. Only generate YAML for codes that exist for the model year
# 2. Replace %%ALL_SHADES%% with appropriate shade configurations
# 3. Replace %%ALL_SHADE_GROUPS%% with available shade groups
# 4. Set OPTIMISTIC_MODE based on model year capabilities
```
### Template File Organization
- Edit `configuration.template.yaml` as the master configuration
- Use `!include` statements with token replacement: `!include %%MOTORHOME_ID%%_automations.yaml`
- Group motorhome-specific files in subdirectories
- Maintain consistent indentation (2 spaces, no tabs)
- Add comments explaining token usage and equipment variations

### Proper Template YAML Syntax
```yaml
# Good: Template with proper token usage in configuration.template.yaml
mqtt:
  light:
    - name: "Docking Lights"
      unique_id: "docking_lights"
      state_topic: "RVC/DC_DIMMER_STATUS_3/%%DOCKING_LIGHTS_CODE%%"
      state_template: >-
        {% if value_json['operating status (brightness)']|int > 0 %}
          on
        {% else %}
          off
        {% endif %}
      command_topic: "RVC/DC_DIMMER_COMMAND_2/%%DOCKING_LIGHTS_CODE%%/set"
      command_on_template: '{"instance": %%DOCKING_LIGHTS_CODE%%, "desired level": 100, "command": %%LIGHT_COMMAND_ON%% }'
      command_off_template: '{"instance": %%DOCKING_LIGHTS_CODE%%, "desired level": 0, "command": %%LIGHT_COMMAND_OFF%% }'
      schema: "template"
      optimistic: %%OPTIMISTIC_MODE%%

  switch:
    - name: "Roof Fan 1 Control"
      unique_id: "roof_fan_1_switch"
      state_topic: "RVC/ROOF_FAN_STATUS_1/%%VENT_FAN_1%%"
      value_template: "{{ value_json['System Status definition'] }}"
      command_topic: "RVC/ROOF_FAN_COMMAND_1/%%VENT_FAN_1%%/set"
      payload_on: >-
        {"instance": %%VENT_FAN_1%%, "System Status": 1, "Fan Mode": 3, "Speed Mode": 3, "Fan Speed Setting": 140}
      payload_off: >-
        {"instance": %%VENT_FAN_1%%, "System Status": 0, "Fan Mode": 3, "Speed Mode": 3, "Fan Speed Setting": 0}
      state_on: "On"
      state_off: "Off"
      optimistic: false
      icon: "mdi:fan"

  sensor:
    - name: "Ambient Temperature"
      state_topic: "RVC/THERMOSTAT_AMBIENT_STATUS/%%AMBIANT_TEMP%%"
      unique_id: "THERMOSTAT_AMBIENT_STATUS"
      unit_of_measurement: "F"
      state_class: measurement
      value_template: "{{ (value_json['ambient temp F'] | float) | round(0) }}"
```
```yaml
# Good: Proper indentation and structure
automation:
  - alias: "Living Room Motion Light"
    description: "Turn on lights when motion detected"
    trigger:
      - platform: state
        entity_id: binary_sensor.living_room_motion
        to: "on"
    condition:
      - condition: numeric_state
        entity_id: sensor.living_room_illuminance
        below: 50
    action:
      - service: light.turn_on
        target:
          entity_id: light.living_room_ceiling
        data:
          brightness_pct: 80
          transition: 2
```

### Motorhome Entity Naming Conventions
- Use %%MOTORHOME_ID%% prefix: `sensor.%%MOTORHOME_ID%%_water_tank_fresh`
- Include equipment type: `binary_sensor.%%MOTORHOME_ID%%_generator_running`
- Use descriptive names: `climate.%%MOTORHOME_ID%%_main_ac` not `climate.%%MOTORHOME_ID%%_ac1`
- Be consistent across similar motorhomes
- Include location when multiple similar devices: `light.%%MOTORHOME_ID%%_bedroom_overhead`

### Template Validation and Processing
- Always validate template YAML syntax before running update_config.sh
- Test token replacement with sample RV-C device codes
- Verify generated configuration.yaml has valid RV-C topics and instances
- Test RV-C device communication after configuration updates
- Include validation checks for required RV-C device instance codes

## Automation Design Principles

### Trigger Best Practices
```yaml
# Multiple triggers with clear identification
trigger:
  - platform: state
    entity_id: binary_sensor.motion_sensor
    to: "on"
    id: "motion_detected"
  - platform: state
    entity_id: sun.sun
    to: "below_horizon"
    id: "sunset"
  - platform: time
    at: "22:00:00"
    id: "bedtime"
```

### Condition Logic
- Use explicit conditions rather than relying on implicit behavior
- Include time-based conditions for context-appropriate actions
- Add presence detection to avoid actions when nobody's home
- Use template conditions for complex logic

### Action Reliability
```yaml
action:
  # Check if entity exists before acting
  - condition: template
    value_template: "{{ states('light.living_room') != 'unavailable' }}"
  # Use choose for multiple action paths
  - choose:
      - conditions:
          - condition: state
            entity_id: input_boolean.guest_mode
            state: "on"
        sequence:
          - service: light.turn_on
            data:
              brightness_pct: 30
    default:
      - service: light.turn_on
        data:
          brightness_pct: 80
```

## Dashboard Configuration Excellence

### Lovelace UI Structure
```yaml
# Well-organized dashboard with clear hierarchy
title: Home Dashboard
views:
  - title: Overview
    path: overview
    type: sections
    sections:
      - title: Climate
        cards:
          - type: thermostat
            entity: climate.living_room
          - type: entities
            entities:
              - entity: sensor.living_room_temperature
                name: Current Temperature
              - entity: sensor.living_room_humidity
                name: Humidity Level
```

### Card Design Principles
- Use consistent spacing and alignment
- Group related entities logically
- Implement responsive design for mobile/tablet viewing
- Use meaningful icons and colors
- Provide clear labels and units

### Motorhome Dashboard Features
```yaml
# Tank level cards with visual indicators in lovelace template
- type: custom:button-card
  entity: sensor.%%MOTORHOME_ID%%_fresh_water
  name: "Fresh Water"
  icon: mdi:water
  styles:
    card:
      - height: 80px
    icon:
      - color: |
          [[[
            const level = parseInt(entity.state);
            if (level > 75) return 'blue';
            if (level > 50) return 'green';
            if (level > 25) return 'orange';
            return 'red';
          ]]]
  tap_action:
    action: more-info

# Generator status with conditional display
- type: conditional
  conditions:
    - entity: binary_sensor.%%MOTORHOME_ID%%_generator_present
      state: "on"
  card:
    type: entities
    title: "Generator"
    entities:
      - entity: switch.%%MOTORHOME_ID%%_generator
      - entity: sensor.%%MOTORHOME_ID%%_generator_runtime
```

### Performance Optimization
- Minimize the number of entities displayed on single view
- Use conditional cards to reduce rendering load
- Implement lazy loading for image-heavy dashboards
- Cache static content appropriately

## Sensor and Template Configuration

### MQTT Template Sensors for Motorhomes
```yaml
template:
  - sensor:
      - name: "%%MOTORHOME_NAME%% Total Water Capacity"
        unit_of_measurement: "gal"
        state: >
          {% set fresh = states('sensor.%%MOTORHOME_ID%%_fresh_water_gallons') | float(0) %}
          {% set gray = states('sensor.%%MOTORHOME_ID%%_gray_water_gallons') | float(0) %}
          {% set black = states('sensor.%%MOTORHOME_ID%%_black_water_gallons') | float(0) %}
          {{ (fresh + gray + black) | round(1) }}
        availability: >
          {{ states('sensor.%%MOTORHOME_ID%%_fresh_water_gallons') not in ['unknown', 'unavailable'] }}
          
      - name: "%%MOTORHOME_NAME%% Power Source"
        state: >
          {% if is_state('binary_sensor.%%MOTORHOME_ID%%_shore_power', 'on') %}
            Shore Power
          {% elif is_state('binary_sensor.%%MOTORHOME_ID%%_generator', 'on') %}
            Generator
          {% elif is_state('binary_sensor.%%MOTORHOME_ID%%_inverter', 'on') %}
            Battery/Inverter
          {% else %}
            Unknown
          {% endif %}
        icon: >
          {% if is_state('binary_sensor.%%MOTORHOME_ID%%_shore_power', 'on') %}
            mdi:power-plug
          {% elif is_state('binary_sensor.%%MOTORHOME_ID%%_generator', 'on') %}
            mdi:engine
          {% else %}
            mdi:battery
          {% endif %}
```

### MQTT Binary Sensors for Motorhome Equipment
```yaml
binary_sensor:
  - platform: mqtt
    name: "%%MOTORHOME_NAME%% Occupied"
    state_topic: "%%MOTORHOME_ID%%/presence/occupied"
    payload_on: "true"
    payload_off: "false"
    device_class: occupancy
    availability_topic: "%%MOTORHOME_ID%%/status"
    
  - platform: template
    sensors:
      %%MOTORHOME_ID%%_any_tank_full:
        friendly_name: "Any Tank Full"
        device_class: problem
        value_template: >
          {{ states('sensor.%%MOTORHOME_ID%%_gray_water') | float(0) > 80 or
             states('sensor.%%MOTORHOME_ID%%_black_water') | float(0) > 80 }}
        delay_on:
          minutes: 5  # Avoid false alarms from sensor fluctuations
```

## Integration Best Practices

### RV-C Device Configuration for Motorhomes
- Use RV-C device instance codes specific to each motorhome model year
- Configure appropriate RV-C message timeouts for CAN bus reliability  
- Implement proper RV-C status monitoring for device availability
- Group related RV-C systems for easier management (lighting zones, HVAC zones)
- Document RV-C device variations and optional equipment by model year

### RV-C Protocol Reliability
```yaml
# RV-C device configuration optimized for CAN bus communication
mqtt:
  # RV-C bridge handles protocol conversion
  optimistic: %%OPTIMISTIC_MODE%%  # Model year dependent
  
  # RV-C devices report availability through bridge
  availability_template: >-
    {% if value_json is defined and value_json['motor status definition'] is defined %}
    online
    {% else %}
    offline
    {% endif %}
    
  # RV-C status updates can be infrequent - use retain for persistence
  retain: true
```

### Security Considerations
- Use secrets.yaml for sensitive information
- Implement proper SSL/TLS certificates
- Configure firewall rules appropriately
- Regular backup of configuration files
- Use strong authentication methods

## Script and Scene Management

### Reusable Scripts
```yaml
script:
  notify_all:
    alias: "Notify All Devices"
    description: "Send notification to all family members"
    fields:
      title:
        description: "Notification title"
        example: "Security Alert"
      message:
        description: "Notification message"
        example: "Front door opened"
      priority:
        description: "Priority level"
        default: "normal"
        selector:
          select:
            options:
              - "low"
              - "normal"
              - "high"
    sequence:
      - service: notify.mobile_app_johns_phone
        data:
          title: "{{ title }}"
          message: "{{ message }}"
          data:
            priority: "{{ priority }}"
```

### Scene Configuration
```yaml
scene:
  - name: "Movie Time"
    entities:
      light.living_room:
        state: on
        brightness: 30
        color_temp: 454
      light.kitchen:
        state: off
      media_player.tv:
        state: on
        source: "Netflix"
      climate.living_room:
        temperature: 21
```

## Error Handling and Logging

### Robust Error Handling
```yaml
automation:
  - alias: "Backup System State"
    trigger:
      - platform: time
        at: "03:00:00"
    action:
      - service: shell_command.create_backup
      - wait_template: "{{ is_state('shell_command.create_backup', 'success') }}"
        timeout: 300
      - choose:
          - conditions:
              - condition: template
                value_template: "{{ wait.completed }}"
            sequence:
              - service: persistent_notification.create
                data:
                  message: "Backup completed successfully"
        default:
          - service: notify.admin
            data:
              message: "Backup failed - manual intervention required"
```

### Logging Configuration
```yaml
logger:
  default: warning
  logs:
    homeassistant.components.automation: info
    homeassistant.components.script: info
    custom_components.my_integration: debug
```

## Testing and Validation

### Automation Testing
- Test all trigger conditions manually
- Verify actions work with unavailable entities
- Check automation behavior during system restarts
- Test edge cases and failure scenarios

### Configuration Validation
- Use YAML validators before applying changes
- Test configuration in development environment first
- Implement gradual rollout for major changes
- Maintain rollback procedures

## Documentation Standards

### Inline Documentation
```yaml
# Automation: Energy Saving Mode
# Purpose: Reduce energy consumption during specified hours
# Triggers: Time-based (10 PM) or manual activation
# Dependencies: input_boolean.energy_saving, group.all_lights
# Last Modified: 2024-01-15
automation:
  - alias: "Energy Saving Mode"
    description: "Automatically reduce energy consumption"
    # ... configuration
```

### Entity Documentation
- Document the purpose and expected behavior of custom sensors
- Include units of measurement and expected value ranges
- Note any dependencies or requirements
- Explain calculation methods for template sensors

## Performance and Maintenance

### Resource Management
- Monitor CPU and memory usage regularly
- Implement database cleanup routines
- Use efficient polling intervals for sensors
- Archive old data appropriately

### Update Management
```yaml
# Update automation with safety checks
automation:
  - alias: "Safe Home Assistant Update"
    trigger:
      - platform: state
        entity_id: update.home_assistant_core_update
        to: "on"
    condition:
      - condition: time
        after: "02:00:00"
        before: "05:00:00"
      - condition: state
        entity_id: binary_sensor.anyone_home
        state: "off"
    action:
      - service: homeassistant.update_entity
        target:
          entity_id: update.home_assistant_core_update
```

## Quality Checklist

### Before Deploying Template Configuration
- [ ] Template YAML syntax is valid
- [ ] All %%TOKEN%% placeholders are properly formatted for RV-C devices
- [ ] RV-C device instance code replacement logic is tested
- [ ] RV-C MQTT topics follow correct PGN naming conventions
- [ ] Equipment conditional logic matches RV-C device availability
- [ ] update_config.sh processes template successfully for target model year
- [ ] Generated configuration.yaml has valid RV-C device instances
- [ ] RV-C to MQTT bridge connectivity is verified
- [ ] Mobile network resilience is tested with RV-C bridge

### RV-C Motorhome-Specific Quality Checks
- [ ] All RV-C tank sensors are properly configured with correct instances
- [ ] RV-C power source detection works correctly (generator, shore, inverter)
- [ ] RV-C generator controls function through proper PGN commands
- [ ] RV-C HVAC thermostat integration working with correct instances  
- [ ] RV-C window shade controls configured with model-year appropriate codes
- [ ] RV-C roof fan controls setup with proper instance codes
- [ ] RV-C lighting dimmer integration working across all zones
- [ ] RV-C device availability monitoring implemented through bridge status

Remember: This is a motorhome-specific project using **RV-C (Recreational Vehicle - Controller Area Network) protocol** bridged to MQTT for Home Assistant integration. Always work with configuration.template.yaml, use %%TOKEN%% replacement for RV-C device instances, and provide debugging templates when uncertain. Never edit configuration.yaml directly - it's auto-generated by update_config.sh based on model year RV-C device mappings. When unsure about RV-C message structure or device instances, provide testable template code for Developer Tools rather than guessing. Understanding RV-C protocol, PGNs (Parameter Group Numbers), and device instances is crucial for successful motorhome automation.
