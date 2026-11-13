#!/usr/bin/env python3
"""Safe, workspace-wide Air/Mini baton transfer for Switchboard.

Only Git repositories declared by workspace.registry.json are transferred (plus
the Projects meta-repository). Git metadata, secrets, local state, and generated
artifacts remain machine-local. Transfer is blocked when either side has staged
work, unpublished commits, divergent branches, or destination-only edits.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import stat
import subprocess
import sys
from datetime import datetime, timezone

VERSION = "2"
STATE_REL = "Switchboard/.local/workspace-handoff.json"
LOCK_REL = "Switchboard/.local/workspace-handoff.lock"
EXCLUDED_PROJECTS = {"projectsdocs", "jorgesvault"}
EXCLUDED_PARTS = {
    ".git", ".local", ".data", ".evidence", ".playwright-mcp", "node_modules",
    "dist", "build", ".next", ".turbo", ".vite", "coverage", "target",
    ".worktrees", ".obsidian", ".Trash", ".legacy-backup",
}


class HandoffError(RuntimeError):
    pass


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def excluded(path: str) -> bool:
    parts = PurePosixPath(path).parts
    return any(part in EXCLUDED_PARTS for part in parts) or any(
        part == ".env" or (part.startswith(".env.") and part != ".env.example")
        for part in parts
    )


def run(args, *, cwd=None, input_data=None, check=True):
    result = subprocess.run(args, cwd=cwd, input=input_data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if check and result.returncode:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise HandoffError(detail or f"Command failed: {shlex.join(map(str, args))}")
    return result


def git(repo: Path, *args, check=True):
    return run(["git", "-C", str(repo), *args], check=check).stdout.decode("utf-8", "replace").strip()


def file_digest(path: Path):
    st = path.lstat()
    if stat.S_ISLNK(st.st_mode):
        data = os.readlink(path).encode("utf-8", "surrogateescape")
        digest = hashlib.sha256(data).hexdigest()
        kind = "link"
    elif stat.S_ISREG(st.st_mode):
        h = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                h.update(chunk)
        digest = h.hexdigest()
        kind = "file"
    else:
        return None
    mode = stat.S_IMODE(st.st_mode)
    if kind == "file":
        mode = 0o755 if mode & 0o111 else 0o644
    return {"sha256": digest, "mode": mode, "kind": kind}


def tracked_and_untracked(repo: Path):
    raw = run(["git", "-C", str(repo), "ls-files", "--cached", "--others",
               "--exclude-standard", "-z"]).stdout
    return sorted({p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0")
                   if p and not excluded(p.decode("utf-8", "surrogateescape"))})


def snapshot_repo(root: Path, rel: str, *, fetch=False):
    repo = root / rel if rel != "." else root
    if not repo.exists() or git(repo, "rev-parse", "--show-toplevel") != str(repo.resolve()):
        raise HandoffError(f"Repository is missing or nested path changed: {rel}")
    branch = git(repo, "branch", "--show-current")
    if not branch:
        raise HandoffError(f"Detached HEAD needs review: {rel}")
    origin = git(repo, "remote", "get-url", "origin", check=False)
    if not origin:
        raise HandoffError(f"No origin remote: {rel}")
    remote_ref = f"refs/remotes/origin/{branch}"
    if fetch:
        run(["git", "-C", str(repo), "fetch", "--no-tags", "origin",
             f"+refs/heads/{branch}:{remote_ref}"])
    head = git(repo, "rev-parse", "HEAD")
    origin_head = git(repo, "rev-parse", remote_ref, check=False)
    if not origin_head:
        raise HandoffError(f"origin/{branch} is unavailable: {rel}")
    staged = git(repo, "diff", "--cached", "--name-only", "-z")
    if staged:
        raise HandoffError(f"Staged changes need review before handoff: {rel}")
    files = {}
    for name in tracked_and_untracked(repo):
        path = repo / name
        if path.exists() or path.is_symlink():
            value = file_digest(path)
            if value is not None:
                files[name] = value
    head_blobs = {}
    for entry in run(["git", "-C", str(repo), "ls-tree", "-r", "-z", "--full-tree", "HEAD"]).stdout.split(b"\0"):
        if not entry:
            continue
        meta, raw_path = entry.split(b"\t", 1)
        mode, kind, oid = meta.decode("ascii").split()
        path = raw_path.decode("utf-8", "surrogateescape")
        if kind == "blob" and not excluded(path):
            content = run(["git", "-C", str(repo), "cat-file", "blob", oid]).stdout
            head_blobs[path] = {"sha256": hashlib.sha256(content).hexdigest(),
                                "mode": 0o777 if mode == "120000" else (0o755 if mode == "100755" else 0o644),
                                "kind": "link" if mode == "120000" else "file"}
    can_fast_forward = run(["git", "-C", str(repo), "merge-base", "--is-ancestor", "HEAD", remote_ref], check=False).returncode == 0
    return {"path": rel, "branch": branch, "head": head, "originHead": origin_head,
            "files": files, "headBlobs": head_blobs, "canFastForward": can_fast_forward}


def repo_paths(root: Path):
    registry = root / "workspace.registry.json"
    if not registry.is_file():
        raise HandoffError("workspace.registry.json is missing; cannot define workspace scope.")
    try:
        data = json.loads(registry.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HandoffError(f"workspace registry is unreadable: {error}") from error
    paths = {"."} if (root / ".git").exists() else set()
    for project in data.get("projects", []):
        if project.get("id") in EXCLUDED_PROJECTS:
            continue
        for repo in project.get("repos", []):
            value = repo.get("path")
            if not isinstance(value, str):
                continue
            value = value.replace("$HOME/Projects", str(root), 1)
            candidate = Path(value).expanduser().resolve()
            if candidate != root and root not in candidate.parents:
                continue
            if (candidate / ".git").exists():
                paths.add(candidate.relative_to(root).as_posix())
    if (root / "Switchboard/.git").exists():
        paths.add("Switchboard")
    return sorted(paths, key=lambda p: (p.count("/"), p))


def peer_call(peer: str, action: str, payload=None):
    remote = f"python3 ~/Projects/Switchboard/scripts/workspace-handoff.py --internal {action}"
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", peer, remote],
                            input=(json.dumps(payload).encode() if payload is not None else b""),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise HandoffError(result.stderr.decode("utf-8", "replace").strip() or f"{peer} is unavailable")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise HandoffError(f"Invalid handoff response from {peer}") from error


def ensure_peer_version(peer: str):
    result = peer_call(peer, "version")
    if result.get("version") != VERSION:
        raise HandoffError(f"Switchboard handoff helper on {peer} is outdated; sync and rebuild it first.")


def acquire_lock(role: str):
    if role == "host":
        root = Path.home() / "Projects"
        lock_path = root / LOCK_REL
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        stream = lock_path.open("a+")
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            stream.close()
            raise HandoffError("A workspace handoff is already running.") from error
        return stream
    return peer_lock("macmini")


def peer_lock(peer: str):
    code = r'''import fcntl, os, pathlib, sys
p=pathlib.Path.home()/"Projects/Switchboard/.local/workspace-handoff.lock"
p.parent.mkdir(parents=True, exist_ok=True)
f=p.open("a+")
try: fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: sys.exit("A workspace handoff is already running.")
print("LOCKED", flush=True)
sys.stdin.read()
'''
    process = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", peer,
                                 "python3", "-c", code], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
    line = process.stdout.readline().strip()
    if line != "LOCKED":
        error = process.stderr.read().strip()
        process.terminate()
        raise HandoffError(error or f"Could not lock workspace handoff state on {peer}")
    return process


def release_lock(lock):
    if isinstance(lock, subprocess.Popen):
        try:
            lock.stdin.close()
        except OSError:
            pass
        lock.wait(timeout=8)
    else:
        lock.close()


def get_state(role):
    if role == "host":
        return local_state(Path.home() / "Projects")
    return peer_call("macmini", "state-read")


def set_state(state, role):
    if role == "host":
        root = Path.home() / "Projects"
        path = root / STATE_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(state, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        os.replace(temp, path)
    else:
        peer_call("macmini", "state-write", state)


def stop_live_sync(root: Path):
    launcher = root / "project-remote.sh"
    if not launcher.is_file():
        raise HandoffError("project-remote.sh is unavailable; cannot safely pause Live Sync.")
    pid_files = sorted(Path("/tmp").glob("project-remote-sync-*.pid"))
    stopped = []
    for pid_file in pid_files:
        project = pid_file.name[len("project-remote-sync-"):-len(".pid")]
        result = subprocess.run(["/bin/bash", str(launcher), "sync", "stop", project],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise HandoffError(f"Could not stop Live Sync for {project}.")
        stopped.append(project)
    return stopped


def local_state(root: Path):
    path = root / STATE_REL
    if not path.exists():
        return {"version": 1, "owner": "client", "phase": "ready", "target": None,
                "updatedAt": None, "blockers": [], "initialOwner": "Air (workspace default)"}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("version") != 1 or value.get("owner") not in {"client", "host"}:
            raise ValueError("unsupported state")
        return value
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise HandoffError(f"Workspace baton state needs repair: {error}") from error


def discover_snapshots(root: Path, role: str, rels):
    if role == "client":
        return [snapshot_repo(root, rel, fetch=True) for rel in rels]
    return peer_call("macbook-air", "inspect", {"paths": rels, "fetch": True})


def remote_snapshots(role: str, rels, *, fetch=True):
    target = "macmini" if role == "client" else "macbook-air"
    return peer_call(target, "inspect", {"paths": rels, "fetch": fetch})


def blockers_for(source, target):
    blockers = []
    by_target = {r["path"]: r for r in target}
    for src in source:
        dst = by_target.get(src["path"])
        if not dst:
            blockers.append(f"Missing repository on destination: {src['path']}")
            continue
        rel = src["path"]
        if src["branch"] != dst["branch"]:
            blockers.append(f"Branches differ in {rel}: {src['branch']} vs {dst['branch']}")
        if src["head"] != src["originHead"]:
            blockers.append(f"Publish or pull source branch before handoff: {rel}")
        if dst["originHead"] != src["originHead"]:
            blockers.append(f"origin changed during handoff preflight: {rel}")
        if dst["head"] != src["head"] and not dst["canFastForward"]:
            blockers.append(f"Destination Git HEAD needs fast-forward alignment: {rel}")
        source_files, target_files = src["files"], dst["files"]
        for path, target_value in target_files.items():
            source_value = source_files.get(path)
            if source_value is not None and source_value == target_value:
                continue
            base = dst["headBlobs"].get(path)
            if source_value is None:
                if base and target_value == base:
                    continue
                blockers.append(f"Destination-only or edited file: {rel}/{path}")
            elif base and target_value == base:
                continue
            else:
                blockers.append(f"Both devices changed the same file: {rel}/{path}")
        for path in set(dst["headBlobs"]) - set(target_files):
            if path in source_files:
                blockers.append(f"Destination deleted a file still present on source: {rel}/{path}")
    extra = set(by_target) - {r["path"] for r in source}
    blockers.extend(f"Destination has a repository missing on source: {p}" for p in sorted(extra))
    return blockers


def internal(action):
    root = Path.home() / "Projects"
    if action == "state-read":
        print(json.dumps(local_state(root), sort_keys=True))
        return
    if action == "state-write":
        value = json.load(sys.stdin)
        path = root / STATE_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        os.replace(temp, path)
        print(json.dumps({"ok": True}))
        return
    if action == "inspect":
        payload = json.load(sys.stdin)
        if any(Path(rel).is_absolute() or ".." in PurePosixPath(rel).parts for rel in payload["paths"]):
            raise HandoffError("Unsafe repository path in inspection request.")
        result = [snapshot_repo(root, rel, fetch=bool(payload.get("fetch"))) for rel in payload["paths"]]
        print(json.dumps(result, sort_keys=True))
        return
    if action == "list-paths":
        print(json.dumps(repo_paths(root)))
        return
    if action == "version":
        print(json.dumps({"version": VERSION}))
        return
    if action == "prepare":
        plan = json.load(sys.stdin)
        for rel, entry in plan.items():
            if Path(rel).is_absolute() or ".." in PurePosixPath(rel).parts:
                raise HandoffError(f"Unsafe repository path: {rel}")
            repo = root / rel if rel != "." else root
            current = snapshot_repo(root, rel)
            expected = entry["expected"]
            for key in ("head", "branch", "originHead", "files"):
                if current[key] != expected[key]:
                    raise HandoffError(f"Destination changed during handoff preflight: {rel}; no reset was applied to it.")
            run(["git", "-C", str(repo), "reset", "--mixed", entry["head"]])
        print(json.dumps({"ok": True}))
        return
    if action == "delete":
        plan = json.load(sys.stdin)
        for rel, paths in plan.items():
            repo = root / rel if rel != "." else root
            for name in paths:
                if excluded(name) or Path(name).is_absolute() or ".." in PurePosixPath(name).parts:
                    raise HandoffError(f"Unsafe deletion path: {rel}/{name}")
                candidate = repo / name
                if candidate.is_file() or candidate.is_symlink():
                    expected = paths[name]
                    if file_digest(candidate) != expected:
                        raise HandoffError(f"Destination file changed during handoff; refusing deletion: {rel}/{name}")
                    candidate.unlink()
        print(json.dumps({"ok": True}))
        return
    if action == "stop-sync":
        print(json.dumps({"stopped": stop_live_sync(root)}))
        return
    raise HandoffError(f"Unknown internal action: {action}")


def preflight(root: Path, role: str, rels):
    # Source is local for this process; destination is queried over SSH.
    source = [snapshot_repo(root, rel, fetch=True) for rel in rels]
    target_role = "host" if role == "client" else "client"
    peer = "macmini" if role == "client" else "macbook-air"
    ensure_peer_version(peer)
    target_paths = peer_call(peer, "list-paths")
    if set(target_paths) != set(rels):
        missing = sorted(set(rels) - set(target_paths))
        extra = sorted(set(target_paths) - set(rels))
        raise HandoffError(f"Workspace repository catalog differs (missing={missing}, extra={extra}).")
    target = remote_snapshots(target_role, rels)
    blockers = blockers_for(source, target)
    if blockers:
        raise HandoffError("Handoff blocked; reconcile these workspace differences first:\n- " + "\n- ".join(blockers[:30]))
    return source, target


def transfer(root: Path, role: str, source, target):
    peer = "macmini" if role == "client" else "macbook-air"
    target_role = "host" if role == "client" else "client"
    # Source HEADs must already be published. Destination reset is mixed and
    # only runs after every repository has passed the non-overwrite preflight.
    target_by_path = {repo["path"]: repo for repo in target}
    prepare_plan = {
        repo["path"]: {
            "head": repo["head"],
            "expected": {key: target_by_path[repo["path"]][key] for key in ("head", "branch", "originHead", "files")},
        }
        for repo in source
    }
    peer_call(peer, "prepare", prepare_plan)
    prepared = remote_snapshots(target_role, [r["path"] for r in source], fetch=False)
    source_by_path = {repo["path"]: repo for repo in source}
    for repo in prepared:
        prior = target_by_path[repo["path"]]
        desired = source_by_path[repo["path"]]
        if repo["head"] != desired["head"] or repo["branch"] != desired["branch"] or repo["files"] != prior["files"]:
            raise HandoffError(f"Destination changed during handoff preparation: {repo['path']}; no workspace files were copied.")
    for repo in source:
        paths = [p for p in repo["files"] if (root / repo["path"] / p).exists() or (root / repo["path"] / p).is_symlink()]
        if paths:
            listing = b"\0".join((repo["path"] + "/" + p).encode("utf-8", "surrogateescape") for p in paths) + b"\0"
            run(["rsync", "-a", "--from0", "--files-from=-", "-R", "./", f"{peer}:~/Projects/"],
                cwd=root, input_data=listing)
    # Remove destination-only tracked files after every repo has passed preflight.
    delete_plan = {}
    for repo in source:
        dst = target_by_path[repo["path"]]
        delete_plan[repo["path"]] = {
            path: dst["files"][path]
            for path in sorted(set(dst["files"]) - set(repo["files"]))
        }
    peer_call(peer, "delete", delete_plan)
    verified = remote_snapshots(target_role, [r["path"] for r in source], fetch=False)
    source_hashes = {r["path"]: r["files"] for r in source}
    source_heads = {r["path"]: r["head"] for r in source}
    if any(r["files"] != source_hashes.get(r["path"]) or r["head"] != source_heads.get(r["path"])
           for r in verified):
        raise HandoffError("Transfer verification failed; the baton remains with the current device.")
    # Editors are not locked by the baton. Re-read the source after transfer so
    # a save that races the rsync cannot silently move ownership with stale data.
    source_after = [snapshot_repo(root, repo["path"]) for repo in source]
    before = {r["path"]: (r["head"], r["branch"], r["files"]) for r in source}
    after = {r["path"]: (r["head"], r["branch"], r["files"]) for r in source_after}
    if before != after:
        raise HandoffError("Source changed during handoff; the baton remains with the current device. Retry after saving editor changes.")


def main_handoff(root: Path, role: str):
    lock = acquire_lock(role)
    source_owner = role
    target_owner = "host" if role == "client" else "client"
    started = False
    try:
        ensure_peer_version("macmini" if role == "client" else "macbook-air")
        state = get_state(role)
        if state["owner"] != role:
            raise HandoffError(f"Workspace baton belongs to {'Air' if state['owner']=='client' else 'Mac Mini'}.")
        state.update({"phase": "syncing", "target": target_owner, "updatedAt": now(), "blockers": []})
        set_state(state, role)
        started = True
        if role == "client":
            stop_result = {"stopped": stop_live_sync(root)}
        else:
            stop_result = peer_call("macbook-air", "stop-sync")
        state["pausedLiveSync"] = stop_result.get("stopped", [])
        set_state(state, role)
        paths = repo_paths(root)
        source, target = preflight(root, role, paths)
        transfer(root, role, source, target)
        state.update({"owner": target_owner, "phase": "ready", "target": None,
                      "updatedAt": now(), "blockers": [], "initialOwner": None})
        set_state(state, role)
        print(json.dumps(state, sort_keys=True))
    except Exception as error:
        if started:
            try:
                state = get_state(role)
                state.update({"owner": source_owner, "phase": "blocked", "target": target_owner,
                              "updatedAt": now(), "blockers": [str(error)]})
                set_state(state, role)
            except Exception:
                pass
        raise
    finally:
        release_lock(lock)


def status(role: str):
    state = get_state(role)
    state["localRole"] = role
    state["localOwnsWorkspace"] = state.get("owner") == role and state.get("phase") == "ready"
    print(json.dumps(state, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", choices=("client", "host"))
    parser.add_argument("--root", type=Path)
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--handoff", action="store_true")
    parser.add_argument("--internal")
    args = parser.parse_args()
    if args.internal:
        internal(args.internal)
        return
    if not args.role:
        raise HandoffError("--role is required")
    if args.status:
        status(args.role)
        return
    if args.handoff:
        main_handoff((args.root or (Path.home() / "Projects")).resolve(), args.role)
        return
    raise HandoffError("Choose --status or --handoff")


if __name__ == "__main__":
    try:
        main()
    except (HandoffError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"workspace-handoff: {error}", file=sys.stderr)
        sys.exit(1)
