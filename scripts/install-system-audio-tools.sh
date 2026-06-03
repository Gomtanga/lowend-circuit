#!/usr/bin/env sh
set -eu

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required. Install it from https://brew.sh first."
    exit 1
fi

if ! brew list --cask blackhole-2ch >/dev/null 2>&1; then
    echo "Installing BlackHole 2ch..."
    brew install --cask blackhole-2ch
else
    echo "BlackHole 2ch is already installed."
fi

if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    echo "Installing switchaudio-osx..."
    brew install switchaudio-osx
else
    echo "SwitchAudioSource is already installed."
fi

echo
echo "Done. If BlackHole was just installed, log out and back in if it does not appear in Sound settings."
