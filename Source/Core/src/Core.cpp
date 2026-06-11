#include "../include/Core/Core.h"

// ─────────────────────────────────────────────
// Biquad — Direct Form I
// Matches Swift Biquad (main.swift:2196-2236)
// ─────────────────────────────────────────────

namespace lowend {

void Biquad::update(const LCBiquadCoefficients& coeffs) {
    b0_ = coeffs.b0;
    b1_ = coeffs.b1;
    b2_ = coeffs.b2;
    a1_ = coeffs.a1;
    a2_ = coeffs.a2;
}

float Biquad::process(float input) {
    float output = b0_ * input + z1_;
    z1_ = b1_ * input - a1_ * output + z2_;
    z2_ = b2_ * input - a2_ * output;
    return output;
}

void Biquad::reset() {
    z1_ = 0.0f;
    z2_ = 0.0f;
}

LCBiquadCoefficients Biquad::makeLowShelf(float sampleRate,
                                           float frequency,
                                           float q,
                                           float gainDb) {
    float a = std::pow(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * 3.141592653589793f * frequency / sampleRate;
    float cosW0 = std::cos(w0);
    float sinW0 = std::sin(w0);
    float alpha = sinW0 / (2.0f * q);
    float beta = 2.0f * std::sqrt(a) * alpha;
    float a0 = (a + 1.0f) + (a - 1.0f) * cosW0 + beta;

    LCBiquadCoefficients c{};
    c.b0 = a * ((a + 1.0f) - (a - 1.0f) * cosW0 + beta) / a0;
    c.b1 = 2.0f * a * ((a - 1.0f) - (a + 1.0f) * cosW0) / a0;
    c.b2 = a * ((a + 1.0f) - (a - 1.0f) * cosW0 - beta) / a0;
    c.a1 = -2.0f * ((a - 1.0f) + (a + 1.0f) * cosW0) / a0;
    c.a2 = ((a + 1.0f) + (a - 1.0f) * cosW0 - beta) / a0;
    return c;
}

LCBiquadCoefficients Biquad::makeLowPass(float sampleRate,
                                          float frequency,
                                          float q) {
    float w0 = 2.0f * 3.141592653589793f * frequency / sampleRate;
    float alpha = std::sin(w0) / (2.0f * q);
    float cosW0 = std::cos(w0);
    float a0 = 1.0f + alpha;

    LCBiquadCoefficients c{};
    c.b0 = ((1.0f - cosW0) / 2.0f) / a0;
    c.b1 = (1.0f - cosW0) / a0;
    c.b2 = ((1.0f - cosW0) / 2.0f) / a0;
    c.a1 = (-2.0f * cosW0) / a0;
    c.a2 = (1.0f - alpha) / a0;
    return c;
}

LCBiquadCoefficients Biquad::makeHighPass(float sampleRate,
                                           float frequency,
                                           float q) {
    float w0 = 2.0f * 3.141592653589793f * frequency / sampleRate;
    float alpha = std::sin(w0) / (2.0f * q);
    float cosW0 = std::cos(w0);
    float a0 = 1.0f + alpha;

    LCBiquadCoefficients c{};
    c.b0 = ((1.0f + cosW0) / 2.0f) / a0;
    c.b1 = (-(1.0f + cosW0)) / a0;
    c.b2 = ((1.0f + cosW0) / 2.0f) / a0;
    c.a1 = (-2.0f * cosW0) / a0;
    c.a2 = (1.0f - alpha) / a0;
    return c;
}

// ─────────────────────────────────────────────
// OnePole — RC-style lowpass
// Matches Swift RcLowPass (main.swift:2291-2310)
// ─────────────────────────────────────────────

void OnePole::update(float alpha) {
    alpha_ = alpha;
}

float OnePole::process(float input) {
    z_ += alpha_ * (input - z_);
    return z_;
}

void OnePole::reset() {
    z_ = 0.0f;
}

float OnePole::makeRcAlpha(float sampleRate, float frequency) {
    float clampedFreq = std::fmax(5.0f, std::fmin(frequency, sampleRate * 0.45f));
    return 1.0f - std::exp(-2.0f * 3.141592653589793f * clampedFreq / sampleRate);
}

// ─────────────────────────────────────────────
// DSPPrecompute
// Matches Swift DSPPrecompute (main.swift:2033-2193)
// ─────────────────────────────────────────────

LCDSPSettings DSPPrecompute::makeDSPSettings(float sampleRate,
                                              float intensity,
                                              float body,
                                              float outputDb,
                                              uint32_t dspModel,
                                              uint32_t exciterOversamplingMode) {
    float normalIntensity = clamp(intensity / 100.0f, 0.0f, 1.0f);
    float normalBody = clamp(body / 100.0f, 0.0f, 1.0f);
    float shelfDb = normalIntensity * 6.5f;
    float shelfFreq = 68.0f + normalIntensity * 24.0f;
    float outputGain = std::pow(10.0f, outputDb / 20.0f);
    float transformerShelfDb = 0.7f + normalIntensity * 2.2f + normalBody * 0.7f;
    float transformerShelfFreq = 78.0f + normalIntensity * 10.0f + normalBody * 24.0f;
    float transformerDrive = 1.0f + normalIntensity * 0.24f + normalBody * 0.08f;
    float transformerAsymmetry = 0.002f + normalIntensity * 0.008f + normalBody * 0.004f;
    float transformerBiasOffset = makePolynomialSoftClip(transformerAsymmetry);
    float transformerMakeupGain = 1.0f / std::fmax(1.0f + (transformerDrive - 1.0f) * 0.35f, 0.001f);
    float exciterFrequency = std::fmin(11000.0f, sampleRate * 0.45f);
    float exciterDrive = (dspModel == 2) ? normalIntensity : 0.0f;   // 2 = HighExciter
    float exciterWetMix = (dspModel == 2) ? normalBody : 0.0f;
    uint32_t exciterOversampleFactor = exciterOversamplingMode == 1u
        || exciterOversamplingMode == 2u
        || exciterOversamplingMode == 4u
        ? exciterOversamplingMode
        : sampleRate <= 48000.5f ? 4u
            : sampleRate <= 96000.5f ? 2u
                                    : 1u;
    while (exciterOversampleFactor > 1u
           && sampleRate * static_cast<float>(exciterOversampleFactor) > 384000.5f) {
        exciterOversampleFactor /= 2u;
    }
    float exciterLowPassFrequency = std::fmin(20000.0f, sampleRate * 0.40f);
    float exciterStage1Rate = sampleRate * 2.0f;
    float exciterStage2Rate = sampleRate * 4.0f;
    constexpr float butterworthQ1 = 0.5411961f;
    constexpr float butterworthQ2 = 1.306563f;

    LCDSPSettings s{};
    s.intensity = normalIntensity;
    s.body = normalBody;
    s.outputGain = outputGain;
    s.headroomGain = std::pow(10.0f, (-3.0f * normalIntensity) / 20.0f);
    s.dspModel = dspModel;
    s.shelf = Biquad::makeLowShelf(sampleRate, shelfFreq, 0.72f, shelfDb);
    s.warmthAmount = 0.008f * normalIntensity + 0.004f * normalBody;
    s.virtualFeedbackGain = 0.16f * normalIntensity;
    s.bodyInjectionGain = (0.46f + 0.06f * normalIntensity) * normalBody;
    s.circuitHeadroomGain = std::pow(10.0f, (-1.2f * normalIntensity - 0.4f * normalBody) / 20.0f);
    s.drive = 1.0f + 0.10f * normalIntensity + 0.04f * normalBody;
    s.wetMix = std::fmin(std::fmax(0.32f * normalIntensity + 0.18f * normalBody, 0.0f), 0.54f);
    s.bassAlpha = OnePole::makeRcAlpha(sampleRate, 72.0f + normalIntensity * 36.0f);
    s.subAlpha = OnePole::makeRcAlpha(sampleRate, 38.0f + normalBody * 26.0f);
    s.transformerPreEmphasis = Biquad::makeLowShelf(sampleRate, transformerShelfFreq, 0.72f, transformerShelfDb);
    s.transformerDeEmphasis = Biquad::makeLowShelf(sampleRate, transformerShelfFreq, 0.72f, -transformerShelfDb);
    s.transformerDrive = transformerDrive;
    s.transformerAsymmetry = transformerAsymmetry;
    s.transformerBiasOffset = transformerBiasOffset;
    s.transformerMakeupGain = transformerMakeupGain;
    s.exciterHighPass = Biquad::makeHighPass(sampleRate, exciterFrequency, 0.707f);
    s.exciterDrive = exciterDrive;
    s.exciterWetMix = exciterWetMix;
    s.exciterOversampleFactor = exciterOversampleFactor;
    s.exciterStage1LowPass1 = Biquad::makeLowPass(
        exciterStage1Rate, exciterLowPassFrequency, butterworthQ1);
    s.exciterStage1LowPass2 = Biquad::makeLowPass(
        exciterStage1Rate, exciterLowPassFrequency, butterworthQ2);
    s.exciterStage2LowPass1 = Biquad::makeLowPass(
        exciterStage2Rate, exciterLowPassFrequency, butterworthQ1);
    s.exciterStage2LowPass2 = Biquad::makeLowPass(
        exciterStage2Rate, exciterLowPassFrequency, butterworthQ2);
    return s;
}

LCSpatialSettings DSPPrecompute::makeSpatialSettings(float sampleRate,
                                                      float listenerX,
                                                      float listenerZ,
                                                      float speakerWidth,
                                                      float amount,
                                                      bool enabled) {
    float width = clamp(speakerWidth, 0.6f, 3.0f);
    float lx = clamp(listenerX, -3.0f, 3.0f);
    float lz = clamp(listenerZ, -2.8f, 2.8f);
    float earOffset = 0.09f;
    float speakerZ = 1.8f;
    float amt = clamp(amount / 100.0f, 0.0f, 1.0f);
    float crossfeed = 0.16f + amt * 0.30f;

    float leftSpeakerX = -width / 2.0f;
    float rightSpeakerX = width / 2.0f;

    float leftEarX = lx - earOffset;
    float rightEarX = lx + earOffset;

    float llDist = distance(leftSpeakerX, speakerZ, leftEarX, lz);
    float lrDist = distance(leftSpeakerX, speakerZ, rightEarX, lz);
    float rlDist = distance(rightSpeakerX, speakerZ, leftEarX, lz);
    float rrDist = distance(rightSpeakerX, speakerZ, rightEarX, lz);

    float minDist = std::fmin(std::fmin(llDist, lrDist), std::fmin(rlDist, rrDist));

    float llGain = inverseDistanceGain(llDist);
    float rrGain = inverseDistanceGain(rrDist);
    float lrGain = inverseDistanceGain(lrDist) * crossfeed;
    float rlGain = inverseDistanceGain(rlDist) * crossfeed;
    float normalizer = 1.0f / std::fmax((llGain + rrGain) * 0.5f, 0.001f);

    LCSpatialSettings s{};
    s.enabled = enabled ? 1u : 0u;
    s.amount = amt;
    s.ll = makeSpatialPath(llDist - minDist, llGain * normalizer, sampleRate);
    s.lr = makeSpatialPath(lrDist - minDist, lrGain * normalizer, sampleRate);
    s.rl = makeSpatialPath(rlDist - minDist, rlGain * normalizer, sampleRate);
    s.rr = makeSpatialPath(rrDist - minDist, rrGain * normalizer, sampleRate);
    return s;
}

// ─────────────────────────────────────────────
// DSPPrecompute — internal helpers
// ─────────────────────────────────────────────

float DSPPrecompute::clamp(float value, float lower, float upper) {
    return std::fmin(std::fmax(value, lower), upper);
}

float DSPPrecompute::makePolynomialSoftClip(float input) {
    if (input > 1.0f) return 1.0f;
    if (input < -1.0f) return -1.0f;
    return input - (input * input * input) / 3.0f;
}

float DSPPrecompute::distance(float ax, float az, float bx, float bz) {
    float dx = ax - bx;
    float dz = az - bz;
    return std::fmax(std::sqrt(dx * dx + dz * dz), 0.12f);
}

float DSPPrecompute::inverseDistanceGain(float meters) {
    return 1.0f / std::fmax(0.45f + meters * 0.62f, 0.2f);
}

LCSpatialPathSettings DSPPrecompute::makeSpatialPath(float distanceOffset,
                                                      float gain,
                                                      float sampleRate) {
    float speedOfSound = 343.0f;
    int32_t samples = static_cast<int32_t>(
        (std::fmax(distanceOffset, 0.0f) / speedOfSound * sampleRate) + 0.5f);
    LCSpatialPathSettings p{};
    p.delaySamples = static_cast<uint32_t>(std::fmax(samples, 0));
    p.gain = gain;
    return p;
}

} // namespace lowend
