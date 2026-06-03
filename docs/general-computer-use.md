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
cd xbass-inspired-plugin
./build.sh
```

Open:

```sh
open "build/XBassInspired_artefacts/Release/Standalone/XBass Inspired.app"
```

The standalone version is a GUI program with four main knobs and preset buttons:

- `Gentle`: light bass lift.
- `XBass`: the default stronger lift.
- `Deep`: heavier bass and body.
- `Reset`: clean pass-through starting point.

The standalone app processes audio through the input and output device you select in its audio settings. For system-wide computer audio, route your Mac's output through a virtual audio device such as BlackHole or Loopback, then choose that virtual device as this app's input.

## Windows or Linux standalone app

Install CMake and a C++ build toolchain, then run:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

The standalone executable is generated under the `build` artefacts folder. Exact folder names vary by platform and generator.

## Easiest non-DAW setup

For everyday listening, the least fussy path is:

1. Build the `Standalone` app.
2. Install a virtual audio cable.
3. Set your computer/system output to the virtual cable.
4. Set the standalone app input to that cable.
5. Set the standalone app output to your headphones, DAC, or speakers.

This is how the plugin can be used with browsers, music players, games, and video apps.
