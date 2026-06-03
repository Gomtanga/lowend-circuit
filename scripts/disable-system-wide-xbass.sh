#!/usr/bin/env sh
set -eu

REAL_OUTPUT="${1:-}"
LAST_OUTPUT_FILE="$(cd "$(dirname "$0")/.." && pwd)/.xbass-last-output"

if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    echo "SwitchAudioSource is missing."
    exit 1
fi

if [ -z "$REAL_OUTPUT" ] && [ -f "$LAST_OUTPUT_FILE" ]; then
    REAL_OUTPUT="$(cat "$LAST_OUTPUT_FILE")"
fi

if [ -z "$REAL_OUTPUT" ]; then
    echo "Usage: scripts/disable-system-wide-xbass.sh \"Output Device Name\""
    echo
    echo "Available output devices:"
    SwitchAudioSource -a -t output
    exit 1
fi

echo "Restoring macOS system output to $REAL_OUTPUT..."
SwitchAudioSource -t output -s "$REAL_OUTPUT"

osascript -e 'tell application "XBass Inspired" to quit' >/dev/null 2>&1 || true
echo "Done."
