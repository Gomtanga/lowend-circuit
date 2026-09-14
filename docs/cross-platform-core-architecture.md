# LowEnd Core — Shared DSP Architecture

> 상태: **현재 소스 구조 정정 (2026-09-07)**.
> 원래는 2026-06-08의 "Cross-Platform Core Architecture" 제안이었습니다.
> C++ portable Core와 C 브리지는 존재하지만 Native live DSP는 Swift 경로이며, JUCE Plugin(Phase 3)과
> Windows Adapter(Phase 4)는 2026-08에 공식 폐기되었습니다. 저장소는 이제
> **macOS Native App + portable Core** 단일 플랫폼으로 운영합니다.

---

## 1. 현재 상태

| 구성 요소 | 상태 |
|---|---|
| `Source/Core/` — C++ portable DSP (CircuitBass, HighExciter, Processor, SpatialGeometry, **SpatialProcessor**) | ✅ 구현 |
| `SystemAudioProcessor/` — macOS Native App | 메인 타깃. 톤 DSP는 `TonalDSP.swift` |
| `Source/Core/test/` — C++ 단위 테스트 | ✅ CI에서 실행 (Ubuntu + Windows) |
| Swift ↔ C++ DSP parity self-test | ✅ macOS CI에서 실행 |
| `Windows/` — WASAPI 기반 Windows CLI | ✅ Phase 2 구현, 로컬 검증 진행 중 |
| JUCE Plugin (Standalone / VST3 / AU) | ❌ 폐기 (2026-08) |
| Windows Adapter / Windows Native (구 계획) | ❌ 폐기 (2026-08), [`windows-port-plan.md`](windows-port-plan.md)로 대체 |

---

## 2. DSP 통합 분석 (역사적 기록)

제안 당시 핵심 발견: Swift DSP와 JUCE DSP는 **완전히 다른 알고리즘**이었습니다.

| 특성 | Swift DSP (VirtualCircuitBassDSP) | JUCE DSP (PluginProcessor) |
|---|---|---|
| Bass 처리 | Low-Shelf + RC Bass/Sub-bass pole + feedback | Low-Shelf (JUCE IIR) |
| Saturation | Asymmetric polynomial + pre/de-emphasis | `tanh` 기반 clamp |
| Body | Frequency-weighted injection | `tanh(sub * 2.4) * 0.18 * body` |
| Sub | RC one-pole 38 Hz | Biquad low-pass 135 Hz |
| Output 보호 | Headroom + makeup + wet mix | 고정 headroom + tanh |
| HighExciter | 별도 DSP 클래스 | 없음 |
| Spatializer | Delay line + crossfeed | 없음 |

JUCE 타깃 폐기는 Native의 Swift 톤 DSP와 C++ portable DSP를 하나의 구현으로 합치지 않았습니다. 실제 callback은 `VirtualCircuitBassDSP`와 `HighExciterDSP`를 호출하며 두 클래스는 `TonalDSP.swift`에 있습니다. `SharedDSPCore`/`LowEndDSPCoreC`의 톤 processor는 parity self-test에서 비교합니다. 톤 계산을 수정하면 두 경로와 독립 expected fixture를 함께 갱신해야 합니다.

공간 geometry는 `Source/Core/src/SpatialGeometry.cpp`의 순수 함수를 C ABI로 공유하고,
런타임 delay/mix는 `Source/Core/src/SpatialProcessor.cpp`가 담당합니다. 이 클래스는
플랫폼 독립 알고리즘이므로 `Source/Core`에 두었고, **Windows 엔진은 이 구현을 직접 사용**합니다.

현재 상태를 정확히 구분하면:

| 경로 | 런타임 delay/mix 구현 | 상태 |
|---|---|---|
| Windows (`Windows/`) | `lowend::SpatialProcessor` (`Source/Core`) | ✅ 사용 중 |
| macOS live callback | `Spatializer` (`SpatialDSP.swift`) | ⚠️ 아직 Swift 구현을 사용 |

즉 두 플랫폼이 **아직 하나의 구현을 공유하지는 않습니다.** `SpatialProcessor`는
`SystemAudioProcessor/Package.swift`의 `LowEndDSPCoreC` 타깃에 아직 포함되지 않았고,
macOS live 경로를 이 구현으로 옮기는 작업은 별도 범위입니다(옮기려면 패리티 회귀를
기존 macOS CI에서 함께 검증해야 합니다).

### 이식 충실성 근거

런타임 교차 검증(Swift ↔ C++ 동일 입력 비교)은 이 워크스테이션에서 불가능합니다 — macOS와
Swift 도구 체인이 없습니다. 대신 다음 세 가지로 근거를 남깁니다:

1. **구조·연산 순서 일치**: `SpatialProcessor::process`가 `Spatializer.process`와 같은 순서로
   동작함을 소스 대조로 확인했습니다. 양쪽 모두 (a) 두 delay line에 먼저 write, (b) mix
   ramp, (c) `progress` 계산, (d) `ll/lr/rl/rr` 동일 라우팅의 tap, (e) 전환 카운터 갱신,
   (f) activation 0이면 원본 반환, (g) `left*(1-amount) + wet*0.82*amount` 후
   `tanh(x*1.02)/1.02` 블렌드. 상수(0.82, 1.02), `transitionFrames = 256`,
   `delayCapacity = 8192`도 동일합니다. `DelayLine`의 5개 메서드도 1:1 대응합니다.
2. **macOS가 쓰는 컴파일러에서 검증**: Clang(`clang++`)으로 Core 전체를 빌드해
   **11/11 테스트 통과, 경고 0**. macOS CI도 Clang을 사용하므로, 새로 옮긴 코드가
   MSVC 전용이 아님을 확인했습니다. GCC에서도 동일하게 11/11 통과, 경고 0입니다.
3. **독립 기준 모델 검사**: `test_spatial_processor.cpp`가 기대값을 구현이 아니라 계약에서
   계산해 impulse 위치·경로 라우팅·전환·리셋·비유한 입력을 검사합니다.

다만 (1)은 소스 대조이고 (2)(3)는 C++ 쪽 자체 검증이므로, **Swift 구현과 지속적으로 같은
결과를 낸다는 보장은 아닙니다.** 이를 보장하려면 macOS CI에 두 구현을 비교하는 회귀를
추가해야 합니다.

`SpatialProcessor`는 `LCSpatialSettings`(C ABI POD)를 직접 입력으로 받으므로 어떤 플랫폼
헤더에도 의존하지 않습니다. geometry의 공유와 톤 processor의 공통화는 서로 다른 범위입니다.

출력 레이트 처리(PCM 2× polyphase 리샘플러와 conditioning 스테이지)도 같은 이유로
`Source/Core`의 `PcmResampler`/`OutputConditioning`에 있습니다. macOS의 `PCMResampler.swift`가
`vDSP`와 스칼라 두 커널을 제공하고 두 결과가 동일하다고 문서화하므로, 이식 시 Accelerate 의존은
넘기지 않고 스칼라 경로만 옮겼습니다. 프로토타입 설계(입력 주기 기준 sinc, Blackman 창,
per-phase DC 정규화, 탭 역순 저장)와 계수 계산은 macOS 구현과 동일합니다.

여기서도 현재 상태는 위 표와 같습니다: Windows가 Core 구현을 사용하고, macOS live 경로는
아직 Swift 구현을 사용합니다.

---

## 3. Core 설계 원칙

- **Float sample I/O**, 저역 shelf 계수와 상태는 Double — 고율 저역 응답 정밀도 보존
- **생성 후 힙 할당 없음** — realtime-safe
- **샘플레이트 인지** — 모든 계수 생성기가 `sampleRate`를 받음
- **전역 상태 없음** — 모든 인스턴스 독립
- **C ABI 타입** (`AudioRingBufferC.h`)이 데이터 계약
- `process()` 내부에 allocation / locking / logging / 계수 연산 없음
- HighExciter Auto: 실제 tap 측 처리율 44.1/48 kHz에서 4x, 88.2/96 kHz에서 2x, 176.4/192 kHz 이상에서 1x
- Live PCM 2×는 HighExciter 내부 배율과 별도의 후단 출력 변환이다.
- Spectrum FFT/history는 전용 worker가 소유하고, immutable meter 수치만 MainActor로 보낸다. GPU buffer는 command completion 후에만 재사용한다.
- SPSC ring clear/destroy는 생산자와 소비자의 정지가 전제다. 실행 중 분석 데이터 폐기는 consumer가 요청을 처리한다.

---

## 4. 참조

- [`Source/Core/README.md`](../Source/Core/README.md) — 빌드 및 테스트 방법
- [`docs/rate-matching.md`](rate-matching.md) — DAC 레이트 매칭 설계
- [`docs/roadmap-v0.2.3-v0.3.0.md`](roadmap-v0.2.3-v0.3.0.md) — v0.2.3 → v0.3.0 로드맵
