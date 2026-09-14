// OutputConditioning.cpp — portable live output-conditioning stage (PCM 2x).
//
// Port of the live path of the macOS ResamplingOutputConditioningEngine
// (`processLive` and the parameter handling in `updateSettings`). See the header
// for the scope decision: live is PCM 2x, every other mode bypasses.
//
// The reference's live path applies headroom gain *before* the FIR, because its
// de-interleave step writes `input[i * 2] * gain`. That ordering is reproduced
// here: the gain is folded into the de-interleaved per-channel buffers and the
// FIR then smooths it, rather than being applied to the oversampled result.
//
// Realtime contract: process() allocates nothing, takes no lock, logs nothing and
// computes no coefficients. The resampler configuration and the headroom gain are
// refreshed by update(); every buffer is allocated by prepare().

#include "../include/Core/OutputConditioning.h"

#include <algorithm>
#include <cmath>

namespace lowend {

OutputConditioning::OutputConditioning() = default;

OutputConditioning::~OutputConditioning() = default;

bool OutputConditioning::prepare(double inputSampleRate, uint32_t maxInputFrames) {
    if (!std::isfinite(inputSampleRate) || !(inputSampleRate > 0.0) || maxInputFrames == 0) {
        return false;
    }

    // Only the live 2x factor can ever run here, so the oversampled work buffers
    // are sized for exactly that rather than for the offline maximum: the live
    // path's peak memory is part of the audio contract.
    const uint32_t maxOutput = maxInputFrames * liveFactor;
    deinterleavedLeft_.assign(maxInputFrames, 0.0f);
    deinterleavedRight_.assign(maxInputFrames, 0.0f);
    oversampledLeft_.assign(maxOutput, 0.0f);
    oversampledRight_.assign(maxOutput, 0.0f);
    leftResampler_ = std::make_unique<PcmResampler>(maxInputFrames);
    rightResampler_ = std::make_unique<PcmResampler>(maxInputFrames);

    inputSampleRate_ = inputSampleRate;
    maxInputFrames_ = maxInputFrames;
    headroomGain_ = 1.0f;
    // The resamplers are new and unprepared, so nothing can run until the next
    // update() pushes a snapshot through.
    prepared_ = true;
    active_ = false;
    return true;
}

bool OutputConditioning::update(const LCOutputConditioningSettings& settings) {
    if (!prepared_) {
        return false;
    }

    // Live scope: enabled PCM oversampling at exactly 2x. 4x/8x, dither and DSD
    // are offline on macOS and bypass here (filterMode/ditherEnabled/
    // noiseShapingEnabled/dsdMode play no part in the live decision, exactly as in
    // the reference).
    const bool activeNow = settings.enabled != 0u
        && settings.outputMode == 1u  // pcmOversampling
        && settings.oversamplingFactor == liveFactor;

    // A non-finite gain falls back to 0 (silence) and a negative gain clamps to 0;
    // this mirrors the reference's `max(gain, 0)` guard, which keeps the
    // post-FIR output finite for a finite input.
    headroomGain_ = std::isfinite(settings.headroomGain)
        ? std::max(settings.headroomGain, 0.0f)
        : 0.0f;

    // Coefficients are built here, on the control thread. prepare() clears the
    // history itself whenever the factor changes, so a filter change keeps the
    // history and the next blocks crossfade over
    // PcmResampler::filterTransitionFrames output frames.
    const bool leftOk = leftResampler_->prepare(inputSampleRate_, liveFactor,
                                                settings.filterMode);
    const bool rightOk = rightResampler_->prepare(inputSampleRate_, liveFactor,
                                                  settings.filterMode);

    // An unsupported filter mode leaves the live path inactive rather than
    // processing with a configuration that was rejected.
    const bool wasActive = active_;
    active_ = activeNow && leftOk && rightOk;

    // Entering or leaving the live path clears the FIR history, as the macOS
    // engine does when the live activation changes: the (re)activated path starts
    // from a clean state instead of a stale one. A filter-only change preserves
    // the history and crossfades.
    if (wasActive != active_) {
        leftResampler_->reset();
        rightResampler_->reset();
    }
    return active_;
}

uint32_t OutputConditioning::process(const float* left, const float* right, uint32_t inputFrames,
                                     float* outLeft, float* outRight) {
    if (!prepared_ || left == nullptr || right == nullptr || outLeft == nullptr
        || outRight == nullptr) {
        return 0;
    }
    // The reference returns 0 for both a degenerate and an oversized block. The
    // oversized case must not touch the output buffers, so the guard comes before
    // any write, including the bypass copy.
    if (inputFrames == 0 || inputFrames > maxInputFrames_) {
        return 0;
    }

    if (!active_) {
        // Verbatim identity copy; no headroom on the bypass path, so the
        // post-tonal signal reaches the caller unchanged.
        std::copy(left, left + inputFrames, outLeft);
        std::copy(right, right + inputFrames, outRight);
        return inputFrames;
    }

    // Headroom trim folded into the de-interleaved per-channel buffers, as the
    // macOS live path does.
    const float gain = headroomGain_;
    for (uint32_t i = 0; i < inputFrames; ++i) {
        deinterleavedLeft_[i] = left[i] * gain;
        deinterleavedRight_[i] = right[i] * gain;
    }

    const uint32_t outFrames = leftResampler_->processChannel(
        deinterleavedLeft_.data(), inputFrames, oversampledLeft_.data());
    rightResampler_->processChannel(deinterleavedRight_.data(), inputFrames,
                                    oversampledRight_.data());

    // A non-finite sample is written as 0 but is not scrubbed from the FIR
    // history: with a zeroed history the resampler's output is a finite linear
    // combination, so the only way to land here is a non-finite gain or a history
    // poisoned by an earlier non-finite sample. Replacing it keeps the output
    // finite for the rest of the stream, at the cost of one silent channel until
    // the next activation change or reset() — the reference has the same
    // property.
    for (uint32_t i = 0; i < outFrames; ++i) {
        const float l = oversampledLeft_[i];
        const float r = oversampledRight_[i];
        outLeft[i] = std::isfinite(l) ? l : 0.0f;
        outRight[i] = std::isfinite(r) ? r : 0.0f;
    }
    return outFrames;
}

uint32_t OutputConditioning::maxOutputFrames(uint32_t inputFrames) const {
    // The caller does not know which mode the next block will run in, so the
    // answer covers both: bypass needs inputFrames, the live 2x path needs twice
    // that.
    return std::max(inputFrames, inputFrames * liveFactor);
}

void OutputConditioning::reset() {
    if (leftResampler_ != nullptr) {
        leftResampler_->reset();
    }
    if (rightResampler_ != nullptr) {
        rightResampler_->reset();
    }
}

} // namespace lowend
