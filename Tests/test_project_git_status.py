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
            self.assertEqual(status["samples"], ["?? file.txt"])

            # Commit it -> becomes clean
            subprocess.run(["git", "-C", str(repo), "add", "file.txt"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-m", "initial"], check=True, capture_output=True)
            status_clean = git_status.check_single_repo(repo, root)
            self.assertIsNotNone(status_clean)
            self.assertEqual(status_clean["dirty"], 0)

    def test_v2_samples_render_like_v1(self):
        hexa = "0" * 40
        self.assertEqual(git_status._v1_sample("? new file.txt"), "?? new file.txt")
        self.assertEqual(
            git_status._v1_sample(f"1 .M N... 100644 100644 100644 {hexa} {hexa} src/a b.js"),
            " M src/a b.js",
        )
        self.assertEqual(
            git_status._v1_sample(f"2 R. N... 100644 100644 100644 {hexa} {hexa} R100 new.js\told.js"),
            "R  new.js",
        )

    def test_porcelain_v2_branch_and_upstream(self):
        output = "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +2 -1\n? x\n"
        branch, ahead, behind, samples, saw_ab = git_status._parse_porcelain_v2(output)
        self.assertEqual((branch, ahead, behind, saw_ab), ("main", 2, 1, True))
        self.assertEqual(samples, ["?? x"])
        self.assertEqual(git_status._parse_porcelain_v2("# branch.head (detached)\n")[0], "detached")

    def test_inspect_workspace_bounds_workers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            (root / "workspace.registry.json").write_text(json.dumps({"projects": [{"id": f"p{i}", "name": f"P{i}"} for i in range(6)]}))
            for i in range(6):
                subprocess.run(["git", "init", "-b", "main", str(root / f"P{i}")], check=True, capture_output=True)
            results = git_status.inspect_workspace(root, max_workers=2)
            self.assertEqual(sorted(k for k in results if k.startswith("p") and k[1:].isdigit()), [f"p{i}" for i in range(6)])

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
