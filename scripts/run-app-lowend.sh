#!/usr/bin/env sh
set -eu

APP="$(cd "$(dirname "$0")/.." && pwd)/build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd Native Audio.app/Contents/MacOS/LowEnd Native Audio"
BUNDLE_ID="${1:-}"

if [ ! -x "$APP" ]; then
    echo "Native system-audio app was not found. Build it first:"
    echo "  ./scripts/build-native-system-audio-app.sh"
    exit 1
fi

if [ -z "$BUNDLE_ID" ]; then
    echo "Usage: scripts/run-app-lowend.sh com.example.AppBundleID"
    echo
    echo "Running apps:"
    "$APP" --list-apps
    exit 1
fi

shift
exec "$APP" --bundle-id "$BUNDLE_ID" "$@"
