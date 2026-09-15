# Windows 포팅 계획

[← 홈](../README.md) · [개발 가이드](development.md) · [Core 아키텍처](cross-platform-core-architecture.md)

> 상태: **계획 수립 (2026-09-14)**. 이 문서는 Windows 포트의 단계, 범위, 검증 기준을 정의합니다.
> Phase 1은 저장소에서 실제로 검증되었고, Phase 2~4는 계획 단계입니다. 각 Phase의 검증 결과는
> 진행하면서 이 문서의 "진행 상태" 표에 기록합니다.

## 1. 목표와 제약

### 목표

Windows에서 LowEnd Circuit을 실제로 사용할 수 있게 만든다. 시스템 오디오(또는 입력 장치)를 캡처해
`Source/Core`의 C++ DSP로 처리하고 출력 장치로 전달한다.

### 제약

| 제약 | 내용 |
|---|---|
| Authoritative DSP | `Source/Core`의 C++ 구현이 Windows의 단일 DSP 구현입니다. 별도 DSP를 새로 쓰지 않습니다. |
| macOS 동작 보존 | Swift 경로(`TonalDSP.swift`, `SpatialDSP.swift`)와 `Source/Core`는 계속 병존합니다. macOS 코드를 삭제하거나 Windows용으로 분기하지 않습니다. |
| DSP 품질 보존 | DSP 커널에 Windows 전용 분기, 근사, 저정밀 대체를 넣지 않습니다. 플랫폼 차이는 컴파일러 플래그 수준에서만 흡수합니다. |
| 단계적 진행 | CLI와 검증이 충분하기 전에는 GUI를 만들지 않습니다. |
| 계층 분리 | DSP와 오디오 엔진은 어떤 UI에도 종속되지 않습니다. GUI는 CLI와 같은 엔진 위에 올라갑니다. |

### 현재 저장소에서 재사용하는 자산

| 자산 | 경로 | Windows에서의 역할 |
|---|---|---|
| Circuit 베이스 DSP | `Source/Core/src/CircuitBass.cpp` | 저역 쉘프 + RC bass/sub + 피드백 + 비대칭 포화 |
| HighExciter DSP | `Source/Core/src/HighExciter.cpp` | 배음 생성, 내부 1x/2x/4x 오버샘플링, DC 블로커 |
| 모델 라우터 | `Source/Core/src/Processor.cpp` | 모델 전환 256프레임 크로스페이드, 힙 할당 없음 |
| 계수 계산 | `Source/Core/src/Core.cpp` (`DSPPrecompute`) | 모든 계수는 오디오 콜백 밖에서 계산 |
| 공간 geometry | `Source/Core/src/SpatialGeometry.cpp` | 순수 함수. 지연/믹스는 엔진이 수행 |
| SPSC 링 버퍼 | `SystemAudioProcessor/Sources/AudioRingBufferC/` | 캡처 스레드 → DSP → 렌더 스레드 전달 |
| C ABI 계약 | `AudioRingBufferC.h`의 `LCDSPSettings` 등 | macOS와 같은 데이터 계약을 그대로 사용 |
| Core 테스트 | `Source/Core/test/` | Windows CI에서 동일하게 실행 |

`LowEndDSPCoreC` 브리지는 Core `.cpp` 5개를 하나의 TU에 아말감으로 include합니다. Windows에서는
`lowend_core` 정적 라이브러리와 동시에 링크하면 중복 정의가 발생하므로, Windows 엔진은 아말감이 아니라
**`lowend_core` 정적 라이브러리를 링크**합니다.

## 2. 단계 구성

### Phase 1 — Core 빌드, 테스트, CI

범위: `Source/Core`를 MSVC/CMake에서 빌드하고, 모든 Core 테스트를 Windows에서 통과시키고,
Windows GitHub Actions CI를 추가한다.

| 항목 | 내용 |
|---|---|
| 빌드 | CMake + MSVC. `lowend_core` 정적 라이브러리와 9개 테스트 실행 파일 |
| 플랫폼 차이 | `AudioRingBufferC.c`는 C11 `<stdatomic.h>`를 사용하고, MSVC는 C 언어에서 이 키워드를 기본으로 노출하지 않아 `/experimental:c11atomics`가 필요합니다. 이 플래그를 테스트 타깃에 추가했습니다. DSP 소스는 수정하지 않았습니다. |
| CI | `.github/workflows/cross-platform-core-ci.yml`을 `ubuntu-latest` + `windows-latest` × `Debug`/`Release` 매트릭스로 확장 |
| 검증 | 두 구성 모두에서 9/9 테스트 통과 |

비목표: 오디오 장치 입출력, CLI, GUI.

### Phase 2 — Windows CLI 애플리케이션

범위: UI 없는 CLI. WASAPI로 장치를 열고, 시스템 오디오(루프백) 또는 입력 장치를 받아
`lowend_core`로 처리한 뒤 출력 장치로 전달한다.

구성 요소:

1. **장치 계층** — `IMMDeviceEnumerator` 기반 열거/선택. 캡처(입력)와 루프백(렌더 엔드포인트),
   출력 장치를 함께 열거하고, 기본 장치와 ID로 선택한다.
2. **엔진 계층** — 캡처 스레드(장치가 구동)와 렌더 스레드(장치가 구동)를 분리하고,
   두 스레드 사이는 `AudioRingBufferC.c`의 SPSC 링으로 연결한다.
   DSP는 렌더 스레드에서 블록 단위로 수행한다.
3. **제어 계층** — DSP 설정 갱신은 `LCDSPSettings` POD를 원자적으로 교체하거나
   `LCControlEventQueue`로 전달한다. 오디오 콜백에서 계수 계산, 할당, 잠금을 하지 않는다.
4. **진단 계층** — 장치 목록, 실제 협상된 mix format/period, 링 버퍼 통계
   (dropped/underrun/total), 재시도 횟수를 CLI로 노출한다.
5. **CLI** — `--list-devices`, `--device`, `--loopback`, `--input-device`, `--model`,
   `--intensity`, `--body`, `--output`, `--exciter-os`, `--spatial` 계열, `--dump-settings`,
   `--self-test`, `--help`. macOS CLI와 같은 옵션 이름과 검증 규칙을 사용한다.

#### 캡처 기반 방식의 한계 (Microsoft 1차 문서 근거)

일반 WASAPI loopback은 **원본 재생을 대체하지 않는다**. Microsoft 문서는 loopback 캡처가
오디오 엔진 출력의 **추가 복사본**이라고 명시한다:

> "When the hardware does not support a loopback pin, WASAPI copies the output stream from the
> audio engine into the loopback application's capture buffer, **in addition to** copying the audio
> data to the hardware's render pin."
> — [Loopback Recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)

따라서 loopback으로 캡처해 다른 엔드포인트로 재생하면:

| 특성 | 결과 |
|---|---|
| 원본 재생 | 계속된다. 원본과 처리본이 **동시에** 들린다 |
| 같은 엔드포인트로 재생 | 자기 출력이 다시 캡처되는 폐루프가 된다. WASAPI에는 이를 끊는 수단이 없다 |
| 볼륨/음소거 | loopback은 기본적으로 **pre-volume** tap이다. 시스템 볼륨을 내려도 캡처 레벨이 변하지 않는다 |
| 보호 콘텐츠 | 신뢰 드라이버가 아닌 한 loopback에서 소실된다 |
| 주 용도 | Microsoft는 loopback을 "primarily to support acoustic echo cancellation (AEC)"로 규정한다 |

이 방식은 **투명한 system-wide DSP가 아니다.** 따라서:

- 엔진은 같은 엔드포인트로의 loopback 재생을 **거부**한다.
- CLI 배너는 loopback 사용 시 원본 중복 재생과 pre-volume 특성을 **명시**한다.
- 투명한 구현은 별도 아키텍처 결정 사항으로 남긴다. 캡처 기반 방식을 투명한 것처럼
  포장하는 workaround는 만들지 않는다.

| 항목 | 내용 |
|---|---|
| 검증 | 실제 장치에서 루프백 → DSP → 출력 실행. 오프라인 경로(장치 없이)는 CI에서 검증한다 |
| 검증 한계 | 장치 열거와 공유 모드 동작은 CI 러너에 오디오 장치가 없어 오프라인으로 검증할 수 없습니다. 실제 장치 검증은 로컬 실행 기록으로 남깁니다 |

### Phase 2.5 — 투명한 system-wide 처리 아키텍처 결정

Phase 2의 캡처 기반 엔진은 CLI/오디오 엔진 검증에 유효하지만, "투명한 system-wide 처리"는
별도 아키텍처가 필요하다. 조사한 대안과 근거:

| 방식 | 원본 대체 | 장치 변경 | 서명/설치 부담 | 지연 | 비고 |
|---|---|---|---|---|---|
| WASAPI loopback + 별도 render | ❌ (추가 복사) | 불필요 | 없음 | 가장 나쁨 | Phase 2 검증용 |
| 가상 오디오 장치 | 조건부 | **필요** | 매우 높음 (커널 드라이버, EV + HLK) | 나쁨 | 커널 드라이버가 오디오 스택을 중단시킬 수 있음 |
| **APO (Endpoint Effect, EFX)** | ✅ | 불필요 | 높음 (드라이버 패키지의 일부로 설치, 서명) | 가장 좋음 | 엔드포인트별 자동 적용, 그래프 내 처리 |
| Process Loopback (per-app) | ❌ | 불필요 | 없음 | 나쁨 | per-app에는 최적, 시스템 전체에는 캡처 방식의 한계를 물려받음 |

Microsoft 문서에 따르면 **EFX APO**는 "모든 mode mixer 이후"에 위치하고 "**raw 스트림에도 항상
적용**"되며 "같은 엔드포인트를 쓰는 모든 스트림"에 적용된다. 즉 원본을 그래프 안에서 대체하므로
중복 재생이 구조적으로 존재하지 않는다:

> "**Endpoint Effect (EFX)** are applied to all streams that use the same endpoint. **An endpoint
> effect is always applied, even to raw streams.** ... Some effects that should be placed in the
> endpoint area are speaker protection and speaker compensation."
> — [Audio Processing Object Architecture](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/audio-processing-object-architecture)

**결정**: 투명한 system-wide 구현의 기술적으로 올바른 구조는 in-graph 처리(EFX APO)다.
다만 APO는 드라이버 패키지의 일부로 설치되어야 하고 서명·유지보수 부담이 크며,
"서드파티 확장 INF가 사용자의 모든 오디오 장치에 매칭될 수 있는지"는 문서로 확정하지 못했다.
따라서 **Phase 2에서 CLI/오디오 엔진을 먼저 검증하고, APO 방식의 구현 비용과 배포 경로를
별도로 결정**한다. 이 결정 전에는 캡처 기반 방식을 투명한 것으로 문서화하지 않는다.

검증되지 않은 채 남는 항목: APO가 스트림 소유 프로세스를 식별할 수 있는 공식 수단,
서드파티 확장 INF의 실제 장치 커버리지, 보호 콘텐츠에서 APO가 정상 로드되기 위한 서명 요건.


### Phase 3 — 실제 Windows 환경 검증

범위: sample rate, latency, underrun, device switching, Bluetooth, shared-mode를 실제 환경에서 검증하고
테스트와 문서를 보강한다.

검증 항목:

- 44.1 / 48 / 96 / 192 kHz에서 협상된 mix format과 DSP 계수 생성이 일치하는지
- 요청한 버퍼 기간(공유 모드)과 실제 콜백 주기, 그에 따른 지연
- 의도적 underrun(링 버퍼 고갈) 시 무음 대신 침묵 채움 + 통계 증가, 그리고 복귀
- 실행 중 기본 장치 변경/장치 제거(Bluetooth 연결 해제) 시 복구 동작
- Bluetooth 출력의 협상 rate와 shared mode에서의 동작
- 독점 모드가 아닌 shared mode 기준 동작

| 항목 | 내용 |
|---|---|
| 검증 | 로컬 실측 기록 + CI에서 가능한 오프라인 회귀 |
| 문서 | Windows 사용/개발 문서 추가, `docs/cross-platform-core-architecture.md`의 "Windows 폐기" 기록 갱신, `docs/getting-started*.md`의 "Windows 바이너리 미제공" 문구 갱신 |

### Phase 4 — Windows GUI

범위: Phase 2/3에서 검증된 CLI와 오디오 엔진 **위에** GUI를 추가한다. DSP와 엔진은 UI에 종속되지 않는다.

- GUI는 엔진의 공개 API만 사용합니다. DSP 설정 전달, 장치 선택, 시작/중지, 상태 조회가 모두
  CLI와 동일한 계층을 통과해야 합니다.
- GUI 전용 DSP 경로, GUI 전용 설정 저장소, GUI 스레드에서의 계수 계산을 만들지 않습니다.

| 항목 | 내용 |
|---|---|
| 검증 | 실제 GUI 실행에서 시작/중지, 모델 전환, 장치 전환, 오류 표시를 확인 |

### Phase 4.5 — 외부 가상 케이블 라우팅 이정표 (프리뷰)

범위: **외부 가상 오디오 케이블(VB-CABLE 등)의 설치를 전제로** 하는 시스템 전체 오디오 라우팅
프리뷰. 사용자가 Windows 기본 출력을 케이블로 돌리면, 재생되는 모든 오디오가
`CABLE Input → CABLE Output → LowEnd 일반 capture → Source/Core → 사용자가 고른 물리 출력`으로
흐릅니다.

이 이정표가 **아닌** 것:

- LowEnd 자체 가상 드라이버/SYSVAD 파생 드라이버가 아님 (외부 드라이버에 의존)
- APO가 아니며 Phase 2.5의 "투명한 in-graph 처리는 EFX APO" 결정을 **대체하지 않음**
- Windows 기본 장치를 자동으로 바꾸거나 복구하지 않음 (사용자가 수동으로 설정·복구)
- 무설정 배포가 아님 (드라이버 설치·재부팅이 필요)
- 모든 앱/DRM/독점 모드 호환성을 보장하지 않음

추가된 것: 장치 신원(컨테이너 + 버스) 기반의 **가상 케이블 양쪽 사용 금지 가드**(시작·재개방
시점), 스트림을 열지 않는 경로 판정 `--route-check`, 지정 endpoint로 테스트 신호를 보내는
`--play-tone`, 캡처 신호를 기록하는 `--monitor --dump-wav`, `--list-devices`의 버스/케이블 정보,
GUI의 케이블 표시·장치 선택 저장/복원·사라진 장치에 대한 명시적 거부·정지 후 복구 안내.

| 항목 | 내용 |
|---|---|
| 검증 | 오프라인(장치 없이) 검사 전부 + 실기기 경로 검사 스크립트 준비. 케이블이 없는 환경에서는 실기기 검사가 SKIPPED로 보고되고 통과로 세지 않음 |
| 기록 | [`docs/windows-routing-validation.md`](windows-routing-validation.md) — VERIFIED/FAILED/SKIPPED 분리, 검증 환경·명령·결과 |
| 한계 | loopback 성질(원본 중복 재생, pre-volume)은 그대로다. LowEnd를 정지하면 기본 출력이 케이블에 남아 소리가 나지 않을 수 있고, 복구는 수동이다 |

## 3. 진행 상태

| Phase | 항목 | 상태 | 근거 |
|---|---|---|---|
| 1 | MSVC/CMake 빌드 | 완료 | MSVC 19.44, Ninja/Visual Studio 양쪽 구성 성공 |
| 1 | Core 테스트 | 완료 | Debug/Release 각각 11/11 통과 (`ctest`) |
| 1 | Windows CI | 완료 | `cross-platform-core-ci.yml`에 `windows-latest` 매트릭스 추가 |
| 1 | 크로스 컴파일러 이식성 | 완료 | Clang / GCC(Linux)에서 Core 11/11 통과, 경고 0 — macOS CI와 같은 컴파일러 계열 |
| 2 | 공간 DSP Core 이관 | 완료 | `Source/Core/src/SpatialProcessor.cpp` + 독립 기준 모델 테스트 |
| 2 | WASAPI 장치 계층 | 완료 | 열거·캡처(loopback/입력)·렌더, shared mode + event callback |
| 2 | 오디오 엔진 | 완료 | 캡처 스레드 → SPSC 링 → 렌더 스레드(DSP), 자기 캡처 방지, rate 변환 |
| 2 | CLI | 완료 | macOS와 동일한 옵션 이름·범위·거부 규칙, 진단 명령 |
| 2 | 오프라인 검사 + CI | 완료 | `--self-test`, `check-windows-cli.py`, `windows-cli-ci.yml` |
| 2 | 실제 장치 실행 | 완료 | 입력→출력 30초 실행(오류 0, dropped 0) + 시스템 오디오 loopback 캡처 검증 |
| 3 | sample rate / underrun / 진단 | 완료 | rate 변환 동작, underrun이 시작 시점 일회성임을 `--verbose`로 확인, `--monitor` 진단 추가 |
| 3 | 시스템 오디오(loopback) 캡처 | 완료 | 톤 재생 시 peak 0.295 / 무재생 시 0.000 (재현 스크립트 포함) |
| 3 | loopback → 별도 출력 라우팅 | 검증 불가 | 활성 출력 엔드포인트가 1개뿐 (WASAPI 전체 상태 열거로 확인) |
| 3 | 장치 오류 복구 | 완료(부분 검증) | 실패 분류 + 재시도 정책 + 재개방 시퀀스를 검증. 실제 장치 제거/재연결 관찰은 관리자 권한 부족으로 미확인 |
| 3 | 지연 보고 | 완료 | `--buffer-ms` 협상 결과와 버퍼 duration 측정(최소 23.4 ms), `GetStreamLatency()` 보고 |
| 3 | 독점 모드 충돌 | 완료 | 점유된 엔드포인트에서 `0x8889000A` → `fatal` 분류, 해제 후 정상 시작 |
| 3 | Bluetooth | 검증 불가 | Bluetooth 오디오 장치 없음 |
| 3 | 투명한 system-wide 아키텍처 결정 | 사용자 결정 필요 | EFX APO는 서명된 드라이버 패키지가 필요. Phase 2.5 참조 |
| 4 | GUI (엔진 위 front end) | 완료 | Win32 창 + 컨트롤, `lowend_engine`만 사용, 실제 조작 검증(시작/통계/정지/종료) |
| 4 | GUI 시각 배치 | 부분 확인 | 컨트롤 열거로 좌표·값 확인. `PrintWindow`가 일부 정적을 그리지 않아 픽셀 확인은 제한적 |
| 4.5 | 케이블 경로 진단 (`--route-check`, `--list-devices` 버스/케이블) | 완료 | 순환·모드 모순·사라진 endpoint·케이블 미설치를 구분해 원인·다음 조치 출력(실제 4가지 경우 확인) |
| 4.5 | 가상 케이블 양쪽 사용 금지 가드 | 완료 | 컨테이너 + 소프트웨어 버스 기반 판정, 시작·재개방 양쪽 검사. `--self-test`와 주입 시험 9건으로 확인 |
| 4.5 | GUI 안내·선택 저장/복원·거부 | 완료 | 케이블 표시, `%LOCALAPPDATA%\LowEndCircuit\device-selection.txt`, 사라진 장치 시 Start 거부(실제 창에서 확인) |
| 4.5 | 실기기 케이블 경로 검증 | **검증 불가(대기)** | 이 워크스테이션에 가상 케이블 없음. 검사 스크립트와 자체 판별력 검사는 준비 완료 |
| 4.5 | 30분 안정성·재시작 10회·3상태 비교 | **검증 불가(대기)** | 케이블 + ZH3 필요 |
| 4.5 | 투명한 system-wide 아키텍처 결정 | 사용자 결정 필요 | Phase 2.5 참조 — 이 이정표는 그 결정을 바꾸지 않음 |

### Phase 2에서 드러난 설계 변경

계획 수립 시점과 달라진 점을 기록합니다.

1. **공간 런타임 DSP를 Core로 이관.** 초기에는 Windows 전용 포팅을 계획했으나, delay/mix가
   플랫폼 독립 알고리즘이므로 `Source/Core`로 옮겨 Windows가 그대로 사용하도록 했습니다.
   중복 구현을 만들지 않는다는 원칙에 따른 변경입니다.
2. **AUTOCONVERTPCM 도입.** 계획에서는 캡처/렌더 rate가 다르면 거부하기로 했습니다. 실제
   장치 조합(48 kHz 입력 + 192 kHz 출력)에서 엔진을 전혀 실행할 수 없다는 것이 확인되어,
   Microsoft가 문서화한 컨버터를 렌더 핸드오프에 사용하도록 변경했습니다. DSP는 여전히
   캡처 장치의 실제 rate에서 실행됩니다. 자세한 내용은
   [WASAPI 계약 4-1](../Windows/WASAPI-CONTRACT.md)을 참고하세요.
3. **자기 캡처 방지 추가.** 같은 엔드포인트로 loopback 재생을 거부합니다.

## 4. 위험과 대응

| 위험 | 대응 |
|---|---|
| DSP 품질 저하 | DSP 커널에 플랫폼 분기를 넣지 않습니다. 빌드 플래그만 다르게 두고, Core 테스트를 Windows에서 동일하게 실행합니다. |
| macOS 회귀 | Swift 타깃, `Package.swift`, macOS 워크플로를 수정하지 않습니다. Core 소스 변경은 Windows에서도 통과해야 합니다. |
| 실시간 안전성 위반 | 오디오 콜백에서 할당/잠금/로그/계수 계산을 금지합니다. 링 버퍼와 설정 교체는 기존 C ABI 계약을 그대로 사용합니다. |
| 32비트 Windows의 무락 보장 | `atomic_uint_fast64_t`가 32비트에서 lock-free가 아닐 수 있습니다. Windows 타깃은 **x64만** 지원하고, 32비트는 지원 대상에서 제외합니다. |
| 장치가 없는 CI | 장치 열거/스트리밍은 CI에서 검증할 수 없습니다. 오프라인 회귀와 로컬 실측을 분리해 문서화합니다. |
| 문서 이중 사본 | 저장소에는 `docs/`가 정본입니다. 대소문자 별칭(`Docs/`)에 별도 파일을 만들지 않습니다. |

## 5. 검증 기록 형식

이 저장소의 기존 관례를 따릅니다. 각 Phase의 기록은 **무엇을 검사했고, 무엇은 검사하지 않았는지**를
함께 적습니다. 빌드 성공이나 오프라인 테스트 통과는 실제 장치 동작, 지연 특성, 청취 품질, Bluetooth
연결 안정성을 의미하지 않습니다.

## 6. 참조

- [`docs/windows.md`](windows.md) — Windows 빌드·사용·검증 범위
- [`docs/windows-routing-validation.md`](windows-routing-validation.md) — 가상 케이블 라우팅 이정표의 검증 기록(환경·명령·VERIFIED/FAILED/SKIPPED)
- [`Windows/WASAPI-CONTRACT.md`](../Windows/WASAPI-CONTRACT.md) — 장치 계층 계약
- [`Source/Core/README.md`](../Source/Core/README.md) — Core 빌드/테스트와 DSP 계약
- [`docs/cross-platform-core-architecture.md`](cross-platform-core-architecture.md) — Core와 macOS 경로의 관계
- [`docs/high-exciter-oversampling.md`](high-exciter-oversampling.md) — 배율 정책과 검증 기준
- [`docs/development.md`](development.md) — 빌드와 검증 명령
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — 기여 절차
