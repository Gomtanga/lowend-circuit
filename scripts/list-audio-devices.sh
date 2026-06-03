#!/usr/bin/env sh
set -eu

if command -v SwitchAudioSource >/dev/null 2>&1; then
    echo "Output devices:"
    SwitchAudioSource -a -t output
    echo
    echo "Input devices:"
    SwitchAudioSource -a -t input
else
    echo "SwitchAudioSource is missing. Run scripts/install-system-audio-tools.sh first."
fi
