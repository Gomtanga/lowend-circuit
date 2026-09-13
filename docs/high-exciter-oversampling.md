# HighExciter Oversampling

## 목적

HighExciter의 다항식 배음 생성기는 비선형 처리이므로 입력에 없던 고조파를
Nyquist 주파수 위에도 생성한다. 이 성분을 원래 샘플레이트에서 바로 계산하면
가청 대역으로 접혀 내려오는 aliasing이 발생할 수 있다.

이 구현은 음원의 해상도나 손실된 정보를 복원하는 업스케일러가 아니다.
HighExciter의 비선형 구간만 더 높은 내부 샘플레이트에서 계산해 aliasing을
줄이는 oversampling 처리다.

## 처리 흐름

```text
Input
  -> 11 kHz High-Pass
  -> 2x 또는 4x Interpolation
  -> Polynomial Harmonic Generator
  -> Anti-Alias Low-Pass
  -> Decimation
  -> 5 Hz harmonic-branch DC blocker
  -> Dry + Harmonic * Wet Mix
```

Dry 신호는 oversampling 경로를 통과하지 않는다. 따라서 Wet Mix가 0이면 기존과
동일한 원본 신호가 출력된다.

## 배율 정책

앱의 HighExciter `배음 품질` 배율과 출력 컨디셔닝의 `DAC 출력 배수`는 독립적이다. 전자는 배음 생성 뒤 원래 Tap 레이트로 돌아오고, 후자는 모델·Spatial 처리가 끝난 전체 PCM의 출력 레이트를 바꾼다. 예를 들어 Tap 48 kHz에서 HighExciter 4×와 출력 2×를 켜면 배음 구간192 kHz → Tap48 kHz → DAC96 kHz이며, 배음 생성8×를 뜻하지 않는다.

출력 헤드룸은 실제 PCM2× 출력의 보간 전에 적용되는 감쇠다. `2× 출력 중` 상태에서 동작하며 시작 전 설정은 `출력 대기`, Bypass·실시간 미구현 모드와 fallback은 `미적용`으로 구분한다. 모델 내부에서 이미 생긴 포화·배음을 되돌리는 조절은 아니다. 후단 PCM 보간도 앞단에서 이미 생긴 alias를 제거하는 대체 수단이 아니다.

| 엔진 샘플레이트 | 배율 | 내부 비선형 처리율 |
| --- | ---: | ---: |
| 44.1 kHz | 4x | 176.4 kHz |
| 48 kHz | 4x | 192 kHz |
| 88.2 kHz | 2x | 176.4 kHz |
| 96 kHz | 2x | 192 kHz |
| 176.4 kHz 이상 | 1x | 엔진 샘플레이트 |

내부 처리율을 대체로 176.4~192 kHz에 맞춰 품질과 CPU 사용량의 상한을 함께
관리한다.

## 사용자 배율 선택

macOS Native 앱에서는 `Auto`, `1x`, `2x`, `4x`를 선택할 수 있다. 기본값은
`Auto`이며 톤 DSP가 실제 사용하는 Tap 측 처리율을 기준으로 위 표의 배율을 선택한다. Live PCM 2×의 후단 output/DAC rate를 이 기준으로 사용하지 않는다. Source
메타데이터는 표시 및 Rate Matching 판단에만 사용하고 DSP 배율을 직접 결정하지
않는다.

수동 선택은 oversampling으로 내부 처리율을 `384 kHz`보다 높이지 않는 범위에서
적용된다. Engine 자체가 이미 384 kHz를 넘는 경우에는 추가 oversampling 없이
1배로 처리한다. 요청한 배율이 한도를 넘으면 설정값은 유지하되 실제 배율은
안전한 값으로 낮아진다.

| Engine | 요청 | 실제 |
| ---: | ---: | ---: |
| 96 kHz | 4x | 4x |
| 192 kHz | 4x | 2x |
| 768 kHz | 4x | 1x |

배율 변경 시 미리 할당한 두 wet 경로 중 새 경로의 interpolation/decimation
필터 상태를 초기화한다. 기존 경로와 새 경로를 함께 처리하며 256 frame 동안
출력을 crossfade한다. 기존 경로의 상태는 전환이 끝날 때까지 유지한다.
전환 중에 들어온 추가 설정은 가장 최근 값 하나를 보관하고 현재 전환이 끝난 뒤
적용한다. Swift live와 C++ portable 구현에 같은 정책을 적용한다.

## 2x Stage

각 2x 단계는 서로 독립적인 interpolation 및 decimation 필터 상태를 가진다.

Interpolation:

1. 입력 샘플에 2를 곱한다.
2. 입력 샘플과 zero sample을 차례로 필터에 넣는다.
3. 2개의 고속 샘플을 얻는다.

Decimation:

1. 2개의 고속 샘플을 anti-alias 필터에 순서대로 넣는다.
2. 한 phase만 출력해 원래 처리율로 돌아간다.

4x 모드는 두 개의 2x stage를 직렬로 연결한다.

## 필터

각 interpolation 및 decimation 필터는 두 개의 Biquad section으로 구성된
4차 Butterworth Low-Pass다.

- Q1: `0.5411961`
- Q2: `1.306563`
- Cutoff: `min(20 kHz, input sample rate * 0.40)`

계수는 `DSPPrecompute`에서만 계산한다. 샘플레이트가 바뀌면 엔진의 기존
재설정 흐름이 필터 상태를 초기화하고 새 계수를 적용한다.

## Realtime 규칙

오디오 콜백의 HighExciter 경로에서는 다음 작업을 하지 않는다.

- heap allocation 또는 collection resize
- lock, semaphore, DispatchQueue
- `sin`, `cos`, `pow` 같은 초월함수
- UI 및 ObservableObject 접근
- 로그와 파일 I/O

콜백은 미리 계산된 Biquad 계수, 고정 개수의 Float 상태, 곱셈과 덧셈만
사용한다.

## 검증 기준

- 모든 지원 샘플레이트에서 올바른 4x/2x/1x 선택
- impulse 및 sine 입력에서 NaN/Inf 미발생
- Wet Mix 0에서 bit-identical dry 반환
- 높은 Drive/Wet의 일정 sine에서 충분한 안정화 후 DC 평균 제한
- Swift live와 C++ portable 경로의 parity 및 독립 harmonic/DC fixture
- 48 kHz, 15 kHz sine 비선형 처리 시 1x보다 alias 성분 감소
- 샘플레이트 재설정 시 High-Pass와 모든 oversampling filter state reset

## 한계

- IIR 필터이므로 harmonic wet 경로에 작은 주파수별 위상 지연이 생긴다.
- 4차 필터는 CPU와 alias 억제 사이의 절충이다.
- 이 처리는 원본에 없는 고역 정보를 복원하지 않는다.
