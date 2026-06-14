import Foundation
import AudioRingBufferC
import LowEndDSPCoreC
import LowEndSupport

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let tidalProcesses = [
    AudioProcessDescriptor(objectID: 10, pid: 100, bundleID: "com.tidal.desktop", isRunningOutput: false),
    AudioProcessDescriptor(objectID: 11, pid: 101, bundleID: "com.tidal.desktop.player", isRunningOutput: true),
    AudioProcessDescriptor(objectID: 12, pid: 102, bundleID: "com.tidal.desktop.helper", isRunningOutput: false)
]
let tidalResult = AudioProcessMatcher.resolve(
    requestedBundleIDs: ["com.tidal.desktop"],
    from: tidalProcesses
)
require(tidalResult.map(\.bundleID) == ["com.tidal.desktop.player"],
        "TIDAL parent bundle must select the active player process")

let idleProcesses = [
    AudioProcessDescriptor(objectID: 20, pid: 200, bundleID: "com.example.player.helper", isRunningOutput: false)
]
require(
    AudioProcessMatcher.resolve(requestedBundleIDs: ["com.example.player"], from: idleProcesses)
        == idleProcesses,
    "idle child process fallback must remain available"
)

let sibling = [
    AudioProcessDescriptor(objectID: 30, pid: 300, bundleID: "com.tidal.desktopish", isRunningOutput: true)
]
require(
    AudioProcessMatcher.resolve(requestedBundleIDs: ["com.tidal.desktop"], from: sibling).isEmpty,
    "bundle matching must respect dot boundaries"
)

require(ExciterOversamplingPolicy.factor(for: 44_100) == 4, "44.1 kHz must use 4x")
require(ExciterOversamplingPolicy.factor(for: 48_000) == 4, "48 kHz must use 4x")
require(ExciterOversamplingPolicy.factor(for: 96_000) == 2, "96 kHz must use 2x")
require(ExciterOversamplingPolicy.factor(for: 192_000) == 1, "192 kHz must use 1x")
require(ExciterOversamplingPolicy.factor(for: 768_000) == 1, "768 kHz must use 1x")
require(
    ExciterOversamplingPolicy.indicator(processingSampleRate: 96_000, factor: 2)
        == "Engine 96.0 kHz -> HighExciter 2x -> 192.0 kHz internal",
    "oversampling indicator must describe the processing path"
)
let manualFourAt96 = ExciterOversamplingPolicy.resolve(
    processingSampleRate: 96_000,
    mode: .four
)
require(manualFourAt96.effectiveFactor == 4, "96 kHz manual 4x must remain below 384 kHz")
let manualFourAt192 = ExciterOversamplingPolicy.resolve(
    processingSampleRate: 192_000,
    mode: .four
)
require(manualFourAt192.effectiveFactor == 2, "192 kHz manual 4x must clamp to 2x")
require(manualFourAt192.isSafetyLimited, "clamped manual mode must report the safety limit")
let manualFourAt768 = ExciterOversamplingPolicy.resolve(
    processingSampleRate: 768_000,
    mode: .four
)
require(manualFourAt768.effectiveFactor == 1, "768 kHz manual 4x must clamp to 1x")
require(
    ExciterOversamplingPolicy.indicator(manualFourAt768)
        == "Engine 768.0 kHz -> HighExciter 1x -> 768.0 kHz internal | 4x requested / 1x safety limit",
    "limited oversampling indicator must expose requested and effective factors"
)

let now = Date()
let appleDecoderEntry = SourceFormatLogEntry(
    date: now,
    message: "ACAppleLosslessDecoder.cpp Input format: 2 ch, 192000 Hz, decoded from 24-bit source"
)
let appleFormat = SourceFormatParser.parseAppleMusic(entries: [appleDecoderEntry])
require(appleFormat?.sampleRate == 192_000, "Apple Music decoder log must expose 192 kHz")
require(appleFormat?.bitDepth == 24, "Apple Music decoder log must expose 24-bit source depth")
require(appleFormat?.confidence == .detected, "explicit Apple source format must be detected")
require(
    appleFormat?.indicatorText == "Source Apple Music: 192.0 kHz / 24-bit (Detected)",
    "Apple Music indicator must distinguish source format from processing format"
)

let appleCapabilitiesEntry = SourceFormatLogEntry(
    date: now.addingTimeInterval(1),
    message: "audioCapabilities: asbdSampleRate = 96 kHz, sdBitDepth = 24 bit"
)
let appleCapabilitiesFormat = SourceFormatParser.parseAppleMusic(entries: [appleCapabilitiesEntry])
require(appleCapabilitiesFormat?.sampleRate == 96_000, "Apple Music kHz values must normalize to Hz")
require(appleCapabilitiesFormat?.bitDepth == 24, "Apple Music capability bit depth must parse")

// MARK: - Apple Music Playback State Detection

let amPlayingContext = AppleMusicPlaybackContext(
    state: .playing, persistentID: "track-abc", sampleRate: 44_100, observedAt: now
)
let amPausedContext = AppleMusicPlaybackContext(
    state: .paused, persistentID: "track-abc", sampleRate: 44_100, observedAt: now
)
let amStoppedContext = AppleMusicPlaybackContext(
    state: .stopped, persistentID: nil, sampleRate: nil, observedAt: now
)
let amNotRunningContext = AppleMusicPlaybackContext(
    state: .notRunning, persistentID: nil, sampleRate: nil, observedAt: now
)

// Paused/stopped/not-running must return nil regardless of log evidence
require(
    SourceFormatParser.resolveAppleMusicFormat(
        logEntries: [appleDecoderEntry], scriptContext: amPausedContext
    ) == nil,
    "paused Apple Music must not produce a source format"
)
require(
    SourceFormatParser.resolveAppleMusicFormat(
        logEntries: [appleDecoderEntry], scriptContext: amStoppedContext
    ) == nil,
    "stopped Apple Music must not produce a source format"
)
require(
    SourceFormatParser.resolveAppleMusicFormat(
        logEntries: [], scriptContext: amNotRunningContext
    ) == nil,
    "not-running Apple Music must not produce a source format"
)

// Playing with only AppleScript → Inferred
let amScriptOnly = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [], scriptContext: amPlayingContext
)
require(amScriptOnly?.sampleRate == 44_100, "AppleScript-only playing must return sample rate")
require(amScriptOnly?.bitDepth == nil, "AppleScript-only must not invent bit depth")
require(amScriptOnly?.confidence == .inferred, "AppleScript-only must be Inferred")
require(amScriptOnly?.evidence == .appleScript, "AppleScript-only evidence must be appleScript")

// Playing with only Unified Log → detected if source keywords present
let amLogOnlyPlaying = AppleMusicPlaybackContext(
    state: .playing, persistentID: "track-xyz", sampleRate: nil, observedAt: now
)
let amLogOnly = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [appleDecoderEntry], scriptContext: amLogOnlyPlaying
)
require(amLogOnly?.sampleRate == 192_000, "log-only playing must return log sample rate")
require(amLogOnly?.bitDepth == 24, "log-only playing must return log bit depth")
require(amLogOnly?.confidence == .detected, "log-only with source keywords must be Detected")
require(amLogOnly?.evidence == .unifiedLog, "log-only evidence must be unifiedLog")

// Cross-validation: rates agree → prefer log confidence + bit depth
let amPlaying44 = AppleMusicPlaybackContext(
    state: .playing, persistentID: "track-44", sampleRate: 44_100, observedAt: now.addingTimeInterval(1)
)
let am44LogEntry = SourceFormatLogEntry(
    date: now,
    message: "ACAppleLosslessDecoder.cpp Input format: 2 ch, 44100 Hz, decoded from 16-bit source"
)
let amCrossValidated = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [am44LogEntry], scriptContext: amPlaying44
)
require(amCrossValidated?.sampleRate == 44_100, "cross-validated rate must match")
require(amCrossValidated?.bitDepth == 16, "cross-validated bit depth must come from log")
require(amCrossValidated?.confidence == .detected, "cross-validated must use log confidence")
require(amCrossValidated?.evidence == .unifiedLog, "cross-validated must prefer log evidence")

// Cross-validation: rates disagree → AppleScript wins (reflects current track, log may be stale)
let amPlaying48 = AppleMusicPlaybackContext(
    state: .playing, persistentID: "track-disagree", sampleRate: 48_000, observedAt: now
)
let amDisagree = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [am44LogEntry], scriptContext: amPlaying48
)
require(amDisagree?.sampleRate == 48_000, "rate disagreement must prefer AppleScript rate")
require(amDisagree?.confidence == .inferred, "rate disagreement must use Inferred confidence")
require(amDisagree?.evidence == .appleScript, "rate disagreement must use AppleScript evidence")

// MARK: - Apple Music Rate Transition Fixtures

let amRate44Log = SourceFormatLogEntry(
    date: now,
    message: "ACAppleLosslessDecoder.cpp Input format: 2 ch, 44100 Hz, decoded from 16-bit source"
)
let amRate48Log = SourceFormatLogEntry(
    date: now.addingTimeInterval(2),
    message: "ACAppleLosslessDecoder.cpp Input format: 2 ch, 48000 Hz, decoded from 24-bit source"
)
let amRate96Log = SourceFormatLogEntry(
    date: now.addingTimeInterval(4),
    message: "ACAppleLosslessDecoder.cpp Input format: 2 ch, 96000 Hz, decoded from 24-bit source"
)
let amRate192Log = SourceFormatLogEntry(
    date: now.addingTimeInterval(6),
    message: "ACAppleLosslessDecoder.cpp Input format: 2 ch, 192000 Hz, decoded from 24-bit source"
)

// 44.1 → 48 kHz transition
let amTrack44to48 = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [amRate44Log, amRate48Log],
    scriptContext: AppleMusicPlaybackContext(
        state: .playing, persistentID: "track-48", sampleRate: 48_000, observedAt: now.addingTimeInterval(2)
    )
)
require(amTrack44to48?.sampleRate == 48_000, "44.1→48 kHz transition must show 48 kHz")
require(amTrack44to48?.bitDepth == 24, "44.1→48 kHz transition must show new bit depth")

// 48 → 96 kHz transition
let amTrack48to96 = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [amRate48Log, amRate96Log],
    scriptContext: AppleMusicPlaybackContext(
        state: .playing, persistentID: "track-96", sampleRate: 96_000, observedAt: now.addingTimeInterval(4)
    )
)
require(amTrack48to96?.sampleRate == 96_000, "48→96 kHz transition must show 96 kHz")

// 96 → 192 kHz transition
let amTrack96to192 = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [amRate96Log, amRate192Log],
    scriptContext: AppleMusicPlaybackContext(
        state: .playing, persistentID: "track-192", sampleRate: 192_000, observedAt: now.addingTimeInterval(6)
    )
)
require(amTrack96to192?.sampleRate == 192_000, "96→192 kHz transition must show 192 kHz")

// 192 → 44.1 kHz transition (high-res to lossy)
let amRate44LogLate = SourceFormatLogEntry(
    date: now.addingTimeInterval(8),
    message: "ACAppleLosslessDecoder.cpp Input format: 2 ch, 44100 Hz, decoded from 16-bit source"
)
let amTrack192to44 = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [amRate192Log, amRate44LogLate],
    scriptContext: AppleMusicPlaybackContext(
        state: .playing, persistentID: "track-44b", sampleRate: 44_100, observedAt: now.addingTimeInterval(8)
    )
)
require(amTrack192to44?.sampleRate == 44_100, "192→44.1 kHz transition must show 44.1 kHz")

// 96 kHz playing → paused → 96 kHz resumes (format clears on pause)
let am96Paused = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [amRate96Log],
    scriptContext: AppleMusicPlaybackContext(
        state: .paused, persistentID: "track-96", sampleRate: 96_000, observedAt: now.addingTimeInterval(3)
    )
)
require(am96Paused == nil, "paused playback must clear format regardless of log evidence")

let am96Resumed = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [amRate96Log],
    scriptContext: AppleMusicPlaybackContext(
        state: .playing, persistentID: "track-96", sampleRate: 96_000, observedAt: now.addingTimeInterval(5)
    )
)
require(am96Resumed?.sampleRate == 96_000, "resumed 96 kHz must re-detect after pause")

// MARK: - Apple Music indicator text with state

let amPlayingNoScript = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [], scriptContext: AppleMusicPlaybackContext(
        state: .playing, persistentID: "track-no-meta", sampleRate: nil, observedAt: now
    )
)
require(amPlayingNoScript == nil, "playing with no script rate and no log must return nil")

let amInferredIndicator = SourceFormatParser.resolveAppleMusicFormat(
    logEntries: [], scriptContext: amPlayingContext
)
require(
    amInferredIndicator?.indicatorText == "Source Apple Music: 44.1 kHz (Inferred)",
    "Apple Music Inferred indicator must not show bit depth"
)

let tidalEntry = SourceFormatLogEntry(
    date: now,
    message: "TIDAL decoder source stream format sample_rate: 44100 bit_depth: 16"
)
let tidalFormat = SourceFormatParser.parseTIDAL(entries: [tidalEntry])
require(tidalFormat?.sampleRate == 44_100, "TIDAL source stream sample rate must parse")
require(tidalFormat?.bitDepth == 16, "TIDAL source stream bit depth must parse")
require(tidalFormat?.player == .tidal, "TIDAL parser must preserve player identity")

let tidalPlayerLogEntries = [
    SourceFormatLogEntry(
        date: now,
        message: "[tisoc] CoreaudioSink::open, rate: 96000, type: int24"
    ),
    SourceFormatLogEntry(
        date: now.addingTimeInterval(0.1),
        message: #"SIGNAL: {"signal": "media.state", "state": "active"}"#
    )
]
let tidalPlayerFormat = SourceFormatParser.parseTIDALPlayerLog(
    entries: tidalPlayerLogEntries,
    observedAt: now.addingTimeInterval(0.2)
)
require(tidalPlayerFormat?.sampleRate == 96_000, "TIDAL player log must expose 96 kHz")
require(tidalPlayerFormat?.bitDepth == 24, "TIDAL player log int24 must expose 24-bit")
require(tidalPlayerFormat?.confidence == .detected, "TIDAL player log must be detected")
require(
    tidalPlayerFormat?.evidence == .tidalPlayerLog,
    "TIDAL player log evidence must remain explicit"
)

let pausedTidalEntries = tidalPlayerLogEntries + [
    SourceFormatLogEntry(
        date: now.addingTimeInterval(0.3),
        message: #"SIGNAL: {"signal": "media.state", "state": "paused"}"#
    )
]
require(
    SourceFormatParser.parseTIDALPlayerLog(entries: pausedTidalEntries) == nil,
    "paused TIDAL playback must not retain a stale source format"
)

let completedTidalEntries = tidalPlayerLogEntries + [
    SourceFormatLogEntry(
        date: now.addingTimeInterval(0.3),
        message: #"SIGNAL: {"signal": "media.state", "state": "completed"}"#
    )
]
require(
    SourceFormatParser.parseTIDALPlayerLog(entries: completedTidalEntries) == nil,
    "completed TIDAL playback must not retain a stale source format"
)
require(
    SourceFormatParser.parseTIDALPlayerLogResult(entries: completedTidalEntries) == .inactive,
    "completed TIDAL playback must explicitly invalidate the tracker cache"
)
require(
    SourceFormatParser.parseTIDALPlayerLogResult(entries: []) == .unavailable,
    "missing TIDAL player evidence must preserve the fallback path"
)

let newerOutputEntry = SourceFormatLogEntry(
    date: now.addingTimeInterval(2),
    message: "device sampleRate = 96000, 32-bit Float"
)
let sourcePreferred = SourceFormatParser.parseAppleMusic(entries: [
    appleDecoderEntry,
    newerOutputEntry
])
require(
    sourcePreferred?.sampleRate == 192_000 && sourcePreferred?.confidence == .detected,
    "explicit source format must outrank a newer shared-device format"
)

require(
    SourceFormatParser.extractSampleRate(from: "render buffer size = 512 frames") == nil,
    "unrelated buffer sizes must not be interpreted as sample rates"
)
require(
    SourceFormatParser.extractSampleRate(from: "sampleRate = 12345") == nil,
    "non-standard rates must not be presented as a detected source format"
)

require(
    SourceRateMatchPolicy.bestRate(
        sourceRate: 192_000,
        supportedRates: [44_100, 48_000, 96_000, 192_000]
    ) == 192_000,
    "rate matching must prefer an exact DAC rate"
)
require(
    SourceRateMatchPolicy.bestRate(
        sourceRate: 192_000,
        supportedRates: [44_100, 48_000, 96_000]
    ) == 96_000,
    "192 kHz must fall back within the 48 kHz family"
)
require(
    SourceRateMatchPolicy.bestRate(
        sourceRate: 176_400,
        supportedRates: [48_000, 88_200, 96_000]
    ) == 88_200,
    "176.4 kHz must fall back within the 44.1 kHz family"
)
require(
    SourceRateMatchPolicy.bestRate(
        sourceRate: 44_100,
        supportedRates: [48_000, 96_000]
    ) == nil,
    "rate matching must not silently cross sample-rate families"
)
let exactPreview = SourceRateMatchPolicy.preview(
    sourceRate: 96_000,
    currentDeviceRate: 96_000,
    supportedRates: [44_100, 48_000, 96_000, 192_000],
    isDeviceRateSettable: true
)
require(exactPreview.targetRate == 96_000, "preview must preserve an exact supported rate")
require(
    exactPreview.indicatorText
        == "Rate Match Preview: 96.0 kHz -> 96.0 kHz (already matched)",
    "preview must distinguish an already matched device"
)
let fallbackPreview = SourceRateMatchPolicy.preview(
    sourceRate: 192_000,
    currentDeviceRate: 48_000,
    supportedRates: [44_100, 48_000, 96_000],
    isDeviceRateSettable: true
)
require(fallbackPreview.targetRate == 96_000, "preview must expose the safe family fallback")
require(
    fallbackPreview.indicatorText
        == "Rate Match Preview: 192.0 kHz -> 96.0 kHz (preview only)",
    "preview must state that it does not mutate the device"
)
let waitingPreview = SourceRateMatchPolicy.preview(
    sourceRate: nil,
    currentDeviceRate: 48_000,
    supportedRates: [44_100, 48_000],
    isDeviceRateSettable: true
)
require(
    waitingPreview.indicatorText == "Rate Match Preview: source waiting",
    "preview must remain visible while waiting for source metadata"
)
var stabilityGate = SourceRateMatchStabilityGate()
let stableFormat = SourceAudioFormat(
    player: .tidal,
    sampleRate: 96_000,
    bitDepth: 24,
    confidence: .detected,
    evidence: .tidalPlayerLog,
    observedAt: now
)
require(
    stabilityGate.observe(
        format: stableFormat,
        currentDeviceRate: 48_000,
        supportedRates: [44_100, 48_000, 96_000],
        isDeviceRateSettable: true,
        observedAt: now
    ) == nil,
    "rate matching must wait for a stable second observation"
)
require(
    stabilityGate.observe(
        format: stableFormat,
        currentDeviceRate: 48_000,
        supportedRates: [44_100, 48_000, 96_000],
        isDeviceRateSettable: true,
        observedAt: now.addingTimeInterval(1)
    ) == 96_000,
    "stable source observations must emit the target rate"
)
require(
    stabilityGate.observe(
        format: stableFormat,
        currentDeviceRate: 48_000,
        supportedRates: [44_100, 48_000, 96_000],
        isDeviceRateSettable: true,
        observedAt: now.addingTimeInterval(2)
    ) == nil,
    "one stable source must not repeatedly emit the same transition"
)

guard let sharedCore = lc_dsp_core_create() else {
    fputs("FAIL: shared DSP core allocation\n", stderr)
    exit(1)
}
defer { lc_dsp_core_destroy(sharedCore) }
lc_dsp_core_prepare(sharedCore, 96_000, 2)

var cleanSettings = LCDSPSettings()
lc_dsp_core_precompute(96_000, 0, 0, 0, 0, &cleanSettings)
lc_dsp_core_update(sharedCore, &cleanSettings)
var cleanLeft: [Float] = [0.25, -0.5, 0.75]
var cleanRight: [Float] = [-0.25, 0.5, -0.75]
cleanLeft.withUnsafeMutableBufferPointer { left in
    cleanRight.withUnsafeMutableBufferPointer { right in
        lc_dsp_core_process_stereo(sharedCore, left.baseAddress, right.baseAddress, UInt32(left.count))
    }
}
require(cleanLeft == [0.25, -0.5, 0.75], "shared Core Clean path must preserve left samples")
require(cleanRight == [-0.25, 0.5, -0.75], "shared Core Clean path must preserve right samples")

var exciterSettings = LCDSPSettings()
lc_dsp_core_precompute(96_000, 100, 100, 0, 2, &exciterSettings)
require(exciterSettings.exciterOversampleFactor == 2, "shared Core must precompute 2x at 96 kHz")
lc_dsp_core_update(sharedCore, &exciterSettings)
var excitedLeft = Array(repeating: Float(0), count: 512)
var excitedRight = Array(repeating: Float(0), count: 512)
for index in excitedLeft.indices {
    let sample: Float = index.isMultiple(of: 2) ? 0.3 : -0.3
    excitedLeft[index] = sample
    excitedRight[index] = sample
}
excitedLeft.withUnsafeMutableBufferPointer { left in
    excitedRight.withUnsafeMutableBufferPointer { right in
        lc_dsp_core_process_stereo(sharedCore, left.baseAddress, right.baseAddress, UInt32(left.count))
    }
}
require(excitedLeft.allSatisfy(\.isFinite), "shared Core HighExciter left output must remain finite")
require(excitedRight.allSatisfy(\.isFinite), "shared Core HighExciter right output must remain finite")

guard let ring = lc_ring_buffer_create(4) else {
    fputs("FAIL: ring buffer allocation\n", stderr)
    exit(1)
}
defer { lc_ring_buffer_destroy(ring) }
require(lc_ring_buffer_total_written_samples(ring) == 0, "ring write total must start at zero")
require(lc_ring_buffer_total_read_samples(ring) == 0, "ring read total must start at zero")
var underflowDestination = Array(repeating: Float(1), count: 4)
underflowDestination.withUnsafeMutableBufferPointer {
    _ = lc_ring_buffer_pop(ring, $0.baseAddress, UInt32($0.count))
}
require(lc_ring_buffer_underrun_samples(ring) == 4, "ring buffer must count output underruns")
require(lc_ring_buffer_total_read_samples(ring) == 0, "underruns must not advance ring read total")

let overflowSource: [Float] = [1, 2, 3, 4, 5, 6]
overflowSource.withUnsafeBufferPointer {
    _ = lc_ring_buffer_push(ring, $0.baseAddress, UInt32($0.count))
}
require(lc_ring_buffer_dropped_write_samples(ring) == 2, "ring buffer must count dropped writes")
require(lc_ring_buffer_total_written_samples(ring) == 4, "ring write total must count accepted samples")
var readableDestination = Array(repeating: Float(0), count: 4)
readableDestination.withUnsafeMutableBufferPointer {
    _ = lc_ring_buffer_pop(ring, $0.baseAddress, UInt32($0.count))
}
require(readableDestination == [1, 2, 3, 4], "ring buffer must preserve accepted samples")
require(lc_ring_buffer_total_read_samples(ring) == 4, "ring read total must count consumed samples")
lc_ring_buffer_reset_diagnostics(ring)
require(lc_ring_buffer_underrun_samples(ring) == 0, "underrun diagnostics must reset")
require(lc_ring_buffer_dropped_write_samples(ring) == 0, "drop diagnostics must reset")
require(lc_ring_buffer_total_written_samples(ring) == 4, "diagnostic reset must preserve ring write total")
require(lc_ring_buffer_total_read_samples(ring) == 4, "diagnostic reset must preserve ring read total")
lc_ring_buffer_clear(ring)
require(lc_ring_buffer_total_written_samples(ring) == 4, "ring clear must preserve write progress")
require(lc_ring_buffer_total_read_samples(ring) == 4, "ring clear must preserve read progress")

guard let gainRamp = lc_output_gain_ramp_create(1) else {
    fputs("FAIL: output gain ramp allocation\n", stderr)
    exit(1)
}
defer { lc_output_gain_ramp_destroy(gainRamp) }
lc_output_gain_ramp_set_target(gainRamp, 0, 4)
var rampLeft: [Float] = [1, 1, 1, 1]
var rampRight: [Float] = [1, 1, 1, 1]
rampLeft.withUnsafeMutableBufferPointer { left in
    rampRight.withUnsafeMutableBufferPointer { right in
        lc_output_gain_ramp_apply_stereo(gainRamp, left.baseAddress, right.baseAddress, 4)
    }
}
require(abs(rampLeft[3]) < 0.000_1, "output ramp must reach silence")
require(abs(lc_output_gain_ramp_current(gainRamp)) < 0.000_1, "output ramp must publish gain")
lc_output_gain_ramp_set_target(gainRamp, 1, 2)
var rampInterleaved: [Float] = [1, 1, 1, 1]
rampInterleaved.withUnsafeMutableBufferPointer {
    lc_output_gain_ramp_apply_interleaved(gainRamp, $0.baseAddress, 2, 2)
}
require(abs(rampInterleaved[3] - 1) < 0.000_1, "interleaved ramp must reach unity")

print("LowEndSupportChecks: all checks passed")
