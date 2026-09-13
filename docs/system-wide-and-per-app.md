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

Only one LowEnd capture session can run for the same macOS user. Current builds coordinate GUI and CLI instances with a shared, nonblocking capture lock. A second session displays an explanation before creating a tap; Stop releases ownership after cleanup and any device-rate restoration finish. A failed cleanup keeps ownership until an explicit retry succeeds or the process exits.

When upgrading, quit older LowEnd and Debug copies and stop any older CLI session first. Old versions do not participate in the lock. The current GUI/CLI detects older registered app bundles at startup and asks you to close them, but cannot discover every older unbundled CLI or prevent an older app from starting later. Two older active global taps can mute each other's processed output; repeatedly pressing Apply can expose brief gaps of unprocessed sound while the taps restart.

If enabling system-wide mode makes the computer silent:

1. Stop processing in the app.
2. Open System Settings.
3. Go to Privacy & Security.
4. Allow `LowEnd Native Audio` under audio/system-audio recording permissions if macOS shows it there.
5. Reopen the app and press `전체 시스템 적용` again.

The GUI version remaps the lower sliders based on the selected model. `Circuit` uses `LowEnd`, `Body`, and `Output`; `HighExciter` uses `Exciter Drive` and `Wet Mix`; `Clean` disables the tonal DSP sliders while Spatial and Output Conditioning remain independent. Disable those stages too when comparing against the unprocessed tap signal. Changes apply while processing is running.

The format indicator shows the app's internal processing format, not the original file format from Apple Music, Tidal, or another player. For example, a 16-bit 44.1 kHz track can still show `Processing 96.0 kHz / 32-bit Float` if the current Core Audio tap/engine path is running at 96 kHz.

Tidal `Use Exclusive Mode` and similar exclusive-output modes are not compatible with system-wide processing. Exclusive mode lets the player take over the output device directly, so the Core Audio process tap can be bypassed or starved. Turn exclusive mode off when using LowEnd Native Audio.

The native processor also includes `HighExciter` as a separate selectable model. Its 11 kHz high-pass coefficients and drive/wet values are precomputed outside the audio callback, then delivered through the lock-free control queue.

The `Analysis` tab contains a GPU-rendered FFT visualizer. The audio callback only copies final output samples into a lock-free visualizer ring buffer. A dedicated 30 Hz worker drains the finite available input snapshot and retains the newest 16,384-frame window for Hann windowing and real FFT analysis with Accelerate/vDSP. It can drain more than one scratch block per tick, including 768 kHz input rates. The resulting fixed 128-bin snapshot is published through an atomic C bridge and rendered as one instanced MetalKit draw call at 30 fps, so spectrum updates do not invalidate the SwiftUI hierarchy.

The small meter next to the spectrum display shows Peak, RMS, and Crest Factor. Peak and RMS are calculated with Accelerate/vDSP after the visualizer buffer is drained, then converted to dB and release-smoothed for readability. Crest Factor is `Peak dB - RMS dB`; lower values usually mean the signal is more compressed.

The GUI version also includes a `Spatial Stage` panel:

- Drag the listener point in the Spatial stage to move the listening position in real time.
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

- `Clean`: tonal model bypass. Spatial and Output Conditioning must also be off for an unprocessed tap comparison.
- `Circuit`: virtual analog model using RC-style bass nodes, lighter transformer-style saturation, and parallel wet/dry blending. This is the default.
- `HighExciter`: independent 11 kHz high-pass harmonic exciter. `Exciter Drive` controls harmonic generation and `Wet Mix` controls the parallel blend.

For sensitive IEMs, start with `IEM` or `Gentle`. If you hear roughness, lower `Body` first, then lower `LowEnd`, and keep `Output` around `-3 dB` to `-5 dB`.

Spatial starting points:

- `Centered`: `나 X 0.00`, `나 Z 0.00`, `Width 1.65`, `Space 35%`.
- `Closer`: `나 X 0.00`, `나 Z 0.65`, `Width 1.30`, `Space 25%`.
- `Wide`: `나 X 0.00`, `나 Z -0.30`, `Width 2.20`, `Space 45%`.

CLI example:

```sh
scripts/run-system-wide-lowend.sh --spatial on --space 35 --listener-x 0 --listener-z 0 --stage-width 1.65
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
- Stop completes only after callback shutdown, resource removal, and any required original-rate restoration are confirmed. If one fails, the GUI keeps the session, reports the reason, and blocks a new Start or Quit until a Stop retry succeeds. The CLI stays open and accepts another `Ctrl-C` to retry.
- Per-app mode resolves a fresh Core Audio process list when applying the target. Matching includes an exact bundle ID or a child beginning with that ID plus `.`. Each requested root selects its active matches, or all its currently known idle matches when none is active. A different active app does not remove another requested app's idle fallback. Processes not present in that snapshot cannot be selected by the matcher.
- While per-app capture is running, diagnostics read the tap's current process membership about once a second on the manager queue. The PID display follows OS-restored processes without reapplying the target. An empty membership or failed read replaces the previous PID; this observation does not change capture membership or restart the audio graph. A listed process establishes tap membership, not successful PCM input or audible output, which have separate data-flow indicators.
- On macOS 26 or newer, builds made with Swift 6.2 or newer enable Process Tap restoration of previously tapped bundle IDs after restart. This OS facility does not establish automatic discovery of every new helper bundle. On older supported macOS versions, or if a restarted/new helper is not processed, start playback in the target app and press **특정 앱 적용** again. That action first requires Stop to succeed, then resolves the current processes again. The CLI equivalent is a successful `Ctrl-C`, followed by the same capture command. **실행 중인 앱 새로고침** only refreshes the visible app list.
- The minimum supported runtime is macOS 14.4. The offline matcher regression verifies a fresh resolution after PID/object-ID changes; it does not verify Process Tap restart behavior on macOS 14.4 or promise automatic restoration for every player.
- The current native processor is intentionally simple: it captures, applies the LowEnd DSP, and plays to the current default output device.

## Build verification and isolated output

The bundle script builds Release, runs fast offline support and executable checks, verifies the shader resource bundle and ad-hoc signature, then replaces the prior app. `LOWEND_BUILD_DIR`, `LOWEND_SWIFT_SCRATCH_DIR`, and `LOWEND_APP_DIR` accept absolute QA paths; launch helpers also honor `LOWEND_APP_DIR`.

`--self-test` does not capture audio or change an audio device. `--benchmark-output-conditioning` runs a separate CPU benchmark. The manual `RateMatchBench` target defaults to read-only `--dry-run`. Only **`--execute --device ID` changes a physical device rate**; the build script and CI never execute it. Build success does not establish permission handling, hardware recovery, or listening quality.

See [Rate Matching](rate-matching.md) for fresh source evidence, mixed-source behavior, and the distinction between Tap processing and post-conditioning output rates.
