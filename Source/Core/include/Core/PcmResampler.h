// PcmResampler.h — portable integer (2x / 4x / 8x) polyphase FIR upsampler.
//
// Direct port of the macOS `PCMResampler`
// (SystemAudioProcessor/Sources/SystemAudioProcessor/PCMResampler.swift). The
// algorithm is platform-independent — a prototype low-pass, a polyphase
// decomposition and a scalar dot product per output sample — so it lives in
// Core and both apps share one implementation instead of keeping a copy each.
//
// The reference offers two dot-product kernels, Accelerate `vDSP_dotpr` and a
// plain scalar loop, and documents them as numerically identical. Only the
// scalar kernel is ported; the Accelerate dependency is not.
//
// Design notes carried over from the reference (its header has the full
// argument):
//
//   * Rate independence. The prototype low-pass is defined relative to the
//     *input* sample period: cut-off at pi/factor input-rate radians, i.e.
//     h[n] = sinc((n - center)/factor) with a Blackman window. Because the taps
//     are expressed in input samples rather than absolute Hz, one coefficient
//     set is correct for 44.1 kHz and 48 kHz families alike. `inputSampleRate`
//     is accepted (and validated) but never enters the coefficient math.
//   * Per-phase DC normalization. Each polyphase branch is scaled so its taps
//     sum to exactly 1, which makes a constant input pass through unchanged.
//   * No per-frame allocation. History, scratch and the coefficient tables are
//     allocated in the constructor / prepare(); processChannel() only indexes.
//   * Block continuity. The last 127 input samples are retained, so a stream may
//     be split into blocks of any size and the samples do not change.
//   * One instance = one channel. The reference keeps per-channel history in a
//     single object; here a caller owns one instance per channel (the macOS live
//     path runs exactly two).
//   * A filter change crossfades over `filterTransitionFrames` output frames,
//     the same value the macOS live entry point passes
//     (`ResamplingOutputConditioningEngine.processLive`, transitionFrames: 512).

#pragma once

#include <cstdint>
#include <vector>

namespace lowend {

class PcmResampler {
public:
    // Tap counts of the two implemented branches. `minimumPhaseExperimental`
    // (filterMode 2) aliases the short branch until a real minimum-phase design
    // lands, exactly as the reference does.
    static constexpr uint32_t shortTapsPerPhase = 32;
    static constexpr uint32_t longTapsPerPhase = 128;

    // Largest supported oversampling factor, used to size caller buffers.
    static constexpr uint32_t maxFactor = 8;

    // Output frames a filter change crossfades over. Matches the value the
    // macOS live path passes on every call.
    static constexpr uint32_t filterTransitionFrames = 512;

    // A block size of 0 is clamped to 1 (the reference clamps too), so the
    // scratch buffer is always valid.
    explicit PcmResampler(uint32_t maxInputFrames);
    ~PcmResampler() = default;
    PcmResampler(const PcmResampler&) = delete;
    PcmResampler& operator=(const PcmResampler&) = delete;

    // Control thread. Builds the two coefficient tables for `factor` and selects
    // `filterMode` (0 linearPhaseShort, 1 linearPhaseLong, 2 minimumPhase → the
    // short tables). Returns false, leaving the previous configuration usable,
    // when:
    //   * `factor` is not 2, 4 or 8 — the reference only builds those three, and
    //     the live path supports 2;
    //   * `filterMode` is outside 0..2;
    //   * `inputSampleRate` is not a positive finite number.
    // A factor change clears the filter history; a filter-only change keeps it
    // and crossfades over filterTransitionFrames output frames.
    bool prepare(double inputSampleRate, uint32_t factor, uint32_t filterMode);

    // Audio thread. Processes `inputFrames` samples of one channel into
    // `output`, which must hold at least maxOutputFrames(inputFrames) samples.
    // Returns the number of output frames written (inputFrames * factor), or 0
    // when the instance is unprepared, a pointer is null, or the block is empty
    // or larger than the maxInputFrames given to the constructor.
    // Allocates nothing, takes no lock and computes no coefficients.
    uint32_t processChannel(const float* input, uint32_t inputFrames, float* output);

    // Largest output frame count one processChannel() call can require. Static,
    // so it reports the worst case (maxFactor) and one buffer sized with it
    // covers every factor.
    static uint32_t maxOutputFrames(uint32_t inputFrames);

    // Control thread, while quiescent. Clears the filter history so the next
    // block starts from silence, as the reference's reset does.
    void reset();

    uint32_t factor() const { return factor_; }

    // Reporting only: the linear-phase FIR group delay of the selected branch at
    // the output rate, as tapsPerPhase * factor — the same quantity the macOS
    // checks measure the impulse peak against
    // (OutputConditioningChecks.swift: groupDelay = tapsPerPhase * factor).
    // 0 when unprepared.
    uint32_t latencyFrames() const;

private:
    // One pre-built polyphase table, stored with the taps reversed within each
    // phase so the dot product reads both the taps and the input window with
    // stride +1 (vDSP-friendly in the reference).
    struct CoefficientSet {
        uint32_t tapsPerPhase = 0;
        std::vector<float> coeffs;  // factor * tapsPerPhase, [phase * taps + k]
    };

    static CoefficientSet buildSet(uint32_t factor, uint32_t tapsPerPhase);
    float dot(const CoefficientSet& set, uint32_t phase, uint32_t anchor) const;

    std::vector<float> history_;  // longTapsPerPhase entries; 127 are live
    std::vector<float> work_;     // maxInputFrames + longTapsPerPhase: [history | input]
    CoefficientSet shortSet_;
    CoefficientSet longSet_;
    uint32_t maxInputFrames_ = 1;
    uint32_t factor_ = 0;
    uint32_t filterMode_ = 0;
    bool prepared_ = false;

    // Filter crossfade state, one per instance (the reference keeps one per
    // channel). Blend of the short and long branches; advances per output frame.
    float transitionMix_ = 0.0f;
    float transitionTarget_ = 0.0f;
    float transitionStep_ = 0.0f;
    uint32_t transitionRemaining_ = 0;
    bool transitionInitialized_ = false;
};

} // namespace lowend
