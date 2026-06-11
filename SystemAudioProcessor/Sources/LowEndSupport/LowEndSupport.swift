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

public enum ExciterOversamplingMode: UInt32, CaseIterable, Sendable {
    case auto = 0
    case one = 1
    case two = 2
    case four = 4

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .one: return "1x"
        case .two: return "2x"
        case .four: return "4x"
        }
    }

    public var requestedFactor: UInt32? {
        self == .auto ? nil : rawValue
    }
}

public struct ExciterOversamplingResolution: Equatable, Sendable {
    public let mode: ExciterOversamplingMode
    public let requestedFactor: UInt32
    public let effectiveFactor: UInt32
    public let processingSampleRate: Double

    public var internalSampleRate: Double {
        processingSampleRate * Double(effectiveFactor)
    }

    public var isSafetyLimited: Bool {
        mode != .auto && requestedFactor != effectiveFactor
    }
}

public enum ExciterOversamplingPolicy {
    public static let maximumInternalSampleRate = 384_000.0

    public static func factor(for sampleRate: Double) -> UInt32 {
        resolve(processingSampleRate: sampleRate, mode: .auto).effectiveFactor
    }

    public static func resolve(
        processingSampleRate: Double,
        mode: ExciterOversamplingMode
    ) -> ExciterOversamplingResolution {
        let validRate = processingSampleRate.isFinite && processingSampleRate > 0
            ? processingSampleRate
            : maximumInternalSampleRate
        let requestedFactor: UInt32
        if let manualFactor = mode.requestedFactor {
            requestedFactor = manualFactor
        } else if validRate <= 48_000.5 {
            requestedFactor = 4
        } else if validRate <= 96_000.5 {
            requestedFactor = 2
        } else {
            requestedFactor = 1
        }

        var effectiveFactor = requestedFactor
        while effectiveFactor > 1
                && validRate * Double(effectiveFactor) > maximumInternalSampleRate + 0.5 {
            effectiveFactor /= 2
        }

        return ExciterOversamplingResolution(
            mode: mode,
            requestedFactor: requestedFactor,
            effectiveFactor: effectiveFactor,
            processingSampleRate: validRate
        )
    }

    public static func indicator(_ resolution: ExciterOversamplingResolution) -> String {
        let path = String(
            format: "Engine %.1f kHz -> HighExciter %ux -> %.1f kHz internal",
            resolution.processingSampleRate / 1000,
            resolution.effectiveFactor,
            resolution.internalSampleRate / 1000
        )
        guard resolution.isSafetyLimited else { return path }
        return "\(path) | \(resolution.requestedFactor)x requested / \(resolution.effectiveFactor)x safety limit"
    }

    public static func indicator(processingSampleRate: Double, factor: UInt32) -> String {
        indicator(
            ExciterOversamplingResolution(
                mode: ExciterOversamplingMode(rawValue: factor) ?? .one,
                requestedFactor: factor,
                effectiveFactor: factor,
                processingSampleRate: processingSampleRate
            )
        )
    }
}
