import Foundation

public struct AudioProcessDescriptor: Equatable, Sendable {
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String
    public let isRunningOutput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

public enum AudioProcessMatcher {
    public static func resolve(requestedBundleIDs: [String],
                               from connected: [AudioProcessDescriptor]) -> [AudioProcessDescriptor] {
        let requested = requestedBundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !requested.isEmpty else { return [] }

        let matches = connected.filter { process in
            let candidate = process.bundleID.lowercased()
            return requested.contains { bundleID in
                candidate == bundleID || candidate.hasPrefix(bundleID + ".")
            }
        }
        let activeMatches = matches.filter(\.isRunningOutput)
        let preferred = activeMatches.isEmpty ? matches : activeMatches
        var seen = Set<UInt32>()
        return preferred.filter { seen.insert($0.objectID).inserted }
    }
}

public enum ExciterOversamplingPolicy {
    public static func factor(for sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite, sampleRate > 0 else { return 1 }
        if sampleRate <= 48_000.5 { return 4 }
        if sampleRate <= 96_000.5 { return 2 }
        return 1
    }

    public static func indicator(processingSampleRate: Double, factor: UInt32) -> String {
        let internalRate = processingSampleRate * Double(factor)
        return String(
            format: "Tap %.1f kHz -> HighExciter %ux -> %.1f kHz internal",
            processingSampleRate / 1000,
            factor,
            internalRate / 1000
        )
    }
}
