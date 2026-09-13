import AudioRingBufferC
import Foundation

private final class CallbackOwnerProbe {
    let destruction: RuntimeSnapshotBox<(count: Int, reentrant: Bool)>
    let insideStop: RuntimeSnapshotBox<Bool>
    var registration: AudioCallbackLifetime?
    init(_ destruction: RuntimeSnapshotBox<(count: Int, reentrant: Bool)>, _ insideStop: RuntimeSnapshotBox<Bool>) {
        self.destruction = destruction; self.insideStop = insideStop
    }
    deinit { destruction.store((1, insideStop.load())) }
}

private final class WeakCallbackOwnerProbe {
    weak var owner: CallbackOwnerProbe?
    init(_ owner: CallbackOwnerProbe?) { self.owner = owner }
}

/// Runs without creating a device, tap, IOProc or AVAudioEngine. The exact
/// production gate ownership and OSStatus adapter are exercised directly.
func runAudioCallbackLifetimeChecks() throws {
    var assertions = 0
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw AppError.message("Callback lifetime check: \(message)") }
    }
    let manager = DispatchQueue(label: "lowend.test.callback-owner")
    let destruction = RuntimeSnapshotBox((count: 0, reentrant: false))
    let insideStop = RuntimeSnapshotBox(false)
    var owner: CallbackOwnerProbe? = CallbackOwnerProbe(destruction, insideStop)
    let weakOwner = WeakCallbackOwnerProbe(owner)
    let lifetime = try AudioCallbackLifetime(retaining: owner!)
    owner!.registration = lifetime // Exercise the production registration cycle.
    owner = nil
    try require(weakOwner.owner != nil, "registration must retain callback userdata")
    try require(lc_callback_gate_try_enter(lifetime.handle) != nil, "active callback entry")
    lifetime.disable()
    var timedOut = false
    do { try lifetime.waitForQuiescence(timeout: 0) }
    catch { timedOut = true }
    try require(timedOut, "held callback was incorrectly quiescent")
    try require(weakOwner.owner != nil && destruction.load().count == 0, "timeout freed an admitted callback's owner")
    lc_callback_gate_leave(lifetime.handle)
    try lifetime.waitForQuiescence()
    try manager.sync {
        insideStop.store(true)
        lifetime.releaseOwnerAfterQuiescence(on: manager)
        try require(weakOwner.owner != nil, "owner release reentered Stop")
        insideStop.store(false)
    }
    manager.sync {}
    try require(weakOwner.owner == nil && destruction.load().count == 1, "successful stop leaked the registration cycle")
    try require(!destruction.load().reentrant, "owner deinit ran inside Stop")
    // The registration has not been removed: callback source failure leaves a
    // valid tombstone after the owner is gone. No userdata may be returned.
    for _ in 0..<1_024 {
        try require(lc_callback_gate_try_enter(lifetime.handle) == nil, "late callback acquired freed userdata")
    }
    lifetime.markSourceRemoved()

    // Actual adapter: failed Stop plus successful IOProc removal is safe, and
    // the nonzero Stop result remains available to production diagnostics.
    var ioPresent = true
    let stopResult = try AudioTeardownAdapter.unregisterIOProc(stop: { -7 }, destroy: { 0 }, didUnregister: { ioPresent = false })
    try require(stopResult == -7 && !ioPresent, "successful IOProc removal must settle a failed Stop")

    // Inject failure at every real destroy boundary. Earlier successes commit;
    // the failed and later handles remain available to the next Stop attempt.
    for failedPhase in ["io", "aggregate", "listener", "tap"] {
        var handles: Set<String> = ["io", "aggregate", "listener", "tap"]
        var attempts: [String] = []
        var fail = true
        func teardown() throws {
            if handles.contains("io") {
                try AudioTeardownAdapter.unregisterIOProc(stop: { attempts.append("stop"); return -8 },
                    destroy: { attempts.append("io"); return fail && failedPhase == "io" ? -1 : 0 },
                    didUnregister: { handles.remove("io") })
            }
            for phase in ["aggregate", "listener", "tap"] where handles.contains(phase) {
                try AudioTeardownAdapter.destroy(phase,
                    call: { attempts.append(phase); return fail && failedPhase == phase ? -1 : 0 },
                    didDestroy: { handles.remove(phase) })
            }
        }
        var resetOrInstall = false
        do {
            try AudioGraphTransition.run(.init(fadeOut: {}, quiesce: { try teardown() },
                installTarget: { resetOrInstall = true }, installRollback: { resetOrInstall = true }, verifyFlow: {}, fadeIn: {}))
            throw AppError.message("Teardown failure was ignored")
        } catch let failure as AudioGraphTransitionFailure {
            try require(!failure.recovered && !resetOrInstall, "failed teardown permitted reset/reinstall")
        }
        try require(handles.contains(failedPhase), "failed handle was forgotten")
        try require(attempts.filter { $0 == failedPhase }.count == 1, "quiesce failure was retried implicitly")
        fail = false
        try teardown()
        try require(handles.isEmpty, "second Stop could not finish preserved teardown")
    }

    // A late install failure must also stop at the rollback teardown barrier.
    var quiesceCalls = 0, rollbackInstalled = false
    do {
        try AudioGraphTransition.run(.init(fadeOut: {}, quiesce: {
            quiesceCalls += 1
            if quiesceCalls == 2 { throw AudioTeardownFailure(operation: "IOProc", status: -1) }
        }, installTarget: {}, installRollback: { rollbackInstalled = true },
            verifyFlow: { throw AppError.message("flow") }, fadeIn: {}))
        throw AppError.message("Late cleanup failure was ignored")
    } catch let failure as AudioGraphTransitionFailure {
        try require(!failure.recovered && !rollbackInstalled, "rollback installed before failed target teardown")
    }

    // These policies are shared by initial start/normal restart and Stop, so a
    // route rejected here is rejected before either callback is started.
    for route in [(48_000.0, 96_000.0), (44_100, 48_000), (.nan, 48_000)] {
        var installed = false
        do {
            try AudioLifecyclePolicy.validateUnityRoute(captureRate: route.0, outputRate: route.1)
            installed = true
        } catch {}
        try require(!installed, "initial unity route admitted mismatched capture/output rates")
    }
    try AudioLifecyclePolicy.validateUnityRoute(captureRate: 48_000, outputRate: 48_000)
    for isAutomatic in [true, false] {
        var pendingRate: Double? = 48_000
        var attemptCount = 0
        func attemptStopRestore() throws {
            guard AudioLifecyclePolicy.needsStop(hasResources: false,
                automaticRestoreRate: isAutomatic ? pendingRate : nil,
                liveRestoreRate: isAutomatic ? nil : pendingRate), let rate = pendingRate else { return }
            try AudioLifecyclePolicy.restoreRate(rate, apply: {
                attemptCount += 1
                if attemptCount == 1 { throw AppError.message("injected hardware restoration failure") }
                return rate
            }, didRestore: { pendingRate = nil })
        }
        do { try attemptStopRestore() } catch {}
        try require(pendingRate == 48_000 && attemptCount == 1, "failed restore lost its pending rate")
        try attemptStopRestore()
        try require(pendingRate == nil && attemptCount == 2, "second Stop did not retry restoration without graph resources")
    }

    // The production settings entry gate must not interpret a stopped graph's
    // pending restoration as a request to deactivate/rebuild live PCM 2x.
    for pendingAutomatic in [false, true] {
        for pendingLive in [false, true] {
            var automaticRestore: Double? = pendingAutomatic ? 44_100 : nil
            var liveRestore: Double? = pendingLive ? 48_000 : nil
            var deviceCalls = 0, graphCalls = 0, controlPackets = 0
            let beforeAutomatic = automaticRestore, beforeLive = liveRestore
            for _ in 0..<3 { // output conditioning, automatic-rate switch, tonal settings
                let accepted = AudioLifecyclePolicy.withRunningProcessor(isStarted: false) {
                    deviceCalls += 1; graphCalls += 1; controlPackets += 1
                    automaticRestore = nil; liveRestore = nil
                }
                try require(!accepted, "stopped settings must be rejected")
            }
            try require(deviceCalls == 0 && graphCalls == 0 && controlPackets == 0,
                        "stopped settings called a device/graph/control operation")
            try require(automaticRestore == beforeAutomatic && liveRestore == beforeLive,
                        "stopped settings consumed pending restoration snapshots")
        }
    }
    var runningCalls = 0
    let acceptedAfterStart = AudioLifecyclePolicy.withRunningProcessor(isStarted: true) { runningCalls += 1 }
    try require(acceptedAfterStart && runningCalls == 1, "fresh running graph must accept settings")
    print("Callback lifetime checks passed (\(assertions) assertions: retained owner, deferred deinit, disabled tombstone, teardown status failures and retry)")
}
