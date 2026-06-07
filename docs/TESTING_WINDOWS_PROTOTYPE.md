# Windows Native Prototype — 실행 테스트 가이드

> **브랜치:** `spike/windows-native-prototype`
> **최종 커밋:** `34cef2c` (Step 4 — end-to-end pipeline)
> **파이프라인:** WASAPI loopback capture → Core::CircuitBass DSP → WASAPI render playback

---

## ⚠️ 첫 실행 전 필독

**실행 전에 시스템 볼륨을 10-20%로 낮추세요.**

이 프로토타입은:
- **시스템 오디오를 캡처해서 DSP 처리한 후 다시 출력**합니다.
- 처리 지연(100ms 버퍼 + ring buffer)으로 인해 **오디오 피드백(하울링)이 발생하지는 않지만**, 예상보다 큰 소리가 나올 수 있습니다.
- 항상 낮은 볼륨에서 시작해서 점차 올리세요.

---

## 빌드 방법

### 요구사항

- Windows 10 또는 Windows 11 64-bit
- Visual Studio 2022 (C++17 지원)
- CMake 3.16+
- 오디오 출력 장치 (스피커/헤드폰)
- 오디오 재생 중인 소스 (YouTube, 음악 앱 등)

### 빌드 명령

```powershell
# 1. 저장소 클론
git clone https://github.com/Gomtanga/lowend-circuit.git
cd lowend-circuit

# 2. 브랜치 전환
git checkout spike/windows-native-prototype

# 3. CMake configure
cmake -S WindowsNativePrototype -B build/win-proto -G "Visual Studio 17 2022" -A x64

# 4. 빌드
cmake --build build/win-proto --config Release
```

### 빌드 확인

성공 시 출력 예시:
```
...
[100%] Built target LowEndWinPrototype
```

실패 시:
```
error Cxxxx: ...
```
→ GitHub Issues에 빌드 로그 전체를 붙여주세요.

---

## 실행 방법

### 기본 실행 (5초)

```powershell
.\build\win-proto\Release\LowEndWinPrototype.exe
```

정상 동작 시 출력 예시:
```
LowEnd Circuit — Windows Native Prototype
=========================================
Version: Step 4 — End-to-End Pipeline
Pipeline: Loopback Capture → Core CircuitBass → Playback

[dsp] Initialising Core::CircuitBass...
[dsp] CircuitBass ready: intensity=55, body=30, output=-1.5 dB

[playback] Initialising WASAPI render...
[playback] Mix format: 48000 Hz, 2 channels, 32 bits
[playback] Initialised: 48000 Hz, 2 ch, buffer=4800 frames
[playback] Started.

[capture] Initialising WASAPI loopback capture...
[capture] Format: 48000 Hz, 2 channels
[capture] Processing callback set.

=== Starting pipeline ===
  Capture → Core CircuitBass → Playback
  Running for 5 seconds...

[capture] 480 frames, flags=0x00000000, cb=active
[capture] 480 frames, flags=0x00000000, cb=active
...

=== Stopping pipeline ===

✅ Prototype complete.
   Pipeline ran for 5 seconds.
   If you heard processed audio, Core CircuitBass is working.
```

### 테스트할 오디오 소스 예시

| 소스 | 설명 |
|---|---|
| YouTube 음악 | 저역이 풍부한 곡 (베이스 드럼, 808 등) |
| 시스템 사운드 | 볼륨 조절 효과음, 알림음 |
| 테스트 톤 | 온라인 주파수 생성기 (100Hz 사인파) |

---

## 기대 결과

### ✅ 성공 증상

1. **소리가 출력 장치로 정상 재생됨**
   - 시스템 사운드가 평소처럼 들림
   - 단, Core CircuitBass DSP가 적용된 상태 (저역 보강, body감 추가)

2. **DSP 효과가 청감상 확인됨**
   - Circuit 모델 (기본값: intensity=55, body=30)에서 저역이 약간 증가
   - Clean 모델(dspModel=0)로 변경 시 flat 응답
   - HighExciter 모델(dspModel=2)로 변경 시 고역 배음 추가

3. **5초 후 정상 종료**
   - `✅ Prototype complete.` 메시지 출력
   - 오디오 출력이 끊김 없이 자연스럽게 중단

### ❌ 예상 실패 케이스

| 실패 | 증상 | 원인 |
|---|---|---|
| **No render device** | `[playback] FAILED` | 오디오 출력 장치 없음 (VM, RDP) |
| **No capture device** | `[capture] FAILED` | WASAPI loopback 미지원 (일부 가상 환경) |
| **Silence only (capture OK)** | capture 로그는 나오는데 아무 소리도 안 들림 | playback ring buffer 문제 |
| **소리가 끊김/지직거림** | 오디오가 click/pop과 함께 재생 | buffer timing, mutex 경합 |
| **원본과 차이가 너무 큼** | DSP 파라미터가 과도함 | intensity/body 값을 낮춰서 재시도 |
| **오디오가 한쪽 채널만 나옴** | format mismatch (mono vs stereo) | capture/playback format 불일치 |

---

## 실패 시 수집할 로그

아래 정보를 모아서 issue 또는 메시지로 보내주세요.

### 1. 전체 콘솔 출력

```powershell
.\build\win-proto\Release\LowEndWinPrototype.exe 2>&1
```

출력 전체를 복사해서 보내주세요.

### 2. Windows 오디오 장치 정보

```powershell
# PowerShell (관리자 권한 불필요)
Get-AudioDevice -Playback
```

### 3. 실패 증상

간단히 어떤 증상인지:
- "소리가 아예 안 나옴"
- "capture init에서 실패"
- "playback init에서 실패"
- "소리는 나는데 지직거림"
- "소리가 너무 큼/작음"
- "처리 전/후 차이가 없음"

---

## 오디오 피드백/하울링 주의사항

이 프로토타입은 **디지털 도메인에서 loopback capture → DSP → render** 구조입니다.
물리적인 마이크-스피커 피드백 루프와는 다릅니다.

| 위험 | 설명 |
|---|---|
| **하울링** | ❌ 발생하지 않음 (디지털 capture, 피드백 루프 없음) |
| **소리 지연** | ⚠️ 약 100-300ms 지연 있음. 실시간 모니터링용 아님 |
| **더블 사운드** | ⚠️ DSP 처리된 소리와 원본이 겹쳐 들릴 수 있음 (OS 오디오 설정에 따라 다름) |
| **갑작스러운 큰 소리** | ⚠️ 첫 실행 전 **볼륨 10-20%** 로 낮추고 시작 |

---

## 고급: DSP 파라미터 변경

(아직 CLI 미구현 상태 — `main.cpp`에서 직접 수정 후 재빌드해야 함)

`main.cpp`에서 다음 부분을 수정하면 DSP 특성을 바꿀 수 있습니다:

```cpp
// intensity: 0-100 (저역 강도)
// body: 0-100 (서브 저역 두께)
// outputDb: -18 ~ +6 (출력 게인)
// dspModel: 1=Circuit, 0=Clean(bypass), 2=HighExciter

auto dspConfig = lowend::DSPPrecompute::makeDSPSettings(
    48000.0f, 55.0f, 30.0f, -1.5f, 1);
```

변경 후:
```powershell
cmake --build build/win-proto --config Release
.\build\win-proto\Release\LowEndWinPrototype.exe
```

---

## 테스트 완료 후 보고 양식

```
## Windows Prototype 테스트 결과

### 환경
- Windows 버전: (예: Windows 11 24H2)
- 오디오 장치: (예: 내장 스피커 / USB DAC / 헤드폰)
- 빌드 커밋: 34cef2c

### 실행 결과
- [ ] Capture init 성공
- [ ] Playback init 성공
- [ ] 오디오 정상 재생
- [ ] DSP 효과 청감 확인
- [ ] 5초 후 정상 종료

### 로그
```
(콘솔 출력 전체를 여기에 붙여넣기)
```

### 비고
- (추가 코멘트)
```
