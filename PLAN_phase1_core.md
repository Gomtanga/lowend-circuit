# Phase 1 — Core Library: 분석 결과 + 설계 제안

## 현재 DSP 중복 분석

### JUCE Plugin (PluginProcessor.cpp) — 4개 파라미터, 1개 DSP 모델

| 항목 | 상세 |
|---|---|
| 파라미터 | intensity(0-100), body(0-100), mix(0-100), output(-18~+6dB) |
| DSP 엔진 | JUCE `dsp::IIR::Filter` (makeLowShelf, makeLowPass) |
| 하모닉 | `tanh(sub * 2.4) * 0.18 * body` |
| 아웃풋 | `tanh(blended * outputGain * 1.05) / 1.05` |
| 프리셋 | 4개 (Gentle/LowEnd/Deep/Reset), intensity/body/mix/output 하드코드 |
| HighExciter | ❌ 없음 |
| Spatializer | ❌ 없음 |
| 상태 저장/복원 | JUCE `AudioProcessorValueTreeState` 자동 |
| **DSP 복잡도** | 낮음 (~60줄) |

### Swift DSP (main.swift) — 8+ 파라미터, 3개 DSP 모델

| 항목 | 상세 |
|---|---|
| 파라미터 | intensity(0-100), body(0-100), output(-18~+6), model(clean/circuit/highexciter), spatial 5개 |
| DSP 엔진 | 자체 Biquad + OnePole (custom 구현) |
| Bass 모델 | VirtualCircuitBassDSP: shelf + 2-stage RC + pre/de-emphasis + 비대칭 saturation + feedback |
| 하모닉 | 동일 + subNode * bodyInjectionGain + bodyInjectionGain (0.46~0.52) |
| HighExciter | 독립 DSP: HP biquad + polynomial harmonic generator |
| Spatializer | 4-path delay line + crossfeed + 거리 기반 gain |
| 아웃풋 | `fastClamp(blended * outputGain)`, `tanh(clamp * 1.02)/1.02` |
| 프리셋 | 모델별 5개씩 (Circuit: IEM/Gentle/LowEnd/Deep/Clear, HighExciter: Soft/Air/Detail/Shimmer/Off) |
| 상태 저장/복원 | `LCDSPSettings` + control queue |
| **DSP 복잡도** | 높음 (~300줄) |

### 핵심 차이점

```text
동일한 "intensity=50, body=30, output=-1.5" 입력이 주어져도
PluginProcessor와 VirtualCircuitBassDSP는 완전히 다른 출력을 냅니다.

이유:
- JUCE: JUCE IIR 저역필터 + low-shelf
- Swift: custom Biquad + custom RC one-pole + transformer saturation 회로

이는 현재 "LowEnd Circuit" VST3와 "LowEnd Native Audio"가
같은 DSP 결과를 보장하지 않는다는 뜻입니다.
```

## 설계 결정: AudioRingBufferC.h를 타입 계약(Type Contract)으로 활용

이미 존재하는 C 헤더를 재활용하는 게 가장 현명함:

```
AudioRingBufferC.h → LC* 타입들 → Core C++에서 include → 모든 플랫폼 공유
```

굳이 새 타입을 만들 필요 없음. `LCDSPSettings`가 이미 DSP 파라미터 전부를 커버하고 있고, C ABI라서 Swift/JUCE/Windows C++ 모두에서 사용 가능.

## 제안 디렉토리 구조

```
Source/Core/
├── CMakeLists.txt               ← Core 전용 CMake (정적 라이브러리)
├── include/
│   └── Core/
│       └── Core.h               ← 통합 헤더 (Core::* 네임스페이스)
├── src/
│   ├── Biquad.cpp / .h          ← Direct Form I biquad
│   ├── OnePole.cpp / .h         ← RC one-pole lowpass
│   ├── CircuitBass.cpp / .h     ← VirtualCircuitBassDSP (이식)
│   ├── HighExciter.cpp / .h     ← HighExciterDSP (이식)
│   ├── Spatializer.cpp / .h     ← Spatializer + DelayLine (이식)
│   ├── Analyzer.cpp / .h        ← FFT spectrum (pluggable backend)
│   └── DSPPrecompute.cpp / .h   ← coefficient 계산 (DSPPrecompute 이식)
├── test/
│   ├── CMakeLists.txt           ← 테스트 전용 CMake
│   ├── test_biquad.cpp
│   ├── test_circuit_bass.cpp
│   ├── test_highexciter.cpp
│   ├── test_spatializer.cpp
│   └── test_precompute.cpp
└── README.md                    ← Core 사용법
```

### AudioRingBufferC와의 관계

기존:
```
SystemAudioProcessor/
  Sources/
    AudioRingBufferC/        ← macOS Swift 전용 위치
```

제안 (변경 없음 — Phase 1에서는 움직이지 않음):
```
AudioRingBufferC/ 위치는 그대로 두고,
Source/Core/CMakeLists.txt에서
  include_directories(../../SystemAudioProcessor/Sources/AudioRingBufferC/include)
로 참조만 함.
```

### JUCE Plugin이 Core를 사용하는 경로 (Phase 3 이후)

```
PluginProcessor.cpp
  └── #include <Core/Core.h>
      └── Core::CircuitBass + Core::HighExciter
          (JUCE dsp::IIR::Filter 제거)
```

기존 `PluginProcessor.cpp`는 JUCE `AudioProcessor` 프레임워크만 유지하고 DSP 알고리즘은 `Core::`로 대체.

### macOS Native App이 Core를 사용하는 경로 (Phase 2 이후)

```
main.swift
  └── bridging header
      └── Core::CircuitBass (C++ → Swift 호출)
```

구체적인 방법:
1. Core 라이브러리를 `.a` (static lib)로 빌드
2. Xcode 프로젝트 / SwiftPM에 추가
3. ObjC++ bridging header로 C++ 클래스 wrapping
4. Swift에서 `CoreCircuitBass` ObjC 클래스 호출

또는 더 간단한 방법:
- Core를 C-compatible C API로 export
- Swift가 C function pointer 직접 호출

### Windows Native App이 Core를 사용하는 경로 (Phase 4 이후)

```
WindowsAdapter/main.cpp
  └── #include <Core/Core.h>
      └── Core::CircuitBass + Core::Spatializer
```

CMake 하나로 끝. Core는 C++17 + stdatomic만 쓰므로 MSVC / Clang 둘 다 OK.

## 이번 커밋 범위 (Phase 1 — 최소 스켈레톤)

아래 파일들만 생성:

```
Source/Core/
├── CMakeLists.txt               ← Core 빌드 + 테스트 빌드
├── include/Core/Core.h          ← 네임스페이스, 타입 define, LC* 타입 include
├── src/
│   ├── Biquad.h                 ← 템플릿/인라인 헤더 (type + process + update)
│   ├── Biquad.cpp               ← makeLowShelf, makeLowPass, makeHighPass
│   ├── OnePole.h                ← 템플릿/인라인 헤더
│   ├── OnePole.cpp              ← makeRcAlpha
│   ├── DSPPrecompute.h          ← 함수 선언
│   └── DSPPrecompute.cpp        ← makeDSPSettings, makeSpatialSettings
├── test/
│   ├── CMakeLists.txt           ← test executable
│   ├── test_biquad.cpp          ← impulse response golden test
│   └── test_precompute.cpp      ← makeDSPSettings sanity check
└── README.md
```

**명시적으로 포함하지 않는 것:**
- `CircuitBass.cpp/.h` — 다음 스텝 (Phase 1 확장)
- `HighExciter.cpp/.h` — 다음 스텝
- `Spatializer.cpp/.h` — 다음 스텝
- `Analyzer.cpp/.h` — 다음 스텝
- 기존 파일 수정 전혀 없음
- `CMakeLists.txt` 루트 수정 없음 (Core는 독립 CMake)

## 검증 방법

```bash
# 1. Core standalone build
cmake -S Source/Core -B build/core -DBUILD_TESTING=ON
cmake --build build/core

# 2. Core 테스트 실행
cd build/core && ctest --output-on-failure
```

---

진행해도 될까? 이 계획이 마음에 들면 바로 파일 생성 들어간다.
