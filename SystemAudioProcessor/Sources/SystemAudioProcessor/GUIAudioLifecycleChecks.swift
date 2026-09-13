import CoreAudio
import Foundation

@available(macOS 14.4, *)
final class GUIAudioWeakOwnerCheck: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storage: SystemAudioProcessor?
    func observe(_ processor: SystemAudioProcessor) {
        lock.lock(); defer { lock.unlock() }
        storage = processor
    }
    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage != nil
    }
}

/// Lock-protected observations are safe to inspect while the worker is gated.
/// GraphCheckIO's mutable dictionaries are inspected only after a barrier.
final class GUIAudioCheckJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(event)
    }
    func count(_ event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0 == event }.count
    }
}

final class GUIAudioCheckGate: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: String?
    private var hasEntered = false
    private let release = DispatchSemaphore(value: 0)
    let journal: GUIAudioCheckJournal
    init(journal: GUIAudioCheckJournal) { self.journal = journal }
    func arm(_ operation: String) {
        lock.lock(); defer { lock.unlock() }
        self.operation = operation
        hasEntered = false
    }
    var entered: Bool {
        lock.lock(); defer { lock.unlock() }
        return hasEntered
    }
    func visit(_ operation: String) {
        lock.lock()
        let holds = self.operation == operation && !hasEntered
        if holds { hasEntered = true }
        lock.unlock()
        guard holds else { return }
        if release.wait(timeout: .now() + 5) != .success { journal.record("gate-timeout") }
    }
    func open() { release.signal() }
}

@available(macOS 14.4, *)
final class GUIAudioLifecycleCheckFixture: @unchecked Sendable {
    private final class Tracker: HardwareTrackerIO, @unchecked Sendable {
        let io: GraphCheckIO
        init(_ io: GraphCheckIO) { self.io = io }
        func defaultOutputDevice() throws -> AudioObjectID { 777 }
        func nominalRate(_ device: AudioObjectID) throws -> Double { try io.nominalRate(device) }
        func setNominalRate(_ rate: Double, device: AudioObjectID) throws { try io.setNominalRate(rate, device: device) }
        func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                         queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus { noErr }
        func removeListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                            queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus { noErr }
    }
    let io = GraphCheckIO()
    let journal = GUIAudioCheckJournal()
    let gate: GUIAudioCheckGate
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lowend-gui-lifecycle-\(UUID().uuidString)")
    let lease: CaptureSessionLease
    let competitor: CaptureSessionLease
    let access: SystemAudioProcessor.GraphCheckAccess
    let processor: SystemAudioProcessor
    let rejectStop = RuntimeSnapshotBox(false)
    let failMake = RuntimeSnapshotBox(false)

    init() throws {
        gate = GUIAudioCheckGate(journal: journal)
        lease = CaptureSessionLease(testDirectory: directory)
        competitor = CaptureSessionLease(testDirectory: directory)
        access = try SystemAudioProcessor.GraphCheckAccess(io: io, captureSessionLease: lease)
        var created: SystemAudioProcessor?
        access.withProcessorForUICheck { created = $0 }
        processor = created!
        let journal = journal, gate = gate
        io.onCall = { operation in
            journal.record(operation)
            gate.visit(operation)
        }
        let io = io, access = access
        io.onPause = {
            let state = access.state()
            io.capture(256)
            if io.outputIsRunning { _ = access.consumeOutput(Int(256 * state.outputRate / max(state.tapRate, 1))) }
        }
    }

    var lifecycleIO: GUIAudioLifecycleIO {
        GUIAudioLifecycleIO(make: { [self] _ in
            journal.record(Thread.isMainThread ? "make-on-main" : "make-off-main")
            gate.visit("make")
            if failMake.load() { throw AppError.message("Injected GUI initialization failure") }
            return processor
        }, start: { [self] _ in
            journal.record(Thread.isMainThread ? "start-on-main" : "start-off-main")
            try access.start(hardwareIO: Tracker(io))
        }, stop: { [self] processor in
            journal.record(Thread.isMainThread ? "stop-on-main" : "stop-off-main")
            gate.visit("stop")
            if rejectStop.load() { return false }
            return processor.stop()
        })
    }

    func close() {
        gate.open()
        io.onCall = nil; io.onPause = nil; io.failures = [:]
        _ = access.stop()
        competitor.release()
        try? FileManager.default.removeItem(at: directory)
    }
}
