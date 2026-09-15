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
| 이정표 시작 시점의 HEAD | `400fa2574472907294b834a97a0985e6cb0f5568` |
| 이 문서가 기록하는 검증 대상 commit | `814f29b` (푸시됨, `origin/feature/windows-virtual-routing`) |
| 이 저장소의 빌드 산출물 | `build/win-cli/Release/lowend_windows.exe`, `build/win-cli/Debug/lowend_windows.exe`, `build/win-cli/Release/lowend_gui.exe`, `build/win-routing-no-ui/Release/lowend_windows.exe` |

### 이 워크스테이션의 오디오 엔드포인트 (검증 시점)

| 흐름 | 이름 | 버스 | 포맷 |
|---|---|---|---|
| 출력 (기본) | Fosi Audio ZH3 | USB | 48000 Hz / 2 ch / 32-bit |
| 출력 | Odyssey G5 (NVIDIA High Definition Audio) | HDAUDIO | 48000 Hz / 2 ch / 32-bit |
| 출력 | Realtek Digital Output | HDAUDIO | 192000 Hz / 2 ch / 32-bit |
| 입력 (기본) | WO Mic Device | ROOT | 48000 Hz / **1 ch** |

**가상 케이블 없음.** 이 머신에서 `--list-devices`는 `Virtual cables: none detected`를 보고합니다
(3절의 마지막 항목). 그래서 케이블을 지나는 **핵심 경로는 실행 검증되지 않았고**, 이 문서는
"실기기 검증 대기, 이정표 미완료"로 끝납니다.

## 3. 검증 결과

### VERIFIED (실행하고 관찰함)

| 항목 | 명령 | 관찰 |
|---|---|---|
| Release 빌드 + 오프라인 검사 | `scripts\build-windows-cli.bat Release` | exit 0: `ctest` 1/1, CLI 인자 회귀 33건(그중 25건은 거부 사유 문구까지), UI 비종속 검사(엔진 13개 소스), 케이블 검사기 self-check |
| Debug 빌드 | `scripts\build-windows-cli.bat Debug` | exit 0, 동일 검사 통과 |
| GUI 비활성 빌드 | `cmake -S Windows -B build/win-routing-no-ui -DLOWEND_WINDOWS_BUILD_GUI=OFF -DLOWEND_WINDOWS_BUILD_TESTING=ON` + `cmake --build` + `ctest` | 구성·빌드·ctest 통과(`NO_UI_BUILD_OK`) |
| 오프라인 검사 (신규 포함) | `lowend_windows.exe --self-test` | 24개 검사 전부 통과. 신규 2개: `routing: pass-through feedback rule`, `routing: endpoint selection and capture mode` |
| 장치 열거에 버스/케이블 정보 | `lowend_windows.exe --list-devices` | 각 행에 `bus=`(USB/HDAUDIO/ROOT) 추가, 마지막에 `Virtual cables:` 절. 이 머신은 `none detected` |
| 경로 진단 (기본 선택) | `lowend_windows.exe --route-check` | `REFUSED (same endpoint)`, exit 1 — 기본 출력 loopback과 기본 렌더가 같은 ZH3 |
| 경로 진단 (입력 → ZH3) | `--route-check --input-device <mic> --device <zh3>` | `READY`, exit 0. 케이블 부재 안내(설치 필요·사용자 동의 필요)를 note로 출력 |
| 경로 진단 (캡처 모드 모순) | `--route-check --capture-device <입력 endpoint>` | `REFUSED (capture mode mismatch)`, exit 1 — "그 id는 입력 endpoint이므로 `--input-device`로 기록하라"는 다음 조치 출력 |
| 경로 진단 (사라진 렌더 id) | `--route-check ... --device {deadbeef-…}` | `REFUSED (render endpoint missing)`, exit 1 — 요청한 id를 그대로 지목, "재설치하면 새 id가 된다"는 다음 조치 |
| 캡처 덤프 | `--monitor 2 --input-device <mic> --dump-wav <file>` | 96,480 프레임 기록(2.01 s). Python `wave`로 읽어 2 ch / 48000 Hz / 16-bit / 96,480 프레임 확인. 이 입력 장치는 무음(peak 0.000000)을 보고했고, 덤프도 전부 0 |
| GUI 컨트롤 목록 | `python scripts\check-windows-gui-controls.py build\win-cli\Release\lowend_gui.exe` | 33개 컨트롤(콤보 4·트랙바 7·버튼 3·정적 19), 겹침 0, 클라이언트 영역 내 |
| GUI 슬라이더 경로 | `python scripts\check-windows-gui-sliders.py …` | 실제 마우스 드래그 21회, 모든 표시값이 썸을 따름 |
| GUI 새로 고침 후 선택 유지 | `python scripts\check-windows-gui-refresh.py …` | 캡처 선택 유지 확인(`Input: 마이크(WO Mic Device)`, index 3). 라이브 경로 절반은 아래 SKIPPED |
| GUI 선택 저장·복원·거부 (신규) | `python scripts\check-windows-gui-persistence.py build\win-cli\Release\lowend_gui.exe` | (1) 저장된 endpoint가 있으면 그대로 선택됨 (2) 사라진 저장 id는 콤보를 비우고 Start가 "no longer present"로 거부 (3) 선택 변경이 사용자 설정 파일에 기록됨. 검사는 사용자의 실제 선택 파일을 백업·복원함 |
| 케이블 검사기 자체 판별력 (신규) | `python scripts\check-windows-cable-route.py --self-check` | 자기가 만든 신호로 통과/거부를 구별: 440 Hz·0.40·양 채널 신호는 수용, 무음·한쪽 채널만·디튠(404 Hz)·감쇠 없는 Circuit은 거부 |
| 순환 가드 규칙 (오프라인) | `--self-test`의 `routing:` 검사 2종 | 같은 컨테이너 + ROOT 버스의 재생/녹음 쌍은 충돌, USB 헤드셋의 마이크·스피커는 충돌 아님, 컨테이너를 못 읽으면 충돌 아님(식별 불가는 허용), 케이블 한쪽 + 물리 출력은 허용 |
| **테스트 톤 실기기 검증 (사용자 동의 후)** | `--monitor 5 --capture-device <ZH3>`(백그라운드, `--dump-wav` 동시 기록) + `--play-tone 3 --device <ZH3>` | `--play-tone`: 144,000 프레임(3.00 s) 기록, peak 0.400000, 양 채널. 동시에 관찰한 **ZH3 자신의 loopback**: 342 패킷/164,160 프레임, **input peak 0.399963 (L 0.399963, R 0.399963)**. 덤프를 검사기의 분석 코드로 읽어 **우세 주파수 440.0 Hz**, 2 ch, 48,000 Hz, 레벨·채널·피치 기준 전부 통과. 즉 지정한 endpoint로 보낸 신호가 그 endpoint의 loopback에서 그대로 관측됨 |
| 주입(mutation) 시험 | 아래 참조 | 새 검사가 실제로 결함을 잡는지 확인 |
| **GitHub CI (이 브랜치의 첫 실행)** | push `814f29b` → Actions | **Windows CI**(`34976189957`, Debug·Release·no-UI 3개 잡) success, **Core CI**(`34976189997`, ubuntu·windows × Debug·Release) success, **macOS Native and Core CI**(`34976189959`) success. Windows 잡의 12/12·7/7 단계가 모두 success이며, 여기에는 신규 단계(**GUI 선택 저장/복원**, **케이블 검사기 self-check**)가 포함됩니다 |
| CI에서의 이정표 첫 시도 실패 → 수정 | push `254e8c2`, `d6d126c` → Actions | Windows 3개 잡이 모두 `check-windows-cli.py` 단계에서 실패했습니다(빌드·ctest는 통과). 원인은 검사가 **엔드포인트가 없는 러너**를 가정하지 않은 것 — `--route-check`가 없는 *render* id를 지목한다고 단정했지만, 엔드포인트가 하나도 없는 머신에서는 capture 쪽 기본 장치가 먼저 해석에 실패합니다. 엔드포인트 유무와 무관하게 같은 답을 내는 capture id 기준으로 바꾸고, 러너에 엔드포인트가 없을 때의 계약도 함께 검증하도록 고쳤습니다 |

#### 주입 시험 (검사가 정말 잡는가)

| 주입한 결함 | 결과 | 되돌림 후 |
|---|---|---|
| `isVirtualEnumerator`가 항상 false (= 케이블 쌍을 식별하지 못함) | `--self-test`에서 **9건 실패**(케이블 쌍 충돌, 결합 규칙, 진단 3종, 목록 표시 등) | 재빌드 후 전부 통과 |
| 저장된 endpoint가 사라졌을 때 첫 항목으로 조용히 대체(원래 수정했던 결함의 재주입) | `check-windows-gui-persistence.py`가 **2건 MISMATCH** — "사라진 선택이 다른 endpoint로 대체됨", "Start가 잘못된 이유(HRESULT 0x8889000F)로 실패" | 재빌드 후 통과 |

### FAILED

없음. 이번 실행에서 실패한 검사는 없습니다(위 주입 시험은 결함을 일부러 넣은 대조 실험이며,
되돌린 뒤 전부 통과했습니다).

### SKIPPED (관찰하지 못했으므로 성공의 근거가 아님)

| 항목 | 이유 | 필요한 것 |
|---|---|---|
| **케이블 경로 실행 검증** (`check-windows-cable-route.py`) | 이 머신에 가상 케이블이 없음. 스크립트는 `SKIPPED: the two endpoints given as the cable are not paired as one virtual device…`로 보고하고 통과로 세지 않음 | VB-CABLE 설치(외부 드라이버, **사용자 동의 필요**) |
| 30분 연속 재생 안정성 | 같은 이유 | 케이블 + ZH3 |
| 정지/재시작 10회 | 같은 이유 | 케이블 + ZH3 |
| 엔진 OFF / 바이패스 / Circuit 3상태 비교 | 같은 이유(테스트 톤 자체는 위에서 검증됨) | 케이블 + ZH3 |
| GUI 새로 고침의 라이브 경로 절반 | 이 머신에서 사용 가능한 캡처/렌더 쌍이 없음(기본 loopback 조합은 자기 캡처 가드가 거부) | 케이블 또는 서로 다른 출력 |
| 물리 USB 탈착·Bluetooth 실행 검증 | 관리자 권한/장치 없음 | 별도 환경 |
| 사람의 청취 평가 | 이 문서가 주장하지 않는 영역 | 사람 |

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
   이 검사는 (a) 엔진 정지 상태에서 ZH3 loopback에 신호가 없음 (`peak < 0.02`), (b) 바이패스로
   0.40의 0.5~1.05배가 도달, (c) Circuit이 바이패스의 0.90배 이하, (d) 양 채널 모두 신호,
   (e) 우세 주파수가 440 ±10 Hz — 를 확인합니다. 판정 기준은 실행 전에 이 문서와 스크립트
   상단에 고정되어 있고, 통과시키려고 사후에 완화하지 않습니다.
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
| 엔진 OFF 시 ZH3 loopback | `peak < 0.02` | 우회·중복 경로가 없음 |
| 바이패스(−model clean −intensity 0 −body 0 −output 0 −spatial off) | 0.40 소스의 0.50~1.05배 | 경로가 신호를 그대로 전달 |
| Circuit(기본) | 바이패스의 0.90배 이하, 그리고 ≥ 0.02 | DSP가 실제로 경로에 있음 |
| 채널 | 좌·우 모두 ≥ 0.02 | 스테레오가 그대로 도달 |
| 피치 | 우세 주파수 440 ± 10 Hz | 잘못된 rate로 재생되지 않음 |

기준선(바이패스/엔진 OFF)은 **두 실행이 같은 소스·같은 endpoint·같은 세션 볼륨**에서 측정합니다.
레벨 비교는 세션 볼륨에 의존하지 않습니다.

## 7. 한계와 미검증

* **좌우 뒤바뀜**은 레벨만으로는 판정할 수 없습니다. 이 검사는 "한 채널 누락"은 잡지만 "교체"는
  잡지 못하며, 그렇게 주장하지 않습니다.
* **사람이 듣는 아날로그 출력**은 검증 대상이 아닙니다. 이 문서의 통과는 디지털 경로 관측입니다.
* **원격 endpoint의 clock**: 이 머신의 유일한 입력 장치는 WO Mic(ROOT, 원격)이며 48 kHz 모노입니다.
  원격 장치는 독립 clock을 가지므로, 원격 입력 기반 경로의 장시간 안정성은 별도 측정이 필요합니다
  (`--route-check`가 이 사실을 note로 알려 줍니다).
* **Bluetooth·HDMI·독점 모드·DRM**: 이번 이정표의 범위가 아니며 검증하지 않았습니다.
* **CI**: 이 브랜치는 푸시되었고 세 워크플로가 `814f29b`에서 모두 success입니다(3절). 다만 **CI 잡 요약의 VERIFIED/SKIPPED 구분은 저장소 자격 증명 없이 읽을 수 없습니다** — 확인할 수 있는 것은 단계가 실패하지 않았다는 사실이며, GUI 단계가 러너에서 "SKIPPED"로 자기 보고했을 가능성은 배제하지 않습니다. 러너에 오디오 장치가 없다는 것과 데스크톱 제약은 위 SKIPPED 표의 항목을 대체하지 않습니다.
* **`--list-devices`/`--route-check`와 엔드포인트가 없는 머신**: 러너처럼 장치가 하나도 없는 환경에서 두 명령은 열거 실패 또는 "기본 장치를 찾을 수 없음"을 보고합니다. 그 계약도 CI에서 검증되지만, "장치가 있는 머신에서의 경로 판정"과는 다른 경로입니다.
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
```

## 9. 남은 작업

1. **Draft PR 생성(사용자 조작 필요)**: 이 브랜치는 푸시되었지만 PR은 만들지 않았습니다 —
   저장소 자격 증명이 필요하고 이 환경에는 인증된 GitHub 클라이언트가 없습니다.
   base `feature/windows-port`, head `feature/windows-virtual-routing`, Draft로 열고,
   PR 본문/제목 초안은 `%TEMP%\lowend-routing-pr-body.md`에 준비해 두었습니다.
   PR #24가 병합되면 base를 `main`으로 바꿉니다.
2. **VB-CABLE 설치 동의 → 재부팅 → 5절의 3~9번 실행**(경로 검증, 30분 안정성, 재시작 10회,
   3상태 OFF/바이패스/Circuit 비교). 이 단계는 외부 드라이버 설치·재부팅·기본 출력 변경·테스트 톤
   재생을 포함하므로 **사용자 동의 없이는 진행하지 않습니다.**
3. 사람의 청취 평가(별도, 이 문서의 주장 범위 밖).
