#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT/SystemAudioProcessor"
BUILD_DIR="${LOWEND_BUILD_DIR:-$ROOT/build/SystemAudioProcessor}"
FINAL_APP_DIR="${LOWEND_APP_DIR:-$ROOT/build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd Native Audio.app}"
SCRATCH_DIR="${LOWEND_SWIFT_SCRATCH_DIR:-$BUILD_DIR/.build}"
SHADER_SOURCE="$PACKAGE_DIR/Shaders/SpectrumShaders.metal"
ICON_SOURCE="$PACKAGE_DIR/Assets/LowEndNativeAudioIcon.icns"

# Absolute overrides make isolated QA independent of the caller's directory.
for output_path in "$BUILD_DIR" "$FINAL_APP_DIR" "$SCRATCH_DIR"; do
    case "$output_path" in
        /*) ;;
        *) echo "Build/app/scratch paths must be absolute: $output_path" >&2; exit 1 ;;
    esac
done
case "$FINAL_APP_DIR" in
    */*.app) ;;
    *) echo "LOWEND_APP_DIR must name an .app bundle" >&2; exit 1 ;;
esac
APP_PARENT=$(dirname "$FINAL_APP_DIR")
mkdir -p "$BUILD_DIR" "$APP_PARENT"
STAGING_ROOT=$(mktemp -d "$APP_PARENT/.lowend-stage.XXXXXX")
APP_DIR="$STAGING_ROOT/LowEnd Native Audio.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
BACKUP_DIR=""
cleanup() {
    if [ -n "$BACKUP_DIR" ] && [ -e "$BACKUP_DIR" ] && [ ! -e "$FINAL_APP_DIR" ]; then
        mv "$BACKUP_DIR" "$FINAL_APP_DIR"
    fi
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A shallow clone's commit count is not globally monotonic. CI can supply its
# run number; the hash+dirty state is the authoritative source identity.
BUILD_NUMBER="${LOWEND_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)}"
case "$BUILD_NUMBER" in ''|*[!0-9]*) echo "LOWEND_BUILD_NUMBER must contain digits only" >&2; exit 1 ;; esac
GIT_COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
GIT_DIRTY=""
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    GIT_DIRTY="-dirty"
fi
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_ID="${GIT_COMMIT}${GIT_DIRTY} · ${BUILD_DATE}"

# Explicit overrides allow an installed compatible SDK without changing the
# system developer directory or silently downgrading the default SDK.
swift_build() {
    if [ -n "${LOWEND_SWIFT_SDK:-}" ]; then
        set -- --sdk "$LOWEND_SWIFT_SDK" "$@"
    fi
    if [ -n "${LOWEND_SWIFT_BUILD_SYSTEM:-}" ]; then
        set -- --build-system "$LOWEND_SWIFT_BUILD_SYSTEM" "$@"
    fi
    swift build --package-path "$PACKAGE_DIR" -c release --scratch-path "$SCRATCH_DIR" "$@"
}
swift_build --product SystemAudioProcessor
swift_build --product LowEndSupportChecks
BIN_DIR=$(swift_build --show-bin-path)
"$BIN_DIR/LowEndSupportChecks"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/SystemAudioProcessor" "$MACOS_DIR/LowEnd Native Audio"
cp "$SHADER_SOURCE" "$RESOURCES_DIR/SpectrumShaders.metal"
cp "$ICON_SOURCE" "$RESOURCES_DIR/LowEndNativeAudioIcon.icns"
RESOURCE_BUNDLE="SystemAudioProcessor_SystemAudioProcessor.bundle"
test -d "$BIN_DIR/$RESOURCE_BUNDLE"
# Signed .app bundles cannot have unsealed files beside Contents. The shader
# loader resolves this resource bundle explicitly before any SwiftPM fallback.
cp -R "$BIN_DIR/$RESOURCE_BUNDLE" "$RESOURCES_DIR/$RESOURCE_BUNDLE"
# Native SwiftPM emits a flat bundle; swiftbuild emits a macOS Contents bundle.
# Preserve either bundle layout and verify the resource that Bundle resolves.
RESOURCE_SHADER="$RESOURCES_DIR/$RESOURCE_BUNDLE/Contents/Resources/SpectrumShaders.metal"
if [ ! -f "$RESOURCE_SHADER" ]; then
    RESOURCE_SHADER="$RESOURCES_DIR/$RESOURCE_BUNDLE/SpectrumShaders.metal"
fi
if [ ! -f "$RESOURCE_SHADER" ]; then
    echo "Swift resource bundle is missing SpectrumShaders.metal" >&2
    exit 1
fi
cmp "$SHADER_SOURCE" "$RESOURCES_DIR/SpectrumShaders.metal"
cmp "$SHADER_SOURCE" "$RESOURCE_SHADER"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
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
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LCBuildCommit</key>
    <string>${GIT_COMMIT}${GIT_DIRTY}</string>
    <key>LCBuildDate</key>
    <string>${BUILD_DATE}</string>
    <key>LCBuildID</key>
    <string>${BUILD_ID}</string>
    <key>LCCaptureLeaseVersion</key>
    <integer>1</integer>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>LowEnd Native Audio captures system or selected app audio so it can apply bass enhancement and play the processed signal to your speakers or headphones.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LowEnd Native Audio sends Apple events to Music to detect playback state and source format.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# Test the exact signed Release executable that will be delivered. This runs
# deterministic offline checks only; benchmarks and RateMatchBench are opt-in.
"$MACOS_DIR/LowEnd Native Audio" --self-test
python3 "$ROOT/scripts/check-native-cli.py" "$MACOS_DIR/LowEnd Native Audio"

# Preserve the existing app until the replacement has passed every check.
# A failed move restores it through cleanup; no unvalidated build deletes it.
if [ -e "$FINAL_APP_DIR" ]; then
    BACKUP_DIR="$STAGING_ROOT/previous.app"
    mv "$FINAL_APP_DIR" "$BACKUP_DIR"
fi
mv "$APP_DIR" "$FINAL_APP_DIR"
if ! codesign --verify --deep --strict "$FINAL_APP_DIR"; then
    mv "$FINAL_APP_DIR" "$STAGING_ROOT/failed.app"
    exit 1
fi
if [ -n "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
    BACKUP_DIR=""
fi

printf 'Built and verified Release app:\n  %s\n' "$FINAL_APP_DIR"
printf 'Offline checks:\n  "%s/Contents/MacOS/LowEnd Native Audio" --self-test\n' "$FINAL_APP_DIR"
printf 'Optional CPU benchmark (does not change audio devices):\n  "%s/Contents/MacOS/LowEnd Native Audio" --benchmark-output-conditioning\n' "$FINAL_APP_DIR"
