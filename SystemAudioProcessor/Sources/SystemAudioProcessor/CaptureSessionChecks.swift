import CoreAudio
import Foundation

struct CaptureStartFailureCheckObserver {
    let handle: (Error) -> Void
    let retainsProcessor: () -> Bool
    let hasPendingFailure: () -> Bool
    let stop: () -> Bool
}

/// The actual Start/Stop and route installer run against simulated devices.
/// File locks are real, but every fixture uses its own temporary directory.
@available(macOS 14.4, *)
enum CaptureSessionChecks {
    private final class TrackerIO: HardwareTrackerIO, @unchecked Sendable {
        let graph: GraphCheckIO
        init(_ graph: GraphCheckIO) { self.graph = graph }
        func defaultOutputDevice() throws -> AudioObjectID { 777 }
        func nominalRate(_ device: AudioObjectID) throws -> Double { try graph.nominalRate(device) }
        func setNominalRate(_ rate: Double, device: AudioObjectID) throws {
            try graph.setNominalRate(rate, device: device)
        }
        func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                         queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus { noErr }
        func removeListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                            queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus { noErr }
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lowend-lease-graph-\(UUID().uuidString)")
        let io = GraphCheckIO()
        let lease: CaptureSessionLease
        let competitor: CaptureSessionLease
        let access: SystemAudioProcessor.GraphCheckAccess
        init() throws {
            lease = CaptureSessionLease(testDirectory: directory)
            competitor = CaptureSessionLease(testDirectory: directory)
            access = try SystemAudioProcessor.GraphCheckAccess(io: io, captureSessionLease: lease)
            io.onPause = { [weak io, weak access] in
                guard let io, let access else { return }
                let state = access.state()
                io.capture(256)
                if io.outputIsRunning {
                    _ = access.consumeOutput(Int(256 * state.outputRate / max(state.tapRate, 1)))
                }
            }
        }
        func start() throws { try access.start(hardwareIO: TrackerIO(io)) }
        func close() {
            io.onCall = nil; io.onPause = nil
            io.failures = [:]; io.rejectRates = []
            _ = access.stop(); competitor.release()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    static func run(makeStartFailureObserver: (SystemAudioProcessor) -> CaptureStartFailureCheckObserver) throws {
        var assertions = 0, cases = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            assertions += 1
            guard condition() else { throw AppError.message("CaptureSessionChecks: \(label)") }
        }
        func fails(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        func blocked(_ fixture: Fixture) -> Bool {
            fails { try fixture.competitor.acquire() }
        }
        func record(_ name: String) { cases += 1; print("CaptureSessionChecks \(name): PASS") }

        do {
            let f = try Fixture(); defer { f.close() }
            try f.competitor.acquire()
            try expect(fails { try f.start() }, "occupied session rejects Start")
            try expect(f.io.trace.isEmpty && !f.lease.isHeld, "rejection precedes every platform graph call")
            try expect(f.access.stop() && f.competitor.isHeld, "nonowner Stop cannot release owner")
            f.competitor.release()
            try f.start()
            let creations = f.io.counts["createTap"]
            try f.start()
            try expect(f.io.counts["createTap"] == creations && f.lease.isHeld && blocked(f), "repeat Start preserves one graph/lease")
            try expect(f.access.stop() && !f.lease.isHeld, "normal Stop releases ownership")
            try f.competitor.acquire()
            try expect(f.competitor.isHeld, "next owner can acquire after Stop")
            record("contention-before-platform-repeat-start-normal-stop")
        }

        for operation in ["createTap", "createAggregate", "configureOutput", "startOutput", "startCapture"] {
            let f = try Fixture(); defer { f.close() }
            f.io.failures[operation] = [1]
            try expect(fails { try f.start() }, "\(operation) failure propagates")
            try expect(!f.lease.isHeld && f.io.taps.isEmpty && f.io.aggregates.isEmpty
                       && !f.io.outputIsRunning && !f.access.state().hasOutputSource, "cleaned start failure releases only after full teardown")
            try f.competitor.acquire()
            try expect(f.competitor.isHeld, "start failure admits next owner")
            record("start-failure-cleanup-\(operation)")
        }

        do {
            let f = try Fixture(); defer { f.close() }
            f.io.failures["startCapture"] = [1]
            f.io.failures["unregisterCapture"] = [1]
            try expect(fails { try f.start() }, "start cleanup failure propagates")
            try expect(f.lease.isHeld && blocked(f) && f.access.state().hasIOProc, "failed cleanup retains both handle and lease")
            let before = f.io.trace
            try expect(fails { try f.start() }, "pending cleanup prevents direct restart")
            try expect(f.io.trace == before, "direct restart does not retry cleanup implicitly")
            f.io.failures = [:]
            try expect(f.access.stop() && !f.lease.isHeld, "explicit cleanup retry releases lease")
            try f.competitor.acquire()
            record("start-cleanup-failure-explicit-retry")
        }

        do {
            let f = try Fixture(); defer { f.close() }
            f.io.failures["createAggregate"] = [1]
            f.io.failures["destroyTap"] = [1]
            try expect(fails { try f.start() }, "nested installer cleanup failure propagates")
            try expect(f.io.counts["destroyTap"] == 1 && f.lease.isHeld && blocked(f),
                       "outer Start does not silently retry failed nested teardown")
            try expect(f.access.stop() && !f.lease.isHeld, "explicit Stop owns nested cleanup retry")
            try f.competitor.acquire()
            record("nested-start-cleanup-failure-preserves-ownership")
        }

        do {
            let f = try Fixture(); defer { f.close() }
            let ui = f.access.makeStartFailureObserver(makeStartFailureObserver)
            f.io.failures["createAggregate"] = [1]
            f.io.failures["destroyTap"] = [1]
            var startupError: Error?
            do { try f.start() } catch { startupError = error }
            guard let startupError else { throw AppError.message("Expected nested startup failure for UI check") }
            ui.handle(startupError)
            try expect(f.io.counts["destroyTap"] == 1 && f.lease.isHeld && blocked(f),
                       "actual GUI error handler must not retry a failed teardown")
            try expect(ui.retainsProcessor() && ui.hasPendingFailure(), "GUI retains failed processor and pending status")
            try expect(ui.stop(), "explicit GUI Stop retries cleanup")
            try expect(!ui.retainsProcessor() && !ui.hasPendingFailure() && !f.lease.isHeld,
                       "successful explicit GUI Stop clears processor/status/lease")
            try f.competitor.acquire()
            record("actual-gui-start-error-preserves-failed-cleanup")
        }

        for operation in ["stopOutput", "unregisterCapture", "destroyAggregate", "destroyTap"] {
            let f = try Fixture(); defer { f.close() }
            try f.start()
            f.io.failures[operation] = [(f.io.counts[operation] ?? 0) + 1]
            try expect(!f.access.stop(), "\(operation) failure reports incomplete Stop")
            try expect(f.lease.isHeld && blocked(f), "incomplete Stop keeps next owner out")
            f.io.failures = [:]
            try expect(f.access.stop() && !f.lease.isHeld, "explicit Stop completes teardown and release")
            try f.competitor.acquire()
            record("stop-failure-retains-\(operation)")
        }

        do {
            let f = try Fixture(); defer { f.close() }
            try f.start()
            f.io.failures["stopCapture"] = [(f.io.counts["stopCapture"] ?? 0) + 1]
            try expect(f.access.stop() && !f.lease.isHeld && f.io.registeredDevice == nil,
                       "successful IOProc removal establishes teardown after Stop status error")
            try f.competitor.acquire()
            record("stop-status-error-with-confirmed-ioproc-removal")
        }

        do {
            let f = try Fixture(); defer { f.close() }
            try f.start()
            var attempts = 0, acquiredDuringGap = false
            f.io.onCall = { operation in
                if operation == "createTap" && f.io.taps.isEmpty {
                    attempts += 1
                    if !blocked(f) { acquiredDuringGap = true; f.competitor.release() }
                }
            }
            f.access.live2x(true)
            try expect(f.access.state().live2x && f.access.state().hardwareRate == 96_000, "actual Start enters live 2x")
            f.access.live2x(false)
            try f.access.transition(96_000)
            try expect(attempts >= 3 && !acquiredDuringGap && f.lease.isHeld,
                       "2x enable/disable and unity reconfigure retain ownership even with zero taps")
            f.io.onCall = nil
            try expect(f.access.stop(), "reconfigured session stops")
            try f.competitor.acquire()
            record("ownership-across-tapless-reconfiguration")
        }

        do {
            let f = try Fixture(); defer { f.close() }
            try f.start(); f.access.live2x(true)
            try expect(f.access.state().live2x, "restoration fixture activated live 2x")
            f.io.rejectRates = [48_000]
            try expect(!f.access.stop() && f.access.state().restoreRate == 48_000, "failed rate restoration stays pending")
            try expect(f.io.taps.isEmpty && f.io.aggregates.isEmpty && f.lease.isHeld && blocked(f),
                       "no tap does not imply ownership release while restoration remains")
            f.io.rejectRates = []
            try expect(f.access.stop() && !f.lease.isHeld, "confirmed restoration releases ownership")
            try f.competitor.acquire()
            record("stop-rate-restoration-retains-ownership")
        }

        do {
            // Fail before callbacks retain SAP, then fail every teardown. Its
            // deinit must hand the lock to process lifetime, never unlock it.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lowend-lease-orphan-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let lease = CaptureSessionLease(testDirectory: directory)
            let competitor = CaptureSessionLease(testDirectory: directory)
            let io = GraphCheckIO()
            io.failures["createAggregate"] = [1]
            io.failures["destroyTap"] = Set(1...32)
            var access: SystemAudioProcessor.GraphCheckAccess? = try .init(io: io, captureSessionLease: lease)
            try expect(fails { try access!.start(hardwareIO: TrackerIO(io)) }, "failed early Start retains orphaned tap")
            let attempts = io.counts["destroyTap"] ?? 0
            access = nil
            try expect((io.counts["destroyTap"] ?? 0) > attempts, "SAP deinit actually retried Stop")
            lease.release()
            try expect(lease.isHeld && fails { try competitor.acquire() }, "failed deinit retains lock through explicit release")
            record("failed-deinit-retains-until-process-exit")
        }

        do {
            typealias Compatibility = CaptureInstanceCompatibility
            let cases: [(Any?, Int?)] = [(nil, nil), (true, nil), ("1", nil),
                (1.5, nil), (NSNumber(value: 1), 1), (NSNumber(value: 0), 0), (NSNumber(value: -1), -1)]
            for (value, expected) in cases {
                try expect(Compatibility.leaseVersion(from: value) == expected, "only integer metadata declares support")
            }
            let snapshots: [Compatibility.Snapshot] = [
                .init(processIdentifier: 1, isTerminated: false, leaseVersion: nil),
                .init(processIdentifier: 2, isTerminated: true, leaseVersion: nil),
                .init(processIdentifier: 3, isTerminated: false, leaseVersion: 1),
                .init(processIdentifier: 4, isTerminated: false, leaseVersion: nil),
                .init(processIdentifier: 5, isTerminated: false, leaseVersion: 0),
                .init(processIdentifier: 0, isTerminated: false, leaseVersion: nil)]
            try expect(Compatibility.incompatibleInstances(in: snapshots, currentPID: 1).map(\.processIdentifier) == [4, 5],
                       "legacy live peers reject; own/terminated/cooperative/invalid peers do not")
            let launch = Date(timeIntervalSince1970: 100)
            for (info, executable, expected) in [(90.0, 90.0, true), (100, 100, true), (101, 90, false), (90, 101, false)] {
                try expect(Compatibility.metadataTimestampsPermitLeaseVersion(launchDate: launch,
                    infoModificationDate: Date(timeIntervalSince1970: info),
                    executableModificationDate: Date(timeIntervalSince1970: executable)) == expected,
                    "metadata/binary replacement after launch is incompatible")
            }
            try expect(!Compatibility.metadataTimestampsPermitLeaseVersion(launchDate: nil,
                infoModificationDate: launch, executableModificationDate: launch), "unknown launch fails closed")
            try expect(!Compatibility.metadataTimestampsPermitLeaseVersion(launchDate: launch,
                infoModificationDate: nil, executableModificationDate: launch), "unknown plist time fails closed")
            try expect(!Compatibility.metadataTimestampsPermitLeaseVersion(launchDate: launch,
                infoModificationDate: launch, executableModificationDate: nil), "unknown executable time fails closed")
            record("legacy-compatibility-without-app-enumeration")
        }

        print("CaptureSessionChecks: \(cases) integrated cases, \(assertions) assertions; actual SAP Start/Stop, isolated file locks, simulated devices; no physical capture")
    }
}
