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
/// * The **live** audio-thread entry point is `processLive(input:inputFrames:output:)`.
///   In bypass it copies `input` → `output` verbatim (identity); when the live
///   PCM 2× oversampling mode is active it polyphase-upsamples 2× with headroom.
///   Live scope is **2× only** (44.1k→88.2k, 48k→96k) — 4×/8×, dither and DSD
///   stay offline. It never touches device format; rate negotiation happens off
///   the audio thread (see `SystemAudioProcessor`'s reconfigure path).
/// * The **offline** entry points (`oversampleStereoInterleaved`,
///   `processDSDToP`) exercise the full 2×/4×/8× pipeline and are used by the
///   test harness. They use the same pre-allocated buffers and the same
///   per-sample loop shape as the live path.
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

    /// Audio-thread entry point. Copies `input` → `output` verbatim (bypass)
    /// unless the live PCM 2× oversampling mode is active, in which case it
    /// polyphase-upsamples 2× with the configured headroom.
    ///
    /// Live scope (this PR): **2× only**, `outputMode == .pcmOversampling`,
    /// `oversamplingFactor == 2`. Any other mode/factor (bypass, dither, DSD,
    /// 4×, 8×) is a verbatim identity copy, so the output frame count equals the
    /// input frame count. Which input sample rates are eligible (44.1k→88.2k,
    /// 48k→96k) is decided *off* the audio thread by the processor before it
    /// activates the mode; the engine only acts on the flattened settings
    /// snapshot it was handed, so a non-eligible rate is never active here.
    ///
    /// `output` must hold at least `inputFrames * 2 * 2` Float samples (the 2×
    /// interleaved-stereo case). Returns the number of output *frames* written
    /// (`inputFrames * 2` when 2× is active, `inputFrames` on bypass, 0 on
    /// degenerate input). The caller pushes `returnedFrames * 2` samples.
    ///
    /// ALLOCATION/LOCK-FREE VERIFICATION POINT: this is the only function the
    /// real-time callback invokes on this engine. It performs no allocation, no
    /// lock, no dispatch, no @Published read, no coefficient work — coefficients
    /// are pre-built at init and selected by index, and all working memory is
    /// the pre-allocated per-channel buffers (`deinterleavedL/R`,
    /// `oversampledL/R`). The resampler `process` is itself allocation-free.
    @discardableResult
    func processLive(input: UnsafePointer<Float>,
                     inputFrames: Int,
                     output: UnsafeMutablePointer<Float>) -> Int {
        guard inputFrames > 0, inputFrames <= maxInputFrames else {
            return 0
        }

        // Live allows ONLY 2×. 4×/8×, dither, DSD and disabled all bypass, so a
        // non-eligible configuration produces a plain identity copy at the input
        // frame count — the output buffer is never read beyond that.
        let liveActive = settings.isEnabled
            && settings.outputMode == .pcmOversampling
            && settings.oversamplingFactor == 2

        guard liveActive else {
            // Verbatim identity copy. No headroom on the bypass path, so the
            // post-tonal signal reaches the ring buffer unchanged (matches the
            // pre-oversampling behaviour exactly).
            output.update(from: input, count: inputFrames * 2)
            return inputFrames
        }

        // 2× polyphase oversample with headroom trim into the per-channel slots,
        // then finite-guarded re-interleave into the caller's output buffer.
        let gain = settings.headroomGain
        for i in 0..<inputFrames {
            deinterleavedL[i] = input[i * 2] * gain
            deinterleavedR[i] = input[i * 2 + 1] * gain
        }
        let outFrames = resampler.process(input: deinterleavedL,
                                          inputFrames: inputFrames,
                                          output: oversampledL,
                                          channel: 0,
                                          factor: 2,
                                          mode: settings.filterMode)
        _ = resampler.process(input: deinterleavedR,
                              inputFrames: inputFrames,
                              output: oversampledR,
                              channel: 1,
                              factor: 2,
                              mode: settings.filterMode)
        for i in 0..<outFrames {
            var l = oversampledL[i]
            var r = oversampledR[i]
            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }
            output[i * 2] = l
            output[i * 2 + 1] = r
        }
        return outFrames
    }

    /// Update the parameter snapshot (audio-thread control-event drain). When the
    /// live-oversampling activation or the oversampling factor changes, the FIR
    /// per-channel history is cleared so the (re)activated path starts from a
    /// clean state — minimising the transient at the mode switch. `resetAll` is a
    /// plain memset of the pre-allocated history, so it stays allocation- and
    /// lock-free and is safe on the audio thread.
    func updateSettings(_ settings: OutputConditioningParameters) {
        let wasLiveActive = self.settings.isEnabled
            && self.settings.outputMode == .pcmOversampling
            && self.settings.oversamplingFactor == 2
        let isLiveActive = settings.isEnabled
            && settings.outputMode == .pcmOversampling
            && settings.oversamplingFactor == 2
        let factorChanged = self.settings.oversamplingFactor != settings.oversamplingFactor
        self.settings = settings
        if wasLiveActive != isLiveActive || factorChanged {
            resampler.resetAll()
        }
    }

    /// Clear all filter/modulator state. Safe to call off the audio thread during
    /// engine reconfiguration (device rate change) to start the next session clean.
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
