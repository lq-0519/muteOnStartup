#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLED_BIN="$HOME/Library/Application Support/MuteOnStartup/MuteOnStartup.app/Contents/MacOS/mute-on-startup-agent"
LEGACY_INSTALLED_BIN="$HOME/Library/Application Support/MuteOnStartup/mute-on-startup-agent"

if [[ -x "$INSTALLED_BIN" ]]; then
  "$INSTALLED_BIN" --once
elif [[ -x "$LEGACY_INSTALLED_BIN" ]]; then
  "$LEGACY_INSTALLED_BIN" --once
else
  cd "$ROOT_DIR"
  swift run -c release mute-on-startup-agent --once
fi
