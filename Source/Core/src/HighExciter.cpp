#include <Core/HighExciter.h>

namespace lowend {

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
    float driven = high * drive;
    float driven2 = driven * driven;
    float harmonic = driven2 + driven2 * driven * 0.5f;

    return fastClamp(dry + harmonic * wetMix);
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
        ch.drive = s.exciterDrive;
        ch.wetMix = s.exciterWetMix;
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
    left_.highPass.reset();
    right_.highPass.reset();
}

} // namespace lowend
