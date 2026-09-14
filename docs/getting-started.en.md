# Getting started

[← Home](../README.en.md) · [한국어](getting-started.md)

The app is **LowEnd Native Audio**. The project is **LowEnd Circuit**. The downloadable app supports **macOS 14.4 or newer on Apple Silicon**. Intel Mac binaries are not provided.

On Windows the project builds a **CLI from source** (no downloadable binary yet). There is no GUI, and system-wide processing is not transparent the way it is on macOS. See the [Windows guide](windows.md).

Download [v0.3.0 for macOS](https://github.com/Gomtanga/lowend-circuit/releases/download/v0.3.0/LowEnd-Native-Audio-macOS-v0.3.0.zip). Read the [release notes](https://github.com/Gomtanga/lowend-circuit/releases/tag/v0.3.0) for changes and verification scope. The app is **ad-hoc signed and not notarized by Apple**. See [Apple’s app-opening guidance](https://support.apple.com/en-us/102445) if the first launch is blocked.

The current interface uses Korean labels. English translations below help you locate the controls.

## macOS: process all system audio

1. Extract the macOS ZIP file.
2. Move `LowEnd Native Audio.app` to Applications.
3. If macOS blocks the first launch, open **System Settings → Privacy & Security** and use **Open Anyway** for this app after checking its source.
4. Allow system-audio recording when macOS asks.
5. Select `Circuit`, `HighExciter`, or `Clean`.
6. Start with `IEM` or `Gentle` for Circuit, or `Soft` or `Air` for HighExciter.
7. Press the **speaker button at the bottom left (전체 시스템 적용 / Apply System-wide)**.

Press **중지 (Stop)** before changing the output device. If audio becomes silent while processing, stop and apply the mode again.

## macOS: process one application

1. Start playback in the target application.
2. Enter its main bundle ID on the **오디오 적용 (Audio Apply)** page.
3. Press **특정 앱 적용 (Apply to App)**.

Use **오디오 적용 → 실행 중인 앱 새로고침 (Audio Apply → Refresh Running Apps)** to identify bundle IDs. Entering a main ID such as `com.tidal.desktop` also lets the app find an active child audio process. If no matching Core Audio process exists, start playback and apply the target again.

## If you cannot hear audio

1. Keep only one copy of LowEnd Native Audio running. Quit older builds before launching another copy.
2. Check the system-audio recording permission in macOS and the selected output device.
3. Turn off exclusive output in the player, including TIDAL **Use Exclusive Mode**.
4. For per-application processing, start playback before applying the target again.
5. Press **중지 (Stop)** and apply the mode again. Stop before switching output devices.

An external DAC is optional. PCM 2× requires an output device that supports the requested rate; check the **active** conditioning status, not only the selected setting.

For tone comparisons, start at a moderate listening level. **Clean** bypasses the tonal model only; turn off Spatial and Output Conditioning as well for a dry comparison.

## Hardware guidance

The figures below are usage guidance, not measured performance guarantees for every device and setting.

| Target | Minimum | Recommended or additional condition |
|---|---|---|
| LowEnd Native Audio | macOS 14.4 or newer, Apple Silicon M1 or newer, 8 GB memory, Metal-capable GPU, roughly 100 MB free space | Apple M2 or newer and 16 GB memory for combined 96/192 kHz processing and Analysis |

[Audio guide](audio-guide.en.md) · [Detailed capture behavior](system-wide-and-per-app.md) · [Report a problem](../CONTRIBUTING.md)
