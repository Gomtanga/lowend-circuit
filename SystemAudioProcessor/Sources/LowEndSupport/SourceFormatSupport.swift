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

    public var bundleID: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .tidal: return "com.tidal.desktop"
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

/// Capture scope is nil for the global tap and a list of bundle roots for a
/// process tap. Multiple usable players are deliberately ambiguous, even when
/// their rates happen to agree; there is no single source owning that mix.
public enum SourceFormatSelectionPolicy {
    public static func select(formats: [SourceAudioFormat],
                              capturedBundleIDs: [String]? = nil) -> SourceAudioFormat? {
        let roots = capturedBundleIDs?.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        let candidates = formats.filter { format in
            guard format.hasUsableSampleRate, format.confidence != .unknown else { return false }
            guard let roots else { return true }
            let playerBundle = format.player.bundleID.lowercased()
            return roots.contains { root in
                root == playerBundle || playerBundle.hasPrefix(root + ".")
                    || root.hasPrefix(playerBundle + ".")
            }
        }
        let players = Set(candidates.map(\.player))
        guard players.count == 1 else { return nil }
        return candidates.max { $0.observedAt < $1.observedAt }
    }
}

public enum TIDALPlayerLogResult: Equatable, Sendable {
    case unavailable
    case inactive
    /// A log exists, but no recent playback evidence belongs to this session.
    case stale
    case format(SourceAudioFormat)
}

/// Stateful parser for newly appended log records only. Polling an unchanged
/// file never refreshes observedAt. Reset when the player/file session changes.
public struct TIDALPlaybackEvidenceTracker: Sendable {
    public let maximumEvidenceAge: TimeInterval
    private var latestFormat: (sampleRate: Double, bitDepth: Int, date: Date)?
    private var playbackIsActive: Bool?
    private var activityDate: Date?

    public init(maximumEvidenceAge: TimeInterval = 15) {
        self.maximumEvidenceAge = max(0, maximumEvidenceAge)
    }

    public mutating func reset() {
        latestFormat = nil
        playbackIsActive = nil
        activityDate = nil
    }

    public mutating func ingest(_ entries: [SourceFormatLogEntry]) {
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            if let format = SourceFormatParser.tidalSinkFormat(from: entry.message),
               latestFormat == nil || entry.date >= latestFormat!.date {
                latestFormat = (format.sampleRate, format.bitDepth, entry.date)
            }
            if let active = SourceFormatParser.tidalPlaybackActivity(from: entry.message),
               activityDate == nil || entry.date >= activityDate! {
                playbackIsActive = active
                activityDate = entry.date
            }
        }
    }

    public func snapshot(observedAt: Date) -> TIDALPlayerLogResult {
        guard playbackIsActive != false else { return .inactive }
        guard playbackIsActive == true, let latestFormat, let activityDate else {
            return .unavailable
        }
        let evidenceAt = max(latestFormat.date, activityDate)
        guard observedAt.timeIntervalSince(evidenceAt) <= maximumEvidenceAge else { return .stale }
        return .format(SourceAudioFormat(
            player: .tidal, sampleRate: latestFormat.sampleRate,
            bitDepth: latestFormat.bitDepth, confidence: .detected,
            evidence: .tidalPlayerLog, observedAt: evidenceAt
        ))
    }
}

public enum TIDALLogReadPlan: Equatable, Sendable {
    case newSession
    case unchanged
    case read(from: UInt64)
}

/// A new PID/file identity or truncation starts at EOF. Historical bytes are
/// never assigned a fresh timestamp when monitoring attaches to a player.
public struct TIDALLogReadCursor: Sendable {
    private var sessionID: String?
    private var offset: UInt64 = 0

    public init() {}

    public mutating func reset() {
        sessionID = nil
        offset = 0
    }

    public mutating func plan(sessionID: String, fileSize: UInt64) -> TIDALLogReadPlan {
        guard self.sessionID == sessionID, fileSize >= offset else {
            self.sessionID = sessionID
            offset = fileSize
            return .newSession
        }
        return fileSize == offset ? .unchanged : .read(from: offset)
    }

    public mutating func didRead(through offset: UInt64) {
        self.offset = offset
    }
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
        var evidence = TIDALPlaybackEvidenceTracker()
        evidence.ingest(entries)
        return evidence.snapshot(observedAt: observedAt)
    }

    fileprivate static func tidalSinkFormat(from message: String) -> (sampleRate: Double, bitDepth: Int)? {
        guard let tidalSinkExpression,
              let values = captures(expression: tidalSinkExpression, in: message),
              let sampleRate = Double(values[0]),
              let bitDepth = Int(values[2]),
              isPlausibleSampleRate(sampleRate), (8...64).contains(bitDepth) else { return nil }
        return (sampleRate, bitDepth)
    }

    fileprivate static func tidalPlaybackActivity(from message: String) -> Bool? {
        // Media state takes precedence when a combined record includes both.
        if message.contains(#""signal": "media.state""#) {
            if message.contains(#""state": "active""#) { return true }
            if message.contains(#""state": "paused""#)
                || message.contains(#""state": "stopped""#)
                || message.contains(#""state": "completed""#) { return false }
        }
        if message.contains("CoreaudioSink::start") { return true }
        if message.contains("CoreaudioSink::close") { return false }
        return nil
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

public struct SourceRateMatchStabilityGate: Sendable {
    private struct Key: Equatable, Sendable {
        let player: SourcePlayer
        let sourceRate: Int
        let confidence: SourceFormatConfidence
        let targetRate: Int
        let currentDeviceRate: Int
    }

    public var minimumStableDuration: TimeInterval
    public var requiredObservationCount: Int
    private var candidate: Key?
    private var candidateSince: Date?
    private var observationCount = 0
    private var emitted: Key?

    public init(minimumStableDuration: TimeInterval = 1,
                requiredObservationCount: Int = 2) {
        self.minimumStableDuration = max(minimumStableDuration, 0)
        self.requiredObservationCount = max(requiredObservationCount, 1)
    }

    public mutating func reset() {
        candidate = nil
        candidateSince = nil
        observationCount = 0
        emitted = nil
    }

    /// Call only after the manager accepted/completed this proposed transition.
    /// A cooldown return or failed device request must not acknowledge it.
    public mutating func acknowledge(targetRate: Double) {
        guard targetRate.isFinite, let candidate,
              abs(Double(candidate.targetRate) - targetRate) <= 1 else { return }
        emitted = candidate
    }

    public mutating func observe(format: SourceAudioFormat?,
                                 currentDeviceRate: Double,
                                 supportedRates: [Double],
                                 isDeviceRateSettable: Bool,
                                 observedAt: Date) -> Double? {
        guard isDeviceRateSettable,
              currentDeviceRate.isFinite, currentDeviceRate >= 8_000,
              currentDeviceRate < Double(Int.max),
              let format,
              let sourceRate = format.sampleRate,
              format.hasUsableSampleRate,
              sourceRate < Double(Int.max),
              let targetRate = SourceRateMatchPolicy.bestRate(
                sourceRate: sourceRate,
                supportedRates: supportedRates
              ),
              targetRate < Double(Int.max),
              abs(targetRate - currentDeviceRate) > 1 else {
            reset()
            return nil
        }

        let key = Key(
            player: format.player,
            sourceRate: Int(sourceRate.rounded()),
            confidence: format.confidence,
            targetRate: Int(targetRate.rounded()),
            currentDeviceRate: Int(currentDeviceRate.rounded())
        )
        if candidate != key {
            candidate = key
            candidateSince = observedAt
            observationCount = 1
            return nil
        }

        observationCount += 1
        guard emitted != key,
              observationCount >= requiredObservationCount,
              observedAt.timeIntervalSince(candidateSince ?? observedAt) >= minimumStableDuration else {
            return nil
        }
        // This is a proposal, not a completed device operation. The manager
        // may defer it during cooldown; leave it eligible until acknowledged.
        return targetRate
    }
}

/// The real manager and offline checks share proposal, cooldown and ACK order.
/// Device work remains in the caller's closure, on its manager queue.
public struct SourceRateMatchCoordinator: Sendable {
    public enum Outcome: Equatable, Sendable {
        case waiting
        case coolingDown(remaining: TimeInterval)
        case deferred(targetRate: Double)
        case applied(targetRate: Double)
    }

    private var gate: SourceRateMatchStabilityGate
    public private(set) var cooldownUntil: Date = .distantPast
    public let cooldownInterval: TimeInterval

    public init(minimumStableDuration: TimeInterval = 1,
                requiredObservationCount: Int = 2,
                cooldownInterval: TimeInterval = 2) {
        gate = SourceRateMatchStabilityGate(minimumStableDuration: minimumStableDuration,
                                           requiredObservationCount: requiredObservationCount)
        self.cooldownInterval = max(0, cooldownInterval)
    }

    /// Source loss invalidates stability but does not cancel a device cooldown.
    public mutating func invalidateSource() { gate.reset() }

    /// Explicit session reset/re-enable also clears the prior cooldown.
    public mutating func reset() {
        gate.reset()
        cooldownUntil = .distantPast
    }

    public mutating func observe(format: SourceAudioFormat?, currentDeviceRate: Double,
                                 supportedRates: [Double], isDeviceRateSettable: Bool,
                                 now: () -> Date,
                                 performTransition: (Double) throws -> Bool) throws -> Outcome {
        let instant = now()
        guard let target = gate.observe(format: format, currentDeviceRate: currentDeviceRate,
                                        supportedRates: supportedRates,
                                        isDeviceRateSettable: isDeviceRateSettable,
                                        observedAt: instant) else { return .waiting }
        guard instant >= cooldownUntil else {
            return .coolingDown(remaining: cooldownUntil.timeIntervalSince(instant))
        }

        let previousCooldown = cooldownUntil
        cooldownUntil = instant.addingTimeInterval(cooldownInterval)
        // A thrown transition is not acknowledged. The caller may disable its
        // session; retaining the cooldown also prevents an immediate retry.
        guard try performTransition(target) else {
            cooldownUntil = previousCooldown
            return .deferred(targetRate: target)
        }
        gate.acknowledge(targetRate: target)
        return .applied(targetRate: target)
    }
}
