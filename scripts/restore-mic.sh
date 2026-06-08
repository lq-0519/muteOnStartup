#!/bin/zsh

set -euo pipefail

INPUT_VOLUME="${1:-80}"

osascript -e "set volume input volume $INPUT_VOLUME"
echo "Restored microphone input volume to $INPUT_VOLUME"
