#!/usr/bin/env python3
"""Fast, read-only Git status inspector for Switchboard.

Inspects local repositories declared in workspace.registry.json (and the meta-repo)
for uncommitted changes, unpushed commits, and unpulled commits.
Never reaches out to the network: runs only local Git queries.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path, PurePosixPath
import subprocess

MAX_WORKERS = 4
# Background polling must never take index locks that contend with real Git work.
GIT_ENV = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}


def _v1_sample(line: str) -> str:
    """Render a porcelain v2 entry like v1 (`XY path`) for the menu."""
    kind = line[:1]
    if kind == "?":
        return "?? " + line[2:]
    if kind == "!":
        return "!! " + line[2:]
    fields = {"1": 8, "2": 9, "u": 10}.get(kind)
    if fields is None:
        return line
    parts = line.split(" ", fields)
    if len(parts) <= fields:
        return line
    xy = parts[1].replace(".", " ")
    path = parts[fields].split("\t", 1)[0]
    return f"{xy} {path}"


def _parse_porcelain_v2(output: str) -> tuple[str, int, int, list[str], bool]:
    branch = "detached"
    ahead = 0
    behind = 0
    saw_ab = False
    dirty_samples: list[str] = []

    for line in output.splitlines():
        if not line:
            continue
        if line.startswith("# branch.head "):
            head = line[len("# branch.head "):].strip()
            branch = "detached" if head in ("", "(detached)") else head
        elif line.startswith("# branch.ab "):
            parts = line[len("# branch.ab "):].strip().split()
            if len(parts) == 2 and parts[0].startswith("+") and parts[1].startswith("-"):
                ahead = int(parts[0][1:])
                behind = int(parts[1][1:])
                saw_ab = True
        elif not line.startswith("# "):
            dirty_samples.append(_v1_sample(line))

    return branch, ahead, behind, dirty_samples, saw_ab


def check_single_repo(repo_path: Path, root: Path) -> dict | None:
    root = root.resolve()
    repo_path = repo_path.resolve()
    if not (repo_path / ".git").exists():
        return None
    try:
        res = subprocess.run(
            ["git", "-C", str(repo_path), "status", "--porcelain=v2", "--branch"],
            capture_output=True,
            text=True,
            timeout=3,
            env=GIT_ENV,
        )
        if res.returncode != 0:
            return None

        branch, ahead, behind, dirty_lines, saw_ab = _parse_porcelain_v2(res.stdout)

        # Fallback only when branch has no configured upstream tracking ref.
        if not saw_ab and branch != "detached":
            res_ab = subprocess.run(
                ["git", "-C", str(repo_path), "rev-list", "--left-right", "--count", f"origin/{branch}...HEAD"],
                capture_output=True,
                text=True,
                timeout=3,
                env=GIT_ENV,
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
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def inspect_workspace(root: Path, max_workers: int = MAX_WORKERS) -> dict:
    root = root.resolve()
    registry_file = root / "workspace.registry.json"
    registry_data = {}
    if registry_file.is_file():
        try:
            registry_data = json.loads(registry_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass

    projects = registry_data.get("projects", [])
    project_repo_targets: list[tuple[dict, list[tuple[str, Path]]]] = []
    unique_paths: dict[Path, Path] = {}

    for p in projects:
        pname = str(p.get("name", ""))
        repos = p.get("repos", [])
        targets: list[tuple[str, Path]] = []

        for r in repos:
            val = r.get("path")
            if not isinstance(val, str):
                continue
            val = val.replace("$HOME/Projects", str(root), 1)
            repo_path = Path(val).expanduser().resolve()
            targets.append((str(r.get("id", "")), repo_path))
            unique_paths[repo_path] = repo_path

        if not targets:
            direct = (root / pname).resolve()
            targets.append(("workspace", direct))
            unique_paths[direct] = direct

        project_repo_targets.append((p, targets))

    unique_paths[root] = root

    repo_cache: dict[Path, dict | None] = {}
    worker_count = max(1, min(max_workers, len(unique_paths)))
    with ThreadPoolExecutor(max_workers=worker_count) as pool:
        futures = {rp: pool.submit(check_single_repo, rp, root) for rp in unique_paths}
        for rp, fut in futures.items():
            repo_cache[rp] = fut.result()

    results: dict[str, dict] = {}
    for p, targets in project_repo_targets:
        pid = str(p.get("id", ""))
        pname = str(p.get("name", ""))
        repo_list = []
        total_dirty = 0
        total_ahead = 0
        total_behind = 0
        primary_branch = "master"

        for rid, repo_path in targets:
            st = repo_cache.get(repo_path)
            if st:
                repo_list.append(st)
                total_dirty += st["dirty"]
                total_ahead += st["ahead"]
                total_behind += st["behind"]
                if rid == "workspace" or primary_branch == "master":
                    primary_branch = st["branch"]

        if not repo_list:
            direct = (root / pname).resolve()
            st = repo_cache.get(direct)
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

    meta = repo_cache.get(root)
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
