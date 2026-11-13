import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "workspace-handoff.py"
SPEC = importlib.util.spec_from_file_location("workspace_handoff", SCRIPT)
handoff = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(handoff)


class WorkspaceHandoffTests(unittest.TestCase):
    def test_excludes_machine_local_and_generated_paths(self):
        for path in [".git/config", ".local/settings.json", ".data/cache", ".env", ".env.production", "node_modules/pkg/a.js", "dist/index.html"]:
            with self.subTest(path=path):
                self.assertTrue(handoff.excluded(path))
        self.assertFalse(handoff.excluded(".env.example"))
        self.assertFalse(handoff.excluded("src/main.swift"))

    def test_registry_scope_skips_generated_docs_and_private_vault(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / ".git").mkdir()
            for name in ["LegalDocs", "ProjectsDocs", "Vault", "Switchboard"]:
                (root / name / ".git").mkdir(parents=True)
            registry = {"projects": [
                {"id": "legaldocs", "repos": [{"path": str(root / "LegalDocs")}]},
                {"id": "projectsdocs", "repos": [{"path": str(root / "ProjectsDocs")}]},
                {"id": "jorgesvault", "repos": [{"path": str(root / "Vault")}]},
            ]}
            (root / "workspace.registry.json").write_text(json.dumps(registry))
            self.assertEqual(handoff.repo_paths(root.resolve()), [".", "LegalDocs", "Switchboard"])

    def test_blockers_allow_source_changes_over_unchanged_destination_baseline(self):
        source = [{"path": "repo", "branch": "main", "head": "same", "originHead": "same",
                   "files": {"src/a.ts": {"sha256": "new"}}, "headBlobs": {}}]
        target = [{"path": "repo", "branch": "main", "head": "same", "originHead": "same",
                   "files": {"src/a.ts": {"sha256": "base"}},
                   "headBlobs": {"src/a.ts": {"sha256": "base"}}, "canFastForward": True}]
        self.assertEqual(handoff.blockers_for(source, target), [])

    def test_blockers_reject_destination_only_edit_and_branch_mismatch(self):
        source = [{"path": "repo", "branch": "main", "head": "same", "originHead": "same",
                   "files": {"src/a.ts": {"sha256": "source"}}, "headBlobs": {}}]
        target = [{"path": "repo", "branch": "feature", "head": "same", "originHead": "same",
                   "files": {"src/a.ts": {"sha256": "destination"}, "notes.txt": {"sha256": "note"}},
                   "headBlobs": {"src/a.ts": {"sha256": "base"}}, "canFastForward": False}]
        blockers = handoff.blockers_for(source, target)
        self.assertTrue(any("Branches differ" in message for message in blockers))
        self.assertTrue(any("Both devices changed" in message for message in blockers))
        self.assertTrue(any("Destination-only or edited" in message for message in blockers))

    def test_snapshot_reads_recursive_head_blobs_and_working_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            origin = root / "origin.git"
            repo = root / "repo"
            subprocess.run(["git", "init", "--bare", str(origin)], check=True, capture_output=True)
            subprocess.run(["git", "clone", str(origin), str(repo)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repo), "checkout", "-b", "main"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.test"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            nested = repo / "src" / "nested"
            nested.mkdir(parents=True)
            (nested / "item.txt").write_text("committed\n")
            subprocess.run(["git", "-C", str(repo), "add", "src/nested/item.txt"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-m", "fixture"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(repo), "push", "-u", "origin", "main"], check=True, capture_output=True)
            (nested / "item.txt").write_text("working change\n")
            snapshot = handoff.snapshot_repo(root, "repo")
            self.assertIn("src/nested/item.txt", snapshot["headBlobs"])
            self.assertNotEqual(snapshot["headBlobs"]["src/nested/item.txt"]["sha256"], snapshot["files"]["src/nested/item.txt"]["sha256"])


if __name__ == "__main__":
    unittest.main()
