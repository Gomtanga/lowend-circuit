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


void HighExciter::Pipeline::update(const LCDSPSettings& s) {
    stage1.update(s.exciterStage1LowPass1, s.exciterStage1LowPass2);
    stage2.update(s.exciterStage2LowPass1, s.exciterStage2LowPass2);
    drive = s.exciterDrive;
    wetMix = s.exciterWetMix;
    oversampleFactor = s.exciterOversampleFactor == 4 ? 4
        : s.exciterOversampleFactor == 2 ? 2 : 1;
    dcBlockPole = std::isfinite(s.exciterDCBlockPole)
        && s.exciterDCBlockPole > 0 && s.exciterDCBlockPole < 1
        ? s.exciterDCBlockPole : 0.9993457f;
}

float HighExciter::Pipeline::process(float high) {
    if (wetMix < 0.0001f || drive < 0.0001f) return 0.0f;
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

    // The even harmonic term generates DC. Remove it only from the wet
    // branch, after decimation, so the dry signal remains unchanged.
    const float dcBlocked = (1.0f + dcBlockPole) * 0.5f
        * (harmonic - previousHarmonic) + dcBlockPole * previousDCBlocked;
    previousHarmonic = harmonic;
    previousDCBlocked = dcBlocked;


    return dcBlocked * wetMix;
}

float HighExciter::Pipeline::makeHarmonic(float input) const {
    const float driven = input * drive;
    const float squared = driven * driven;
    return squared + squared * driven * 0.5f;
}

void HighExciter::Pipeline::reset() {
    stage1.reset();
    stage2.reset();
    previousHarmonic = 0;
    previousDCBlocked = 0;
}

void HighExciter::Channel::update(const LCDSPSettings& settings) {
    if (transitionRemaining > 0) {
        pending = settings;
        hasPending = true;
        return;
    }
    const uint32_t nextFactor = settings.exciterOversampleFactor == 4 ? 4
        : settings.exciterOversampleFactor == 2 ? 2 : 1;
    highPass.update(settings.exciterHighPass);
    if (!initialized) {
        pipelines[active].update(settings);
        pipelines[active].reset();
        initialized = true;
    } else if (pipelines[active].oversampleFactor == nextFactor) {
        pipelines[active].update(settings);
    } else {
        target = 1u - active;
        pipelines[target].update(settings);
        pipelines[target].reset();
        transitionRemaining = transitionFrames;
    }
}

float HighExciter::Channel::processSample(float input) {
    const float dry = std::isfinite(input) ? input : 0.0f;
    const float high = highPass.process(dry);
    const bool isDry = (pipelines[active].wetMix < 0.0001f || pipelines[active].drive < 0.0001f)
        && (transitionRemaining == 0 || pipelines[target].wetMix < 0.0001f || pipelines[target].drive < 0.0001f);
    float wet = pipelines[active].process(high);
    if (transitionRemaining > 0) {
        const float nextWet = pipelines[target].process(high);
        const float mix = static_cast<float>(transitionFrames - transitionRemaining + 1u)
            / static_cast<float>(transitionFrames);
        wet += (nextWet - wet) * mix;
        if (--transitionRemaining == 0) {
            active = target;
            if (hasPending) {
                const LCDSPSettings next = pending;
                hasPending = false;
                update(next);
            }
        }
    }
    return isDry ? dry : fastClamp(dry + wet);
}

void HighExciter::Channel::reset() {
    if (transitionRemaining > 0) active = target;
    transitionRemaining = 0;
    if (hasPending) {
        highPass.update(pending.exciterHighPass);
        pipelines[active].update(pending);
        hasPending = false;
    }
    highPass.reset();
    pipelines[0].reset();
    pipelines[1].reset();
}

float HighExciter::Channel::fastClamp(float value) {
    if (!std::isfinite(value)) return 0;
    return value > 1 ? 1 : value < -1 ? -1 : value;
}

void HighExciter::update(const LCDSPSettings& settings) {
    left_.update(settings);
    right_.update(settings);
}

void HighExciter::process(float leftIn, float rightIn, float& leftOut, float& rightOut) {
    leftOut = left_.processSample(leftIn);
    rightOut = right_.processSample(rightIn);
}

void HighExciter::reset() {
    left_.reset();
    right_.reset();
}

} // namespace lowend
