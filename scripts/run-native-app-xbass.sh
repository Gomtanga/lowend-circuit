#!/usr/bin/env sh
set -eu

APP="$(cd "$(dirname "$0")/.." && pwd)/build/XBassInspired_artefacts/Release/NativeSystemAudio/XBass Native System Audio.app/Contents/MacOS/XBass Native System Audio"
BUNDLE_ID="${1:-}"

if [ ! -x "$APP" ]; then
    echo "Native system-audio app was not found. Build it first:"
    echo "  ./scripts/build-native-system-audio-app.sh"
    exit 1
fi

if [ -z "$BUNDLE_ID" ]; then
    echo "Usage: scripts/run-native-app-xbass.sh com.example.AppBundleID"
    echo
    echo "Running apps:"
    "$APP" --list-apps
    exit 1
fi

shift
exec "$APP" --bundle-id "$BUNDLE_ID" "$@"
