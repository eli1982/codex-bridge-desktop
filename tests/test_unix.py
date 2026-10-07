import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "bridge", Path(__file__).resolve().parents[1] / "unix" / "bridge.py"
)
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


class UnixSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.project = self.base / "project"
        self.project.mkdir()
        self.patches = [
            patch.object(bridge, "CONFIG_HOME", self.base / "config"),
            patch.object(bridge, "STATE_HOME", self.base / "state"),
            patch.object(bridge, "SETTINGS", self.base / "config/settings.json"),
            patch.object(bridge, "DEVSPACE_HOME", self.base / "config/devspace"),
            patch.object(bridge, "STATE", self.base / "state/state.json"),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def test_rejects_home_and_filesystem_root(self):
        for root in (Path.home(), Path(Path.home().anchor)):
            with self.subTest(root=str(root)):
                with self.assertRaises(ValueError):
                    bridge.checked_root(str(root))

    def test_uses_exact_one_root_and_keeps_owner_secret_separate(self):
        bridge.prepare_devspace(str(self.project), "https://bridge.example.invalid")
        config = json.loads((bridge.DEVSPACE_HOME / "config.json").read_text())
        auth = json.loads((bridge.DEVSPACE_HOME / "auth.json").read_text())
        self.assertEqual(config["allowedRoots"], [str(self.project)])
        self.assertEqual(config["host"], "127.0.0.1")
        self.assertNotIn("ownerToken", config)
        self.assertGreaterEqual(len(auth["ownerToken"]), 32)

    def test_off_with_stale_pid_record_does_not_signal_other_process(self):
        bridge.save_json(bridge.STATE, {
            "desired": "running", "status": "healthy",
            "daemon": {"pid": 1, "created": 0},
            "devspace": {"pid": 1, "created": 0},
            "tunnel": {"pid": 1, "created": 0},
        })
        bridge.off()
        self.assertEqual(bridge.load_json(bridge.STATE)["desired"], "stopped")
        self.assertEqual(bridge.load_json(bridge.STATE)["status"], "off")

    def test_rotate_revokes_persisted_oauth_and_changes_owner_password(self):
        bridge.save_json(bridge.STATE, {"desired": "stopped", "status": "off"})
        database = bridge.STATE_HOME / "devspace-state/devspace.sqlite"
        database.parent.mkdir(parents=True)
        database.write_text("test-state")
        auth = bridge.DEVSPACE_HOME / "auth.json"
        bridge.save_json(auth, {"ownerToken": "previous-owner-password"})
        bridge.rotate()
        self.assertFalse(database.exists())
        self.assertNotEqual(json.loads(auth.read_text())["ownerToken"],
                            "previous-owner-password")
    def test_on_without_dependencies_does_not_create_runtime(self):
        bridge.save_json(bridge.SETTINGS, {
            "projectRoot": str(self.project), "autoOff": "1h"
        })
        with patch.object(bridge, "shutil_which", return_value=None):
            with self.assertRaises(RuntimeError):
                bridge.on()
        self.assertFalse(bridge.STATE.exists())


if __name__ == "__main__":
    unittest.main()