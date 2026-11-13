#!/usr/bin/env bash
# Home-directory integrations are symlinks to this repository.
set -u
APP_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$APP_ROOT/build/Switchboard.app"
APP_LINK="$HOME/Applications/Switchboard.app"
CLI_LINK="$HOME/.local/bin/switchboard"
# Hidden compatibility alias for scripts written before the Switchboard rename.
LEGACY_CLI_LINK="$HOME/.local/bin/project-menu"
MINI_CLI_LINK="$HOME/.local/bin/mini-bar"
LEGACY_APP_LINK="$HOME/Applications/Mini Bar.app"
OLDER_APP_LINK="$HOME/Applications/Projects Menu.app"

for target in "$APP_LINK" "$CLI_LINK" "$LEGACY_CLI_LINK" "$MINI_CLI_LINK" "$LEGACY_APP_LINK" "$OLDER_APP_LINK"; do
  if [[ -e "$target" && ! -L "$target" ]]; then
    echo "Refusing to replace an existing regular file: $target" >&2
    exit 1
  fi
done

# Retire only the compatibility app links that this installer created for the
# exact stable bundle. Never remove a user app or an unrelated symlink target.
for legacy_link in "$LEGACY_APP_LINK" "$OLDER_APP_LINK"; do
  if [[ -L "$legacy_link" ]]; then
    legacy_target="$(readlink "$legacy_link")" || exit 1
    if [[ "$legacy_target" == "$APP" ]]; then
      rm "$legacy_link" || exit 1
      echo "Removed duplicate compatibility app link: $legacy_link"
    else
      echo "Preserving unrelated app link: $legacy_link -> $legacy_target" >&2
    fi
  fi
done

# A live legacy registration must be migrated under a separate reviewed rollout.
LEGACY_AGENT="$HOME/Library/LaunchAgents/com.jorgedelacruz.projects-menu.plist"
if [[ -e "$LEGACY_AGENT" || -L "$LEGACY_AGENT" ]]; then
  echo 'Legacy login plist present. Preserve it and follow the reviewed migration plan before installing.' >&2
  exit 1
fi
/bin/bash "$APP_ROOT/switchboard.sh" build || exit 1
mkdir -p "$HOME/Applications" "$HOME/.local/bin" || exit 1
ln -sfn "$APP" "$APP_LINK" || exit 1
ln -sfn "$APP_ROOT/switchboard.sh" "$CLI_LINK" || exit 1
ln -sfn "$APP_ROOT/switchboard.sh" "$LEGACY_CLI_LINK" || exit 1
ln -sfn "$APP_ROOT/switchboard.sh" "$MINI_CLI_LINK" || exit 1
/bin/bash "$APP_ROOT/switchboard.sh" connect-claude || exit 1
open "$APP" || exit 1
echo 'Installed Switchboard. Login registration is unchanged; inspect switchboard login status before an explicit register action.'
