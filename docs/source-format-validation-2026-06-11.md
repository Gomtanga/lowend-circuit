# Source Format Validation - 2026-06-11

## Test Environment

- macOS 26
- TIDAL desktop 2.42.1
- TIDAL Player 4.0.2.295
- Apple Music
- Fosi Audio ZH3 USB DAC

Only sanitized format lines are recorded here. Streaming URLs, tokens, and
encryption fields were not copied into the repository.

## TIDAL

Actual track changes produced these player log transitions:

```text
CoreaudioSink::open, rate: 96000, type: int24
media.state = active

CoreaudioSink::open, rate: 44100, type: int16
media.state = active

CoreaudioSink::open, rate: 96000, type: int24
media.state = active

CoreaudioSink::open, rate: 48000, type: int24
media.state = active

CoreaudioSink::open, rate: 44100, type: int24
media.state = active
```

The same log also recorded device selection changes between shared and
exclusive mode. The source tracker reads only the final 256 KiB of
`~/Library/Logs/TIDAL/player.log`, extracts the sink format, and returns it only
while the most recent media state is active. Paused, stopped, or completed
playback returns unknown instead of retaining stale track information.

Expected UI results:

```text
Source TIDAL: 96.0 kHz / 24-bit (Detected)
Source TIDAL: 44.1 kHz / 16-bit (Detected)
Source TIDAL: 96.0 kHz / 24-bit (Detected)
Source TIDAL: 48.0 kHz / 24-bit (Detected)
Source TIDAL: 44.1 kHz / 24-bit (Detected)
```

The release app was also observed switching the UI from a detected format to
`Source Apple Music + TIDAL: unknown` immediately after a completed or paused
state, then back to the next track's detected format after playback became
active.

## Apple Music

Two local library tracks were played and switched through AppleScript. Both
reported:

```text
sample rate of current track = 44100
```

No recognized Apple Music/Core Audio source-format Unified Log message was
emitted during this test. The correct result is therefore:

```text
Source Apple Music: 44.1 kHz (Inferred)
```

AppleScript does not reliably provide source bit depth, so the UI must not
invent or copy the DAC's bit depth.

## Accuracy Rules Confirmed

- TIDAL player log format outranks generic Core Audio device messages.
- TIDAL paused/stopped/completed state clears the detected format.
- Apple Music metadata is labeled `Inferred`, not `Detected`.
- Tap, Engine, and DAC rates are never substituted for an unknown source rate.
