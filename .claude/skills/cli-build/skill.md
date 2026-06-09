---
name: cli-build
description: >
  LowEnd Circuit 프로젝트의 CLI 인터페이스 구현. JUCE 콘솔 앱 빌드, CLI11 서브커맨드,
  DSP-GUI 분리, 오프라인 오디오 처리, 파이프 호환 JSON 출력 등 CLI 관련 모든 작업에 사용.
  "CLI 빌드", "콘솔 앱", "헤드리스", "process 서브커맨드", "CLI11" 등을 언급하면 이 스킬 사용.
---

# CLI Build Skill

LowEnd Circuit JUCE 오디오 DSP 프로젝트에 CLI 인터페이스를 추가하는 스킬.

## 프로젝트 컨텍스트

- **기술 스택**: C++17, JUCE 8.0.13, CMake 3.22+
- **현재 구조**: `PluginProcessor.h/cpp` (DSP + AudioProcessor), `PluginEditor.h/cpp` (GUI)
- **빌드 타겟**: VST3, AU (macOS), Standalone — 모두 `juce_add_plugin` 기반
- **CLI 프레임워크**: CLI11 (header-only, FetchContent)

## 아키텍처 결정사항

### DSP 코어 분리

DSP 처리 로직을 `Source/DSP/` 디렉토리로 분리하여 CMake static library(`lowend_dsp_core`)로 빌드한다.
플러그인 타겟과 CLI 타겟 모두 이 라이브러리에 링크한다.

### CLI 타겟 구조

```
Source/CLI/
├── Main.cpp                  # 진입점, CLI11 앱 설정
├── Commands/
│   ├── ProcessCommand.h/cpp  # process 서브커맨드 (파일→파일)
│   ├── InfoCommand.h/cpp     # info 서브커맨드 (파라미터/프리셋 정보)
│   └── ListPresetsCommand.h  # list-presets 서브커맨드
```

### CMake 타겟 구조

```cmake
# 공유 DSP 코어 (static library)
add_library(lowend_dsp_core STATIC ...)

# 기존 플러그인 (lowend_dsp_core에 링크)
juce_add_plugin(LowEndCircuit ...)

# 새 CLI 타겟
juce_add_console_app(LowEndCircuitCLI ...)
# CLI11 FetchContent
```

### 서브커맨드 설계

| 서브커맨드 | 용도 | 우선순위 |
|---|---|---|
| `process` | 파일→파일 오프라인 오디오 처리 | 1순위 |
| `info` | 프리셋/파라미터 정보 JSON 출력 | 2순위 |
| `list-presets` | 사용 가능한 프리셋 나열 | 2순위 |
| `live` | 실시간 오디오 처리 | 후순위 |

### process 서브커맨드 인터페이스

```bash
lowend-circuit process -i input.wav -o output.wav [--preset NAME] [--lowend 0-100] [--body 0-100] [--mix 0-100] [--output-db -18..6] [--json]
```

## 작업 원칙

1. **기존 빌드 회귀 금지**: CLI 추가 후에도 플러그인 빌드가 동일해야 한다.
2. **점진적 구현**: DSP 분리 → CMake 타겟 → 에디터 의존성 제거 → process 구현 순서.
3. `processBlock()` 루프에서 `setNonRealtime(true)` 설정 후 오프라인 렌더링.
4. `--json` 플래그로 구조화된 출력 지원.
5. stdin/stdout 파이핑은 후순위 (현재는 파일 기반).

## 에러 핸들링

- 파일 I/O 실패: 명확한 에러 메시지 + 종료 코드 1
- 알 수 없는 서브커맨드: CLI11 기본 에러 핸들링
- 빌드 실패: 서브 에이전트에서 에러 로그 보고 후 수정 시도
