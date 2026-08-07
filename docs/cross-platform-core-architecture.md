# LowEnd Core — Shared DSP Architecture

> 상태: **구현 완료 + 방향 전환 (2026-08)**.
> 원래는 2026-06-08의 "Cross-Platform Core Architecture" 제안이었습니다.
> macOS Native App 통합(Phase 1–2)은 구현되었고, JUCE Plugin(Phase 3)과
> Windows Adapter(Phase 4)는 2026-08에 공식 폐기되었습니다. 저장소는 이제
> **macOS Native App + portable Core** 단일 플랫폼으로 운영합니다.

---

## 1. 현재 상태

| 구성 요소 | 상태 |
|---|---|
| `Source/Core/` — C++ portable DSP (CircuitBass, HighExciter, Processor) | ✅ 구현 |
| `SystemAudioProcessor/` — macOS Native App | ✅ 메인 타깃 (`LowEndDSPCoreC` C 브리지로 Core 사용) |
| `Source/Core/test/` — C++ 단위 테스트 | ✅ CI에서 실행 |
| Swift ↔ C++ DSP parity self-test | ✅ macOS CI에서 실행 |
| JUCE Plugin (Standalone / VST3 / AU) | ❌ 폐기 (2026-08) |
| Windows Adapter / Windows Native | ❌ 폐기 (2026-08) |

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

JUCE 타깃이 폐기되면서 이제 **단일 DSP 구현**만 유지하면 됩니다. portable Core가
기준 구현이며, macOS Native App은 C 브리지(`LowEndDSPCoreC`)로 동일한 코드를
사용합니다. 이중 구현 유지비용 문제가 원천적으로 해소되었습니다.

---

## 3. Core 설계 원칙

- **float only** (double 미사용) — Swift 구현과 수치 일치
- **생성 후 힙 할당 없음** — realtime-safe
- **샘플레이트 인지** — 모든 계수 생성기가 `sampleRate`를 받음
- **전역 상태 없음** — 모든 인스턴스 독립
- **C ABI 타입** (`AudioRingBufferC.h`)이 데이터 계약
- `process()` 내부에 allocation / locking / logging / 계수 연산 없음
- HighExciter: 44.1/48 kHz에서 4x, 88.2/96 kHz에서 2x, 176.4/192 kHz 이상에서 1x

---

## 4. 참조

- [`Source/Core/README.md`](../Source/Core/README.md) — 빌드 및 테스트 방법
- [`docs/rate-matching.md`](rate-matching.md) — DAC 레이트 매칭 설계
- [`docs/roadmap-v0.2.3-v0.3.0.md`](roadmap-v0.2.3-v0.3.0.md) — v0.2.3 → v0.3.0 로드맵
