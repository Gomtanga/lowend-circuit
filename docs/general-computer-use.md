# Using It On A Regular Computer

This project builds three formats:

- `Standalone`: a normal desktop app. Use this when you do not want to open a DAW.
- `VST3`: for DAWs and plugin hosts that support VST3.
- `AU`: for macOS apps that support Audio Units.

## macOS standalone app

Install CMake and Xcode command line tools:

```sh
xcode-select --install
brew install cmake
```

Build:

```sh
cd lowend-circuit
./build.sh
```

Open:

```sh
open "build/LowEndCircuit_artefacts/Release/Standalone/LowEnd Circuit.app"
```

The standalone version is a GUI program with four main knobs and preset buttons:

- `Gentle`: light bass lift.
- `LowEnd`: the default stronger lift.
- `Deep`: heavier bass and body.
- `Reset`: clean pass-through starting point.

The standalone app processes audio through the input and output device you select in its audio settings. On macOS, the native system-audio app is the easier option for whole-computer listening because it uses Core Audio process taps and does not require a third-party virtual audio driver.

## Windows or Linux standalone app

Install CMake and a C++ build toolchain, then run:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

The standalone executable is generated under the `build` artefacts folder. Exact folder names vary by platform and generator.

## Easiest non-DAW setup

For everyday listening on macOS, the least fussy path is:

1. Build the project.
2. Open `LowEnd Native Audio.app`.
3. Choose a preset and model.
4. Press `전체 시스템 적용`.

This is how the plugin can be used with browsers, music players, games, and video apps.

The native app also has a `Spatial Stage` panel. Drag the blue `Me` point to move the listener in real time, or enter exact values:

- `나 X`: listener left/right position in meters.
- `나 Z`: listener front/back position in meters.
- `Width`: virtual speaker spacing in meters.
- `Space`: blend amount for the spatial processing.

For IEMs, start around `Width 1.4-1.8m` and `Space 25-45%`. If the image feels phasey or noisy, reduce `Space` first.
