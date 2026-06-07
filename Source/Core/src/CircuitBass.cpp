#include <Core/CircuitBass.h>

namespace lowend {

// ═══════════════════════════════════════════════════════════════════════
// Channel — per-channel processing
// ═══════════════════════════════════════════════════════════════════════

float CircuitBass::Channel::processSample(float input) {
    // Near-zero intensity+body → bypass (just gain)
    if (intensity < 0.001f && body < 0.001f) {
        return input * outputGain;
    }

    float bassShaped = shelf.process(input);
    float bassNode = bassPole.process(input);
    float subNode = subPole.process(input);

    float shaped = bassShaped + subNode * bodyInjectionGain;
    float circuitInput = (shaped + bassNode * virtualFeedbackGain) * headroomGain;

    float emphasized = preEmphasis.process(circuitInput);
    float saturated = asymmetricSaturate(emphasized);
    float deEmphasized = deEmphasis.process(saturated);

    float blended = shaped + (deEmphasized - shaped) * wetMix;
    return fastClamp(blended * outputGain);
}

float CircuitBass::Channel::asymmetricSaturate(float input) const {
    float driven = input * transformerDrive;
    float biased = driven + transformerAsymmetry;

    float clipped;
    if (biased > 1.0f) {
        clipped = 1.0f;
    } else if (biased < -1.0f) {
        clipped = -1.0f;
    } else {
        clipped = biased - (biased * biased * biased) * 0.33333334f;
    }

    return (clipped - transformerBiasOffset) * transformerMakeupGain;
}

float CircuitBass::Channel::fastClamp(float value) {
    if (std::isnan(value) || std::isinf(value)) return 0.0f;
    if (value > 1.0f) return 1.0f;
    if (value < -1.0f) return -1.0f;
    return value;
}

// ═══════════════════════════════════════════════════════════════════════
// CircuitBass — stereo wrapper
// ═══════════════════════════════════════════════════════════════════════

void CircuitBass::update(const LCDSPSettings& settings) {
    auto assign = [](Channel& ch, const LCDSPSettings& s) {
        ch.intensity = s.intensity;
        ch.body = s.body;
        ch.outputGain = s.outputGain;
        ch.virtualFeedbackGain = s.virtualFeedbackGain;
        ch.bodyInjectionGain = s.bodyInjectionGain;
        ch.headroomGain = s.circuitHeadroomGain;
        ch.wetMix = s.wetMix;
        ch.transformerDrive = s.transformerDrive;
        ch.transformerAsymmetry = s.transformerAsymmetry;
        ch.transformerBiasOffset = s.transformerBiasOffset;
        ch.transformerMakeupGain = s.transformerMakeupGain;
        ch.shelf.update(s.shelf);
        ch.preEmphasis.update(s.transformerPreEmphasis);
        ch.deEmphasis.update(s.transformerDeEmphasis);
        ch.bassPole.update(s.bassAlpha);
        ch.subPole.update(s.subAlpha);
    };

    assign(left_, settings);
    assign(right_, settings);
}

void CircuitBass::process(float leftIn, float rightIn,
                           float& leftOut, float& rightOut) {
    leftOut = left_.processSample(leftIn);
    rightOut = right_.processSample(rightIn);
}

void CircuitBass::reset() {
    auto resetChannel = [](Channel& ch) {
        ch.shelf.reset();
        ch.bassPole.reset();
        ch.subPole.reset();
        ch.preEmphasis.reset();
        ch.deEmphasis.reset();
    };
    resetChannel(left_);
    resetChannel(right_);
}

} // namespace lowend
