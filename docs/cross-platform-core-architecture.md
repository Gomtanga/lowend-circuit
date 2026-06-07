# LowEnd Circuit — Cross-Platform Core Architecture

> 제안일: 2026-06-08
> 상태: **초안 — 코드 수정 없음, 아키텍처 제안 단계**

---

## 0. 현재 상태 분석

### 0.1 전체 파일 구성

| 계층 | 파일 | 언어 | 라인 수 | OS 종속 |
|---|---|---|---:|---:|
| **C Core** | `SystemAudioProcessor/Sources/AudioRingBufferC/AudioRingBufferC.c` | C | 382 | ❌ (stdatomic.h) |
| **C 헤더** | `SystemAudioProcessor/Sources/AudioRingBufferC/include/AudioRingBufferC.h` | C | 115 | ❌ (types + function signatures) |
| **Swift DSP** | `SystemAudioProcessor/Sources/SystemAudioProcessor/main.swift` (일부) | Swift | ~580 | ⚠️ (vDSP만 macOS) |
| **Swift macOS** | `SystemAudioProcessor/Sources/SystemAudioProcessor/main.swift` (나머지) | Swift | ~2805 | ✅ macOS 전용 |
| **JUCE DSP** | `Source/PluginProcessor.cpp` | C++ | 147 | ❌ (JUCE cross-platform) |
| **JUCE UI** | `Source/PluginEditor.cpp` | C++ | 170 | ❌ (JUCE cross-platform) |
| **Metal Shader** | `SystemAudioProcessor/Shaders/SpectrumShaders.metal` | MSL | 59 | ✅ macOS 전용 |

### 0.2 DSP 중복 현상

**가장 중요한 발견:** Swift DSP와 JUCE DSP는 **완전히 다른 알고리즘**입니다.

| 특성 | Swift DSP (VirtualCircuitBassDSP) | JUCE DSP (PluginProcessor) |
|---|---|---|
| Bass 처리 | Low-Shelf + RC Bass/Sub-bass pole + feedback | Low-Shelf (JUCE IIR) |
| Saturation | Asymmetric polynomial + pre/de-emphasis | `tanh` 기반 간단한 clamp |
| Body | Frequency-weighted injection | `tanh(sub * 2.4) * 0.18 * body` |
| Sub | RC one-pole 38 Hz | Biquad low-pass 135 Hz |
| Output 보호 | Complex headroom + makeup + wet mix | 고정 headroom + tanh |
| HighExciter | 별도 DSP 클래스 | 없음 |
| Spatializer | Delay line + crossfeed | 없음 |
| **결과** | **동일 입력 → 다른 출력** | |

즉, 지금 macOS Native App과 JUCE VST3/Standalone은 **DSP 결과가 다릅니다.**

---

## 1. 공유 가능한 부분과 macOS 전용 부분

### ✅ Core — 완전히 공유 가능 (pure math, 아키텍처 단계)

| 컴포넌트 | 현재 위치 | 비고 |
|---|---|---|
| `Biquad` struct | main.swift 2196-2236 | Direct Form I, portable |
| `RcLowPass` (one-pole) | main.swift 2291-2310 | Pure math |
| `DSPPrecompute` (coefficient 계산) | main.swift 2033-2193 | Biquad, shelf, spatial geometry |
| `VirtualCircuitBassDSP` (full circuit) | main.swift 2313-2438 | Channel별 LP + shelf + sat |
| `LowEndDSP` (simple bass) | main.swift 2242-2289 | Portable |
| `HighExciterDSP` | main.swift 2441-2510 | HP biquad + polynomial harmonic |
| `DelayLine` | main.swift 2512-2535 | Circular buffer |
| `Spatializer` | main.swift 2537-2591 | Crossfeed + delay |
| `AudioSpectrumAnalyzer` | main.swift 930-1196 | ⚠️ vDSP 의존 (Accelerate) |
| 프리셋 데이터 | main.swift 1650-1689 | Key-value |
| `SceneKit` 대체 뷰 | — | Spatial Stage 렌더링은 새로 작성 |

### ✅ 이미 C로 작성 — 재컴파일만 하면 공유 가능

| 파일 | 용도 | Windows |
|---|---|---|
| `AudioRingBufferC.c` | Lock-free ring buffer, control queue, spectrum snapshot | `stdatomic.h` 필요 (C11, MSVC 호환) |
| `AudioRingBufferC.h` | 타입 정의 (LCBiquadCoefficients, LCDSPSettings 등) | 재컴파일만으로 가능 |

### ✅ macOS 전용 (건드리지 않음)

| 컴포넌트 | 용도 |
|---|---|
| `HardwareSampleRateTracker` | CoreAudio AudioObject API로 장치/샘플레이트 감지 |
| `SystemAudioProcessor` | AVAudioEngine + CoreAudio Process Tap + Aggregate Device |
| `NativeAppDelegate` (일부) | NSApplication, NSWindow, AppKit 컨트롤 |
| `SpatialStageView` | SceneKit 기반 3D 뷰 |
| `MetalSpectrumView` | MTKView + Metal 렌더링 |
| `RightPanelContainerView` | SwiftUI (NSHostingView로 임베드) |
| `launchGUI()` | NSApplication run loop 시작 |
| `listRunningApps()` | NSWorkspace API |

### ⚠️ 부분적 macOS 의존 (Windows에서 대체 필요)

| 컴포넌트 | macOS | Windows 대안 |
|---|---|---|
| `AudioSpectrumAnalyzer` — vDSP FFT | `vDSP_fft_zrip` | DirectXMath / Intel IPP / kissfft |
| `vDSP_vmul`, `vDSP_vsmul`, 등 | Accelerate | Eigen / 수동 루프 |
| `NSWorkspace.shared.runningApplications` | AppKit | `EnumProcesses` / WMI |

---

## 2. 제안 아키텍처

### 2.1 디렉터리 구조

```
LowEndCircuit/
├── Core/                          # 🔷 NEW: Cross-platform C++ core
│   ├── CMakeLists.txt
│   ├── include/
│   │   ├── Core/                  # Public headers
│   │   │   ├── Types.h            # LCSettings, LCDSPParameters, LCPreset
│   │   │   ├── Biquad.h           # Biquad filter (DF1)
│   │   │   ├── OnePole.h          # RC one-pole filter
│   │   │   ├── CircuitBass.h      # VirtualCircuitBassDSP
│   │   │   ├── HighExciter.h      # HighExciterDSP
│   │   │   ├── Spatializer.h      # Crossfeed spatializer
│   │   │   ├── DelayLine.h        # Circular delay buffer
│   │   │   ├── Analyzer.h         # Spectrum analysis (pluggable FFT)
│   │   │   ├── Presets.h          # Preset definitions
│   │   │   └── RingBuffer.h       # Wrapper around AudioRingBufferC
│   │   └── Core/
│   │       └── Export.h           # DLL export macros
│   ├── src/
│   │   ├── Biquad.cpp
│   │   ├── OnePole.cpp
│   │   ├── CircuitBass.cpp
│   │   ├── HighExciter.cpp
│   │   ├── Spatializer.cpp
│   │   ├── DelayLine.cpp
│   │   ├── Analyzer.cpp           # FFT-based, pluggable backend
│   │   └── Presets.cpp
│   └── test/                      # 🔷 NEW: Cross-platform tests
│       ├── CMakeLists.txt
│       ├── test_biquad.cpp
│       ├── test_circuit_bass.cpp
│       ├── test_highexciter.cpp
│       ├── test_spatializer.cpp
│       ├── test_ring_buffer.cpp
│       └── test_presets.cpp
│
├── AudioRingBufferC/              # 🔷 MOVE from SystemAudioProcessor/
│   ├── AudioRingBufferC.c         # (그대로 유지)
│   └── include/AudioRingBufferC.h # (그대로 유지)
│
├── MacOSAdapter/                  # 🔷 NEW: macOS 전용 앱
│   ├── CMakeLists.txt
│   ├── CoreAudioCapture/
│   │   ├── HardwareTracker.mm     # CoreAudio AudioObject (기존)
│   │   ├── SystemProcessor.mm     # AVAudioEngine 연동 (기존)
│   │   └── ProcessTap.mm          # CATap + Aggregate Device (기존)
│   ├── UI/
│   │   ├── AppDelegate.swift      # NSApplication (기존)
│   │   ├── ControlPanel.swift     # SwiftUI / AppKit UI (기존)
│   │   ├── SpatialStageView.swift # SceneKit 3D (기존)
│   │   └── MetalSpectrumView.swift# MTKView (기존)
│   └── main.swift                 # 진입점 (기존 launchGUI)
│
├── WindowsAdapter/                # 🔷 NEW: Windows 전용 앱
│   ├── CMakeLists.txt
│   ├── WasapiCapture/
│   │   ├── WasapiLoopback.h
│   │   ├── WasapiLoopback.cpp     # WASAPI loopback capture
│   │   ├── AudioRenderer.h
│   │   └── AudioRenderer.cpp      # WASAPI playback
│   ├── UI/
│   │   ├── MainWindow.h/cpp       # WinUI 3 또는 Qt 메인 윈도우
│   │   ├── ControlPanel.h/cpp     # 슬라이더, 버튼, 드롭다운
│   │   ├── LevelMeter.h/cpp       # Peak / RMS 미터
│   │   └── SpectrumView.h/cpp     # DirectX 11 spectrum bars
│   └── main.cpp                   # WinMain 진입점
│
├── PluginAdapter/                 # 🔷 NEW: JUCE VST3/Standalone 어댑터
│   ├── CMakeLists.txt
│   ├── PluginProcessor.cpp        # 🔷 REFACTOR: Core/ 호출
│   └── PluginEditor.cpp           # (기존 유지)
│
├── Source/                        # (기존 — Phase 0에서 철거 예정)
│   ├── PluginProcessor.cpp        # → PluginAdapter/
│   └── PluginEditor.cpp           # → PluginAdapter/
│
├── SystemAudioProcessor/          # (기존 — 유지, 점진적 교체)
│
├── scripts/
├── docs/
└── AGENTS.md
```

### 2.2 계층 구조

```
┌─────────────────────────────────────────────────────┐
│                    PluginAdapter/                     │
│  (JUCE VST3/Standalone — 모든 플랫폼)                │
│  PluginProcessor.cpp → Core::CircuitBass             │
│  PluginEditor.cpp (JUCE UI)                          │
└────────────────────┬────────────────────────────────┘
                     │
┌────────────────────┼────────────────────────────────┐
│         Core/       │      Cross-platform C++ DSP     │
│                    │                                  │
│  ┌──────────────┐  │  ┌───────────────────────────┐  │
│  │ CircuitBass  │  │  │ Spatializer + DelayLine    │  │
│  │ HighExciter  │  │  │ Analyzer (FFT)             │  │
│  │ LowEndDSP    │  │  │ Presets, Parameters        │  │
│  │ Biquad       │  │  │ OnePole (RC filter)        │  │
│  └──────────────┘  │  └───────────────────────────┘  │
│                    │                                  │
│  ┌──────────────────────────────────────────────┐    │
│  │ AudioRingBufferC (C — lock-free ring buffer) │    │
│  └──────────────────────────────────────────────┘    │
└────────────────────┬────────────────────────────────┘
                     │
    ┌────────────────┼────────────────────┐
    │                │                     │
┌───┴──────────┐ ┌──┴───────────┐ ┌──────┴───────────┐
│ MacOSAdapter  │ │WindowsAdapter│ │  기존 SystemAudio │
│               │ │              │ │  Processor       │
│ CoreAudio Tap │ │ WASAPI       │ │  (macOS, 점진적  │
│ AVAudioEngine │ │ Loopback     │ │   마이그레이션)  │
│ Metal/SwiftUI │ │ DirectX 11   │ │                  │
│ SceneKit      │ │ WinUI/Qt     │ │                  │
└───────────────┘ └──────────────┘ └──────────────────┘
```

### 2.3 데이터 흐름

```
UI Slider 변경
     │
     ▼
Core::Parameters 구조체 업데이트
     │
     ▼
Core::CoefficientPrecompute::calculate(sampleRate, params)
     │  (biquad 계수, RC alpha, spatial path, drive 값 등)
     ▼
Core::DSPConfig (read-only, realtime-safe struct)
     │
     ├──► lock-free control queue ──► 오디오 콜백 스레드
     │     (AudioRingBufferC의 LCControlEventQueue 사용)
     │
     └──► snapshot copy ──► UI 표시용 값
```

### 2.4 핵심 설계 결정

#### 결정 1: C++로 Core 작성 (Swift 아님)

| 기준 | C++ | Swift |
|---|---|---|
| JUCE Plugin과 공유 | ✅ 직접 include 가능 | ❌ ObjC bridging 필요 |
| Windows 지원 | ✅ MSVC + Clang | ❌ Swift for Windows 미성숙 |
| C 호환 | ✅ extern "C" | ⚠️ @objc bridging header |
| 실시간 안전성 | ✅ new/delete 지양 | ⚠️ ARC, COW |
| 기존 AudioRingBufferC | ✅ C linkage 직접 호출 | ⚠️ 별도 bridging |

#### 결정 2: Core는 `new`/`malloc`을 생성자에서만 사용, 실시간 콜백에서 절대 금지

```cpp
// 생성 시에만 allocation
class CircuitBass {
    Biquad shelfL, shelfR;
    OnePole bassPoleL, bassPoleR;
    OnePole subPoleL, subPoleR;
    // ...
public:
    void update(const DSPConfig& config);  // 할당 없음, 필드 대입만
    void process(const float* in, float* out, int frames);  // 할당 없음
};
```

#### 결정 3: Spectrum Analyzer의 FFT 백엔드는 추상화

```cpp
class FFTAnalyzer {
public:
    virtual ~FFTAnalyzer() = default;
    virtual void compute(const float* input, int fftSize, float* magnitudes) = 0;
};

// macOS: Accelerate 기반
class AccelerateFFTAnalyzer : public FFTAnalyzer { ... };

// Windows: DirectXMath / Intel IPP / kissfft 기반
class KissFFTAnalyzer : public FFTAnalyzer { ... };
```

#### 결정 4: AudioRingBufferC는 그대로 유지, Core에서 C linkage로 호출

이미 portable한 C 코드이므로 재작성 불필요. Core의 CMakeLists.txt에 포함.

#### 결정 5: 기존 SystemAudioProcessor/는 점진적으로 Core/로 마이그레이션

macOS Native App이 즉시 Core를 사용하도록 변경하지 않고, 기존 Swift DSP를 유지하면서 Core와 비교 테스트할 수 있는 브리징 단계를 둠.

---

## 3. 기존 JUCE DSP와 Swift DSP 통합 분석

### 3.1 알고리즘 비교

| 처리 단계 | Swift VirtualCircuitBass | JUCE PluginProcessor | 통합 방향 |
|---|---|---|---|
| Bass shelf | Biquad low-shelf (8.5dB, 105Hz) | JUCE IIR low-shelf | Core에 통합 |
| Low-pass sub | RC one-pole 38Hz | Biquad low-pass 135Hz | Core에서 둘 다 지원, 모드 선택 |
| Body injection | Gain * subNode | tanh(sub * 2.4) * body | Core에서 제공 |
| Saturation | Asymmetric polynomial + pre/de-emphasis | tanh blended * outputGain | Core에서 다단계 선택 |
| Headroom | Complex circuitHeadroom | 없음 | Core에서 제공 |
| HighExciter | 독립 HP biquad + polynomial | 없음 | Core에서 추가 |
| Spatializer | Delay line crossfeed | 없음 | Core에서 추가 |
| Presets | 모델별 분리 | 없음 | Core에서 제공 |

### 3.2 결론: Core로 통합해야 Swift와 JUCE DSP가 동일한 결과를 냄

**지금은 다른 DSP이므로, 공유 Core를 만들기 전에 먼저 알고리즘 동기화가 필요합니다.**

**권장: Swift VirtualCircuitBassDSP 알고리즘을 기준으로 Core를 작성**

- Swift DSP가 더 정교함 (transformer saturation, spatializer, HighExciter, body injection)
- JUCE DSP는 더 단순하므로 Core 구현 후 JUCE PluginProcessor가 Core를 호출하도록 변경

---

## 4. Migration Plan

### Phase 1: Core Library 구축 (예상: 2-3주)

| 단계 | 작업 | 파일 |
|---|---:|---|
| 1.1 | `Core/include/Core/Types.h` — DSP 파라미터, 설정, enum 정의 | 신규 |
| 1.2 | `Core/src/Biquad.cpp` — Direct Form I biquad | 신규 |
| 1.3 | `Core/src/OnePole.cpp` — RC one-pole | 신규 |
| 1.4 | `Core/src/CircuitBass.cpp` — VirtualCircuitBassDSP 이식 | 신규 |
| 1.5 | `Core/src/HighExciter.cpp` — HighExciterDSP 이식 | 신규 |
| 1.6 | `Core/src/Spatializer.cpp` + `DelayLine.cpp` | 신규 |
| 1.7 | `Core/src/Analyzer.cpp` — FFT 추상화 + kissfft 기본 구현 | 신규 |
| 1.8 | `Core/src/Presets.cpp` — 프리셋 정의 | 신규 |
| 1.9 | `Core/CMakeLists.txt` — C++17 + C link | 신규 |
| 1.10 | `Core/test/` — 각 컴포넌트 단위 테스트 | 신규 |
| 1.11 | 브랜치 생성: `spike/cross-platform-core` | |

**당시 변경하지 않는 것:**
- `SystemAudioProcessor/` — 기존 Swift DSP 그대로 유지
- `Source/` — 기존 JUCE PluginProcessor 그대로 유지
- `CMakeLists.txt` — 루트 CMakeLists.txt는 Core만 추가 빌드, 기존 타깃 변경 없음

### Phase 2: macOS Adapter가 Core를 사용하도록 전환 (예상: 1주)

| 단계 | 작업 |
|---|---:|---|
| 2.1 | Swift에서 C++ Core를 호출할 bridging header 작성 |
| 2.2 | SystemAudioProcessor의 DSP 클래스를 Core::CircuitBass + Core::Spatializer로 교체 |
| 2.3 | 기존 Swift DSP와 Core DSP 출력을 비교 테스트 |
| 2.4 | 동일 출력 확인 후 Swift DSP 코드 제거 |

### Phase 3: Plugin Adapter가 Core를 사용하도록 전환 (예상: 1주)

| 단계 | 작업 |
|---|---:|---|
| 3.1 | PluginProcessor.cpp에서 Core include |
| 3.2 | Core::CircuitBass + Core::HighExciter + Core::Spatializer 사용 |
| 3.3 | 기존 Juce DSP 코드 제거 |
| 3.4 | PluginEditor.cpp에서 Core::Presets 사용 |
| 3.5 | macOS + Windows에서 Plugin 빌드 및 DSP 결과 일치 확인 |

### Phase 4: Windows Native App (예상: 3-4주, Core 기반)

| 단계 | 작업 |
|---|---:|---|
| 4.1 | `WindowsAdapter/WasapiCapture/` — WASAPI loopback capture + playback |
| 4.2 | `WindowsAdapter/UI/` — WinUI 3 또는 Qt 기반 UI |
| 4.3 | `WindowsAdapter/UI/SpectrumView` — DirectX 11 spectrum bars |
| 4.4 | `WindowsAdapter/main.cpp` — WinMain 진입점, Core::CircuitBass 연결 |
| 4.5 | macOS Native App과 동일한 프리셋 + Spatializer 지원 확인 |
| 4.6 | CI에 Windows Adapter 빌드 추가 |

### Phase 5: 통합 및 릴리즈

| 단계 | 작업 |
|---|---:|---|
| 5.1 | 모든 플랫폼에서 동일 DSP 출력 검증 테스트 |
| 5.2 | 기존 `SystemAudioProcessor/` Swift DSP 제거 |
| 5.3 | `Source/PluginProcessor.cpp` → `PluginAdapter/`로 이동 |
| 5.4 | v0.3.0 릴리즈 (Core 기반, 모든 플랫폼 동일 DSP) |

---

## 5. 브랜치 전략

```text
main                     ← v0.2.1 (현재, 변경 금지)
  │
  └── spike/cross-platform-core    ← Phase 1 (여기서 시작)
       │
       ├── macOS/keep-swift-dsp    ← Phase 2 대비 (Swift DSP 유지)
       │
       └── (Phase 1 완료 후 PR → main 또는 feature/core-integration)
```

**최초 브랜치 생성 제안:**

```bash
git checkout main
git checkout -b spike/cross-platform-core
git push -u origin spike/cross-platform-core
```

이 브랜치에서 Phase 1 (Core Library)만 구현. macOS Native App, JUCE Plugin, Windows Adapter는 전혀 건드리지 않음.

---

## 6. Core Library 상세 설계 (Phase 1 범위)

### 6.1 `Core/include/Core/Types.h`

```cpp
#pragma once
#include <cstdint>

namespace lowend {

// DSP 모델 선택
enum class DSPModel : uint32_t {
    Clean = 0,
    Circuit = 1,
    HighExciter = 2,
};

// Biquad 계수 (AudioRingBufferC.h의 LCBiquadCoefficients와 동일)
struct BiquadCoefficients {
    float b0 = 1.0f;
    float b1 = 0.0f;
    float b2 = 0.0f;
    float a1 = 0.0f;
    float a2 = 0.0f;
};

// 실시간 DSP 설정 (AudioRingBufferC.h의 LCDSPSettings와 호환)
struct DSPConfig {
    float intensity;          // 0..1
    float body;               // 0..1
    float outputGain;         // linear
    float headroomGain;       // linear
    uint32_t dspModel;        // DSPModel
    BiquadCoefficients shelf;
    // ... (VirtualCircuitBassDSP의 모든 파라미터)
    BiquadCoefficients exciterHighPass;
    float exciterDrive;
    float exciterWetMix;
};

// Spatial 설정
struct SpatialConfig {
    bool enabled;
    float amount;             // 0..1
    struct Path {
        uint32_t delaySamples;
        float gain;
    };
    Path ll, lr, rl, rr;
};

// 사용자 파라미터 (UI→DSP)
struct UserParameters {
    DSPModel model = DSPModel::Circuit;
    float intensity = 55.0f;
    float body = 30.0f;
    float outputDb = -1.5f;
    struct {
        bool enabled = true;
        float listenerX = 0.0f;
        float listenerZ = 0.0f;
        float speakerWidth = 1.65f;
        float amount = 35.0f;
    } spatial;
};

// Coefficient precompute (비실시간)
DSPConfig calculateDSPConfig(float sampleRate, const UserParameters& params);
SpatialConfig calculateSpatialConfig(float sampleRate, const UserParameters& params);

} // namespace lowend
```

### 6.2 `Core/src/Biquad.cpp`

```cpp
// Swift Biquad struct과 동일한 Direct Form I
// process():
//   output = b0 * input + z1
//   z1 = b1 * input - a1 * output + z2
//   z2 = b2 * input - a2 * output
// 실시간 안전: 예외 없음, 동적 할당 없음
```

### 6.3 `Core/src/CircuitBass.cpp`

```cpp
// VirtualCircuitBassDSP의 Channel 클래스 직접 이식
// - Biquad shelfL, shelfR
// - OnePole bassPoleL, bassPoleR
// - OnePole subPoleL, subPoleR
// - preEmphasis, deEmphasis Biquad
// - asymmetric saturate 동일 구현
// - fastClamp 동일 구현
```

### 6.4 `Core/src/Spatializer.cpp`

```cpp
// DelayLine: circular buffer (Swift 그대로 이식)
// Spatializer: 4 path crossfeed (Swift 그대로 이식)
```

### 6.5 Core 테스트 (`Core/test/`)

Core Phase 1의 가장 중요한 산출물 중 하나는 테스트입니다. 테스트는 **어떤 플랫폼에서도** 실행 가능해야 합니다.

```bash
# macOS or Windows from Core/
cmake -S . -B build -DBUILD_TESTING=ON
cmake --build build
ctest --test-dir build --output-on-failure
```

**테스트 목록:**

| 테스트 | 검증 |
|---|---|
| `test_biquad.cpp` | Biquad coefficients (lowShelf, lowPass, highPass), impulse response, DC blocking |
| `test_circuit_bass.cpp` | input=0 → output=0, sample rate independence, parameter clamping |
| `test_highexciter.cpp` | wetMix=0 → bypass, drive saturation curve |
| `test_spatializer.cpp` | enabled=false → bypass, 좌우 분리 |
| `test_delay_line.cpp` | delay=0 → passthrough, delay=10 → 10 sample delay |
| `test_ring_buffer.cpp` | push/pop consistency, wraparound, empty/full behavior |
| `test_presets.cpp` | 프리셋 로드 시 예상 값과 일치하는지 |
| `test_cross_platform_consistency.cpp` | **Phase 2-3**: 동일 입력 → 동일 출력 (macOS vs Windows) |

---

## 7. 위험 요소 및 대응

| 위험 | 영향 | 대응 |
|---|---|---|
| Swift DSP와 Core C++ 출력 차이 | Phase 2에서 마이그레이션 지연 | Phase 1에서 테스트 코드에 golden reference 포함 |
| WASAPI loopback 레이턴시 | Phase 4 Windows UX 저하 | 버퍼 크기 조절 가능하도록 설계 |
| ARM/x86 FFT 결과 차이 | 분석 스펙트럼 미세 차이 | 상대 비교만 사용, 절대값 의존 금지 |
| MSVC `stdatomic.h` 호환성 | C ring buffer 컴파일 실패 | C11 atomics fallback 또는 MSVC `_Interlocked*` 래퍼 |

---

## 8. 요약

### 핵심 전략

1. **Core/를 C++로 먼저 만들고** — DSP, 파라미터, 프리셋, 테스트 포함
2. **테스트로 검증하고** — golden reference으로 모든 플랫폼에서 동일 출력 보장
3. **점진적으로 교체하고** — macOS Adapter → Plugin Adapter → Windows Adapter 순서
4. **v0.2.1은 건드리지 않고** — `spike/cross-platform-core` 브랜치에서 시작

### 타임라인 추정

| Phase | 내용 | 예상 기간 |
|---|---:|---:|
| Phase 1 | Core Library + 테스트 | 2-3주 |
| Phase 2 | macOS Adapter → Core 전환 | 1주 |
| Phase 3 | Plugin Adapter → Core 전환 | 1주 |
| Phase 4 | Windows Native App (Core 기반) | 3-4주 |
| Phase 5 | 통합, 정리, v0.3.0 릴리즈 | 1주 |

### Phase 1 시작 명령

```bash
git checkout main
git checkout -b spike/cross-platform-core
```

### Phase 1 완료 조건

- [ ] `Core/` 디렉터리 생성, CMake 정상 빌드
- [ ] `Core::Biquad`가 Swift Biquad와 동일한 impulse response 출력
- [ ] `Core::CircuitBass`가 Swift VirtualCircuitBassDSP와 동일한 출력
- [ ] `Core::Spatializer`가 Swift Spatializer와 동일한 출력
- [ ] `Core::HighExciter`가 Swift HighExciterDSP와 동일한 출력
- [ ] 모든 단위 테스트 통과
- [ ] 기존 `SystemAudioProcessor/` 및 `Source/` 코드 **수정 없음**
- [ ] 기존 `v0.2.1` 태그/CD 변경 없음
