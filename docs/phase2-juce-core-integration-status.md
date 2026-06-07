# Phase 2 — JUCE Plugin Core Integration Status

> 2026-06-08
> 브랜치: `spike/cross-platform-core`
> 다음: Windows Native Prototype → `spike/windows-native-prototype`

---

## 1. 현재까지 완료된 작업

### Phase 1 — Core Library (Source/Core/)

| 컴포넌트 | 상태 | 테스트 |
|---|---|---|
| Biquad (Direct Form I) | ✅ | golden test 15 |
| OnePole (RC lowpass) | ✅ | golden test (별도 파일) |
| DSPPrecompute (coefficient 계산) | ✅ | sanity test 33 |
| CircuitBass (full circuit bass model) | ✅ | behavioral test 14 |
| HighExciter (harmonic exciter) | ✅ | behavioral test 14 |
| **Core 합계** | **✅ 76/76** | **모든 테스트 통과** |

### Phase 2 — JUCE Plugin Core Integration

| 단계 | 내용 | 상태 |
|---|---|---|
| Step 1 | Core library JUCE 빌드 연결 (`add_subdirectory` + link) | ✅ |
| Step 2 | Core include-only 검증 (PluginProcessor.h에 include) | ✅ |
| Step 3 | Core CircuitBass 멤버 + prepareToPlay 초기화 | ✅ |
| Step 4 | Core CircuitBass A/B switch (processBlock) | ✅ |
| Step 5 | HighExciter Plugin 연결 | ❌ 보류 |
| Step 6 | Core 경로 기본값 전환 | ❌ 보류 |

### Phase 2 커밋

```
49ddcc1  phase2: wire Core CircuitBass into JUCE Plugin (init only)
445eee2  phase2: add A/B switch for Core CircuitBass processing
```

---

## 2. A/B Switch 상세

### 기본값

```cpp
// PluginProcessor.h
static constexpr bool kUseSharedCoreCircuitBass = false;
```

`false` = 기존 JUCE IIR shelf + LP + tanh 처리. DAW 호환성 완전 유지.

### Core 경로 활성화

```cpp
kUseSharedCoreCircuitBass = true;  // 로컬에서만 변경, 커밋 금지
```

### Core 경로의 처리 흐름

```
dry buffer
  → Core::CircuitBass::process()  ← full circuit model
  → post-blend: dry + (coreOut - dry) * (JUCE mix / 100)
  → outputGain (from JUCE output parameter)
  → buffer write
```

### mix 파라미터 호환성

JUCE의 `mix` (0-100) 파라미터는 Core 경로에서도 dry/wet post-blend로 유지됨.
Core 내부 wetMix (DSPPrecompute에서 intensity+body로 계산)와는 별도로 동작.

### HighExciter

Core 라이브러리에는 구현되어 있지만, JUCE Plugin UI/파라미터에는 추가되지 않음.
`DSPPrecompute::makeDSPSettings(dspModel=2)`로 호출 가능하나 PluginEditor에서 모델 선택 UI가 없으므로 무의미.

---

## 3. 빌드 검증

| 타겟 | 상태 |
|---|---|
| Core standalone test (`cmake -S Source/Core -B build -DBUILD_TESTING=ON`) | ✅ 76/76 |
| LowEndCircuit Standalone | ✅ |
| LowEndCircuit AU | ✅ |
| LowEndCircuit VST3 | ✅ |

---

## 4. 기존 시스템 영향

| 항목 | 영향 |
|---|---|
| DAW session 호환성 | ❌ 없음 (기본 경로 변경 없음) |
| public parameter ID | ❌ 변경 없음 |
| macOS Native App | ❌ 수정 없음 |
| Windows 빌드 | ❌ 변경 없음 |
| Release/tag | ❌ 변경 없음 |

---

## 5. 향후 방향

| 작업 | 우선순위 | 상태 |
|---|---|---|
| Windows Native Prototype | 🔴 최우선 | 다음 브랜치: `spike/windows-native-prototype` |
| HighExciter Plugin 추가 | 🟡 낮음 | Core는 완료, Plugin UI 작업 필요 |
| Core 기본값 전환 | 🟡 낮음 | A/B 비교 후 결정 |
| Spatializer Core 이식 | ⚪ 보류 | |
| macOS Native App Core 전환 | ⚪ 보류 | |
| Core CI 테스트 | ⚪ 보류 | |
