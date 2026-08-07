# LowEnd Core — macOS DSP Library

C++ DSP core used by the **macOS Native App** (`SystemAudioProcessor/`)
via the `LowEndDSPCoreC` C bridge.

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
176.4/192/768 kHz.

## Dependency

- C++17 compiler
- `AudioRingBufferC.h` from `SystemAudioProcessor/Sources/AudioRingBufferC/include/`
- CMake 3.16+

## Build & Test

```bash
cd Source/Core
cmake -S . -B build -DLOWEND_CORE_BUILD_TESTING=ON
cmake --build build
cd build && ctest --output-on-failure
```

## Contents

| File | Description |
|---|---|
| `include/Core/Core.h` | Umbrella header — all public API |
| `include/Core/Processor.h` | POD settings and pointer-based block processor |
| `src/Core.cpp` | Biquad, OnePole, DSPPrecompute implementations |
| `test/test_biquad.cpp` | Golden reference tests for Biquad + OnePole |
| `test/test_precompute.cpp` | Sanity tests for DSPPrecompute |

## Design Rules

- **float** only (no double) — matches the Swift implementation
- **No heap allocation** after construction — realtime-safe
- **Sample-rate-aware** — all coefficient generators take `sampleRate`
- **No global state** — all instances are independent
- **C ABI types** from `AudioRingBufferC.h` serve as the data contract
