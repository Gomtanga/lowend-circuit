#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT/SystemAudioProcessor"
BUILD_DIR="$ROOT/build/SystemAudioProcessor"
APP_DIR="$ROOT/build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd Native Audio.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SHADER_SOURCE="$PACKAGE_DIR/Shaders/SpectrumShaders.metal"
ICON_SOURCE="$PACKAGE_DIR/Assets/LowEndNativeAudioIcon.icns"

swift build \
    --package-path "$PACKAGE_DIR" \
    -c release \
    --scratch-path "$BUILD_DIR/.build"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/.build/release/SystemAudioProcessor" "$MACOS_DIR/LowEnd Native Audio"
cp "$SHADER_SOURCE" "$RESOURCES_DIR/SpectrumShaders.metal"
cp "$ICON_SOURCE" "$RESOURCES_DIR/LowEndNativeAudioIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>LowEnd Native Audio</string>
    <key>CFBundleIdentifier</key>
    <string>com.codexaudiolab.lowendcircuit.systemaudio</string>
    <key>CFBundleName</key>
    <string>LowEnd Native Audio</string>
    <key>CFBundleIconFile</key>
    <string>LowEndNativeAudioIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.2</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>LowEnd Native Audio captures system or selected app audio so it can apply bass enhancement and play the processed signal to your speakers or headphones.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"

echo "Built:"
echo "  $APP_DIR"
echo
echo "Run all system audio:"
echo "  \"$MACOS_DIR/LowEnd Native Audio\" --all"
echo
echo "List running app bundle IDs:"
echo "  \"$MACOS_DIR/LowEnd Native Audio\" --list-apps"
echo
echo "Run one app:"
echo "  \"$MACOS_DIR/LowEnd Native Audio\" --bundle-id com.spotify.client"
