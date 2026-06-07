# LowEnd Core — Cross-platform DSP Library

Cross-platform C++ DSP core shared by:

- **macOS Native App** (SystemAudioProcessor/) — via ObjC++ bridging
- **JUCE Plugin** (Source/) — via C++ include
- **Windows Native App** (WindowsAdapter/, future) — via C++ include

## Dependency

- C++17 compiler
- `AudioRingBufferC.h` from `SystemAudioProcessor/Sources/AudioRingBufferC/include/`
- CMake 3.16+

## Build & Test

```bash
cd Source/Core
cmake -S . -B build -DBUILD_TESTING=ON
cmake --build build
cd build && ctest --output-on-failure
```

## Contents

| File | Description |
|---|---|
| `include/Core/Core.h` | Umbrella header — all public API |
| `src/Core.cpp` | Biquad, OnePole, DSPPrecompute implementations |
| `test/test_biquad.cpp` | Golden reference tests for Biquad + OnePole |
| `test/test_precompute.cpp` | Sanity tests for DSPPrecompute |

## Design Rules

- **float** only (no double) — matches both Swift and JUCE implementations
- **No heap allocation** after construction — realtime-safe
- **Sample-rate-aware** — all coefficient generators take `sampleRate`
- **No global state** — all instances are independent
- **C ABI types** from `AudioRingBufferC.h` serve as the data contract
