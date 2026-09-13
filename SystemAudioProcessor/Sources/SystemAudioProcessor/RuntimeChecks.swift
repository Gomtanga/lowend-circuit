import AudioRingBufferC
import Foundation

func runRuntimeChecks() throws {
    try runAudioCallbackLifetimeChecks()
    try runTapFormatEventChecks()
    try runPrecomputedConditioningGainChecks()
    try runSpatialDryBoundaryChecks()
    var assertions = 0
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw AppError.message("Runtime check failed: \(message)") }
    }

    for capacity in [2, 32, Spatializer.delayCapacity] {
        for delay in [0, 1, capacity - 1] {
            let line = DelayLine(capacity: capacity)
            for frame in 0..<(capacity + 2) {
                let output = line.process(frame == 0 ? 1 : 0, delaySamples: delay)
                try require(output == (frame == delay ? 1 : 0), "delay impulse capacity=\(capacity), delay=\(delay), frame=\(frame)")
            }
        }
    }

    let rates: [Float] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000]
    for rate in rates {
        for position: (Float, Float, Float) in [(0, 0, 1.65), (-3, 1.75, 3), (3, 2.8, 0.6)] {
            let settings = SpatialSettings(enabled: true, listenerX: position.0, listenerZ: position.1, speakerWidth: position.2, amount: 100)
            guard let geometry = SpatialGeometrySnapshot.make(sampleRate: rate, settings: settings) else {
                throw AppError.message("Valid geometry was rejected")
            }
            let paths = [geometry.raw.ll, geometry.raw.lr, geometry.raw.rl, geometry.raw.rr]
            for path in paths {
                try require(path.requestedDelaySamples == path.appliedDelaySamples, "supported geometry must not truncate its delay")
                try require(path.appliedDelaySamples < UInt32(Spatializer.delayCapacity), "delay capacity")
                try require(abs(path.appliedDelayMs - Float(path.appliedDelaySamples) * 1_000 / rate) < 0.0001, "preview samples/ms")
            }
            // Observe all four paths in the actual Swift spatial audio processor.
            // At amount=1, there is no dry impulse to hide a wrong arrival index.
            for source in 0..<2 {
                let spatial = Spatializer(settings: geometry.raw.settings)
                let expectedLeft = source == 0 ? geometry.raw.ll : geometry.raw.rl
                let expectedRight = source == 0 ? geometry.raw.lr : geometry.raw.rr
                for frame in 0..<Spatializer.delayCapacity {
                    let impulse: Float = frame == 0 ? 0.1 : 0
                    let actual = spatial.process(left: source == 0 ? impulse : 0, right: source == 1 ? impulse : 0)
                    let left: Float = frame == Int(expectedLeft.appliedDelaySamples) ? tanh(0.1 * expectedLeft.gain * 0.82 * 1.02) / 1.02 : 0
                    let right: Float = frame == Int(expectedRight.appliedDelaySamples) ? tanh(0.1 * expectedRight.gain * 0.82 * 1.02) / 1.02 : 0
                    try require(abs(actual.0 - left) < 0.000001 && abs(actual.1 - right) < 0.000001, "actual impulse differs from preview at \(rate) Hz, frame \(frame)")
                }
            }
        }
    }
    try require(SpatialGeometrySnapshot.make(sampleRate: .nan, settings: SpatialSettings()) == nil, "NaN rate rejected")
    try require(SpatialGeometrySnapshot.make(sampleRate: 768_001, settings: SpatialSettings()) == nil, "unsupported rate rejected")
    var nonfinite = SpatialSettings(); nonfinite.listenerX = .infinity
    try require(SpatialGeometrySnapshot.make(sampleRate: 48_000, settings: nonfinite) == nil, "infinite position rejected")

    var packet = LCSpatialSettings(enabled: 0, amount: 1,
        ll: LCSpatialPathSettings(delaySamples: 12, gain: 1),
        lr: LCSpatialPathSettings(delaySamples: 12, gain: 0),
        rl: LCSpatialPathSettings(delaySamples: 12, gain: 0),
        rr: LCSpatialPathSettings(delaySamples: 12, gain: 1))
    let bypass = Spatializer(settings: packet)
    for frame in 0..<30 {
        let value: Float = frame == 29 ? 0.3 : -0.4
        let result = bypass.process(left: value, right: -value)
        try require(result.0 == value && result.1 == -value, "initial bypass must be exact")
    }
    packet.enabled = 1
    bypass.update(packet)
    var arrival: Float = 0
    for frame in 0..<12 { arrival = bypass.process(left: 0, right: 0).0; if frame == 11 { try require(arrival > 0, "bypass must retain recent history") } }
    for _ in 0..<Spatializer.transitionFrames { _ = bypass.process(left: 0.3, right: -0.3) }
    packet.enabled = 0; bypass.update(packet)
    for _ in 0..<Spatializer.transitionFrames { _ = bypass.process(left: 0.3, right: -0.3) }
    let settled = bypass.process(left: 1.25, right: -1.25)
    try require(settled.0 == 1.25 && settled.1 == -1.25, "settled off must be exact, including signals above full scale")
    for _ in 0..<(Spatializer.delayCapacity + 30) { _ = bypass.process(left: 0, right: 0) }
    packet.enabled = 1; bypass.update(packet)
    for _ in 0..<64 {
        let result = bypass.process(left: 0, right: 0)
        try require(result.0 == 0 && result.1 == 0, "reenable must not replay a stale tail")
    }

    packet.enabled = 1; packet.ll.delaySamples = 0; packet.rr.delaySamples = 0
    let moving = Spatializer(settings: packet)
    for _ in 0..<128 { _ = moving.process(left: 0.3, right: -0.3) }
    var previous = moving.process(left: 0.3, right: -0.3).0
    for frame in 0..<1_024 {
        if frame % 40 == 0 {
            packet.ll.delaySamples = UInt32(frame % 80)
            packet.ll.gain = frame % 80 == 0 ? 0.2 : 1.5
            moving.update(packet)
        }
        let value = moving.process(left: 0.3, right: -0.3).0
        try require(value.isFinite && abs(value - previous) < 0.01, "rapid retarget continuity")
        previous = value
    }

    let queue = try LockFreeControlEventQueue(capacity: 16, sampleRate: 768_000)
    var finalSettings = SpatialSettings(enabled: true, listenerX: -3, listenerZ: 1.75, speakerWidth: 3, amount: 75)
    for revision in 1...20_000 {
        finalSettings.listenerX = revision == 20_000 ? 2.4 : Float(revision % 7) - 3
        queue.pushSpatial(finalSettings, revision: UInt64(revision))
    }
    var event = LCControlEvent()
    var finalPacket: LCSpatialSettings?
    var blocks = 0
    while queue.appliedSpatialRevision < 20_000 && blocks < 10 {
        var drained = 0
        for _ in 0..<LockFreeControlEventQueue.callbackDrainBudget {
            guard queue.pop(into: &event) else { break }
            drained += 1
            if event.type == UInt32(LC_CONTROL_EVENT_SPATIAL) {
                finalPacket = event.spatial
                queue.acknowledgeSpatial(event.revision)
            }
        }
        try require(drained <= 8, "callback drain bound")
        queue.flushPending()
        blocks += 1
    }
    let expected = DSPPrecompute.makeSpatialSettings(sampleRate: 768_000, settings: finalSettings)
    try require(queue.appliedSpatialRevision == 20_000, "full queue lost final spatial revision")
    try require(finalPacket?.ll.delaySamples == expected.ll.delaySamples && finalPacket?.ll.gain == expected.ll.gain, "final applied packet differs")

    // A stopped session may still have UI events queued. Rebuild must discard
    // those old-rate events before directly applying the newest submission.
    queue.pushSpatial(SpatialSettings(), revision: 20_001)
    queue.pushSpatial(SpatialSettings(), revision: 20_002)
    queue.updateSampleRate(48_000)
    queue.acknowledgeSpatial(20_100)
    try require(!queue.pop(into: &event), "restart retained an event that can overwrite the newest direct settings")
    queue.flushPending()
    try require(!queue.pop(into: &event) && queue.appliedSpatialRevision == 20_100, "restart retained old-rate pending settings")

    let hardwareToken = HardwareObservationToken()
    var deliveryRate: Double?
    var actualRate = 44_100.0
    let delayedDelivery = {
        HardwareObservationDelivery.deliver(deviceID: 7, token: hardwareToken,
            currentDevice: { 7 }, currentRate: { actualRate }, onChange: { _, rate in deliveryRate = rate })
    }
    actualRate = 96_000 // target notification was produced here
    actualRate = 44_100 // rollback finishes before the manager consumes it
    delayedDelivery()
    try require(deliveryRate == 44_100, "queued target notification overrode completed rollback")
    deliveryRate = nil
    HardwareObservationDelivery.deliver(deviceID: 7, token: hardwareToken,
        currentDevice: { 8 }, currentRate: { 96_000 }, onChange: { _, rate in deliveryRate = rate })
    try require(deliveryRate == nil, "notification for previous device was delivered")
    hardwareToken.invalidate()
    delayedDelivery()
    try require(deliveryRate == nil, "notification was delivered after tracker stop")

    let submissions = SpatialSubmissionBox(SpatialSettings())
    for _ in 0..<50_000 { submissions.submit(finalSettings) }
    try require(submissions.load().revision == 50_000, "single-slot ingress lost newest revision")
    let cache = RuntimeSnapshotBox(ManagerDisplayState(captureTarget: "cached"))
    let blockedManager = DispatchQueue(label: "lowend.test.blocked-manager")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    blockedManager.async { entered.signal(); release.wait(); cache.store(ManagerDisplayState(captureTarget: "new")); finished.signal() }
    entered.wait()
    try require(cache.load().captureTarget == "cached", "snapshot read depends on a blocked manager")
    release.signal(); finished.wait()
    try require(cache.load().captureTarget == "new", "new manager snapshot not published")

    // Inject each target phase failure, including failures after the graph runs.
    for failurePoint in ["fadeOut", "device", "tap", "aggregate", "output", "capture", "flow", "fadeIn"] {
        var objects = 0, running = false, rollingBack = false
        var events: [String] = []
        func step(_ name: String) throws {
            events.append(name)
            if !rollingBack && name == failurePoint { throw AppError.message(name) }
        }
        do {
            try AudioGraphTransition.run(.init(
                fadeOut: { try step("fadeOut") },
                quiesce: { events.append("quiesce"); running = false; objects = 0 },
                installTarget: {
                    try require(objects == 0 && !running, "target install before quiescence")
                    for phase in ["device", "tap", "aggregate", "output", "capture"] { objects += 1; try step(phase) }
                    running = true
                },
                installRollback: {
                    try require(objects == 0 && !running && events.last == "quiesce", "late rollback must destroy target graph first")
                    rollingBack = true; events.append("rollback"); objects = 5; running = true
                },
                verifyFlow: { try step("flow") },
                fadeIn: { try step("fadeIn") }
            ))
            throw AppError.message("Injected transition unexpectedly succeeded")
        } catch let failure as AudioGraphTransitionFailure {
            try require(failure.recovered && running && objects == 5, "rollback must recover a coherent graph after \(failurePoint)")
        }
    }
    var stopped = false
    do {
        try AudioGraphTransition.run(.init(fadeOut: {}, quiesce: { stopped = true },
            installTarget: { stopped = false; throw AppError.message("target") },
            installRollback: { stopped = false; throw AppError.message("rollback") }, verifyFlow: {}, fadeIn: {}))
        throw AppError.message("Failed rollback unexpectedly succeeded")
    } catch let failure as AudioGraphTransitionFailure {
        try require(!failure.recovered && stopped, "failed rollback must leave both callbacks stopped")
    }
    print("Runtime checks passed (\(assertions) assertions: spatial impulse/history/transition, queue saturation/final ACK, snapshots, lifecycle failure injection)")
}


/// Exercise amount bypass independently from enabled=false. The public amount
/// percentage has already been normalized to 0...1 in this POD; 0.001 is 0.1%.
func runSpatialDryBoundaryChecks() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message("Spatial dry boundary: \(message)") }
    }
    let finiteInputs: [Float] = [-1.25, -0.5, -0.01, 0, 0.01, 0.5, 1.25]
    for boundary: Float in [0, 0.001] {
        var packet = LCSpatialSettings(enabled: 1, amount: boundary,
            ll: LCSpatialPathSettings(delaySamples: 0, gain: 1),
            lr: LCSpatialPathSettings(delaySamples: 0, gain: 0),
            rl: LCSpatialPathSettings(delaySamples: 0, gain: 0),
            rr: LCSpatialPathSettings(delaySamples: 0, gain: 1))
        let initial = Spatializer(settings: packet)
        for input in finiteInputs {
            let output = initial.process(left: input, right: -input)
            try require(output.0 == input && output.1 == -input,
                        "initial amount \(boundary) changed a finite dry sample")
        }
        packet.amount = 0.7
        let transitioning = Spatializer(settings: packet)
        let wet = transitioning.process(left: 1.25, right: -1.25)
        try require(wet.0 != 1.25 && wet.1 != -1.25, "active fixture never entered processing")
        packet.amount = boundary
        transitioning.update(packet)
        for frame in 1...Spatializer.transitionFrames {
            let output = transitioning.process(left: 1.25, right: -1.25)
            try require(output.0.isFinite && output.1.isFinite, "amount fade produced non-finite output")
            if frame < Spatializer.transitionFrames {
                try require(output.0 != 1.25 && output.1 != -1.25,
                            "amount bypass skipped its declared activation fade")
            } else {
                try require(output.0 == 1.25 && output.1 == -1.25,
                            "amount bypass did not reach exact dry on the declared final frame")
            }
        }
        for input in finiteInputs {
            let output = transitioning.process(left: input, right: -input)
            try require(output.0 == input && output.1 == -input,
                        "settled amount \(boundary) changed a finite dry sample")
        }
    }
    let aboveThreshold = Spatializer(settings: LCSpatialSettings(enabled: 1, amount: 0.00101,
        ll: LCSpatialPathSettings(delaySamples: 0, gain: 1),
        lr: LCSpatialPathSettings(delaySamples: 0, gain: 0),
        rl: LCSpatialPathSettings(delaySamples: 0, gain: 0),
        rr: LCSpatialPathSettings(delaySamples: 0, gain: 1)))
    let active = aboveThreshold.process(left: 0.75, right: -0.75)
    try require(active.0.isFinite && active.1.isFinite && active.0 != 0.75 && active.1 != -0.75,
                "amount just above 0.1% incorrectly bypassed processing")
    print("Spatial dry boundary checks passed: amount 0%/0.1% initial and settled exact identity, active-to-dry 256-frame convergence, above-threshold active.")
}
