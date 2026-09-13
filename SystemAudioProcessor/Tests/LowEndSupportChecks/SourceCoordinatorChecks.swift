import Foundation
import LowEndSupport

func runSourceCoordinatorChecks() throws {
    enum FixtureError: Error { case transition }
    var assertions = 0
    func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if !(try condition()) { throw NSError(domain: "SourceCoordinatorChecks: \(message)", code: 1) }
    }
    let origin = Date(timeIntervalSinceReferenceDate: 100)
    func format(_ rate: Double) -> SourceAudioFormat {
        SourceAudioFormat(player: .tidal, sampleRate: rate, bitDepth: 24,
                          confidence: .detected, evidence: .tidalPlayerLog, observedAt: origin)
    }
    var coordinator = SourceRateMatchCoordinator()
    var clock = origin.addingTimeInterval(-1)
    var deviceRate = 48_000.0
    var requests: [Double] = []
    func observe(_ source: SourceAudioFormat?) throws -> SourceRateMatchCoordinator.Outcome {
        try coordinator.observe(format: source, currentDeviceRate: deviceRate,
            supportedRates: [44_100, 48_000, 96_000], isDeviceRateSettable: true,
            now: { clock }, performTransition: { target in
                requests.append(target); deviceRate = target; return true
            })
    }
    try require(try observe(format(44_100)) == .waiting, "first candidate must settle")
    clock = origin
    try require(try observe(format(44_100)) == .applied(targetRate: 44_100), "initial accepted transition")
    clock = origin.addingTimeInterval(0.1)
    try require(try observe(format(96_000)) == .waiting, "new target establishes stability")
    for offset in [1.1, 1.5] {
        clock = origin.addingTimeInterval(offset)
        let outcome = try observe(format(96_000))
        guard case .coolingDown(let remaining) = outcome else { throw FixtureError.transition }
        try require(remaining > 0 && requests == [44_100], "actual cooldown must suppress the transition closure")
    }
    clock = origin.addingTimeInterval(2.1)
    try require(try observe(format(96_000)) == .applied(targetRate: 96_000), "deferred stable proposal runs after cooldown")
    clock = origin.addingTimeInterval(3.1)
    try require(try observe(format(96_000)) == .waiting && requests == [44_100, 96_000], "matching device must not run twice")

    // Recreate the same real cooldown, then lose evidence before it expires.
    coordinator.reset(); requests = []; deviceRate = 48_000
    clock = origin.addingTimeInterval(-1); _ = try observe(format(44_100))
    clock = origin; _ = try observe(format(44_100))
    clock = origin.addingTimeInterval(0.1); _ = try observe(format(96_000))
    clock = origin.addingTimeInterval(1.1); _ = try observe(format(96_000))
    clock = origin.addingTimeInterval(1.7)
    try require(try observe(nil) == .waiting, "missing source clears stability during cooldown")
    clock = origin.addingTimeInterval(2.1)
    try require(try observe(format(96_000)) == .waiting && requests == [44_100], "cooldown expiry does not revive pre-gap stability")
    clock = origin.addingTimeInterval(3.1)
    try require(try observe(format(96_000)) == .applied(targetRate: 96_000), "fresh stability after gap is required")

    for shouldThrow in [false, true] {
        coordinator.reset(); deviceRate = 48_000
        clock = origin
        _ = try observe(format(96_000))
        clock = origin.addingTimeInterval(1)
        var attempts = 0
        do {
            let result = try coordinator.observe(format: format(96_000), currentDeviceRate: deviceRate,
                supportedRates: [48_000, 96_000], isDeviceRateSettable: true, now: { clock },
                performTransition: { _ in attempts += 1; if shouldThrow { throw FixtureError.transition }; return false })
            try require(!shouldThrow && result == .deferred(targetRate: 96_000), "false outcome must not ACK")
        } catch FixtureError.transition {
            try require(shouldThrow, "unexpected injected failure")
        }
        clock = origin.addingTimeInterval(shouldThrow ? 3.1 : 1.1)
        let retried = try coordinator.observe(format: format(96_000), currentDeviceRate: deviceRate,
            supportedRates: [48_000, 96_000], isDeviceRateSettable: true, now: { clock },
            performTransition: { _ in attempts += 1; return true })
        try require(retried == .applied(targetRate: 96_000) && attempts == 2, "unaccepted/failed proposal must remain eligible")
        clock = clock.addingTimeInterval(3)
        let repeated = try coordinator.observe(format: format(96_000), currentDeviceRate: deviceRate,
            supportedRates: [48_000, 96_000], isDeviceRateSettable: true, now: { clock },
            performTransition: { _ in attempts += 1; return true })
        try require(repeated == .waiting && attempts == 2, "successful ACK consumes the same proposal even before device snapshot refresh")
    }
    print("Source coordinator checks passed (\(assertions) assertions: real cooldown, injected clock/outcome, source gap and successful ACK)")
}
