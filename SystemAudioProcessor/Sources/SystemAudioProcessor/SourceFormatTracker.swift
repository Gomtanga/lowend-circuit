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
        }
    }

    private func poll() {
        let activePlayers = SourcePlayer.allCases.filter(Self.isPlayerRunning)
        let now = Date()

        if activePlayers.contains(.appleMusic) {
            if let logFormat = readUnifiedLog(player: .appleMusic)
                ?? readAppleMusicScriptFormat(observedAt: now) {
                cachedFormats[.appleMusic] = logFormat
            }
        } else {
            cachedFormats.removeValue(forKey: .appleMusic)
        }

        if activePlayers.contains(.tidal) {
            if let tidalFormat = readUnifiedLog(player: .tidal) {
                cachedFormats[.tidal] = tidalFormat
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

    private func readUnifiedLog(player: SourcePlayer) -> SourceAudioFormat? {
        do {
            guard let store = logStore else { return nil }
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

            let entries = try store.getEntries(at: position, matching: predicate)
                .compactMap { entry -> SourceFormatLogEntry? in
                    guard let log = entry as? OSLogEntryLog else { return nil }
                    return SourceFormatLogEntry(date: log.date, message: log.composedMessage)
                }
            switch player {
            case .appleMusic:
                return SourceFormatParser.parseAppleMusic(entries: entries)
            case .tidal:
                return SourceFormatParser.parseTIDAL(entries: entries)
            }
        } catch {
            return nil
        }
    }

    private func readAppleMusicScriptFormat(observedAt: Date) -> SourceAudioFormat? {
        let source = """
        tell application "Music"
            if player state is not playing then return "not-playing"
            set trackRate to sample rate of current track
            return trackRate as string
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error).stringValue
        guard error == nil,
              let result,
              let sampleRate = Double(result),
              sampleRate.isFinite,
              sampleRate >= 8_000 else {
            return nil
        }
        return SourceAudioFormat(
            player: .appleMusic,
            sampleRate: sampleRate,
            bitDepth: nil,
            confidence: .inferred,
            evidence: .appleScript,
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
