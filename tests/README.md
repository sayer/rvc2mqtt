# Offline bridge regression tests

From the repository root, run the complete automated suite:

```sh
python3 -m unittest discover -s tests -v
```

Requirements: Python 3.9+, Perl, and the bridge's `JSON`, `YAML::Tiny`, and `Switch`
Perl modules. `JSON::PP` is part of Perl. The MQTT module is a test double; no MQTT
broker, CAN interface, Home Assistant instance, or Docker daemon is needed.

The suite starts both unmodified Perl entrypoints with the real RV-C specification
and JSON/YAML codecs. It feeds fixture CAN frames or MQTT callbacks, records
publications, intercepts `cansend`, and replaces the `candump` pipe with fixture
input. The test MQTT module has no socket implementation. Unexpected process
commands fail closed. Test support modules are not included in the add-on image.

Coverage includes command-versus-confirmed light state, valid and invalid driver
output states, independent physical-panel telemetry, and generator start/stop byte
encoding. Fixture results establish bridge behavior only; they do not establish
physical circuit mapping, real generator starting, delivery latency, or telemetry
freshness. There is no configured UI suite in this bridge repository.

Do not run `rvc2mqtt/test_lights.pl` as an automated unit test: its default mode
actuates lights, pumps, and locks. `mqtt_test.sh` and the appliance procedures in
`MQTT_TESTING.md` also require a separately supervised hardware session.
