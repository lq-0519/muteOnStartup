#!/bin/zsh

set -euo pipefail

LABEL="local.mute-on-startup"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/MuteOnStartup"
APP_BUNDLE_PATH="$APP_SUPPORT_DIR/MuteOnStartup.app"
APP_CONTENTS_DIR="$APP_BUNDLE_PATH/Contents"
APP_MACOS_DIR="$APP_CONTENTS_DIR/MacOS"
APP_RESOURCES_DIR="$APP_CONTENTS_DIR/Resources"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/MuteOnStartup"
BIN_PATH="$APP_MACOS_DIR/mute-on-startup-agent"
INFO_PLIST_PATH="$APP_CONTENTS_DIR/Info.plist"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
ICON_SOURCE_PATH="$ROOT_DIR/assets/AppIcon.icns"
ICON_BUNDLE_PATH="$APP_RESOURCES_DIR/AppIcon.icns"

mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

cd "$ROOT_DIR"
swift build -c release

cp "$ROOT_DIR/.build/release/mute-on-startup-agent" "$BIN_PATH"
chmod 755 "$BIN_PATH"

if [[ -f "$ICON_SOURCE_PATH" ]]; then
  cp "$ICON_SOURCE_PATH" "$ICON_BUNDLE_PATH"
else
  echo "Warning: missing icon at $ICON_SOURCE_PATH" >&2
fi

cat > "$INFO_PLIST_PATH" <<APPPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>mute-on-startup-agent</string>
  <key>CFBundleIdentifier</key>
  <string>$LABEL</string>
  <key>CFBundleName</key>
  <string>启动静音</string>
  <key>CFBundleDisplayName</key>
  <string>启动静音</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
APPPLIST

if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || \
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
fi

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>Nice</key>
  <integer>10</integer>
  <key>LowPriorityIO</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/agent.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/agent.err.log</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST_PATH"
launchctl bootstrap "gui/$UID" "$PLIST_PATH"
launchctl enable "gui/$UID/$LABEL"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "Installed $LABEL"
echo "Logs: $LOG_DIR/agent.err.log"
