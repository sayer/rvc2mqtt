# Repository Guidelines

## Project Structure & Module Organization
- Core bridges: `rvc2mqtt.pl` (CAN → MQTT) and `mqtt2rvc.pl` (MQTT → CAN); helpers such as `mqtt_rvc_set.pl`, `map_window_shade.pl`, `healthcheck.pl`, and the command `.sh` scripts cover device-specific flows.
- `run.sh` orchestrates CAN setup and daemon supervision; keep it aligned with add-on packaging in `addon.yaml`, `config.yaml`, `build.yaml`, and the `Dockerfile`.
- `rvc-spec.yml` is the reference RV-C map mirrored to `/coachproxy/etc/rvc-spec.yml`; supporting notes live in `README.md` and `MQTT_TESTING.md`.

## Build, Test, and Development Commands
- `docker build -t rvc2mqtt-addon .` builds the add-on image; retag for the architecture declared in `build.yaml`.
- `docker run --rm --net host --privileged rvc2mqtt-addon` mimics the Supervisor runtime and needs CAN pass-through.
- `bash run.sh` boots the supervisor locally; ensure `can0` exists or mock it with `slcan` first.
- `perl -c script.pl` checks syntax; `perl mqtt2rvc.pl --debug --interface can0 --specfile ./rvc-spec.yml` runs the bridge during iteration.

## Coding Style & Naming Conventions
- Match the two-space indentation in Perl, keep `use strict; use warnings;`, and name subs with concise snake_case identifiers.
- RV-C DGNs remain uppercase in `rvc-spec.yml`; MQTT topics stay lowercase with slash separators.
- Shell scripts start with `#!/bin/bash`; enable `set -euo pipefail` in new utilities unless supervising long-running daemons.
- YAML keys stay lowercase_with_underscores; add only brief comments above complex logic.

## Testing Guidelines
- Follow the workflow in `MQTT_TESTING.md`; watch CAN traffic with `candump` while exercising new DGN mappings.
- Use `test_lights.pl` for regression checks and `mqtt_monitor.pl` to confirm topic chatter before shipping.
- Record manual scenarios in pull requests and capture syntax checks or Docker dry runs when container behavior changes.

## Commit & Pull Request Guidelines
- Mirror the concise, imperative commit style in history (`bump version…; update rvc-spec.yml`), keeping summaries ≤72 characters.
- Squash to logical commits and justify spec or protocol changes in the body.
- Pull requests should state user impact, sample MQTT payloads or candump excerpts, and the hardware or broker used for tests.
- All Git pushes should be done as an actual PR. Use the "gh pr" command

## Security & Configuration Tips
- Keep secrets out of version control; `run.sh` reads MQTT credentials from `/data/options.json`.
- Validate `rvc-spec.yml` against the RV-C spec and search for duplicate DGNs with `grep -n "^[0-9A-F]\\{4,\\}:" rvc-spec.yml`.
- Preserve CAN bitrate setup and restart safeguards inside `run.sh` to avoid outages.
