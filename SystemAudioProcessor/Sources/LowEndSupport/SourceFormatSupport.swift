import Foundation

public enum SourcePlayer: String, CaseIterable, Sendable {
    case appleMusic
    case tidal

    public var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .tidal:
            return "TIDAL"
        }
    }
}

public enum SourceFormatConfidence: Int, Comparable, Sendable {
    case unknown = 0
    case inferred = 1
    case detected = 2

    public static func < (lhs: SourceFormatConfidence, rhs: SourceFormatConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum SourceFormatEvidence: String, Sendable {
    case unifiedLog
    case appleScript
    case tidalPlayerLog
    case unavailable
}

public struct SourceAudioFormat: Equatable, Sendable {
    public let player: SourcePlayer
    public let sampleRate: Double?
    public let bitDepth: Int?
    public let confidence: SourceFormatConfidence
    public let evidence: SourceFormatEvidence
    public let observedAt: Date

    public init(player: SourcePlayer,
                sampleRate: Double?,
                bitDepth: Int?,
                confidence: SourceFormatConfidence,
                evidence: SourceFormatEvidence,
                observedAt: Date) {
        self.player = player
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.confidence = confidence
        self.evidence = evidence
        self.observedAt = observedAt
    }

    public var hasUsableSampleRate: Bool {
        sampleRate.map { $0.isFinite && $0 >= 8_000 } ?? false
    }

    public var indicatorText: String {
        guard let sampleRate, hasUsableSampleRate else {
            return "Source \(player.displayName): unknown"
        }

        let rateText = sampleRate >= 1_000
            ? String(format: "%.1f kHz", sampleRate / 1_000)
            : String(format: "%.0f Hz", sampleRate)
        let depthText = bitDepth.map { " / \($0)-bit" } ?? ""
        let confidenceText = confidence == .detected ? "Detected" : "Inferred"
        return "Source \(player.displayName): \(rateText)\(depthText) (\(confidenceText))"
    }
}

public struct SourceFormatLogEntry: Equatable, Sendable {
    public let date: Date
    public let message: String

    public init(date: Date, message: String) {
        self.date = date
        self.message = message
    }
}

public enum TIDALPlayerLogResult: Equatable, Sendable {
    case unavailable
    case inactive
    case format(SourceAudioFormat)
}

public enum AppleMusicPlaybackState: String, Equatable, Sendable {
    case playing
    case paused
    case stopped
    case notRunning
}

public struct AppleMusicPlaybackContext: Equatable, Sendable {
    public let state: AppleMusicPlaybackState
    public let persistentID: String?
    public let sampleRate: Double?
    public let observedAt: Date

    public init(state: AppleMusicPlaybackState,
                persistentID: String?,
                sampleRate: Double?,
                observedAt: Date) {
        self.state = state
        self.persistentID = persistentID
        self.sampleRate = sampleRate
        self.observedAt = observedAt
    }

    public var isPlaying: Bool { state == .playing }
}

public enum SourceFormatParser {
    private static let tidalSinkExpression = try? NSRegularExpression(
        pattern: #"(?i)CoreaudioSink::open,\s*rate:\s*([0-9]+(?:\.[0-9]+)?),\s*type:\s*(int|float)([0-9]{1,2})"#
    )

    private static let sampleRateExpressions = [
        #"(?i)(?:asbdSampleRate|sample[_ ]?rate|samplerate|mSampleRate)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)\s*(kHz|Hz)?"#,
        #"(?i)(?:input|source|stream)[^\n]{0,96}?([0-9]{4,7}(?:\.[0-9]+)?)\s*Hz"#,
        #"(?i)(?:ch|channels?)\s*,\s*([0-9]{4,7}(?:\.[0-9]+)?)\s*Hz"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let bitDepthExpressions = [
        #"(?i)(?:bit[_ ]?depth|sdBitDepth|bitsPerChannel)\s*[:=]\s*([0-9]{1,2})"#,
        #"(?i)from\s+([0-9]{1,2})-bit\s+source"#,
        #"(?i)\b([0-9]{1,2})-bit\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let standardSampleRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000,
        44_100, 48_000, 64_000, 88_200, 96_000, 176_400, 192_000,
        352_800, 384_000, 705_600, 768_000, 1_411_200, 1_536_000
    ]

    public static func parseAppleMusic(entries: [SourceFormatLogEntry]) -> SourceAudioFormat? {
        parse(entries: entries, player: .appleMusic)
    }

    public static func parseTIDAL(entries: [SourceFormatLogEntry]) -> SourceAudioFormat? {
        parse(entries: entries, player: .tidal)
    }

    public static func parseTIDALPlayerLog(entries: [SourceFormatLogEntry],
                                           observedAt: Date = Date()) -> SourceAudioFormat? {
        guard case let .format(format) = parseTIDALPlayerLogResult(
            entries: entries,
            observedAt: observedAt
        ) else {
            return nil
        }
        return format
    }

    public static func parseTIDALPlayerLogResult(
        entries: [SourceFormatLogEntry],
        observedAt: Date = Date()
    ) -> TIDALPlayerLogResult {
        guard let tidalSinkExpression else { return .unavailable }

        var latestFormat: (sampleRate: Double, bitDepth: Int)?
        var playbackIsActive: Bool?

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            let message = entry.message
            if let captures = captures(expression: tidalSinkExpression, in: message),
               let sampleRate = Double(captures[0]),
               let bitDepth = Int(captures[2]),
               isPlausibleSampleRate(sampleRate),
               (8...64).contains(bitDepth) {
                latestFormat = (sampleRate, bitDepth)
            }

            if message.contains(#""signal": "media.state""#) {
                if message.contains(#""state": "active""#) {
                    playbackIsActive = true
                } else if message.contains(#""state": "paused""#)
                            || message.contains(#""state": "stopped""#)
                            || message.contains(#""state": "completed""#) {
                    playbackIsActive = false
                }
            }
        }

        guard playbackIsActive == true else {
            return playbackIsActive == false ? .inactive : .unavailable
        }
        guard let latestFormat else { return .unavailable }
        return .format(
            SourceAudioFormat(
                player: .tidal,
                sampleRate: latestFormat.sampleRate,
                bitDepth: latestFormat.bitDepth,
                confidence: .detected,
                evidence: .tidalPlayerLog,
                observedAt: observedAt
            )
        )
    }

    public static func resolveAppleMusicFormat(
        logEntries: [SourceFormatLogEntry],
        scriptContext: AppleMusicPlaybackContext
    ) -> SourceAudioFormat? {
        guard scriptContext.isPlaying else { return nil }

        let logFormat = parseAppleMusic(entries: logEntries)

        guard let scriptRate = scriptContext.sampleRate,
              scriptRate.isFinite, scriptRate >= 8_000 else {
            return logFormat
        }

        guard let logFormat else {
            return SourceAudioFormat(
                player: .appleMusic,
                sampleRate: scriptRate,
                bitDepth: nil,
                confidence: .inferred,
                evidence: .appleScript,
                observedAt: scriptContext.observedAt
            )
        }

        let ratesAgree = logFormat.hasUsableSampleRate
            && abs(logFormat.sampleRate! - scriptRate) <= 1

        if ratesAgree {
            return SourceAudioFormat(
                player: .appleMusic,
                sampleRate: logFormat.sampleRate ?? scriptRate,
                bitDepth: logFormat.bitDepth,
                confidence: logFormat.confidence,
                evidence: logFormat.evidence,
                observedAt: max(logFormat.observedAt, scriptContext.observedAt)
            )
        }

        return SourceAudioFormat(
            player: .appleMusic,
            sampleRate: scriptRate,
            bitDepth: nil,
            confidence: .inferred,
            evidence: .appleScript,
            observedAt: scriptContext.observedAt
        )
    }

    private static func parse(entries: [SourceFormatLogEntry],
                              player: SourcePlayer) -> SourceAudioFormat? {
        var bestFormat: SourceAudioFormat?
        for entry in entries {
            guard let sampleRate = extractSampleRate(from: entry.message) else {
                continue
            }

            let bitDepth = extractBitDepth(from: entry.message)
            let lowercased = entry.message.lowercased()
            let explicitlyDescribesSource = lowercased.contains("source")
                || lowercased.contains("input format")
                || lowercased.contains("decoder")
                || lowercased.contains("stream format")
                || lowercased.contains("audiocapabilities")
            let confidence: SourceFormatConfidence = explicitlyDescribesSource ? .detected : .inferred

            let candidate = SourceAudioFormat(
                player: player,
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                confidence: confidence,
                evidence: .unifiedLog,
                observedAt: entry.date
            )
            if let current = bestFormat {
                if candidate.confidence > current.confidence
                    || (candidate.confidence == current.confidence
                        && candidate.observedAt > current.observedAt) {
                    bestFormat = candidate
                }
            } else {
                bestFormat = candidate
            }
        }
        return bestFormat
    }

    public static func extractSampleRate(from message: String) -> Double? {
        for expression in sampleRateExpressions {
            guard let captures = captures(expression: expression, in: message),
                  let rawValue = Double(captures[0]) else {
                continue
            }
            let unit = captures.count > 1 ? captures[1].lowercased() : ""
            let normalized = unit == "khz" ? rawValue * 1_000 : rawValue
            if isPlausibleSampleRate(normalized) {
                return normalized
            }
        }
        return nil
    }

    public static func extractBitDepth(from message: String) -> Int? {
        for expression in bitDepthExpressions {
            guard let captures = captures(expression: expression, in: message),
                  let bitDepth = Int(captures[0]),
                  (8...64).contains(bitDepth) else {
                continue
            }
            return bitDepth
        }
        return nil
    }

    private static func captures(expression: NSRegularExpression,
                                 in text: String) -> [String]? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }

        return (1..<match.numberOfRanges).map { index in
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let swiftRange = Range(captureRange, in: text) else {
                return ""
            }
            return String(text[swiftRange])
        }
    }

    private static func isPlausibleSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite && standardSampleRates.contains { abs($0 - sampleRate) <= 1 }
    }
}

public enum SourceRateMatchPolicy {
    public static func bestRate(sourceRate: Double,
                                supportedRates: [Double]) -> Double? {
        guard sourceRate.isFinite, sourceRate >= 8_000 else { return nil }
        let supported = supportedRates
            .filter { $0.isFinite && $0 >= 8_000 }
            .sorted()
        guard !supported.isEmpty else { return nil }

        if let exact = supported.first(where: { abs($0 - sourceRate) <= 1 }) {
            return exact
        }

        let familyBase = isMultiple(sourceRate, of: 44_100) ? 44_100.0 : 48_000.0
        return supported.last {
            $0 < sourceRate
                && isMultiple($0, of: familyBase)
        }
    }

    private static func isMultiple(_ rate: Double, of base: Double) -> Bool {
        let ratio = rate / base
        return abs(ratio - ratio.rounded()) <= 0.000_1
    }
}

public struct SourceRateMatchPreview: Equatable, Sendable {
    public let sourceRate: Double?
    public let currentDeviceRate: Double?
    public let targetRate: Double?
    public let isDeviceRateSettable: Bool

    public init(sourceRate: Double?,
                currentDeviceRate: Double?,
                targetRate: Double?,
                isDeviceRateSettable: Bool) {
        self.sourceRate = sourceRate
        self.currentDeviceRate = currentDeviceRate
        self.targetRate = targetRate
        self.isDeviceRateSettable = isDeviceRateSettable
    }

    public var indicatorText: String {
        guard let sourceRate, sourceRate.isFinite, sourceRate >= 8_000 else {
            return "Rate Match Preview: source waiting"
        }
        guard let targetRate else {
            return "Rate Match Preview: \(Self.rateText(sourceRate)) -> no compatible DAC rate"
        }

        let suffix: String
        if !isDeviceRateSettable {
            suffix = "read-only device"
        } else if let currentDeviceRate, abs(currentDeviceRate - targetRate) <= 1 {
            suffix = "already matched"
        } else {
            suffix = "preview only"
        }
        return "Rate Match Preview: \(Self.rateText(sourceRate)) -> \(Self.rateText(targetRate)) (\(suffix))"
    }

    private static func rateText(_ sampleRate: Double) -> String {
        sampleRate >= 1_000
            ? String(format: "%.1f kHz", sampleRate / 1_000)
            : String(format: "%.0f Hz", sampleRate)
    }
}

public extension SourceRateMatchPolicy {
    static func preview(sourceRate: Double?,
                        currentDeviceRate: Double?,
                        supportedRates: [Double],
                        isDeviceRateSettable: Bool) -> SourceRateMatchPreview {
        SourceRateMatchPreview(
            sourceRate: sourceRate,
            currentDeviceRate: currentDeviceRate,
            targetRate: sourceRate.flatMap {
                bestRate(sourceRate: $0, supportedRates: supportedRates)
            },
            isDeviceRateSettable: isDeviceRateSettable
        )
    }
}
