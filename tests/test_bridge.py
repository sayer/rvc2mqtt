"""Exercise both production Perl entrypoints with MQTT/CAN replaced offline."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BridgeTests(unittest.TestCase):
    def run_bridge(self, script, *, messages=(), frames=""):
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "events.jsonl"
            env = os.environ | {
                "RVC_TEST_TRACE": str(trace),
                "RVC_TEST_SPEC": str(ROOT / "rvc2mqtt/rvc-spec.yml"),
                "RVC_TEST_MESSAGES": json.dumps(messages),
                "RVC_TEST_FRAMES": frames,
            }
            result = subprocess.run(
                ["perl", "-I", str(ROOT / "tests/lib"), "-MBridgeSandbox",
                 str(ROOT / "rvc2mqtt" / script)],
                env=env, text=True, capture_output=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("Error processing message", result.stdout)
            self.assertEqual(result.stderr, "")
            return [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []

    def test_light_command_is_not_confirmed_telemetry(self):
        events = self.run_bridge("mqtt2rvc.pl", messages=[{
            "topic": "RVC/DC_DIMMER_COMMAND_2/30/set",
            "payload": json.dumps({"instance": 30, "desired level": level, "command": command}),
        } for command, level in ((0, 100), (3, 0), (5, 100))])
        self.assertEqual(len([e for e in events if e["kind"] == "can"]), 3)
        self.assertFalse(any(e.get("topic", "").startswith("RVC/DC_DIMMER_STATUS_3/") for e in events))
        diagnostics = [e for e in events if e.get("topic") == "RVC/DC_DIMMER_COMMAND_2/30/debug"]
        self.assertEqual(len(diagnostics), 3)
        self.assertTrue(all(e["payload"]["confirmed"] is False for e in diagnostics))

    def test_native_panel_updates_keep_each_light_independent(self):
        events = self.run_bridge("rvc2mqtt.pl", frames=(
            "(1750000000.000000) can0 19FEDA42 [8] 1E FF C8 FC FF 00 FF FF\n"
            "(1750000001.000000) can0 19FEDA42 [8] 1B FF 00 FC FF 03 FF FF\n"
            "(1750000002.000000) can0 19FEDA42 [8] 1E FF 00 FC FF 03 FF FF\n"
        ))
        lights = [e for e in events if e.get("topic", "").startswith("RVC/DC_DIMMER_STATUS_3/")]
        self.assertEqual([(e["topic"], e["payload"]["operating status (brightness)"]) for e in lights], [
            ("RVC/DC_DIMMER_STATUS_3/30", 100),
            ("RVC/DC_DIMMER_STATUS_3/27", 0),
            ("RVC/DC_DIMMER_STATUS_3/30", 0),
        ])

    def test_driver_status_accepts_only_known_on_off(self):
        for status in range(4):
            with self.subTest(status=status):
                events = self.run_bridge("rvc2mqtt.pl", frames=(
                    f"(1750000000.000000) can0 196F0042 [8] 01 1E FF FF FF FF {status:02X} FF\n"
                ))
                lights = [e for e in events if e.get("topic") == "RVC/DC_DIMMER_STATUS_3/30"]
                self.assertEqual(len(lights), 1 if status in (0, 1) else 0)
                if lights:
                    self.assertEqual(lights[0]["payload"]["operating status (brightness)"], status * 100)

    def test_generator_start_stop_encoding(self):
        for command in (0, 1):
            with self.subTest(command=command):
                events = self.run_bridge("mqtt2rvc.pl", messages=[{
                    "topic": "RVC/GENERATOR_COMMAND/1/set",
                    "payload": json.dumps({"instance": 1, "command": command}),
                }])
                self.assertEqual(events, [{
                    "kind": "can", "command": f"cansend can0 19FFDAA0#{command:02X}FFFFFFFFFFFFFF",
                }])


if __name__ == "__main__":
    unittest.main()
