import Foundation

struct AudioDiagnosticsSnapshot: Sendable {
    let outputUnderrunSamples: UInt64
    let outputDroppedSamples: UInt64
    let visualizerDroppedSamples: UInt64
    let engineRestartCount: UInt64
    let captureTarget: String

    var displayText: String {
        "XRuns out \(outputUnderrunSamples) / drop \(outputDroppedSamples) / analysis \(visualizerDroppedSamples) | restart \(engineRestartCount) | \(captureTarget)"
    }
}
