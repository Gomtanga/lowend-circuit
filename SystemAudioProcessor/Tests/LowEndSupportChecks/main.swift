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
        == "Tap 96.0 kHz -> HighExciter 2x -> 192.0 kHz internal",
    "oversampling indicator must describe the processing path"
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

let tidalEntry = SourceFormatLogEntry(
    date: now,
    message: "TIDAL decoder source stream format sample_rate: 44100 bit_depth: 16"
)
let tidalFormat = SourceFormatParser.parseTIDAL(entries: [tidalEntry])
require(tidalFormat?.sampleRate == 44_100, "TIDAL source stream sample rate must parse")
require(tidalFormat?.bitDepth == 16, "TIDAL source stream bit depth must parse")
require(tidalFormat?.player == .tidal, "TIDAL parser must preserve player identity")

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
var underflowDestination = Array(repeating: Float(1), count: 4)
underflowDestination.withUnsafeMutableBufferPointer {
    _ = lc_ring_buffer_pop(ring, $0.baseAddress, UInt32($0.count))
}
require(lc_ring_buffer_underrun_samples(ring) == 4, "ring buffer must count output underruns")

let overflowSource: [Float] = [1, 2, 3, 4, 5, 6]
overflowSource.withUnsafeBufferPointer {
    _ = lc_ring_buffer_push(ring, $0.baseAddress, UInt32($0.count))
}
require(lc_ring_buffer_dropped_write_samples(ring) == 2, "ring buffer must count dropped writes")
lc_ring_buffer_reset_diagnostics(ring)
require(lc_ring_buffer_underrun_samples(ring) == 0, "underrun diagnostics must reset")
require(lc_ring_buffer_dropped_write_samples(ring) == 0, "drop diagnostics must reset")

print("LowEndSupportChecks: all checks passed")
