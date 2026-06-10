// HighExciter.h — HighExciterDSP port from Swift
//
// Reference: SystemAudioProcessor/.../main.swift
//   HighExciterDSP (lines 2441-2510)
//
// Independent high-frequency harmonic exciter.
// Extracts content above ~11 kHz and applies polynomial harmonic generation:
//   harmonic = driven² + 0.5 * driven³
//
// All methods are realtime-safe after construction.

#pragma once

#include "Core.h"

namespace lowend {

class HighExciter {
public:
    HighExciter() = default;

    /// (Re)configure from DSPPrecompute output.
    void update(const LCDSPSettings& settings);

    /// Process one stereo frame.  left/right are in/out.
    void process(float leftIn, float rightIn, float& leftOut, float& rightOut);

    /// Zero filter state.  Coefficients preserved.
    void reset();

private:
    struct OversamplingLowPass {
        Biquad section1;
        Biquad section2;

        void update(const LCBiquadCoefficients& first,
                    const LCBiquadCoefficients& second);
        float process(float input);
        void reset();
    };

    struct Oversampling2xStage {
        OversamplingLowPass interpolationFilter;
        OversamplingLowPass decimationFilter;

        void update(const LCBiquadCoefficients& first,
                    const LCBiquadCoefficients& second);
        void upsample(float input, float& first, float& second);
        float downsample(float first, float second);
        void reset();
    };

    struct Channel {
        Biquad highPass;       // ~11 kHz high-pass
        Oversampling2xStage stage1;
        Oversampling2xStage stage2;
        float drive = 0.0f;   // exciter drive gain
        float wetMix = 0.0f;  // wet blend amount (0 = bypass)
        uint32_t oversampleFactor = 1;

        float processSample(float input);
        float makeHarmonic(float input) const;
        void reset();
        static float fastClamp(float value);
    };

    Channel left_;
    Channel right_;
};

} // namespace lowend
