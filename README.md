# LowEnd Circuit

LowEnd Circuit is an open-source bass enhancement project with two parts:

- a JUCE audio plugin/standalone app for DAWs and plugin hosts
- a native macOS system-audio app that can process whole-computer or selected-application audio

The project models general low-frequency compensation and virtual analog bass circuitry. It is not affiliated with, endorsed by, or based on the proprietary circuit of any hardware manufacturer.

## 한국어 요약

LowEnd Circuit는 저역 보강과 간단한 공간음향 처리를 제공하는 오픈소스 오디오 프로젝트입니다.

바로 사용하려면 [Releases 페이지](https://github.com/Gomtanga/lowend-circuit/releases/tag/v0.1.0)에서 macOS는 `LowEnd-Native-Audio-macOS-v0.1.0.zip`, Windows는 `LowEnd-Circuit-Standalone-Windows-v0.1.0.zip` 또는 `LowEnd-Circuit-VST3-Windows-v0.1.0.zip`을 내려받으세요.

- DAW/플러그인 호스트용 `VST3`, macOS `AU`, 일반 데스크톱용 `Standalone` 앱을 빌드할 수 있습니다.
- macOS에서는 `LowEnd Native Audio` 앱으로 컴퓨터 전체 소리 또는 특정 앱 소리에 처리를 적용할 수 있습니다.
- Windows에서는 `Standalone.exe`와 `VST3` 플러그인을 제공합니다. Windows 전체 시스템 오디오 적용 앱은 아직 별도 개발이 필요합니다.
- `Circuit` 모델에서 `LowEnd`는 저역 보강 강도, `Body`는 서브 저역의 두께, `Output`은 최종 출력 보정입니다.
- `HighExciter` 모델은 11 kHz 이상 성분만 분리해 `Exciter Drive`와 `Wet Mix`로 고역 배음을 병렬 보강합니다.
- `Spatial Stage`에서는 파란 청취자 포인트를 드래그하거나 `나 X`, `나 Z`, `Width` 값을 직접 입력해 공간감을 조정합니다.
- macOS native 앱에는 최종 출력의 실시간 FFT 스펙트럼 표시가 포함됩니다.
- Peak/RMS/Crest Factor 미터로 출력 레벨과 압축감을 실시간으로 확인할 수 있습니다.
- `원위치` 버튼은 청취자 위치를 중앙 기준점으로 되돌립니다. `Width`와 `Space` 값은 유지됩니다.
- `Width`는 좌우 가상 스피커 사이 거리이고, `Space`는 원본 스테레오와 공간 처리 신호를 섞는 양입니다.
- 프리셋은 `LowEnd`, `Body`, `Output`만 바꾸며 사용자가 맞춰둔 공간음향 설정은 유지합니다.
- 상단 포맷 표시는 앱 내부 처리 포맷입니다. 음원의 원본 bit depth나 파일 샘플레이트 표시는 아닙니다.
- Tidal `Use Exclusive Mode` 같은 독점 출력 모드는 시스템 오디오 처리와 함께 사용할 수 없습니다.

처음 사용할 때는 `IEM` 또는 `Gentle` 프리셋에서 시작하고, 공간음향은 `Space 25-45%`, `Width 1.4-1.8m` 근처를 권장합니다. 위상이 거칠거나 소리가 부자연스러우면 `Space`를 먼저 낮추세요.

## Legal And Licensing

LowEnd Circuit is an independent open-source project. Product names, trademarks, and audio-circuit designs owned by third parties are not used as branding for this project.

This repository is licensed under `AGPL-3.0-or-later`. JUCE is fetched at build time and is available under its own dual-license terms; review the JUCE licence if you plan to distribute binaries or use the project commercially.

## What it does

- `LowEnd`: low-shelf boost from roughly 72-105 Hz in the Circuit model.
- `Body`: blends in a controlled low-passed soft-saturated sub component.
- `Mix`: parallel wet/dry blend.
- `Output`: final trim before a gentle tanh safety stage.
- `Spatial Stage`: native macOS app only. Adds a drag-controlled 3D listener position with distance, inter-ear delay, level difference, and crossfeed processing.
- `HighExciter`: native macOS app only. A separate selectable model that adds a high-frequency harmonic branch above about 11 kHz while preserving the dry signal.
- `Spectrum`: native macOS app only. Copies final output samples to a lock-free visualizer buffer, runs Accelerate/vDSP FFT analysis outside the audio callback, and renders 128 instanced bars with MetalKit at 30 fps.
- `Dynamics Meter`: native macOS app only. Uses Accelerate/vDSP peak and RMS analysis outside the audio callback, then shows crest factor in dB.

This is an original approximation, not an emulation endorsed by or affiliated with any hardware manufacturer.

## Build A Normal Desktop App

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

JUCE is fetched automatically from the official GitHub repository at tag `8.0.13`.

The project always builds a `Standalone` desktop app and a `VST3` plugin. On macOS it also builds an `AU` plugin. With `COPY_PLUGIN_AFTER_BUILD` enabled, JUCE will also try to copy built plugins to the standard local plugin folders.

On macOS, the standalone app is expected here after a release build:

```sh
build/LowEndCircuit_artefacts/Release/Standalone/LowEnd Circuit.app
```

That standalone target is the GUI program version. It opens as a normal desktop window with large controls, preset buttons, and device routing through JUCE's standalone audio settings.

On Windows, GitHub Releases provide:

- `LowEnd-Circuit-Standalone-Windows-v0.1.0.zip`: normal desktop executable.
- `LowEnd-Circuit-VST3-Windows-v0.1.0.zip`: VST3 plugin for DAWs and plugin hosts.

Windows builds do not include the macOS-only native system-audio processor.

See `docs/general-computer-use.md` for using the standalone app with ordinary computer audio from browsers, music players, games, and video apps.

For built-in whole-computer audio and per-application audio processing without third-party virtual audio drivers, see `docs/system-wide-and-per-app.md`.

The native system-audio app includes simple presets:

- `IEM`
- `Gentle`
- `LowEnd`
- `Deep`
- `Clear`

It also has three native system-audio models:

- `Clean`: dry bypass for comparing against the unprocessed tap signal.
- `Circuit`: virtual analog RC/transformer-style bass circuit model with lighter saturation and wet/dry blending.
- `HighExciter`: independent 11 kHz high-pass harmonic exciter with `Exciter Drive` and `Wet Mix` controls.

The native app also includes a `Spatial Stage` panel. Drag the blue listener point in the 3D view or type exact meter values for `나 X`, `나 Z`, and `Width`. The `원위치` button returns the listener point to the center while keeping `Width` and `Space`. The setting updates while system audio is running.

## Starting point for tuning

The current DSP is intentionally simple and stable:

1. Apply a variable low-shelf boost.
2. Extract low-frequency content around 135 Hz.
3. Soft-saturate that content and blend it back as `Body`.
4. Reduce internal headroom as the boost increases.
5. Apply output trim and gentle clipping protection.

For a closer match to a specific hardware setting, measure pink-noise or swept-sine captures from the target device and adjust the shelf frequency, Q, gain curve, and circuit-model constants.
