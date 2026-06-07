// CircuitBass.h — VirtualCircuitBassDSP port from Swift
//
// Reference: SystemAudioProcessor/Sources/SystemAudioProcessor/main.swift
//   VirtualCircuitBassDSP (lines 2313-2438)
//
// This class implements the full "Circuit" bass enhancement model:
//   input → shelf filter + RC bass/sub → feedback → pre-emphasis →
//   asymmetric saturation → de-emphasis → wet blend → output
//
// All methods are realtime-safe after construction:
//   - No heap allocation in process() or update()
//   - No locks, no syscalls, no exceptions
//   - Uses only Biquad + OnePole from this same Core library

#pragma once

#include "Core.h"

namespace lowend {

class CircuitBass {
public:
    CircuitBass() = default;

    /// (Re)configure from DSPPrecompute output.
    void update(const LCDSPSettings& settings);

    /// Process one stereo frame.  left/right are in/out.
    void process(float leftIn, float rightIn, float& leftOut, float& rightOut);

    /// Zero all filter state.  Coefficients are preserved.
    void reset();

private:
    struct Channel {
        // Filters — direct member storage (no heap, no pointer indirection)
        Biquad shelf;
        OnePole bassPole;
        OnePole subPole;
        Biquad preEmphasis;
        Biquad deEmphasis;

        // Scalar parameters (set by update(), read by process())
        float intensity = 0.0f;
        float body = 0.0f;
        float outputGain = 1.0f;
        float virtualFeedbackGain = 0.0f;
        float bodyInjectionGain = 0.0f;
        float headroomGain = 1.0f;
        float wetMix = 0.0f;
        float transformerDrive = 1.0f;
        float transformerAsymmetry = 0.0f;
        float transformerBiasOffset = 0.0f;
        float transformerMakeupGain = 1.0f;

        float processSample(float input);
        float asymmetricSaturate(float input) const;
        static float fastClamp(float value);
    };

    Channel left_;
    Channel right_;
};

} // namespace lowend
