// PcmResampler.cpp — portable polyphase FIR upsampler.
//
// Port of SystemAudioProcessor/Sources/SystemAudioProcessor/PCMResampler.swift.
// The reference's `.direct` kernel is the one ported: a plain scalar dot product
// whose accumulation order (`result += coeffs[k] * window[k]`, k ascending in
// Float) is reproduced exactly, so this implementation is bit-identical to the
// macOS `.direct` baseline. The `.vDSP` kernel is documented as numerically
// identical to it and is not part of the port.
//
// Coefficient design is copied from `PCMResampler.buildSet` line for line: the
// prototype is a sinc low-pass with a Blackman window, the polyphase branches are
// normalized to unit DC gain, and the taps are stored reversed within each phase.
// See the header for why the input sample rate never enters the math.
//
// Realtime contract: processChannel() allocates nothing, takes no lock, logs
// nothing and computes nothing but the dot products. The tables are built once in
// prepare() and the scratch/history buffers are allocated in the constructor.

#include "../include/Core/PcmResampler.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace lowend {
namespace {

constexpr double kPi = 3.14159265358979323846;

// Blackman window as the reference writes it. The reference uses `length - 1` as
// the denominator, which is >= 63 here (shortest set is 2 x 32 taps), so there is
// no division by zero.
double blackman(uint32_t n, uint32_t length) {
    const double phase = 2.0 * kPi * static_cast<double>(n) / static_cast<double>(length - 1);
    return 0.42 - 0.5 * std::cos(phase) + 0.08 * std::cos(2.0 * phase);
}

} // namespace

PcmResampler::PcmResampler(uint32_t maxInputFrames)
    : history_(longTapsPerPhase, 0.0f),
      work_(std::max(1u, maxInputFrames) + longTapsPerPhase, 0.0f),
      maxInputFrames_(std::max(1u, maxInputFrames)) {}

PcmResampler::CoefficientSet PcmResampler::buildSet(uint32_t factor, uint32_t tapsPerPhase) {
    // Prototype length is a whole multiple of the factor, so every phase has
    // exactly tapsPerPhase taps.
    const uint32_t length = factor * tapsPerPhase;
    const double center = (static_cast<double>(length) - 1.0) / 2.0;

    // Cut-off at pi/factor in input-rate radians: h[n] = sinc((n - center)/factor),
    // Blackman-windowed. The 1/factor DC-gain scaling is the sinc argument itself,
    // so no extra scale factor is applied.
    std::vector<double> prototype(length, 0.0);
    for (uint32_t n = 0; n < length; ++n) {
        const double x = (static_cast<double>(n) - center) / static_cast<double>(factor);
        const double sample = (std::fabs(x) < 1e-12) ? 1.0 : std::sin(kPi * x) / (kPi * x);
        prototype[n] = sample * blackman(n, length);
    }

    // Polyphase decomposition, per-phase DC normalization and per-phase tap
    // reversal:
    //     coeffs[phase * tapsPerPhase + k] = prototype[phase + (taps - 1 - k) * factor] * norm
    // The normalization makes each branch sum to 1, so a constant input passes
    // through unchanged; the reversal lets the render loop read taps and window
    // with stride +1.
    CoefficientSet set;
    set.tapsPerPhase = tapsPerPhase;
    set.coeffs.assign(length, 0.0f);
    for (uint32_t phase = 0; phase < factor; ++phase) {
        float phaseSum = 0.0f;
        for (uint32_t k = 0; k < tapsPerPhase; ++k) {
            phaseSum += static_cast<float>(prototype[phase + k * factor]);
        }
        const float norm = (std::fabs(phaseSum) > 1e-12f) ? (1.0f / phaseSum) : 1.0f;
        for (uint32_t k = 0; k < tapsPerPhase; ++k) {
            const uint32_t protoIndex = phase + (tapsPerPhase - 1 - k) * factor;
            set.coeffs[phase * tapsPerPhase + k] =
                static_cast<float>(prototype[protoIndex]) * norm;
        }
    }
    return set;
}

bool PcmResampler::prepare(double inputSampleRate, uint32_t factor, uint32_t filterMode) {
    if (!std::isfinite(inputSampleRate) || !(inputSampleRate > 0.0)) {
        return false;
    }
    if (factor != 2 && factor != 4 && factor != 8) {
        return false;
    }
    if (filterMode > 2) {
        return false;
    }

    // A factor change replaces the whole filter, so the retained input history no
    // longer belongs to this configuration and is cleared — the same reset the
    // macOS engine performs when the live factor changes. A change between the
    // two implemented branches is a filter-only change: the history is preserved
    // and processChannel() crossfades (minimumPhase aliases short, so selecting it
    // is a filter-only change too).
    if (factor_ != factor) {
        reset();
    }

    shortSet_ = buildSet(factor, shortTapsPerPhase);
    longSet_ = buildSet(factor, longTapsPerPhase);
    factor_ = factor;
    filterMode_ = filterMode;
    prepared_ = true;
    return true;
}

uint32_t PcmResampler::processChannel(const float* input, uint32_t inputFrames, float* output) {
    if (!prepared_ || input == nullptr || output == nullptr) {
        return 0;
    }
    if (inputFrames == 0 || inputFrames > maxInputFrames_) {
        return 0;
    }

    // Everything below only indexes pre-allocated storage.
    const uint32_t historyCount = longTapsPerPhase - 1;

    // Chronological prefix [history tail | new input], so a dot product reads a
    // contiguous ascending window. The prefix is a fixed 127 samples even when the
    // short branch is selected; that branch simply starts further into it, which
    // is what keeps the history valid across a filter change.
    std::memcpy(work_.data(), history_.data(), historyCount * sizeof(float));
    std::memcpy(work_.data() + historyCount, input, inputFrames * sizeof(float));

    const uint32_t outCount = inputFrames * factor_;
    const float target = (filterMode_ == 1) ? 1.0f : 0.0f;
    if (!transitionInitialized_) {
        transitionMix_ = target;
        transitionTarget_ = target;
        transitionStep_ = 0.0f;
        transitionRemaining_ = 0;
        transitionInitialized_ = true;
    } else if (transitionTarget_ != target) {
        // A new request during a fade starts from the current mix, so repeated
        // filter changes do not restart the blend.
        transitionTarget_ = target;
        transitionRemaining_ = filterTransitionFrames;
        transitionStep_ = (target - transitionMix_) / static_cast<float>(filterTransitionFrames);
    }

    for (uint32_t outputFrame = 0; outputFrame < outCount; ++outputFrame) {
        const uint32_t j = outputFrame / factor_;
        const uint32_t phase = outputFrame - j * factor_;
        const uint32_t anchor = j + historyCount;
        const float mix = std::min(1.0f, std::max(0.0f, transitionMix_));
        if (mix == 0.0f) {
            output[outputFrame] = dot(shortSet_, phase, anchor);
        } else if (mix == 1.0f) {
            output[outputFrame] = dot(longSet_, phase, anchor);
        } else {
            const float shortValue = dot(shortSet_, phase, anchor);
            const float longValue = dot(longSet_, phase, anchor);
            output[outputFrame] = shortValue + (longValue - shortValue) * mix;
        }
        if (transitionRemaining_ > 0) {
            --transitionRemaining_;
            transitionMix_ = (transitionRemaining_ == 0)
                ? transitionTarget_
                : transitionMix_ + transitionStep_;
        }
    }

    // Keep the last 127 samples of the stream for the next block. Because the
    // scratch prefix is [history | input], those 127 samples are exactly
    // work[inputFrames .. inputFrames + 126] for every block size: the block's own
    // samples when inputFrames >= 127, and the unused tail of the previous history
    // followed by the block's samples when the block is shorter than 127.
    std::memcpy(history_.data(), work_.data() + inputFrames, historyCount * sizeof(float));
    return outCount;
}

uint32_t PcmResampler::maxOutputFrames(uint32_t inputFrames) {
    // A static query cannot know the configured factor, so it reports the worst
    // case the class can be prepared for.
    return inputFrames * maxFactor;
}

void PcmResampler::reset() {
    std::fill(history_.begin(), history_.end(), 0.0f);
    transitionMix_ = 0.0f;
    transitionTarget_ = 0.0f;
    transitionStep_ = 0.0f;
    transitionRemaining_ = 0;
    transitionInitialized_ = false;
}

uint32_t PcmResampler::latencyFrames() const {
    if (!prepared_) {
        return 0;
    }
    const uint32_t taps = (filterMode_ == 1) ? longTapsPerPhase : shortTapsPerPhase;
    return taps * factor_;
}

float PcmResampler::dot(const CoefficientSet& set, uint32_t phase, uint32_t anchor) const {
    const uint32_t taps = set.tapsPerPhase;
    const float* coefficients = set.coeffs.data() + phase * taps;
    const float* window = work_.data() + (anchor - (taps - 1));
    float result = 0.0f;
    for (uint32_t k = 0; k < taps; ++k) {
        result += coefficients[k] * window[k];
    }
    return result;
}

} // namespace lowend
