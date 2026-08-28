# LowEnd Circuit — Audio DSP for Bass Enhancement and Spatial Processing

[한국어](README.md) | **English**

[![Latest release](https://img.shields.io/github/v/release/Gomtanga/lowend-circuit?display_name=tag&sort=semver)](https://github.com/Gomtanga/lowend-circuit/releases/latest)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
[![Cross-Platform Core CI](https://github.com/Gomtanga/lowend-circuit/actions/workflows/cross-platform-core-ci.yml/badge.svg)](https://github.com/Gomtanga/lowend-circuit/actions/workflows/cross-platform-core-ci.yml)
[![macOS Native and Core CI](https://github.com/Gomtanga/lowend-circuit/actions/workflows/macos-native-ci.yml/badge.svg)](https://github.com/Gomtanga/lowend-circuit/actions/workflows/macos-native-ci.yml)

<p align="center">
  <img src="SystemAudioProcessor/Assets/LowEndNativeAudioIcon.png" width="180" alt="LowEnd Native Audio app icon">
</p>

LowEnd Circuit is an open-source audio DSP project for bass enhancement, high-frequency harmonic generation, headphone spatial processing, and real-time signal analysis. The repository includes a macOS system-audio application and a portable C++ DSP core (`Source/Core/`).

This is an original DSP design. It is not affiliated with or endorsed by any hardware or software manufacturer, and it does not claim to reproduce a third party's proprietary circuit.

The current macOS interface uses Korean control labels. This guide includes their English meanings where you need to find a specific control.

## Which build should I use?

`LowEnd Circuit` is the name of the overall project. Choose the program that matches how you plan to use it.

| What you want to do | Choose | Availability | Important detail |
|---|---|---|---|
| Process all Mac audio or one application | **LowEnd Native Audio** | Prebuilt macOS app | macOS 14.4 or newer; Apple Silicon only |

The project is organized as follows:

```text
LowEnd Circuit
└─ LowEnd Native Audio
   └─ System-wide or per-application processing on macOS
```

## Download

The latest release is [v0.2.10](https://github.com/Gomtanga/lowend-circuit/releases/tag/v0.2.10). See the release notes for changes and verification results.

### Prebuilt files

| Platform | File | Purpose |
|---|---|---|
| macOS 14.4 or newer, Apple Silicon | [`LowEnd-Native-Audio-macOS-v0.2.10.zip`](https://github.com/Gomtanga/lowend-circuit/releases/download/v0.2.10/LowEnd-Native-Audio-macOS-v0.2.10.zip) | System-wide or per-application processing |

Previous versions are available from [GitHub Releases](https://github.com/Gomtanga/lowend-circuit/releases).

### Distribution scope and cautions

- The downloadable macOS build is `arm64` only. There is no Intel Mac binary.
- The macOS app is signed ad hoc and is not notarized by Apple.
- Public binaries now cover only the macOS build of LowEnd Native Audio. The former Windows/JUCE distribution targets and historical Windows release assets were retired in August 2026.

## Start in one minute

### macOS: process all system audio

1. Extract the macOS ZIP file.
2. Move `LowEnd Native Audio.app` to Applications.
3. If the first launch is blocked, right-click the app in Finder and choose **Open**.
4. Allow system-audio recording when macOS asks.
5. Select `Circuit`, `HighExciter`, or `Clean`.
6. Start with `IEM` or `Gentle` for Circuit, or `Soft` or `Air` for HighExciter.
7. Press **전체 시스템 적용 (Apply System-wide)**.

Press **중지 (Stop)** before changing the output device. If audio becomes silent while processing, stop and apply the mode again.

### macOS: process one application

1. Start playback in the target application.
2. Enter its main bundle ID in LowEnd Native Audio.
3. Press **특정 앱 적용 (Apply to App)**.

The running-app list near the bottom of the window helps identify bundle IDs. Entering a main ID such as `com.tidal.desktop` also lets the app find an active child audio process. If no matching Core Audio process exists, start playback and apply the target again.

## Core features

| Feature | What it does | Available in |
|---|---|---|
| **Clean** | Bypasses model DSP and spatial processing for comparison with the unprocessed dry signal. | LowEnd Native Audio |
| **Circuit** | Combines `LowEnd`, `Body`, a parallel wet path, asymmetric saturation, and output protection to shape bass weight and texture. | LowEnd Native Audio |
| **HighExciter** | Generates harmonics from content above roughly 11 kHz and adapts nonlinear-stage oversampling to the sample rate. | LowEnd Native Audio |
| **Spatial Stage** | Uses virtual-speaker width, listener position, distance gain, interaural timing, and crossfeed to shape headphone space. | LowEnd Native Audio |
| **Analysis** | Displays a 16,384-point FFT, 128 spectrum bars, Peak, RMS, and Crest Factor. | LowEnd Native Audio |
| **Source and Rate Match** | Conservatively derives source-format information from player metadata or logs and previews a matching DAC rate. | LowEnd Native Audio |

Spatial Stage is a geometry-based stereo processor. It is not room reverb or an individualized HRTF renderer.

### Presets

Presets are starting points. Circuit presets are not loudness-matched, so you may hear both tonal and playback-level differences when comparing them.

<details>
<summary>Show Circuit and HighExciter preset values</summary>

#### Circuit

| Preset | LowEnd | Body | Output |
|---|---:|---:|---:|
| IEM | 30% | 8% | -2.0 dB |
| Gentle | 22% | 8% | -1.0 dB |
| LowEnd | 42% | 18% | -1.8 dB |
| Deep | 54% | 22% | -2.8 dB |
| Clear | 0% | 0% | 0.0 dB |

Stronger bass settings use lower output values to preserve headroom and reduce the risk of clipping.

#### HighExciter

| Preset | Exciter Drive | Wet Mix |
|---|---:|---:|
| Soft | 0.12 | 0.04 |
| Air | 0.22 | 0.07 |
| Detail | 0.35 | 0.11 |
| Shimmer | 0.50 | 0.16 |
| Off | 0.00 | 0.00 |

HighExciter presets change only `Exciter Drive` and `Wet Mix`. They do not change Circuit `Output` or Spatial Stage settings.

</details>

## Audio formats and Rate Match

LowEnd Native Audio keeps several format values separate:

- `Tap`: the format delivered by Core Audio Process Tap
- `Engine`: the DSP engine's processing format
- `DAC`: the output device's nominal sample rate
- `Source`: playback-source information obtained independently from Apple Music or TIDAL

`Source` is labeled `Detected` or `Inferred` according to the available evidence. A value that cannot be established remains `unknown`; the app never substitutes the Tap or DAC rate and presents it as the source-file format.

For TIDAL, the app watches `player.log` for filesystem changes and rechecks the source format after an approximately 80 ms debounce. It rearms the watcher when the log is replaced or rotated and retains periodic polling as a recovery path. `CoreaudioSink::start` and `CoreaudioSink::close` are also treated as playback-state evidence, covering track changes where TIDAL delays or omits `media.state=active`.

`Rate Match Preview` is read-only. It compares a detected source rate with rates reported by the DAC and shows a candidate without changing the device.

`자동 Rate Match (Automatic Rate Match)` is an experimental Expert Mode option and is off by default. After stable source observations, it fades out, stops the engine, changes the DAC and Engine rates, rebuilds capture and output, verifies flow, and fades back in. Hardware relocking can cause roughly one to two seconds of silence on every track change.

For gapless playback, leave Automatic Rate Match off and keep the DAC at a fixed value such as 96 kHz or 192 kHz. See [Rate Matching](docs/rate-matching.md) and the [Source Rate Tracking and Device Lock Plan](docs/source-rate-and-device-lock-plan.md) for transition and recovery details.

## Limitations to read first

- DSP intentionally changes the signal, so the output is not bit-perfect in the strict sense.
- Exclusive output such as TIDAL **Use Exclusive Mode** can bypass or starve Core Audio Process Tap. Disable exclusive mode during system-wide or per-application processing.
- TIDAL provides no public source-format API. `Source` may remain `unknown` when the installed player emits no recognized message.
- The Apple Music metadata fallback may request macOS Automation permission.
- The target application's Core Audio output process must be active when per-application capture starts.
- The macOS app is not Developer ID signed or notarized by Apple.
- Spatial Stage is not an individualized HRTF.

## System requirements

| Target | Minimum | Recommended or additional condition |
|---|---|---|
| LowEnd Native Audio | macOS 14.4 or newer, Apple Silicon M1 or newer, 8 GB memory, Metal-capable GPU, roughly 100 MB free space | Apple M2 or newer and 16 GB memory for combined 96/192 kHz processing and Analysis |

These requirements do not guarantee identical performance across every device, sample rate, and buffer size.

## Detailed documentation

| Document | Subject |
|---|---|
| [System-Wide and Per-App Use](docs/system-wide-and-per-app.md) | macOS system-wide and per-application processing |
| [Rate Matching](docs/rate-matching.md) | Automatic sample-rate transitions and recovery |
| [HighExciter Oversampling](docs/high-exciter-oversampling.md) | Factor policy, filters, and real-time constraints |
| [Source Format Validation](docs/source-format-validation-2026-06-11.md) | Apple Music and TIDAL source-detection evidence |
| [Source Rate Tracking and Device Lock Plan](docs/source-rate-and-device-lock-plan.md) | Source, automatic transition, and Device Lock design |
| [Cross-Platform Core Architecture](docs/cross-platform-core-architecture.md) | Swift and C++ DSP-core integration design and migration plan |
| [GitHub Releases](https://github.com/Gomtanga/lowend-circuit/releases) | Version changes, downloadable files, and verification results |

Design documents and dated validation records describe the state at the time they were written. Check the latest code and release notes when you need the current behavior.

## Build from source

### LowEnd Native Audio

You need macOS 14.4 or newer and a current Xcode command-line or Swift toolchain.

```sh
git clone https://github.com/Gomtanga/lowend-circuit.git
cd lowend-circuit
./scripts/build-native-system-audio-app.sh
open "build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd Native Audio.app"
```

The following helpers can start system-wide or per-application modes from the command line:

```sh
./scripts/run-system-wide-lowend.sh
./scripts/list-audio-apps.sh
./scripts/run-app-lowend.sh com.spotify.client
```

## Verification

The repository CI checks the portable C++ Core, Swift support cases, Swift and C++ DSP parity, and the LowEnd Native Audio build separately. Run the commands that match your change.

```sh
cmake -S Source/Core -B build/core-tests -DLOWEND_CORE_BUILD_TESTING=ON
cmake --build build/core-tests --parallel
ctest --test-dir build/core-tests --output-on-failure
```

On macOS, you can also run:

```sh
swift run --package-path SystemAudioProcessor LowEndSupportChecks
swift run --package-path SystemAudioProcessor SystemAudioProcessor --self-test
```

The real-time audio callback is designed to avoid memory allocation, locks, logging and file I/O, UI access, and filter-coefficient calculation. See the source and [Cross-Platform Core Architecture](docs/cross-platform-core-architecture.md) for details.

## Reporting issues and contributing

Report bugs and feature requests in [GitHub Issues](https://github.com/Gomtanga/lowend-circuit/issues). Audio problems depend heavily on the environment, so include as much of the following as you reasonably can:

- operating system and version
- CPU and application version
- input and output devices, including the DAC model
- sample rate and buffer settings
- selected model and preset
- system-wide or per-application use
- exclusive-mode and Automatic Rate Match state
- reproduction steps and expected result
- relevant logs or screenshots

Before attaching logs, remove account information, user names, private paths, listening history, and anything else that does not need to be public.

When proposing a change, state the affected platform, the checks you ran, and anything you did not verify. Pull requests run the repository's macOS and cross-platform CI workflows.

## Repository layout

```text
Source/Core/                    Testable portable Circuit and HighExciter DSP
SystemAudioProcessor/           Native macOS Swift and C engine
SystemAudioProcessor/Shaders/   Metal spectrum shader
SystemAudioProcessor/Assets/    Native app icon
scripts/                        Build and launch helpers
docs/                           Usage, design, and validation records
```

## License and third-party terms

This repository is distributed under [GNU AGPL-3.0-or-later](LICENSE).

Third-party names and trademarks belong to their respective owners. The project does not use another company's product name as its brand or claim an exact emulation of a proprietary circuit.
