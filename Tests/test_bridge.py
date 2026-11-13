"""Test quota bridge installation in temporary settings only."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/claude-bridge.py"
SPEC = importlib.util.spec_from_file_location("claude_bridge", SCRIPT)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Mini Bar Bridge ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.settings = self.root / "settings.json"

    def test_preserves_all_other_settings_and_handles_spaces(self):
        original = {"hooks": {"Stop": []}, "theme": "dark"}
        self.settings.write_text(json.dumps(original))
        self.assertTrue(BRIDGE.install(self.settings, self.root))
        data = json.loads(self.settings.read_text())
        self.assertEqual(data["hooks"], original["hooks"])
        self.assertEqual(data["theme"], "dark")
        self.assertIn("'", data["statusLine"]["command"])
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)

    def test_preserves_existing_status_line(self):
        original = '{"statusLine":{"type":"command","command":"my-status"}}'
        self.settings.write_text(original)
        self.assertFalse(BRIDGE.install(self.settings, self.root))
        self.assertEqual(self.settings.read_text(), original)

    def test_install_is_idempotent(self):
        BRIDGE.install(self.settings, self.root)
        original = self.settings.read_text()
        self.assertTrue(BRIDGE.install(self.settings, self.root))
        self.assertEqual(self.settings.read_text(), original)

    def test_invalid_settings_are_preserved(self):
        self.settings.write_text("malformed")
        with self.assertRaises(ValueError):
            BRIDGE.install(self.settings, self.root)
        self.assertEqual(self.settings.read_text(), "malformed")
