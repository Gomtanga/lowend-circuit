import Foundation
import LowEndSupport

/// Real SourceFormatTracker.poll/cache/cursor/FileHandle path with injected
/// process identity and time. Only this fixture's temporary player.log is read;
/// Unified Log, Music AppleScript and file watchers are explicitly disabled.
func runSourceFormatTrackerChecks() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message("Source tracker lifecycle: \(message)") }
    }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lowend-source-tracker-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logURL = directory.appendingPathComponent("player.log")
    let baseline = Date(timeIntervalSince1970: 1_800_000_000)
    let state = SourceFormatTrackerFixtureState(now: baseline,
        process: SourcePlayerProcess(processIdentifier: 111, launchDate: baseline))
    func log(_ rate: Int) -> String {
        "CoreaudioSink::open, rate: \(rate), type: int24\nCoreaudioSink::start\n"
    }
    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    try Data(log(96_000).utf8).write(to: logURL)
    let environment = SourceFormatTrackerEnvironment(
        runningApplication: { player in player == .tidal ? state.currentProcess() : nil },
        now: { state.currentDate() }, tidalPlayerLogURL: logURL, allowsSystemObservations: false)
    let tracker = SourceFormatTracker(onUpdate: { _ in }, environment: environment)
    defer { tracker.stop() }
    let historical = tracker.pollOnce()
    try require(historical.activePlayers == [.tidal] && historical.format == nil,
                "first poll promoted bytes predating observation")

    state.set(time: baseline.addingTimeInterval(1))
    try append(log(96_000))
    let firstStart = tracker.pollOnce()
    try require(firstStart.format?.sampleRate == 96_000 && firstStart.format?.bitDepth == 24,
                "new sink open/start did not enter the actual tracker cache")
    try require(firstStart.format?.evidence == .tidalPlayerLog,
                "temporary player.log did not supply the observed format")
    state.set(time: baseline.addingTimeInterval(2))
    let unchanged = tracker.pollOnce()
    try require(unchanged.format?.observedAt == firstStart.format?.observedAt,
                "polling unchanged bytes renewed playback evidence")

    // No stop/close log line: model an abnormal application exit while the
    // previous active evidence is still well inside its 15-second lifetime.
    state.set(time: baseline.addingTimeInterval(3), process: nil)
    let crashed = tracker.pollOnce()
    try require(crashed.activePlayers.isEmpty && crashed.formats.isEmpty && crashed.format == nil,
                "abnormal player exit retained a cached current format")
    state.set(time: baseline.addingTimeInterval(4),
              process: SourcePlayerProcess(processIdentifier: 222, launchDate: baseline.addingTimeInterval(4)))
    let relaunched = tracker.pollOnce()
    try require(relaunched.activePlayers == [.tidal] && relaunched.formats.isEmpty
                && relaunched.indicatorText.contains("unknown"),
                "relaunch against the same old log revived the prior session")
    state.set(time: baseline.addingTimeInterval(5))
    try require(tracker.pollOnce().format == nil, "unchanged old file was promoted on a later poll")
    try append("unrelated network heartbeat\nCoreaudioSink::start\n")
    try require(tracker.pollOnce().format == nil,
                "new start reused a sink format from the crashed process")

    state.set(time: baseline.addingTimeInterval(6))
    try append(log(48_000))
    let newStart = tracker.pollOnce()
    try require(newStart.format?.sampleRate == 48_000
                && newStart.format?.observedAt == baseline.addingTimeInterval(6),
                "fresh relaunch open/start did not establish its own format")
    state.set(time: baseline.addingTimeInterval(22))
    let stale = tracker.pollOnce()
    try require(stale.activePlayers == [.tidal] && stale.formats.isEmpty,
                "running process with expired log evidence kept a current format")
    print("Source format tracker lifecycle checks passed: real temp-file poll/cache, fresh start, crash without stop, unknown after relaunch with unchanged log, no old-format start promotion, fresh new format, stale expiry; system observations disabled.")
}

private final class SourceFormatTrackerFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    private var process: SourcePlayerProcess?
    init(now: Date, process: SourcePlayerProcess?) { self.now = now; self.process = process }
    func currentDate() -> Date { lock.lock(); defer { lock.unlock() }; return now }
    func currentProcess() -> SourcePlayerProcess? { lock.lock(); defer { lock.unlock() }; return process }
    func set(time: Date) { lock.lock(); defer { lock.unlock() }; now = time }
    func set(time: Date, process: SourcePlayerProcess?) {
        lock.lock(); defer { lock.unlock() }; now = time; self.process = process
    }
}
