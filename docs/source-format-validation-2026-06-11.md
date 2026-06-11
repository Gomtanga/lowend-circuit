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

## Apple Music Detection Improvements (2026-06-11)

### Playback State Detection

AppleScript now queries `player state` alongside `sample rate of current track` and
`persistent ID of current track`. The tracker distinguishes:

- **playing**: format is resolved through cross-validation of Unified Log and AppleScript
- **paused**: cached format is explicitly cleared
- **stopped**: cached format is explicitly cleared
- **not running** (Music.app not launched): cached format is explicitly cleared

This matches the existing TIDAL behavior where paused/stopped/completed playback
returns unknown instead of retaining stale track information.

### Cross-Validation Logic

When Apple Music is playing and both Unified Log and AppleScript report a sample rate:

1. Rates agree → use Unified Log confidence (Detected if source keywords present)
   and include Unified Log bit depth when available
2. Rates disagree → use AppleScript rate with Inferred confidence, no bit depth
   (AppleScript reflects the current track; Unified Log may contain stale entries from
   a previous track)
3. Only AppleScript has rate → Inferred, no bit depth
4. Only Unified Log has rate → use Unified Log confidence and bit depth

AppleScript `sample rate of current track` always reflects the current track,
so it is used as the fallback when Unified Log contains stale entries from a
previous track.

### Accelerated Polling

When the tracker detects a track change (persistent ID differs) or a state
transition to playing, it temporarily reduces the poll interval from 2 seconds
to 0.5 seconds for up to 4 cycles. This reduces the latency of detecting a new
track's sample rate after a track change.

### Regression Tests Added

- Apple Music playing/paused/stopped/not-running state recognition
- AppleScript-only detection returns Inferred with nil bit depth
- Unified Log-only detection returns Detected with bit depth
- Cross-validation: rates agree → log confidence + bit depth
- Cross-validation: rates disagree → AppleScript rate, Inferred
- Rate transition fixtures: 44.1→48, 48→96, 96→192, 192→44.1 kHz
- Paused playback clears format; resumed playback re-detects
