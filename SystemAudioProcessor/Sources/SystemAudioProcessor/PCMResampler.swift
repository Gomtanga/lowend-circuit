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
/// * **Block continuity.** Each channel always retains the latest 127 input
///   samples, including when a short filter is selected. Every filter reads its
///   own tail from this history, so changing tap count cannot read stale samples.
/// * **Two kernels.** `process(..., kernel:)` offers `.vDSP` (Accelerate
///   `vDSP_dotpr`, default) and `.direct` (a plain scalar dot product). Both
///   produce numerically identical output; `.direct` exists as a baseline so the
///   offline benchmark can compare throughput and so the structure is not
///   hard-dependent on Accelerate.
///
/// Live PCM uses 2×; 4× and 8× remain offline. Optional filter crossfades use the
/// same history for both filters and preallocated per-channel transition state.
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

    private struct FilterTransition {
        var mix: Float = 0
        var target: Float = 0
        var step: Float = 0
        var remaining = 0
        var initialized = false
    }
    private let transitions: UnsafeMutablePointer<FilterTransition>

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
        transitions = .allocate(capacity: self.channelCount)
        transitions.initialize(repeating: FilterTransition(), count: self.channelCount)

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
        transitions.deinitialize(count: channelCount)
        transitions.deallocate()
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
    ///   - transitionFrames: Output frames used to crossfade a filter change.
    ///     Zero selects the new filter immediately. A new request during a fade
    ///     starts at the current mix, so repeated changes do not reset the blend.
    ///     Short/long have different group delay: the fade prevents a sample
    ///     discontinuity, but may briefly change level through phase cancellation.
    /// - Returns: output frame count, or 0 if the set/config is invalid.
    @discardableResult
    func process(input: UnsafePointer<Float>,
                 inputFrames: Int,
                 output: UnsafeMutablePointer<Float>,
                 channel: Int,
                 factor: Int,
                 mode: ResamplingFilterMode,
                 kernel: Kernel = .vDSP,
                 transitionFrames: Int = 0) -> Int {
        guard inputFrames > 0,
              inputFrames <= maxInputFrames,
              channel >= 0, channel < channelCount,
              let shortSet = sets[factor]?[.linearPhaseShort],
              let longSet = sets[factor]?[.linearPhaseLong] else {
            return 0
        }
        let historyCount = maxTapsPerPhase - 1
        let workBase = channel * workStride
        let histBase = channel * historyStride

        // Keep a fixed-size chronological history prefix, even for the short
        // filter. Its dot product begins further into the same prefix.
        if historyCount > 0 {
            work.advanced(by: workBase).update(from: history.advanced(by: histBase),
                                               count: historyCount)
        }
        work.advanced(by: workBase + historyCount).update(from: input, count: inputFrames)

        let outCount = inputFrames * factor
        var transition = transitions[channel]
        let target: Float = mode == .linearPhaseLong ? 1 : 0
        if !transition.initialized || transitionFrames <= 0 {
            transition = FilterTransition(mix: target, target: target,
                                          step: 0, remaining: 0, initialized: true)
        } else if transition.target != target {
            transition.target = target
            transition.remaining = transitionFrames
            transition.step = (target - transition.mix) / Float(transitionFrames)
        }
        for outputFrame in 0..<outCount {
            let j = outputFrame / factor
            let phase = outputFrame - j * factor
            let anchor = workBase + j + historyCount
            let mix = min(1, max(0, transition.mix))
            if mix == 0 {
                output[outputFrame] = dotProduct(shortSet, phase: phase,
                                                 anchor: anchor, kernel: kernel)
            } else if mix == 1 {
                output[outputFrame] = dotProduct(longSet, phase: phase,
                                                 anchor: anchor, kernel: kernel)
            } else {
                let short = dotProduct(shortSet, phase: phase, anchor: anchor, kernel: kernel)
                let long = dotProduct(longSet, phase: phase, anchor: anchor, kernel: kernel)
                output[outputFrame] = short + (long - short) * mix
            }
            if transition.remaining > 0 {
                transition.remaining -= 1
                transition.mix = transition.remaining == 0
                    ? transition.target : transition.mix + transition.step
            }
        }
        transitions[channel] = transition

        // Save the last `historyCount` input samples for the next block.
        if historyCount > 0 {
            let srcStart = workBase + inputFrames
            history.advanced(by: histBase).update(from: work.advanced(by: srcStart),
                                                  count: historyCount)
        }
        return outCount
    }

    @inline(__always)
    private func dotProduct(_ set: CoefficientSet, phase: Int,
                            anchor: Int, kernel: Kernel) -> Float {
        let taps = set.tapsPerPhase
        let coefficients = set.coeffs.advanced(by: phase * taps)
        let window = work.advanced(by: anchor - (taps - 1))
        var result: Float = 0
        switch kernel {
        case .vDSP:
            vDSP_dotpr(coefficients, 1, window, 1, &result, vDSP_Length(taps))
        case .direct:
            for k in 0..<taps { result += coefficients[k] * window[k] }
        }
        return result
    }

    /// Clear the per-channel FIR memory (call off the audio thread on a reset).
    func reset(channel: Int) {
        guard channel >= 0, channel < channelCount else { return }
        history.advanced(by: channel * historyStride)
            .update(repeating: 0, count: historyStride)
        transitions[channel] = FilterTransition()
    }

    func resetAll() {
        history.update(repeating: 0, count: channelCount * historyStride)
        transitions.update(repeating: FilterTransition(), count: channelCount)
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
