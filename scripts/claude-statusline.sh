#!/usr/bin/env bash
# Capture only Claude Code quota fields. This helper exits after every status update.
set -u
APP_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXECUTABLE="$APP_ROOT/build/Switchboard.app/Contents/MacOS/Switchboard"
[[ -x "$EXECUTABLE" ]] || exit 0
exec "$EXECUTABLE" --capture-claude-usage "$APP_ROOT/.local/claude-usage.json"
