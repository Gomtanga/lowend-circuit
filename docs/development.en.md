# Development

[← Home](../README.en.md) · [한국어](development.md)

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

The repository CI checks the portable C++ Core, Swift support cases, Swift and C++ DSP parity, the LowEnd Native Audio build, and the Windows CLI separately. Run the commands that match your change.

```sh
cmake -S Source/Core -B build/core-tests -DCMAKE_BUILD_TYPE=Release -DLOWEND_CORE_BUILD_TESTING=ON
cmake --build build/core-tests --parallel
ctest --test-dir build/core-tests --output-on-failure
```

On macOS, you can also run:

```sh
swift run --package-path SystemAudioProcessor -c release LowEndSupportChecks
swift run --package-path SystemAudioProcessor -c release SystemAudioProcessor --self-test
```

On Windows, run the build script, which configures CMake, builds, runs `ctest`, and then runs the CLI argument regressions. See the [Windows guide](windows.md) for details.

```bat
scripts\build-windows-cli.bat Release
```

`--self-test` runs fast offline regressions. Run CPU throughput measurements separately with `--benchmark-output-conditioning`. `RateMatchBench` defaults to read-only `--dry-run`; physical rate changes require `--execute --device ID` and can interrupt other audio. This manual tool is never part of routine builds or CI.

The bundle script builds Release, runs support checks, assembles and signs a staged app, checks its SwiftPM shader bundle, and runs that exact executable's offline self-test and CLI argument regressions before replacing an existing app. The CLI checks verify invalid-argument rejection and help output. Isolate QA output with absolute overrides:

```sh
LOWEND_BUILD_DIR=/tmp/lowend-build-qa \
LOWEND_APP_DIR="/tmp/lowend-app-qa/LowEnd Native Audio.app" \
./scripts/build-native-system-audio-app.sh
```

`LOWEND_SWIFT_SCRATCH_DIR` and a numeric `LOWEND_BUILD_NUMBER` are optional. A shallow clone's commit count is not a globally monotonic build identity. Offline checks do not verify Process Tap permission, physical DAC transitions, listening quality, or VoiceOver interaction.

To validate a specific toolchain configuration, set `LOWEND_SWIFT_SDK` to an installed macOS SDK path and `LOWEND_SWIFT_BUILD_SYSTEM` to a build system supported by that Swift installation. Both product builds and the binary-path query receive the same options. Omit them to use Swift's defaults; these options do not change the system developer directory.

The real-time audio callback is designed to avoid memory allocation, locks, logging and file I/O, UI access, and filter-coefficient calculation. See the source and [Cross-Platform Core Architecture](cross-platform-core-architecture.md) for details.

## Current source implementation and experimental scope

The Native live callback uses the Swift Circuit/HighExciter implementations in `TonalDSP.swift` and Spatial processing in `SpatialDSP.swift`. C++ `Source/Core` provides portable kernels and the parity comparison path. Spatial geometry is shared through its pure C++ function and C ABI. Agreement between two implementations is supplemented by independent impulse, response, DC, and transition fixtures.

The **Windows** engine uses `Source/Core` directly as its live DSP: `lowend::Processor` for tone and `lowend::SpatialProcessor` for spatial. There is no Windows-only DSP implementation. The macOS live path still runs the Swift spatial stage, so the two platforms do not yet share one spatial runtime implementation. See the [Windows guide](windows.md).

Live Output Conditioning supports PCM 2×. Higher factors, dither/noise shaping, and DSD/DoP are not connected to live output. The offline DoP packer stores 16 DSD bits and an 8-bit marker per channel in a 32-bit little-endian container `[payloadLow, payloadHigh, marker, 0]`, preserving partial payloads and marker phase across blocks. This format check does not establish complete DSD64/128/256 transport or hardware compatibility.

v0.3.0 includes the Spatial Stage redesign and audio-processing stabilization. See its release notes for included features and verification scope.

## Repository layout

```text
Source/Core/                    Testable portable Circuit, HighExciter, and Spatial DSP
SystemAudioProcessor/           Native macOS Swift and C engine
SystemAudioProcessor/Shaders/   Metal spectrum shader
SystemAudioProcessor/Assets/    Native app icon
Windows/                        Windows CLI and GUI audio engine (WASAPI)
scripts/                        Build and launch helpers
docs/                           Usage, design, and validation records
```

[Contributing](../CONTRIBUTING.md) · [License](../LICENSE)

## Reference documents

| Document | Subject |
|---|---|
| [Windows Guide](windows.md) | Windows build, CLI usage, limitations, and verification scope |
| [Windows Port Plan](windows-port-plan.md) | Windows porting phases and architecture decisions |
| [System-Wide and Per-App Use](system-wide-and-per-app.md) | macOS system-wide and per-application processing |
| [Rate Matching](rate-matching.md) | Automatic sample-rate transitions and recovery |
| [HighExciter Oversampling](high-exciter-oversampling.md) | Factor policy, filters, and real-time constraints |
| [Source Format Validation](source-format-validation-2026-06-11.md) | Apple Music and TIDAL source-detection evidence |
| [Source Rate Tracking and Device Lock Plan](source-rate-and-device-lock-plan.md) | Source, automatic transition, and Device Lock design |
| [Cross-Platform Core Architecture](cross-platform-core-architecture.md) | Swift and C++ DSP-core integration design and migration plan |
| [GitHub Releases](https://github.com/Gomtanga/lowend-circuit/releases) | Version changes, downloadable files, and verification results |

Design documents and dated validation records describe the state at the time they were written. Check the latest code and release notes when you need the current behavior.
