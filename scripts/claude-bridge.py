"""Install a quota-only status line without replacing an existing customization."""
import argparse
import json
from pathlib import Path
import shlex
import tempfile


def install(settings: Path, app_root: Path) -> bool:
    original = settings.read_text() if settings.exists() else None
    data = json.loads(original) if original is not None else {}
    if not isinstance(data, dict):
        raise ValueError("Claude settings must be a JSON object.")
    command = shlex.quote(str(app_root / "scripts/claude-statusline.sh"))
    current = data.get("statusLine")
    desired = {"type": "command", "command": command}
    if current and current != desired:
        print("Existing Claude status line preserved. Quota capture is not connected.")
        return False
    if current == desired:
        print("Claude quota capture is already connected.")
        return True
    data["statusLine"] = desired
    settings.parent.mkdir(parents=True, exist_ok=True)
    # Existing settings stay intact; no credentials or transcripts are copied.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=settings.parent, prefix=".mini-bar-", delete=False) as target:
            temporary = Path(target.name)
            json.dump(data, target, indent=2)
            target.write("\n")
        if (settings.read_text() if settings.exists() else None) != original:
            raise OSError("Settings changed during installation.")
        temporary.replace(settings)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print("Claude quota capture connected. Use Claude Code to publish the first reading.")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Connect Claude Code quota capture to Switchboard.")
    parser.add_argument("--settings", type=Path, default=Path.home() / ".claude/settings.json")
    parser.add_argument("--app-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        install(args.settings, args.app_root)
    except (ValueError, OSError):
        raise SystemExit("Could not connect Claude quota capture; existing settings were preserved.")
