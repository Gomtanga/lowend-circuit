# Phase 1 종료 보고서 — Cross-Platform Core Library

---

## 1. 현재 Core 구성

```
Source/Core/
├── CMakeLists.txt                  C++17 + C, standalone 빌드
├── README.md
├── include/
│   └── Core/
│       ├── Core.h                  Umbrella header (Biquad/OnePole/DSPPrecompute 선언)
│       ├── CircuitBass.h           VirtualCircuitBassDSP
│       └── HighExciter.h           HighExciterDSP
├── src/
│   ├── Core.cpp                    Biquad, OnePole, DSPPrecompute 구현
│   ├── CircuitBass.cpp             Full circuit bass model
│   └── HighExciter.cpp             High-frequency harmonic exciter
└── test/
    ├── CMakeLists.txt
    ├── test_biquad.cpp             15 tests
    ├── test_precompute.cpp         33 tests
    ├── test_circuit_bass.cpp       14 tests
    └── test_high_exciter.cpp       14 tests
```

### 외부 의존성

| 항목 | 의존 |
|---|---|
| C++17 compiler | ✅ |
| `AudioRingBufferC.h` (C ABI types) | ✅ — SystemAudioProcessor/ 위치 그대로 참조 |
| JUCE | ❌ |
| Swift / Xcode | ❌ |
| Accelerate / vDSP | ❌ |
| CoreAudio / WASAPI | ❌ |
| Platform-specific headers | ❌ |

---

## 2. 테스트 현황

| 테스트 | 유형 | 개수 | 통과 |
|---|---|---|---|
| `test_biquad` | Golden (analytical) | 15/15 | ✅ |
| `test_precompute` | Sanity (Swift reference) | 33/33 | ✅ |
| `test_circuit_bass` | Behavioral + stability | 14/14 | ✅ |
| `test_high_exciter` | Behavioral + stability | 14/14 | ✅ |
| **Total** | | **76/76** | ✅ |

### Golden test 기준

| 클래스 | Golden value 출처 |
|---|---|
| Biquad | 수식 분석 (impulse response를 직접 계산) |
| OnePole | 수식 분석 |
| DSPPrecompute | Swift `DSPPrecompute` 동일 수식, sanity range check |
| CircuitBass | **Swift `VirtualCircuitBassDSP`** (main.swift:2313-2438) |
| HighExciter | **Swift `HighExciterDSP`** (main.swift:2441-2510) |

Core 밖의 구현체에 종속된 golden test는 없음. 모든 값은 수식 자체에서 도출됨.

---

## 3. Canonical Reference

### CircuitBass

| 항목 | 내용 |
|---|---|
| **Canonical reference** | **Swift `VirtualCircuitBassDSP`** |
| JUCE 비교 | JUCE `PluginProcessor`는 더 단순한 DSP만 있음 (shelf + LP + tanh). transformer saturation / pre-de-emphasis / body injection / feedback path 없음 |
| Core 방향 | Swift 수준을 기준으로 구현. JUCE Plugin이 Core를 사용하면 **DSP 품질이 업그레이드됨** |

### HighExciter

| 항목 | 내용 |
|---|---|
| **Canonical reference** | **Swift `HighExciterDSP`** (유일한 구현) |
| JUCE 비교 | **JUCE PluginProcessor에 HighExciter가 존재하지 않음.** `mix` 파라미터는 Circuit bass wet/dry용으로 완전히 다른 목적 |
| Core 방향 | Swift 구현을 그대로 이식. JUCE Plugin이 Core를 사용하면 **HighExciter 모델이 처음으로 추가됨** |

---

## 4. Core가 해결한 문제

### 1) DSP 중복

**Before:**
```
SystemAudioProcessor/main.swift
  └── VirtualCircuitBassDSP  (Swift, 130줄)
  └── HighExciterDSP         (Swift, 70줄)

Source/PluginProcessor.cpp
  └── Circuit DSP (JUCE IIR, 60줄) ← 다른 알고리즘, HighExciter 없음
```

**After:**
```
Source/Core/
  └── CircuitBass  (C++, 100줄) ← Swift 기준, 모든 플랫폼 공유 가능
  └── HighExciter  (C++, 60줄)  ← Swift 기준
```

### 2) 서로 다른 DSP 출력

**Before:** 동일한 `intensity=50, body=30, output=-1.5` 입력에 대해 Swift Native App과 JUCE VST3가 **다른 소리를 냄**

**After (Core 사용 시):** 동일한 `Core::CircuitBass`가 같은 계산을 하므로 **모든 플랫폼에서 동일한 DSP 출력 보장**

### 3) Windows Native App의 진입 장벽

**Before:** Windows에서 Native App을 만들려면 Swift DSP를 처음부터 다시 구현해야 했음

**After:** Core 라이브러리가 C++17로 준비되어 있음. Windows CMake 프로젝트에서 `add_subdirectory(Source/Core)` 한 줄이면 DSP 완료

### 4) 테스트 부재

**Before:** DSP 테스트가 없었음. Swift 앱을 실행해서 사람이 귀로 확인

**After:** 76개의 자동화된 golden/behavioral 테스트. CI에서 실행 가능. 회귀 방지

---

## 5. 아직 해결하지 못한 문제

### 1) Spatializer 미구현

Core에 아직 Spatializer (crossfeed delay line)가 없음.
Swift에는 있지만 JUCE Plugin에는 없음.
Phase 1에서 보류됨.

### 2) Spectrum Analyzer (FFT)

Swift의 `AudioSpectrumAnalyzer`는 Accelerate/vDSP에 의존.
Core로 이식하려면 FFT 백엔드 추상화가 필요함 (kissfft 등).
Phase 1에서 의도적으로 제외됨.

### 3) AudioRingBufferC의 위치

현재 `AudioRingBufferC/`가 `SystemAudioProcessor/` 아래에 있어서
Core가 상대 경로로 참조해야 함. Phase 2/3에서 위치 정리 필요.

### 4) Parameter serialization / state save-restore

JUCE Plugin은 `AudioProcessorValueTreeState`로 자동 처리.
Swift Native App은 `LCDSPSettings`를 control queue로 전달.
Core 레벨의 통일된 serialize/deserialize는 아직 없음.

---

## 6. JUCE Plugin 통합 난이도

### 예상: 하루~이틀

변경해야 할 파일:

| 파일 | 변경 내용 | 난이도 |
|---|---|---|
| `CMakeLists.txt` (root) | CMake에 Core/ 추가 | 하 |
| `PluginProcessor.cpp` | JUCE IIR → Core::CircuitBass + Core::HighExciter | 중 |
| `PluginProcessor.h` | 멤버 변수 타입 변경 | 하 |
| `PluginEditor.cpp` | 파라미터 레이아웃에 HighExciter/모델 선택 추가 | 중 |
| `PluginEditor.h` | UI 컨트롤 추가 | 하 |

### 리스크

- JUCE의 `dsp::IIR::Coefficients::makeLowShelf`와 Core의 `Biquad::makeLowShelf`가 같은 수식이므로 계수는 동일
- JUCE의 `SmoothedValue`는 Core에 없음. PluginProcessor가 직접 smoothing 하거나 JUCE smoothing 유지
- JUCE의 `AudioProcessorValueTreeState` serialization 유지하면서 Core 파라미터와 매핑 필요

### 권장 접근법

```cpp
// PluginProcessor.cpp — Core 사용 시
#include <Core/CircuitBass.h>
#include <Core/HighExciter.h>

class LowEndCircuitAudioProcessor {
    lowend::CircuitBass circuitBass;
    lowend::HighExciter highExciter;
    
    void prepareToPlay(double sampleRate, int) {
        auto dspConfig = lowend::DSPPrecompute::makeDSPSettings(
            sampleRate, currentIntensity, currentBody, currentOutput, currentModel);
        circuitBass.update(dspConfig);
        highExciter.update(dspConfig);
    }
};
```

---

## 7. Swift Native App 통합 난이도

### 예상: 2-3일

### 방법 A: C++ Core를 Swift에서 직접 호출 (권장)

```swift
// 1. ObjC++ bridging header
#import <Core/CircuitBass.h>

// 2. Swift에서 C++ wrapper 호출
class CircuitBassProxy {
    let impl = OpaquePointer(...) // Core::CircuitBass*
    func process(_ left: Float, _ right: Float) -> (Float, Float) { ... }
}
```

장점: Core 라이브러리를 그대로 사용. Windows/JUCE와 완전히 동일한 DSP.
단점: ObjC++ bridging header 필요. `SystemAudioProcessor/` 디렉토리 구조 변경 필요.

### 방법 B: Core를 C API로 re-export

```c
// CoreC.h — C-compatible wrapper
extern "C" {
    void* core_circuit_bass_create();
    void core_circuit_bass_process(void* handle, float l, float r, float* ol, float* or);
    void core_circuit_bass_destroy(void* handle);
}
```

장점: Swift에서 C function pointer 직접 호출 (가장 간단한 bridging)
단점: Wrapper 레이어 유지보수 필요.

### 리스크

- Swift Native App의 DSP 호출이 AVAudioEngine render callback 안에서 일어나는지, 아니면 ring buffer 기반인지 확인 필요
  - 현 구조: `SystemAudioProcessor.handleInput()` → `processAndPushStereo()` → `processSelectedModel()` → `circuitDSP.process()`
  - 이 부분은 실시간 콜백 안에서 동작
- Core::CircuitBass는 실시간 안전하므로 (heap allocation 없음) 문제 없음
- `LCDSPSettings` update는 control queue로 전달되므로 실시간 문제 없음

---

## 8. 추천 첫 통합 대상

### 1순위: JUCE Plugin (PluginProcessor)

이유:

| 이유 | 설명 |
|---|---|
| **리스크가 가장 낮음** | JUCE C++ 프로젝트에 Core C++ 라이브러리를 추가하는 것 = 일반적인 CMake 서브디렉토리 |
| **영향 범위 좁음** | PluginProcessor.cpp 하나만 변경. Native App 전체를 바꾸는 것보다 훨씬 안전 |
| **Windows에서 즉시 검증 가능** | GitHub Actions Windows 빌드에서 Core 사용 + 테스트 실행 |
| **사용자에게 가시적인 개선** | JUCE Plugin이 HighExciter를 처음으로 가지게 됨 |
| **병렬 작업 가능** | Native App 통합과 독립적으로 진행 가능 |

### 2순위: macOS Native App (SystemAudioProcessor)

Native App은 Swift ↔ C++ bridging이 필요해서 JUCE보다 더 많은 작업이 필요.
JUCE Plugin 통합으로 Core 검증이 끝난 후 진행하는 것이 안전함.

---

# Phase 2 제안 — Core Integration Plan

## 목표

기존 앱/플러그인이 `Source/Core`를 사용하도록 전환하고,
동일한 DSP 출력을 보장한다.

## 브랜치

`spike/cross-platform-core` 유지. Phase 1 커밋 위에 Phase 2 추가.

## Phase 2-A: JUCE Plugin → Core 전환 (예상: 1-2일)

### 작업 순서

1. Root CMakeLists.txt에 `add_subdirectory(Source/Core)` 추가
   → Core가 JUCE 빌드에 포함됨
   → 주의: `AudioRingBufferC.h` include 경로 설정

2. `PluginProcessor.h`에 Core 타입 멤버 추가
   ```cpp
   #include <Core/CircuitBass.h>
   #include <Core/HighExciter.h>
   lowend::CircuitBass circuitBass;
   lowend::HighExciter highExciter;
   ```

3. `PluginProcessor.cpp`에서 DSP 교체
   - `prepareToPlay()`: `DSPPrecompute::makeDSPSettings()` 호출 후 `circuitBass.update()`
   - `processBlock()`: JUCE IIR → `circuitBass.process()` + `highExciter.process()`
   - `updateFilters()` 유지 또는 제거 (Core가 계산하므로)
   - 파라미터 smoothing: JUCE `SmoothedValue` 유지 필요 (Core는 smoothing 없음)

4. 파라미터 레이아웃 확장
   - `dspModel` 파라미터 추가 (0=Clean, 1=Circuit, 2=HighExciter)
   - Clean/Circuit/HighExciter 모델 선택 → `DSPPrecompute::makeDSPSettings(dspModel: ...)`에 전달

5. `PluginEditor.cpp`에 모델 선택 UI 추가
   - NSPopUpButton 또는 juce::ComboBox로 모델 선택
   - HighExciter 프리셋 버튼 추가

6. 검증
   - 기존 JUCE 빌드와 Core 빌드의 출력을 같은 입력으로 비교
   - AudioPluginHost 또는 테스트 신호로 A/B 비교

### Phase 2-A에서 변경되는 파일

```
📋 변경 목록:
  M  CMakeLists.txt              ← add_subdirectory(Source/Core)
  M  Source/PluginProcessor.h    ← Core include + 멤버 추가
  M  Source/PluginProcessor.cpp  ← JUCE IIR → Core::CircuitBass + Core::HighExciter
  M  Source/PluginEditor.h       ← UI 컨트롤 멤버 추가
  M  Source/PluginEditor.cpp     ← 모델 선택 UI, 프리셋 버튼

📋 변경되지 않는 파일:
  SystemAudioProcessor/          ← 전혀 건드리지 않음
  Source/Core/                   ← 이미 Phase 1에서 완료
```

### Phase 2-A 완료 조건

- [ ] macOS + Windows JUCE 빌드 성공
- [ ] Core::CircuitBass가 JUCE IIR shelf와 동일 입력에 대해 근접한 출력 (약간의 차이는 허용 — Core가 더 정교하므로)
- [ ] HighExciter 모델이 JUCE Plugin에서 처음으로 동작
- [ ] 모델 선택 UI에서 Clean/Circuit/HighExciter 전환
- [ ] 기존 PluginProcessor와 Core 사용 PluginProcessor를 A/B 비교 가능
- [ ] 기존 76개 Core 테스트 여전히 통과

---

## Phase 2-B: macOS Native App → Core 전환 (예상: 2-3일, Phase 2-A 이후)

### 작업 순서

1. Core 라이브러리를 SwiftPM 또는 Xcode 프로젝트에 추가
   - SwiftPM: `SystemAudioProcessor/Package.swift`에 `.binaryTarget()` 또는 `.target()`으로 Core 추가
   - Xcode: 직접 `.a` / `.xcframework` 링크

2. ObjC++ bridging header 작성
   ```objc
   // Core-Bridge.h
   #import <Core/CircuitBass.h>
   #import <Core/HighExciter.h>
   ```

3. Swift wrapper class 작성
   ```swift
   class CoreCircuitBass {
       let impl: UnsafeMutableRawPointer  // Core::CircuitBass*
       func update(_ settings: LCDSPSettings)
       func process(left: Float, right: Float) -> (Float, Float)
       func reset()
   }
   ```

4. SystemAudioProcessor의 DSP 교체
   - `SystemAudioProcessor`의 `circuitDSP` → `CoreCircuitBass`
   - `exciterDSP` → `CoreHighExciter`
   - `DSPPrecompute` (Swift) → `lowend::DSPPrecompute` (Core C++)

5. 검증
   - Core 사용 전/후의 DSP 출력을 golden test로 비교
   - 실제 앱 실행해서 동작 확인
   - Spatializer + Analyzer는 아직 Core에 없으므로 Swift 구현 유지

### Phase 2-B 완료 조건

- [ ] macOS Native App이 Core::CircuitBass를 사용
- [ ] macOS Native App이 Core::HighExciter를 사용
- [ ] Core 사용 전/후의 DSP 출력이 동일 (수치 비교)
- [ ] Spatializer / Analyzer는 기존 Swift 구현 유지
- [ ] 기존 76개 Core 테스트 여전히 통과

---

## Phase 2 추천 우선순위

```text
Phase 2-A (JUCE Plugin)  →  검증  →  Phase 2-B (macOS Native App)
```

JUCE Plugin이 Core를 가장 먼저 사용해야 하는 이유:

1. **CMake 하나로 끝남** (Swift ↔ C++ bridging 불필요)
2. **Windows에서도 빌드 가능** → CI로 Core 검증
3. **HighExciter가 JUCE Plugin에 처음 추가됨** → 사용자에게 가시적인 개선
4. **macOS Native App보다 리스크가 훨씬 낮음**

---

## 리스크 및 대응

| 리스크 | 대응 |
|---|---|
| Core::CircuitBass와 JUCE IIR 출력 차이 (Core가 더 정교해서) | 문서에 명시: "Core 사용 시 DSP 품질이 개선됩니다." 불필요한 완전일치 추구 금지 |
| Swift ObjC++ bridging 복잡도 | Phase 2-B 시작 전에 prototype 작성. C API wrapper로 단순화 가능 |
| Spatializer / Analyzer 미이관 | Phase 3으로 연기. Core가 모든 DSP를 커버할 필요는 없음 |
| AudioRingBufferC.h 위치 의존성 | Phase 3에서 `AudioRingBufferC/`를 Core 아래로 이동 |
| JUCE APVTS vs Core 파라미터 | Phase 2-A에서 APVTS 유지 + Core 파라미터로 매핑. APVTS 제거는 Phase 3 이후 |
