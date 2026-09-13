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

## Contents

| File | Description |
|---|---|
| `include/Core/Core.h` | Umbrella header — all public API |
| `include/Core/Processor.h` | POD settings and pointer-based block processor |
| `src/Core.cpp` | Biquad, OnePole, DSPPrecompute implementations |
| `src/SpatialGeometry.cpp` | Shared geometry and preview/audio snapshot |
| `test/test_biquad.cpp` | Golden reference tests for Biquad + OnePole |
| `test/test_precompute.cpp` | Sanity tests for DSPPrecompute |
| `test/test_precise_biquad.cpp` | Independent frequency response and 768 kHz processing checks |
| `test/test_spatial_geometry.cpp` | Geometry bounds, mirror symmetry, delay capacity, invalid input |

## Design Rules

- **Float sample I/O**; low-shelf coefficients and filter state use Double in both languages
- **No heap allocation** after construction — realtime-safe
- **Sample-rate-aware** — all coefficient generators take `sampleRate`
- **No global state** — all instances are independent
- **C ABI types** from `AudioRingBufferC.h` serve as the data contract
