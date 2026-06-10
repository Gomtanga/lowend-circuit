#include "../include/Core/HighExciter.h"

namespace lowend {

void HighExciter::OversamplingLowPass::update(
    const LCBiquadCoefficients& first,
    const LCBiquadCoefficients& second) {
    section1.update(first);
    section2.update(second);
}

float HighExciter::OversamplingLowPass::process(float input) {
    return section2.process(section1.process(input));
}

void HighExciter::OversamplingLowPass::reset() {
    section1.reset();
    section2.reset();
}

void HighExciter::Oversampling2xStage::update(
    const LCBiquadCoefficients& first,
    const LCBiquadCoefficients& second) {
    interpolationFilter.update(first, second);
    decimationFilter.update(first, second);
}

void HighExciter::Oversampling2xStage::upsample(
    float input, float& first, float& second) {
    first = interpolationFilter.process(input * 2.0f);
    second = interpolationFilter.process(0.0f);
}

float HighExciter::Oversampling2xStage::downsample(float first, float second) {
    float output = decimationFilter.process(first);
    (void) decimationFilter.process(second);
    return output;
}

void HighExciter::Oversampling2xStage::reset() {
    interpolationFilter.reset();
    decimationFilter.reset();
}

// ═══════════════════════════════════════════════════════════════════════
// Channel
// ═══════════════════════════════════════════════════════════════════════

float HighExciter::Channel::processSample(float input) {
    float dry = std::isfinite(input) ? input : 0.0f;

    // wetMix near zero → dry bypass (avoid unnecessary HP processing)
    if (wetMix < 0.0001f) {
        return dry;
    }

    float high = highPass.process(dry);
    float harmonic = 0.0f;

    if (oversampleFactor == 4) {
        float stage1First = 0.0f;
        float stage1Second = 0.0f;
        stage1.upsample(high, stage1First, stage1Second);

        float sample0 = 0.0f;
        float sample1 = 0.0f;
        float sample2 = 0.0f;
        float sample3 = 0.0f;
        stage2.upsample(stage1First, sample0, sample1);
        stage2.upsample(stage1Second, sample2, sample3);

        float downsampled0 = stage2.downsample(
            makeHarmonic(sample0), makeHarmonic(sample1));
        float downsampled1 = stage2.downsample(
            makeHarmonic(sample2), makeHarmonic(sample3));
        harmonic = stage1.downsample(downsampled0, downsampled1);
    } else if (oversampleFactor == 2) {
        float first = 0.0f;
        float second = 0.0f;
        stage1.upsample(high, first, second);
        harmonic = stage1.downsample(makeHarmonic(first), makeHarmonic(second));
    } else {
        harmonic = makeHarmonic(high);
    }

    return fastClamp(dry + harmonic * wetMix);
}

float HighExciter::Channel::makeHarmonic(float input) const {
    float driven = input * drive;
    float driven2 = driven * driven;
    return driven2 + driven2 * driven * 0.5f;
}

void HighExciter::Channel::reset() {
    highPass.reset();
    stage1.reset();
    stage2.reset();
}

float HighExciter::Channel::fastClamp(float value) {
    if (std::isnan(value) || std::isinf(value)) return 0.0f;
    if (value > 1.0f) return 1.0f;
    if (value < -1.0f) return -1.0f;
    return value;
}

// ═══════════════════════════════════════════════════════════════════════
// HighExciter — stereo wrapper
// ═══════════════════════════════════════════════════════════════════════

void HighExciter::update(const LCDSPSettings& settings) {
    auto assign = [](Channel& ch, const LCDSPSettings& s) {
        ch.highPass.update(s.exciterHighPass);
        ch.stage1.update(s.exciterStage1LowPass1, s.exciterStage1LowPass2);
        ch.stage2.update(s.exciterStage2LowPass1, s.exciterStage2LowPass2);
        ch.drive = s.exciterDrive;
        ch.wetMix = s.exciterWetMix;
        ch.oversampleFactor = s.exciterOversampleFactor == 4 ? 4
                                  : s.exciterOversampleFactor == 2 ? 2
                                                                  : 1;
    };
    assign(left_, settings);
    assign(right_, settings);
}

void HighExciter::process(float leftIn, float rightIn,
                           float& leftOut, float& rightOut) {
    leftOut = left_.processSample(leftIn);
    rightOut = right_.processSample(rightIn);
}

void HighExciter::reset() {
    left_.reset();
    right_.reset();
}

} // namespace lowend
