#!/usr/bin/env python3
"""Fast, read-only Git status inspector for Switchboard.

Inspects local repositories declared in workspace.registry.json (and the meta-repo)
for uncommitted changes, unpushed commits, and unpulled commits.
Never reaches out to the network: runs only local Git queries.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys


def check_single_repo(repo_path: Path, root: Path) -> dict | None:
    root = root.resolve()
    repo_path = repo_path.resolve()
    if not (repo_path / ".git").exists():
        return None
    try:
        # Branch
        res_b = subprocess.run(
            ["git", "-C", str(repo_path), "branch", "--show-current"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        branch = res_b.stdout.strip() or "detached"

        # Dirty files (modified, staged, untracked)
        res_s = subprocess.run(
            ["git", "-C", str(repo_path), "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        dirty_lines = [l for l in res_s.stdout.strip().splitlines() if l]

        # Ahead / behind against origin/<branch> (or @{u})
        ahead, behind = 0, 0
        res_ab = subprocess.run(
            ["git", "-C", str(repo_path), "rev-list", "--left-right", "--count", f"origin/{branch}...HEAD"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if res_ab.returncode != 0 and branch != "detached":
            res_ab = subprocess.run(
                ["git", "-C", str(repo_path), "rev-list", "--left-right", "--count", "@{u}...HEAD"],
                capture_output=True,
                text=True,
                timeout=3,
            )
        if res_ab.returncode == 0:
            parts = res_ab.stdout.strip().split()
            if len(parts) == 2:
                behind = int(parts[0])
                ahead = int(parts[1])

        return {
            "name": repo_path.name,
            "path": str(repo_path.relative_to(root)),
            "branch": branch,
            "dirty": len(dirty_lines),
            "ahead": ahead,
            "behind": behind,
            "samples": dirty_lines[:5],
        }
    except (subprocess.SubprocessError, OSError):
        return None


def inspect_workspace(root: Path) -> dict:
    registry_file = root / "workspace.registry.json"
    registry_data = {}
    if registry_file.is_file():
        try:
            registry_data = json.loads(registry_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass

    projects = registry_data.get("projects", [])
    results: dict[str, dict] = {}

    for p in projects:
        pid = str(p.get("id", ""))
        pname = str(p.get("name", ""))
        repos = p.get("repos", [])

        repo_list = []
        total_dirty = 0
        total_ahead = 0
        total_behind = 0
        primary_branch = "master"

        # If project has repos defined in registry
        for r in repos:
            val = r.get("path")
            if not isinstance(val, str):
                continue
            val = val.replace("$HOME/Projects", str(root), 1)
            repo_path = Path(val).expanduser().resolve()
            st = check_single_repo(repo_path, root)
            if st:
                repo_list.append(st)
                total_dirty += st["dirty"]
                total_ahead += st["ahead"]
                total_behind += st["behind"]
                if r.get("id") == "workspace" or primary_branch == "master":
                    primary_branch = st["branch"]

        # If project didn't declare repos or none were found, check project root directly
        if not repo_list:
            direct = root / pname
            st = check_single_repo(direct, root)
            if st:
                repo_list.append(st)
                total_dirty += st["dirty"]
                total_ahead += st["ahead"]
                total_behind += st["behind"]
                primary_branch = st["branch"]

        status_obj = {
            "dirty": total_dirty,
            "ahead": total_ahead,
            "behind": total_behind,
            "branch": primary_branch,
            "repos": repo_list,
        }

        # Index under multiple keys so Switchboard matches by id, name, or key
        if pid:
            results[pid.lower()] = status_obj
            results[pid.lower().replace("-", "").replace("_", "")] = status_obj
            if pid.endswith("2026"):
                results[pid[:-4].lower()] = status_obj
        if pname:
            results[pname.lower()] = status_obj
            results[pname.lower().replace(" ", "").replace("-", "")] = status_obj
        proj_root = p.get("projectRoot")
        if isinstance(proj_root, str):
            folder_name = PurePosixPath(proj_root).name.lower()
            results[folder_name] = status_obj
            results[folder_name.replace("-", "").replace("_", "")] = status_obj

    # Also inspect meta-repo root
    meta = check_single_repo(root, root)
    if meta:
        results["workspace-root"] = {
            "dirty": meta["dirty"],
            "ahead": meta["ahead"],
            "behind": meta["behind"],
            "branch": meta["branch"],
            "repos": [meta],
        }

    return results


def main():
    parser = argparse.ArgumentParser(description="Git status inspector for Switchboard")
    parser.add_argument("--root", type=Path, default=Path.home() / "Projects")
    args = parser.parse_args()

    root = args.root.expanduser().resolve()
    status = inspect_workspace(root)
    print(json.dumps(status))


if __name__ == "__main__":
    main()
