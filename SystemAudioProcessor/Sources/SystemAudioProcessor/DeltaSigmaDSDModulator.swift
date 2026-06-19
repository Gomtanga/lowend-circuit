import Foundation

/// 1-bit delta-sigma modulator (1st or 2nd order, error-feedback form) that
/// turns a high-rate PCM stream into a 1-bit PDM/DSD bit stream.
///
/// This is the experimental PCM -> DSD stage. It is **offline / test-only** in
/// this iteration (live output stays in PCM bypass) because real-time 1-bit
/// modulation at DSD clock rates (2.8 / 5.6 / 11.3 MHz) is very CPU heavy and
/// requires the deferred DoP device-format switching.
///
/// Real-time contract (held even though only the offline harness calls it now):
/// * per-channel integrator/error state is pre-allocated at init and indexed by
///   channel — never grown at runtime;
/// * `process(...)` takes raw pointers and a caller-owned output buffer, applies
///   the headroom gain and [-1,1] clamp itself, and writes one 0/1 byte per
///   input sample;
/// * an overload guard resets a channel's state if the error term runs away,
///   which keeps the loop bounded for pathological input.
final class DeltaSigmaDSDModulator {
    enum Order: Int { case first = 1, second = 2 }

    private let channelCount: Int
    /// Per-channel error memory: `[e1, e2]` per channel (e2 unused for 1st order).
    private let state: UnsafeMutablePointer<Float>
    private let stateStride: Int     // = 2

    /// Modulator is considered unstable past this error magnitude; reset channel.
    private let overloadThreshold: Float = 4.0

    /// Counts how many times the overload guard has fired. Test/diagnostic only —
    /// lets the offline checks PROVE the guard is exercised (not just that the
    /// loop happens to stay bounded). Never read on the audio path.
    private var overloadResetCount: Int = 0

    init(channels: Int) {
        self.channelCount = max(1, channels)
        self.stateStride = 2
        let count = self.channelCount * stateStride
        self.state = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.state.initialize(repeating: 0, count: count)
    }

    deinit {
        state.deallocate()
    }

    /// Modulate `frames` samples of one channel into a 1-bit stream.
    ///
    /// - Parameters:
    ///   - input: `frames` Float samples (any amplitude; headroom + clamp applied).
    ///   - output: caller-owned buffer of at least `frames` bytes (0 or 1 each).
    ///   - channel: channel index with independent modulator state.
    ///   - order: 1st or 2nd order loop (selected per call).
    ///   - headroomGain: linear gain applied before quantization (e.g. ~0.708 for
    ///     -3 dB). Protects the loop from overload.
    /// - Returns: number of bytes written (== `frames`), or 0 on invalid args.
    @discardableResult
    func process(input: UnsafePointer<Float>,
                 frames: Int,
                 output: UnsafeMutablePointer<UInt8>,
                 channel: Int,
                 order: Order,
                 headroomGain: Float) -> Int {
        guard frames > 0,
              channel >= 0, channel < channelCount else { return 0 }

        let base = channel * stateStride
        var e1 = state[base]
        var e2 = state[base + 1]

        for i in 0..<frames {
            // Headroom + hard clamp to keep the loop bounded.
            var x = input[i] * headroomGain
            if !x.isFinite { x = 0 }
            if x > 1.0 { x = 1.0 } else if x < -1.0 { x = -1.0 }

            let bitPlusOne: UInt8
            switch order {
            case .first:
                // y = x + e1 ; bit = sign(y) ; e1 = y - bit.  NTF = (1 - z^-1).
                let y = x + e1
                if y >= 0 {
                    bitPlusOne = 1
                    e1 = y - 1.0
                } else {
                    bitPlusOne = 0
                    e1 = y + 1.0
                }
            case .second:
                // 2nd-order error feedback: y = x + 2*e1 - e2 ; bit = sign(y).
                // NTF = (1 - z^-1)^2.
                let y = x + 2.0 * e1 - e2
                e2 = e1
                if y >= 0 {
                    bitPlusOne = 1
                    e1 = y - 1.0
                } else {
                    bitPlusOne = 0
                    e1 = y + 1.0
                }
            }
            output[i] = bitPlusOne

            // Overload guard: if the loop is diverging, snap this channel back.
            if abs(e1) > overloadThreshold || abs(e2) > overloadThreshold {
                e1 = 0
                e2 = 0
                overloadResetCount &+= 1
            }
        }

        state[base] = e1
        state[base + 1] = e2
        return frames
    }

    /// Clear one channel's modulator memory (call off the audio thread on reset).
    func reset(channel: Int) {
        guard channel >= 0, channel < channelCount else { return }
        state.advanced(by: channel * stateStride)
            .update(repeating: 0, count: stateStride)
    }

    func resetAll() {
        state.update(repeating: 0, count: channelCount * stateStride)
    }

    /// Test/diagnostic accessor: the largest |error state| across all channels.
    /// Used by the offline checks to confirm the overload guard keeps the loop
    /// bounded for pathological input. Read-only; no effect on processing.
    func maxStateMagnitude() -> Float {
        var peak: Float = 0
        for i in 0..<(channelCount * stateStride) {
            let v = abs(state[i])
            if v > peak { peak = v }
        }
        return peak
    }

    /// Diagnostic: the configured overload threshold (tests assert state stays
    /// at or below this after processing extreme input).
    var overloadLimit: Float { overloadThreshold }

    /// Test/diagnostic: how many times the overload guard has fired since the
    /// last reset. Used to PROVE the guard is exercised, not just that the loop
    /// stays bounded. Read-only; never accessed from the audio path.
    func overloadResets() -> Int { overloadResetCount }

    /// Test/diagnostic: zero the overload-reset counter.
    func resetOverloadCounters() { overloadResetCount = 0 }

    /// Test/diagnostic: force a channel's integrator/error state to arbitrary
    /// values. Used to seed an over-threshold condition so the offline check can
    /// verify the guard actually fires and recovers. No effect on normal use.
    func seedState(channel: Int, e1: Float, e2: Float) {
        guard channel >= 0, channel < channelCount else { return }
        let base = channel * stateStride
        state[base] = e1
        state[base + 1] = e2
    }
}
