import Foundation

/// Exercises the production handler and shared route guard with injected
/// actions. No Process Tap, AVAudioEngine or hardware rate operation is opened.
func runTapFormatEventChecks() throws {
    enum FixtureError: Error { case read, rebuild }
    var assertions = 0
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw AppError.message("TapFormatEventChecks: \(message)") }
    }
    let running = TapFormatEventHandler.State(previousSampleRate: 48_000,
        isStarted: true, isAutomaticTransition: false, isLivePCM2x: false)
    var state = running
    var currentRate = 96_000.0
    var token = HardwareObservationToken()
    var events: [String] = []
    var acceptedRate: Double?
    var failRead = false, invalidateDuringRead = false, failRebuild = false
    var rejectMismatchedUnity = false
    let unchangedOutputRate = 48_000.0
    func run() -> TapFormatEventHandler.Outcome {
        TapFormatEventHandler.handle(state: state, operations: .init(
            isCurrentRegistration: { token.isValid },
            readCurrentSampleRate: {
                events.append("read")
                if invalidateDuringRead { token.invalidate() }
                if failRead { throw FixtureError.read }
                return currentRate
            },
            acceptSampleRate: { acceptedRate = $0; events.append("accept") },
            rebuildNormalGraph: {
                events.append("rebuild")
                if rejectMismatchedUnity {
                    try AudioLifecyclePolicy.validateUnityRoute(captureRate: currentRate, outputRate: unchangedOutputRate)
                }
                if failRebuild { token.invalidate(); throw FixtureError.rebuild }
            },
            deactivateLivePCM2x: {
                events.append("deactivate2x")
                if rejectMismatchedUnity {
                    try AudioLifecyclePolicy.validateUnityRoute(captureRate: currentRate, outputRate: unchangedOutputRate)
                }
            },
            reportFailure: { _, phase in events.append(phase == .read ? "failure.read" : "failure.reconfigure") },
            publishState: { events.append("publish") }
        ))
    }
    func clear() { events = []; acceptedRate = nil }

    try require(run() == .rebuilt, "independent tap change must request a normal rebuild")
    try require(events == ["read", "accept", "rebuild", "publish"] && acceptedRate == 96_000,
                "unchanged output must not suppress the independent tap event")
    clear(); rejectMismatchedUnity = true
    try require(run() == .failed, "persistent new-tap/output mismatch must fail shared route validation")
    try require(events == ["read", "accept", "rebuild", "failure.reconfigure", "publish"],
                "route failure must publish failure rather than report a successful rebuild")
    rejectMismatchedUnity = false

    for disposition in 0..<3 {
        clear(); state = running; currentRate = 96_000
        if disposition == 0 { currentRate = 48_000 }
        if disposition == 1 { state.isStarted = false }
        if disposition == 2 { state.isAutomaticTransition = true }
        try require(run() == .displayOnly && events == ["read", "accept", "publish"],
                    "duplicate, stopped or automatic-transition event must not install another graph")
    }

    clear(); state = running; state.isLivePCM2x = true; currentRate = 44_100
    try require(run() == .requestedLivePCM2xDeactivation, "tap change invalidating 48k/96k live split requests deactivation")
    try require(events == ["read", "accept", "deactivate2x", "publish"], "2x must not run the normal update branch directly")
    clear(); rejectMismatchedUnity = true
    try require(run() == .failed && events.contains("failure.reconfigure"),
                "a still-mismatched normal route after 2x deactivation must report failure")
    rejectMismatchedUnity = false; state = running

    clear(); failRead = true
    try require(run() == .failed && acceptedRate == nil && events == ["read", "failure.read", "publish"],
                "read failure must not accept an invented rate or rebuild")
    failRead = false
    for invalid in [Double.nan, .infinity, 7_999, 768_001] {
        clear(); currentRate = invalid
        try require(run() == .failed && acceptedRate == nil && events == ["read", "failure.read", "publish"],
                    "invalid tap rates must use the read-failure path")
    }

    clear(); currentRate = 96_000; token.invalidate()
    try require(run() == .ignoredRegistration && events.isEmpty, "retired tap registration must not even read the new session")
    clear(); token = HardwareObservationToken(); invalidateDuringRead = true
    try require(run() == .ignoredRegistration && events == ["read"] && acceptedRate == nil,
                "retired-during-read observation must not publish a late event")
    invalidateDuringRead = false; token = HardwareObservationToken()

    clear(); currentRate = 96_000 // Notification arrives before rollback changes the live rate.
    let delayedDelivery = { run() }
    currentRate = 48_000
    try require(delayedDelivery() == .displayOnly && acceptedRate == 48_000 && !events.contains("rebuild"),
                "late event must read current tap rate, not replay the notification-time rate")

    clear(); currentRate = 96_000; failRebuild = true
    try require(run() == .failed && !token.isValid && events.contains("failure.reconfigure"),
                "a rebuild retiring its own registration must still report its later failure")
    print("Tap format event checks passed (\(assertions) assertions: production handler, independent tap change, 2x mismatch, read failure and late registration; injected actions, not Core Audio execution)")
}
