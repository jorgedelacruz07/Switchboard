import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "project-git-status.py"
SPEC = importlib.util.spec_from_file_location("project_git_status", SCRIPT)
git_status = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(git_status)


class ProjectGitStatusTests(unittest.TestCase):
    def test_non_git_returns_none(self):
        with tempfile.TemporaryDirectory() as temp:
            self.assertIsNone(git_status.check_single_repo(Path(temp), Path(temp)))

    def test_clean_and_dirty_repo(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo = root / "MyRepo"
            repo.mkdir()
            subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Tester"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)

            # Untracked file
            (repo / "file.txt").write_text("hello")
            status = git_status.check_single_repo(repo, root)
            self.assertIsNotNone(status)
            self.assertEqual(status["dirty"], 1)
            self.assertEqual(status["branch"], "main")

            # Commit it -> becomes clean
            subprocess.run(["git", "-C", str(repo), "add", "file.txt"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-m", "initial"], check=True, capture_output=True)
            status_clean = git_status.check_single_repo(repo, root)
            self.assertIsNotNone(status_clean)
            self.assertEqual(status_clean["dirty"], 0)

    def test_inspect_workspace(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            proj = root / "DemoApp"
            proj.mkdir()
            subprocess.run(["git", "init", "-b", "master", str(proj)], check=True, capture_output=True)
            registry = {
                "projects": [
                    {
                        "id": "demoapp",
                        "name": "DemoApp",
                        "repos": [{"id": "workspace", "path": str(proj)}],
                    }
                ]
            }
            (root / "workspace.registry.json").write_text(json.dumps(registry))
            results = git_status.inspect_workspace(root)
            self.assertIn("demoapp", results)
            self.assertEqual(results["demoapp"]["branch"], "master")
            self.assertEqual(results["demoapp"]["dirty"], 0)


if __name__ == "__main__":
    unittest.main()
