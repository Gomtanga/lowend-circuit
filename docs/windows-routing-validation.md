# Windows 가상 케이블 라우팅 검증

[← 홈](../README.md) · [Windows 개발 가이드](windows.md) · [Windows 포팅 계획](windows-port-plan.md)

> 이 문서는 **외부 가상 오디오 케이블을 사용하는 라우팅 이정표** 하나의 검증 기록입니다.
> 이 이정표는 VB-CABLE 같은 **외부 드라이버 설치를 전제로 하는 프리뷰**이며, LowEnd가 자체
> 가상 드라이버·APO·기본 장치 자동 전환을 제공한다는 뜻이 아닙니다. 장기 목표(투명한 in-graph
> 처리)는 [Windows 포팅 계획](windows-port-plan.md)의 Phase 2.5 결정 그대로 유지되며 이 문서가
> 그것을 바꾸지 않습니다.

## 1. 이정표의 경로와 범위

기준 경로:

```text
Windows 기본 재생 장치 또는 테스트 앱 출력
  → VB-CABLE의 재생 엔드포인트 CABLE Input   (앱이 재생하는 쪽)
  → VB-CABLE의 녹음 엔드포인트 CABLE Output  (그 신호를 실어 나르는 쪽)
  → LowEnd의 일반 WASAPI capture (eCapture, loopback=false)
  → 기존 lowend_engine / Source/Core
  → 사용자가 명시적으로 선택한 ZH3 렌더 엔드포인트
```

* LowEnd GUI의 Capture에는 `Input: CABLE Output`을 고르는 것이 기준이며 `System audio: <출력>`
  (loopback)이 아닙니다.
* 최종 출력은 **사용자가 고른 물리 장치의 endpoint ID로 고정**됩니다. 케이블로 바뀐 Windows
  기본 출력을 따라가지 않습니다.
* 케이블의 두 endpoint는 서로 다른 ID이지만 **하나의 신호 경로**입니다. 그래서 "ID가 다르니
  안전하다"고 판단하지 않고, 별도의 순환 가드를 둡니다(4절).

이 이정표가 제공하지 않는 것: 자체 가상 드라이버, APO, 기본 장치 자동 전환, 무설정 배포,
모든 앱/DRM/독점 모드 호환성, 사람의 청취 품질 평가.

## 2. 검증 환경

| 항목 | 값 |
|---|---|
| 날짜 | 2026-09-15 |
| OS | Windows 11 (10.0.26200.9457), x64 |
| 툴체인 | Visual Studio 2022 Community, MSVC toolset 14.44.35207, CMake 3.31.6-msvc6 |
| 브랜치 | `feature/windows-virtual-routing` (PR #24 `feature/windows-port` head `400fa25` 기반) |
| PR #24 실행 시점 재확인 | 2026-09-15: `state=open`, `merged=false`, `draft=false`, head `400fa2574472907294b834a97a0985e6cb0f5568`, base `main`(`52f745421cf17e5f070c690263ec8d79f51ff3ae`), `mergeable_state=clean`. 따라서 후속 PR의 base는 `feature/windows-port`입니다 |
| 이정표 시작 시점의 HEAD | `400fa2574472907294b834a97a0985e6cb0f5568` |
| 코드 검증 대상 commit | `6d6eefa` — 이 커밋에서 Windows(3잡)·Core(4잡)·macOS CI가 모두 success입니다. 그 뒤 **C++ 변경은 `a06240f` 하나**입니다: `--self-test`의 충돌 fixture를 실제 머신에서 복사한 endpoint id 대신 합성 id로 바꾸고 `AGENTS.md`에서 실제 절대 경로를 지운 위생 커밋이며 **동작은 바뀌지 않습니다**(fixture는 모양만 유지). `2d0517c`는 검사 스크립트(`scripts/check-windows-route-stability.py`)만 추가했고 나머지는 문서입니다. 이 문서가 마지막으로 CI를 확인한 commit은 `66468b9`이고 거기서 16/16 check success였습니다. 이 문서를 고치는 commit 자체가 그 뒤에 오는 문서 커밋이므로, 위 문장은 "그 뒤 커밋에 C++ 변경이 없다"는 뜻을 유지합니다(확인: `git log --oneline 6d6eefa..HEAD -- Windows/Source`). 브랜치 tip의 현재 CI는 PR #25의 checks에서 확인합니다 |
| 이 표의 실기기 측정을 만든 바이너리 | 이 브랜치에서 빌드한 `build/win-cli/Release/lowend_windows.exe`(CLI)와 `build/win-cli/Release/lowend_gui.exe`(GUI 행), 그리고 `build/win-routing-no-ui/Release/lowend_windows.exe`(no-UI 행)입니다. 측정은 `296efd3` 이후 빌드로 시작했고, **마지막 C++ 변경(`a06240f`) 이후에 세 바이너리가 모두 다시 만들어졌습니다** — 파일 시각이 CLI·GUI 02:05:17, no-UI 02:06:09로 마지막 C++ 소스 시각 02:05:13보다 새것이고, `SelfTest.obj`도 소스보다 새것임을 확인한 다음 `--self-test`를 재실행해 통과시켰습니다. GUI 소스(`MainWindow.obj`, 09-16)는 그 뒤 바뀌지 않았습니다. 그 뒤 커밋은 문서뿐이므로 이 표의 숫자는 현재 C++ 소스와 같은 동작의 바이너리에서 나온 것입니다. "Release"라는 디렉터리 이름을 근거로 삼지 않습니다 |
| 이 저장소의 빌드 산출물 | `build/win-cli/Release/lowend_windows.exe`, `build/win-cli/Debug/lowend_windows.exe`, `build/win-cli/Release/lowend_gui.exe`, `build/win-routing-no-ui/Release/lowend_windows.exe` |

### 이 워크스테이션의 오디오 엔드포인트 (검증 시점)

| 흐름 | 이름 | 버스 | 포맷 |
|---|---|---|---|
| 출력 (기본) | Fosi Audio ZH3 | USB | 48000 Hz / 2 ch / 32-bit |
| 출력 | CABLE Input (VB-Audio Virtual Cable) | ROOT | 48000 Hz / 2 ch / 32-bit |
| 출력 | CABLE In 16ch (VB-Audio Virtual Cable) | ROOT | 48000 Hz / 2 ch / 32-bit |
| 출력 | Odyssey G5 (NVIDIA High Definition Audio) | HDAUDIO | 48000 Hz / 2 ch / 32-bit |
| 출력 | Realtek Digital Output | HDAUDIO | 192000 Hz / 2 ch / 32-bit |
| 입력 (기본) | WO Mic Device | ROOT | 48000 Hz / **1 ch** |
| 입력 | CABLE Output (VB-Audio Virtual Cable) | ROOT | 48000 Hz / 2 ch / 32-bit |

VB-CABLE(VB-Audio Virtual Cable, `VBCABLE_Driver_Pack45`)은 **사용자가 2026-09-18에 설치**했습니다.
설치는 외부 드라이버 조작이라 이 저장소의 도구가 대신 실행하지 않습니다. 이 드라이버는 PnP
인스턴스 하나(`ROOT\MEDIA\0001`)에 재생 2개(`CABLE Input`, `CABLE In 16ch`)와 녹음 1개
(`CABLE Output`)를 노출합니다.

### 지원 포맷 열거 (실측 기준 구성)

기준 실측은 **48 kHz stereo**에서 합니다. 이 머신에서 `--list-devices`가 보고하는 mix format은
다음이 전부입니다:

| 엔드포인트 | 흐름 | mix rate | 채널 |
|---|---|---|---|
| Fosi Audio ZH3 (기본 출력, 이정표의 목적지) | render | 48,000 Hz | 2 |
| CABLE Input / CABLE In 16ch (VB-Audio) | render | 48,000 Hz | 2 |
| CABLE Output (VB-Audio) | capture | 48,000 Hz | 2 |
| Odyssey G5 | render | 48,000 Hz | 2 |
| Realtek Digital Output | render | 192,000 Hz | 2 |
| WO Mic Device | capture | 48,000 Hz | **1 (모노)** |

* **44.1 kHz 및 96 kHz 구성은 이 머신에 존재하지 않습니다**(해당 mix rate를 가진 엔드포인트 없음).
  따라서 그 구성은 **검사하지 않았고, 검사했다고 주장하지 않습니다.** 케이블·DAC을 추가해 그러한
  장치가 생기면 같은 검사를 그 구성에서 실행해야 합니다.
* 케이블 경로의 기준 구성은 capture 48 kHz(케이블 녹음 쪽) → render ZH3 48 kHz입니다. 렌더
  스트림은 **캡처 장치의 rate로 열리고**, 엔드포인트 mix rate가 다르면 Windows 오디오 엔진의
  문서화된 컨버터가 한 번 변환합니다(PR #24에서 48↔192 kHz 양방향으로 확인됨).
* 이 머신의 유일한 입력 장치는 48 kHz **모노**입니다. 모노 입력의 채널 확장은 기존 경로가
  처리하며, 이 문서의 톤 검증은 **스테레오 소스**(케이블 경로) 기준입니다.

**가상 케이블 설치됨(2026-09-18).** 사용자가 VB-CABLE을 설치한 뒤 `--list-devices`는 `CABLE Input`
/ `CABLE In 16ch` ↔ `CABLE Output`을 한 장치로 묶어 보고합니다. 케이블을 지나는 **핵심 경로는
실행 검증됐습니다**(3절의 케이블 경로 행). 케이블 경로의 **30분 연속 검증은 2회 실행되어 1차 실패·
2차 통과**했고(사유·기전·두 표본은 4절 FAILED), **GUI의 케이블 라벨과 시작 안내 분기도 실제 창에서
관측**했습니다(3절). 재개방 가드의 실기기 충돌 상황 등 남은 항목은 SKIPPED 표에 있습니다.

## 3. 검증 결과

### VERIFIED (실행하고 관찰함)

| 항목 | 명령 | 관찰 |
|---|---|---|
| Release 빌드 + 오프라인 검사 | `scripts\build-windows-cli.bat Release` | exit 0: `ctest` 1/1, CLI 인자 회귀 33건(그중 25건은 거부 사유 문구까지), UI 비종속 검사(엔진 13개 소스), 케이블 검사기 self-check |
| Debug 빌드 | `scripts\build-windows-cli.bat Debug` | exit 0, 동일 검사 통과 |
| GUI 비활성 빌드 | `cmake -S Windows -B build/win-routing-no-ui -DLOWEND_WINDOWS_BUILD_GUI=OFF -DLOWEND_WINDOWS_BUILD_TESTING=ON` + `cmake --build` + `ctest` | 구성·빌드·ctest 통과(`NO_UI_BUILD_OK`) |
| 오프라인 검사 (신규 포함) | `lowend_windows.exe --self-test` | **23개 검사** 전부 통과(실행 출력의 섹션 배너를 세어 확인). 신규 2개: `routing: pass-through feedback rule`, `routing: endpoint selection and capture mode` |
| 장치 열거에 버스/케이블 정보 | `lowend_windows.exe --list-devices` | 각 행에 `bus=`(USB/HDAUDIO/ROOT) 추가, 마지막에 `Virtual cables:` 절 |
| `--list-devices`의 케이블 짝 (설치 후) | `lowend_windows.exe --list-devices` | `CABLE In 16ch → CABLE Output`, `CABLE Input → CABLE Output` **두 줄만** 나옵니다(VB-CABLE 인스턴스 `ROOT\MEDIA\0001`의 재생 2개 × 녹음 1개). WO Mic(`ROOT\MEDIA\0000`)는 짝으로 묶이지 않고, 아래 `Software-bus endpoints NOT paired as one device` 절에 "다른 장치 인스턴스라 식별 불가"로 따로 보고됩니다 — 즉 `CABLE Input → 마이크(WO Mic)` 같은 거짓 짝이 사라졌습니다(아래 결함 행) |
| 경로 진단 (기본 선택) | `lowend_windows.exe --route-check` | `REFUSED (same endpoint)`, exit 1 — 기본 출력 loopback과 기본 렌더가 같은 ZH3 |
| 경로 진단 (입력 → ZH3) | `--route-check --input-device <mic> --device <zh3>` | `READY`, exit 0. 입력 라우트에서는 케이블 부재 안내가 note로 나옵니다(설치 전 기록) |
| **경로 진단 (케이블 → ZH3, 설치 후)** | `--route-check --input-device {0.0.1...8eb85364…}(CABLE Output) --device {0.0.0...275d2e95…}(ZH3)` | **`READY`, exit 0**: capture = `CABLE Output`(ROOT, 48 kHz/2 ch), render = `스피커(Fosi Audio ZH3)`(USB, 48 kHz/2 ch), 케이블 짝 2줄 표시. 스트림을 열지 않고 판정만 합니다 |
| **케이블 경로 실행 검증 (이정표의 핵심)** | `python scripts\check-windows-cable-route.py build\win-cli\Release\lowend_windows.exe --cable-playback {…368e189b…}(CABLE Input) --cable-recording {…8eb85364…}(CABLE Output) --output {…275d2e95…}(ZH3)` | **exit 0 · "cable route verified"**. 톤(440 Hz stereo, 진폭 0.40, 3초)을 **케이블 재생측 endpoint로** 보내고 **ZH3 자신의 loopback**을 관측: 기준값(목적지 직접) peak 0.307343 (L/R 동일), 440.0 Hz · **엔진 OFF: peak 0.000000, 프레임 0**(우회·중복 경로 없음) · **바이패스**: peak 0.307343 = 기준의 1.00×, 440.0 Hz, 양 채널 · **Circuit**: peak 0.213287 = **바이패스의 0.69×**, 440.0 Hz, 양 채널. 즉 앱이 케이블에 재생한 신호가 케이블 녹음측 → LowEnd DSP → 지정한 물리 출력까지 실제로 도달하며, 두 채널·피치가 유지되고 원본/처리본이 겹치지 않습니다. **이 검증은 디지털 경로 관측이며 사람의 청취 평가가 아닙니다** |
| 경로 진단 (캡처 모드 모순) | `--route-check --capture-device <입력 endpoint>` | `REFUSED (capture mode mismatch)`, exit 1 — "그 id는 입력 endpoint이므로 `--input-device`로 기록하라"는 다음 조치 출력 |
| 경로 진단 (사라진 렌더 id) | `--route-check ... --device {deadbeef-…}` | `REFUSED (render endpoint missing)`, exit 1 — 요청한 id를 그대로 지목, "재설치하면 새 id가 된다"는 다음 조치 |
| 캡처 덤프 | `--monitor 2 --input-device <mic> --dump-wav <file>` | 96,480 프레임 기록(2.01 s). Python `wave`로 읽어 2 ch / 48000 Hz / 16-bit / 96,480 프레임 확인. 이 입력 장치는 무음(peak 0.000000)을 보고했고, 덤프도 전부 0 |
| GUI 컨트롤 목록 | `python scripts\check-windows-gui-controls.py build\win-cli\Release\lowend_gui.exe` | 33개 컨트롤(콤보 4·트랙바 7·버튼 3·정적 19), 겹침 0, 클라이언트 영역 내 |
| GUI 슬라이더 경로 | `python scripts\check-windows-gui-sliders.py …` | 실제 마우스 드래그 21회, 모든 표시값이 썸을 따름 |
| GUI 새로 고침 후 선택 유지 | `python scripts\check-windows-gui-refresh.py …` | 캡처 선택 유지 확인(`Input: 마이크(WO Mic Device)`, index 3) + **라이브 경로 절반도 통과**: 실행 중 새로 고침 전후로 협상된 캡처 경로가 동일(`4회 연속 재현`). 이전 실행에서 이 절반이 SKIPPED로 보고된 것은 **하드웨어 한계가 아니라 그 시점의 저장된 선택이 자기 캡처 조합(기본 출력 loopback + 같은 출력 렌더)이었기 때문**입니다 — 그 조합은 가드가 정당하게 거부합니다. 선택을 입력 장치로 두면 같은 머신에서 라이브 절반이 통과합니다 |
| GUI 선택 저장·복원·거부 (신규) | `python scripts\check-windows-gui-persistence.py build\win-cli\Release\lowend_gui.exe` | (1) 저장된 endpoint가 있으면 그대로 선택됨 (2) 사라진 저장 id는 콤보를 비우고 Start가 "no longer present"로 거부 (3) 선택 변경이 사용자 설정 파일에 기록됨. 검사는 사용자의 실제 선택 파일을 백업·복원함 |
| 케이블 검사기 자체 판별력 (신규) | `python scripts\check-windows-cable-route.py --self-check` | 자기가 만든 신호로 통과/거부를 구별: 440 Hz·0.40·양 채널 신호는 수용, 무음·한쪽 채널만·디튠(404 Hz)·감쇠 없는 Circuit은 거부 |
| 순환 가드 규칙 (오프라인) | `--self-test`의 `routing:` 검사 2종 | 같은 **장치 인스턴스** + ROOT 버스의 재생/녹음 쌍은 충돌, USB 헤드셋의 마이크·스피커는 충돌 아님, 식별자를 못 읽으면 충돌 아님(식별 불가는 허용), 케이블 한쪽 + 물리 출력은 허용, **zero 컨테이너를 공유하는 두 소프트웨어 장치는 충돌 아님·짝 아님** |
| **테스트 톤 실기기 검증 (사용자 동의 후)** | `--monitor 5 --capture-device <ZH3>`(백그라운드, `--dump-wav` 동시 기록) + `--play-tone 3 --device <ZH3>` | `--play-tone`: 144,000 프레임(3.00 s) 기록, peak 0.400000, 양 채널. 동시에 관찰한 **ZH3 자신의 loopback**: 342 패킷/164,160 프레임, **input peak 0.399963 (L 0.399963, R 0.399963)**. 덤프를 검사기의 분석 코드로 읽어 **우세 주파수 440.0 Hz**, 2 ch, 48,000 Hz, 레벨·채널·피치 기준 전부 통과. 즉 지정한 endpoint로 보낸 신호가 그 endpoint의 loopback에서 그대로 관측됨 |
| **CLI 엔진 시작 가드 (실기기)** | `lowend_windows.exe --capture-device <ZH3> --device <ZH3>` (기본 loopback 흐름 + 같은 출력) | `Failed to start audio processing: capture and render resolved to the same endpoint (스피커(Fosi Audio ZH3)); … Pass --device with a different output endpoint to break the loop.` + **exit 1**, 즉시 종료(0.14초). 스트림이 열린 채로 남지 않고, 우회 플래그 없이 거부됨. `--route-check`의 사전 판정과 별개로 **실제 엔진 `start()` 경로**가 하드웨어에서 거부하는 것을 확인 |
| **안정성·재시작 검사기 (신규, 명시적 ID)** | `python scripts\check-windows-route-stability.py <exe> --capture <id> --render <id> [--capture-mode input\|loopback] --minutes N --cycles N` | 입력 라우트(WO Mic → ZH3)로 3회 사이클 + 1분 연속 실행: 사이클마다 개방·dropped 0·오류 0, 연속 구간 frames 2,885,664·dropped 0·underrun 고정, 버퍼 추세 보고. **판별력 확인**: 존재하지 않는 endpoint를 주면 `the engine exited with code 1`·`no statistics were reported`로 **실패(exit 1)**, 같은 endpoint 양쪽 지정은 실행 전에 거부, 인자 누락은 사용법 오류로 거부. 30분 연속·10회 재시작의 고정 기준(장치 오류·dropped·정체·프라이밍 후 underrun 증가·버퍼 고갈)이 코드에 박혀 있어 케이블 설치 후 그대로 실행합니다 |
| 주입(mutation) 시험 | 아래 참조 | 새 검사가 실제로 결함을 잡는지 확인 |
| **30분 연속 재생 (실제 장치, 케이블 경로 아님)** | capture = WO Mic(무음 전달), render = ZH3, `--model circuit --verbose`, 1800.3초 벽시계 | 865 샘플(2.1초 간격). **dropped 0 (전 구간), 캡처/렌더 오류 0, exit 0.** 처리 프레임 86,406,336 = 1800.13초분, 벽시계 대비 **−0.068초** 드리프트(누적 없음). 프레임 단조 증가. **underrun은 프라이밍 구간에 4,992로 확정된 뒤 안정 구간에서 5,568~5,952(델타 384 샘플 = 4 ms)로 사실상 고정**, 62.0 ms(렌더 버퍼 약 3개). `Resyncs 1`(시작 시 1회) |
| 30분 실행의 버퍼 추세 (쏠림 여부) | 같은 로그의 `buffered` 열, 3분 창 9개 | 창별 평균 2,545 → 2,889 → 3,004 → 3,206 → 3,411 → 3,725 → 3,808 → 4,032 → 4,119 샘플. 선형 기울기 **+1.07 샘플/초** → 30분 동안 약 1,929 샘플(≈1.8 렌더 주기) 증가. 링 용량은 131,072 샘플(65,536 프레임)이므로 **용량의 약 1.5%**이며, 고갈(buffer 0)이나 포화 방향이 아니라 완만한 상승입니다. 후반에도 min이 0에 닿지 않고 max가 5,760에서 멈춥니다(주기 1,056프레임의 약 5.5개). **두 장치의 clock 차이가 원인이면 선형으로 계속 늘어야 하므로**, 이 추세는 정상 범위로 기록하되 **"완전히 평형"이라고 주장하지 않습니다** |
| **정지/재시작 10회 (실제 장치, 케이블 경로 아님)** | 같은 라우트에서 시작→8초 실행→Ctrl-Break 정지, 10회 반복 | **10/10 경로 개방, exit code 전부 0, 캡처/렌더 오류 0, dropped 0.** 사이클별 처리 프레임 381,408~387,744(≈8.0초), underrun 2,112~5,952(프라이밍), Resyncs 1~2. 즉 반복 시작/정지에서 장치가 매번 정상 개방되고 통계가 매 실행 새로 집계됨 |
| **위 두 항목을 저장소 검사기로 재실행 (같은 입력 라우트, 케이블 경로 아님)** | `python scripts\check-windows-route-stability.py build\win-cli\Release\lowend_windows.exe --capture <WO Mic 입력 id> --render <ZH3 id> --capture-mode input --minutes 30 --cycles 10` | **통과 `route stability checks passed`, exit 0, 벽시계 1,881.76초**. 사이클 10/10 각 8.0초: dropped 0·장치 오류 0/0·Resyncs 1, 처리 프레임 293,760~390,336, underrun 1,152~5,952(프라이밍). 연속 구간 **30.0분·프레임 86,383,104·dropped 0·장치 오류 0/0·Resyncs 1**, underrun은 프라이밍에서 5,952로 확정된 뒤 **증가 없음**. 버퍼 192..5,760 샘플, 1/4분위 평균 2,229 → 4/4분위 3,637, 기울기 **+1.10 샘플/초**(1,800초에 ≈1,980 샘플 = 링 용량의 1.5%)로 고갈·포화 방향 아님. **앞의 두 항목(강제 하네스로 측정한 같은 라우트)과 같은 결론**이며, 이 실행은 **드레인 스레드 + 커버리지 가드가 들어간 뒤의 검사기가 직접 판정**했으므로 주장한 30분 구간을 실제로 덮습니다 — 가드가 없던 시절에는 첫 ~98초 샘플만으로도 "통과"가 나왔습니다 |
| **3상태(OFF/바이패스/Circuit) 방법을 실제 라우트에서 실행** (케이블 경로 아님) | 캡처 = ZH3 loopback(48 kHz) → 렌더 = Odyssey G5, 톤은 ZH3로. `--monitor 6 --capture-device <Odyssey>` + `--dump-wav`, 엔진 유/무, `--play-tone 3` | **OFF**: tone이 케이블 대신 ZH3로 갔고(이 실행은 케이블 대신 loopback 경로), Odyssey loopback은 **프레임 0** — 엔진이 없으면 목적지에 아무것도 도달하지 않음. **바이패스**(clean/0/0/0/spatial off): 228,000 프레임, peak **0.999054** (L 0.962952, R 0.999054), **440.0 Hz**. **Circuit**(기본): 223,680 프레임, peak **0.554871**, 440.0 Hz, 바이패스의 **0.555×**. 즉 이 방법(신호원→엔진→목적지 loopback 관측)이 실제 장치에서 동작하고, 두 채널·피치·DSP 감쇠가 관측됨 |
| 3상태 실행에서 드러난 판정 기준 결함 → 수정 | 위 실행의 레벨 | 바이패스 peak 0.999는 소스 진폭 0.40의 **2.5배**였습니다. 같은 엔진 출력이 어떤 endpoint의 loopback에서는 0.40으로, 다른 endpoint에서는 1.0으로 읽힙니다(엔드포인트 볼륨·드라이버 효과가 render 스트림과 loopback 탭 사이에 있음). 즉 "바이패스는 소스의 0.5~1.05배"라는 절대 기준은 **정상 경로를 실패로 판정**합니다. 검사기는 이제 엔진을 끈 상태에서 같은 톤을 **목적지 endpoint에 직접** 보내 그 loopback으로 기준값을 먼저 측정하고, 바이패스를 그 기준의 0.50~1.15배로 판정합니다. 기준을 얻지 못하면 상대 판정을 하지 않고 중단합니다 |
| 위 수정의 자체 검증 | `--self-check` | 기준 대비 0.75배 바이패스는 수용, **2.5배**(증폭·중복 경로)와 **0.25배**(무음 감쇠)는 거부, 감쇠 없는 Circuit은 거부 |
| **GitHub CI (푸시된 모든 커밋)** | push `814f29b` … `9d08c8f` → Actions | 현재 팁 `9d08c8f`에서 **16/16 job success**입니다(Windows Debug·Release·no-UI 3잡, Core ubuntu·windows × Debug·Release 4잡, macOS — 워크플로마다 PR용·푸시용 2회 실행되어 총 6개 워크플로). 이번에는 **자격 증명으로 잡 로그까지 읽어 단계별 자기 보고를 확인**했습니다: `windows-cli` 잡에서 CLI 검사(33 거부 사례)와 **GUI 컨트롤 목록·슬라이더 경로는 VERIFIED**, **새로 고침 선택 유지·선택 저장/복원 두 단계는 러너에 엔드포인트가 없어 스스로 `SKIPPED`**(실패 아님, 통과로도 세지 않음)로 보고했습니다. `2d0517c`, `a0e1ccb`, `8de1275`, `66468b9`도 16/16 — 이 브랜치의 푸시된 커밋은 모두 green입니다 |
| CI에서의 첫 시도 실패 → 수정 | push `254e8c2`, `d6d126c` → Actions | Windows 3개 잡이 모두 `check-windows-cli.py` 단계에서 실패했습니다(빌드·ctest는 통과). 원인은 검사가 **엔드포인트가 없는 러너**를 가정하지 않은 것 — `--route-check`가 없는 *render* id를 지목한다고 단정했지만, 엔드포인트가 하나도 없는 머신에서는 capture 쪽 기본 장치가 먼저 해석에 실패합니다. 엔드포인트 유무와 무관하게 같은 답을 내는 capture id 기준으로 바꾸고, 러너에 엔드포인트가 없을 때의 계약도 함께 검증하도록 고쳤습니다 |
| GUI 선택 저장 결함 (자체 발견·수정) | `check-windows-gui-persistence.py` 4단계 | 한쪽 콤보를 바꾸면 **저장 파일의 두 줄을 모두 다시 썼고**, 선택이 없는 쪽은 빈 값으로 기록되었습니다. 그러면 사용자가 고른 id가 지워지고 다음 실행에서 첫 목록 항목이 선택되어 **사용자가 고른 적 없는 endpoint로 시작**합니다(빈 콤보가 막으려던 바로 그 대체가 한 실행 뒤에 발생). 이제 선택이 없는 쪽은 이전 값을 유지합니다. 수정 전 빌드에서 새 단계가 `the file now holds ''`로 실패하고, 수정 후 통과하는 것을 확인했습니다 |
| GUI 시작 안내 결함 (자체 발견·수정) | 실행 중인 창의 상태 컨트롤을 직접 읽음 | 창을 열면 상태줄이 `Idle. Choose an output endpoint, then Start.`만 보였습니다. 케이블 안내와 "LowEnd는 Windows 기본 출력을 바꾸지 않는다 + 되돌리는 경로"는 `updateStatusText()`가 만들지만, 시작 시에는 그 함수를 부르지 않고 짧은 리터럴을 설정하고 있었습니다. 이제 `create()`가 장치 목록을 채운 뒤 `updateStatusText()`를 호출하고, GUI end-to-end 검사가 시작 시점에 그 안내(`virtual cable`, `Settings > System > Sound > Output`)가 화면에 있는지 확인합니다. **옛 시작 줄을 주입하면 검사가 실패**하는 것을 확인했습니다 |
| GUI end-to-end (재확인) | `python scripts\check-windows-gui.py build\win-cli\Release\lowend_gui.exe` | 같은 endpoint 시작 거부 → 입력 장치로 시작 → 통계 진행(20,928 → 165,504) → 실행 중 모델 변경이 오디오 스레드에 반영 → Stop → 재시작 시 통계 초기화(→ 21,792) → 두 번째 Stop → 정상 종료. 상태 텍스트가 박스에 맞음(192/276 px) |
| **GUI 5종 재실행 (현재 바이너리)** | `check-windows-gui-controls.py` · `-sliders` · `-refresh` · `-persistence` · `check-windows-gui.py`, 전부 `build\win-cli\Release\lowend_gui.exe` | 다섯 검사 모두 **exit 0**. 컨트롤 33개(combo 4·trackbar 7·button 3·static 19)가 760×760 클라이언트 안에 들어가고 겹침 없음 · 실제 드래그 21회에서 모든 readout이 썸을 따라감 · 새로 고침 후 캡처 선택(`Input: 마이크(WO Mic Device)`, index 2)과 라이브 라우트 유지 · 저장된 endpoint 복원, 사라진 endpoint는 콤보를 비우고 Start를 그 사유로 거부, 변경은 사용자 설정 파일에 기록, 한쪽 변경이 반대편의 저장된-없는 id를 지우지 않음(검사가 사용자 파일을 원복) · end-to-end: 통계 **21,792 → 165,984** 프레임, 실행 중 모델 변경이 오디오 스레드에 반영(`HighExciter`), Stop 후 재시작 시 통계 초기화(**165,984 → 22,752 → 167,424**), 두 번째 Stop 정상, 정상 종료. 위 GUI 행들의 수치(20,928 → 165,504 등)는 그때 빌드의 실행값이고, 이 재실행은 **현재 바이너리**에서 같은 동작을 다시 확인한 것입니다 |
| **GUI의 케이블 표시 (실기기 관측)** | `python scripts\check-windows-gui-controls.py` 로 창을 열고 Win32 `CB_GETLBTEXT`로 콤보 항목을 읽음 | 캡처 콤보: `Input: CABLE Output(VB-Audio Virtual Cable)  [virtual cable: recording side]`(녹음측 표시), `System audio: CABLE Input(…)/CABLE In 16ch(…)  [virtual cable: play into it]`(재생측 표시). 출력 콤보: `CABLE Input(…)`, `CABLE In 16ch(…)`에 재생측 표시. 즉 라벨 분기가 케이블이 있는 머신에서 실제로 켜집니다 |
| **GUI Idle 안내의 "케이블 감지" 분기 (실기기 관측)** | 같은 창에서 Static 텍스트를 읽음 | `Virtual cable detected: choose Capture "Input: CABLE Output(VB-Audio Virtual Cable)" and Output "스피커(Fosi Audio ZH3)", then set Windows' default output to the cable's playback side. …` + 복구 경로(`Settings > System > Sound > Output`) 문단이 시작 시점에 표시됩니다. 출력 예시가 **물리 장치**를 가리키는 것은 아래 결함 수정의 결과입니다 |
| **GUI end-to-end (케이블 설치 후 재실행)** | `python scripts\check-windows-gui.py build\win-cli\Release\lowend_gui.exe` | exit 0: 같은 endpoint 시작 거부 → 입력 장치로 시작 → 통계 진행(21,792 → 165,984) → 실행 중 모델 변경 반영 → Stop → 재시작 시 통계 초기화(22,080) → 두 번째 Stop 정상 종료. 시작 안내에 케이블 감지 문구와 복구 경로가 있는지도 검사합니다(신규 단언 포함) |
| **케이블 양쪽을 한 실행에서 사용 (실기기)** | `--route-check --input-device <CABLE Output> --device <CABLE Input>` · 같은 인자로 엔진 시작 | **둘 다 거부**: `--route-check` → `REFUSED (virtual pass-through pair)`, exit 1, 원인에 **장치 인스턴스 `ROOT\MEDIA\0001`**를 지목하고 다음 조치를 출력. 엔진 시작 경로도 `Failed to start audio processing: capture (CABLE Output…) and render (CABLE Input…) are the two sides of one virtual audio device, …` + **exit 1**로 같은 판정을 냅니다(설정 출력 후 즉시 종료, 우회 플래그 없음) |
| **케이블 짝 판정: 컨테이너가 아니라 장치 인스턴스 (실기기 검증에서 발견·수정)** | VB-CABLE 설치 후 `--list-devices` · `--route-check` | 짝 판정이 `PKEY_Device_ContainerId`를 비교했는데, Windows는 **root 열거(소프트웨어) 장치 전부에 같은 zero 컨테이너** `{00000000-0000-0000-FFFF-FFFFFFFFFFFF}`를 줍니다(VB-Audio 3개 endpoint·WO Mic·Realtek·NVIDIA가 모두 같은 값). 그 결과 ① 목록이 `CABLE Input → 마이크(WO Mic Device)` 같은 **실제로는 없는 짝**을 인쇄했고 ② 순환 가드가 **안전한 조합**(예: WO Mic 캡처 + CABLE Input 렌더)을 순환으로 오판할 수 있었습니다. 실제 구분자는 엔드포인트 속성 `{b3f8fa53-…},2`의 **PnP 인스턴스**(`ROOT\MEDIA\0001` vs `ROOT\MEDIA\0000`, ZH3는 `USB\VID_152A&…`)입니다. 이제 판정·키·거부 메시지가 모두 장치 인스턴스를 쓰고, 컨테이너는 **실제 값일 때만** fallback으로 씁니다. 수정 후 목록은 VB-CABLE 내부 조합 2줄만 남고 WO Mic는 "식별 불가" 절로 분리됩니다. `--self-test`에 회귀 3건 추가, **주입 시험에서 컨테이너 전용 판정으로 되돌리면 그 3건이 각각 다른 메시지로 실패**함을 확인 |
| **GUI 시작 안내가 출력으로 케이블 재생측을 가리킴 (실기기 검증에서 발견·수정)** | 창을 열어 Static 텍스트를 읽음 | 케이블이 있으면 `virtualCableNote_`가 Output 예시로 케이블의 **재생측** 이름(`CABLE In 16ch`)을 넣어 `Output "CABLE In 16ch(…)…-style physical device"`라고 표시했습니다. 이정표 경로의 출력은 **물리 장치**이고, 안내가 시키는 대로 케이블 재생측을 고르면 가드가 정당하게 거부합니다(사용자에게 모순된 지시). 이제 목록에서 **케이블이 아닌 출력**(기본 출력 우선)을 골라 이름을 넣고, 그런 장치가 없으면 "your physical output device"로 남깁니다. `check-windows-gui.py`에 **출력 예시가 케이블 재생측 이름을 포함하면 실패**하는 단언을 추가했고, **주입 시험(안내가 다시 케이블을 가리키게 되돌림)에서 그 검사가 exit 1로 실패**함을 확인했습니다 |
| 스크립트 인자 오류 (자체 발견·수정) | 각 검사 스크립트에 존재하지 않는 실행 파일 경로를 주고 실행 | 12개 검사 스크립트 전부 `pathlib`의 `FileNotFoundError` **트레이스백**을 내고 있었습니다 — 사용자가 안내서의 명령을 잘못된 빌드 경로로 실행하면 스크립트가 깨진 것처럼 보입니다. 이제 각 스크립트가 **자기 이름과 찾지 못한 경로**를 밝히고 빌드 명령을 안내한 뒤 **exit 1**로 끝냅니다(`check-native-cli.py`는 앱 경로를 받으므로 빌드 안내 없이 경로만). 12개 전부 트레이스백 없음·exit 1·자기 이름 표기 확인, 실제 실행은 그대로 통과(`check-windows-cli.py` 33 거부 케이스) |
| **안정성 검사기: 긴 실행의 통계를 중간부터 잃음 (자체 발견·수정)** | `check-windows-route-stability.py`로 30분 + 10회 실행 | 검사기가 자식의 파이프를 **읽지 않고** 잠든 뒤 마지막에 한 번만 수집했습니다. 엔진이 2초마다 찍는 통계가 64 KiB 파이프 버퍼를 약 97초에 채우고 그 뒤 출력은 버려져, **30분 실행이 첫 ~98초 샘플(프레임 4,643,904 ≈ 96.75초)만으로 "통과"**했습니다 — 판정 대상 구간은 건강했지만 **주장한 구간을 덮지 않았습니다**(검증 범위 ≠ 주장 범위). 이제 `start()`가 드레인 스레드를 띄워 실행 중 계속 읽고, `judge_run`이 **샘플이 요청 구간을 덮지 않으면 실패**로 판정합니다(커버리지 기준 신설). **검증**: 고정 버전은 2분 실행에서 샘플 118초·exit 0, old capture 동작으로 되돌린 mutant는 `only 98.0 s of statistics were captured for a 120 s run`으로 **exit 1** |
| **안정성 검사기: 순간적인 `buffer 0`을 고갈로 판정 (자체 발견·수정)** | 같은 30분 실행에서 | 기준이 프라이밍 후 `buffered == 0` **한 번**만으로 실패를 냈습니다. 그러나 이 브랜치의 기존 실측이 "렌더 버퍼 잔량이 0~3192 프레임에서 정상 진동(고갈이 아니라 평형)"이라고 기록하고 있고, 그 실행에서 **underrun은 증가하지 않았습니다**(4992 고정) — 렌더가 제때 공급받았다는 뜻입니다. 이제 **프라이밍 이후 샘플의 10% 초과가 0일 때만** 고갈로 판정하고, 순간 0은 보고 숫자(`buffer a..b`)로 남깁니다. **검증**: 같은 2분 실행이 `buffer 0..3840`·exit 0으로 통과 |


#### 주입 시험 (검사가 정말 잡는가)

| 주입한 결함 | 결과 | 되돌림 후 |
|---|---|---|
| `isVirtualEnumerator`가 항상 false (= 케이블 쌍을 식별하지 못함) | `--self-test`에서 **9건 실패**(케이블 쌍 충돌, 결합 규칙, 진단 3종, 목록 표시 등) | 재빌드 후 전부 통과 |
| 저장된 endpoint가 사라졌을 때 첫 항목으로 조용히 대체(원래 수정했던 결함의 재주입) | `check-windows-gui-persistence.py`가 **2건 MISMATCH** — "사라진 선택이 다른 endpoint로 대체됨", "Start가 잘못된 이유(HRESULT 0x8889000F)로 실패" | 재빌드 후 통과 |
| 시작 상태줄을 다시 짧은 리터럴로 되돌림 | `check-windows-gui.py`가 **실패** — "The startup status does not tell the user that LowEnd leaves Windows' default output alone …" | 재빌드 후 통과 |

### FAILED

**케이블 경로 30분 연속 검증 — 첫 실행이 고정 기준을 통과하지 못했습니다(exit 1).**

| 항목 | 명령 | 관찰 |
|---|---|---|
| **케이블 경로 30분 연속 (1차 실행, 실패)** | `python scripts\check-windows-route-stability.py build\win-cli\Release\lowend_windows.exe --capture {…8eb85364…}(CABLE Output) --render {…275d2e95…}(ZH3) --capture-mode input --minutes 30 --cycles 10` | **exit 1.** 사이클 10/10은 정상(각 8.0초, dropped 0·장치 오류 0/0·Resyncs 1, underrun 4,992~5,952 = 프라이밍). 연속 구간 30.0분: frames **86,352,864**, dropped **0**, 장치 오류 **0/0**, **Resyncs 2**(시작 1회 + 실행 중 1회), buffer **0..4,800**(1/4분위 평균 2,034 → 4/4분위 2,551, 기울기 +0.40/s). 판정 실패 사유: **`underrun grew by 6528 samples after priming (limit 4096)`** — 프라이밍 이후 무음 136 ms가 추가로 발생했습니다 |
| 위 실패의 기전 조사 (10분 계열) | 같은 라우트에서 `--verbose`로 600초 실행, 2초 간격 통계 47개 수집 | **underrun이 4,992에서 전혀 늘지 않았습니다**(증가 0), Resyncs 1(시작만), dropped 0, 장치 오류 0/0, frames 28,796,736(=599.9초). 20초·45초 실행에서도 underrun은 프라이밍 값에서 고정. 즉 실패는 **연속 드리프트가 아니라 30분 중 한 번 일어난 캡처 스트림 불연속**과 그 뒤의 링 재프라이밍 때문입니다 |
| 위 실패의 기전 | 엔진 코드: `runCapture()`가 `isDiscontinuity()`를 보면 `lc_ring_buffer_request_discard()`를 걸고, `runRender()`가 그 요청을 소비해 **백로그를 버리고 DSP 상태를 리셋**합니다(문서화된 정책: 끊긴 뒤의 오래된 오디오를 이어 붙이지 않음). 버린 백로그만큼 렌더가 무음을 쓰고, 그 무음은 링이 정직하게 underrun으로 셉니다. 같은 정책이 캡처 스트림 재개방에도 적용됩니다 | 이 실행의 +6,528 샘플은 그 재프라이밍 구간이며, **무음을 숨기거나 이전 샘플을 재생해서 없애지 않습니다**(이정표가 금지). 장치 오류·드롭·정체는 없었습니다 |

**정리**: 이 실패는 환경 부재가 아니라 실제로 관찰된 결과이며, 회피하지 않고 위에 그대로 기록합니다.
같은 고정 기준으로 **두 번째 표본**을 실행했고, 그 결과는 다음과 같습니다.

| 항목 | 명령 | 관찰 |
|---|---|---|
| **케이블 경로 30분 연속 (2차 실행, 통과)** | 같은 명령을 같은 endpoint로 재실행 | **exit 0 · `route stability checks passed`**, 벽시계 1,882.60초. 사이클 10/10 정상(각 8.0초, dropped 0·장치 오류 0/0·Resyncs 1). 연속 구간 30.0분: frames **86,353,536**, dropped **0**, 장치 오류 **0/0**, **Resyncs 1**(실행 중 재개방·불연속 없음), **underrun 5,952 고정**(프라이밍 이후 증가 **0**), buffer 0..5,568(1/4분위 평균 2,286 → 4/4분위 3,365, 기울기 +0.83/s) |

**두 표본의 판정**: 1차는 실행 중 캡처 스트림 불연속 1회로 기준을 넘겼고(기전은 위에 기록), 2차는 같은
경로·같은 기준에서 30분 내내 증가 없이 통과했습니다. 즉 이 기준은 **재현되지 않는 간헐적 이벤트**에
반응한 것이며, **두 실행을 모두 기록**합니다 — 2차 통과로 1차 실패를 지우지 않습니다. 케이블 경로의
안정성은 "2회 중 1회 실패, 실패 기전은 문서화됨"으로 남기고, "항상 안정"이라고 주장하지 않습니다.
3차 실행은 하지 않았습니다(같은 실패에 대한 근거 없는 반복을 피하기 위해).

### SKIPPED (관찰하지 못했으므로 성공의 근거가 아님)

| 항목 | 이유 | 필요한 것 |
|---|---|---|
| **재개방 시점의 순환 충돌(실기기, 장치 제거 필요)** | 규칙은 `--self-test`로, 재개방 경로는 정책 단위로 검증했고, 케이블 양쪽 사용은 실기기에서 거부되는 것을 확인했습니다(3절). 다만 **저장된 endpoint가 사라져 재해석이 케이블 양쪽에 떨어지는 상황**은 장치를 실제로 제거해야 만들 수 있어 관찰하지 않았습니다 | 장치 제거/재연결(관리자·물리 조작) |
| 물리 USB 탈착·Bluetooth 실행 검증 | 관리자 권한/장치 없음 | 별도 환경 |
| 사람의 청취 평가 | 이 문서가 주장하지 않는 영역 | 사람 |

**참고**: 케이블 경로의 3상태(OFF/바이패스/Circuit) 비교는 위 VERIFIED 표의 "케이블 경로 실행 검증" 행에서 실제 케이블 소스로 확인했습니다.

**정정 기록**: `check-windows-gui-refresh.py`의 라이브 경로 절반은 처음에 SKIPPED로 보고되었으나,
그 원인은 하드웨어가 아니라 **그 시점의 저장된 선택이 자기 캡처 조합**(기본 출력 loopback + 같은
출력 렌더)이었습니다. 그 조합은 가드가 정당하게 거부하므로 엔진이 시작되지 않았고, 검사는
"사용 가능한 쌍이 없다"고 잘못 결론지었습니다. 선택을 입력 장치로 둔 상태에서 4회 연속 통과했고,
VERIFIED 표로 옮겼습니다. SKIPPED를 하드웨어 부재로 단정하지 않는다는 규칙이 이 경우에도
적용됩니다 — 원인을 확인하기 전에는 "환경 때문에 못 봤다"고 쓰지 않습니다.

`--dump-wav`가 기록한 WO Mic 캡처가 무음이었던 것은 결함이 아닙니다: 그 장치는 실제로
무음(peak 0.000000)을 전달했고, 덤프는 그 사실을 그대로 기록했습니다.

테스트 톤 실행은 **대상(ZH3)과 레벨(진폭 0.40, 3초)을 먼저 알리고 사용자 동의를 받은 뒤**에만
수행했습니다. 그 실행은 `--play-tone`이 지정한 endpoint로 정확한 레벨의 신호를 보낸다는 것과
`--dump-wav`+분석 경로가 실제 장치에서 동작한다는 것을 보여 주지만, **DSP를 거치는 케이블 경로를
증명하지는 않습니다**(그 경로는 아직 SKIPPED입니다). 관찰에 사용한 loopback은 ZH3 자신의
것이므로, 이 측정으로 "신호원이 그 endpoint에 도달했다"까지만 말할 수 있습니다.

## 4. 이번 이정표가 추가한 것

| 영역 | 내용 |
|---|---|
| 장치 모델 | `DeviceInfo.enumeratorName` 추가(`PKEY_Device_EnumeratorName`). `EndpointIdentity`(id·컨테이너·버스)를 장치 계층이 `open()`에서 함께 해석해 두고 게시 |
| 순환 가드 | 같은 endpoint 금지에 더해 **하나의 가상 장치 양쪽 사용 금지**: 컨테이너가 같고 그 버스가 소프트웨어(ROOT)인 쌍은 하나의 신호 경로로 판정. 시작 시점과 **양쪽 재개방 직후**에 각각 검사(`routeFormsFeedbackLoop`). 우회 플래그 없음 |
| 경로 진단 (순수 함수) | `Windows/Source/AudioEngine/RouteDiagnosis.{h,cpp}`: 선택 해석(빈 id = 그 흐름의 기본 장치, 미상 id는 **대체 없이** 실패), 5가지 구분(케이블 미설치 / ZH3 같은 렌더 부재 / 원격 오디오만 존재 / 캡처 모드 모순 / 위험한 순환)과 각각의 원인·다음 조치 |
| CLI | `--route-check`(스트림을 열지 않는 사전 판정, exit 0/1), `--play-tone <초>`(지정한 endpoint로 440 Hz 0.40 스테레오 톤, 대상·포맷·레벨을 먼저 출력, 볼륨 변경 없음), `--monitor --dump-wav <파일>`(캡처 신호를 16-bit PCM WAV로), `--list-devices`의 `bus=` 열과 `Virtual cables:` 절, `--help` 갱신 |
| GUI | 장치 목록에 가상 케이블 표시(`[virtual cable: play into it]` / `[virtual cable: recording side]`), 캡처·출력 선택을 사용자별 설정에 저장·복원(`%LOCALAPPDATA%\LowEndCircuit\device-selection.txt`), 저장된 endpoint가 사라지면 콤보를 비우고 Start 거부, Idle 상태줄에 케이블 안내와 **정지 시 Windows 기본 출력을 되돌리는 수동 절차** 안내 |
| 테스트 | `--self-test` 라우팅 검사 2종(합성 endpoint, 장치 불필요), `scripts/check-windows-cable-route.py`(명시적 id + `--self-check`), `scripts/check-windows-gui-persistence.py`, `check-windows-cli.py`에 `--route-check`/`--play-tone`/`--dump-wav` 거부 및 진단 검증 추가 |
| CI | `windows-cli-ci.yml`에 GUI 선택 유지·선택 저장/복원·케이블 검사기 self-check 단계 추가(각 단계는 VERIFIED/SKIPPED를 요약에 기록) |

### 경로 진단이 구분하는 실패 (실제 출력)

```text
Result: REFUSED (same endpoint)
  cause: capture and render are the same endpoint (스피커(Fosi Audio ZH3) [Speakers]); …
Result: REFUSED (capture mode mismatch)
  cause: the requested capture endpoint ({0.0.1.…}) is an endpoint of the other flow than the
         selected capture mode
  next:  that id is an input endpoint: pass it to --input-device to record it, or …
Result: REFUSED (render endpoint missing)
  cause: no endpoint with the requested render id is present
  next:  run --list-devices and pass an id from that list; a disconnected output device
         (USB DAC, HDMI sink) must be reconnected, and a reinstalled one gets a new id
```

## 5. 실기기(가상 케이블) 검증 절차 — 실행 전 동의가 필요한 단계

아래는 **자동으로 실행하지 않았습니다.** 외부 드라이버 설치·재부팅·기본 출력 변경·테스트 톤
재생은 사용자 동의가 필요한 조작입니다.

1. **VB-CABLE 설치 (외부 드라이버, 사용자 결정)**
   - 공식 배포: <https://vb-audio.com/Cable/> (VBCABLE_Driver_Pack*.zip)
   - 설치: 압축 해제 후 `VBCABLE_Setup_x64.exe`를 **관리자 권한으로** 실행 → Install Driver →
     **재부팅**
   - 되돌리기: 같은 폴더의 `VBCABLE_Setup_x64.exe`를 관리자 권한으로 실행 → Uninstall Driver,
     또는 장치 관리자에서 `VB-Audio Virtual Cable` 제거 후 재부팅
   - LowEnd는 이 드라이버를 설치·삭제·배포하지 않습니다(저장소에도 포함하지 않음).
2. **확인**
   ```bat
   build\win-cli\Release\lowend_windows.exe --list-devices
   ```
   `Virtual cables (playback side -> recording side):` 절에 `CABLE Input → CABLE Output`이
   보여야 합니다. 두 id를 각각 복사해 둡니다.
3. **경로 판정 (소리 없음)**
   ```bat
   build\win-cli\Release\lowend_windows.exe --route-check --input-device "<CABLE Output id>" --device "<ZH3 id>"
   ```
   `Result: READY`가 아니면 4절의 cause/next를 따릅니다.
4. **테스트 톤 (소리 남)** — 대상·레벨을 확인한 뒤에만:
   ```bat
   rem ① 신호원: 케이블의 재생 쪽으로 3초간 440 Hz / 0.40
   build\win-cli\Release\lowend_windows.exe --play-tone 3 --device "<CABLE Input id>"
   ```
5. **엔진 실행(수동 확인)**
   ```bat
   build\win-cli\Release\lowend_windows.exe --input-device "<CABLE Output id>" --device "<ZH3 id>" --model circuit --verbose
   ```
6. **자동 검증(디지털 경로)**
   ```bat
   python scripts\check-windows-cable-route.py build\win-cli\Release\lowend_windows.exe ^
     --cable-playback "<CABLE Input id>" --cable-recording "<CABLE Output id>" --output "<ZH3 id>"
   ```
   이 검사는 네 번 측정합니다. (0) **기준값**: 엔진을 끈 채 같은 톤을 출력 endpoint 자신에게 보내
   그 loopback에서 관측(목적지 체인의 기준). (a) 엔진 정지 상태에서 케이블로 보낸 톤이
   목적지에 남지 않음 (`peak < 0.02`), (b) 바이패스가 그 **기준값의 0.50~1.15배**,
   (c) Circuit이 바이패스의 0.90배 이하, (d) 양 채널 모두 신호, (e) 우세 주파수가 440 ±10 Hz.
   판정 기준은 실행 전에 이 문서와 스크립트 상단에 고정되어 있고, 통과시키려고 사후에
   완화하지 않습니다.
7. **Windows 기본 출력을 케이블로 돌리는 경우(선택)**
   - 설정 → 시스템 → 소리 → 출력에서 `CABLE Input` 선택. 이때 **Windows의 일반 재생이 LowEnd를
     거쳐야만** ZH3로 나옵니다.
   - **LowEnd를 Stop하거나 종료하면 소리가 나지 않습니다.** 이 동작을 자동으로 되돌리지 않습니다.
     복구: 설정 → 시스템 → 소리 → 출력에서 `스피커(Fosi Audio ZH3)` 선택.
   - Windows의 "이 장치로 듣기"나 다른 앱의 중복 모니터링을 켜면 **처리되지 않은 원본이 ZH3로
     직접 흘러** 원본/처리본이 겹쳐 들립니다. 켜지 마세요. 켜져 있으면 검사 (a)에서 신호가
     잡히므로 검사가 실패합니다.
8. **30분 안정성**: 5절 명령을 `--verbose`로 30분 실행하고 초기 프라이밍 구간과 이후 통계를
   분리해 기록합니다. 안정 구간에서 장치 오류·dropped·underrun 증가·정체·지속적 버퍼 쏠림이
   나타나면 "안정화 완료"로 표시하지 않습니다. `underrun < 1%` 같은 임의 기준을 정상의 근거로
   쓰지 않습니다.
9. **정지/재시작 10회** 및 GUI에서 선택 저장·복원 확인.

## 6. 신호 검증 기준 (실행 전 고정)

| 기준 | 값 | 의미 |
|---|---|---|
| 엔진 OFF 시 목적지 loopback | `peak < 0.02` | 우회·중복 경로가 없음 |
| 목적지 기준값(reference) | 같은 톤을 **출력 endpoint에 직접** 보내 그 loopback에서 측정 | 이 머신·이 endpoint에서 목적지 체인이 0.40 톤을 어떻게 보고하는지. 아래 두 레벨 기준은 이 값에 대한 **상대** 비율입니다 |
| 바이패스(−model clean −intensity 0 −body 0 −output 0 −spatial off) | **측정된 기준값의 0.50~1.15배** | 경로가 신호를 그대로 전달(증폭·중복·감쇠 없음) |
| Circuit(기본) | 바이패스의 0.90배 이하, 그리고 ≥ 0.02 | DSP가 실제로 경로에 있음 |
| 채널 | 좌·우 모두 ≥ 0.02 | 스테레오가 그대로 도달 |
| 피치 | 우세 주파수 440 ± 10 Hz | 잘못된 rate로 재생되지 않음 |

기준선(바이패스/엔진 OFF)은 **두 실행이 같은 소스·같은 endpoint·같은 세션 볼륨**에서 측정합니다.
바이패스 기준이 절대 진폭이 아니라 **목적지에서 측정한 기준값**인 이유는 3절의 "3상태 실행에서
드러난 판정 기준 결함" 항목에 있습니다: 엔드포인트 볼륨과 드라이버 효과가 render 스트림과
loopback 탭 사이에 있어서, 같은 출력이 어떤 endpoint에서는 0.40, 다른 endpoint에서는 1.0으로
관측됩니다.

## 7. 한계와 미검증

* **좌우 뒤바뀜**은 레벨만으로는 판정할 수 없습니다. 이 검사는 "한 채널 누락"은 잡지만 "교체"는
  잡지 못하며, 그렇게 주장하지 않습니다.
* **사람이 듣는 아날로그 출력**은 검증 대상이 아닙니다. 이 문서의 통과는 디지털 경로 관측입니다.
* **원격 endpoint의 clock**: 이 머신의 유일한 입력 장치는 WO Mic(ROOT, WiFi로 폰의 마이크를
  전달)이며 48 kHz **모노**입니다. 두 장치의 clock이 독립일 수 있으므로 이 입력을 쓰는 장시간
  경로는 별도 측정이 필요합니다.
  **정정**: `--route-check`의 원격 경고는 Windows가 `Network` form factor로 보고하는 endpoint를
  기준으로 하는데, 이 머신의 WO Mic은 그 값으로 보고되지 않아 **그 note가 실제로 출력되는 것을
  확인하지 못했습니다**(관측된 `--route-check` 출력에는 케이블 부재 note만 있습니다). 즉 이
  항목은 "도구가 경고해서 아는 위험"이 아니라 **도구가 잡지 못하는, 문서로만 남긴 위험**입니다.
  규칙 자체(모든 캡처 endpoint가 Network일 때 note)는 `--self-test`의 합성 endpoint로 검증되어
  있지만, 실기기에서 그 분기를 관찰한 적은 없습니다.
* **Bluetooth·HDMI·독점 모드·DRM**: 이번 이정표의 범위가 아니며 검증하지 않았습니다.
* **CI**: 이 브랜치의 모든 커밋이 푸시되었고, 마지막으로 확인한 팁 `9d08c8f`에서 **Windows CI(Debug·Release·no-UI), Core CI(ubuntu·windows × Debug·Release), macOS Native and Core CI가 모두 success**(16/16 job, 워크플로마다 PR용·푸시용 2회 실행)입니다(`a0e1ccb`, `2d0517c`, `8de1275`, `66468b9`도 같음). 이번에는 **자격 증명으로 잡 로그까지 읽어 각 단계의 자기 보고를 확인**했습니다: `windows-cli` 잡의 **GUI 컨트롤 목록·슬라이더 경로 단계는 VERIFIED**로 통과했고, **새로 고침 선택 유지·선택 저장/복원 두 단계는 러너에 엔드포인트가 없어 스스로 `SKIPPED`**로 보고했습니다(실패가 아니지만 통과도 아닙니다). 러너에 오디오 장치가 없다는 것과 데스크톱 제약은 위 SKIPPED 표의 항목을 대체하지 않습니다. **이 항목은 하드웨어 검증이 아니라, 하드웨어가 필요 없는 계층이 tip에서 여전히 깨지지 않았다는 증거입니다.**
* **`--list-devices`/`--route-check`와 엔드포인트가 없는 머신**: 러너처럼 장치가 하나도 없는 환경에서 두 명령은 열거 실패 또는 "기본 장치를 찾을 수 없음"을 보고합니다. 그 계약도 CI에서 검증되지만, "장치가 있는 머신에서의 경로 판정"과는 다른 경로입니다.
* **3상태 방법을 돌린 ad-hoc 실행의 underrun**: 그 실행은 같은 endpoint에서 톤 재생 + loopback
  캡처 + 세 번째 관측 스트림이 동시에 도는 구성이었고, 바이패스 712 ms·Circuit 6,256 ms의
  underrun을 보고했습니다. 이는 **그 임시 구성의 관측**이며 이정표의 안정성 주장과 무관합니다.
  안정성은 케이블 경로에서 별도로 측정하며, 아직 측정하지 않았습니다(SKIPPED).
* **그 실행의 절대 레벨**: 목적지(Odyssey G5)에 대해 톤을 직접 재생해 기준값을 측정하는 것은
  모니터로 소리를 내는 조작이라 동의 범위 밖이어서 하지 않았습니다. 따라서 그 실행의 레벨을
  소스 진폭 0.40과 직접 비교할 수 없고, 비교하지 않았습니다. 케이블 경로 검사는 기준값을 스스로
  측정하므로 이 문제가 없습니다.
* **32비트 Windows**: 지원하지 않습니다(기존 결정 유지).

## 8. 재현 명령 요약

```bat
scripts\build-windows-cli.bat Release
scripts\build-windows-cli.bat Debug
build\win-cli\Release\lowend_windows.exe --self-test
build\win-cli\Release\lowend_windows.exe --list-devices
build\win-cli\Release\lowend_windows.exe --route-check --input-device "<CABLE Output id>" --device "<ZH3 id>"
python scripts\check-windows-cli.py build\win-cli\Release\lowend_windows.exe
python scripts\check-windows-gui-controls.py build\win-cli\Release\lowend_gui.exe
python scripts\check-windows-gui-sliders.py build\win-cli\Release\lowend_gui.exe
python scripts\check-windows-gui-refresh.py build\win-cli\Release\lowend_gui.exe
python scripts\check-windows-gui-persistence.py build\win-cli\Release\lowend_gui.exe
python scripts\check-windows-cable-route.py --self-check
python scripts\check-windows-cable-route.py build\win-cli\Release\lowend_windows.exe --cable-playback "<CABLE Input id>" --cable-recording "<CABLE Output id>" --output "<ZH3 id>"

rem 30분 연속과 정지/재시작 10회는 명시적 ID를 받는 저장소 스크립트로 실행합니다.
rem (무음이 전달되는 입력 장치를 쓰면 소리가 나지 않습니다.)
python scripts\check-windows-route-stability.py build\win-cli\Release\lowend_windows.exe ^
  --capture "<케이블 녹음 id 또는 입력 id>" --render "<ZH3 id>" --capture-mode input --minutes 30 --cycles 10
```

## 8-1. 저장소 위생

이 이정표가 커밋한 파일에 **실제 장치 id나 전체 개인 경로를 남기지 않는다**는 규칙을 적용해 두
가지를 정리했습니다.

| 대상 | 문제 | 조치 |
|---|---|---|
| `AGENTS.md` | 작성한 머신의 절대 경로가 그대로 들어 있었음 | 규칙(Windows worktree에서 작업)은 유지하고 경로는 제거. 파일 자체가 "저장소에 절대 개인 경로를 적지 않는다"를 명시 |
| `--self-test`의 충돌 검사 픽스처 | 개발 머신에서 복사한 endpoint id 2개 — 그중 하나는 **이 워크스테이션에 실제로 존재하는 오디오 endpoint의 id**였음 | 합성 id로 교체. 검사에 필요한 것은 서로 다른 well-formed id뿐이므로 동작 변화 없음(재빌드 후 오프라인 검사 전부 통과) |

| **저장소에 커밋된 파이썬 바이트코드 (자체 발견·수정)** | `git ls-files` 점검 | 검사 스크립트 12개를 한 번에 고치면서 `git add scripts/`를 실행했고, 그 직전에 돌린 `python -m py_compile scripts/*.py`가 만든 `scripts/__pycache__/*.pyc` **16개가 그 커밋에 함께 들어갔습니다**(`576d105`). 기계마다 달라지는 컴파일 산출물이고, 그중 하나는 **수정 전 안정성 검사기의 바이트코드**였습니다. 인덱스에서 제거하고 파일을 지운 뒤 `.gitignore`에 `__pycache__/`·`*.pyc`를 추가했습니다. 작업 트리 전체를 다시 훑어 추적 중인 `.pyc`·`.obj`·`.exe`·`.pdb`·`.wav`가 없음을 확인했습니다. **교훈**: 스크립트를 고친 뒤에는 `git add scripts/` 같은 디렉터리 단위 스테이징 대신 파일을 지정합니다 |
검증 환경 섹션의 장치 이름(ZH3·Odyssey G5 등)은 사용자가 승인한 대상 장치의 제품명이며,
endpoint id·컨테이너 id·개인 경로는 저장소에 넣지 않았습니다. 검증 로그(`build/` 아래)는
`.gitignore` 대상이라 커밋되지 않습니다.

## 9. 남은 작업

1. **후속 Draft PR: #25** — <https://github.com/Gomtanga/lowend-circuit/pull/25>
   (base `feature/windows-port` `400fa25`, head `feature/windows-virtual-routing`, draft, 이 브랜치의 모든 커밋에서 CI green). 이 문서를 마지막으로 갱신한 commit의 **부모가 `66468b9`**(32번째 커밋, CI 16/16)이고 문서 수정 자체가 33번째 커밋입니다. PR #24가 병합되면 base를 `main`으로 바꿉니다.
   **병합은 하지 않았습니다.**
2. **VB-CABLE 설치 동의 → 재부팅 → 5절의 3~9번 실행**(경로 검증, 30분 안정성, 재시작 10회,
   3상태 OFF/바이패스/Circuit 비교). 이 단계는 외부 드라이버 설치·재부팅·기본 출력 변경·테스트 톤
   재생을 포함하므로 **사용자 동의 없이는 진행하지 않습니다.**
3. 사람의 청취 평가(별도, 이 문서의 주장 범위 밖).
