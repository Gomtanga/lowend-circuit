# Rate Matching

LowEnd keeps source detection, device-rate selection, and DSP oversampling as
three separate decisions.

- Source tracking observes Apple Music or TIDAL metadata and logs.
- Rate matching selects an exact DAC rate or a lower rate in the same
  44.1/48 kHz family.
- HighExciter oversampling uses the actual Engine rate after any device change.

The preview is always visible and never changes the device. Automatic matching
is opt-in and defaults to off.

## Automatic transition

1. Require two stable observations over at least one second.
2. Fade the output to silence with the lock-free C gain ramp.
3. Stop the engine and capture path.
4. Clear audio buffers and reset DSP state.
5. Set and confirm the DAC nominal sample rate.
6. Rebuild the Engine format and HighExciter coefficients.
7. Restart capture and fade back to unity gain.

The audio callback only consumes atomic ramp commands and multiplies samples.
It does not allocate, lock, dispatch, log, calculate filter coefficients, or
access UI state.

LowEnd records the original device rate before its first automatic change.
Disabling automatic matching or stopping the app restores that rate. A failed
transition attempts a rollback and pauses automatic changes for the current
session.
