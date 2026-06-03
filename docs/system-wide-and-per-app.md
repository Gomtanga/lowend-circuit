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

The GUI version includes `LowEnd`, `Body`, and `Output` sliders. Changes apply while processing is running.

The GUI version also includes a `Spatial Stage` panel:

- Drag the blue `Me` point in the 3D view to move the listening position in real time.
- Type exact `나 X`, `나 Z`, and `Width` meter values when you want repeatable settings.
- Use `Space` to blend the spatial processor with the original stereo signal.

The spatial processor treats the left and right channels as front speakers, then calculates listener-ear distance differences, inter-ear delays, level differences, and crossfeed. It is meant for headphone/IEM listening and is not a room simulation reverb.

Preset buttons:

- `IEM`: low-noise starting point for sensitive earphones.
- `Gentle`: light bass support for long listening.
- `LowEnd`: balanced default starting point.
- `Deep`: stronger bass, now tuned with less circuit drive than the first version.
- `Clear`: near-bypass reference point.

Slider meanings:

- `LowEnd`: bass boost strength.
- `Body`: added low-end thickness.
- `Output`: final level trim. Lower this if the sound feels too loud or compressed.

Model selector:

- `Circuit`: virtual analog model using RC-style bass nodes and a soft op-amp stage. This is the default.
- `Clean DSP`: the earlier filter-based bass enhancer. Use it when you want a cleaner, more direct low-shelf sound.

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
