"""Installer keeps one official Switchboard application link."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.app = self.repo / "build/Switchboard.app"
        self.apps = self.home / "Applications"
        self.repo.mkdir()
        self.app.mkdir(parents=True)
        self.apps.mkdir(parents=True)
        self.bin.mkdir()
        (self.repo / "install.sh").write_text((REPO / "install.sh").read_text())
        runner = self.repo / "switchboard.sh"
        runner.write_text("#!/bin/sh\ncase \"$1\" in build|connect-claude) exit 0 ;; *) exit 1 ;; esac\n")
        runner.chmod(0o755)
        opener = self.bin / "open"
        opener.write_text("#!/bin/sh\nexit 0\n")
        opener.chmod(0o755)
        self.canonical = self.apps / "Switchboard.app"
        self.legacy = [self.apps / "Mini Bar.app", self.apps / "Projects Menu.app"]

    def run_installer(self):
        return subprocess.run(
            ["/bin/bash", str(self.repo / "install.sh")],
            env={**os.environ, "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin"},
            capture_output=True,
            text=True,
        )

    def test_removes_only_exact_legacy_aliases_and_keeps_one_canonical_app(self):
        self.canonical.symlink_to(self.app)
        for alias in self.legacy:
            alias.symlink_to(self.app)
        unrelated_target = self.root / "Other.app"
        unrelated_target.mkdir()
        unrelated = self.apps / "Unrelated.app"
        unrelated.symlink_to(unrelated_target)

        result = self.run_installer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.canonical.is_symlink())
        self.assertEqual(self.canonical.resolve(), self.app)
        self.assertTrue(all(not alias.is_symlink() for alias in self.legacy))
        self.assertEqual(unrelated.resolve(), unrelated_target)
        self.assertEqual(result.stdout.count("Removed duplicate compatibility app link:"), 2)

    def test_regular_legacy_file_is_preserved_and_stops_install(self):
        legacy_file = self.legacy[0]
        legacy_file.write_text("user file")

        result = self.run_installer()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(legacy_file.read_text(), "user file")
        self.assertFalse(self.canonical.exists())


if __name__ == "__main__":
    unittest.main()
