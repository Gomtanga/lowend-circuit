import Accelerate
import Foundation

/// Offline verification + benchmark of the output-conditioning engine.
///
/// Mirrors the `runDSPParityChecks()` idiom: pure-DSP, no audio device required,
/// invoked from `SystemAudioProcessor --self-test`. Each check throws
/// `AppError.message` on failure so a failure exits non-zero. The informational
/// benchmark is a separate opt-in entry point, not part of correctness checks.
///
/// Allocation-free contract: the real-time path is exercised here through
/// `processLive` in both bypass and live 2× modes. The
/// offline pipeline uses the same pre-allocated per-channel buffers the engine
/// owns at init; tests supply caller-owned output buffers sized up front, exactly
/// like `compareProcessing` in `DSPParityChecks.swift`.
func runOutputConditioningChecks() throws {
    let engine = ResamplingOutputConditioningEngine(maxInputFrames: 4096)
    let inputFrames = 1024

    // A 1 kHz stereo sine at ~0.8 amplitude, identical on both channels.
    let sine44 = stereoSine(freq: 1000, rate: 44_100, frames: inputFrames, amplitude: 0.8)

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 1 — PCM resampler: finiteness across frequencies, factors, rates
    // ─────────────────────────────────────────────────────────────────────
    // Exercises every (frequency × factor × rate-family) cell and asserts no
    // NaN/Inf and the correct output length. Frequencies include near-Nyquist
    // (0.49·fs) to stress the filter's stop-band behaviour.
    let frequenciesHz: [Float] = [1_000, 10_000, 18_000, 20_000]
    let factors = OutputConditioningParameters.allowedOversamplingFactors // [2,4,8]
    let modes: [ResamplingFilterMode] = [.linearPhaseShort, .linearPhaseLong, .minimumPhaseExperimental]
    try check(OutputConditioningParameters.clampFactor(Int.min) == 2
              && OutputConditioningParameters.clampFactor(Int.max) == 8,
              "Extreme persisted oversampling factors must clamp without integer overflow.")

    for rate in [Float(44_100), Float(48_000)] {
        for freq in frequenciesHz {
            let signal = stereoSine(freq: freq, rate: rate, frames: inputFrames, amplitude: 0.8)
            for factor in factors {
                for mode in modes {
                    let out = try oversample(engine: engine, input: signal,
                                             inputFrames: inputFrames,
                                             factor: factor, mode: mode, headroomGain: 1.0)
                    try check(out.count == inputFrames * factor * 2,
                              "\(rate/1000)k \(freq)Hz \(factor)x \(mode) length \(out.count) != \(inputFrames * factor * 2).")
                    for value in out {
                        try check(value.isFinite,
                                  "\(rate/1000)k \(freq)Hz \(factor)x non-finite output \(value).")
                    }
                }
            }
        }
        // Near-Nyquist input (0.49·fs): must stay finite even though the filter
        // attenuates heavily near the band edge.
        let nearNyq = stereoSine(freq: rate * 0.49, rate: rate, frames: inputFrames, amplitude: 0.9)
        for factor in factors {
            let out = try oversample(engine: engine, input: nearNyq, inputFrames: inputFrames,
                                     factor: factor, mode: .linearPhaseLong, headroomGain: 1.0)
            for value in out where !value.isFinite {
                try check(false, "\(rate/1000)k near-Nyquist \(factor)x non-finite \(value).")
            }
        }
    }

    // Swept sine 20 Hz -> ~18 kHz: exercises a continuum of frequencies; must
    // remain finite end to end.
    let sweep = stereoSweptSine(rate: 44_100, frames: inputFrames,
                                f0: 20, f1: 18_000, amplitude: 0.7)
    for factor in factors {
        let out = try oversample(engine: engine, input: sweep, inputFrames: inputFrames,
                                 factor: factor, mode: .linearPhaseLong, headroomGain: 1.0)
        for value in out where !value.isFinite {
            try check(false, "Swept sine \(factor)x non-finite \(value).")
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 2 — Interpolator correctness: DC unity-gain + passband preservation
    // ─────────────────────────────────────────────────────────────────────
    // A correct L-fold interpolator must pass a constant input through unchanged
    // (unity DC gain, no ripple). We measure the STEADY STATE only — the first
    // taps·factor output samples are the startup transient (history starts at 0,
    // so the FIR sees a 0→1 step and rings briefly before settling). After the
    // per-phase DC normalization the steady-state output is flat at ~1.0.
    for factor in factors {
        let dc = stereoDC(frames: inputFrames, amplitude: 1.0)
        let out = try oversample(engine: engine, input: dc, inputFrames: inputFrames,
                                 factor: factor, mode: .linearPhaseLong, headroomGain: 1.0)
        let skip = ResamplingFilterMode.linearPhaseLong.tapsPerPhase * factor * 2
        let steady = out.dropFirst(skip)
        let lo = steady.reduce(Float.infinity, { min($0, $1) })
        let hi = steady.reduce(-Float.infinity, { max($0, $1) })
        try check(hi - lo < 1e-4,
                  "DC \(factor)x not flat in steady state (ripple \(hi - lo)); per-phase normalization failed.")
        let mid = (lo + hi) * 0.5
        try check(abs(mid - 1.0) < 0.02,
                  "DC \(factor)x steady-state gain \(mid) != 1.0 (unity gain broken).")
    }

    // Passband preservation: a tone well inside the passband (1 kHz) must keep
    // its amplitude after oversampling (within 15%). This confirms the filter
    // does not attenuate in-band content.
    for rate in [Float(44_100), Float(48_000)] {
        let tone = stereoSine(freq: 1_000, rate: rate, frames: inputFrames, amplitude: 0.8)
        for factor in factors {
            let out = try oversample(engine: engine, input: tone, inputFrames: inputFrames,
                                     factor: factor, mode: .linearPhaseLong, headroomGain: 1.0)
            // Skip the first/last `taps` edge region (FIR transient) before measuring.
            let taps = ResamplingFilterMode.linearPhaseLong.tapsPerPhase
            let start = taps * factor
            let end = out.count - taps * factor
            var peak: Float = 0
            for i in (start..<end) where out[i].isFinite { peak = max(peak, abs(out[i])) }
            try check(peak > 0.68 && peak < 0.92,
                      "\(rate/1000)k 1kHz \(factor)x passband peak \(peak) outside [0.68, 0.92]; amplitude not preserved.")
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 3 — Impulse response: finite + symmetric (linear-phase) + located
    // ─────────────────────────────────────────────────────────────────────
    let impulseCenter = inputFrames / 2
    let impulse = stereoImpulse(frames: inputFrames, center: impulseCenter, amplitude: 1.0)
    for factor in factors {
        let out = try oversample(engine: engine, input: impulse, inputFrames: inputFrames,
                                 factor: factor, mode: .linearPhaseLong, headroomGain: 1.0)
        for value in out where !value.isFinite {
            try check(false, "Impulse \(factor)x non-finite \(value).")
        }
        // Peak must land within the filter's group delay of the impulse position.
        let expectedPeakFrame = impulseCenter * factor
        var peakIndex = 0
        var peakValue: Float = -1
        for i in 0..<(out.count / 2) {
            let v = abs(out[i * 2])
            if v > peakValue { peakValue = v; peakIndex = i }
        }
        let groupDelay = ResamplingFilterMode.linearPhaseLong.tapsPerPhase * factor
        try check(abs(peakIndex - expectedPeakFrame) <= groupDelay,
                  "Impulse \(factor)x peak at output frame \(peakIndex), expected near \(expectedPeakFrame) (±\(groupDelay)).")
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 4 — Kernel equivalence: vDSP and direct dot products match
    // ─────────────────────────────────────────────────────────────────────
    // Both kernels compute the same polyphase dot product; outputs must agree to
    // floating-point tolerance. This proves the `.direct` baseline is a faithful
    // reference and that the structure is not hard-dependent on Accelerate.
    let resampler = PCMResampler(channels: 2, maxInputFrames: inputFrames)
    var inL = [Float](repeating: 0, count: inputFrames)
    var inR = [Float](repeating: 0, count: inputFrames)
    for i in 0..<inputFrames {
        inL[i] = sine44[i * 2]
        inR[i] = sine44[i * 2 + 1]
    }
    for factor in factors {
        var outV = [Float](repeating: 0, count: inputFrames * factor)
        var outD = [Float](repeating: 0, count: inputFrames * factor)
        outV.withUnsafeMutableBufferPointer { ov in
            outD.withUnsafeMutableBufferPointer { od in
                inL.withUnsafeBufferPointer { ip in
                    // Reset the per-channel FIR history before each call so both
                    // kernels see the identical [zeros | input] window; otherwise
                    // the second call inherits the first's history and diverges.
                    resampler.reset(channel: 0)
                    _ = resampler.process(input: ip.baseAddress!, inputFrames: inputFrames,
                                          output: ov.baseAddress!, channel: 0,
                                          factor: factor, mode: .linearPhaseLong, kernel: .vDSP)
                    resampler.reset(channel: 0)
                    _ = resampler.process(input: ip.baseAddress!, inputFrames: inputFrames,
                                          output: od.baseAddress!, channel: 0,
                                          factor: factor, mode: .linearPhaseLong, kernel: .direct)
                }
            }
        }
        var maxDelta: Float = 0
        for i in 0..<outV.count { maxDelta = max(maxDelta, abs(outV[i] - outD[i])) }
        try check(maxDelta < 1e-5,
                  "vDSP vs direct \(factor)x output delta \(maxDelta) exceeds tolerance.")
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 5 — Live path: bypass cases are identity; 2× is rate-changing
    // ─────────────────────────────────────────────────────────────────────
    // The live path must be a verbatim identity copy for every configuration that
    // is NOT enabled + pcmOversampling + 2×: disabled, bypass, dither, and
    // pcmOversampling at 4×/8× (live allows 2× only). Only the 2× configuration
    // produces a 2× output — that is exercised in Section 5b below.
    try checkProcessLiveIdentity(engine: engine, reference: sine44, inputFrames: inputFrames,
                                 enabled: false, mode: .bypass, factor: 2, label: "disabled")
    try checkProcessLiveIdentity(engine: engine, reference: sine44, inputFrames: inputFrames,
                                 enabled: true, mode: .bypass, factor: 2, label: "enabled+bypass")
    try checkProcessLiveIdentity(engine: engine, reference: sine44, inputFrames: inputFrames,
                                 enabled: true, mode: .pcmOversampling, factor: 4, label: "enabled+4x(live=2x-only)")
    try checkProcessLiveIdentity(engine: engine, reference: sine44, inputFrames: inputFrames,
                                 enabled: true, mode: .pcmOversampling, factor: 8, label: "enabled+8x(live=2x-only)")
    try checkProcessLiveIdentity(engine: engine, reference: sine44, inputFrames: inputFrames,
                                 enabled: true, mode: .pcmWithDither, factor: 2, label: "enabled+dither")

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 5b — Live PCM 2× oversampling: frame count doubles, finite, continuous
    // ─────────────────────────────────────────────────────────────────────
    var live2x = OutputConditioningParameters()
    live2x.isEnabled = true
    live2x.outputMode = .pcmOversampling
    live2x.oversamplingFactor = 2
    let out2x = processLiveCopy(engine: engine, settings: live2x,
                                input: sine44, inputFrames: inputFrames)
    // Output is exactly 2× the input frame count (interleaved stereo: frames·2·2).
    try check(out2x.count == inputFrames * 2 * 2,
              "Live 2× output length \(out2x.count) != \(inputFrames * 2 * 2).")
    for value in out2x where !value.isFinite {
        try check(false, "Live 2× non-finite output \(value).")
    }
    // It is a genuine 2× rate change, not an identity-length copy.
    try check(out2x.count != sine44.count,
              "Live 2× produced an identity-length output — it must double the frame count.")

    // State reset leaves the path finite and well-formed.
    engine.resetAll()
    let out2xAfterReset = processLiveCopy(engine: engine, settings: live2x,
                                          input: sine44, inputFrames: inputFrames)
    try check(out2xAfterReset.count == inputFrames * 2 * 2,
              "Live 2× post-reset length \(out2xAfterReset.count) mismatch.")
    for value in out2xAfterReset where !value.isFinite {
        try check(false, "Live 2× post-reset non-finite \(value).")
    }

    // Block-split continuity: two consecutive half-blocks (no reset between them)
    // must match the whole-block output in steady state — the FIR history carries
    // across calls, so splitting must not change the result.
    engine.resetAll()
    let whole2x = processLiveCopy(engine: engine, settings: live2x,
                                  input: sine44, inputFrames: inputFrames)
    engine.resetAll()
    let half = inputFrames / 2
    var aHalf = [Float](repeating: 0, count: half * 2)
    var bHalf = [Float](repeating: 0, count: half * 2)
    for i in 0..<(half * 2) { aHalf[i] = sine44[i] }
    for i in 0..<(half * 2) { bHalf[i] = sine44[half * 2 + i] }
    let partA2x = processLiveCopy(engine: engine, settings: live2x,
                                  input: aHalf, inputFrames: half)
    let partB2x = processLiveCopy(engine: engine, settings: live2x,
                                  input: bHalf, inputFrames: half)
    try check(partA2x.count == half * 2 * 2 && partB2x.count == half * 2 * 2,
              "Live 2× split length mismatch: \(partA2x.count), \(partB2x.count).")
    let joined2x = partA2x + partB2x
    try check(joined2x.count == whole2x.count,
              "Live 2× split-join length \(joined2x.count) != whole \(whole2x.count).")
    // Compare past the startup transient (taps·2 output frames per channel).
    let transient = ResamplingFilterMode.linearPhaseShort.tapsPerPhase * 2 * 2
    var maxDelta: Float = 0
    for i in (transient..<whole2x.count) {
        maxDelta = max(maxDelta, abs(joined2x[i] - whole2x[i]))
    }
    try check(maxDelta < 1e-5,
              "Live 2× block-split delta \(maxDelta) exceeds tolerance (history broken).")

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 6 — Headroom gain accuracy (-3 dB ≈ 0.7079)
    // ─────────────────────────────────────────────────────────────────────
    var headroomParams = OutputConditioningParameters()
    headroomParams.headroomDB = -3.0
    try check(abs(headroomParams.headroomGain - 0.707945784) < 1e-4,
              "-3 dB headroom gain \(headroomParams.headroomGain) != 0.7079.")
    var tone = sine44
    let peakBefore = tone.maxAbs()
    tone.withUnsafeMutableBufferPointer { ptr in
        _ = engine.applyHeadroomInPlace(interleaved: ptr.baseAddress!,
                                        frames: inputFrames,
                                        headroomGain: headroomParams.headroomGain)
    }
    let peakAfter = tone.maxAbs()
    try check(abs(peakAfter - peakBefore * headroomParams.headroomGain) < 1e-4,
              "Headroom gain misapplied: peak \(peakBefore) -> \(peakAfter), expected \(peakBefore * headroomParams.headroomGain).")

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 7 — Block-boundary continuity for every factor (2 / 4 / 8)
    // ─────────────────────────────────────────────────────────────────────
    // Oversampling one whole block must equal two consecutive half-blocks with no
    // reset between them — proves the per-channel FIR history carries over.
    for factor in factors {
        engine.resetAll()
        let whole = try oversample(engine: engine, input: sine44, inputFrames: inputFrames,
                                   factor: factor, mode: .linearPhaseLong, headroomGain: 1.0)
        engine.resetAll()
        let half = inputFrames / 2
        var a = [Float](repeating: 0, count: half * 2)
        var b = [Float](repeating: 0, count: half * 2)
        for i in 0..<(half * 2) { a[i] = sine44[i] }
        for i in 0..<(half * 2) { b[i] = sine44[half * 2 + i] }
        let partA = try oversample(engine: engine, input: a, inputFrames: half,
                                   factor: factor, mode: .linearPhaseLong, headroomGain: 1.0)
        let partB = try oversample(engine: engine, input: b, inputFrames: half,
                                   factor: factor, mode: .linearPhaseLong, headroomGain: 1.0)
        try check(partA.count + partB.count == whole.count,
                  "\(factor)x split length \(partA.count + partB.count) != whole \(whole.count).")
        var maxDelta: Float = 0
        for i in 0..<whole.count {
            let split = i < partA.count ? partA[i] : partB[i - partA.count]
            maxDelta = max(maxDelta, abs(split - whole[i]))
        }
        try check(maxDelta < 1e-5,
                  "\(factor)x block-boundary delta \(maxDelta) exceeds tolerance (history broken).")
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 8 — DSD modulator stability across input classes
    // ─────────────────────────────────────────────────────────────────────
    // DC, full-scale sine, digital silence and hard-clipped input must all yield
    // a strictly 1-bit stream, finite, and keep the modulator state bounded by
    // the overload guard.
    let dsdFactor = 4
    let dsdFrames = inputFrames * dsdFactor
    let stabilityInputs: [(label: String, signal: [Float])] = [
        ("DC +1.0", stereoDC(frames: inputFrames, amplitude: 1.0)),
        ("DC -1.0", stereoDC(frames: inputFrames, amplitude: -1.0)),
        ("full-scale 1kHz", stereoSine(freq: 1000, rate: 44_100, frames: inputFrames, amplitude: 1.0)),
        ("silence", [Float](repeating: 0, count: inputFrames * 2)),
        ("clipped >+1", clippedSine(freq: 1000, rate: 44_100, frames: inputFrames, amplitude: 5.0)),
        ("clipped <-1", clippedSine(freq: 1000, rate: 44_100, frames: inputFrames, amplitude: -5.0))
    ]
    let limit = engine.modulatorOverloadLimit()
    for testCase in stabilityInputs {
        engine.resetAll()
        let (left, right, _, _) = try dsdProcess(engine: engine, input: testCase.signal,
                                                     inputFrames: inputFrames, factor: dsdFactor,
                                                     dsdMode: .dsd64, order: .second,
                                                     headroomGain: 0.708)
        try check(left.count == dsdFrames && right.count == dsdFrames,
                  "\(testCase.label) DSD frame count mismatch.")
        for byte in left where byte > 1 { try check(false, "\(testCase.label) left non-1-bit \(byte).") }
        for byte in right where byte > 1 { try check(false, "\(testCase.label) right non-1-bit \(byte).") }
        // DoP bytes are UInt8 (always representable); marker/interleave checks
        // are covered in Section 9.
        let stateMag = engine.modulatorMaxStateMagnitude()
        try check(stateMag.isFinite && stateMag <= limit + 0.001,
                  "\(testCase.label) modulator state \(stateMag) exceeds overload limit \(limit); guard failed.")
    }

    // Both modulator orders must remain stable on a full-scale tone.
    for order in [DeltaSigmaDSDModulator.Order.first, .second] {
        engine.resetAll()
        let (left, _, _, _) = try dsdProcess(engine: engine,
                                             input: stereoSine(freq: 1000, rate: 44_100,
                                                               frames: inputFrames, amplitude: 1.0),
                                             inputFrames: inputFrames, factor: dsdFactor,
                                             dsdMode: .dsd64, order: order, headroomGain: 0.708)
        for byte in left where byte > 1 { try check(false, "order \(order) non-1-bit \(byte).") }
        try check(engine.modulatorMaxStateMagnitude() <= limit + 0.001,
                  "order \(order) modulator state unbounded.")
    }

    // Overload guard is actually EXERCISED (not just inertly stable): seed an
    // over-threshold modulator state on both channels, then process. The guard
    // must fire (reset counter > 0) and the state must recover to within the
    // limit. Without this, a removed guard would still pass the checks above.
    engine.resetAll()
    engine.resetModulatorOverloadCounters()
    engine.seedModulatorState(channel: 0, e1: 100, e2: 80)
    engine.seedModulatorState(channel: 1, e1: -90, e2: 70)
    let guardSignal = stereoSine(freq: 1000, rate: 44_100, frames: 256, amplitude: 0.8)
    let (gL, _, _, _) = try dsdProcess(engine: engine, input: guardSignal, inputFrames: 256,
                                       factor: dsdFactor, dsdMode: .dsd64, order: .second,
                                       headroomGain: 0.708)
    let resets = engine.modulatorOverloadResets()
    try check(resets >= 2,
              "Overload guard never fired (resets=\(resets)); seeded |e|~100 should trip the >\(Int(limit)) threshold.")
    for byte in gL where byte > 1 { try check(false, "post-overload left non-1-bit \(byte).") }
    try check(engine.modulatorMaxStateMagnitude() <= limit + 0.001,
              "Modulator state unbounded after overload recovery: \(engine.modulatorMaxStateMagnitude()).")

    // DoP transport is checked against fixed standard-derived words, separately
    // from the PCM-to-PDM modulator. A successful self-generated round trip
    // alone cannot establish protocol compatibility.
    try checkDoPKnownVectorsAndStreaming()
    engine.resetAll()
    let (_, _, dopBytes, dop) = try dsdProcess(engine: engine, input: sine44,
                                              inputFrames: inputFrames,
                                              factor: dsdFactor, dsdMode: .dsd64,
                                              order: .second, headroomGain: 0.708)
    let inspected = dop.withUnsafeBufferPointer { ptr in
        engine.verifyDoPMarkers(output: ptr.baseAddress!, byteCount: dopBytes)
    }
    try check(inspected == dsdFrames / 16,
              "DoP pipeline must emit one carrier per 16 DSD bits.")

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 10 — DoP carrier-rate + DSD clock-rate math
    // ─────────────────────────────────────────────────────────────────────
    try check(DoPCarrier.requiredCarrierRate(for: .dsd64) == 176_400, "DSD64 carrier rate.")
    try check(DoPCarrier.requiredCarrierRate(for: .dsd128) == 352_800, "DSD128 carrier rate.")
    try check(DoPCarrier.requiredCarrierRate(for: .dsd256) == 705_600, "DSD256 carrier rate.")
    try check(DoPCarrier.requiredCarrierRate(for: .off) == 0, "DSD off carrier rate.")
    try check(DSDMode.dsd64.bitStreamRate == 2_822_400, "DSD64 bit-stream rate.")
    try check(DSDMode.dsd128.bitStreamRate == 5_644_800, "DSD128 bit-stream rate.")
    try check(DSDMode.dsd256.bitStreamRate == 11_289_600, "DSD256 bit-stream rate.")

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 11 — Capability gating logic (drives UI enablement / PCM fallback)
    // ─────────────────────────────────────────────────────────────────────
    // canAttemptDoP must require BOTH the carrier rate AND a wide carrier bit
    // depth; an unsupported DAC must report no DSD family as attemptable, which
    // is exactly the condition that disables the DSD popup in the UI.
    let fullyCapable = OutputConditioningCapability(
        supportedCarriers: [.off: true, .dsd64: true, .dsd128: true, .dsd256: true],
        supportsWideCarrierBitDepth: true, supportedRates: [176_400, 352_800, 705_600],
        isRateSettable: true, deviceID: 1)
    try check(fullyCapable.canAttemptDoP(.dsd64) && fullyCapable.canAttemptDoP(.dsd256),
              "Fully capable DAC should attempt all DSD families.")
    try check(!fullyCapable.canAttemptDoP(.off), ".off must never be attemptable.")

    let rateOnly = OutputConditioningCapability(
        supportedCarriers: [.off: true, .dsd64: true, .dsd128: false, .dsd256: false],
        supportsWideCarrierBitDepth: false, supportedRates: [176_400],
        isRateSettable: false, deviceID: 2)
    try check(!rateOnly.canAttemptDoP(.dsd64),
              "Carrier rate alone (no 24/32-bit carrier) must NOT be attemptable.")

    let unsupportedDAC = OutputConditioningCapability.unknown(deviceID: 3)
    try check([DSDMode.dsd64, .dsd128, .dsd256].allSatisfy { !unsupportedDAC.canAttemptDoP($0) },
              "Unknown/unsupported DAC must report no DSD family attemptable (UI disables DSD → PCM fallback).")

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 12 — Real-time structure: bypass copies verbatim; 2× is deterministic
    // ─────────────────────────────────────────────────────────────────────
    // The bypass path is a plain copy — output equals input every call. The 2×
    // path is deterministic given a fixed state: two runs from a reset state on
    // the same input must be bit-identical (no hidden nondeterminism).
    engine.updateSettings(OutputConditioningParameters())  // bypass
    var bypassOut = [Float](repeating: 0, count: inputFrames * 2 * 2)
    let bypassFrames = sine44.withUnsafeBufferPointer { ip in
        bypassOut.withUnsafeMutableBufferPointer { op in
            engine.processLive(input: ip.baseAddress!, inputFrames: inputFrames,
                               output: op.baseAddress!)
        }
    }
    try check(bypassFrames == inputFrames,
              "Bypass processLive returned \(bypassFrames) frames, expected \(inputFrames).")
    try check(Array(bypassOut.prefix(inputFrames * 2)) == sine44,
              "Bypass processLive did not copy the input verbatim.")

    engine.resetAll()
    let run1 = processLiveCopy(engine: engine, settings: live2x,
                               input: sine44, inputFrames: inputFrames)
    engine.resetAll()
    let run2 = processLiveCopy(engine: engine, settings: live2x,
                               input: sine44, inputFrames: inputFrames)
    try check(run1 == run2,
              "Live 2× is not deterministic across identical reset runs (hidden nondeterminism).")

    // ─────────────────────────────────────────────────────────────────────
    // Benchmark (informational; offline only — never runs on the audio thread)
    // ─────────────────────────────────────────────────────────────────────
    // Run runOutputConditioningBenchmark() explicitly for timing measurements.
    try checkFilterSwitchHistoryAndCrossfade()

    // ─────────────────────────────────────────────────────────────────────
    // SECTION 13 — Image rejection / stopband attenuation (offline FFT)
    // ─────────────────────────────────────────────────────────────────────
    // Quantitative check that the polyphase FIR suppresses the upsampling
    // images. Offline only — the audio callback never runs FFT/measurement.
    try measureImageRejection(engine: engine)

    print("Output conditioning checks passed: resampler finite (44.1k/48k × 1/10/18/20k × 2/4/8 "
          + "+ near-Nyquist + swept), DC unity + passband + impulse, vDSP==direct, "
          + "bypass==identity (disabled/bypass/dither/4x/8x), live PCM 2× frame-doubling + finite "
          + "+ deterministic + block-split continuity, headroom, offline block continuity 2/4/8, "
          + "DSD stable (DC/sine/silence/clipped, 1st+2nd order, overload guard verified to fire), "
          + "DoP known vectors+all bit splits+markers, filter switching+crossfade, "
          + "carrier math, capability gating, calibrated FFT image rejection.")
}

// MARK: - Signal generators

private func stereoSine(freq: Float, rate: Float, frames: Int, amplitude: Float) -> [Float] {
    var out = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let s = sin(2.0 * Float.pi * freq * Float(i) / rate) * amplitude
        out[i * 2] = s
        out[i * 2 + 1] = s
    }
    return out
}

private func stereoSweptSine(rate: Float, frames: Int, f0: Float, f1: Float, amplitude: Float) -> [Float] {
    var out = [Float](repeating: 0, count: frames * 2)
    let k = pow(f1 / f0, 1.0 / Float(max(frames - 1, 1)))
    var phase: Float = 0
    var freq = f0
    let twoPi = 2.0 * Float.pi
    for i in 0..<frames {
        let s = sin(phase) * amplitude
        out[i * 2] = s
        out[i * 2 + 1] = s
        phase += twoPi * freq / rate
        freq *= k
    }
    return out
}

private func stereoDC(frames: Int, amplitude: Float) -> [Float] {
    [Float](repeating: amplitude, count: frames * 2)
}

private func stereoImpulse(frames: Int, center: Int, amplitude: Float) -> [Float] {
    var out = [Float](repeating: 0, count: frames * 2)
    let c = max(0, min(frames - 1, center))
    out[c * 2] = amplitude
    out[c * 2 + 1] = amplitude
    return out
}

/// A sine clipped to [-1, 1] (amplitude > 1 exercises the modulator's input clamp).
private func clippedSine(freq: Float, rate: Float, frames: Int, amplitude: Float) -> [Float] {
    var out = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        var s = sin(2.0 * Float.pi * freq * Float(i) / rate) * amplitude
        if s > 1 { s = 1 } else if s < -1 { s = -1 }
        out[i * 2] = s
        out[i * 2 + 1] = s
    }
    return out
}

// MARK: - Engine helpers

private func oversample(engine: ResamplingOutputConditioningEngine,
                        input: [Float],
                        inputFrames: Int,
                        factor: Int,
                        mode: ResamplingFilterMode,
                        headroomGain: Float) throws -> [Float] {
    var output = [Float](repeating: 0, count: inputFrames * factor * 2)
    let written = input.withUnsafeBufferPointer { inPtr in
        output.withUnsafeMutableBufferPointer { outPtr in
            engine.oversampleStereoInterleaved(
                input: inPtr.baseAddress!,
                inputFrames: inputFrames,
                output: outPtr.baseAddress!,
                factor: factor,
                mode: mode,
                headroomGain: headroomGain
            )
        }
    }
    try check(written == inputFrames * factor,
              "Oversample wrote \(written) frames, expected \(inputFrames * factor).")
    return output
}

/// Run the full PCM → oversample → delta-sigma → DoP pipeline and return the
/// per-channel 1-bit streams plus the packed DoP bytes.
private func dsdProcess(engine: ResamplingOutputConditioningEngine,
                        input: [Float],
                        inputFrames: Int,
                        factor: Int,
                        dsdMode: DSDMode,
                        order: DeltaSigmaDSDModulator.Order,
                        headroomGain: Float) throws
    -> (left: [UInt8], right: [UInt8], dopBytes: Int, dop: [UInt8]) {
    let dsdFrames = inputFrames * factor
    var left = [UInt8](repeating: 0, count: dsdFrames)
    var right = [UInt8](repeating: 0, count: dsdFrames)
    let dopByteCount = engine.requiredDoPOutputBytes(dsdFrames: dsdFrames)
    var dop = [UInt8](repeating: 0, count: max(1, dopByteCount))
    let result = input.withUnsafeBufferPointer { inPtr in
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                dop.withUnsafeMutableBufferPointer { d in
                    engine.processDSDToP(
                        interleaved: inPtr.baseAddress!,
                        inputFrames: inputFrames,
                        factor: factor,
                        mode: .linearPhaseShort,
                        dsdMode: dsdMode,
                        modulatorOrder: order,
                        headroomGain: headroomGain,
                        leftDsdBits: l.baseAddress!,
                        rightDsdBits: r.baseAddress!,
                        dopOutput: d.baseAddress!
                    )
                }
            }
        }
    }
    try check(result.dsdFrames == dsdFrames && result.dopBytes == dopByteCount,
              "DSD path returned \(result), expected (\(dsdFrames), \(dopByteCount)).")
    return (left, right, result.dopBytes, Array(dop.prefix(result.dopBytes)))
}

private func processLiveCopy(engine: ResamplingOutputConditioningEngine,
                             settings: OutputConditioningParameters,
                             input: [Float],
                             inputFrames: Int) -> [Float] {
    engine.updateSettings(settings)
    // 2× headroom so the buffer always holds the largest possible output.
    var output = [Float](repeating: 0, count: inputFrames * 2 * 2)
    let frames = input.withUnsafeBufferPointer { ip in
        output.withUnsafeMutableBufferPointer { op in
            engine.processLive(input: ip.baseAddress!,
                               inputFrames: inputFrames,
                               output: op.baseAddress!)
        }
    }
    return Array(output.prefix(frames * 2))
}

private func checkProcessLiveIdentity(engine: ResamplingOutputConditioningEngine,
                                      reference: [Float],
                                      inputFrames: Int,
                                      enabled: Bool,
                                      mode: OutputConditioningMode,
                                      factor: Int,
                                      label: String) throws {
    var params = OutputConditioningParameters()
    params.isEnabled = enabled
    params.outputMode = mode
    params.oversamplingFactor = factor
    let result = processLiveCopy(engine: engine, settings: params,
                                 input: reference, inputFrames: inputFrames)
    try check(result == reference,
              "processLive (\(label)) was not identity — len \(result.count) vs \(reference.count).")
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw AppError.message(message) }
}

private extension Array where Element == Float {
    /// Maximum absolute finite sample value (NaN/Inf ignored). Returns
    /// `fallback` when no finite sample is present.
    func maxAbs(fallback: Float = 0) -> Float {
        var peak: Float = -1
        var found = false
        for value in self where value.isFinite {
            let magnitude = abs(value)
            if !found || magnitude > peak {
                peak = magnitude
                found = true
            }
        }
        return found ? peak : fallback
    }
}

// MARK: - Image rejection / stopband attenuation (offline FFT, vDSP)

/// Quantitative image-rejection verification of `PCMResampler`.
///
/// For an L-fold interpolator a tone at `f0` produces spectral images at
/// `k·fs ± f0` (k = 1…L-1) in the output band. The polyphase FIR must suppress
/// them. We oversample a pure tone, take a Hann-windowed steady-state slice,
/// run a real→complex vDSP FFT, and compare the fundamental peak (baseband) to
/// the strongest peak in the image band `(fs/2, Nyquist]`. Rejection is the
/// difference in dB.
///
/// Hard thresholds (best rejection over in-band tones 1/10/18 kHz):
///   linearPhaseShort ≥ 50 dB,  linearPhaseLong ≥ 70 dB.
/// If the current FIR cannot meet them, this throws (we do NOT silently lower
/// the bar) — the failure is reported and a coefficient change is proposed.
private func measureImageRejection(engine: ResamplingOutputConditioningEngine) throws {
    let fs: Float = 44_100
    let inputFrames = 4096
    let fftN = 4096
    let log2n = vDSP_Length(Int(log2(Double(fftN))))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        throw AppError.message("Could not create vDSP FFT setup for image-rejection test.")
    }
    defer { vDSP_destroy_fftsetup(setup) }

    engine.resetAll()
    let calibratedTone = fs * 2 * 64 / Float(fftN)
    let calibration = rejectionOf(engine: engine,
                                  signal: stereoSine(freq: calibratedTone, rate: fs,
                                                     frames: inputFrames, amplitude: 0.5),
                                  inputFrames: inputFrames, factor: 2, mode: .linearPhaseLong,
                                  fs: fs, f0: calibratedTone, setup: setup, fftN: fftN, guardBins: 3)
    try check(abs(calibration.fundDB - 20 * log10(Float(0.5))) < 0.05,
              "FFT coherent-gain calibration failed: 0.5 peak sine measured \(calibration.fundDB) dBFS.")

    let tones: [(label: String, f0: Float)] = [
        ("1kHz", 1_000), ("10kHz", 10_000), ("18kHz", 18_000),
        ("20kHz", 20_000), ("nearNyq", fs * 0.49)
    ]
    let factors = OutputConditioningParameters.allowedOversamplingFactors
    let inBand = Set(["1kHz", "10kHz", "18kHz"])
    // Bins excluded just above fs/2 to drop fundamental-skirt leakage from the
    // primary image measurement. 3 bins clears the Hann main-lobe skirt while
    // leaving real images measurable — including the near-Nyquist transition
    // image, which sits ~4.5/9/18 bins above fs/2 for 8x/4x/2x respectively (a
    // wider guard would wrongly swallow the 8x transition image and mislabel it
    // as "leakage").
    let guardBins = 3

    print("PCMResampler image rejection (offline \(fftN)-pt Hann FFT, \(Int(fs / 1000))k input, "
          + "guard \(guardBins) bins above fs/2):")
    // Collect per-cell rejection keyed by (mode, factor, tone) for the
    // minimumPhase-vs-short aliasing check.
    var rejByCell: [String: Float] = [:]   // key: "\(mode)|\(factor)|\(tone)"
    var minShort: Float = .infinity
    var minLong: Float = .infinity
    var minMinPhase: Float = .infinity
    var fundamentalPositionFailures = 0
    let measuredModes: [ResamplingFilterMode] = [.linearPhaseShort, .linearPhaseLong, .minimumPhaseExperimental]
    for mode in measuredModes {
        let name: String
        switch mode {
        case .linearPhaseShort: name = "short"
        case .linearPhaseLong: name = "long "
        case .minimumPhaseExperimental: name = "minPh"
        }
        for factor in factors {
            for tone in tones {
                engine.resetAll()
                let signal = stereoSine(freq: tone.f0, rate: fs, frames: inputFrames, amplitude: 0.9)
                let r = rejectionOf(engine: engine, signal: signal, inputFrames: inputFrames,
                                    factor: factor, mode: mode, fs: fs, f0: tone.f0,
                                    setup: setup, fftN: fftN, guardBins: guardBins)
                if inBand.contains(tone.label) && !r.fundBinOK {
                    fundamentalPositionFailures &+= 1
                }
                rejByCell["\(mode == .linearPhaseShort ? "short" : mode == .linearPhaseLong ? "long" : "minPh")|\(factor)|\(tone.label)"] = r.rejDB

                // near-Nyq: report raw vs guarded to make leakage vs real image explicit.
                let nearNote: String
                if tone.label == "nearNyq" {
                    let rawRej = r.fundDB - r.imageRawDB
                    if abs(rawRej - r.rejDB) > 3.0 {
                        nearNote = String(format: "  (raw %.1f dB — fundamental leakage)", rawRej)
                    } else {
                        nearNote = String(format: "  (raw %.1f dB — real transition image)", rawRej)
                    }
                } else {
                    nearNote = ""
                }
                let threshold = (mode == .linearPhaseLong) ? 70.0 : 50.0
                let pass = r.fundBinOK && r.rejDB >= Float(threshold)
                let tag = (pass || !inBand.contains(tone.label)) ? "" : "  ← below target"
                print(String(format: "  %dx %@ %@ fund %7.1f dBFS  image %7.1f dBFS  rejection %6.1f dB%@%@",
                             factor, name, tone.label, r.fundDB, r.imageGuardedDB, r.rejDB, nearNote, tag))
                if inBand.contains(tone.label) {
                    switch mode {
                    case .linearPhaseShort: minShort = min(minShort, r.rejDB)
                    case .linearPhaseLong: minLong = min(minLong, r.rejDB)
                    case .minimumPhaseExperimental: minMinPhase = min(minMinPhase, r.rejDB)
                    }
                }
            }
        }
    }

    // Swept-sine aggregate (20 Hz → 18 kHz): whole-spectrum baseband vs image peak.
    let sweep = stereoSweptSine(rate: fs, frames: inputFrames, f0: 20, f1: 18_000, amplitude: 0.8)
    for factor in factors {
        engine.resetAll()
        let r = rejectionOf(engine: engine, signal: sweep, inputFrames: inputFrames,
                            factor: factor, mode: .linearPhaseLong, fs: fs, f0: 0,
                            setup: setup, fftN: fftN, guardBins: guardBins)
        print(String(format: "  %dx long  swept   strongest image %7.1f dBFS vs baseband %7.1f dBFS  → %6.1f dB",
                     factor, r.imageGuardedDB, r.fundDB, r.rejDB))
    }

    // (1) Real fundamental-position check: the measured baseband peak bin must be
    // at f0 for every in-band tone (no longer a tautology).
    try check(fundamentalPositionFailures == 0,
              "Fundamental peak not at f0 for \(fundamentalPositionFailures) in-band tone cells.")
    // (3) minimumPhaseExperimental must reproduce linearPhaseShort exactly
    // (same coefficient set, by aliasing) — verify per in-band cell.
    var aliasMismatches = 0
    for factor in factors {
        for tone in tones where inBand.contains(tone.label) {
            let s = rejByCell["short|\(factor)|\(tone.label)"] ?? -.infinity
            let m = rejByCell["minPh|\(factor)|\(tone.label)"] ?? -.infinity
            if abs(s - m) > 0.5 { aliasMismatches &+= 1 }
        }
    }
    try check(aliasMismatches == 0,
              "minimumPhaseExperimental differs from linearPhaseShort in \(aliasMismatches) cells (aliasing broken).")
    // Stopband floor: the WORST in-band rejection must still clear the target.
    try check(minShort >= 50.0,
              "linearPhaseShort worst in-band image rejection \(minShort) dB < 50 dB target.")
    try check(minLong >= 70.0,
              "linearPhaseLong worst in-band image rejection \(minLong) dB < 70 dB target.")
    try check(minMinPhase >= 50.0,
              "minimumPhaseExperimental worst in-band image rejection \(minMinPhase) dB < 50 dB target.")
    print(String(format: "  → in-band stopband floor (min over 1/10/18k): short %.1f, long %.1f, minPhase %.1f dB "
                 + "(targets 50/70/50). minPhase verified == short (aliasing). "
                 + "20k/near-Nyq are report-only (transition-band limit).",
                 minShort, minLong, minMinPhase))
}

/// One image-rejection measurement: oversample `signal`, FFT the steady-state
/// left channel, return fundamental level, guarded + raw image levels, rejection,
/// and whether the actual fundamental peak landed at f0 (non-tautological).
///
/// `guardBins` excludes the `guardBins` immediately above fs/2 from the primary
/// image search, removing fundamental-skirt leakage at the band edge. The raw
/// (unguarded) image is also returned so callers can tell a real transition-band
/// image (raw ≈ guarded) from fundamental leakage (raw ≫ guarded).
private func rejectionOf(engine: ResamplingOutputConditioningEngine,
                         signal: [Float],
                         inputFrames: Int,
                         factor: Int,
                         mode: ResamplingFilterMode,
                         fs: Float,
                         f0: Float,
                         setup: FFTSetup,
                         fftN: Int,
                         guardBins: Int)
    -> (fundDB: Float, imageGuardedDB: Float, imageRawDB: Float,
        rejDB: Float, fundBinOK: Bool) {
    guard let out = try? oversample(engine: engine, input: signal, inputFrames: inputFrames,
                                    factor: factor, mode: mode, headroomGain: 1.0),
          out.count == inputFrames * factor * 2 else {
        return (-200, -200, -200, 0, false)
    }
    let outFrames = inputFrames * factor
    let transient = mode.tapsPerPhase * factor + factor
    guard outFrames - transient >= fftN else { return (-200, -200, -200, 0, false) }

    // Left channel steady-state slice, Hann-windowed.
    var windowed = [Float](repeating: 0, count: fftN)
    var hann = [Float](repeating: 0, count: fftN)
    vDSP_hann_window(&hann, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
    for i in 0..<fftN {
        windowed[i] = out[(transient + i) * 2] * hann[i]
    }

    // Real→complex FFT (imag input = 0) via vDSP_fft_zop on a DSPSplitComplex.
    var realIn = windowed
    var imagIn = [Float](repeating: 0, count: fftN)
    var realOut = [Float](repeating: 0, count: fftN)
    var imagOut = [Float](repeating: 0, count: fftN)
    let log2n = vDSP_Length(Int(log2(Double(fftN))))
    realIn.withUnsafeMutableBufferPointer { ri in
    imagIn.withUnsafeMutableBufferPointer { ii in
    realOut.withUnsafeMutableBufferPointer { ro in
    imagOut.withUnsafeMutableBufferPointer { io in
        var inSC = DSPSplitComplex(realp: ri.baseAddress!, imagp: ii.baseAddress!)
        var outSC = DSPSplitComplex(realp: ro.baseAddress!, imagp: io.baseAddress!)
        vDSP_fft_zop(setup, &inSC, 1, &outSC, 1, log2n, FFTDirection(FFT_FORWARD))
    }}}}

    let halfN = fftN / 2
    var mag = [Float](repeating: 0, count: halfN + 1)
    for b in 0...halfN {
        mag[b] = sqrt(realOut[b] * realOut[b] + imagOut[b] * imagOut[b])
    }

    let binWidth = (fs * Float(factor)) / Float(fftN)     // Hz/bin at output rate L·fs
    let expectedFundBin = Int(round(f0 / binWidth))
    let basebandEdgeBin = max(1, Int(round((fs / 2) / binWidth))) // = fftN/(2·factor)

    // Actual baseband peak: scan [1, fs/2) for the strongest bin (the fundamental
    // for a clean tone). This makes the position check NON-tautological — it
    // compares the measured peak bin against the expected f0 bin, not f0 to itself.
    var fundPeak: Float = 0
    var actualPeakBin = 1
    for b in 1..<basebandEdgeBin {
        if mag[b] > fundPeak { fundPeak = mag[b]; actualPeakBin = b }
    }
    let fundBinOK = f0 <= 0 || abs(actualPeakBin - expectedFundBin) <= 2

    // Image peaks. Raw includes the whole image band [fs/2, Nyquist]; guarded
    // skips `guardBins` just above fs/2 to drop fundamental-skirt leakage.
    var imageRawPeak: Float = 0
    for b in basebandEdgeBin...halfN { imageRawPeak = max(imageRawPeak, mag[b]) }
    var imageGuardedPeak: Float = 0
    let guardedStart = min(halfN, basebandEdgeBin + guardBins)
    for b in guardedStart...halfN { imageGuardedPeak = max(imageGuardedPeak, mag[b]) }

    let amplitudeScale: Float = 2 / hann.reduce(0, +)
    let toDB: (Float) -> Float = { 20 * log10(max($0 * amplitudeScale, 1e-12)) }
    let fundDB = toDB(fundPeak)
    let imageGuardedDB = toDB(imageGuardedPeak)
    let imageRawDB = toDB(imageRawPeak)
    return (fundDB, imageGuardedDB, imageRawDB, fundDB - imageGuardedDB, fundBinOK)
}

// MARK: - Offline benchmark (informational only; never invoked from the audio thread)

/// Measures 2-channel `PCMResampler.process` throughput at block sizes
/// 32 / 64 / 128 / 256 for both the `.vDSP` and `.direct` kernels. Results are
/// printed; nothing is asserted. This is the ONLY place timing is collected —
/// the real-time audio callback contains no timing/logging.
func runOutputConditioningBenchmark(iterations requestedIterations: Int = 2000) {
    let blockSizes = [32, 64, 128, 256]
    let factors = OutputConditioningParameters.allowedOversamplingFactors
    let iterations = max(1, min(requestedIterations, 20_000))
    let maxBlock = 256

    let resampler = PCMResampler(channels: 2, maxInputFrames: maxBlock)
    var inputL = [Float](repeating: 0, count: maxBlock)
    var inputR = [Float](repeating: 0, count: maxBlock)
    var out = [Float](repeating: 0, count: maxBlock * 8)
    for i in 0..<maxBlock {
        let s = sin(2.0 * Float.pi * 1000.0 * Float(i) / 44_100.0) * 0.8
        inputL[i] = s
        inputR[i] = s
    }

    print("PCMResampler 2ch offline benchmark (iterations=\(iterations), mode=linearPhaseLong):")
    inputL.withUnsafeBufferPointer { ipL in
    inputR.withUnsafeBufferPointer { ipR in
    out.withUnsafeMutableBufferPointer { op in
        for factor in factors {
            for kernel in [PCMResampler.Kernel.vDSP, .direct] {
                for bs in blockSizes {
                    let l = ipL.baseAddress!
                    let r = ipR.baseAddress!
                    let o = op.baseAddress!
                    // Warm up (history fill + caches).
                    _ = resampler.process(input: l, inputFrames: bs, output: o, channel: 0,
                                          factor: factor, mode: .linearPhaseLong, kernel: kernel)
                    _ = resampler.process(input: r, inputFrames: bs, output: o, channel: 1,
                                          factor: factor, mode: .linearPhaseLong, kernel: kernel)
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<iterations {
                        _ = resampler.process(input: l, inputFrames: bs, output: o, channel: 0,
                                              factor: factor, mode: .linearPhaseLong, kernel: kernel)
                        _ = resampler.process(input: r, inputFrames: bs, output: o, channel: 1,
                                              factor: factor, mode: .linearPhaseLong, kernel: kernel)
                    }
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0
                    let nsPerBlock = Double(elapsedNs) / Double(iterations)
                    let outSamples = bs * factor * 2
                    let nsPerOutSample = nsPerBlock / Double(outSamples)
                    let name = kernel == .vDSP ? "vDSP  " : "direct"
                    print(String(format: "  %dx %@ bs=%-3d  %8.1f ns/block  %6.2f ns/out-sample",
                                 factor, name, bs, nsPerBlock, nsPerOutSample))
                }
            }
        }
    }}}
}

// MARK: - Independent transport and transition regressions

private func checkDoPKnownVectorsAndStreaming() throws {
    // DoP 1.1 page 2 diagram: t0 (oldest bit) is bit 15 of the DSD word.
    // https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf
    // Encode three deliberately asymmetric words; expected bytes are literal,
    // not obtained by reusing the packer's shifts or marker-verifier logic.
    let left: [UInt8] = Array("100000000000000100010010101001011100001101011010").map { $0 == "1" ? 1 : 0 }
    let right: [UInt8] = Array("010000000000001010100101000000010011110001100101").map { $0 == "1" ? 1 : 0 }
    let stereo: [UInt8] = [0x01, 0x80, 0xFA, 0, 0x02, 0x40, 0xFA, 0,
                           0xA5, 0x12, 0x05, 0, 0x01, 0xA5, 0x05, 0,
                           0x5A, 0xC3, 0xFA, 0, 0x65, 0x3C, 0xFA, 0]
    let mono: [UInt8] = [0x01, 0x80, 0xFA, 0, 0xA5, 0x12, 0x05, 0, 0x5A, 0xC3, 0xFA, 0]

    func pack(_ packer: DoPacker, start: Int, count: Int,
              includeRight: Bool = true) throws -> [UInt8] {
        let predicted = packer.outputByteCount(forDsdFrames: count)
        // A sentinel detects writing beyond the exact advertised capacity,
        // including calls that retain only partial bits and emit no output.
        var out = [UInt8](repeating: 0xCC, count: predicted + 1)
        let written = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                out.withUnsafeMutableBufferPointer { d in
                    packer.pack(leftBits: l.baseAddress!.advanced(by: start),
                                rightBits: includeRight ? r.baseAddress!.advanced(by: start) : nil,
                                dsdFrames: count, output: d.baseAddress!)
                }
            }
        }
        try check(written == predicted, "DoP next-call capacity \(predicted) != written \(written).")
        try check(out[predicted] == 0xCC, "DoP wrote beyond its predicted output capacity.")
        return Array(out.prefix(written))
    }

    for (layout, expected) in [(DoPacker.ChannelLayout.mono, mono), (.stereo, stereo)] {
        let whole = DoPacker(channelLayout: layout)
        try check(try pack(whole, start: 0, count: 48) == expected,
                  "DoP independent known word/byte-order vector failed (\(layout)).")
        for split in 1..<48 {
            let splitPacker = DoPacker(channelLayout: layout)
            let a = try pack(splitPacker, start: 0, count: split)
            let b = try pack(splitPacker, start: split, count: 48 - split)
            try check(a + b == expected, "DoP changed at bit split \(split) (\(layout)).")
        }
        let singleBit = DoPacker(channelLayout: layout)
        var joined: [UInt8] = []
        for bit in 0..<48 { joined += try pack(singleBit, start: bit, count: 1) }
        try check(joined == expected, "DoP one-bit chunks lost payload/marker state.")
        _ = try pack(singleBit, start: 0, count: 7)
        singleBit.reset()
        try check(try pack(singleBit, start: 0, count: 48) == expected,
                  "DoP reset must discard pending bits and restart marker phase.")
        try check(singleBit.outputByteCount(forDsdFrames: -1) == 0,
                  "Negative DoP size must be rejected.")
    }

    let invalid = DoPacker(channelLayout: .stereo)
    _ = try pack(invalid, start: 0, count: 7)
    var sink = [UInt8](repeating: 0xCC, count: 8)
    let rejected = left.withUnsafeBufferPointer { l in
        sink.withUnsafeMutableBufferPointer { d in
            invalid.pack(leftBits: l.baseAddress!, rightBits: nil, dsdFrames: 16, output: d.baseAddress!)
        }
    }
    try check(rejected == 0 && sink.allSatisfy { $0 == 0xCC },
              "Missing stereo right bits must fail without writing output.")
    try check(try pack(invalid, start: 7, count: 9) == Array(stereo.prefix(8)),
              "Invalid stereo call changed pending payload state.")

    let verifier = DoPacker(channelLayout: .stereo)
    try check(stereo.withUnsafeBufferPointer {
        verifier.verifyMarkers(output: $0.baseAddress!, byteCount: stereo.count, startingMarker: 0xFA)
    } == 3, "DoP known marker sequence failed.")
    var corrupt = stereo
    corrupt[10] = 0xFA  // Second carrier must switch to 0x05.
    try check(corrupt.withUnsafeBufferPointer {
        verifier.verifyMarkers(output: $0.baseAddress!, byteCount: corrupt.count)
    } == 0, "DoP marker verifier accepted a repeated marker.")
    try check(stereo.withUnsafeBufferPointer {
        verifier.verifyMarkers(output: $0.baseAddress!, byteCount: -8)
    } == 0, "DoP marker verifier must reject negative lengths.")
    for mode in [DSDMode.dsd64, .dsd128, .dsd256] {
        try check(DoPCarrier.requiredCarrierRate(for: mode) * 16 == mode.bitStreamRate,
                  "DoP carrier clock must transport 16 payload bits per frame.")
    }
}

private func checkFilterSwitchHistoryAndCrossfade() throws {
    let count = 512
    let signal = (0..<(count * 3)).map {
        Float(0.8 * sin(2 * Double.pi * 997 * Double($0) / 44_100))
    }
    func process(_ resampler: PCMResampler, start: Int, count: Int,
                 factor: Int, mode: ResamplingFilterMode, transition: Int = 0,
                 channel: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: count * factor)
        signal.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                _ = resampler.process(input: input.baseAddress!.advanced(by: start),
                                      inputFrames: count, output: output.baseAddress!,
                                      channel: channel, factor: factor, mode: mode,
                                      transitionFrames: transition)
            }
        }
        return out
    }

    // The reference has always used the target filter. Once history is warm,
    // switching must produce exactly that target response, even after tiny input
    // chunks and even when the previous filter needed much less history.
    for factor in [2, 4, 8] {
        for (old, new) in [(ResamplingFilterMode.linearPhaseShort, ResamplingFilterMode.linearPhaseLong),
                           (.linearPhaseLong, .linearPhaseShort),
                           (.minimumPhaseExperimental, .linearPhaseLong)] {
            for blockSize in [1, 16, 31, 32, 127, 128] {
                let changed = PCMResampler(channels: 2, maxInputFrames: count)
                let reference = PCMResampler(channels: 2, maxInputFrames: count)
                for channel in 0..<2 {
                    var cursor = 0
                    while cursor < count {
                        let frames = min(blockSize, count - cursor)
                        _ = process(changed, start: cursor, count: frames, factor: factor, mode: old, channel: channel)
                        _ = process(reference, start: cursor, count: frames, factor: factor, mode: new, channel: channel)
                        cursor += frames
                    }
                    let actual = process(changed, start: count, count: count, factor: factor, mode: new, channel: channel)
                    let expected = process(reference, start: count, count: count, factor: factor, mode: new, channel: channel)
                    let delta = zip(actual, expected).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
                    try check(delta < 1e-6, "Filter history \(old)→\(new), \(factor)× bs\(blockSize) ch\(channel): \(delta).")
                }
            }
        }
    }

    // A filter transition starts exactly at the old response, converges exactly
    // to the new response, and yields the same samples across callback splits.
    for (old, new) in [(ResamplingFilterMode.linearPhaseShort, ResamplingFilterMode.linearPhaseLong),
                       (.linearPhaseLong, .linearPhaseShort)] {
        let fading = PCMResampler(channels: 1, maxInputFrames: count)
        let split = PCMResampler(channels: 1, maxInputFrames: count)
        let oldReference = PCMResampler(channels: 1, maxInputFrames: count)
        let newReference = PCMResampler(channels: 1, maxInputFrames: count)
        for sampler in [fading, split, oldReference] {
            _ = process(sampler, start: 0, count: count, factor: 2, mode: old, transition: 512)
        }
        _ = process(newReference, start: 0, count: count, factor: 2, mode: new)
        let actual = process(fading, start: count, count: count, factor: 2, mode: new, transition: 512)
        let oldOutput = process(oldReference, start: count, count: count, factor: 2, mode: old)
        let newOutput = process(newReference, start: count, count: count, factor: 2, mode: new)
        try check(actual[0] == oldOutput[0], "Filter fade did not begin at the old response.")
        for i in actual.indices {
            let mix = Float(min(i, 512)) / 512
            let expected = oldOutput[i] + (newOutput[i] - oldOutput[i]) * mix
            try check(abs(actual[i] - expected) < 1e-6, "Filter fade coefficient trajectory failed at \(i).")
        }
        var joined: [Float] = []
        var cursor = 0
        while cursor < count {
            let frames = min(17, count - cursor)
            joined += process(split, start: count + cursor, count: frames,
                              factor: 2, mode: new, transition: 512)
            cursor += frames
        }
        try check(actual == joined, "Filter crossfade changed with callback block boundaries.")
    }

    let retargeted = PCMResampler(channels: 1, maxInputFrames: count)
    let shortReference = PCMResampler(channels: 1, maxInputFrames: count)
    let longReference = PCMResampler(channels: 1, maxInputFrames: count)
    _ = process(retargeted, start: 0, count: count, factor: 2, mode: .linearPhaseShort, transition: 512)
    _ = process(shortReference, start: 0, count: count, factor: 2, mode: .linearPhaseShort)
    _ = process(longReference, start: 0, count: count, factor: 2, mode: .linearPhaseLong)
    _ = process(retargeted, start: count, count: 37, factor: 2, mode: .linearPhaseLong, transition: 512)
    _ = process(shortReference, start: count, count: 37, factor: 2, mode: .linearPhaseShort)
    _ = process(longReference, start: count, count: 37, factor: 2, mode: .linearPhaseLong)
    let actual = process(retargeted, start: count + 37, count: count,
                         factor: 2, mode: .linearPhaseShort, transition: 512)
    let short = process(shortReference, start: count + 37, count: count, factor: 2, mode: .linearPhaseShort)
    let long = process(longReference, start: count + 37, count: count, factor: 2, mode: .linearPhaseLong)
    for i in actual.indices {
        let mix = (Float(74) / 512) * (1 - Float(min(i, 512)) / 512)
        let expected = short[i] + (long[i] - short[i]) * mix
        try check(abs(actual[i] - expected) < 1e-6,
                  "Retargeting a filter fade reset its current mix at sample \(i).")
    }
}
