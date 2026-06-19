import Foundation

/// Independent output-conditioning layer that sits between the tonal DSP
/// (Clean / Circuit / HighExciter / Spatializer) and the output device.
///
/// Signal flow (when active):
///
/// ```
/// post-tonal PCM -> headroom -> [polyphase oversample] -> [dither/noise-shape]
///                -> [experimental delta-sigma] -> [DoP pack] -> output
/// ```
///
/// ## Real-time-safety contract
///
/// * The **live** audio-thread entry point is `processLive(interleaved:frames:)`.
///   In this iteration it is a pure **identity bypass** — it never mutates the
///   buffer. The non-bypass modes are rate-changing and require output device
///   format negotiation, which is explicitly out of scope for this PR, so live
///   stays bypass. The call is still wired in so the plumbing is real and a
///   future PR can activate it without restructuring.
/// * The **offline** entry points (`oversampleStereoInterleaved`,
///   `processDSDToP`) exercise the full pipeline and are used by the test
///   harness. They use the same pre-allocated buffers and the same per-sample
///   loop shape as a future live path would.
/// * `updateSettings(_:)` is a single struct copy invoked from the audio-thread
///   control-event drain (`applyPendingControlEvents`). The lock-free SPSC
///   control queue is the *only* cross-thread handoff, so no locks/atomics are
///   needed inside the engine. Coefficients are pre-built at init and selected
///   by index, so the audio thread never generates coefficients.
final class ResamplingOutputConditioningEngine {
    private let channelCount = 2
    private let maxInputFrames: Int
    private let maxFactor = 8

    private let resampler: PCMResampler
    private let modulator: DeltaSigmaDSDModulator
    private let dopPacker: DoPacker

    // Pre-allocated intermediates, reused on every call. No growth at runtime.
    private let deinterleavedL: UnsafeMutablePointer<Float>
    private let deinterleavedR: UnsafeMutablePointer<Float>
    private let oversampledL: UnsafeMutablePointer<Float>
    private let oversampledR: UnsafeMutablePointer<Float>

    // Current parameter snapshot. Audio-thread single-writer (from the control
    // queue drain), audio-thread reader (in processLive). Tests read/write
    // directly because they own the only thread touching the engine.
    private var settings = OutputConditioningParameters()

    init(maxInputFrames: Int = 8192) {
        self.maxInputFrames = max(64, maxInputFrames)
        let n = self.maxInputFrames
        resampler = PCMResampler(channels: channelCount, maxInputFrames: n)
        modulator = DeltaSigmaDSDModulator(channels: channelCount)
        dopPacker = DoPacker(channelLayout: .stereo)

        deinterleavedL = UnsafeMutablePointer<Float>.allocate(capacity: n)
        deinterleavedR = UnsafeMutablePointer<Float>.allocate(capacity: n)
        oversampledL = UnsafeMutablePointer<Float>.allocate(capacity: n * maxFactor)
        oversampledR = UnsafeMutablePointer<Float>.allocate(capacity: n * maxFactor)
        deinterleavedL.initialize(repeating: 0, count: n)
        deinterleavedR.initialize(repeating: 0, count: n)
        oversampledL.initialize(repeating: 0, count: n * maxFactor)
        oversampledR.initialize(repeating: 0, count: n * maxFactor)
    }

    deinit {
        deinterleavedL.deallocate()
        deinterleavedR.deallocate()
        oversampledL.deallocate()
        oversampledR.deallocate()
    }

    // MARK: - Live path (audio thread)

    /// Audio-thread entry point. Identity bypass for this iteration.
    ///
    /// The conditioning layer is wired into the render path but, per the PR
    /// scope, the live output stays in PCM bypass: enabling oversampling or DSD
    /// would change the output sample rate, which requires device-format
    /// switching that is deferred. `processLive` therefore returns `frames`
    /// without touching `interleaved`. When `isEnabled` is false or `outputMode`
    /// is `.bypass` this is also a no-op, so bypass == disabled (tested).
    @discardableResult
    @inline(__always)
    func processLive(interleaved: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        // Intentional identity. See class docs for the live-vs-offline split.
        // ALLOCATION/LOCK-FREE VERIFICATION POINT: this is the only function the
        // real-time callback invokes on this engine; it performs no allocation,
        // no lock, no dispatch, no @Published read, no coefficient work.
        _ = interleaved
        _ = settings
        return frames
    }

    /// Update the parameter snapshot (audio-thread control-event drain).
    func updateSettings(_ settings: OutputConditioningParameters) {
        self.settings = settings
    }

    func resetAll() {
        resampler.resetAll()
        modulator.resetAll()
    }

    // MARK: - Offline pipeline (test harness)

    /// Polyphase-oversample interleaved stereo, applying `headroomGain` as a
    /// pre-gain. Writes interleaved oversampled stereo into `output`.
    /// - Returns: output frame count (`inputFrames * factor`), or 0 on bad args.
    @discardableResult
    func oversampleStereoInterleaved(input: UnsafePointer<Float>,
                                     inputFrames: Int,
                                     output: UnsafeMutablePointer<Float>,
                                     factor: Int,
                                     mode: ResamplingFilterMode,
                                     headroomGain: Float) -> Int {
        guard inputFrames > 0, inputFrames <= maxInputFrames,
              OutputConditioningParameters.allowedOversamplingFactors.contains(factor) else {
            return 0
        }
        // Deinterleave + headroom trim into per-channel slots.
        for i in 0..<inputFrames {
            deinterleavedL[i] = input[i * 2] * headroomGain
            deinterleavedR[i] = input[i * 2 + 1] * headroomGain
        }
        let outFrames = resampler.process(input: deinterleavedL,
                                          inputFrames: inputFrames,
                                          output: oversampledL,
                                          channel: 0,
                                          factor: factor,
                                          mode: mode)
        _ = resampler.process(input: deinterleavedR,
                              inputFrames: inputFrames,
                              output: oversampledR,
                              channel: 1,
                              factor: factor,
                              mode: mode)
        // Re-interleave.
        for i in 0..<outFrames {
            output[i * 2] = oversampledL[i]
            output[i * 2 + 1] = oversampledR[i]
        }
        return outFrames
    }

    /// Apply headroom gain in place (used by the headroom-accuracy test on the
    /// rate-preserving path). Fills any non-finite sample with 0.
    @discardableResult
    func applyHeadroomInPlace(interleaved: UnsafeMutablePointer<Float>,
                              frames: Int,
                              headroomGain: Float) -> Int {
        guard frames > 0, frames <= maxInputFrames else { return 0 }
        for i in 0..<(frames * 2) {
            var v = interleaved[i] * headroomGain
            if !v.isFinite { v = 0 }
            interleaved[i] = v
        }
        return frames
    }

    /// Full experimental PCM -> delta-sigma -> DoP path.
    ///
    /// The modulator runs at the oversampled rate (`inputFrames * factor`), i.e.
    /// an experimental sub-rate 1-bit stream — reaching a true DSD family clock
    /// would need cascaded oversampling, which is intentionally out of scope.
    /// The DSD family still drives the DoP carrier-rate math and the device
    /// capability check.
    ///
    /// - Parameters:
    ///   - leftDsdBits / rightDsdBits: caller buffers of at least
    ///     `inputFrames * factor` bytes (filled 0/1).
    ///   - dopOutput: caller buffer of at least
    ///     `DoPacker.outputByteCount(forDsdFrames: inputFrames * factor)` bytes.
    /// - Returns: `(dsdFrames, dopBytes)` written, or `(0, 0)` on bad args.
    @discardableResult
    func processDSDToP(interleaved input: UnsafePointer<Float>,
                      inputFrames: Int,
                      factor: Int,
                      mode: ResamplingFilterMode,
                      dsdMode: DSDMode,
                      modulatorOrder: DeltaSigmaDSDModulator.Order,
                      headroomGain: Float,
                      leftDsdBits: UnsafeMutablePointer<UInt8>,
                      rightDsdBits: UnsafeMutablePointer<UInt8>,
                      dopOutput: UnsafeMutablePointer<UInt8>)
        -> (dsdFrames: Int, dopBytes: Int) {
        guard dsdMode != .off,
              inputFrames > 0, inputFrames <= maxInputFrames,
              OutputConditioningParameters.allowedOversamplingFactors.contains(factor) else {
            return (0, 0)
        }
        // Deinterleave (no headroom here — the modulator applies it).
        for i in 0..<inputFrames {
            deinterleavedL[i] = input[i * 2]
            deinterleavedR[i] = input[i * 2 + 1]
        }
        let oversampledFrames = resampler.process(input: deinterleavedL,
                                                  inputFrames: inputFrames,
                                                  output: oversampledL,
                                                  channel: 0,
                                                  factor: factor,
                                                  mode: mode)
        _ = resampler.process(input: deinterleavedR,
                              inputFrames: inputFrames,
                              output: oversampledR,
                              channel: 1,
                              factor: factor,
                              mode: mode)

        modulator.process(input: oversampledL,
                          frames: oversampledFrames,
                          output: leftDsdBits,
                          channel: 0,
                          order: modulatorOrder,
                          headroomGain: headroomGain)
        modulator.process(input: oversampledR,
                          frames: oversampledFrames,
                          output: rightDsdBits,
                          channel: 1,
                          order: modulatorOrder,
                          headroomGain: headroomGain)

        let dopBytes = dopPacker.pack(leftBits: leftDsdBits,
                                      rightBits: rightDsdBits,
                                      dsdFrames: oversampledFrames,
                                      output: dopOutput)
        return (oversampledFrames, dopBytes)
    }

    /// Expose the DoP packer marker sanity check for tests.
    @discardableResult
    func verifyDoPMarkers(output: UnsafePointer<UInt8>, byteCount: Int) -> Int {
        dopPacker.verifyMarkers(output: output, byteCount: byteCount)
    }

    /// Test/diagnostic: largest |error state| across modulator channels. Used by
    /// the offline checks to confirm the overload guard keeps the delta-sigma loop
    /// bounded for pathological input. Read-only; no effect on processing.
    func modulatorMaxStateMagnitude() -> Float {
        modulator.maxStateMagnitude()
    }

    /// Test/diagnostic: the configured modulator overload threshold.
    func modulatorOverloadLimit() -> Float {
        modulator.overloadLimit
    }

    /// Test/diagnostic: how many times the modulator overload guard has fired.
    func modulatorOverloadResets() -> Int { modulator.overloadResets() }

    /// Test/diagnostic: zero the modulator overload-reset counter.
    func resetModulatorOverloadCounters() { modulator.resetOverloadCounters() }

    /// Test/diagnostic: seed a channel's modulator state to force an overload.
    func seedModulatorState(channel: Int, e1: Float, e2: Float) {
        modulator.seedState(channel: channel, e1: e1, e2: e2)
    }
}
