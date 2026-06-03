# LowEnd Circuit

LowEnd Circuit is an open-source bass enhancement project with two parts:

- a JUCE audio plugin/standalone app for DAWs and plugin hosts
- a native macOS system-audio app that can process whole-computer or selected-application audio

The project models general low-frequency compensation and virtual analog bass circuitry. It is not affiliated with, endorsed by, or based on the proprietary circuit of any hardware manufacturer.

## Legal And Licensing

LowEnd Circuit is an independent open-source project. Product names, trademarks, and audio-circuit designs owned by third parties are not used as branding for this project.

This repository is licensed under `AGPL-3.0-or-later`. JUCE is fetched at build time and is available under its own dual-license terms; review the JUCE licence if you plan to distribute binaries or use the project commercially.

## What it does

- `LowEnd`: low-shelf boost from roughly 72-105 Hz, up to about 8.5 dB.
- `Body`: blends in a controlled low-passed soft-saturated sub component.
- `Mix`: parallel wet/dry blend.
- `Output`: final trim before a gentle tanh safety stage.
- `Spatial Stage`: native macOS app only. Adds a drag-controlled 3D listener position with distance, inter-ear delay, level difference, and crossfeed processing.

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

See `docs/general-computer-use.md` for using the standalone app with ordinary computer audio from browsers, music players, games, and video apps.

For built-in whole-computer audio and per-application audio processing without third-party virtual audio drivers, see `docs/system-wide-and-per-app.md`.

The native system-audio app includes simple presets:

- `IEM`
- `Gentle`
- `LowEnd`
- `Deep`
- `Clear`

It also has two models:

- `Circuit`: virtual analog RC/op-amp style bass circuit model.
- `Clean DSP`: the earlier filter-based bass enhancer.

The native app also includes a `Spatial Stage` panel. Drag the blue `Me` point in the 3D view or type exact meter values for `Me X`, `Me Z`, and `Width`. The setting updates while system audio is running.

## Starting point for tuning

The current DSP is intentionally simple and stable:

1. Apply a variable low-shelf boost.
2. Extract low-frequency content around 135 Hz.
3. Soft-saturate that content and blend it back as `Body`.
4. Reduce internal headroom as the boost increases.
5. Apply output trim and gentle clipping protection.

For a closer match to a specific hardware setting, measure pink-noise or swept-sine captures from the target device and adjust the shelf frequency, Q, gain curve, and circuit-model constants.
