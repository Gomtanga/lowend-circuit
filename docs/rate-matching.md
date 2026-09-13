# Rate Matching

Source evidence, capture/processing rate, and the output device rate are distinct. `Rate Match Preview` is read-only. Automatic matching is opt-in, defaults to off, and is independent of the detailed-format display toggle.

## Source evidence and capture scope

- Apple Music combines playback state/track metadata with source-oriented Unified Log evidence.
- TIDAL monitoring tracks PID, file identity, and an incremental byte offset. A new session, rotated file, or truncated file starts at EOF; historical bytes are not assigned the current poll time.
- Only new sink/playback records refresh the evidence timestamp. An unchanged file or unrelated heartbeat does not. Evidence older than 15 seconds becomes unavailable for automatic matching.
- Attaching while a track is already playing can therefore show `unknown` until a new sink/playback lifecycle record establishes that session's format. This is a deliberate conservative fallback, not proof that capture stopped.
- A process tap only uses source evidence matching its selected bundle roots. A mixed global source has no single rate owner, so multiple known players do not trigger an arbitrary device choice.

The policy chooses an exact supported rate, or a lower rate in the same 44.1/48 kHz family. A candidate requires two observations separated by at least one second. The shared source coordinator applies the real cooldown decision and acknowledges the proposal only when the transition returns success. Cooldown keeps an unaccepted proposal pending. Missing source evidence resets stability while preserving an outstanding device cooldown. Explicit session re-enable resets both. Injected-clock and transition-outcome checks exercise this same coordinator.

## Automatic transition

The route transaction fades out, stops capture/output, applies a coherent rate and conditioning snapshot, rebuilds, verifies capture/output progress, and fades in. Rollback uses the same teardown path and reports recovered, stopped, or failed state. An original-rate restoration failure retains its recovery information for a later attempt.

Automatic matching and Live PCM 2× are mutually exclusive device-rate modes. With Live PCM 2×, tonal and Spatial DSP run at the captured Tap rate; the conditioning layer produces twice as many frames for an output graph/DAC at twice that rate. The analyzer observes those post-conditioning samples at the output rate.

Device relocking can interrupt playback. The duration depends on the device, nominal rate confirmation, and recovery result; there is no fixed gapless guarantee. A failed transition pauses automatic changes for the session. Turning matching off or stopping processing attempts to restore the saved original rate.

An independent Tap format event uses a shared handler that rereads the current registration's rate. A changed rate requests a normal graph rebuild or Live PCM 2× deactivation; a stopped session or an automatic transition in progress cannot install another graph. Invalid reads report failure, and retired listener registrations cannot publish a late rate. The resulting graph still has to pass its actual capture/output ratio checks before starting callbacks. Offline tests inject the handler's actions and exercise the same route guard; they do not simulate Core Audio notifications or prove hardware negotiation.

The callback consumes POD settings and gain commands. Device queries, rate changes, graph lifetime work, UI publication, and diagnostics run outside that callback. Diagnostics use the last published runtime snapshot so a device wait does not block Spatial interaction.

## Offline checks and manual hardware measurement

```sh
swift run --package-path SystemAudioProcessor -c release LowEndSupportChecks
swift run --package-path SystemAudioProcessor -c release SystemAudioProcessor --self-test
```

These checks exercise policy and injected transition failures without opening a Process Tap or changing a DAC rate. They do not replace device/OS/permission/listening QA.

`SystemAudioProcessor/Tests/RateMatchBench` is a manual hardware tool. Its default `--dry-run` reads the selected device (or the current default device when no ID is supplied), lists supported standard rates, and shows the proposed test without changing a hardware value.

```sh
swift run --package-path SystemAudioProcessor -c release RateMatchBench --dry-run
```

Physical measurement requires both `--execute` and an explicit `--device ID` obtained from the read-only result. `--rounds` accepts 1…20. Do not use a guessed device ID. Execution changes that device's nominal rate and can interrupt other applications' audio. Stop playback and choose a test device before intentionally running it.

The tool measures with a monotonic clock, protects listener-observed values, and attempts to restore and read back the original rate after successful rounds or a round failure. `RESTORE VERIFIED` reports readback success; `RESTORE FAILED` identifies the original rate and device for manual recovery. This is an attempted recovery contract, not a guarantee that a disconnected or failing device will accept it.

Neither dry-run nor execute mode is invoked by the bundle script or routine CI. The CPU-only `--benchmark-output-conditioning` option is separate and does not run RateMatchBench.
