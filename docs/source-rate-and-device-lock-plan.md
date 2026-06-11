# Source Rate Tracking and Device Lock Plan

## Terminology

- **Source rate**: the format reported by Apple Music or TIDAL metadata/logs.
- **Tap rate**: the PCM format delivered by the Core Audio Process Tap.
- **Engine rate**: the rate used by the LowEnd DSP graph.
- **DAC rate**: the physical output device nominal sample rate.
- **Device Lock**: LowEnd owns the physical DAC and writes processed PCM
  directly. This is not bit-perfect because DSP intentionally changes samples.

## Phase 1: Read-Only Source Tracking

`SourceFormatTracker` runs outside the real-time audio path and publishes:

- player identity
- sample rate and optional bit depth
- confidence (`Detected`, `Inferred`, or unknown)
- evidence (`Unified Log` or AppleScript)

The tracker never substitutes Tap, Engine, or DAC rates for an unknown source
rate. Apple Music uses recognized Unified Log messages with an AppleScript
metadata fallback. TIDAL uses only conservative recognized log patterns because
it has no public source-format API.

## Phase 2: Opt-In Rate Matching

Automatic rate matching remains off until Phase 1 is validated against real
track changes. The transition state machine will:

1. debounce a stable source rate
2. enumerate rates supported by the selected DAC
3. choose the exact rate or a lower rate in the same 44.1/48 kHz family
4. fade out and stop the engine
5. flush audio/visualizer ring buffers and reset DSP state
6. change the device nominal rate
7. rebuild Tap, Aggregate, Engine, and DSP formats
8. restart and fade in

The previous device rate is restored when processing stops if LowEnd changed it.

## Phase 3: Virtual Output

Shared Process Tap capture cannot coexist reliably with a player that owns the
physical DAC. A separately installed Audio Server Plug-in will expose
`LowEnd Virtual Output`:

```text
Apple Music / TIDAL
        -> LowEnd Virtual Output
        -> fixed-capacity shared audio transport
        -> LowEnd DSP
        -> physical DAC
```

The virtual device and DAC have independent clocks, so the transport requires
drift measurement, bounded asynchronous rate correction, underrun/overrun
telemetry, and deterministic recovery.

## Phase 4: Device Lock

LowEnd will request the physical device's Core Audio hog mode only after the
virtual output is active. Output should use a HAL AudioDevice IOProc rather than
adding another shared AVAudioEngine mixer stage.

Required safeguards:

- refuse to lock the same virtual device used as input
- restore hog mode, default output, and nominal rate after stop or failure
- recover after DAC disconnect/reconnect
- expose a prominent emergency stop
- never perform driver, lock, allocation, UI, or logging work in an audio IOProc

## Validation Gates

- Apple Music and TIDAL track changes do not display stale source formats.
- Unknown source data remains unknown.
- 44.1/48/88.2/96/176.4/192/352.8/384/705.6/768 kHz transitions avoid pitch
  changes and persistent pops.
- Device switching and sleep/wake restore the original system output.
- DSP callbacks and HAL IOProcs remain allocation-free and lock-free.
- Device Lock is labeled sample-rate matched/exclusive output, never bit-perfect.
