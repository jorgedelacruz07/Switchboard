"""Configuration regressions in temporary folders; no real services or settings."""
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "switchboard.sh"


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Switchboard CLI ")
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name)
        self.app = self.workspace / "App With Spaces"
        self.app.mkdir()
        self.cli = self.app / "switchboard.sh"
        shutil.copyfile(SOURCE, self.cli)
        self.env = dict(os.environ)
        self.env.pop("PROJECTS_WORKSPACE_ROOT", None)
        (self.workspace / "project-dev.sh").write_text("#!/bin/bash\nexit 99\n")

    def run_cli(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.cli), *map(str, args)], env=self.env,
            capture_output=True, text=True, timeout=10,
        )

    def test_detects_parent_without_executing_launcher(self):
        result = self.run_cli("workspace")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.strip()), self.workspace.resolve())

    def test_configure_preserves_spaces_and_saves_private_setting(self):
        result = self.run_cli("configure", self.workspace)
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = json.loads((self.app / ".local/settings.json").read_text())
        self.assertEqual(Path(saved["workspaceRoot"]), self.workspace.resolve())

    def test_environment_takes_priority_over_saved_setting(self):
        self.assertEqual(self.run_cli("configure", self.workspace).returncode, 0)
        other = self.workspace / "Another Workspace"
        other.mkdir()
        (other / "project-dev.sh").write_text("#!/bin/bash\nexit 99\n")
        self.env["PROJECTS_WORKSPACE_ROOT"] = str(other)
        result = self.run_cli("workspace")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.strip()), other.resolve())

    def test_invalid_workspace_does_not_create_settings(self):
        result = self.run_cli("configure", self.app)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.app / ".local/settings.json").exists())

    def test_corrupt_settings_reports_error(self):
        settings = self.app / ".local/settings.json"
        settings.parent.mkdir()
        settings.write_text("invalid JSON")
        self.assertNotEqual(self.run_cli("workspace").returncode, 0)

    def test_missing_workspace_reports_error(self):
        (self.workspace / "project-dev.sh").unlink()
        result = self.run_cli("workspace")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("configure", result.stderr)

    def test_unknown_command_fails_without_creating_settings(self):
        result = self.run_cli("unsupported")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.app / ".local").exists())

    def login_fixture(self, capable=True):
        bundle = self.app / "build/Switchboard.app/Contents"
        executable = bundle / "MacOS/Switchboard"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\"\nexit 17\n")
        executable.chmod(0o700)
        with (bundle / "Info.plist").open("wb") as file:
            plistlib.dump({"SwitchboardLoginAPIVersion": 2} if capable else {}, file)
        return bundle

    def test_login_diagnostic_missing_bundle_does_not_build_or_launch(self):
        result = self.run_cli("login", "status")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no build or GUI launch", result.stderr)
        self.assertFalse((self.app / "build").exists())

    def test_old_bundle_never_receives_login_flag(self):
        self.login_fixture(capable=False)
        result = self.run_cli("login", "status")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Reviewed login-capable bundle", result.stderr)

    def test_login_explicit_commands_share_app_adapter_and_preserve_failures(self):
        self.login_fixture()
        for action, expected in (("status", "status"), ("diagnostic", "diagnostic"),
                                 ("migration-plan", "migration-plan"), ("on", "register"),
                                 ("off", "unregister"), ("register", "register"),
                                 ("unregister", "unregister")):
            with self.subTest(action=action):
                result = self.run_cli("login", action)
                self.assertEqual(result.returncode, 17)
                self.assertEqual(result.stdout, "--login\n" + expected + "\n")
        self.assertFalse((self.app / ".local").exists())

    def test_unknown_or_extra_login_action_never_executes_adapter(self):
        self.login_fixture()
        for args in (("login", "retry"), ("login", "register", "unexpected")):
            result = self.run_cli(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
