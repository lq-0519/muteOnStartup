#!/bin/zsh

set -euo pipefail

LABEL="local.mute-on-startup"
APP_SUPPORT_DIR="$HOME/Library/Application Support/MuteOnStartup"
APP_BUNDLE_PATH="$APP_SUPPORT_DIR/MuteOnStartup.app"
LEGACY_BIN_PATH="$APP_SUPPORT_DIR/mute-on-startup-agent"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || \
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
fi

rm -f "$PLIST_PATH"
rm -f "$LEGACY_BIN_PATH"
rm -rf "$APP_BUNDLE_PATH"
rmdir "$APP_SUPPORT_DIR" >/dev/null 2>&1 || true

echo "Uninstalled $LABEL"
