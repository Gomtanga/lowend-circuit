# LowEnd Circuit

**한국어** | [English README](README.md)

<p align="center">
  <img src="SystemAudioProcessor/Assets/LowEndNativeAudioIcon.png" width="180" alt="LowEnd Native Audio 앱 아이콘">
</p>

LowEnd Circuit는 저역 보강, 배음 생성, 헤드폰 공간음향, 실시간 신호 분석을
제공하는 오픈소스 오디오 프로젝트입니다.

저장소에는 서로 연관된 두 종류의 프로그램이 포함되어 있습니다.

- **LowEnd Native Audio**: Core Audio, AVAudioEngine, Accelerate, MetalKit,
  AppKit, SwiftUI로 만든 macOS 14.4 이상용 전체 시스템/특정 앱 오디오
  처리 프로그램
- **LowEnd Circuit JUCE 타깃**: Windows/macOS용 Standalone, VST3, macOS 전용 AU.
  Native 앱의 시스템 캡처 기능 없이 일반 오디오 장치나 DAW에서 사용합니다.

이 프로젝트는 독자적으로 설계한 DSP입니다. 특정 하드웨어나 소프트웨어
제조사와 제휴·승인 관계가 없으며, 타사의 독점 회로를 복제한 제품이 아닙니다.

## 다운로드

최신 빌드는
[GitHub Releases](https://github.com/Gomtanga/lowend-circuit/releases/latest)에서
받을 수 있습니다.

| 플랫폼 | 파일 | 용도 |
| --- | --- | --- |
| macOS 14.4 이상 | `LowEnd-Native-Audio-macOS-v0.2.2.zip` | 전체 시스템 및 특정 앱 처리 |
| Windows x64 | `LowEnd-Circuit-Standalone-Windows-v0.2.2.zip` | 일반 데스크톱 오디오 앱 |
| Windows x64 | `LowEnd-Circuit-VST3-Windows-v0.2.2.zip` | DAW/플러그인 호스트 |

> **Windows Native System Audio Processor**: macOS Native 앱의 전체 시스템 및
> 특정 앱 오디오 처리 기능은 Windows에서 아직 지원되지 않습니다. Windows
> 사용자는 JUCE 기반 Standalone(일반 데스크톱 오디오 앱)과 VST3 플러그인을
> 받을 수 있습니다. Windows Native 시스템 오디오 캡처는 추후 릴리즈에서
> 지원 예정입니다.

macOS 릴리스는 임시 서명되어 있으며 Apple 공증을 받지 않았습니다. 처음 실행이
차단되면 Finder에서 앱을 우클릭한 뒤 **열기**를 선택하세요. 오디오 캡처를
시작할 때 macOS 시스템 오디오 녹음 권한도 허용해야 합니다.

## 시스템 요구사항

### macOS LowEnd Native Audio

현재 `v0.2.2` 릴리스 최소 사양:

- macOS 14.4 이상
- Apple Silicon Mac (`arm64`), M1 이상
- 메모리 8 GB
- Metal 지원 GPU
- Core Audio 출력 장치, 헤드폰, 스피커 또는 외장 DAC
- 압축 해제와 일반 사용을 위한 약 100 MB의 여유 저장 공간

96/192 kHz 처리와 Analysis 탭을 함께 사용할 때의 권장 사양:

- Apple M2 이상
- 메모리 16 GB

Apple M5 테스트 환경에서는 FFT, Metal, SwiftUI 최적화 후 Analysis 모드의 CPU
사용률이 한 자릿수 범위로 측정됐습니다. 이는 참고 결과이며 장치, 샘플레이트,
재생 환경에 따라 동일한 성능을 보장하는 수치는 아닙니다.

현재 배포 중인 macOS `v0.2.2` 바이너리는 arm64 전용입니다. 해당 ZIP은 Intel
Mac을 지원하지 않습니다.

### Windows Standalone 및 VST3

- Windows 10 또는 Windows 11 64-bit
- 4코어 x64 프로세서 이상
- 메모리 8 GB
- 호환 오디오 장치 또는 DAW/플러그인 호스트

Windows 빌드에는 전체 시스템 및 특정 앱 Native 캡처 기능이 포함되지 않습니다.

## macOS Native 앱 빠른 시작

1. `LowEnd-Native-Audio-macOS-v0.2.2.zip`의 압축을 풉니다.
2. `LowEnd Native Audio.app`을 응용 프로그램 폴더로 옮깁니다.
3. 앱을 실행하고 macOS가 요청하는 시스템 오디오 녹음 권한을 허용합니다.
4. `Circuit`, `HighExciter`, `Clean` 중 모델을 선택합니다.
5. Circuit은 `IEM` 또는 `Gentle`, HighExciter는 `Soft` 또는 `Air`부터 권장합니다.
6. **전체 시스템 적용**을 눌러 대부분의 시스템 출력에 적용합니다.
7. 출력 장치를 바꾸거나 소리가 나오지 않으면 먼저 **중지**를 누릅니다.

특정 앱에만 적용하려면 먼저 음악을 재생하고, 앱의 기본 bundle ID를 입력한 뒤
**특정 앱 적용**을 누르세요. 현재 출력 중인 하위 오디오 프로세스도 자동으로
찾으므로 `com.tidal.desktop`을 입력하면 TIDAL의
`com.tidal.desktop.player`까지 함께 추적합니다. 하단 실행 앱 목록에서 bundle
ID를 확인할 수 있습니다. 일치하는 Core Audio 프로세스를 찾지 못하면 재생을
시작한 상태에서 다시 적용하세요.

## Windows Standalone 및 VST3 빠른 시작

### Standalone

1. `LowEnd-Circuit-Standalone-Windows-v0.2.2.zip`의 압축을 풉니다.
2. `LowEnd Circuit.exe`를 일반 데스크톱 오디오 앱으로 실행합니다.
3. JUCE 설정 패널에서 오디오 입력/출력 장치를 선택합니다.
4. `LowEnd`, `Body`, `Output` 슬라이더를 조절합니다.
5. Standalone 앱은 시스템 오디오를 캡처하지 않으며 선택한 입력 장치의
   신호를 처리합니다. macOS Native 앱의 Spatial Stage, Analysis 스펙트럼,
   특정 앱 캡처 기능은 포함되지 않습니다.

### VST3

1. `LowEnd-Circuit-VST3-Windows-v0.2.2.zip`의 압축을 풉니다.
2. `LowEnd Circuit.vst3` 폴더를 VST3 플러그인 디렉터리에 복사합니다:
   ```
   C:\Program Files\Common Files\VST3
   ```
3. DAW를 다시 시작하고 `LowEnd Circuit`을 오디오 이펙트로 불러옵니다.

## DSP 모델

### Clean

비교용 완전 Dry 경로입니다. 모델 DSP, Output 보정, 공간음향을 모두 우회합니다.

### Circuit

기본 저역 모델은 다음 처리로 구성됩니다.

- `LowEnd`가 조절하는 가변 Low-Shelf
- 서로 분리된 RC 방식 Bass/Sub-Bass 노드
- 메인 저역보다 낮은 대역에 집중되는 `Body` 주입
- Pre-Emphasis와 대칭 De-Emphasis 필터
- 트랜스포머 질감을 위한 비대칭 다항식 Saturation
- 병렬 Wet 처리와 출력 보호

`LowEnd`와 `Body`는 독립적으로 작동합니다. LowEnd는 측정 가능한 넓은 저역
Shelf를 만들고, Body는 더 좁고 낮은 서브 저역을 추가합니다.

### HighExciter

Circuit과 독립적인 고역 배음 모델입니다.

- 약 11 kHz 이상의 성분을 High-Pass Biquad로 분리
- 비선형 배음 구간만 44.1/48 kHz에서 4배, 88.2/96 kHz에서 2배
  오버샘플링하며 176.4/192 kHz 이상에서는 1배로 처리
- 비선형 처리 전후에 4차 이미징/앨리어싱 억제 필터 적용
- 상단 포맷 표시 아래에서 현재 오버샘플링 배율과 내부 처리율 확인 가능
- 빠른 다항식 배음 생성
- 원본 Dry 신호 유지
- 두 메인 슬라이더를 `Exciter Drive`, `Wet Mix`로 전환

## Circuit 프리셋

| 프리셋 | LowEnd | Body | Output |
| --- | ---: | ---: | ---: |
| IEM | 30% | 8% | -2.0 dB |
| Gentle | 22% | 8% | -1.0 dB |
| LowEnd | 42% | 18% | -1.8 dB |
| Deep | 54% | 22% | -2.8 dB |
| Clear | 0% | 0% | 0.0 dB |

강한 저역 부스트에서 헤드룸을 확보하기 위해 프리셋별 Output을 다르게 낮춥니다.
현재 프리셋은 **동일 음량으로 보정된 비교가 아닙니다**. 프리셋을 비교할 때는
DSP 차이와 재생 음량 차이가 함께 들릴 수 있다는 점에 주의하세요. 프리셋은
Spatial Stage 설정을 변경하지 않습니다.

## HighExciter 프리셋

| 프리셋 | Exciter Drive | Wet Mix |
| --- | ---: | ---: |
| Soft | 0.12 | 0.04 |
| Air | 0.22 | 0.07 |
| Detail | 0.35 | 0.11 |
| Shimmer | 0.50 | 0.16 |
| Off | 0.00 | 0.00 |

HighExciter 프리셋은 `Exciter Drive`와 `Wet Mix`만 변경합니다. Circuit의
`Output` 슬라이더는 이동시키거나 적용하지 않습니다. `Clean`은 완전한 bypass
모델이므로 프리셋 버튼이 비활성화됩니다.

## Spatial Stage

macOS Native 앱에는 헤드폰/IEM용 실시간 공간음향 기능이 포함됩니다.

- 파란 청취자 포인트를 드래그하거나 클릭해 이동
- `X`, `Z` 위치를 미터 단위로 직접 입력
- 가상 스피커 사이의 `Width` 조절
- 원본과 공간 처리 신호를 `Space`로 혼합
- **원위치**로 청취자 위치만 중앙에 복귀

가상 배치로부터 거리 게인, 양 귀 사이 시간차, 크로스피드를 계산합니다. 공간
리버브나 완전한 HRTF 렌더러는 아닙니다.

IEM 권장 시작점:

```text
X: 0.00 m
Z: 0.00 m
Width: 1.4-1.8 m
Space: 25-45%
```

위상이 거칠거나 거리가 부자연스럽다면 `Space`를 먼저 낮추세요.

## Analysis

Analysis 탭은 다음 기능을 제공합니다.

- Accelerate/vDSP 기반 16,384 포인트 Hann Window Real FFT
- 한 번의 Metal 인스턴싱 Draw로 렌더링하는 128개 로그 분포 Spectrum Bar
- Peak 및 RMS 미터
- Crest Factor (`Peak dB - RMS dB`)

분석 연산은 실시간 오디오 콜백에서 수행하지 않습니다. FFT는 Analysis 탭이
보일 때만 실행되고, Metal은 데이터가 바뀐 경우에만 렌더링하며, 미터 발행
빈도를 제한해 불필요한 SwiftUI 레이아웃 연산을 줄였습니다.

## 오디오 포맷과 독점 모드

상단 포맷 표시는 Core Audio `Tap`, DSP `Engine`, 출력 `DAC` 레이트를
구분합니다. 세 값이 같으면
`Shared Tap/Engine/DAC 96.0 kHz / 32-bit Float`처럼 나타납니다.

음악 파일 원본의 bit depth나 sample rate를 표시하는 값은 아닙니다. 공유/비독점
재생에서는 Core Audio가 앱의 출력을 공유 장치 포맷으로 변환하며, 스트리밍
서비스의 원본 파일 레이트는 Process Tap에 제공되지 않습니다.

앱은 Process Tap 포맷, 기본 출력 장치, Nominal Sample Rate 변경을 감지합니다.
포맷 변경은 즉시 표시하고 출력 처리율이 바뀌면 AVAudioEngine과 DSP 상태를
안전하게 재설정합니다.

DSP가 신호를 변경하므로 출력은 엄밀한 의미의 Bit-Perfect가 아닙니다. Tidal
**Use Exclusive Mode** 같은 독점 출력은 Core Audio Process Tap을 우회하거나
입력을 끊을 수 있습니다. LowEnd Native Audio를 사용할 때는 플레이어의 독점
모드를 끄세요.

## 실시간 처리 구조

Native 오디오 콜백에서는 다음 작업을 하지 않습니다.

- Heap allocation과 Collection resize
- Lock, Mutex, Semaphore, `DispatchQueue`
- 로그 출력과 파일 I/O
- UI 객체 및 `@Published` 접근
- 필터 계수 계산과 초월함수 연산

UI 쪽 `DSPPrecompute`가 Biquad 계수와 Scalar 파라미터를 계산합니다. 변경값은
Lock-free SPSC 제어 큐로 전달되고, 콜백은 최신 패킷을 꺼내 필터 상태를 유지한
채 필드 대입만 수행합니다. 오디오 출력과 비주얼라이저는 서로 분리된 Lock-free
링 버퍼를 사용합니다.

## macOS Native 앱 빌드

요구사항:

- macOS 14.4 이상
- Xcode Command Line Tools와 최신 Swift Toolchain

```sh
git clone https://github.com/Gomtanga/lowend-circuit.git
cd lowend-circuit
./scripts/build-native-system-audio-app.sh
open "build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd Native Audio.app"
```

명령줄 실행 도구:

```sh
./scripts/run-system-wide-lowend.sh
./scripts/list-audio-apps.sh
./scripts/run-app-lowend.sh com.spotify.client
```

실행 파일 옵션:

```text
--intensity 0...100
--body 0...100
--output dB
--model clean|circuit|highexciter
--spatial on|off
--listener-x meters
--listener-z meters
--stage-width meters
--space 0...100
```

## Standalone 및 플러그인 빌드

요구사항:

- CMake 3.22 이상
- C++17 Toolchain
- JUCE 8.0.13을 가져오기 위한 인터넷 연결

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

생성 타깃:

- 모든 플랫폼: Standalone, VST3
- macOS: Standalone, VST3, AU

Windows에서는 Standalone과 VST3만 빌드됩니다. Native 시스템
오디오 프로세서(`SystemAudioProcessor/`)는 macOS 전용이며
Windows에서는 사용할 수 없습니다.

JUCE Standalone 앱은 일반 입력/출력 장치를 사용합니다. macOS Native 앱의 Core
Audio Process Tap 기반 시스템 캡처 기능은 포함하지 않습니다.

## 현재 제한사항

- 전체 시스템/특정 앱 Native 캡처는 macOS에서만 지원합니다.
- Windows 릴리스는 현재 Standalone과 VST3만 제공합니다.
- 플레이어 독점 출력 모드는 Process Tap 캡처와 호환되지 않습니다.
- 특정 앱 캡처는 활성 하위 오디오 프로세스를 자동으로 찾지만, 캡처를 시작할
  때 해당 앱의 Core Audio 출력 프로세스가 실행 중이어야 합니다.
- macOS 릴리스는 Developer ID 서명 및 Apple 공증을 받지 않았습니다.
- Spatial Stage는 기하학 기반 Stereo Processor이며 개인화 HRTF가 아닙니다.

## 저장소 구조

```text
Source/                         JUCE 플러그인 및 Standalone 소스
SystemAudioProcessor/           macOS Native Swift/C 엔진
SystemAudioProcessor/Shaders/   Metal Spectrum Shader
SystemAudioProcessor/Assets/    Native 앱 아이콘
scripts/                        빌드 및 실행 스크립트
docs/                           추가 사용 문서
```

## 라이선스 및 제3자 조건

이 저장소는 [GNU AGPL-3.0-or-later](LICENSE)로 배포됩니다.

JUCE는 빌드 구성 시 자동으로 가져오며 자체 Dual License 조건이 적용됩니다.
바이너리를 배포하거나 JUCE 타깃을 상업적으로 사용하려면 JUCE 라이선스를
별도로 확인하세요.

제3자 명칭과 상표는 각 소유자에게 귀속됩니다. 이 프로젝트는 타사의 제품명을
브랜드로 사용하지 않으며 특정 독점 회로의 완전한 에뮬레이션을 주장하지
않습니다.
