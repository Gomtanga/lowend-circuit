#!/usr/bin/env sh
set -eu

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
./scripts/build-native-system-audio-app.sh

echo
echo "Build finished."
echo "Standalone app:"
echo "  build/LowEndCircuit_artefacts/Release/Standalone/LowEnd Circuit.app"
echo "Native system-audio app:"
echo "  build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd Native Audio.app"
echo
echo "Plugin formats:"
echo "  AU and VST3 are generated under build/LowEndCircuit_artefacts/Release/"
