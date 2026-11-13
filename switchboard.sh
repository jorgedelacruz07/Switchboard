#!/usr/bin/env bash
# Build and manage the native Switchboard app. No services start during setup.
set -u
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
APP_ROOT="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
APP="$APP_ROOT/build/Switchboard.app"
SETTINGS="$APP_ROOT/.local/settings.json"

require_macos() {
  [[ "$(uname -s)" == Darwin ]] || { echo 'Switchboard requires macOS.' >&2; return 1; }
}

workspace_root() {
  python3 - "$SETTINGS" "$APP_ROOT/.." <<'PY'
import json, os, pathlib, sys
settings = pathlib.Path(sys.argv[1])
try:
    saved = json.loads(settings.read_text()) if settings.exists() else {}
    raw = os.environ.get('PROJECTS_WORKSPACE_ROOT') or saved.get('workspaceRoot') or sys.argv[2]
    root = pathlib.Path(raw).expanduser().resolve()
    if not (root / 'project-dev.sh').is_file():
        raise ValueError('No project-dev.sh found. Run: switchboard configure /path/to/workspace')
    print(root)
except (ValueError, OSError, TypeError) as error:
    print(error, file=sys.stderr)
    sys.exit(1)
PY
}

signing_identity() {
  python3 - "$SETTINGS" <<'PY'
import json, pathlib, sys
settings = pathlib.Path(sys.argv[1])
try:
    saved = json.loads(settings.read_text()) if settings.exists() else {}
    identity = saved.get('codeSigningIdentity', '-')
    if not isinstance(identity, str) or not identity.strip() or any(ord(char) < 32 for char in identity):
        raise ValueError('Invalid codeSigningIdentity in .local/settings.json')
    print(identity)
except (ValueError, OSError, TypeError) as error:
    print(error, file=sys.stderr)
    sys.exit(1)
PY
}

build_app() {
  require_macos || return 1
  local workspace identity
  workspace="$(workspace_root)" || return 1
  identity="$(signing_identity)" || return 1
  command -v xcrun >/dev/null || { echo 'Apple developer tools (xcrun swiftc) are required.' >&2; return 1; }
  mkdir -p "$APP_ROOT/build" || return 1
  local stage_dir stage
  stage_dir="$(mktemp -d "$APP_ROOT/build/.stage-XXXXXXXX")" || return 1
  stage="$stage_dir/Switchboard.app"
  mkdir -p "$stage/Contents/MacOS" || return 1
  xcrun swiftc -target "$(uname -m)-apple-macos13.0" -swift-version 5 -O -framework AppKit -framework ServiceManagement -lsqlite3 "$APP_ROOT"/Sources/*.swift "$APP_ROOT"/Features/ProviderStatus/*.swift -o "$stage/Contents/MacOS/Switchboard" || return 1
  python3 - "$APP_ROOT/Resources/Info.plist" "$stage/Contents/Info.plist" "$workspace" "$APP_ROOT" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
info['ProjectsWorkspaceRoot'] = sys.argv[3]
info['ProjectsAppRoot'] = sys.argv[4]
info['SwitchboardLoginAPIVersion'] = 2
with open(sys.argv[2], 'wb') as target:
    plistlib.dump(info, target)
PY
  [[ $? -eq 0 ]] || return 1
  # Compiler output may be linker-signed; sign only this new isolated stage.
  if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$stage" || return 1
  else
    security find-identity -v -p codesigning | rg -F -q "\"$identity\"" || {
      echo "Configured code-signing identity is unavailable: $identity" >&2
      return 1
    }
    codesign --force --sign "$identity" "$stage" || return 1
    local signed_identity
    signed_identity="$(codesign -dv --verbose=4 "$stage" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    [[ "$signed_identity" == "$identity" ]] || {
      echo "Staged bundle signer mismatch: expected '$identity', got '${signed_identity:-none}'" >&2
      return 1
    }
  fi
  python3 "$APP_ROOT/scripts/app-update.py" verify --stage "$stage" --stable "$APP" --app-root "$APP_ROOT" --workspace "$workspace" || return 1
  if [[ "${1:-}" == "--stage-only" ]]; then
    echo "Staged only (not installed, launched or registered): $stage"
    return 0
  fi
  python3 "$APP_ROOT/scripts/app-update.py" publish --stage "$stage" --stable "$APP" --app-root "$APP_ROOT" --workspace "$workspace"
}

login_command() {
  require_macos || return 1
  # Never build, register or launch GUI implicitly for a diagnostic. Old bundles
  # do not understand --login and could otherwise fall through to GUI startup.
  python3 - "$APP/Contents/Info.plist" <<'PYLOGIN'
import plistlib, sys
try:
    with open(sys.argv[1], 'rb') as source:
        info = plistlib.load(source)
    if info.get('SwitchboardLoginAPIVersion') != 2:
        raise ValueError('unsupported login diagnostic API')
except Exception:
    sys.exit('Reviewed login-capable bundle required; no build or GUI launch was attempted.')
PYLOGIN
  [[ $? -eq 0 ]] || return 1
  [[ -x "$APP/Contents/MacOS/Switchboard" ]] || return 1
  "$APP/Contents/MacOS/Switchboard" --login "$1"
}

case "${1:-open}" in
  configure)
    [[ $# -eq 2 ]] || { echo 'Usage: switchboard configure /path/to/workspace' >&2; exit 1; }
    python3 - "$SETTINGS" "$2" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[2]).expanduser().resolve()
if not (root / 'project-dev.sh').is_file():
    sys.exit('The workspace must contain project-dev.sh.')
settings = pathlib.Path(sys.argv[1])
settings.parent.mkdir(parents=True, exist_ok=True)
settings.write_text(json.dumps({'workspaceRoot': str(root)}, indent=2) + '\n')
print('Workspace configured. Run switchboard install to rebuild and apply it.')
PY
    ;;
  build)
    [[ $# -eq 1 || ( $# -eq 2 && "$2" == "--stage-only" ) ]] || { echo 'Usage: switchboard build [--stage-only]' >&2; exit 1; }
    build_app "${2:-}" ;;
  workspace) workspace_root ;;
  install|setup) exec /bin/bash "$APP_ROOT/install.sh" ;;
  open)
    require_macos || exit 1
    [[ -x "$APP/Contents/MacOS/Switchboard" ]] || build_app || exit 1
    open "$APP" ;;
  login)
    [[ $# -le 2 ]] || { echo 'Usage: switchboard login status|diagnostic|migration-plan|register|unregister' >&2; exit 1; }
    case "${2:-status}" in
      on|register) login_command register ;;
      off|unregister) login_command unregister ;;
      status|diagnostic|migration-plan) login_command "${2:-status}" ;;
      *) echo 'Usage: switchboard login status|diagnostic|migration-plan|register|unregister' >&2; exit 1 ;;
    esac ;;
  test)
    require_macos || exit 1
    python3 -m unittest discover -s "$APP_ROOT/Tests" || exit 1
    mkdir -p "$APP_ROOT/build" || exit 1
    # A separate test binary leaves the installed/running app untouched and needs
    # no configured workspace, provider authentication, or project checkout.
    xcrun swiftc -target "$(uname -m)-apple-macos13.0" -swift-version 5 -O -framework AppKit -framework ServiceManagement -lsqlite3 "$APP_ROOT"/Sources/*.swift "$APP_ROOT"/Features/ProviderStatus/*.swift -o "$APP_ROOT/build/SwitchboardTests" || exit 1
    "$APP_ROOT/build/SwitchboardTests" --self-test ;;
  usage|usage-live)
    [[ -x "$APP/Contents/MacOS/Switchboard" ]] || build_app || exit 1
    if [[ "$1" == usage-live ]]; then
      "$APP/Contents/MacOS/Switchboard" --ai-snapshot --live-codex
    else
      "$APP/Contents/MacOS/Switchboard" --ai-snapshot
    fi ;;
  connect-claude) python3 "$APP_ROOT/scripts/claude-bridge.py" ;;
  role)
    case "${2:-status}" in
      client|host|auto)
        python3 - "$SETTINGS" "$2" <<'PY'
import json, pathlib, sys
settings_file = pathlib.Path(sys.argv[1])
data = json.loads(settings_file.read_text()) if settings_file.exists() else {}
data['role'] = sys.argv[2]
settings_file.parent.mkdir(parents=True, exist_ok=True)
settings_file.write_text(json.dumps(data, indent=2) + '\n')
print(f"Switchboard role set to '{sys.argv[2]}'.")
PY
        ;;
      status)
        python3 - "$SETTINGS" <<'PY'
import json, pathlib, sys
settings_file = pathlib.Path(sys.argv[1])
data = json.loads(settings_file.read_text()) if settings_file.exists() else {}
print(data.get('role', 'auto'))
PY
        ;;
      *) echo 'Usage: switchboard role client|host|auto|status' >&2; exit 1 ;;
    esac ;;
  snapshot)
    [[ -x "$APP/Contents/MacOS/Switchboard" ]] || build_app || exit 1
    shift
    "$APP/Contents/MacOS/Switchboard" --snapshot "$@" ;;
  help|--help|-h)
    cat <<'EOF'
Switchboard — a native macOS menu bar controller for development projects and AI service status
  configure PATH   Save the workspace containing project-dev.sh
  workspace        Show the workspace selected for the next build
  install          Build, install and open (login registration is separate)
  open             Open the menu without starting or stopping projects
  build [--stage-only]  Verify staged app; ordinary replacement requires stopped/unregistered stable app
  login register|unregister  Explicit SMAppService action (on/off aliases)
  login status|diagnostic    Read modern status and legacy authorization
  login migration-plan       Read-only reversible legacy migration plan
  role client|host Set or check machine role (client: MacBook Air, host: Mac Mini)
  usage            Read AI usage as JSON without generating model requests
  usage-live       Also read Codex account directly using a temporary helper
  connect-claude   Connect quota capture without replacing an existing status line
  snapshot         Print current project status as JSON (read-only)
  test             Run isolated tests without changing real services
  help             Show this help

Workspace selection: PROJECTS_WORKSPACE_ROOT, saved configure setting, parent folder.
EOF
    ;;
  *) echo 'Unknown command. Run switchboard help.' >&2; exit 1 ;;
esac
