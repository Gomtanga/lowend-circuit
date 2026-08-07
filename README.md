# LowEnd Circuit — 저역 보강과 공간 처리를 위한 오디오 DSP

**한국어** | [English](README.en.md)

[![Latest release](https://img.shields.io/github/v/release/Gomtanga/lowend-circuit?display_name=tag&sort=semver)](https://github.com/Gomtanga/lowend-circuit/releases/latest)
[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
[![Cross-Platform Core CI](https://github.com/Gomtanga/lowend-circuit/actions/workflows/cross-platform-core-ci.yml/badge.svg)](https://github.com/Gomtanga/lowend-circuit/actions/workflows/cross-platform-core-ci.yml)
[![macOS Native and Core CI](https://github.com/Gomtanga/lowend-circuit/actions/workflows/macos-native-ci.yml/badge.svg)](https://github.com/Gomtanga/lowend-circuit/actions/workflows/macos-native-ci.yml)

<p align="center">
  <img src="SystemAudioProcessor/Assets/LowEndNativeAudioIcon.png" width="180" alt="LowEnd Native Audio 앱 아이콘">
</p>

LowEnd Circuit는 저역 보강, 고역 배음 생성, 헤드폰 공간 처리, 실시간 신호 분석을 제공하는 오픈소스 오디오 DSP 프로젝트입니다. 한 저장소에서 macOS 시스템 오디오 앱과 휴대용 C++ DSP 코어(`Source/Core/`)를 함께 개발합니다.

이 프로젝트는 독자적으로 설계한 DSP입니다. 특정 하드웨어 또는 소프트웨어 제조사와 제휴하거나 승인을 받은 제품이 아니며, 타사의 독점 회로를 그대로 재현한다고 주장하지 않습니다.

## 어떤 빌드를 사용해야 하나요?

`LowEnd Circuit`는 전체 프로젝트 이름입니다. 실제로 사용하는 프로그램은 목적에 따라 달라집니다.

| 하고 싶은 일 | 선택할 프로그램 | 제공 방식 | 알아둘 점 |
|---|---|---|---|
| Mac 전체 소리 또는 특정 앱의 소리 처리 | **LowEnd Native Audio** | 미리 빌드된 macOS 앱 | macOS 14.4 이상, Apple Silicon 전용 |

프로젝트 구성은 다음과 같습니다.

```text
LowEnd Circuit
└─ LowEnd Native Audio
   └─ macOS 전체 시스템 또는 특정 앱 오디오 처리
```

## 다운로드

현재 최신 릴리스는 [v0.2.9](https://github.com/Gomtanga/lowend-circuit/releases/tag/v0.2.9)입니다. 변경 사항과 검증 결과는 릴리스 노트에서 확인할 수 있습니다.

### 미리 빌드된 파일

| 플랫폼 | 파일 | 용도 |
|---|---|---|
| macOS 14.4 이상, Apple Silicon | [`LowEnd-Native-Audio-macOS-v0.2.9.zip`](https://github.com/Gomtanga/lowend-circuit/releases/download/v0.2.9/LowEnd-Native-Audio-macOS-v0.2.9.zip) | 전체 시스템 또는 특정 앱 처리 |

이전 버전은 [GitHub Releases](https://github.com/Gomtanga/lowend-circuit/releases)에서 받을 수 있습니다.

### 배포 범위와 주의 사항

- macOS 배포 파일은 `arm64` 전용입니다. Intel Mac용 바이너리는 제공하지 않습니다.
- macOS 앱은 애드혹 서명(ad-hoc signing) 상태이며 Apple 공증을 받지 않았습니다.

## 1분 빠른 시작

### macOS: 전체 시스템 소리 처리

1. macOS ZIP 파일의 압축을 풉니다.
2. `LowEnd Native Audio.app`을 `응용 프로그램` 폴더로 옮깁니다.
3. 처음 실행이 차단되면 Finder에서 앱을 우클릭하고 **열기**를 선택합니다.
4. 앱이 요청하는 시스템 오디오 녹음 권한을 허용합니다.
5. `Circuit`, `HighExciter`, `Clean` 가운데 하나를 선택합니다.
6. 처음에는 Circuit의 `IEM` 또는 `Gentle`, HighExciter의 `Soft` 또는 `Air` 프리셋을 권장합니다.
7. **전체 시스템 적용**을 누릅니다.

출력 장치를 바꾸기 전에는 먼저 **중지**를 누르세요. 처리 중 소리가 끊기면 중지한 뒤 다시 적용하세요.

### macOS: 특정 앱만 처리

1. 대상 앱에서 오디오 재생을 시작합니다.
2. LowEnd Native Audio에 기본 번들 ID를 입력합니다.
3. **특정 앱 적용**을 누릅니다.

앱 아래쪽의 실행 목록에서 번들 ID를 확인할 수 있습니다. `com.tidal.desktop`처럼 기본 앱 ID를 입력하면 현재 재생 중인 하위 오디오 프로세스도 찾습니다. 일치하는 Core Audio 프로세스가 없으면 재생을 시작한 상태에서 다시 적용하세요.

## 핵심 기능

| 기능 | 역할 | 제공 대상 |
|---|---|---|
| **Clean** | 모델 DSP와 공간 처리를 우회해 처리 전 원본 신호(Dry)를 비교합니다. | LowEnd Native Audio |
| **Circuit** | `LowEnd`, `Body`, 병렬 처리 신호(Wet), 비대칭 포화, 출력 보호를 조합해 저역의 양감과 질감을 조절합니다. | LowEnd Native Audio |
| **HighExciter** | 약 11 kHz 이상의 성분에서 배음을 만들고 샘플레이트에 따라 비선형 구간의 오버샘플링 배율을 조절합니다. | LowEnd Native Audio |
| **Spatial Stage** | 가상 스피커 폭, 청취자 위치, 거리 게인, 양이간 시간차, 크로스피드를 이용해 헤드폰 공간을 조절합니다. | LowEnd Native Audio |
| **Analysis** | 16,384포인트 FFT, 128개 스펙트럼 막대, Peak, RMS, Crest Factor를 표시합니다. | LowEnd Native Audio |
| **Source 및 Rate Match** | 재생 앱이 제공하는 정보와 로그를 바탕으로 소스 포맷을 보수적으로 추정하고 DAC 후보를 보여 줍니다. | LowEnd Native Audio |

Spatial Stage는 기하학 기반의 스테레오 공간 처리 기능입니다. 방 리버브나 개인화 HRTF 렌더러가 아닙니다.

### 프리셋

프리셋은 시작점을 빠르게 고르기 위한 값입니다. Circuit 프리셋은 같은 음량으로 보정되어 있지 않으므로, 음색뿐 아니라 재생 음량 차이도 함께 들릴 수 있습니다.

<details>
<summary>Circuit 및 HighExciter 프리셋 수치 보기</summary>

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

</details>

## 오디오 포맷과 Rate Match

LowEnd Native Audio의 포맷 표시는 서로 다른 값을 구분합니다.

- `Tap`: Core Audio Process Tap이 전달하는 포맷
- `Engine`: DSP 엔진의 처리 포맷
- `DAC`: 출력 장치가 사용하는 명목 샘플레이트
- `Source`: Apple Music 또는 TIDAL에서 별도로 확인한 재생 소스 정보

`Source`는 근거에 따라 `Detected` 또는 `Inferred`로 표시됩니다. 확인할 수 없는 값은 `unknown`으로 남기며, Tap이나 DAC 값을 원본 파일의 포맷처럼 대신 표시하지 않습니다.

`Rate Match Preview`는 감지된 소스와 DAC가 보고한 지원 샘플레이트를 비교해 후보만 보여 주는 읽기 전용 기능입니다. DAC 설정을 직접 바꾸지 않습니다.

`자동 Rate Match`는 전문가 모드에서만 보이는 실험 기능이며 기본값은 꺼져 있습니다. 켜면 안정적인 소스 관찰 뒤 출력 페이드 아웃, 엔진 정지, DAC 및 Engine 변경, 캡처·출력 재구성, 흐름 확인, 페이드 인 순서로 전환합니다. 하드웨어가 다시 동기화되는 동안 곡이 바뀔 때마다 약 1~2초 동안 소리가 나지 않을 수 있습니다.

끊김 없는 재생이 우선이라면 자동 Rate Match를 끄고 DAC를 96 kHz 또는 192 kHz처럼 고정된 값으로 사용하세요. 자세한 동작과 복구 조건은 [Rate Matching](docs/rate-matching.md)과 [Source Rate Tracking and Device Lock Plan](docs/source-rate-and-device-lock-plan.md)에 정리되어 있습니다.

## 먼저 알아둘 제한사항

- DSP가 신호를 의도적으로 바꾸므로 출력은 엄밀한 의미의 비트 퍼펙트(bit-perfect)가 아닙니다.
- TIDAL의 **Use Exclusive Mode** 같은 독점 출력은 Core Audio Process Tap을 우회하거나 입력을 끊을 수 있습니다. 시스템 또는 특정 앱 처리 중에는 독점 모드를 끄세요.
- TIDAL은 공개된 원본 포맷 API를 제공하지 않습니다. 설치된 TIDAL 앱이 LowEnd Native Audio에서 인식하는 메시지를 남기지 않으면 Source가 `unknown`으로 표시될 수 있습니다.
- Apple Music 메타데이터 보조 경로는 macOS 자동화 권한을 요청할 수 있습니다.
- 특정 앱 캡처를 시작할 때 대상 앱의 Core Audio 출력 프로세스가 실행 중이어야 합니다.
- macOS 앱은 Developer ID 서명과 Apple 공증을 받지 않았습니다.
- Spatial Stage는 개인화 HRTF가 아닙니다.

## 시스템 요구사항

| 대상 | 최소 사양 | 권장 또는 추가 조건 |
|---|---|---|
| LowEnd Native Audio | macOS 14.4 이상, Apple Silicon M1 이상, 메모리 8 GB, Metal 지원 GPU, 약 100 MB의 여유 공간 | 96/192 kHz와 Analysis를 함께 쓸 때 Apple M2 이상 및 메모리 16 GB 권장 |

표의 사양은 모든 장치, 샘플레이트, 버퍼 크기에서 같은 성능을 보장하는 벤치마크가 아닙니다.

## 상세 문서

| 문서 | 내용 |
|---|---|
| [System-Wide and Per-App Use](docs/system-wide-and-per-app.md) | macOS 전체 시스템 및 특정 앱 처리 |
| [Rate Matching](docs/rate-matching.md) | 자동 샘플레이트 전환과 복구 흐름 |
| [HighExciter Oversampling](docs/high-exciter-oversampling.md) | 배율 정책, 필터, 실시간 처리 규칙 |
| [Source Format Validation](docs/source-format-validation-2026-06-11.md) | Apple Music·TIDAL 소스 감지 검증 기록 |
| [Source Rate Tracking and Device Lock Plan](docs/source-rate-and-device-lock-plan.md) | Source, 자동 전환, Device Lock 설계 |
| [Cross-Platform Core Architecture](docs/cross-platform-core-architecture.md) | Swift·C++ DSP 코어 통합 설계와 이행 계획 |
| [GitHub Releases](https://github.com/Gomtanga/lowend-circuit/releases) | 버전별 변경 사항, 배포 파일, 검증 결과 |

설계 문서와 날짜가 붙은 검증 기록은 작성 당시의 상태를 담고 있습니다. 현재 동작을 확인할 때는 최신 코드와 릴리스 노트를 함께 보세요.

## 소스에서 빌드

### LowEnd Native Audio

macOS 14.4 이상과 최신 Xcode 명령줄 도구 또는 Swift 도구 체인이 필요합니다.

```sh
git clone https://github.com/Gomtanga/lowend-circuit.git
cd lowend-circuit
./scripts/build-native-system-audio-app.sh
open "build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd Native Audio.app"
```

명령줄에서 전체 시스템 또는 특정 앱 모드를 시험할 때는 다음 도구를 사용할 수 있습니다.

```sh
./scripts/run-system-wide-lowend.sh
./scripts/list-audio-apps.sh
./scripts/run-app-lowend.sh com.spotify.client
```

## 검증

이 저장소의 CI는 휴대용 C++ Core, Swift 지원 검사, Swift·C++ DSP 비교, LowEnd Native Audio 빌드를 나누어 검사합니다. 로컬에서는 필요한 범위에 맞춰 다음 명령을 사용할 수 있습니다.

```sh
cmake -S Source/Core -B build/core-tests -DLOWEND_CORE_BUILD_TESTING=ON
cmake --build build/core-tests --parallel
ctest --test-dir build/core-tests --output-on-failure
```

macOS에서는 다음 검사도 실행할 수 있습니다.

```sh
swift run --package-path SystemAudioProcessor LowEndSupportChecks
swift run --package-path SystemAudioProcessor SystemAudioProcessor --self-test
```

실시간 오디오 콜백은 메모리 할당, 잠금, 로그 및 파일 입출력, UI 접근, 필터 계수 계산을 하지 않도록 설계되어 있습니다. 자세한 구조는 소스와 [Cross-Platform Core Architecture](docs/cross-platform-core-architecture.md)를 참고하세요.

## 문제 신고와 기여

버그와 기능 제안은 [GitHub Issues](https://github.com/Gomtanga/lowend-circuit/issues)에 남겨 주세요. 오디오 문제는 환경에 따라 재현 조건이 달라지므로 가능한 범위에서 다음 정보를 포함하면 좋습니다.

- 운영체제와 버전
- CPU와 앱 버전
- 입력·출력 장치 및 DAC 모델
- 샘플레이트와 버퍼 설정
- 선택한 모델과 프리셋
- 전체 시스템 또는 특정 앱 가운데 사용한 방식
- 독점 모드와 자동 Rate Match 사용 여부
- 재현 순서와 기대한 결과
- 관련 로그 또는 화면 캡처

로그를 첨부하기 전에는 계정 정보, 사용자 이름, 개인 경로, 재생 기록처럼 공개할 필요가 없는 내용을 지우세요.

변경을 제안할 때는 영향을 받는 플랫폼, 실행한 검사, 확인하지 못한 항목을 함께 적어 주세요. Pull Request에서는 저장소의 macOS 및 크로스 플랫폼 CI가 실행됩니다.

## 저장소 구조

```text
Source/Core/                    테스트 가능한 휴대용 Circuit·HighExciter DSP
SystemAudioProcessor/           macOS Native Swift·C 엔진
SystemAudioProcessor/Shaders/   Metal 스펙트럼 셰이더
SystemAudioProcessor/Assets/    Native 앱 아이콘
scripts/                        빌드 및 실행 도구
docs/                           사용법, 설계, 검증 기록
```

## 라이선스와 제3자 조건

이 저장소는 [GNU AGPL-3.0-or-later](LICENSE)에 따라 배포됩니다.

제3자의 이름과 상표는 각 소유자에게 귀속됩니다. 이 프로젝트는 특정 회사의 제품명을 프로젝트 브랜드로 사용하거나 독점 회로의 정확한 에뮬레이션을 주장하지 않습니다.
