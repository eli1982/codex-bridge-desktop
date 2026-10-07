import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "ci_build_gate", Path(__file__).resolve().parents[1] / "scripts" / "ci_build_gate.py"
)
gate_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate_module)


class NightlyGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / "output"
        self.environment = patch.dict(os.environ, {
            "GITHUB_EVENT_NAME": "schedule",
            "GITHUB_REPOSITORY": "example/bridge",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "123",
            "GITHUB_OUTPUT": str(self.output),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_unchanged_successful_commit_skips_all_builds(self):
        statuses = {"statuses": [
            {"context": gate_module.CONTEXT, "state": "success"}
        ]}
        with patch.object(gate_module, "api_json", return_value=statuses) as api:
            gate_module.gate()
        self.assertEqual(self.output.read_text(), "build=false\n")
        self.assertEqual(api.call_count, 1)
        self.assertEqual(api.call_args.args[0], "GET")

    def test_failed_build_is_retried_next_night(self):
        statuses = {"statuses": [
            {"context": gate_module.CONTEXT, "state": "failure"}
        ]}
        with patch.object(gate_module, "api_json", side_effect=[statuses, {}]) as api:
            gate_module.gate()
        self.assertEqual(self.output.read_text(), "build=true\n")
        self.assertEqual(api.call_count, 2)
        self.assertEqual(api.call_args.args[2]["state"], "pending")

    def test_new_commit_without_build_marker_runs(self):
        with patch.object(gate_module, "api_json", side_effect=[
            {"statuses": []}, {}
        ]) as api:
            gate_module.gate()
        self.assertEqual(self.output.read_text(), "build=true\n")
        self.assertEqual(api.call_count, 2)

    def test_status_api_failure_does_not_launch_builds(self):
        with patch.object(gate_module, "api_json", side_effect=RuntimeError("API down")):
            with self.assertRaises(RuntimeError):
                gate_module.gate()
        self.assertFalse(self.output.exists())

    def test_manual_trigger_builds_even_after_success(self):
        os.environ["GITHUB_EVENT_NAME"] = "workflow_dispatch"
        with patch.object(gate_module, "api_json", return_value={}) as api:
            gate_module.gate()
        self.assertEqual(self.output.read_text(), "build=true\n")
        self.assertEqual(api.call_count, 1)
        self.assertEqual(api.call_args.args[0], "POST")

    def test_success_marker_requires_both_platform_jobs(self):
        os.environ["WINDOWS_RESULT"] = "success"
        os.environ["UNIX_RESULT"] = "success"
        with patch.object(gate_module, "api_json", return_value={}) as api:
            gate_module.record()
        self.assertEqual(api.call_args.args[2]["state"], "success")

        os.environ["UNIX_RESULT"] = "failure"
        with patch.object(gate_module, "api_json", return_value={}) as api:
            gate_module.record()
        self.assertEqual(api.call_args.args[2]["state"], "failure")


if __name__ == "__main__":
    unittest.main()
