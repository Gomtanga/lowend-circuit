# 설치와 사용 시작

[← 홈](../README.md) · [English](getting-started.en.md)

실제로 실행하는 앱 이름은 **LowEnd Native Audio**이며, 프로젝트 이름은 **LowEnd Circuit**입니다. 배포 앱은 **macOS 14.4 이상, Apple Silicon**을 지원합니다. Intel Mac 및 Windows 바이너리는 제공하지 않습니다.

[macOS용 v0.3.0 다운로드](https://github.com/Gomtanga/lowend-circuit/releases/download/v0.3.0/LowEnd-Native-Audio-macOS-v0.3.0.zip) · [릴리스 노트와 검증 범위](https://github.com/Gomtanga/lowend-circuit/releases/tag/v0.3.0)

앱은 **애드혹 서명 상태이며 Apple 공증을 받지 않았습니다**. 처음 실행이 차단되면 [Apple의 앱 실행 안내](https://support.apple.com/ko-kr/102445)도 참고하세요.

## macOS: 전체 시스템 소리 처리

1. macOS ZIP 파일의 압축을 풉니다.
2. `LowEnd Native Audio.app`을 `응용 프로그램` 폴더로 옮깁니다.
3. 처음 실행이 차단되면 출처를 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**에서 이 앱의 실행을 허용합니다.
4. 앱이 요청하는 시스템 오디오 녹음 권한을 허용합니다.
5. `Circuit`, `HighExciter`, `Clean` 가운데 하나를 선택합니다.
6. 처음에는 Circuit의 `IEM` 또는 `Gentle`, HighExciter의 `Soft` 또는 `Air` 프리셋을 권장합니다.
7. **왼쪽 아래 스피커 버튼**(전체 시스템 적용)을 누릅니다.

출력 장치를 바꾸기 전에는 먼저 **중지**를 누르세요. 처리 중 소리가 끊기면 중지한 뒤 다시 적용하세요.

## macOS: 특정 앱만 처리

1. 대상 앱에서 오디오 재생을 시작합니다.
2. **오디오 적용** 화면에 대상 앱의 기본 번들 ID를 입력합니다.
3. **특정 앱 적용**을 누릅니다.

**오디오 적용 → 실행 중인 앱 새로고침**으로 번들 ID를 확인할 수 있습니다. `com.tidal.desktop`처럼 기본 앱 ID를 입력하면 현재 재생 중인 하위 오디오 프로세스도 찾습니다. 일치하는 Core Audio 프로세스가 없으면 재생을 시작한 상태에서 다시 적용하세요.

## 소리가 나오지 않을 때

1. LowEnd Native Audio가 하나만 실행 중인지 확인합니다. 새 버전을 실행하기 전에 이전 앱을 종료하세요.
2. macOS의 시스템 오디오 녹음 권한과 현재 출력 장치를 확인합니다.
3. TIDAL의 **Use Exclusive Mode** 등 플레이어의 독점 출력을 끕니다.
4. 특정 앱 처리라면 대상 앱에서 재생을 시작한 뒤 다시 적용합니다.
5. **중지**한 뒤 다시 적용합니다. 출력 장치를 바꾸기 전에도 먼저 중지하세요.

외장 DAC는 필수가 아닙니다. PCM 2×는 출력 장치가 요청한 샘플레이트를 지원해야 하므로, 선택한 설정뿐 아니라 **실제 활성 상태**를 확인하세요.

음색을 비교할 때는 적당한 청취 음량에서 시작하세요. **Clean**은 톤 모델만 우회하므로 원본과 비교하려면 Spatial과 Output Conditioning도 꺼야 합니다.

## 하드웨어 참고 사양

아래 사양은 사용 환경을 고르기 위한 참고값입니다. 모든 장치와 설정에서 같은 성능을 보장하는 실측 기준은 아닙니다.

| 대상 | 최소 사양 | 권장 또는 추가 조건 |
|---|---|---|
| LowEnd Native Audio | macOS 14.4 이상, Apple Silicon M1 이상, 메모리 8 GB, Metal 지원 GPU, 약 100 MB의 여유 공간 | 96/192 kHz와 Analysis를 함께 쓸 때 Apple M2 이상 및 메모리 16 GB 권장 |

[오디오 가이드](audio-guide.md) · [캡처 상세 동작](system-wide-and-per-app.md) · [문제 신고](../CONTRIBUTING.md)
