# WindowsNativePrototype — LowEnd Circuit Windows Native App Prototype

Minimal console-based prototype for Windows system-audio capture + DSP + playback,
using the shared Core DSP library (Source/Core/).

## Build Status

| Platform | Status |
|---|---|
| Windows (CI) | ⏳ GitHub Actions |
| macOS | ❌ (Windows-only project) |

## Build

```powershell
# From repository root
cmake -S WindowsNativePrototype -B build/win-prototype -G "Visual Studio 17 2022" -A x64
cmake --build build/win-prototype --config Release
```

## Milestones

- [ ] Step 1: Console app boot + CMake + CI build
- [ ] Step 2: WASAPI loopback capture (compiles)
- [ ] Step 3: Core CircuitBass DSP integration
- [ ] Step 4: WASAPI playback
- [ ] Step 5: End-to-end prototype
