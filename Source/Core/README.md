# LowEnd Core — macOS DSP Library

C++ DSP core exposed to the **macOS Native App** (`SystemAudioProcessor/`)
through `LowEndDSPCoreC`. Native diagnostics compare these kernels with the
Swift processing kernels in `TonalDSP.swift`; the existence of the bridge alone
does not imply that the live audio callback invokes `Processor`.

## Processing API

```cpp
lowend::Processor processor;
processor.prepare(sampleRate, maxChannels);
processor.update(settings);
processor.process(channelPointers, frameCount);
processor.reset();
```

`DSPSettings` is a POD alias of `LCDSPSettings`. `DSPPrecompute` calculates
coefficients outside the audio callback. `process()` performs no allocation,
locking, logging, or coefficient transcendental math.

HighExciter uses 4x at 44.1/48 kHz, 2x at 88.2/96 kHz, and 1x at
176.4/192/768 kHz in Auto mode. Its harmonic branch has a sample-rate-aware
5 Hz DC blocker after decimation; the dry branch is preserved.
Oversampling changes keep old and new oversampling/DC states in two preallocated
pipelines and crossfade for 256 frames. Updates arriving during that fade replace
one pending snapshot; they do not restart the current fade.

Circuit uses a continuous cubic saturation curve and Double coefficients/state
for its low shelves. Rounding low-frequency coefficients to Float at 768 kHz
can change their response by several dB, even if the coefficient calculation
itself uses Double. `LCDSPSettings` therefore carries an additive precise
coefficient snapshot, while sample input/output and existing Float fields remain
available.

`Processor` and Swift `TonalDSPRouter` use two preallocated model banks. A model
change resets the target bank and crossfades old/new output for 256 frames;
outside a transition only the active model runs. Reusing an inactive bank cannot
replay frozen filter history. Initial setup applies directly, and reset collapses
to the latest requested state before clearing histories.

`SpatialGeometry.h` provides the authoritative pure geometry calculation for
both the UI preview and `LCSpatialSettings`. The C bridge returns requested and
applied delays, geometric and effective distances, and gain. Its caller supplies
the actual delay capacity; 8,192 samples covers the current bounds through
768 kHz. Geometry work runs on control/UI threads, not the audio callback.

`SpatialProcessor.h` provides the runtime spatial stage: the delay taps,
crossfeed, settings crossfade and activation blend. It takes an
`LCSpatialSettings` (the same C ABI struct the geometry produces) rather than
platform types, so the macOS and Windows apps run one shared implementation
instead of keeping a copy each. It is realtime-safe after construction:
`process()` allocates nothing, takes no locks, and performs no geometry work.
A control thread calls `update()`; a settings change crossfades over 256 frames
and a request arriving during a fade replaces the single pending plan.

```cpp
lowend::SpatialProcessor spatial;
spatial.prepare(sampleRate);                     // control thread
spatial.update(spatialSettings);                 // control thread
spatial.process(left, right);                    // audio thread, in place
spatial.reset();                                 // control thread, quiescent
```

`OutputConditioning.h` / `PcmResampler.h` hold the output-rate stage: a polyphase
FIR upsampler (2x/4x/8x) and the conditioning stage that drives it. Only the live
PCM 2× path is implemented; other modes bypass. The macOS design is ported
unchanged — the prototype low-pass is defined relative to the *input* period
(`h[n] = sinc((n - center)/factor)`, Blackman-windowed), each polyphase branch is
DC-normalized so a constant passes through at unity gain, and the last 127 input
samples are retained so a stream may be split into blocks of any size without
changing the output. Both platforms therefore run the same resampler design;
`SystemAudioProcessor` still compiles its own Swift copy today.

```cpp
lowend::OutputConditioning conditioning;
conditioning.prepare(sampleRate, maxInputFrames);  // control thread
conditioning.update(conditioningSettings);         // control thread
conditioning.process(left, right, frames, outLeft, outRight);  // audio thread
```

A block larger than the `maxInputFrames` passed to `prepare()` is refused
(`process()` returns 0 and writes nothing) rather than silently truncated. Size
that bound to the largest block the caller can hand over.

## Dependency

- C++17 compiler
- `AudioRingBufferC.h` from `SystemAudioProcessor/Sources/AudioRingBufferC/include/`
- CMake 3.16+

## Build & Test

```bash
cd Source/Core
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLOWEND_CORE_BUILD_TESTING=ON
cmake --build build
cd build && ctest --output-on-failure
```

On Windows with MSVC the same commands work. The C11 atomics used by
`AudioRingBufferC.c` need `/experimental:c11atomics`; the test target adds it
automatically, so no manual flag is required. Ninja or the Visual Studio
generator both work:

```bat
cmake -S Source\Core -B build\win-core -G Ninja -DCMAKE_BUILD_TYPE=Release -DLOWEND_CORE_BUILD_TESTING=ON
cmake --build build\win-core --parallel
ctest --test-dir build\win-core --output-on-failure
```

CI runs this matrix on `ubuntu-latest` and `windows-latest` for Debug and
Release. The same sources build warning-free and pass every test under MSVC,
Clang, and GCC. See [`docs/windows-port-plan.md`](../../docs/windows-port-plan.md)
for the Windows audio application built on top of this core.

## Contents

| File | Description |
|---|---|
| `include/Core/Core.h` | Umbrella header — all public API |
| `include/Core/Processor.h` | POD settings and pointer-based block processor |
| `include/Core/SpatialProcessor.h` | Portable stereo spatial stage (delay taps, crossfeed, crossfade) |
| `include/Core/PcmResampler.h` | Polyphase FIR upsampler (2x/4x/8x) |
| `include/Core/OutputConditioning.h` | Output conditioning stage (live PCM 2×) |
| `src/Core.cpp` | Biquad, OnePole, DSPPrecompute implementations |
| `src/SpatialGeometry.cpp` | Shared geometry and preview/audio snapshot |
| `src/SpatialProcessor.cpp` | Runtime delay/mix shared by the macOS and Windows apps |
| `src/PcmResampler.cpp` | Polyphase coefficient design and upsampling |
| `src/OutputConditioning.cpp` | Bypass and PCM 2× output path |
| `test/test_biquad.cpp` | Golden reference tests for Biquad + OnePole |
| `test/test_precompute.cpp` | Sanity tests for DSPPrecompute |
| `test/test_precise_biquad.cpp` | Independent frequency response and 768 kHz processing checks |
| `test/test_spatial_geometry.cpp` | Geometry bounds, mirror symmetry, delay capacity, invalid input |
| `test/test_spatial_processor.cpp` | Impulse positions, path routing, transitions, reset, non-finite input |
| `test/test_output_conditioning.cpp` | Bypass identity, 2× framing, block continuity, headroom, bounds |

## Design Rules

- **Float sample I/O**; low-shelf coefficients and filter state use Double in both languages
- **No heap allocation** after construction — realtime-safe
- **Sample-rate-aware** — all coefficient generators take `sampleRate`
- **No global state** — all instances are independent
- **C ABI types** from `AudioRingBufferC.h` serve as the data contract
