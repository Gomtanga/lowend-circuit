#!/usr/bin/env sh
set -eu

APP="$(cd "$(dirname "$0")/.." && pwd)/build/XBassInspired_artefacts/Release/NativeSystemAudio/XBass Native System Audio.app/Contents/MacOS/XBass Native System Audio"

if [ ! -x "$APP" ]; then
    echo "Native system-audio app was not found. Build it first:"
    echo "  ./scripts/build-native-system-audio-app.sh"
    exit 1
fi

exec "$APP" --list-apps
