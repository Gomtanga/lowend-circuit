import Accelerate
import Foundation

/// Integer (2x / 4x / 8x) polyphase FIR upsampler.
///
/// Design notes
/// ------------
/// * **Rate independence (44.1 kHz vs 48 kHz families).** The prototype low-pass
///   is defined relative to the *input* sample period: its normalized cut-off is
///   π/L radians per input sample (i.e. half the input Nyquist, which is exactly
///   the input's usable band). Because the taps are expressed in units of input
///   samples — not absolute Hz — the SAME coefficient set is correct for any
///   input rate: 44 100, 48 000, 88 200, 96 000, … all the way up. A 2x set maps
///   44.1k→88.2k and 48k→96k identically; an 8x set maps 44.1k→352.8k and
///   48k→384k identically. Only `(factor, filterMode)` changes the taps, never
///   the absolute rate. We therefore pre-build every `(factor, filterMode)`
///   coefficient set **once at init** and the render path only selects a
///   pre-built set by index. No coefficient generation ever happens on the audio
///   thread. The `runOutputConditioningChecks` "rate-family" cases verify this
///   by oversampling the same signal at both 44 100 and 48 000 Hz and confirming
///   the outputs match to floating-point tolerance.
/// * **No per-frame allocation.** All working memory (per-channel history and
///   scratch) is allocated at init and reused. `process(...)` takes raw
///   `UnsafePointer<Float>` buffers and writes into a caller-owned output buffer.
/// * **Block continuity.** A per-channel history of the last `tapsPerPhase - 1`
///   input samples is retained across calls so consecutive blocks interpolate
///   correctly (the FIR has memory, not just within one block).
/// * **Two kernels.** `process(..., kernel:)` offers `.vDSP` (Accelerate
///   `vDSP_dotpr`, default) and `.direct` (a plain scalar dot product). Both
///   produce numerically identical output; `.direct` exists as a baseline so the
///   offline benchmark can compare throughput and so the structure is not
///   hard-dependent on Accelerate.
///
/// The live audio path keeps this module in `bypass` in this iteration, so
/// `process(...)` is currently exercised only by the offline test harness — but
/// it is written to the same real-time contract so a future PR can flip it live
/// without reworking the structure.
final class PCMResampler {
    /// Selects the dot-product kernel used by `process`. Both are real-time safe
    /// (no allocation); `.direct` is a baseline for offline benchmarking.
    enum Kernel { case vDSP, direct }

    /// One pre-built polyphase coefficient set, stored with taps *reversed*
    /// within each phase so the per-output dot product reads both the taps and
    /// the input window with stride +1 (vDSP_dotpr friendly).
    private struct CoefficientSet {
        let factor: Int
        let mode: ResamplingFilterMode
        let tapsPerPhase: Int
        /// Flat storage: `factor * tapsPerPhase` floats, laid out as
        /// `coeffs[phase * tapsPerPhase + k]` (already reversed per phase).
        let coeffs: UnsafeMutablePointer<Float>
    }

    private let channelCount: Int
    private let maxInputFrames: Int

    /// All `(factor, filterMode)` coefficient sets, keyed for O(1) selection.
    /// `minimumPhaseExperimental` aliases onto the short linear-phase set until
    /// a real minimum-phase design lands (kept out of this iteration).
    private let sets: [Int: [ResamplingFilterMode: CoefficientSet]]

    /// Per-channel history: the last `maxTapsPerPhase - 1` input samples.
    private let history: UnsafeMutablePointer<Float>
    private let historyStride: Int          // = maxTapsPerPhase (room for taps-1 + guard)
    private let maxTapsPerPhase: Int

    /// Per-channel scratch that holds [history tail | new input] for a single
    /// `process` call, so the dot products read a contiguous ascending window.
    private let work: UnsafeMutablePointer<Float>
    private let workStride: Int             // = maxInputFrames + maxTapsPerPhase

    init(channels: Int, maxInputFrames: Int) {
        self.channelCount = max(1, channels)
        self.maxInputFrames = max(1, maxInputFrames)
        self.maxTapsPerPhase = ResamplingFilterMode.linearPhaseLong.tapsPerPhase

        // Build every supported coefficient set up front (off any audio thread).
        var built: [Int: [ResamplingFilterMode: CoefficientSet]] = [:]
        let factors = OutputConditioningParameters.allowedOversamplingFactors
        for factor in factors {
            var perMode: [ResamplingFilterMode: CoefficientSet] = [:]
            for mode in [ResamplingFilterMode.linearPhaseShort,
                         ResamplingFilterMode.linearPhaseLong] {
                perMode[mode] = PCMResampler.buildSet(factor: factor, mode: mode)
            }
            // minimumPhaseExperimental reuses the short set (stub, see header).
            perMode[.minimumPhaseExperimental] = perMode[.linearPhaseShort]
            built[factor] = perMode
        }
        self.sets = built

        let taps = self.maxTapsPerPhase
        self.historyStride = taps
        self.history = UnsafeMutablePointer<Float>.allocate(capacity: self.channelCount * historyStride)
        history.initialize(repeating: 0, count: self.channelCount * historyStride)

        self.workStride = self.maxInputFrames + taps
        self.work = UnsafeMutablePointer<Float>.allocate(capacity: self.channelCount * workStride)
        work.initialize(repeating: 0, count: self.channelCount * workStride)
    }

    deinit {
        // `minimumPhaseExperimental` aliases the short set, so several CoefficientSet
        // values may share one buffer. Deallocate each distinct pointer exactly once.
        var freed = Set<UnsafeMutablePointer<Float>>()
        for perMode in sets.values {
            for set in perMode.values {
                if freed.insert(set.coeffs).inserted {
                    set.coeffs.deallocate()
                }
            }
        }
        history.deallocate()
        work.deallocate()
    }

    // MARK: - Render path (allocation-free)

    /// Upsample `inputFrames` samples of one channel by `factor` and write the
    /// result into `output`. Returns the number of output frames written
    /// (`inputFrames * factor`).
    ///
    /// - Parameters:
    ///   - input: `inputFrames` contiguous Float samples for `channel`.
    ///   - output: caller-owned buffer of at least `inputFrames * factor` floats.
    ///   - channel: channel index (0-based). Each channel keeps independent state.
    ///   - factor: 2, 4 or 8.
    ///   - mode: filter character.
    ///   - kernel: `.vDSP` (Accelerate, default) or `.direct` (scalar loop). Both
    ///     are real-time safe and numerically identical; `.direct` is for the
    ///     offline benchmark baseline.
    /// - Returns: output frame count, or 0 if the set/config is invalid.
    @discardableResult
    func process(input: UnsafePointer<Float>,
                 inputFrames: Int,
                 output: UnsafeMutablePointer<Float>,
                 channel: Int,
                 factor: Int,
                 mode: ResamplingFilterMode,
                 kernel: Kernel = .vDSP) -> Int {
        guard inputFrames > 0,
              inputFrames <= maxInputFrames,
              channel >= 0, channel < channelCount,
              let set = sets[factor]?[mode] else {
            return 0
        }
        let taps = set.tapsPerPhase
        let historyCount = taps - 1
        let workBase = channel * workStride
        let histBase = channel * historyStride

        // Assemble [history tail | new input] contiguously in the scratch slot.
        // historyCount is at most maxTapsPerPhase-1; scratch is sized for that.
        if historyCount > 0 {
            work.advanced(by: workBase).update(from: history.advanced(by: histBase),
                                               count: historyCount)
        }
        work.advanced(by: workBase + historyCount).update(from: input, count: inputFrames)

        let coeffsBase = set.coeffs
        let outCount = inputFrames * factor

        switch kernel {
        case .vDSP:
            // Accelerate dot product. Both inputs read with stride +1 because the
            // per-phase taps are stored reversed (see buildSet).
            for outputFrame in 0..<outCount {
                let j = outputFrame / factor          // input anchor index
                let phase = outputFrame - j * factor  // outputFrame % factor
                var dot: Float = 0
                vDSP_dotpr(coeffsBase.advanced(by: phase * taps), 1,
                           work.advanced(by: workBase + j), 1,
                           &dot,
                           vDSP_Length(taps))
                output[outputFrame] = dot
            }
        case .direct:
            // Plain scalar dot product — identical math, no Accelerate dependency.
            // Kept as a baseline so the offline benchmark can compare throughput.
            for outputFrame in 0..<outCount {
                let j = outputFrame / factor
                let phase = outputFrame - j * factor
                let tapBase = coeffsBase.advanced(by: phase * taps)
                let window = work.advanced(by: workBase + j)
                var acc: Float = 0
                for k in 0..<taps {
                    acc += tapBase[k] * window[k]
                }
                output[outputFrame] = acc
            }
        }

        // Save the last `historyCount` input samples for the next block.
        if historyCount > 0 {
            let srcStart = workBase + historyCount + (inputFrames - historyCount)
            history.advanced(by: histBase).update(from: work.advanced(by: srcStart),
                                                  count: historyCount)
        }
        return outCount
    }

    /// Clear the per-channel FIR memory (call off the audio thread on a reset).
    func reset(channel: Int) {
        guard channel >= 0, channel < channelCount else { return }
        history.advanced(by: channel * historyStride)
            .update(repeating: 0, count: historyStride)
    }

    func resetAll() {
        history.update(repeating: 0, count: channelCount * historyStride)
    }

    // MARK: - Coefficient design (init-time only)

    private static func buildSet(factor: Int, mode: ResamplingFilterMode) -> CoefficientSet {
        let tapsPerPhase = mode.tapsPerPhase
        let length = factor * tapsPerPhase      // prototype length (multiple of factor)

        // Prototype low-pass: cut-off at π/factor in input-rate radians.
        // h[n] = sinc((n - center)/factor), Blackman-windowed. The 1/factor
        // DC-gain scaling is the sinc argument itself (sinc(x)/factor), so we do
        // not multiply by an extra scaleFactor below.
        let center = Double(length - 1) / 2.0
        var prototype = [Double](repeating: 0, count: length)
        for n in 0..<length {
            let x = (Double(n) - center) / Double(factor)
            var sample: Double
            if abs(x) < 1e-12 {
                sample = 1.0
            } else {
                sample = sin(.pi * x) / (.pi * x)
            }
            // Blackman window.
            let w = 0.42
                - 0.5 * cos(2.0 * .pi * Double(n) / Double(length - 1))
                + 0.08 * cos(4.0 * .pi * Double(n) / Double(length - 1))
            prototype[n] = sample * w
        }

        // Polyphase decomposition + per-phase tap reversal so render reads both
        // buffers with stride +1. phase p taps (k=0..tapsPerPhase-1):
        //   forward: prototype[p + k*factor]
        //   reversed store: coeffs[p*tapsPerPhase + k] = prototype[p + (tapsPerPhase-1-k)*factor]
        //
        // Per-phase DC normalization: each phase's taps are scaled so they sum to
        // exactly 1. This guarantees unity DC gain and a perfectly flat DC
        // response regardless of windowing/truncation — a constant input passes
        // through unchanged (verified by the DC unity-gain check). Without it the
        // Blackman-windowed finite prototype leaves a small per-phase sum error
        // that shows up as DC ripple.
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: length)
        for phase in 0..<factor {
            var phaseSum: Float = 0
            for k in 0..<tapsPerPhase {
                phaseSum += Float(prototype[phase + k * factor])
            }
            let norm = abs(phaseSum) > 1e-12 ? 1.0 / phaseSum : 1.0
            for k in 0..<tapsPerPhase {
                let protoIndex = phase + (tapsPerPhase - 1 - k) * factor
                storage[phase * tapsPerPhase + k] = Float(prototype[protoIndex]) * norm
            }
        }
        return CoefficientSet(factor: factor,
                              mode: mode,
                              tapsPerPhase: tapsPerPhase,
                              coeffs: storage)
    }
}
