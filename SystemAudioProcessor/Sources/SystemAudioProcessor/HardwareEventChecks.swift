import AudioToolbox
import CoreAudio
import Foundation

/// Simulated property storage and registrations, not a substitute event policy.
/// The saved production blocks execute on the queues passed by the real tracker.
@available(macOS 14.4, *)
private final class HardwareEventCheckIO: HardwareTrackerIO, @unchecked Sendable {
    final class Registration: @unchecked Sendable {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let listener: AudioObjectPropertyListenerBlock
        init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
             _ queue: DispatchQueue, _ listener: @escaping AudioObjectPropertyListenerBlock) {
            self.object = object; self.address = address; self.queue = queue; self.listener = listener
        }
    }
    let graph: GraphCheckIO
    private let lock = NSLock()
    private var registrations: [Registration] = []
    private var operations: [String] = []
    private var pausedRead: (DispatchSemaphore, DispatchSemaphore)?
    init(_ graph: GraphCheckIO) { self.graph = graph }
    private func record(_ operation: String) {
        lock.lock(); operations.append(operation); lock.unlock()
    }
    var trace: [String] { lock.lock(); defer { lock.unlock() }; return operations }
    var active: [Registration] { lock.lock(); defer { lock.unlock() }; return registrations }
    func defaultOutputDevice() throws -> AudioObjectID {
        record("readDefault \(graph.defaultOutputDeviceID)")
        return graph.defaultOutputDeviceID
    }
    func nominalRate(_ device: AudioObjectID) throws -> Double {
        record("readNominal \(device)")
        guard let rate = graph.nominal[device] else { throw AppError.message("Unknown simulated tracker device") }
        lock.lock(); let pause = pausedRead; pausedRead = nil; lock.unlock()
        if let (entered, release) = pause {
            entered.signal()
            guard release.wait(timeout: .now() + 2) == .success else { throw AppError.message("Paused property read expired") }
        }
        return rate
    }
    func pauseNextRead(entered: DispatchSemaphore, release: DispatchSemaphore) {
        lock.lock(); pausedRead = (entered, release); lock.unlock()
    }
    func setNominalRate(_ rate: Double, device: AudioObjectID) throws {
        record("setNominal \(device) \(rate)")
        try graph.setNominalRate(rate, device: device)
    }
    func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                     queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        registrations.append(Registration(object, address, queue, listener))
        operations.append("add \(object) \(address.mSelector) queue=\(queue.label)")
        return noErr
    }
    func removeListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                        queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        registrations.removeAll { $0.object == object && $0.address.mSelector == address.mSelector }
        operations.append("remove \(object) \(address.mSelector)")
        return noErr
    }
    func registration(defaultOutput: Bool) throws -> Registration {
        let selector = defaultOutput ? kAudioHardwarePropertyDefaultOutputDevice : kAudioDevicePropertyNominalSampleRate
        guard let result = active.first(where: { $0.address.mSelector == selector }) else {
            throw AppError.message("Missing actual tracker registration")
        }
        return result
    }
    func enqueue(_ registration: Registration) -> DispatchSemaphore {
        let finished = DispatchSemaphore(value: 0)
        registration.queue.async {
            var address = registration.address
            withUnsafePointer(to: &address) { registration.listener(1, $0) }
            finished.signal()
        }
        return finished
    }
    func deliver(_ registration: Registration) throws {
        let finished = enqueue(registration)
        guard finished.wait(timeout: .now() + 2) == .success else {
            throw AppError.message("Tracker listener queue exceeded bounded wait")
        }
    }
}

@available(macOS 14.4, *)
enum HardwareEventChecks {
    private final class Fixture: @unchecked Sendable {
        let graph = GraphCheckIO()
        let io: HardwareEventCheckIO
        let access: SystemAudioProcessor.GraphCheckAccess
        let tracker: HardwareSampleRateTracker
        init() throws {
            io = HardwareEventCheckIO(graph)
            access = try SystemAudioProcessor.GraphCheckAccess(io: graph)
            try access.seed()
            tracker = try access.attachHardwareTracker(io)
            graph.onPause = { [weak self] in
                guard let self else { return }
                let state = self.access.state()
                self.graph.capture(256)
                _ = self.access.consumeOutput(Int(256 * state.outputRate / max(state.tapRate, 1)))
            }
        }
        func emit(defaultOutput: Bool = false) throws {
            try io.deliver(io.registration(defaultOutput: defaultOutput))
            access.managerBarrier()
        }
        func close() throws {
            graph.failures = [:]; graph.rejectRates = []; graph.forcedTapRate = nil; graph.onPause = nil
            guard access.stop() else { throw AppError.message("HardwareEventChecks Stop failed") }
            // Retain the stopped tracker solely to exercise already-queued blocks.
            // Calling stop again also cleans a before-fix canary's bad registration.
            tracker.stop()
            access.managerBarrier()
            guard io.active.isEmpty, graph.taps.isEmpty, graph.aggregates.isEmpty,
                  graph.registeredDevice == nil, graph.listeners.isEmpty, !graph.outputIsRunning else {
                throw AppError.message("HardwareEventChecks leaked simulated resources")
            }
        }
    }

    /// These execute the two suspected production bugs without stopping at the
    /// first bad observation, so the preserved before run records both boundaries.
    static func runFailureCanaries() throws {
        var failed: [String] = []
        try checkRetiredCallbacks { valid, name in if !valid { failed.append(name) } }
        try checkFailureBarrier { valid, name in if !valid { failed.append(name) } }
        guard failed.isEmpty else {
            throw AppError.message("HardwareEventChecks expected contracts failed: \(failed.joined(separator: ", "))")
        }
        print("HardwareEventChecks failure canaries: PASS")
    }

    private static func checkRetiredCallbacks(_ expect: (Bool, String) throws -> Void) throws {
        for defaultOutput in [true, false] {
            let f = try Fixture(); defer { try? f.close() }
            let queued = try f.io.registration(defaultOutput: defaultOutput)
            let confirmed = RateBox()
            if !defaultOutput {
                try f.tracker.requestRateChange(48_000, for: 777) { confirmed.set($0) }
            }
            try expect(f.access.stop(), "retired callback initial Stop")
            let original = f.access.state()
            if defaultOutput { f.graph.defaultOutputDeviceID = 888 }
            let reads = f.io.trace.count
            try f.io.deliver(queued)
            f.access.managerBarrier()
            let state = f.access.state()
            let newOperations = Array(f.io.trace.dropFirst(reads))
            print("HardwareEvent canary retired-\(defaultOutput ? "default" : "nominal"): operations=\(newOperations) registrations=\(f.io.active.count) output=\(state.outputDevice) confirmed=\(String(describing: confirmed.get()))")
            try expect(newOperations.isEmpty, "retired \(defaultOutput) callback performed external work")
            try expect(f.io.active.isEmpty, "retired callback reinstalled listener")
            try expect(state.outputDevice == original.outputDevice && state.resets == original.resets && !state.started,
                       "retired callback changed stopped processor")
            try expect(confirmed.get() == nil, "retired callback consumed confirmation")
            try f.close()
        }
        do {
            let f = try Fixture(); defer { try? f.close() }
            let oldNominal = try f.io.registration(defaultOutput: false)
            let oldDefault = try f.io.registration(defaultOutput: true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            f.io.pauseNextRead(entered: entered, release: release)
            let finished = f.io.enqueue(oldNominal)
            guard entered.wait(timeout: .now() + 1) == .success else { throw AppError.message("Nominal read did not pause") }
            defer { release.signal() }
            try expect(f.access.stop(), "read-in-flight Stop")
            try f.access.restartHardwareTracker(f.tracker)
            let confirmed = RateBox()
            try f.tracker.requestRateChange(96_000, for: 777) { confirmed.set($0) }
            release.signal()
            guard finished.wait(timeout: .now() + 1) == .success else { throw AppError.message("Old nominal read did not finish") }
            f.access.managerBarrier()
            print("HardwareEvent canary read-in-flight restart: registrations=\(f.io.active.count) oldReadConsumedNewConfirmation=\(String(describing: confirmed.get()))")
            try expect(confirmed.get() == nil, "old same-device read consumed new session confirmation")
            try expect(f.io.active.count == 2, "same-device tracker restart has both listeners")
            let operations = f.io.trace.count
            try f.io.deliver(oldDefault); f.access.managerBarrier()
            try expect(f.io.trace.count == operations, "retired default callback entered restarted session")
            if let current = f.io.active.first(where: { $0.address.mSelector == kAudioDevicePropertyNominalSampleRate }) {
                try f.io.deliver(current); f.access.managerBarrier()
                try expect(confirmed.get() == 96_000, "current registration confirms current request")
            } else { try expect(false, "current nominal listener exists") }
            try f.close()
        }
    }

    private static func checkFailureBarrier(_ expect: (Bool, String) throws -> Void) throws {
        for nested in [false, true] {
            let f = try Fixture(); defer { try? f.close() }
            let initial = f.access.state()
            f.graph.failures["unregisterCapture"] = [nested ? 2 : 1]
            if nested { f.graph.failures["startCapture"] = [2] }
            f.graph.nominal[777] = 96_000
            try f.emit()
            let state = f.access.state()
            let unregisters = f.graph.counts["unregisterCapture"] ?? 0
            print("HardwareEvent canary barrier nested=\(nested): unregisters=\(unregisters) resets=\(state.resets) started=\(state.started) tap=\(state.tap) aggregate=\(state.aggregate) ioProc=\(state.hasIOProc)")
            try expect(unregisters == (nested ? 2 : 1), "hardware caller retried failed teardown")
            try expect(state.resets == initial.resets + (nested ? 1 : 0), "hardware caller reset after failed barrier")
            try expect(!state.started && !state.outputRunning && state.hasIOProc && state.aggregate != kAudioObjectUnknown,
                       "hardware caller discarded failed graph ownership")
            try expect(f.graph.counts["createTap"] == (nested ? 2 : 1), "hardware caller reinstalled after failure")
            if !nested { try expect(state.tap == initial.tap && state.aggregate == initial.aggregate, "initial barrier changed handles") }
            try f.close()
        }
        do {
            let f = try Fixture(); defer { try? f.close() }
            f.access.live2x(true)
            let initial = f.access.state()
            guard initial.live2x, let listener = f.access.currentTapListener() else {
                throw AppError.message("Missing actual live2x tap registration")
            }
            let unregisters = f.graph.counts["unregisterCapture"] ?? 0
            let creates = f.graph.counts["createTap"]
            f.graph.failures["unregisterCapture"] = [unregisters + 1]
            f.graph.forcedTapRate = 44_100
            f.access.deliver(listener)
            let state = f.access.state()
            print("HardwareEvent canary live2x-tap-deactivation: unregisterDelta=\((f.graph.counts["unregisterCapture"] ?? 0) - unregisters) resetDelta=\(state.resets - initial.resets) aggregate=\(state.aggregate) ioProc=\(state.hasIOProc) restore=\(String(describing: state.restoreRate))")
            try expect(f.graph.counts["unregisterCapture"] == unregisters + 1, "tap deactivation caller retried failed barrier")
            try expect(state.resets == initial.resets, "tap deactivation reset preserved graph")
            try expect(!state.started && state.hasIOProc && state.aggregate == initial.aggregate && state.tap == initial.tap,
                       "tap deactivation lost preserved graph handles")
            try expect(state.restoreRate == 48_000, "tap deactivation lost original restore target")
            try expect(f.graph.counts["createTap"] == creates, "tap deactivation reinstalled after failed barrier")
            try f.close()
        }
    }

    @MainActor
    static func run() throws {
        var assertions = 0
        var groups = 0
        var traces: [String] = []
        func expect(_ valid: Bool, _ name: String) throws {
            assertions += 1
            guard valid else { throw AppError.message("HardwareEventChecks: \(name)") }
        }
        func finish(_ name: String, _ fixture: Fixture) throws {
            let state = fixture.access.state()
            try fixture.close()
            groups += 1
            let line = "HardwareEvent group \(name): PASS device=\(state.outputDevice) tap=\(state.tapRate) output=\(state.outputRate) resets=\(state.resets) finalStop=true resources=0"
            print(line); traces.append(line); traces += fixture.graph.trace; traces += fixture.io.trace
        }
        func checkEpoch(_ f: Fixture, device: AudioObjectID, tap: Double, output: Double) throws {
            let before = f.access.state()
            try expect(before.started && before.outputRunning && before.hasIOProc, "actual graph active")
            try expect(before.outputDevice == device && before.tapRate == tap && before.outputRate == output
                       && before.hardwareRate == output && f.graph.nominal[device] == output, "actual epoch device/rates agree")
            f.graph.capture(257)
            let after = f.access.state()
            let frames = Int(257 * output / tap)
            try expect(after.written - before.written == UInt64(frames * 2), "actual input/conditioning frame ratio")
            let samples = f.access.consumeOutput(frames)
            try expect(samples.count == frames * 2 && samples.allSatisfy(\.isFinite), "actual ring output finite")
        }

        do {
            let f = try Fixture(); defer { try? f.close() }
            let before = f.access.state(); let creates = f.graph.counts["createTap"]
            try f.emit(); try f.emit(defaultOutput: true)
            try expect(f.access.state().resets == before.resets && f.graph.counts["createTap"] == creates,
                       "identical actual nominal/default notifications do not rebuild")
            try checkEpoch(f, device: 777, tap: 48_000, output: 48_000)
            try finish("unchanged", f)
        }
        do {
            let f = try Fixture(); defer { try? f.close() }
            try checkEpoch(f, device: 777, tap: 48_000, output: 48_000)
            f.graph.nominal[777] = 96_000; try f.emit()
            try checkEpoch(f, device: 777, tap: 96_000, output: 96_000)
            try expect(f.access.state().resets == 1, "external rate rebuild exactly once")
            try finish("external-rate", f)
        }
        do {
            let f = try Fixture(); defer { try? f.close() }
            var settings = SpatialSettings(); settings.enabled = true; settings.listenerX = 1.375; settings.amount = 63
            let revision = f.access.submit(settings)
            f.access.live2x(true)
            try checkEpoch(f, device: 777, tap: 48_000, output: 96_000)
            let before = f.access.state()
            try expect(before.live2x && before.restoreRate == 48_000, "old device has active split and restore target")
            f.graph.defaultOutputDeviceID = 888; try f.emit(defaultOutput: true)
            try checkEpoch(f, device: 888, tap: 44_100, output: 44_100)
            let state = f.access.state()
            try expect(!state.live2x && state.restoreRate == nil && state.automaticRestoreRate == nil,
                       "device replacement retires split and old restore targets")
            try expect(state.appliedRevision == revision, "latest Spatial revision applied at new epoch")
            let domain = "lowend.hardware-preview.\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: domain)!
            defer { preferences.removePersistentDomain(forName: domain) }
            let model = SpatialControlModel(preferences: preferences)
            model.processingSampleRate = Float(state.tapRate)
            model.mutate(final: true) { $0 = settings }
            guard let preview = model.preview else { throw AppError.message("Missing actual preview") }
            let spatial = Mirror(reflecting: f.access.spatialState())
            guard let target = spatial.children.first(where: { $0.label == "target" })?.value else {
                throw AppError.message("Missing actual applied Spatial storage")
            }
            let targetMirror = Mirror(reflecting: target)
            for (name, expected) in [("ll", preview.raw.settings.ll), ("lr", preview.raw.settings.lr),
                                     ("rl", preview.raw.settings.rl), ("rr", preview.raw.settings.rr)] {
                guard let path = targetMirror.children.first(where: { $0.label == name })?.value else {
                    throw AppError.message("Missing applied Spatial path")
                }
                let stored = Mirror(reflecting: path)
                try expect(stored.children.first(where: { $0.label == "delay" })?.value as? Int == Int(expected.delaySamples)
                           && stored.children.first(where: { $0.label == "gain" })?.value as? Float == expected.gain,
                           "device replacement actual \(name) precompute matches 44.1k preview")
            }
            try expect(f.io.active.count == 2 && f.io.active.contains(where: { $0.object == 888 })
                       && !f.io.active.contains(where: { $0.object == 777 }), "old nominal registration retired")
            let requests = f.graph.rateRequests.count
            try finish("device-replacement-from-2x", f)
            try expect(f.graph.rateRequests.count == requests && f.graph.nominal[777] == 96_000,
                       "Stop does not restore old device target onto replacement")
        }
        do {
            let f = try Fixture(); defer { try? f.close() }
            let old = try f.io.registration(defaultOutput: false)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            f.access.stallManager(entered: entered, release: release)
            guard entered.wait(timeout: .now() + 1) == .success else { throw AppError.message("Manager stall did not start") }
            f.graph.nominal[777] = 96_000
            do { try f.io.deliver(old) } catch { release.signal(); throw error }
            f.graph.nominal[777] = 44_100
            release.signal(); f.access.managerBarrier()
            try checkEpoch(f, device: 777, tap: 44_100, output: 44_100)
            try expect(f.graph.counts["createTap"] == 2, "delayed 96k notification did not install obsolete epoch")
            f.graph.defaultOutputDeviceID = 888; try f.emit(defaultOutput: true)
            let reads = f.io.trace.count, resets = f.access.state().resets
            try f.io.deliver(old); f.access.managerBarrier()
            try expect(f.io.trace.count == reads && f.access.state().resets == resets, "retired old-device callback does no work")
            try checkEpoch(f, device: 888, tap: 44_100, output: 44_100)
            try finish("late-and-old-device-delivery", f)
        }
        try checkRetiredCallbacks(expect)
        groups += 1; print("HardwareEvent group retired-callbacks: PASS finalStop=true resources=0")
        try checkFailureBarrier(expect)
        groups += 1; print("HardwareEvent group failed-barrier: PASS finalStop=true resources=0")
        if let path = ProcessInfo.processInfo.environment["LOWEND_HARDWARE_TRACE"] {
            try traces.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("HardwareEventChecks: \(groups) integrated groups, \(assertions) assertions; actual tracker/listener queues/SAP hardware handler/input/conditioning; simulated property APIs and output schedule; no physical device calls")
    }
}
