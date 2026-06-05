# System-Wide And Per-App Use

## Whole-computer audio

The project includes a native macOS system-audio processor. It uses Apple's Core Audio Process Tap API, so it does not need a third-party virtual audio cable.

Signal path:

```text
macOS app/system output -> Core Audio Process Tap -> LowEnd DSP -> default speakers/headphones/DAC
```

Build the native processor:

```sh
scripts/build-native-system-audio-app.sh
```

Run it on all system audio:

```sh
scripts/run-system-wide-lowend.sh
```

The first run may ask for macOS permission to record system audio. Allow it in System Settings if prompted.

If enabling system-wide mode makes the computer silent:

1. Stop processing in the app.
2. Open System Settings.
3. Go to Privacy & Security.
4. Allow `LowEnd Native Audio` under audio/system-audio recording permissions if macOS shows it there.
5. Reopen the app and press `전체 시스템 적용` again.

The GUI version remaps the lower sliders based on the selected model. `Circuit` uses `LowEnd`, `Body`, and `Output`; `HighExciter` uses `Exciter Drive` and `Wet Mix`; `Clean` disables the DSP sliders and outputs the dry signal. Changes apply while processing is running.

The format indicator shows the app's internal processing format, not the original file format from Apple Music, Tidal, or another player. For example, a 16-bit 44.1 kHz track can still show `Processing 96.0 kHz / 32-bit Float` if the current Core Audio tap/engine path is running at 96 kHz.

Tidal `Use Exclusive Mode` and similar exclusive-output modes are not compatible with system-wide processing. Exclusive mode lets the player take over the output device directly, so the Core Audio process tap can be bypassed or starved. Turn exclusive mode off when using LowEnd Native Audio.

The native processor also includes `HighExciter` as a separate selectable model. Its 11 kHz high-pass coefficients and drive/wet values are precomputed outside the audio callback, then delivered through the lock-free control queue.

The small spectrum display next to the app-list refresh button is a UI-side FFT visualizer. The audio callback only copies final output samples into a lock-free visualizer ring buffer. A 60 Hz UI timer drains that buffer and runs Hann windowing plus real FFT analysis with Accelerate/vDSP.

The small meter next to the spectrum display shows Peak, RMS, and Crest Factor. Peak and RMS are calculated with Accelerate/vDSP after the visualizer buffer is drained, then converted to dB and release-smoothed for readability. Crest Factor is `Peak dB - RMS dB`; lower values usually mean the signal is more compressed.

The GUI version also includes a `Spatial Stage` panel:

- Drag the blue listener point in the 3D view to move the listening position in real time.
- Type exact `나 X`, `나 Z`, and `Width` meter values when you want repeatable settings.
- Press `원위치` to reset only the listener position to `나 X 0.00`, `나 Z 0.00`.
- `Width` is the virtual distance between the left and right front speakers. It moves the speaker nodes visually and changes the DSP distance/delay calculation.
- `Space` blends the spatial processor with the original stereo signal. Higher values make distance, inter-ear delay, level difference, and crossfeed more obvious.

한국어 설명:

- `나 X`: 청취자의 좌우 위치입니다. 음수는 왼쪽, 양수는 오른쪽입니다.
- `나 Z`: 청취자의 앞뒤 위치입니다. 양수는 스피커 쪽, 음수는 뒤쪽입니다.
- `Width`: 좌우 가상 스피커 사이 거리입니다. 화면의 노란 스피커 간격과 실제 DSP 거리/딜레이 계산이 같이 바뀝니다.
- `Space`: 원본 스테레오와 공간 처리 신호를 섞는 양입니다. 높일수록 거리감, 귀 사이 딜레이, 좌우 레벨 차이, 크로스피드가 더 강해집니다.
- `원위치`: `Width`와 `Space`는 유지하고 청취자 위치만 중앙으로 되돌립니다.

The spatial processor treats the left and right channels as front speakers, then calculates listener-ear distance differences, inter-ear delays, level differences, and crossfeed. It is meant for headphone/IEM listening and is not a room simulation reverb.

Preset buttons:

- `IEM`: low-noise starting point for sensitive earphones.
- `Gentle`: light bass support for long listening.
- `LowEnd`: balanced default starting point.
- `Deep`: stronger bass, tuned with reduced circuit drive.
- `Clear`: near-bypass reference point.

Presets only change `LowEnd`, `Body`, and `Output`. They keep the spatial on/off state, listener position, `Width`, and `Space` exactly as you set them.

Slider meanings:

- `LowEnd`: bass boost strength.
- `Body`: added low-end thickness.
- `Output`: final level trim. Lower this if the sound feels too loud or compressed.

Model selector:

- `Clean`: dry bypass. Use it to compare against the unprocessed tap signal.
- `Circuit`: virtual analog model using RC-style bass nodes, lighter transformer-style saturation, and parallel wet/dry blending. This is the default.
- `HighExciter`: independent 11 kHz high-pass harmonic exciter. `Exciter Drive` controls harmonic generation and `Wet Mix` controls the parallel blend.

For sensitive IEMs, start with `IEM` or `Gentle`. If you hear roughness, lower `Body` first, then lower `LowEnd`, and keep `Output` around `-3 dB` to `-5 dB`.

Spatial starting points:

- `Centered`: `나 X 0.00`, `나 Z 0.00`, `Width 1.65`, `Space 35%`.
- `Closer`: `나 X 0.00`, `나 Z 0.65`, `Width 1.30`, `Space 25%`.
- `Wide`: `나 X 0.00`, `나 Z -0.30`, `Width 2.20`, `Space 45%`.

CLI example:

```sh
scripts/run-system-wide-lowend.sh --space 35 --listener-x 0 --listener-z 0 --stage-width 1.65
```

## Only one application

List running apps and bundle IDs:

```sh
scripts/list-audio-apps.sh
```

Run LowEnd only on one app:

```sh
scripts/run-app-lowend.sh com.spotify.client
```

You can also use the binary directly:

```sh
build/LowEndCircuit_artefacts/Release/NativeSystemAudio/LowEnd\ Native\ Audio.app/Contents/MacOS/LowEnd\ Native\ Audio --bundle-id com.spotify.client
```

## Notes

- The native processor runs until you press `Ctrl-C`.
- Per-app mode uses bundle IDs. Some apps produce sound from helper processes with different bundle IDs, so you may need to list apps while audio is playing and choose the audible helper.
- The current native processor is intentionally simple: it captures, applies the LowEnd DSP, and plays to the current default output device.
