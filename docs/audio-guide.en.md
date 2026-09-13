# Audio guide

[← Home](../README.en.md) · [한국어](audio-guide.md)

## Models and Spatial Stage

| Feature | What it does | Available in |
|---|---|---|
| **Clean** | Bypasses the Circuit/HighExciter tonal model. Spatial and Output Conditioning remain independent; disable both for a dry comparison. | LowEnd Native Audio |
| **Circuit** | Combines `LowEnd`, `Body`, a parallel wet path, asymmetric saturation, and output protection to shape bass weight and texture. | LowEnd Native Audio |
| **HighExciter** | Generates harmonics from content above roughly 11 kHz and adapts nonlinear-stage oversampling to the sample rate. | LowEnd Native Audio |
| **Spatial Stage** | Uses virtual-speaker width, listener position, distance gain, interaural timing, and crossfeed to shape headphone space. | LowEnd Native Audio |
| **Analysis** | Displays a 16,384-point FFT, 128 spectrum bars, Peak, RMS, and Crest Factor. | LowEnd Native Audio |
| **Source and Rate Match** | Conservatively derives source-format information from player metadata or logs and previews a matching DAC rate. | LowEnd Native Audio |

Spatial Stage is a geometry-based stereo processor. It is not room reverb or an individualized HRTF renderer.

### Presets

Presets are starting points. Circuit presets are not loudness-matched, so you may hear both tonal and playback-level differences when comparing them.

#### Circuit

| Preset | LowEnd | Body | Output |
|---|---:|---:|---:|
| IEM | 30% | 8% | -2.0 dB |
| Gentle | 22% | 8% | -1.0 dB |
| LowEnd | 42% | 18% | -1.8 dB |
| Deep | 54% | 22% | -2.8 dB |
| Clear | 0% | 0% | 0.0 dB |

Stronger bass settings use lower output values to preserve headroom and reduce the risk of clipping.

#### HighExciter

| Preset | Exciter Drive | Wet Mix |
|---|---:|---:|
| Soft | 0.12 | 0.04 |
| Air | 0.22 | 0.07 |
| Detail | 0.35 | 0.11 |
| Shimmer | 0.50 | 0.16 |
| Off | 0.00 | 0.00 |

HighExciter presets change only `Exciter Drive` and `Wet Mix`. They do not change Circuit `Output` or Spatial Stage settings.

## Oversampling and headroom

| Control | Where it acts | Purpose |
|---|---|---|
| HighExciter oversampling | Inside its nonlinear stage | Reduces aliasing from harmonic generation, then returns to the processing rate |
| Output Conditioning → PCM Oversampling 2× | After tonal and Spatial processing | Converts the output stream to a supported 2× device rate |
| Output Conditioning → Headroom | The active PCM 2× output path | Attenuates the signal before output conversion |

These oversampling stages have different scopes and can be used together. Live PCM 2× supports **44.1 → 88.2 kHz** and **48 → 96 kHz** when the output device supports the target rate. An external DAC is not required if the built-in output supports it.

Headroom affects audio only while **PCM 2× is actually active**. A stored headroom value does not attenuate an inactive or unsupported path. At 0 dB there is no attenuation; −6 dB is approximately half the signal amplitude. It does not reverse saturation already introduced by the tonal model, and it is separate from Circuit **Output**.

The live path is limited to PCM 2×. Higher factors, dither/noise shaping, and DSD/DoP are not connected to live output. See [development](development.en.md) for the offline experimental scope.

## Audio formats and Rate Match

LowEnd Native Audio keeps several format values separate:

- `Tap`: the format delivered by Core Audio Process Tap
- `Engine`: the output graph format. With Live PCM 2×, tonal/Spatial DSP runs at the Tap rate before upsampling to this output rate.
- `DAC`: the output device's nominal sample rate
- `Source`: playback-source information obtained independently from Apple Music or TIDAL

`Source` is labeled `Detected` or `Inferred` according to the available evidence. A value that cannot be established remains `unknown`; the app never substitutes the Tap or DAC rate and presents it as the source-file format.

For TIDAL, the app watches `player.log` for filesystem changes and rechecks the source format after an approximately 80 ms debounce. It rearms the watcher when the log is replaced or rotated and retains periodic polling as a recovery path. `CoreaudioSink::start` and `CoreaudioSink::close` are also treated as playback-state evidence, covering track changes where TIDAL delays or omits `media.state=active`.

Source monitoring tracks the player PID, log-file identity, and read offset. Old log bytes are not promoted to fresh observations. Source can remain `unknown` until a new playback/sink record arrives after monitoring begins, or when evidence has not refreshed for 15 seconds. Mixed sources and sources outside the capture scope do not trigger automatic rate changes.

`Rate Match Preview` is read-only. It compares a detected source rate with rates reported by the DAC and shows a candidate without changing the device.

`자동 Rate Match (Automatic Rate Match)` is experimental, independent of the detailed format display, and off by default. After stable source observations, it fades out, stops the engine, changes the DAC and Engine rates, rebuilds capture and output, verifies flow, and fades back in. Changing to a different source rate can introduce silence while the device relocks; duration depends on the device and transition result. Live PCM 2× and automatic matching are mutually exclusive rate-changing modes.

To avoid device reconfiguration between tracks, leave Automatic Rate Match off and use a fixed rate supported by the DAC. See [Rate Matching](rate-matching.md) and the [Source Rate Tracking and Device Lock Plan](source-rate-and-device-lock-plan.md) for transition and recovery details.

## Limitations

- DSP intentionally changes the signal, so the output is not bit-perfect in the strict sense.
- Exclusive output such as TIDAL **Use Exclusive Mode** can bypass or starve Core Audio Process Tap. Disable exclusive mode during system-wide or per-application processing.
- TIDAL provides no public source-format API. `Source` may remain `unknown` when the installed player emits no recognized message.
- The Apple Music metadata fallback may request macOS Automation permission.
- The target application's Core Audio output process must be active when per-application capture starts.
- The macOS app is not Developer ID signed or notarized by Apple.
- Spatial Stage is not an individualized HRTF.
