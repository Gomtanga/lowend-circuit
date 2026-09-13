# 오디오 가이드

[← 홈](../README.md) · [English](audio-guide.en.md)

## 모델과 Spatial Stage

| 기능 | 역할 | 제공 대상 |
|---|---|---|
| **Clean** | Circuit/HighExciter 톤 모델만 우회합니다. Spatial과 Output Conditioning은 독립적이므로 원본 비교 시 각각 꺼야 합니다. | LowEnd Native Audio |
| **Circuit** | `LowEnd`, `Body`, 병렬 처리 신호(Wet), 비대칭 포화, 출력 보호를 조합해 저역의 양감과 질감을 조절합니다. | LowEnd Native Audio |
| **HighExciter** | 약 11 kHz 이상의 성분에서 배음을 만들고 샘플레이트에 따라 비선형 구간의 오버샘플링 배율을 조절합니다. | LowEnd Native Audio |
| **Spatial Stage** | 가상 스피커 폭, 청취자 위치, 거리 게인, 양이간 시간차, 크로스피드를 이용해 헤드폰 공간을 조절합니다. | LowEnd Native Audio |
| **Analysis** | 16,384포인트 FFT, 128개 스펙트럼 막대, Peak, RMS, Crest Factor를 표시합니다. | LowEnd Native Audio |
| **Source 및 Rate Match** | 재생 앱이 제공하는 정보와 로그를 바탕으로 소스 포맷을 보수적으로 추정하고 DAC 후보를 보여 줍니다. | LowEnd Native Audio |

Spatial Stage는 기하학 기반의 스테레오 공간 처리 기능입니다. 방 리버브나 개인화 HRTF 렌더러가 아닙니다.

### 프리셋

프리셋은 시작점을 빠르게 고르기 위한 값입니다. Circuit 프리셋은 같은 음량으로 보정되어 있지 않으므로, 음색뿐 아니라 재생 음량 차이도 함께 들릴 수 있습니다.

#### Circuit

| 프리셋 | LowEnd | Body | Output |
|---|---:|---:|---:|
| IEM | 30% | 8% | -2.0 dB |
| Gentle | 22% | 8% | -1.0 dB |
| LowEnd | 42% | 18% | -1.8 dB |
| Deep | 54% | 22% | -2.8 dB |
| Clear | 0% | 0% | 0.0 dB |

강한 저역 설정은 클리핑을 피할 출력 헤드룸(headroom)을 확보하도록 출력값이 더 낮게 설정됩니다.

#### HighExciter

| 프리셋 | Exciter Drive | Wet Mix |
|---|---:|---:|
| Soft | 0.12 | 0.04 |
| Air | 0.22 | 0.07 |
| Detail | 0.35 | 0.11 |
| Shimmer | 0.50 | 0.16 |
| Off | 0.00 | 0.00 |

HighExciter 프리셋은 `Exciter Drive`와 `Wet Mix`만 바꿉니다. Circuit의 `Output`이나 Spatial Stage 설정은 변경하지 않습니다.

## 오버샘플링과 헤드룸

| 조절 항목 | 적용 위치 | 역할 |
|---|---|---|
| HighExciter 오버샘플링 | HighExciter의 비선형 처리 구간 내부 | 배음 생성 과정의 에일리어싱을 줄인 뒤 원래 처리 샘플레이트로 복귀 |
| 출력 컨디셔닝 → PCM Oversampling 2× | 톤 모델과 Spatial 처리 이후 | 출력 신호를 장치가 지원하는 2배 샘플레이트로 변환 |
| 출력 컨디셔닝 → 헤드룸 | 실제 활성화된 PCM 2× 출력 경로 | 출력 변환 전에 신호 레벨을 낮춰 여유 확보 |

두 오버샘플링은 적용 범위가 다르며 함께 사용할 수 있습니다. Live PCM 2×는 출력 장치가 목표 샘플레이트를 지원할 때 **44.1 → 88.2 kHz**, **48 → 96 kHz**로 동작합니다. 내장 출력이 해당 샘플레이트를 지원하면 외장 DAC 없이 사용할 수 있습니다.

헤드룸은 **PCM 2×가 실제로 활성화된 상태**에서만 소리에 반영됩니다. 꺼져 있거나 지원되지 않는 경로에서는 저장된 값만으로 감쇠하지 않습니다. 0 dB는 감쇠 없음, −6 dB는 신호 진폭의 약 절반입니다. 톤 모델에서 이미 발생한 포화를 되돌리지는 않으며, Circuit의 **Output**과는 별도입니다.

실시간 출력 범위는 PCM 2×입니다. 4×/8×, dither/noise shaping, DSD/DoP는 live 출력에 연결되어 있지 않습니다. 오프라인 실험 범위는 [개발 가이드](development.md)에 정리되어 있습니다.

## 오디오 포맷과 Rate Match

LowEnd Native Audio의 포맷 표시는 서로 다른 값을 구분합니다.

- `Tap`: Core Audio Process Tap이 전달하는 포맷
- `Engine`: 출력 그래프의 포맷. Live PCM 2×에서는 톤/Spatial DSP가 Tap rate로 처리한 뒤 2× 변환되어 이 포맷에 도달합니다.
- `DAC`: 출력 장치가 사용하는 명목 샘플레이트
- `Source`: Apple Music 또는 TIDAL에서 별도로 확인한 재생 소스 정보

`Source`는 근거에 따라 `Detected` 또는 `Inferred`로 표시됩니다. 확인할 수 없는 값은 `unknown`으로 남기며, Tap이나 DAC 값을 원본 파일의 포맷처럼 대신 표시하지 않습니다.

TIDAL은 `player.log` 변경을 파일 시스템 이벤트로 감지해 소스 포맷을 다시 확인합니다. 약 80 ms 디바운스 뒤 즉시 분석하고 로그 교체·회전 시 감시를 다시 연결하며, 이벤트를 놓친 경우에는 주기적 확인 경로가 복구를 담당합니다. `CoreaudioSink::start`와 `CoreaudioSink::close`도 재생 상태 근거로 사용하므로 TIDAL이 `media.state=active`를 늦게 쓰거나 생략하는 곡 전환도 처리할 수 있습니다.

소스 감시는 PID·로그 파일 identity·읽은 위치로 재시작과 회전을 구분합니다. 기존 로그를 현재 관측으로 다시 사용하지 않으므로 감시 시작 이후 새 playback/sink 기록이 없거나 증거가 15초 이상 갱신되지 않으면 `unknown`이 될 수 있습니다. 복수 소스가 섞이거나 실제 캡처 대상과 일치하지 않으면 자동 rate 변경을 보류합니다.

`Rate Match Preview`는 감지된 소스와 DAC가 보고한 지원 샘플레이트를 비교해 후보만 보여 주는 읽기 전용 기능입니다. DAC 설정을 직접 바꾸지 않습니다.

`자동 Rate Match`는 상세 포맷 표시와 독립된 실험 기능이며 기본값은 꺼져 있습니다. 켜면 안정적인 소스 관찰 뒤 출력 페이드 아웃, 엔진 정지, DAC 및 Engine 변경, 캡처·출력 재구성, 흐름 확인, 페이드 인 순서로 전환합니다. 다른 샘플레이트의 소스로 전환할 때 하드웨어 재동기화로 무음 구간이 생길 수 있으며, 소요 시간은 장치와 전환 결과에 따라 달라집니다. Live PCM 2×와 자동 Rate Match는 배타적인 rate 변경 모드입니다.

곡 전환 시 장치 재설정을 피하려면 자동 Rate Match를 끄고 해당 DAC가 지원하는 고정 샘플레이트로 사용하세요. 자세한 동작과 복구 조건은 [Rate Matching](rate-matching.md)과 [Source Rate Tracking and Device Lock Plan](source-rate-and-device-lock-plan.md)에 정리되어 있습니다.

## 제한사항

- DSP가 신호를 의도적으로 바꾸므로 출력은 엄밀한 의미의 비트 퍼펙트(bit-perfect)가 아닙니다.
- TIDAL의 **Use Exclusive Mode** 같은 독점 출력은 Core Audio Process Tap을 우회하거나 입력을 끊을 수 있습니다. 시스템 또는 특정 앱 처리 중에는 독점 모드를 끄세요.
- TIDAL은 공개된 원본 포맷 API를 제공하지 않습니다. 설치된 TIDAL 앱이 LowEnd Native Audio에서 인식하는 메시지를 남기지 않으면 Source가 `unknown`으로 표시될 수 있습니다.
- Apple Music 메타데이터 보조 경로는 macOS 자동화 권한을 요청할 수 있습니다.
- 특정 앱 캡처를 시작할 때 대상 앱의 Core Audio 출력 프로세스가 실행 중이어야 합니다.
- macOS 앱은 Developer ID 서명과 Apple 공증을 받지 않았습니다.
- Spatial Stage는 개인화 HRTF가 아닙니다.
