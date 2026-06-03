#!/usr/bin/env sh
set -eu

APP_PATH="$(cd "$(dirname "$0")/.." && pwd)/build/XBassInspired_artefacts/Release/Standalone/XBass Inspired.app"
VIRTUAL_DEVICE="${XBASS_VIRTUAL_DEVICE:-BlackHole 2ch}"
REAL_OUTPUT="${1:-}"

if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    echo "SwitchAudioSource is missing. Run scripts/install-system-audio-tools.sh first."
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Standalone app was not found:"
    echo "  $APP_PATH"
    echo "Build it first with ./build.sh"
    exit 1
fi

if ! SwitchAudioSource -a -t output | grep -Fx "$VIRTUAL_DEVICE" >/dev/null 2>&1; then
    echo "$VIRTUAL_DEVICE was not found."
    echo "Run scripts/install-system-audio-tools.sh, then log out and back in if needed."
    exit 1
fi

if [ -n "$REAL_OUTPUT" ]; then
    echo "$REAL_OUTPUT" > "$(cd "$(dirname "$0")/.." && pwd)/.xbass-last-output"
fi

echo "Setting macOS system output to $VIRTUAL_DEVICE..."
SwitchAudioSource -t output -s "$VIRTUAL_DEVICE"

echo "Opening XBass Inspired..."
open "$APP_PATH"

echo
echo "In the XBass Inspired audio settings, choose:"
echo "  Input:  $VIRTUAL_DEVICE"
if [ -n "$REAL_OUTPUT" ]; then
    echo "  Output: $REAL_OUTPUT"
else
    echo "  Output: your real headphones, speakers, DAC, or interface"
fi
echo
echo "To restore normal sound later, run:"
echo "  scripts/disable-system-wide-xbass.sh \"Your Real Output Device\""
