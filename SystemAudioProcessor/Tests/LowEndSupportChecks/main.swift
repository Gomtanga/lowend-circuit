import Foundation
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

print("LowEndSupportChecks: all checks passed")
