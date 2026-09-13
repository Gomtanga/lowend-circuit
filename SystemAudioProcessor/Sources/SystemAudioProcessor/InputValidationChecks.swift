import Foundation

func runInputValidationChecks() throws {
    func require(_ valid: Bool, _ message: String) throws {
        if !valid { throw AppError.message("Input validation check failed: \(message)") }
    }
    var input = Settings()
    input.intensity = .nan
    input.body = .infinity
    input.outputDb = .greatestFiniteMagnitude
    input.spatial.listenerX = -.infinity
    input.spatial.listenerZ = 1_000
    input.spatial.speakerWidth = -10
    input.spatial.amount = .nan
    let safe = input.normalized()
    try require(safe.intensity.isFinite && (0...100).contains(safe.intensity), "nonfinite intensity")
    try require(safe.body.isFinite && (0...100).contains(safe.body), "nonfinite body")
    try require(safe.outputDb == 6, "finite extreme output must be clamped before pow")
    try require(safe.spatial.listenerX == 0 && safe.spatial.listenerZ == 2.8, "listener fallback/range")
    try require(safe.spatial.speakerWidth == 0.6 && safe.spatial.amount.isFinite, "width/amount fallback")
    for (frames, channels) in [(Int.max, 2), (1, Int.max), (-1, 2), (32, 0)] {
        var rejected = false
        do { _ = try LockFreeFloatRingBuffer(capacityFrames: frames, channels: channels) }
        catch { rejected = true }
        try require(rejected, "ring dimensions must fail without arithmetic/conversion traps")
    }
    print("Input checks passed: nonfinite settings, ranges, oversized/invalid ring dimensions")
}
