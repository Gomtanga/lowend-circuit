import AppKit
import Foundation
import LowEndSupport
import OSLog

struct SourceFormatSnapshot: Sendable {
    let activePlayers: [SourcePlayer]
    let format: SourceAudioFormat?

    var indicatorText: String {
        if let format {
            return format.indicatorText
        }
        guard !activePlayers.isEmpty else {
            return "Source: Apple Music/TIDAL 대기 중"
        }
        return "Source \(activePlayers.map(\.displayName).joined(separator: " + ")): unknown"
    }
}

final class SourceFormatTracker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.codexaudiolab.lowendcircuit.source-format",
        qos: .utility
    )
    private let onUpdate: @Sendable (SourceFormatSnapshot) -> Void
    private var timer: DispatchSourceTimer?
    private var lastSnapshotText = ""
    private var cachedFormats: [SourcePlayer: SourceAudioFormat] = [:]
    private let cacheLifetime: TimeInterval = 15
    private lazy var logStore: OSLogStore? = try? OSLogStore.local()
    private let tidalPlayerLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TIDAL/player.log")
    private var lastAppleMusicPersistentID: String?
    private var lastAppleMusicState: AppleMusicPlaybackState = .notRunning
    private var acceleratedPollsRemaining: Int = 0

    init(onUpdate: @escaping @Sendable (SourceFormatSnapshot) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            cachedFormats.removeAll(keepingCapacity: true)
            lastAppleMusicPersistentID = nil
            lastAppleMusicState = .notRunning
            acceleratedPollsRemaining = 0
        }
    }

    private func poll() {
        let activePlayers = SourcePlayer.allCases.filter(Self.isPlayerRunning)
        let now = Date()

        if activePlayers.contains(.appleMusic) {
            let logEntries = readUnifiedLogEntries(player: .appleMusic)
            let scriptContext = readAppleMusicScriptContext(observedAt: now)
            let resolvedFormat = SourceFormatParser.resolveAppleMusicFormat(
                logEntries: logEntries,
                scriptContext: scriptContext
            )
            if let resolvedFormat {
                cachedFormats[.appleMusic] = resolvedFormat
            } else {
                cachedFormats.removeValue(forKey: .appleMusic)
            }

            let shouldAccelerate: Bool
            if scriptContext.state != lastAppleMusicState
                && scriptContext.state == .playing {
                shouldAccelerate = true
            } else if scriptContext.state == .playing
                        && scriptContext.persistentID != lastAppleMusicPersistentID {
                shouldAccelerate = true
            } else {
                shouldAccelerate = false
            }

            if shouldAccelerate && acceleratedPollsRemaining == 0 {
                acceleratedPollsRemaining = 4
                timer?.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
            }

            if acceleratedPollsRemaining > 0 {
                acceleratedPollsRemaining -= 1
                if acceleratedPollsRemaining == 0 {
                    timer?.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
                }
            }

            lastAppleMusicState = scriptContext.state
            lastAppleMusicPersistentID = scriptContext.persistentID
        } else {
            cachedFormats.removeValue(forKey: .appleMusic)
            lastAppleMusicState = .notRunning
            lastAppleMusicPersistentID = nil
        }

        if activePlayers.contains(.tidal) {
            switch readTIDALPlayerLog(observedAt: now) {
            case let .format(tidalFormat):
                cachedFormats[.tidal] = tidalFormat
            case .inactive:
                cachedFormats.removeValue(forKey: .tidal)
            case .unavailable:
                if let tidalFormat = readUnifiedLog(player: .tidal) {
                    cachedFormats[.tidal] = tidalFormat
                }
            }
        } else {
            cachedFormats.removeValue(forKey: .tidal)
        }

        cachedFormats = cachedFormats.filter {
            activePlayers.contains($0.key)
                && now.timeIntervalSince($0.value.observedAt) <= cacheLifetime
        }

        let bestFormat = cachedFormats.values.max { lhs, rhs in
            if lhs.observedAt != rhs.observedAt {
                return lhs.observedAt < rhs.observedAt
            }
            return lhs.confidence < rhs.confidence
        }
        let snapshot = SourceFormatSnapshot(activePlayers: activePlayers, format: bestFormat)
        guard snapshot.indicatorText != lastSnapshotText else { return }
        lastSnapshotText = snapshot.indicatorText
        onUpdate(snapshot)
    }

    private func readUnifiedLogEntries(player: SourcePlayer) -> [SourceFormatLogEntry] {
        do {
            guard let store = logStore else { return [] }
            let position = store.position(timeIntervalSinceEnd: -8)
            let predicate: NSPredicate
            switch player {
            case .appleMusic:
                predicate = NSPredicate(
                    format: "(process == %@) AND ((subsystem == %@) OR (subsystem == %@) OR (subsystem == %@))",
                    "Music",
                    "com.apple.coreaudio",
                    "com.apple.Music",
                    "com.apple.coremedia"
                )
            case .tidal:
                predicate = NSPredicate(
                    format: "(process CONTAINS[c] %@) OR (senderImagePath CONTAINS[c] %@)",
                    "TIDAL",
                    "TIDAL"
                )
            }

            return try store.getEntries(at: position, matching: predicate)
                .compactMap { entry -> SourceFormatLogEntry? in
                    guard let log = entry as? OSLogEntryLog else { return nil }
                    return SourceFormatLogEntry(date: log.date, message: log.composedMessage)
                }
        } catch {
            return []
        }
    }

    private func readUnifiedLog(player: SourcePlayer) -> SourceAudioFormat? {
        let entries = readUnifiedLogEntries(player: player)
        switch player {
        case .appleMusic:
            return SourceFormatParser.parseAppleMusic(entries: entries)
        case .tidal:
            return SourceFormatParser.parseTIDAL(entries: entries)
        }
    }

    private func readTIDALPlayerLog(observedAt: Date) -> TIDALPlayerLogResult {
        guard let handle = try? FileHandle(forReadingFrom: tidalPlayerLogURL) else {
            return .unavailable
        }
        defer { try? handle.close() }

        do {
            let fileSize = try handle.seekToEnd()
            let readSize = min(fileSize, 256 * 1_024)
            try handle.seek(toOffset: fileSize - readSize)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else {
                return .unavailable
            }

            let entries = text.split(separator: "\n").enumerated().map { index, line in
                SourceFormatLogEntry(
                    date: observedAt.addingTimeInterval(Double(index) * 0.000_001),
                    message: String(line)
                )
            }
            return SourceFormatParser.parseTIDALPlayerLogResult(
                entries: entries,
                observedAt: observedAt
            )
        } catch {
            return .unavailable
        }
    }

    private func readAppleMusicScriptContext(observedAt: Date) -> AppleMusicPlaybackContext {
        let source = """
        tell application "Music"
            set currentState to player state as string
            if currentState is not "playing" then
                return currentState & "|missing value|0"
            end if
            try
                set trackID to persistent ID of current track
                set trackRate to sample rate of current track
                return currentState & "|" & trackID & "|" & (trackRate as string)
            on error
                return currentState & "|unknown|0"
            end try
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return AppleMusicPlaybackContext(
                state: .notRunning, persistentID: nil, sampleRate: nil, observedAt: observedAt
            )
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error).stringValue
        guard error == nil, let result else {
            return AppleMusicPlaybackContext(
                state: .notRunning, persistentID: nil, sampleRate: nil, observedAt: observedAt
            )
        }

        let parts = result.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else {
            return AppleMusicPlaybackContext(
                state: .notRunning, persistentID: nil, sampleRate: nil, observedAt: observedAt
            )
        }

        let stateString = String(parts[0]).lowercased()
        let persistentID = String(parts[1])
        let sampleRateValue = Double(parts[2])

        let state: AppleMusicPlaybackState
        switch stateString {
        case "playing":
            state = .playing
        case "paused":
            state = .paused
        case "stopped":
            state = .stopped
        default:
            state = .notRunning
        }

        let sampleRate: Double? = sampleRateValue.flatMap { value in
            value.isFinite && value >= 8_000 ? value : nil
        }

        let resolvedPersistentID: String? = (persistentID == "missing value" || persistentID == "unknown")
            ? nil : persistentID

        return AppleMusicPlaybackContext(
            state: state,
            persistentID: resolvedPersistentID,
            sampleRate: sampleRate,
            observedAt: observedAt
        )
    }

    private static func isPlayerRunning(_ player: SourcePlayer) -> Bool {
        let bundleID: String
        switch player {
        case .appleMusic:
            bundleID = "com.apple.Music"
        case .tidal:
            bundleID = "com.tidal.desktop"
        }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
