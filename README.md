# XBass Inspired

A small JUCE/CMake audio plugin that approximates the style of an iFi-like bass enhancement circuit without using iFi branding or claiming circuit accuracy.

## What it does

- `XBass`: low-shelf boost from roughly 72-105 Hz, up to about 8.5 dB.
- `Body`: blends in a controlled low-passed soft-saturated sub component.
- `Mix`: parallel wet/dry blend.
- `Output`: final trim before a gentle tanh safety stage.

This is an original approximation, not an emulation endorsed by or affiliated with iFi.

## Build A Normal Desktop App

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

JUCE is fetched automatically from the official GitHub repository at tag `8.0.13`.

The project always builds a `Standalone` desktop app and a `VST3` plugin. On macOS it also builds an `AU` plugin. With `COPY_PLUGIN_AFTER_BUILD` enabled, JUCE will also try to copy built plugins to the standard local plugin folders.

On macOS, the standalone app is expected here after a release build:

```sh
build/XBassInspired_artefacts/Release/Standalone/XBass Inspired.app
```

That standalone target is the GUI program version. It opens as a normal desktop window with large controls, preset buttons, and device routing through JUCE's standalone audio settings.

See `docs/general-computer-use.md` for using the standalone app with ordinary computer audio from browsers, music players, games, and video apps.

For built-in whole-computer audio and per-application audio processing without BlackHole, see `docs/system-wide-and-per-app.md`.

The native system-audio app includes simple presets:

- `IEM`
- `Gentle`
- `XBass`
- `Deep`
- `Clear`

It also has two models:

- `Circuit`: virtual analog RC/op-amp style bass circuit model.
- `Clean DSP`: the earlier filter-based bass enhancer.

## Starting point for tuning

The current DSP is intentionally simple and stable:

1. Apply a variable low-shelf boost.
2. Extract low-frequency content around 135 Hz.
3. Soft-saturate that content and blend it back as `Body`.
4. Reduce internal headroom as the boost increases.
5. Apply output trim and gentle clipping protection.

For a closer match to a specific hardware setting, measure pink-noise or swept-sine captures from the device and adjust the shelf frequency, Q, and gain curve in `Source/PluginProcessor.cpp`.
