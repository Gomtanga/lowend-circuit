# LowEnd Circuit

[한국어 README](README.ko.md) | **English**

<p align="center">
  <img src="SystemAudioProcessor/Assets/LowEndNativeAudioIcon.png" width="180" alt="LowEnd Native Audio app icon">
</p>

LowEnd Circuit is an open-source audio project for bass enhancement, harmonic
coloration, spatial headphone processing, and real-time signal analysis.

The repository contains two related applications:

- **LowEnd Native Audio**: a macOS 14.4+ system-audio processor for the whole
  computer or selected applications, built with Core Audio, AVAudioEngine,
  Accelerate, MetalKit, AppKit, and SwiftUI.
- **LowEnd Circuit JUCE targets**: Standalone, VST3, and macOS AU builds for
  normal audio devices, DAWs, and plugin hosts.

This is an original DSP design. It is not affiliated with, endorsed by, or
based on the proprietary circuit of any hardware or software manufacturer.

## Download

Get the latest binaries from
[GitHub Releases](https://github.com/Gomtanga/lowend-circuit/releases/latest).

| Platform | Download | Purpose |
| --- | --- | --- |
| macOS 14.4+ | `LowEnd-Native-Audio-macOS-v0.2.1.zip` | Whole-system and per-app processing |
| Windows x64 | `LowEnd-Circuit-Standalone-Windows-v0.2.1.zip` | Normal desktop audio application |
| Windows x64 | `LowEnd-Circuit-VST3-Windows-v0.2.1.zip` | DAW/plugin-host use |

The macOS release is ad-hoc signed, not Apple-notarized. If Gatekeeper blocks
the first launch, right-click the app in Finder and choose **Open**. macOS will
also request system-audio recording permission when capture starts.

## System Requirements

### LowEnd Native Audio for macOS

Current `v0.2.1` release:

- macOS 14.4 or newer
- Apple Silicon Mac (`arm64`); M1 or newer
- 8 GB memory
- Metal-capable GPU
- Core Audio output device, headphones, speakers, or external DAC
- approximately 100 MB of free storage for extraction and normal use

Recommended for 96/192 kHz processing with the Analysis tab:

- Apple M2 or newer
- 16 GB memory

An Apple M5 test system kept Analysis-mode CPU use in the single-digit range
after the FFT, Metal, and SwiftUI optimizations. This is a reference result,
not a guaranteed benchmark for every device, sample rate, or audio workload.

The downloadable macOS `v0.2.1` binary is arm64-only. Intel Macs are not
supported by that archive.

### Windows Standalone and VST3

- Windows 10 or Windows 11, 64-bit
- four-core x64 processor or better
- 8 GB memory
- compatible audio device or DAW/plugin host

Windows builds do not include native whole-system or per-application capture.

## Quick Start: macOS Native App

1. Extract `LowEnd-Native-Audio-macOS-v0.2.1.zip`.
2. Move `LowEnd Native Audio.app` to Applications.
3. Open the app and allow system-audio recording when macOS asks.
4. Select `Circuit`, `HighExciter`, or `Clean`.
5. For Circuit, start with `IEM` or `Gentle`. For HighExciter, start with `Soft` or `Air`.
6. Press **전체 시스템 적용** to process most system output.
7. Press **중지** before changing audio hardware if output becomes silent.

For one application, enter its bundle ID and press **특정 앱 적용**. The app
list at the bottom helps identify running bundle IDs.

## DSP Models

### Clean

Dry comparison path. Model processing, output trim, and spatial processing are
bypassed.

### Circuit

The default bass model combines:

- a variable low-shelf controlled by `LowEnd`
- separate RC-style bass and sub-bass nodes
- `Body` injection focused below the main bass shelf
- pre-emphasis and matching de-emphasis filters
- asymmetric polynomial saturation for transformer-like coloration
- parallel wet processing and output protection

`LowEnd` and `Body` are independent controls. At maximum settings, `LowEnd`
produces a clearly measurable bass shelf while `Body` adds a narrower
sub-bass-weighted lift.

### HighExciter

An independent high-frequency harmonic model:

- extracts content above approximately 11 kHz with a high-pass biquad
- applies a fast polynomial harmonic generator
- preserves the original dry signal
- maps the two main sliders to `Exciter Drive` and `Wet Mix`

## Circuit Presets

| Preset | LowEnd | Body | Output |
| --- | ---: | ---: | ---: |
| IEM | 30% | 8% | -2.0 dB |
| Gentle | 22% | 8% | -1.0 dB |
| LowEnd | 42% | 18% | -1.8 dB |
| Deep | 54% | 22% | -2.8 dB |
| Clear | 0% | 0% | 0.0 dB |

Output trim is reduced on stronger presets to preserve headroom after bass
boosting. These presets are **not loudness-matched**, so compare tonal changes
carefully; apparent differences include both DSP and playback level. Presets
do not change Spatial Stage settings.

## HighExciter Presets

| Preset | Exciter Drive | Wet Mix |
| --- | ---: | ---: |
| Soft | 0.12 | 0.04 |
| Air | 0.22 | 0.07 |
| Detail | 0.35 | 0.11 |
| Shimmer | 0.50 | 0.16 |
| Off | 0.00 | 0.00 |

HighExciter presets only change `Exciter Drive` and `Wet Mix`. They never move
or apply the Circuit `Output` control. The preset row is disabled in `Clean`
because that model is a complete bypass.

## Spatial Stage

The native macOS app includes a real-time headphone/IEM spatializer:

- drag or click the blue listener point
- enter exact `X` and `Z` positions
- adjust virtual speaker `Width`
- blend the result with `Space`
- use **원위치** to reset only the listener position

The processor derives distance gain, inter-ear timing differences, and
crossfeed from the virtual geometry. It is a stereo spatializer, not a room
reverb or a full HRTF renderer.

Suggested IEM starting point:

```text
X: 0.00 m
Z: 0.00 m
Width: 1.4-1.8 m
Space: 25-45%
```

Reduce `Space` first if the image feels phasey or unnaturally distant.

## Analysis

The Analysis tab provides:

- 16,384-point Hann-windowed real FFT using Accelerate/vDSP
- 128 log-distributed spectrum bars rendered with one instanced Metal draw
- Peak and RMS meters
- Crest Factor (`Peak dB - RMS dB`)

Analysis never runs in the real-time audio callback. FFT work is limited to the
visible Analysis tab, Metal skips unchanged snapshots, and meter publishing is
rate-limited to avoid unnecessary SwiftUI layout work.

## Audio Format and Exclusive Mode

The format label reports the **current internal processing format**, for
example `Processing 96.0 kHz / 32-bit Float`. It does not report the original
bit depth or sample rate of a music file.

The app tracks default-output-device and nominal-sample-rate changes, stops and
reconfigures AVAudioEngine, clears ring buffers, resets filter state, and
recomputes sample-rate-dependent coefficients outside the audio callback.

DSP output is not bit-perfect because the signal is intentionally modified.
Player-exclusive modes such as Tidal **Use Exclusive Mode** can bypass or starve
the Core Audio process tap. Disable exclusive mode when using system-wide
processing.

## Real-Time Architecture

The native engine keeps the audio callback free from:

- heap allocation and collection resizing
- locks, mutexes, semaphores, and `DispatchQueue`
- logging and file I/O
- UI objects and `@Published` access
- coefficient calculation and transcendental functions

UI-side `DSPPrecompute` calculates biquad coefficients and scalar parameters.
Changes are delivered through a lock-free SPSC control queue. The callback
drains the latest packet and performs assignment-only DSP updates while
preserving filter state. Audio and visualizer samples use separate lock-free
ring buffers.

## Build the Native macOS App

Requirements:

- macOS 14.4 or newer
- Xcode command-line tools / a current Swift toolchain

```sh
git clone https://github.com/Gomtanga/lowend-circuit.git
cd lowend-circuit
./scripts/build-native-system-audio-app.sh
open "build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd Native Audio.app"
```

Useful command-line helpers:

```sh
./scripts/run-system-wide-lowend.sh
./scripts/list-audio-apps.sh
./scripts/run-app-lowend.sh com.spotify.client
```

The binary also accepts:

```text
--intensity 0...100
--body 0...100
--output dB
--model clean|circuit|highexciter
--spatial on|off
--listener-x meters
--listener-z meters
--stage-width meters
--space 0...100
```

## Build Standalone and Plugins

Requirements:

- CMake 3.22+
- C++17 toolchain
- internet access during configuration to fetch JUCE 8.0.13

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

Targets:

- all platforms: Standalone and VST3
- macOS: Standalone, VST3, and AU

The JUCE Standalone app uses normal input/output device routing. It does not
provide the macOS Core Audio Process Tap system-capture path.

## Current Limitations

- Native whole-system/per-app capture is macOS-only.
- Windows releases currently contain Standalone and VST3 builds only.
- Exclusive-output player modes are incompatible with process-tap capture.
- Some applications play audio through helper processes with different bundle
  IDs.
- The macOS release is not Developer ID signed or notarized.
- Spatial Stage is a geometric stereo processor, not individualized HRTF.

## Repository Layout

```text
Source/                         JUCE plugin and Standalone sources
SystemAudioProcessor/           Native macOS Swift/C engine
SystemAudioProcessor/Shaders/   Metal spectrum shader
SystemAudioProcessor/Assets/    Native app icon assets
scripts/                        Build and launch helpers
docs/                           Additional usage notes
```

## License and Third-Party Terms

The repository is licensed under
[GNU AGPL-3.0-or-later](LICENSE).

JUCE is fetched at build time and remains subject to its own dual-license
terms. Review the JUCE license before distributing binaries or using the JUCE
targets commercially.

Names and trademarks belonging to third parties remain the property of their
respective owners. No third-party product name or proprietary circuit is used
as project branding or claimed as an exact emulation.
