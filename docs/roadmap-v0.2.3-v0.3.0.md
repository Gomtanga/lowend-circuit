# v0.2.3 to v0.3.0 Roadmap

## v0.2.3 Stabilization

- Keep the macOS Native Swift DSP as the default sound path.
- Ship diagnostic counters for output underruns, output/analysis drops, engine
  restarts, and resolved per-app capture targets.
- Run Swift checks, portable Core tests, Native Debug/Release builds, and JUCE
  legacy/shared-Core builds in CI.
- Validate device and sample-rate transitions on real hardware before release.

## v0.3.0 Beta

- Enable `LOWEND_JUCE_SHARED_CORE` for dedicated A/B builds.
- Compare impulse, sine, and deterministic noise fixtures between the
  established Swift implementation and portable Core.
- Record output delta, CPU use, crest factor, and HighExciter alias energy.
- Preserve existing APVTS parameter IDs and old DAW session loading.

## v0.3.0

- Make portable Core the default only after numeric and listening acceptance.
- Keep Spatial Stage and analysis platform-native until equivalent portable
  implementations and tests exist.

## Windows Native

The WASAPI polling prototype remains isolated on
`spike/windows-native-prototype`. It must pass real Windows PC and USB DAC
testing before integration. Product-level system processing requires a
separate virtual endpoint or APO/driver design to prevent original and
processed audio from playing together. Driver installation, signing, device
switching, sample-rate conversion, and recovery are not part of v0.2.3.
