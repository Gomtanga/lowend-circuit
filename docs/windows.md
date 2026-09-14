# Windows 개발 가이드

[← 홈](../README.md) · [개발 가이드](development.md) · [Windows 포팅 계획](windows-port-plan.md)

Windows용 LowEnd Circuit은 **CLI**와 **GUI** 두 가지 front end를 제공합니다. 둘 다 같은
`lowend_engine` 라이브러리를 사용하며, Windows 오디오 장치에서 입력 또는 시스템 오디오를 받아
`Source/Core`의 C++ DSP로 처리한 뒤 출력 장치로 전달합니다.

> 상태: **Phase 4 (GUI) 구현 완료, 로컬 검증 진행 중**. 검증 범위는
> [검증 범위](#검증-범위)를 참고하세요.

## 요구 사항

| 항목 | 내용 |
|---|---|
| OS | Windows 10 2004 (빌드 19041) 이상. 로컬 검증은 Windows 11 (26200)에서 수행했습니다. |
| 아키텍처 | **x64만**. 32비트 Windows는 지원하지 않습니다. `AudioRingBufferC.c`의 `atomic_uint_fast64_t`가 32비트에서 lock-free라는 보장이 없기 때문입니다. |
| 빌드 도구 | Visual Studio 2022 이상 (**Desktop development with C++** 워크로드) + Windows SDK. CMake는 Visual Studio에 포함된 것을 사용합니다. |
| 런타임 | 관리자 권한 불필요. 일반 사용자 앱입니다. GUI는 추가 런타임 의존성이 없습니다(Win32 + common controls 6). |

## 빌드와 검사

```bat
scripts\build-windows-cli.bat Release
```

이 스크립트는 `vswhere`로 Visual Studio를 찾아 `vcvars64.bat`을 호출하고, CMake 구성 →
빌드 → `ctest` → CLI 인자 회귀 검사까지 수행합니다. 전부 오프라인 검사이며 오디오 장치를
열지 않습니다. GUI 타깃(`lowend_gui.exe`)도 함께 빌드됩니다.

직접 빌드하려면:

```bat
cmake -S Windows -B build\win-cli -DLOWEND_WINDOWS_BUILD_TESTING=ON
cmake --build build\win-cli --config Release --parallel
ctest --test-dir build\win-cli -C Release --output-on-failure
```

GUI 없이 CLI만 빌드하려면 `-DLOWEND_WINDOWS_BUILD_GUI=OFF`를 추가합니다.

## GUI 사용

```bat
build\win-cli\Release\lowend_gui.exe
```

창에서 캡처 소스와 출력 장치를 고르고 **Start**를 누릅니다. 슬라이더를 움직이면 실행 중에도
즉시 반영됩니다(엔진이 설정을 큐로 넘기므로 UI가 멈추지 않고 스트림도 재시작되지 않습니다).

- **Capture** 목록은 `System audio: ...` 항목들을 먼저 나열하고 그 뒤에 `Input: ...` 항목을
  나열합니다. 선택 자체가 모드입니다(CLI의 `--capture-device` / `--input-device`에 해당).
- **Output**은 렌더 엔드포인트입니다. 캡처와 같은 장치를 고르면 엔진의 자기 캡처 방지가
  동작해 시작이 거부되고 이유가 상태줄에 표시됩니다.
- 슬라이더 옆에 현재 값이 숫자로 표시됩니다. **Speaker width**, **Listener X/Z**는 0.01 단위,
  나머지는 0.1 단위입니다. 이는 표시값이 CLI·Core와 정확히 같은 값이 되도록 하기 위한 것입니다
  (예: Speaker width 기본값 1.65 m).
- 상태줄은 0.5초마다 갱신되며 처리 프레임, dropped, underrun, 재시도, 장치 오류를 보여줍니다.

GUI는 엔진의 공개 API만 사용합니다. 창·컨트롤·이벤트 루프는 `Windows/Source/GUI/`에만 있고
DSP와 장치 코드는 `lowend_engine`에 있습니다. GUI 전용 DSP 경로나 GUI 전용 설정 모델은 없습니다.

GUI를 자동으로 검증하는 스크립트가 있습니다. 실제 컨트롤에 사용자와 같은 메시지를 보내고
상태줄에서 결과를 확인합니다:

```bat
python scripts\check-windows-gui.py build\win-cli\Release\lowend_gui.exe
```

```text
window found
controls present; initial status: 'Idle. Choose an output endpoint, then Start.'
same-endpoint start refused, as designed
running; route and stats present (frames=20970)
statistics advancing: frames 20970 -> 165708
stopped cleanly
GUI verification passed: start, live statistics, stop, and shutdown
```

이 스크립트는 오디오 엔드포인트가 필요하므로 CI에서 실행하지 않습니다.

## CLI 사용

### 1. 장치 확인

```bat
build\win-cli\Release\lowend_windows.exe --list-devices
```

출력 장치(루프백 가능)와 입력 장치를 나열합니다. `*`는 기본 장치이고, `id=` 값이
`--device` / `--capture-device` / `--input-device`에 넣을 문자열입니다.

Bluetooth 장치는 `[Bluetooth]`로 표시됩니다.

### 2. 실행

```bat
rem 실제 입력 장치(마이크, 라인 입력)를 처리해서 출력 장치로 보내기
lowend_windows.exe --input-device <입력-id> --device <출력-id> --model circuit

rem 시스템 오디오를 처리해서 다른 출력 장치로 보내기
lowend_windows.exe --capture-device <출력-id> --device <다른-출력-id> --model circuit
```

Ctrl-C로 중지합니다. 중지 시 처리 프레임 수, dropped/underrun, 재시도 횟수를 보고합니다.

### 3. 옵션

| 옵션 | 범위 | 기본값 |
|---|---|---|
| `--device <id>` | 출력(렌더) 엔드포인트 | 기본 출력 |
| `--capture-device <id>` | 캡처 엔드포인트 | 캡처 flow의 기본 장치 |
| `--input-device <id>` | 실제 입력 장치를 캡처 (`--loopback on`과 함께 쓸 수 없음) | — |
| `--loopback on\|off` | 출력 엔드포인트 자체의 오디오를 캡처 | `on` |
| `--buffer-ms <n>` | 공유 모드 버퍼 요청(ms). 장치 최소값 미만은 클램프됨 | `20` |
| `--intensity <n>` | LowEnd | `55` |
| `--body <n>` | Body | `30` |
| `--output <n>` | 출력 (dB) | `-1.5` |
| `--model <m>` | `clean` / `circuit` / `highexciter` | `circuit` |
| `--exciter-os <m>` | `auto` / `1x` / `2x` / `4x` | `auto` |
| `--spatial on\|off` | 공간 처리 | `off` |
| `--listener-x`, `--listener-z` | 청취자 위치 (m) | `0`, `0` |
| `--stage-width <m>` | 스피커 폭 (m) | `1.65` |
| `--space <n>` | 공간 처리량 | `35` |
| `--verbose` | 협상된 경로, 실행 중 2초 간격 통계, 종료 통계 출력 | off |
| `--monitor <초>` | 캡처만 수행하고 통계를 보고한 뒤 종료 (1~600초) | — |
| `--list-devices`, `--dump-settings`, `--self-test`, `--help` | 진단 명령 | — |

### 진단: `--monitor`

출력 엔드포인트를 열지 않고 **캡처만** 수행합니다. 따라서 캡처하려는 엔드포인트가 이 머신의
유일한 출력일 때도 동작하며, "이 엔드포인트가 실제로 오디오를 주고 있는가"를 확인할 수 있습니다.
DSP는 매 블록 실행되므로 최종 장치 출력만 빠진 것과 같습니다.

```bat
rem 시스템 오디오(loopback)를 5초 관찰
lowend_windows.exe --monitor 5

rem 특정 입력 장치를 5초 관찰
lowend_windows.exe --monitor 5 --input-device <입력-id>

rem 다른 설정과 함께 사용 (진단 명령과 달리 단독일 필요 없음)
lowend_windows.exe --monitor 5 --model highexciter --spatial on --space 30
```

**재생 중인 소리가 없으면 loopback은 패킷을 아예 보내지 않습니다.** 무음 스트림이 계속 오는
것이 아니라 오디오 엔진이 그 엔드포인트의 스트림을 돌리지 않기 때문입니다. 따라서
`packets: 0`은 "장치 고장"이 아니라 "아무것도 재생되지 않음"을 뜻합니다.
`--monitor`는 관찰 구간이 끝나면 엔드포인트를 닫아 대기 중인 캡처를 깨우므로, 패킷이 오지
않아도 **지정한 시간에 정확히 종료**합니다. 1초마다 진행 상황을 출력합니다.

출력 예시 (톤 재생 중):

```text
Monitoring loopback of "Realtek Digital Output(Realtek(R) Audio)" for 5 s
  negotiated: 192000 Hz, 2 ch, 32-bit, 4224-frame period
  packets:       501 (0 silent, 1 discontinuous)
  frames:        961920 (5.01 s)
  input peak:    0.294982  (L 0.294982, R 0.294982)
  input RMS:     0.208574
  DSP:           Circuit, 1 applied revision(s)
```

`input peak`/`output peak`는 **양쪽 채널을 각각** 재고, 괄호 안에 좌/우 값을 함께 표시합니다.
괄호 앞의 값은 두 채널 중 **큰 쪽**입니다 — "무언가 재생 중인가"를 판단하는 값이라 한 채널만
보면 답할 수 없기 때문입니다. 한쪽 채널에만 신호가 있으면(모노 소스, 한쪽으로 치우친 소스 등)
`input peak`가 0보다 큰데도 **"One channel carried no signal (right/left)"**로 알려 줍니다.
양쪽 다 0일 때만 순수 무음이라고 보고합니다.
`discontinuous`는 스트림이 재배치되어 DSP 상태를 리셋한 횟수입니다.

이 진단을 자동으로 검증하는 스크립트가 있습니다. 알려진 톤을 재생하면서 관찰하고, 재생하지 않은
상태와 비교해 **신호가 있을 때는 잡히고 없을 때는 무음**임을 확인합니다(둘 다 통과해야 합니다):

```bat
python scripts\check-windows-system-audio.py build\win-cli\Release\lowend_windows.exe
```

```text
silence: no packets packets=0 frames=0
tone:    peak=0.294982 packets=401 frames=769920
System-audio loopback capture verified: the monitor saw the played tone
and saw no signal when nothing was playing.
```

무재생 구간에서는 패킷이 오지 않으므로(`packets=0`) 스크립트도 그 상태를 "신호 없음"으로
판정합니다. 톤 재생 중에는 패킷과 peak가 모두 나타나야 통과합니다.

이 스크립트는 오디오 엔드포인트가 필요하므로 CI에서 실행하지 않습니다(GitHub 러너에 오디오
장치가 없습니다). 로컬 검증 도구입니다.

`--verbose`는 실행 중 다음 열을 2초마다 출력합니다. 링 버퍼 상태를 실시간으로 보여주므로
문제를 화면에서 구분할 수 있습니다.

```text
elapsed    frames         dropped      underrun   recovered buffered
2.1        97908          0            6144       0         984
4.1        196644         0            6144       0         2232
```

`underrun`이 고정되어 있으면 시작 시점의 일회성 프라임 부족이고, 계속 증가하면 캡처 쪽이
따라가지 못하는 것입니다. `recovered`는 장치 오류 후 다시 열기에 성공한 횟수이고,
`buffered`는 현재 링에 쌓여 있는 프레임 수입니다.

옵션 이름과 범위, 오류 문구는 **macOS CLI와 동일**합니다. 범위를 벗어난 값은 클램프되고,
비유한 값(`nan`, `inf`)과 부분적으로 숫자인 값(`55abc`)은 거부됩니다.
진단 명령은 macOS와 같이 **단독으로만** 사용할 수 있습니다.

`--dump-settings`는 샘플레이트별 DSP 계획(배율, wet mix, headroom)을 표시하며 장치를 열지 않습니다.
`--self-test`는 오프라인 검사를 실행하며 장치를 열지 않습니다.

## 동작 방식

```text
입력/루프백 캡처 스레드 ──▶ SPSC 링 버퍼 ──▶ 렌더 스레드
   (WASAPI EVENTCALLBACK)      (AudioRingBufferC)   (DSP → WASAPI render)

CLI (lowend_windows.exe) ──┐
                           ├──▶ lowend_engine ──▶ lowend_core (Source/Core)
GUI (lowend_gui.exe)     ──┘        (WASAPI 장치 + 엔진 + DSP 스테이지)
```

`lowend_engine`은 정적 라이브러리이며 창·컨트롤·이벤트 루프를 참조하지 않습니다. CLI와 GUI는
각자 진입점만 추가합니다. 이것이 DSP와 오디오 엔진을 UI에 종속시키지 않는 구조입니다.

- DSP는 `Source/Core`의 `lowend::Processor`와 `lowend::SpatialProcessor`를 **그대로** 사용합니다.
  Windows 전용 DSP 구현은 없습니다.
- DSP 설정은 `LCControlEventQueue`(lock-free SPSC)로 오디오 스레드에 전달됩니다. 계수 계산은
  컨트롤 스레드에서만 일어나며, 오디오 스레드는 할당·잠금·로그·계수 계산을 하지 않습니다.
- DSP는 **캡처 장치의 실제 샘플레이트**에서 실행됩니다. 렌더 스트림에도 같은 rate를 요청하고,
  엔드포인트의 mix rate가 다르면 Windows 오디오 엔진이 문서화된 컨버터
  (`AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` + `SRC_DEFAULT_QUALITY`)로 변환합니다.
  캡처 측은 변환하지 않으며, 변환은 렌더 핸드오프에서 한 번만 일어납니다.
- `--verbose`와 GUI 상태줄은 **협상된 버퍼 duration**과 **WASAPI가 보고하는 엔진 지연**을
  표시합니다. 버퍼 duration은 협상된 프레임 수를 스트림 rate로 나눈 값이고, 엔진 지연은
  `GetStreamLatency()`가 주는 값(오디오 엔진 + 엔드포인트)입니다. 공유 모드 엔드포인트가
  후자를 0으로 보고하는 경우가 있으므로 0은 "측정 불가"를 뜻합니다. 링 버퍼와 DSP가 더하는
  지연은 포함되지 않으므로 이 값들은 전체 경로 지연이 아닙니다.
- 실행 중 장치가 끊기거나 스트림이 재배치되면 링 버퍼를 비우고 DSP 상태를 리셋합니다
  (`Resyncs` 카운터로 확인 가능). 이 카운터는 **길이에 비례하지 않습니다**: 90·180·240초 실행이
  모두 1이었으므로 시작 시점의 스트림 재배치 1회이고, 실행 중 반복되는 현상이 아닙니다.
  값이 실행 시간에 따라 늘어난다면 그때가 스트림이 계속 재배치되는 상황입니다(장치 전환,
  Bluetooth 재협상, 드라이버 문제).
- **장치 오류 복구**: 엔드포인트가 사라지면(Bluetooth 연결 해제, USB 분리, 기본 장치 변경)
  엔진이 그 장치를 **다시 열어 스트림을 이어갑니다**. 다시 열기는 원래 요청했던 옵션 그대로
  수행하며, 시도 간격은 점점 늘어나고 최대 8회로 제한됩니다. **총 재시도 시간은 약 4.9초**입니다
  (100 + 250 + 400 + 550 + 700 + 850 + 1000 + 1000 ms). 복구에 성공하면 `Recovered` 카운터가
  증가하고, 실패하면 `Reopen attempts`가 증가합니다.
  복구할 수 없는 오류(잘못된 포맷·요청, 메모리 부족 등)는 재시도하지 않고 즉시 중지합니다 —
  같은 실패를 반복하며 오디오 스레드를 붙잡고 있지 않기 위해서입니다.
  자세한 분류 근거는 [`Windows/Source/AudioEngine/RecoveryPolicy.h`](../Windows/Source/AudioEngine/RecoveryPolicy.h)와
  `WasapiDevices.cpp`의 `classifyFailure`에 있습니다.
- 공유 모드(shared mode)만 사용합니다. 독점 모드는 구현하지 않았습니다.

## 제한사항

Windows에서 시스템 전체 오디오 처리는 **macOS처럼 투명하지 않습니다.**

일반 WASAPI loopback은 원본 재생을 대체하지 **않습니다.** Microsoft 문서는 loopback 캡처가
오디오 엔진 출력의 추가 복사본이라고 명시합니다:

> "WASAPI **copies** the output stream from the audio engine into the loopback application's
> capture buffer, **in addition to** copying the audio data to the hardware's render pin."
> — [Loopback Recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)

따라서:

| 제한 | 내용 |
|---|---|
| 원본 중복 재생 | loopback 사용 시 원본이 원래 엔드포인트로 **계속 재생**됩니다. 처리본은 추가 출력입니다. |
| 볼륨/음소거 | loopback은 기본적으로 **pre-volume** tap입니다. 시스템 볼륨을 내려도 캡처 레벨은 변하지 않습니다. |
| 자기 캡처 | 같은 엔드포인트로 loopback 캡처 후 다시 재생하면 폐루프가 됩니다. 엔진은 **같은 엔드포인트 조합을 거부**합니다. |
| 보호 콘텐츠 | 신뢰 드라이버가 아닌 한 DRM 콘텐츠는 loopback에서 소실됩니다. |
| 독점 모드 | 독점 모드를 쓰는 앱(일부 ASIO, exclusive 출력)은 이 경로를 우회할 수 있습니다. |

**이는 의도된 정직한 한계 표시입니다.** 캡처 기반 방식을 투명한 것처럼 포장하지 않습니다.
투명한 구현에 필요한 Windows 아키텍처(APO 등)는
[Windows 포팅 계획](windows-port-plan.md)의 Phase 2.5에 조사 결과와 함께 정리했습니다.

추가로:

- **Bluetooth**: 출력 장치가 Bluetooth면 협상되는 주기와 rate가 가장 예측하기 어렵습니다.
  `--list-devices`에서 `[Bluetooth]`로 표시됩니다. 연결이 끊기면 캡처/렌더 오류로 종료됩니다.
- **장치 전환**: 실행 중 기본 장치를 바꾸는 동작은 자동으로 따라가지 않습니다. 중지하고 다시
  시작하세요. 엔진은 장치가 무효화되면 오류 카운터를 올리고 복구를 시도하며, 복구가 불가능하거나
  재시도 예산을 다 쓰면 종료합니다. 복구 중 기본 장치 변경으로 캡처와 렌더가 **같은 엔드포인트로
  해석되면** 폐루프를 만들지 않기 위해 즉시 중지합니다(위 검증 항목 참조).
- **리샘플링**: 캡처와 렌더 rate가 다르면 Windows 오디오 엔진의 컨버터에 의존합니다. 엔진이
  요청한 rate로 열리지 않으면 피치가 틀어진 채로 재생하는 대신 시작을 거부합니다.

## 검증 범위

### CI 상태

`.github/workflows/windows-cli-ci.yml`이 추가되어 `windows-latest`에서 Debug/Release 두 구성으로
빌드·`ctest`·CLI 인자 회귀·**GUI 컨트롤 목록**·**GUI 슬라이더 경로**를 수행하고,
**UI 비종속 잡**(`windows-no-ui`: 소스·링크 경계 검사 + GUI 타깃 없이 엔진/CLI 빌드·검사)이
추가되어 있습니다. 또 `.github/workflows/cross-platform-core-ci.yml`에 `windows-latest`가 추가되어
Core 테스트를 두 OS에서 돌립니다.

슬라이더 검사는 **실제 마우스 입력**을 사용하므로 입력 데스크톱이 필요합니다. GitHub 러너가
헤드리스여서 썸이 전혀 움직이지 않으면 그 사실을 **SKIPPED로 보고하고 통과로 세지 않습니다** —
이것이 실제 결함(썸은 움직이는데 표시가 안 따라오는 경우)과 구별되는 지점입니다. 로컬
워크스테이션에서는 21개 드래그가 모두 실행됩니다.

**이 두 워크플로는 아직 GitHub에서 실행되지 않았습니다.** 이 작업은 로컬 브랜치
(`feature/windows-port`)에서 진행되었고 원격에 푸시되지 않았습니다(자격 증명을 대화형으로
요구해 푸시할 수 없었습니다). 따라서 CI 구성이 실제 러너에서 통과한다는 관찰은 아직 없습니다.
대신 **워크플로가 실행하는 명령을 로컬에서 그대로 재현**해 검증했습니다: Visual Studio
제너레이터(CI 기본값)로 Debug/Release 양쪽 구성, `ctest`, `check-windows-cli.py`까지 모두
통과했습니다. 또한 YAML 문법과 매트릭스 정의를 파싱해 확인했습니다.

검증한 것:

- **macOS 무손상**: `SystemAudioProcessor/` 아래 파일은 **한 줄도 변경하지 않았습니다**
  (`git status` 결과 없음). macOS가 실제로 컴파일하는 Core DSP 5개 소스
  (`Core.cpp`, `CircuitBass.cpp`, `HighExciter.cpp`, `Processor.cpp`, `SpatialGeometry.cpp`)와
  그 공개 헤더도 **변경 없음** — `LowEndDSPCoreC.cpp`가 이들을 amalgamate하므로, 이들이 그대로라는
  것이 macOS DSP 경로가 그대로라는 직접 근거입니다. 추가된 Core 파일(`SpatialProcessor`,
  `PcmResampler`, `OutputConditioning`)은 macOS 타깃에 포함되지 않습니다
- **크로스 컴파일러 검증**: Core 전체를 **Clang**(macOS CI와 같은 컴파일러 계열)과 **GCC**로
  빌드해 각각 **11/11 테스트 통과, 경고 0**. 새로 옮긴 코드가 MSVC 전용이 아님을 확인
- `Source/Core` 전 테스트가 MSVC(Debug/Release)에서 통과
- 오프라인 검사(`--self-test`): DSP 모델 동작, oversampling 정책, 공간 처리, 링 버퍼/제어 큐
  계정, 스레드 핸드오프, 샘플레이트 매트릭스, 인자 파싱·거부 규칙
- CLI 인자 회귀: 잘못된 인자 23종 거부(그중 5종은 거부 사유 문구까지 확인), 장치를 열지 않는 진단 명령, `--help` 문서화 확인
- **CI 명령 로컬 재현**: 워크플로가 실행하는 명령을 VS 제너레이터로 Debug/Release 양쪽 실행해
  전부 통과(아래 CI 상태 참조)
- **실제 장치 실행 (입력 → 출력)**: 48 kHz 입력 → Circuit DSP → 192 kHz 출력 엔드포인트
  (48 kHz 스트림으로 변환됨)를 30초간 실행. 처리 프레임 1,436,454 (29.93초분), 캡처/렌더 오류 0,
  dropped 0. `--verbose`로 시작 시점에만 6144 프레임(64 ms)의 underrun이 발생하고 이후 증가하지
  않음을 확인
- **시스템 오디오 loopback 캡처 (`--monitor`)**: 활성 출력 엔드포인트(Realtek Digital Output,
  192 kHz)의 loopback을 캡처하면서 440 Hz 톤을 재생 → 401 패킷 / 769,920 프레임, peak 0.294982
  (재현 스크립트 포함). **DSP(Circuit)가 실제 시스템 오디오에 적용됨을 확인**
- **무신호 판정**: 같은 loopback을 재생 없이 관찰 → **패킷 0개**. 오디오 엔진은 그 엔드포인트에
  렌더링하는 스트림이 없으면 loopback 스트림을 돌리지 않으므로, 무음 패킷이 계속 오는 것이
  아니라 패킷 자체가 오지 않습니다. 따라서 위 신호 값은 실제 재생된 오디오를 잡은 것입니다
- **`--monitor`가 지정 시간에 종료됨**: 패킷이 오지 않는 동안에도 대기 중인 캡처를 닫아 깨우므로
  `--monitor 3`이 3.3초에 종료(초기 버전은 무기한 대기했고 이 결함을 수정)
- **입력 장치 캡처 (`--monitor --input-device`)**: WO Mic 48 kHz에서 301 패킷 / 144,480 프레임
  (3.01초) 수신. 무음 판정이 입력 장치에도 동일하게 동작
- **loopback + HighExciter + Spatial**: 401 패킷 / 769,920 프레임 (4.01초), peak 0.294982.
  모델 전환과 공간 처리가 실제 시스템 오디오 경로에서 동작
- **GUI (창·컨트롤)**: 실제 창에서 컨트롤을 열거해 **33개**(콤보 4, 트랙바 7, 버튼 3,
  정적 19 = 섹션 라벨 13 + 값 표시 6 + 상태줄 1)가 모두 생성되고 배치되었음을 확인했습니다.
  모든 컨트롤이 0이 아닌 크기를 갖습니다(존재하지만 배치되지 않은 컨트롤은 결함이므로).
  값 표시가 CLI/Core 기본값과 일치(55.0 / 30.0 / -1.5 dB / 35.0 / 1.65 m / 0.00 m).
  참고로 문서가 이전에 적었던 "15개(정적 1)"는 **틀린 수치**였습니다 — 콤보·트랙바·버튼 개수는
  맞았지만 정적을 1개로 세어 전체를 18개 적게 보고했습니다. 지금은
  `scripts/check-windows-gui-controls.py`가 클래스별 개수와 총계를 실제 창에서 확인합니다
- **GUI → 엔진 (실제 컨트롤 조작)**: 같은 엔드포인트 선택 시 자기 캡처 방지가 GUI에 도달해
  시작이 거부됨. 입력 장치로 시작 시 경로 협상 + 통계 표시, 프레임 20,970 → 165,708로 증가,
  **실행 중 모델 변경**(Circuit → HighExciter)이 오디오 스레드에 반영되고 변경 후에도 프레임이
  계속 진행, Stop 후 Idle 복귀, **Stop → Start 재시작** 시 통계가 새 스트림 기준으로 초기화되고
  (165,708 → 23,064) 다시 증가(→ 167,790), 두 번째 Stop도 정상, WM_CLOSE로 정상 종료.
  실행 중 설정 변경이 반영되는지는 상태줄의 `running model`(오디오 스레드가 실제 실행 중인 모델)
  로 확인합니다. 컨트롤 값은 "선택된" 값을 보여줄 뿐 적용 여부는 보여주지 않으므로 둘을 함께
  표시합니다. 이 검사는 설정 큐 전달을 끊는 변경을 주입했을 때 실패하는 것도 확인했습니다
- **장치 오류 복구 정책**: 실패 분류와 재시도 예산을 오프라인 검사로 검증(복구 가능/불가능
  구분, 예산 소진 시 중지, 백오프 증가와 상한, reset 후 예산 회복)
- **DSP가 신호 경로에 있음**: `--monitor`가 캡처한 실제 오디오에 대해 **처리 전/후 레벨을 함께**
  보고합니다(`input peak` / `output peak`). 루프백으로 440 Hz 톤을 잡아 측정한 값:
  입력 0.294982 → 출력 0.203087. 입력만 재면 "오디오가 도착했다"만 증명되고 코어가 경로에
  있는지는 증명되지 않으므로, 출력을 함께 재서 비교합니다. 설정 반응성도 확인했습니다
  (기본 circuit: 0.65x, `--intensity 0`: 0.94x). 감쇠는 결함이 아니라 설계된 동작입니다:
  서셈션 압축 + wet/dry 블렌딩 + `output -1.5 dB`. `--intensity 0`이 우회가 아닌 이유는
  우회 조건이 "intensity와 body가 모두 0에 가까울 때"이고 body 기본값이 30이기 때문입니다.
- **DSP와 엔진이 UI에 종속되지 않음 (구조 + 빌드 + 실행)**: 세 가지로 확인했습니다.
  (1) **구조**: `Windows/Source/AudioEngine/` 전체에 UI 헤더(`commctrl.h`, `windowsx.h`,
  `uxtheme.h`, `gui/` 등), UI 심볼(`HWND`, `CreateWindow*`, `WM_*`, `MessageBox`, `WNDCLASS*`,
  `SendMessage*`, `SetTimer` 등), GUI 소스 참조가 **하나도 없고**, `lowend_engine`의 링크
  라인에도 UI 라이브러리(`user32`, `comctl32`, `gdi32`)가 없습니다.
  (2) **빌드**: `-DLOWEND_WINDOWS_BUILD_GUI=OFF`로 GUI 타깃 없이 엔진+CLI만 빌드·`ctest` 통과.
  `lowend_gui.exe`는 생성되지 않고 `lowend_windows.exe`는 정상 생성됩니다.
  (3) **실행**: 그 GUI 없는 바이너리로 실제 입력 장치에서 라이브 오디오를 처리(284,004 프레임,
  exit 0)하고, CLI 검사도 그 바이너리로 통과합니다. GUI 쪽도 DSP·장치 심볼을 참조하지
  않습니다(문자열 리터럴만 존재).
- **UI 비종속 회귀 방지 (`scripts/check-windows-ui-independence.py`)**: 위 성질은 조용히
  무너질 수 있으므로 검사를 추가했습니다. **GUI를 끈 빌드만으로는 부족합니다** — GUI 소스가
  디스크에 남아 있어 엔진이 GUI 헤더를 include해도 그대로 컴파일됩니다(실제로 주입해 확인:
  빌드가 통과했습니다). 그래서 컴파일러 없이 소스·링크 경계를 직접 검사합니다: 엔진의 UI
  헤더/심볼/GUI 소스 참조, 엔진 링크 라인의 UI 라이브러리, GUI의 DSP·장치 구현. 결합 7종을
  주입해 모두 잡아내는 것을 확인했고, `build-windows-cli.bat`과 CI `windows-no-ui` 잡에서
  실행됩니다. 참고로 이 검사를 처음 작성했을 때 `#include` 줄이 문자열 리터럴 제거 단계에서
  함께 지워져 include 검사가 **조용히 아무것도 못 잡는** 결함이 있었고, 주입 테스트로 발견해
  수정했습니다(지금은 include 지시문을 별도로 스캔합니다).
  검사 범위는 **의도된 결합**입니다: GUI가 `Engine.h`/`Settings.h`를 include해 엔진을 호출하는
  것은 허용하고, DSP 커널이나 WASAPI 인터페이스를 직접 쓰는 것은 금지합니다.
- **장시간 안정성 (실제 장치)**: 입력→출력 경로를 **298초 연속** 실행하며 `--verbose`로 2초마다
  카운터를 관찰했습니다(샘플 144개). 결과: **dropped 항상 0**, **누적 프레임이 경과 시간을
  93 ms 이내로 추종**(296초 구간에서 드리프트 누적 없음), 프레임 단조 증가, 렌더 버퍼 잔량이
  0~3192 프레임에서 정상 진동(고갈이 아니라 평형). 별도로 90/180/240초 실행에서도 dropped 0,
  오류 0, exit 0.
- **시작 과도 상태 해석 (중요)**: `Resyncs`와 `Underrun samples`는 **길이에 비례하지 않습니다**.
  90초·180초·240초 실행 모두 **Resyncs = 1**, underrun도 3264~5184 샘플(≈54 ms, 렌더 버퍼
  2~3개)로 일정했습니다. 즉 **시작 시점의 일회성 이벤트**이며 지속적인 고갈이 아닙니다.
  298초 실행에서 렌더 버퍼 잔량이 순간적으로 0을 찍은 구간이 한 번 있었지만 **그 순간에도
  underrun 카운터는 증가하지 않았습니다**(5184 그대로). 프레임도 계속 단조 증가했으므로 실제
  샘플 손실은 없었고 샘플은 다음 블록에서 따라잡혔습니다. 따라서 값이 **고정**이면 초기 과도
  상태로 봐야 하고, 계속 증가하면 그때가 캡처가 못 따라가는 상황입니다.
- **명시적 장치 선택**: `--device <id>`로 기본이 아닌 렌더 엔드포인트를 직접 지정해 시작 →
  경로 협상과 291,210 프레임 처리(exit 0). 잘못된 id는 조용히 기본값으로 대체되지 않고
  `ERROR_NOT_FOUND`로 실패하며 그 이유를 그대로 표시합니다.
- **자기 캡처 방지 (CLI)**: 같은 엔드포인트를 캡처+렌더로 지정하고 loopback을 켜면 시작이
  거부되고 이유가 출력됩니다(문서의 "CLI, GUI 양쪽" 주장을 CLI에서도 실제 실행으로 확인).
  같은 조합이라도 loopback을 끄면 폐루프가 아니므로 거부 대상이 아닙니다.
- **빈 장치 id 거부 (수정한 결함)**: 장치 선택 플래그에 **명시적으로 빈 문자열**을 주면 플래그마다
  다르게 동작하는 결함이 있었습니다. `--device ""`와 `--capture-device ""`는 실패했지만
  **`--input-device ""`는 조용히 기본 입력 장치로 시작**했습니다(`capture: input "default input"`).
  셸 변수가 비어 있는 경우(`--input-device "$MIC"`)에 사용자가 지정하지 않은 경로를 처리하게
  되므로, 선택 플래그가 막아야 할 바로 그 실수입니다. 내부적으로 빈 id는 "기본 장치"를 뜻하지만
  **플래그를 생략한 것과 명시적으로 빈 값을 준 것은 다릅니다**. 이제 세 플래그 모두
  `--input-device needs a device id`처럼 플래그 이름을 밝히며 거부하고, 거부된 값은 캡처 flow를
  바꾸지 않습니다. 플래그를 생략하면 종전처럼 기본 엔드포인트를 씁니다. 이 동작은
  `scripts/check-windows-cli.py`의 회귀 검사에 포함되어 있습니다
- **캡처 소스 플래그 모순 거부 (수정한 결함)**: `--input-device`와 `--loopback on`은 **서로 반대**를
  가리킵니다(전자는 실제 입력 장치, 후자는 출력 엔드포인트 자체). 그런데 두 플래그가 모두 캡처
  flow를 덮어써서 **인자 순서가 의미를 결정**하는 결함이 있었습니다:
  `--loopback on --input-device X`는 loopback 요청을 **조용히 무시**하고 입력 장치를 캡처했고,
  `--input-device X --loopback on`은 입력 장치를 가리키는 render-flow loopback을 만들어
  **무관한 엔드포인트 오류**로 실패했습니다. 순서에 따라 다르게 동작하는 대신, 이제 두 플래그를
  따로 기록하고 루프가 끝난 뒤 판정합니다. 모순이면 순서와 무관하게 같은 메시지로 거부하고,
  `--loopback off --input-device X`처럼 일치하는 조합은 양쪽 순서에서 동일하게 동작합니다.
  `--capture-device`는 선택된 flow의 엔드포인트를 지정하는 플래그이므로 flow 결정 후에 적용되어
  flow 자체를 바꾸지 않습니다.
- **회귀 검사에 "이유"까지 검증**: 위 모순 검사를 처음 추가했을 때는 **종료 코드만** 확인했는데,
  존재하지 않는 엔드포인트 id를 썼기 때문에 모순 검사를 무력화해도 다른 이유로 exit 1이 나와
  **검사가 통과했습니다**(주입 테스트로 발견). 지금은 거부 사유 문구(`cannot be combined`,
  `needs a device id`)까지 확인하므로 해당 결함을 실제로 잡아냅니다
- **재시도 예산 시간 (문서 오류 수정)**: 코드 주석과 사용자 문서가 복구 재시도가 "약 15초"를
  시도한다고 적고 있었지만, 실제 합계는 **4.85초**였습니다(100+250+400+550+700+850+1000+1000 ms).
  헤더에서 합계를 계산하는 프로그램을 만들어 확인했습니다. 이제 주석과 문서 모두 4.9초로
  정정했고, `--self-test`가 합계를 **문서화된 값에 고정**해 검사합니다. 이전 검사는 하한만
  봤기 때문에(`>= 4000`) 예산이 어떤 값으로 늘어나도 통과했고, 문서와 코드가 어긋나도 잡지
  못했습니다. 지금은 백오프 계수를 바꾸는 변경을 주입하면 두 검사가 실패하는 것을 확인했습니다
- **GUI 슬라이더 경로 (수정한 결함 + 실제 드래그 검증)**: 슬라이더를 **실제 마우스로 드래그**해
  위치→값 변환과 표시를 검증했습니다. 7개 슬라이더를 각각 3개 지점(양 끝, 중간)으로 드래그해
  **총 21회**, 모든 경우에 값 표시가 썸 위치와 일치했습니다.
  이 과정에서 **실제 결함을 발견했습니다**: 트랙바는 사용자 입력을 `WM_HSCROLL`로 부모에
  알리는데 창 프로시저가 이 메시지를 **처리하지 않았습니다**. 그 결과 슬라이더를 드래그하면
  썸은 움직이고 적용되는 값도 바뀌었지만, 옆의 숫자와 상태줄은 **이전 값을 계속 표시**했습니다
  (예: 위치 550→84로 드래그해도 표시는 55.0 그대로). 사용자가 보는 값과 실제 적용값이
  어긋나는 결함입니다. `WM_HSCROLL` 처리를 추가해 수정했고, 실행 중 드래그도 확인했습니다
  (드래그 후 표시 91.1, 프레임 213,498 → 285,306 계속 진행).
  **중요**: `TBM_SETPOS`로 위치만 바꾸는 방식으로는 이 결함을 재현할 수 없습니다 — 알림이
  발생하지 않기 때문입니다. 그래서 검사는 실제 마우스 입력을 사용하며, `WM_HSCROLL` 처리를
  제거하는 변경을 주입하면 21개 드래그가 모두 실패하는 것을 확인했습니다
- **GUI Refresh devices가 캡처 선택을 잃던 결함 (수정)**: "Refresh devices" 버튼은 두 콤보를
  엔드포인트 목록으로 다시 채우는데, **렌더 선택만 복원하고 캡처 선택은 복원하지 않았습니다**.
  그 결과 캡처 목록의 인덱스가 0(기본 출력의 시스템 오디오)으로 되돌아갔고, 이는 렌더 기본값과
  **같은 엔드포인트**입니다. 사용자가 입력 장치를 골라 쓰고 있어도 새로 고침 한 번이면
  자기 캡처 조합이 되어 **다음 Start가 "same device"로 거부**되었습니다 — 사용자가 선택한 적
  없는 이유로 실패하는 셈입니다. 캡처 목록은 "출력 엔드포인트 전부 → 입력 엔드포인트 전부"로
  구성되어 하드웨어에 따라 인덱스가 달라지므로, 선택을 id로 기억해 복원하도록 수정했습니다.
  실제 창에서 확인: 새로 고침 전후로 협상된 캡처 경로가 **동일**합니다
  (`capture: input "{0.0.1...}"` → render `{0.0.0...}`). 회귀 검사
  `scripts/check-windows-gui-refresh.py`를 추가했고, 복원 코드를 제거하는 변경을 주입하면
  `capture selection moved from index 1 to index 0`으로 실패하는 것을 확인했습니다
- **DSP 패리티 (Windows stage ↔ portable Core)**: "Windows가 macOS와 같은 Source/Core DSP를
  그대로 쓴다"는 주장을 직접 검증하는 검사를 추가했습니다. `DspStage`를 통과시킨 출력이
  `lowend::Processor` + `lowend::SpatialProcessor`를 같은 계획으로 **직접** 구동한 출력과
  **비트 단위로 동일**해야 합니다. 3가지 구성(Circuit/spatial off, Circuit/spatial on,
  HighExciter/spatial on)에 대해, 청크 분할이 일어나도록 8192*2+37 프레임으로 실행합니다.
  허용 오차를 두지 않습니다 — 0.01% 이득(0.9999)이나 공간 단계 생략 같은 미세한 발산을
  주입하면 즉시 실패하는 것을 확인했습니다(첫 불일치 프레임까지 출력).
  이 검사가 덮는 것: 설정→계획 변환, 블록 청킹, 공간 스테이징, 제어 큐 핸드오프.
  덮지 않는 것: 그 계획 자체가 macOS와 같은지 — 그 근거는 Core 테스트와 동일 소스의
  Clang/GCC 빌드입니다.
- **출력 컨디셔닝(PCM 2×) 부재가 품질을 떨어뜨리지 않는 근거**: Windows 엔진에는 출력
  컨디셔닝 단계가 없습니다. 이것이 **기능 누락이 아니라 기본 설정에서 macOS와 동일**하다는 것을
  코드 경로로 확인했습니다. macOS live 경로는 `processLive`를 항상 호출하지만 그 문서상 동작은
  "Bypass (verbatim copy) unless the live PCM 2× mode is active"이고, 저장되는 기본값은
  `isEnabled = false` + `outputMode = .bypass`입니다(`OutputConditioningParameters`). Core의
  `OutputConditioning::update()`는 `enabled && outputMode == pcmOversampling && factor == 2`일
  때만 `active_`를 세우고, 비활성 경로는 `std::copy` 그대로입니다. 따라서 사용자가 실제로
  시작하는 구성에서 macOS 단계는 **프레임 수가 같은 항등 복사**이고, 이를 생략한 Windows와
  샘플이 일치합니다. 이 등가성은 Core 동작에 의존하므로 주석으로 두지 않고
  `--self-test`의 **default output conditioning** 검사로 고정했습니다(macOS 기본값을 필드
  단위로 재현 → 비활성 확인, 프레임 수 동일, 비트 단위 동일). 바이패스 경로에 헤드룸을
  적용하는 변경을 주입하면 즉시 실패합니다. 참고로 2×를 **활성화**하면 Windows에는 그 경로가
  없으므로 그때는 macOS와 달라지며, 이는 아래 제한사항에 적혀 있습니다
- **GUI 검사 스크립트의 헤드리스 처리**: GUI를 대상으로 하는 검사 4종(컨트롤 목록, 슬라이더,
  새로 고침, end-to-end)은 창이 필요합니다. 세션에 데스크톱이 없어 창이 만들어지지 않으면
  **SKIPPED로 보고하고 통과로 세지 않습니다**(관찰한 것이 없으므로). 반대로 프로세스가 창을
  만들기 전에 **종료 코드와 함께 죽으면 실패**로 처리합니다 — 환경 한계와 실제 결함을 구분하기
  위해서입니다. 두 분기를 모두 주입해 확인했습니다: 창이 없는 정상 실행은 skip, 종료 코드 3으로
  죽는 경우는 `exited with code 3 before its window appeared; this is a failure, not a missing
  desktop`으로 실패합니다. 이는 CI 러너가 헤드리스여도 검사가 거짓 통과를 만들지 않게 합니다
- **서로 다른 두 장치 간 라우팅 (검증 완료 — 이전에 불가능했던 항목)**: 이 워크스테이션에
  **출력 엔드포인트가 하나만** 있었기 때문에 "한 장치를 loopback으로 캡처해 다른 장치로 재생"하는
  조합을 오래 검증하지 못했습니다. 이후 출력 장치가 3개가 되어(기본 Fosi Audio ZH3 48 kHz,
  Odyssey G5 48 kHz, Realtek Digital Output 192 kHz) 이 경로를 실제로 실행했습니다.
  Fosi(48 kHz) loopback → Realtek(192 kHz) 엔드포인트로 **294,738 프레임(6.1초), 캡처/렌더 오류 0,
  dropped 0**. 반대 방향(Realtek 192 kHz loopback → Fosi)도 정상 개방됩니다.
  함께 확인된 것: **렌더 스트림은 렌더 장치의 mix rate가 아니라 캡처 장치의 rate로 열립니다** —
  192 kHz 엔드포인트에 48 kHz 스트림이 열리고, 48 kHz 엔드포인트에는 192 kHz 스트림이 열립니다.
  변환은 Windows 오디오 엔진이 수행하며(엔진 자체 리샘플러 없음), 두 방향 모두 rate가 일치하지
  않으면 엔진이 시작을 거부합니다. 회귀 검사 `scripts/check-windows-cross-device.py`를 추가했고,
  rate 변환 요청을 없애는 변경을 주입하면 라우트가 열리지 않아(exit 1) 실패하는 것을 확인했습니다.
  출력 장치가 2개 미만이면 이전처럼 **SKIPPED로 보고하고 통과로 세지 않습니다**
- **처리된 오디오가 실제로 렌더 장치에 도달함 (A/B 검증)**: 다른 모든 검사는 "렌더 스트림이 열리고
  쓰기를 받았다"에서 멈춥니다. 그것은 "오디오가 엔드포인트에 도달했다"와 다릅니다 — 스트림이 열려
  블록을 받아들이면서도 아무 소리도 내지 않을 수 있습니다. 확인 방법은 **렌더 엔드포인트 자신의
  loopback**을 관찰하는 것이고, 그 장치로 실제 재생되는 내용이 그대로 보입니다.
  측정: 톤을 기본 출력(Fosi Audio ZH3 48 kHz)에서 재생 → 엔진이 그 loopback을 캡처해
  **다른 엔드포인트(Odyssey G5)**로 렌더 → Odyssey 자신의 loopback을 관찰.
  (1) **기준선**: 아무것도 렌더하지 않는 Odyssey loopback = **패킷 0개**(idle 엔드포인트의
  loopback은 패킷을 아예 보내지 않으므로 깨끗한 대조군입니다).
  (2) **엔진이 렌더하는 동안**: 501 패킷 / 240,480 프레임, peak **0.260078**.
  (3) **A/B**: 같은 톤·같은 엔드포인트·같은 세션에서 DSP 모델만 바꿔 비교했습니다.
  문서상 비트 단위 우회인 `--model clean --intensity 0 --body 0 --output 0`은 **0.399963**(= 톤
  진폭 그대로)인데 기본 Circuit은 **0.260078**로 **0.65x**입니다. 즉 (a) 엔진이 렌더 장치까지
  감쇠 없이 전달하고, (b) DSP가 그 경로에서 실제로 신호를 shaping했으며, (c) 0.65x는 앞서
  입력 측에서 측정한 Circuit 이득과 **독립적인 측정 지점에서 일치**합니다.
  이 비교는 세션 볼륨에 의존하지 않습니다(두 실행 모두 같은 볼륨).
  회귀 검사 `scripts/check-windows-render-landing.py`를 추가했고, 프로세스된 블록 대신 **무음을
  쓰도록** 변경을 주입하면 탐지됩니다(패킷은 도착하는데 peak 0.0 → 실패)
- **복구 중 자기 캡처 방지 누락 (수정한 결함)**: 같은 엔드포인트 금지 검사가 **`start()`에만**
  있었고 재개방 경로에는 없었습니다. 그런데 **빈 장치 id는 "기본 장치"를 뜻하고 매 `open()`마다
  다시 해석**되므로, 스트림이 복구되는 동안 기본 장치가 바뀌면 캡처와 렌더가 **같은 엔드포인트로
  해석**될 수 있습니다 — 시작 시점 검사로는 볼 수 없는 상황입니다. 그대로 두면 WASAPI가 끊어주지
  않는 **무한 피드백 루프**(처리 결과가 자기 입력으로 다시 들어감)가 됩니다. 이제 캡처/렌더
  **양쪽 재개방 성공 직후**에 충돌을 확인하고, 충돌이면 스트림을 멈추고 `givingUp`을 세웁니다.
  판정은 `endpointsCollide()` 한 곳에 두었고, 문자열이 아니라 **해시**를 비교합니다 — 두 엔드포인트는
  서로 다른 오디오 스레드가 소유하므로, 다른 스레드가 재작성 중인 `std::string`을 읽으면 데이터
  경합이 됩니다. 각 스레드는 open/close 직후 자기 해시를 atomic에 게시하고(0 = 엔드포인트 없음),
  검사는 그 원자값만 읽습니다. 0은 절대 충돌로 취급하지 않으므로 닫힌 쪽이 오탐을 만들지 않습니다.
  `--self-test`에 판정 6종을 고정했고, **양방향** 주입(항상 충돌로 판정 / 절대 충돌 아님)이 모두
  실패하는 것을 확인했습니다. 실제 장치에서도 확인: 같은 엔드포인트 명시 조합과 기본 loopback
  조합은 여전히 거부되고, 서로 다른 장치 경로는 정상 동작합니다
- **시작 시 빈 창이 보이던 결함 (수정)**: 창을 만들 때 `WS_VISIBLE`을 함께 지정해, **컨트롤이
  만들어지기 전에 창이 먼저 표시**되었습니다. 그 결과 사용자는 약 **70~130 ms 동안 빈 창**을
  보게 되었습니다(이 워크스테이션 측정: 창이 보이는 시점에 자식 컨트롤 0개, 컨트롤 33개가
  준비되기까지 71~127 ms). `WS_VISIBLE`을 제거하고 컨트롤 생성·배치·장치 열거가 모두 끝난 뒤
  `ShowWindow()`가 창을 드러내도록 했습니다. 수정 후 4회 측정 모두 **창이 보이는 순간 이미 컨트롤
  33개가 존재**합니다. 이 결함은 GUI end-to-end 검사가 간헐적으로 실패하면서 드러났습니다
  ("The start/stop control is missing") — 검사가 창을 찾은 직후 컨트롤을 읽었는데 그 시점이
  창은 있고 컨트롤은 없는 구간에 걸린 것입니다. 수정 후 같은 검사를 **3회 연속 통과**했습니다
- **GUI 배치 검증 (겹침·경계)**: 컨트롤 존재 여부뿐 아니라 **배치**를 검사합니다. 33개 컨트롤
  전부가 **부모의 클라이언트 영역(760x760) 안에** 있고, **상호작용 컨트롤(콤보 4·트랙바 7·버튼 3)
  사이에 겹침이 0**임을 실제 창에서 확인합니다. 겹치면 나중에 생성된 컨트롤이 그 영역의 클릭을
  가져가므로 하나는 사용할 수 없게 됩니다. 좌표 비교는 반드시 **같은 좌표계**에서 해야 합니다 —
  `GetWindowRect`는 화면 좌표, `GetClientRect`는 클라이언트 좌표라 그대로 비교하면 모든 컨트롤이
  범위를 벗어난 것으로 잘못 보고됩니다(처음에 이 실수를 했고, `MapWindowPoints`로 양 모서리를
  클라이언트 좌표로 변환해 수정했습니다). 주입 테스트로 두 경우를 모두 확인했습니다: 트랙바를
  버튼 위로 겹치면 `controls 1012 and 1013 overlap`, 컨트롤을 클라이언트 밖으로 밀면
  `control id(s) [1004] are placed outside the window's client area`로 실패합니다
- **사용되지 않던 공개 API 제거**: `Engine::drainInput`, `Engine::produceOutput`,
  `Engine::requestResync`는 **호출 지점이 0개**였습니다(저장소 전체 검색: `SelfTest.cpp`에서도,
  CLI/GUI에서도, 어떤 문서·계약에서도 사용되지 않음). 특히 주석은 이들이 "offline checks가
  실제 경로를 구동할 수 있도록 노출"되었다고 적고 있었지만 **그 근거가 사실이 아니었습니다** —
  self-test는 `processBlock`만 사용합니다. 구현 3개(약 60줄)와 선언을 제거했고, 빌드가 그대로
  통과하는 것으로 다른 참조가 없음을 확인했습니다. 마찬가지로 `DspStage::queueSettings`는
  `applySettings` 내부에서만 호출되므로 **private으로 내렸습니다**(주석의 "여러 레이트를 검사하는
  offline check가 사용한다"는 설명도 사실이 아니어서 함께 정정). 남겨둔 `processBlock`은
  self-test가 실제로 사용하므로 그대로 공개입니다
- **`--monitor`가 왼쪽 채널만 측정하던 결함 (수정)**: `--monitor`의 peak/RMS 계산이
  `sourceLeft`/`left`만 읽고 있었습니다. 그래서 **오른쪽 채널에만 신호가 있는 스트림**은
  `input peak 0.000000`으로 보고되었고, 프로그램은 **"the endpoint produced pure silence"**라고
  단정했습니다 — 신호가 흐르고 있는데도 무음이라고 말한 **거짓 진단**입니다.
  좌/우 전용 톤으로 재현했습니다(수정 전): 왼쪽 전용 → `0.260078`, 오른쪽 전용 → `0.000000`
  (두 경우 모두 401 패킷 도착). 이제 양쪽 채널을 각각 측정하고(`input peak: X (L …, R …)`),
  한쪽만 무음이면 **"One channel carried no signal (right/left)"**로 정확히 보고합니다.
  수정 후: 왼쪽 전용 → `L 0.191807, R 0.000000`, 오른쪽 전용 → `L 0.000000, R 0.191807`.
  이 재현은 동시에 **캡처·DSP 경로가 오른쪽 채널을 정상 처리**한다는 증거이기도 합니다 —
  수정 전의 0은 순수하게 측정 결함이었습니다
- **채널별 검증 (`check-windows-system-audio.py`)**: 위 결함을 회귀 검사로 고정했습니다. 재생하는
  톤은 양쪽 채널이 같은 스테레오이므로 **두 채널 모두** 신호가 있어야 합니다. 검사는 이제
  `input peak: X (L …, R …)`에서 좌/우를 파싱해 **양쪽 모두 최소값 이상**임을 확인하고, 한쪽이라도
  무음이면 실패합니다. 왼쪽만 측정하도록 되돌리는 변경을 주입하면
  `A channel carried no signal from a stereo tone (L 0.399963, R 0.000000)`으로 실패하는 것을
  확인했습니다. 정상 실행은 `input peak 0.399963 (L 0.399963, R 0.399963)`을 보고합니다
- **GUI 상태줄에 구분자가 없던 결함 (수정)**: GUI 상태줄은 ①설정 요약 ②협상된 경로 ③실행 통계를
  하나의 static 컨트롤에 이어 붙입니다. 설정 요약은 개행 없이 `space 35`로 끝나고 경로는
  `capture:`로 시작하는데, 그 사이에 **구분자가 없어서** 실제 화면에
  **`... space 35capture: input "{...}" ...`** 처럼 두 덩어리가 한 줄로 붙어 나왔습니다 —
  35라는 값 뒤에 `capture:`가 이어져 하나의 깨진 값처럼 보입니다. 유휴 상태 경로는 같은 목적으로
  `"\n\n"`를 쓰고 있었으므로 실행 중 경로만 누락된 것이었습니다. `text + L"\n" + ...`로 수정했고
  실제 창에서 확인했습니다: `space 35`가 자기 줄에, `capture: ...`가 다음 줄에 나옵니다.
  회귀 검사는 이제 ①`capture:`가 **자기 줄에서 시작**하는지 ②**첫 줄에 `capture:`가 섞여 있지
  않은지** ③`running model:`이 자기 줄에 있는지를 확인합니다. 구분자를 제거하는 변경을 주입하면
  실패하는 것을 확인했습니다(CLI 쪽은 `"\n%s\n"`로 이미 올바르게 분리되어 있어 영향이 없습니다)
- **GUI 상태줄이 잘리던 결함 (수정)**: 상태줄 박스가 "마지막 컨트롤 아래 남은 공간"으로
  계산되어 **84 px**였는데, 실제로 표시해야 하는 텍스트는 실행 중 loopback 기준 **256 px**가
  필요했습니다. 즉 상태 텍스트의 **약 3분의 2가 보이지 않았고**, 잘리는 부분이 하필 마지막에
  붙는 **실행 통계와 오류 안내 문구**였습니다 — 문제가 생겼을 때 사용자가 읽어야 하는 내용입니다.
  실제 창에서 컨트롤의 폰트로 `DrawText(DT_CALCRECT)`를 호출해 측정했습니다(유휴 16 px,
  loopback 실행 256 px, 입력 장치 실행 192 px). 수정: 창 클라이언트 높이를 760으로 늘리고
  상태 박스를 `statusHeight()`(276 px)로 **명시**했습니다("남은 공간" 방식이면 다시 어긋날 수
  있으므로). 추가로 `create()`에 **레이아웃 불변식**을 넣어 `y + statusHeight() + margin > clientHeight()`이면
  창 생성을 실패시킵니다 — 이제 위쪽에 행을 추가하면 조용히 잘리는 대신 즉시 드러납니다.
  회귀 검사는 실행 중 상태에서 컨트롤 폰트로 필요한 높이를 재어 박스 높이와 비교합니다
  (`status text fits its box: needs 192 px of 276 px`). 두 방어를 각각 주입해 확인했습니다:
  원래 결함(560 창 + 남은 공간 계산)은 **창 생성 실패(exit 1)**로, 박스만 84 px로 줄이면
  검사가 **CLIPPED**로 잡아냅니다
- **maxBlockFrames 초과 패킷 처리 (실측)**: `--buffer-ms 250`/`500`으로 입력 장치를 열면 협상
  주기가 **12000 / 24000 프레임**이 되어 `maxBlockFrames`(8192)를 훨씬 넘습니다. 그 상태로 5초
  실행해도 **프레임 손실 없이(240,000) 종료 코드 0**이었습니다. 이는 `release()`가 제한된
  `frameCount()`가 아니라 **`GetBuffer`가 보고한 전체 패킷 크기**로 `ReleaseBuffer`를 호출한다는
  증거입니다 — 제한된 값을 넘기면 WASAPI가 `AUDCLNT_E_INVALID_SIZE`로 거부해 실패했을 것입니다.
  계약 문서(`Windows/WASAPI-CONTRACT.md`)의 해당 줄이 `ReleaseBuffer(frameCount, 0)`로 잘못
  적혀 있어 구현과 모순되었고, 이 측정으로 구현이 옳다는 것을 확인해 계약을 정정했습니다.
  참고로 loopback 엔드포인트는 `--buffer-ms`를 키워도 주기가 1056 프레임에 고정되어(오디오
  엔진이 자체 주기로 패킷을 냄) 이 경로는 입력 장치로만 재현됩니다
- **macOS CLI와의 옵션/오류 문구 일치 (검증 + 결함 수정)**: 문서가 "옵션 이름과 범위, 오류 문구는
  macOS CLI와 동일"이라고 주장하므로 실제 macOS 파서
  (`SystemAudioProcessor/Sources/SystemAudioProcessor/main.swift`의 `parseArguments()`)와
  항목별로 대조했습니다.
  - **옵션 이름·범위·클램프**: 공유 옵션 10종(`--intensity`, `--body`, `--output`, `--model`,
    `--exciter-os`, `--spatial`, `--listener-x/z`, `--stage-width`, `--space`)이 모두 존재하고,
    범위와 폴백도 `AudioSettings.normalized()`의 `finiteClamp`와 **정확히 일치**합니다
    (intensity 0~100/55, body 0~100/30, output -18~6/-1.5, listenerX -3~3/0, listenerZ -2.8~2.8/0,
    speakerWidth 0.6~3/1.65, space 0~100/35). 실측으로 확인: `--intensity 1e9`→100,
    `--intensity -5`→0, `--output 500`→6, `--output -100`→-18, `--stage-width 100`→3,
    `--listener-x 100 --listener-z -100`→`x=3.00 z=-2.80`. 비유한 값(`nan`/`inf`/`±Infinity`)은
    macOS의 `isFinite` 검사와 동일하게 **거부**됩니다
  - **오류 문구 (수정한 결함)**: macOS는 각 옵션에서 "값이 없음"과 "값이 숫자가 아님"을 **하나의
    guard로** 처리하므로 두 경우 모두 같은 메시지를 냅니다(`--intensity needs a number`).
    Windows는 `takeValue()`가 먼저 실패하면서 **`--intensity needs a value`**라는 다른 문구를
    냈습니다 — 공유 옵션 **10종 전부**에서 불일치였습니다. 이제 각 옵션이 자신의 메시지를
    `takeValue()`에 넘겨 누락과 파싱 실패가 같은 문구를 냅니다(`--model needs clean, circuit, or
    highexciter`, `--spatial needs on or off` 등). 실측 결과 **누락 10종·잘못된 값 10종 모두
    불일치 0**입니다. 회귀 검사에 이 20가지 경우를 넣었고(이유 문구까지 확인), 일반 문구로
    되돌리는 변경을 주입하면 `expected the reason to mention 'needs a number'`로 실패합니다
- **재개방 시퀀스 (실제 장치)**: 엔진이 복구 시 수행하는 `close()` → 저장된 옵션으로 `open()` →
  재개를 실제 엔드포인트에서 확인. 캡처/렌더 모두 재개방 후 같은 엔드포인트로 열리고 패킷/오디오를
  다시 받음. `close()`가 실패 분류를 지우는 것도 확인
- **복구 루프 판단 (`--self-test`의 loop decision)**: 캡처/렌더 루프가 따르는 판단을 오프라인으로
  전수 검사합니다. 열린 엔드포인트의 정상 동작, 손실 시 재개방, **재개방 실패 후 재시도**,
  예산 소진 시 중지, 복구 불가 시 즉시 중지(엔드포인트가 닫혀 있어도), 그리고 영구 부재 장치가
  정확히 예산 횟수만큼 시도한 뒤 종료되는지까지 확인합니다. 이 판단 로직에 결함 4종을 주입해
  검사가 실제로 잡아내는지도 확인했습니다
- **복구 불가 시 즉시 종료**: 출력 엔드포인트를 다른 프로세스가 독점 점유한 상태에서 엔진이
  **0.08초** 만에 실패하고 종료 — 재시도 예산을 낭비하지 않음
- **장치 부재 분류 (실제 API 응답)**: 존재하지 않는 엔드포인트 id로 열면
  `HRESULT_FROM_WIN32(ERROR_NOT_FOUND)`(0x80070490)가 돌아오고 `deviceLost`로 분류됨.
  이는 "장치가 뽑혀 있는 동안 재개방이 실패하는" 바로 그 경우이므로 복구 가능해야 합니다.
  `--self-test`에 포함되어 CI에서도 실행됩니다
- **COM apartment 수명**: `open()` 실패 후 객체를 파괴하는 경로가 접근 위반으로 죽지 않음.
  `--self-test`가 이 경로를 실행합니다(실패한 open 이후 `close()` + 소멸)
- **독점 모드 충돌 (실제 장치)**: 다른 프로세스가 출력 엔드포인트를 독점 모드로 점유한 상태에서
  엔진이 `AUDCLNT_E_DEVICE_IN_USE`(0x8889000A)로 실패하고 이를 `fatal`로 분류(재시도 안 함).
  점유가 해제되면 같은 엔드포인트로 정상 시작 — 장치 문제가 아니라 구성 충돌임을 확인.
  CLI와 GUI 양쪽에서 오류가 사용자에게 그대로 표시됨
- 자기 캡처 방지: 같은 엔드포인트 조합이 거부됨 (CLI, GUI 양쪽)
- rate 불일치 처리: AUTOCONVERTPCM으로 렌더 스트림이 캡처 rate로 열림

검증하지 않은 것 (또는 부족한 것):

- **서로 다른 두 장치 간 라우팅**: 위 검증 항목대로 **검증했습니다** — 경로 개방, 오류·dropped 0,
  그리고 **렌더 엔드포인트 자신의 loopback으로 처리된 오디오가 그 장치에 도달함**까지 확인했습니다
  (idle 기준선 0 패킷 → 엔진 렌더 중 501 패킷 / peak 0.260078). 다만 두 번째 출력이 HDMI/모니터
  계열이라 **사람이 실제로 소리를 듣고 평가하지는 않았습니다** — 청취 품질 평가는 여전히 하지
  않았습니다.
- **실측 지연 (buffer duration)**: `--buffer-ms`가 실제로 어떻게 협상되는지 **7개 값**으로
  측정했습니다. 48 kHz 엔드포인트에서 1·5·20 ms 요청은 모두 장치 최소값(**1122 프레임 = 23.4 ms**)으로
  클램프되고, 50 ms → 2400 프레임(50.0 ms), 100 ms → 4800 프레임(100.0 ms), 500 ms → 24000
  프레임(500.0 ms)로 **정확히 반영**됩니다. 즉 20 ms 이하 요청은 구분되지 않고 모두 같은 최소값을
  받으며, 그보다 큰 요청은 요청값 그대로입니다. 캡처 측도 같은 방식으로 보고됩니다. 이 값은
  협상된 버퍼를 스트림 rate로 나눈 것이며, 캡처 대기 + DSP + 렌더 대기의 왕복 지연이 아닙니다.
- **`GetStreamLatency()`는 이 엔드포인트에서 0을 보고합니다.** 공유 모드 엔드포인트가 이 값을
  제공하지 않는 경우가 있으므로, 엔진은 버퍼 duration을 함께 보고하고 0을 "측정 불가"로
  안내합니다. 0을 실제 지연으로 오해하지 않도록 출력에 note를 붙입니다.
- **`Underrun samples`를 정확히 해석해야 합니다.** 이 값은 **길이에 비례하지 않습니다**:
  30초 실행 6144, 90초 3264, 180초 5184, 240초 5184 샘플로 모두 렌더 버퍼 2~3개(≈54 ms) 수준이며
  실행이 길어져도 늘지 않았습니다. 즉 **시작 시점의 일회성 프라임 부족**이고 지속적인 고갈이
  아닙니다. `--verbose`가 2초마다 `frames / dropped / underrun / buffered`를 출력하므로, 값이
  계속 증가하는지 화면에서 바로 구분할 수 있습니다. 값이 계속 증가하면 캡처 쪽이 따라가지 못하는
  것이고, 고정되어 있으면 초기 과도 상태입니다. (298초 관찰에서 버퍼 잔량이 순간적으로 0을 찍은
  적이 있으나 그때도 underrun은 늘지 않았고 프레임은 계속 증가했습니다 — 실제 샘플 손실 없음.)
- **실제 장치 제거/재연결로 복구를 끝까지 재현하지 못했습니다.** 재개방 시퀀스(`close()` →
  `open()` → 재개)는 실제 엔드포인트에서 검증했고 실패 분류도 검증했지만, 실제로 장치를
  뽑았다 꽂아 `AUDCLNT_E_DEVICE_INVALIDATED`를 발생시켜 **자동 복구가 스트림을 이어가는 것까지는
  확인하지 못했습니다.** 이 워크스테이션에서 장치를 비활성화하려면 관리자 권한이 필요하고
  (`Disable-PnpDevice` 실패, 오디오 서비스 재시작 실패, 현재 프로세스는 비관리자), 독점 모드로
  스트림을 점유해 오류를 유도하는 것도 이 엔드포인트에서 불가능했습니다(exclusive Initialize가
  `0x88890008`로 거부됨). 따라서 "복구 코드 경로가 옳다"는 근거는 정책 단위 검사 + 실제 재개방
  시퀀스 검사이며, "장치를 뽑으면 자동으로 이어진다"는 실기기 관찰은 없습니다.
- **Bluetooth 장치에서 실행 검증하지 않았습니다.** 이 환경에 Bluetooth 오디오 장치가 없습니다.
- **독점 모드 상호작용**: 다른 앱이 출력 엔드포인트를 독점 모드로 잡고 있으면 엔진은
  `AUDCLNT_E_DEVICE_IN_USE`(0x8889000A)로 시작에 실패합니다. 이 실패는 **복구 불가로 분류**되어
  재시도하지 않고 즉시 보고합니다 — 장치가 사라진 것이 아니라 사용 중이므로 다시 열어도 해결되지
  않기 때문입니다. 다른 앱이 놓으면 같은 엔드포인트로 정상 시작되는 것도 확인했습니다.
  CLI와 GUI 모두 실패 이유를 그대로 표시합니다.
- **4×/8× 출력 오버샘플링, dither/noise shaping, DSD**는 Windows 엔진에 연결되어 있지 않습니다
  (macOS도 live 출력은 PCM 2×만 연결되어 있습니다). Core의 `PcmResampler`는 4×/8× 계수도
  지원하지만 엔진이 그 경로를 사용하지 않습니다. **live PCM 2×를 켠 경우에도 Windows는 그
  단계를 실행하지 않으므로** 그 구성에서는 macOS와 다릅니다 — 다만 기본값(비활성 + bypass)에서는
  위 검증 항목대로 샘플이 일치합니다.
- **`--self-test`의 DSP 검사는 48 kHz 단일 레이트에서 실행됩니다.** 샘플레이트 매트릭스는
  44.1k~768k에서 유한/비음수를 확인하지만, 청취 품질이나 레이트별 음색 변화는 평가하지 않습니다.

빌드 성공이나 오프라인 테스트 통과는 장치 권한, 하드웨어 협상, 청취 품질, 장치 전환 안정성을
의미하지 않습니다.

GUI에 대해 검증하지 않은 것:

- **화면 캡처로 전체 배치를 확인하지 못했습니다.** 도구(`scripts/capture-window.py`)로 창을
  이미지로 저장했지만, `PrintWindow`가 일부 정적 텍스트를 다시 그리지 않아 캡처본에는 값
  표시가 일부 비어 있습니다. 대신 실제 창에서 컨트롤을 열거해 **모든 컨트롤과 값 표시가
  존재하고 올바른 값**임을 확인했습니다(위 검증 항목). 시각적 배치는 열거 결과(좌표·크기)로
  확인했으며, 픽셀 단위 렌더링 품질을 평가하지는 않았습니다.
- **다중 모니터·고DPI에서 확인하지 않았습니다.** 창은 고정 크기이고 DPI 인식 설정을 하지
  않았으므로, 배율이 100%가 아니면 레이아웃이 달라질 수 있습니다.
- **GUI 슬라이더 드래그는 실제 마우스 입력으로 검증했습니다**(위 검증 항목). 7개 슬라이더를
  양 끝과 중간으로 드래그해 값 표시가 썸을 따르는지 확인하며, 이 경로에서 `WM_HSCROLL` 미처리
  결함을 발견해 수정했습니다. 다만 **드래그 중 연속적인 중간 프레임**까지 검증하지는 않았습니다 —
  각 지점에서 최종 위치와 표시가 일치하는지만 확인합니다.
- **GUI에서 청취 품질을 평가하지 않았습니다.**

## 저장소 구조 (Windows 관련)

```text
Windows/CMakeLists.txt              Windows 빌드 정의 (엔진 라이브러리 + CLI + GUI)
Windows/WASAPI-CONTRACT.md          장치 계층의 동결된 계약
Windows/Source/AudioEngine/         장치·엔진·DSP 스테이지·오프라인 검사
Windows/Source/CLI/                 CLI 인자 파싱과 진입점
Windows/Source/GUI/                 GUI 창·컨트롤 (엔진 API만 사용)
scripts/build-windows-cli.bat       빌드 + 검사
scripts/check-windows-cli.py        CLI 인자 회귀 검사 (장치 불필요)
scripts/check-windows-ui-independence.py  엔진/DSP의 UI 비종속 검사 (컴파일러·장치 불필요)
scripts/check-windows-system-audio.py  시스템 오디오 캡처 검증 (장치 필요)
scripts/check-windows-gui-controls.py  GUI 컨트롤 목록 검사 (장치 불필요)
scripts/check-windows-gui-sliders.py  GUI 슬라이더 실드래그 검사 (장치 불필요, 입력 데스크톱 필요)
scripts/check-windows-gui-refresh.py   GUI 장치 선택 유지 검사 (장치 불필요)
scripts/check-windows-cross-device.py  서로 다른 두 장치 간 라우팅 검사 (출력 장치 2개 필요)
scripts/check-windows-render-landing.py  렌더 장치 도달 A/B 검사 (출력 장치 2개 + 톤 재생)
scripts/check-windows-gui.py        GUI 조작 검증 (장치 필요)
scripts/capture-window.py           창 캡처 (시각 확인용)
scripts/run-windows-cli.py          제한 시간 실행 + 통계 보고
Source/Core/                        공유 DSP (Windows가 그대로 사용)
```

## 참고 문서

| 문서 | 내용 |
|---|---|
| [Windows 포팅 계획](windows-port-plan.md) | 단계, 아키텍처 결정, 조사 근거 |
| [WASAPI 계약](../Windows/WASAPI-CONTRACT.md) | 장치 계층이 지켜야 하는 계약 |
| [Core 아키텍처](cross-platform-core-architecture.md) | Core와 두 플랫폼의 관계 |
| [HighExciter Oversampling](high-exciter-oversampling.md) | 배율 정책 |
| [개발 가이드](development.md) | macOS 빌드와 검증 |
