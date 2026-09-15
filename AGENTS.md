# Agent 규칙 (LowEnd Circuit)

이 파일은 이 저장소에서 자동화 에이전트가 지켜야 하는 **프로젝트 고유 규칙**만 담습니다. 일반적인
기여 절차와 코드 관례는 [`CONTRIBUTING.md`](CONTRIBUTING.md), 빌드·검증 명령은
[`docs/development.md`](docs/development.md)와 [`docs/windows.md`](docs/windows.md)가 정본입니다.
이 파일은 그 문서들을 대체하지 않습니다.

## 작업공간

- Windows 작업은 worktree `C:/Users/Gomtang/lowend-winport`(`feature/windows-port` 계열
  브랜치)에서 합니다. 다른 worktree(`lowend-circuit`)는 `main`을 체크아웃한 별도 작업공간이며,
  이름만 보고 같은 작업으로 가정하지 않습니다.
- 옛 프로토타입(`spike/windows-native-prototype`, `WindowsNativePrototype/`,
  `LowEndWinPrototype.exe`)은 **수정·실행·삭제·이식하지 않습니다.** 그 미커밋 변경은 사용자
  자산으로 보존합니다(현재 `git stash`에 보관됨).
- 시작 전에 `git status`가 dirty이거나 기준 브랜치·PR head와 다르면 자동 `stash`/`reset`/
  `switch`를 하지 않고 충돌 내용을 사용자에게 보고합니다.
- `git reset --hard`, `git clean -fd`, 강제 push, 브랜치 삭제, `main` 자동 병합·직접 push는
  금지입니다. 모든 변경은 후속 브랜치 + Draft PR로만 전달합니다.

## 검증

- **미실행 CI를 로컬 재현으로 대신했다고 말하지 않습니다.** 로컬에서 워크플로 명령을 재현한
  경우 그 사실과 미실행 사실을 함께 적습니다.
- 보고는 **VERIFIED / FAILED / SKIPPED**를 분리합니다. `SKIPPED`는 성공의 근거가 아닙니다.
  장치가 없어서 관찰하지 못한 항목은 "관찰하지 못했다"고 적습니다.
- 환경 부재를 SKIPPED로 바꾸는 것은 허용하지만, 실제 실패를 SKIPPED로 바꾸는 것은 금지입니다.
- 새 검사나 가드를 추가하면 **주입(mutation) 시험**으로 그 검사가 실제 결함을 잡는지 확인하고,
  되돌린 뒤 다시 통과하는지까지 확인합니다. 실패 메시지 문자열은 서로 달라야 합니다(스크립트가
  문자열로 식별합니다).
- 검사가 스스로 판별력을 증명할 수 있으면 그렇게 합니다(예:
  `scripts/check-windows-cable-route.py --self-check`). 스스로 실패하지 않는 검사는 통과하는
  경로와 구별되지 않습니다.
- 재현 명령은 실제로 실행한 형태로 기록하고, 산출물은 "Release" 디렉터리 이름만으로 그 commit의
  결과라고 단정하지 않습니다.

## 사용자 존중 (오디오·장치)

- **소리를 내는 조작**(테스트 톤, 출력 장치로의 재생)은 대상 endpoint와 레벨을 먼저 알리고
  동의를 받습니다. 동의 없이 시스템·장치 볼륨을 올리지 않습니다.
- **외부 드라이버 설치/삭제, 재부팅, Windows 기본 출력 변경**은 사용자 결정입니다. 자동으로
  실행하지 않고, 공식 출처·필요한 동작·되돌리는 방법을 한 번에 안내합니다.
- 사용자가 창을 닫거나 Stop한 것을 오류로 단정하지 않습니다. 앱을 자동 재실행하지 않고,
  감시·상주 프로세스·자동 기본 장치 복구를 임의로 추가하지 않습니다.
- 장치 선택을 사용자 대신 추측하지 않습니다. 저장된 endpoint가 사라지면 **첫 번째 장치로 조용히
  대체하지 않고** 명시적으로 재선택을 요구합니다.

## 라우팅 (Windows 가상 케이블 이정표)

- 이 이정표의 범위와 한계는 [`docs/windows-routing-validation.md`](docs/windows-routing-validation.md)에
  고정되어 있습니다. 외부 케이블 설치를 전제로 한 프리뷰이며, 자체 드라이버·APO·기본 장치 자동
  전환을 약속하지 않습니다. Phase 2.5의 "투명한 처리는 EFX APO" 결정을 바꾸지 않습니다.
- 순환 금지 규칙(같은 endpoint 금지, **한 가상 장치의 양쪽 사용 금지**)을 **우회하는 플래그나
  임시 패치를 만들지 않습니다.** 이 규칙은 시작 시점과 장치 재개방 시점 모두에 적용됩니다.
- 오디오 콜백 경로에 할당·잠금·로그·파일 I/O·계수 계산을 추가하지 않습니다. underrun을 숨기기
  위해 미기입 버퍼나 이전 샘플을 재생하지 않습니다.
- `underrun < 1%` 같은 임의 기준을 정상의 근거로 쓰지 않습니다. 캡처율·DSP 처리율·렌더 스트림율·
  엔드포인트 mix rate를 구분하고, 서로 다른 장치의 clock drift를 "같은 샘플레이트"로 해결됐다고
  가정하지 않습니다.
