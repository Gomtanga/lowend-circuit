// Core.h — Cross-platform DSP core umbrella header
//
// This header is the single entry point for all platform adapters
// (macOS Swift, JUCE C++, Windows C++) to use the shared DSP core.
//
// The C ABI types (LCBiquadCoefficients, LCDSPSettings, LCSpatialSettings,
// LCSpatialPathSettings, LCControlEvent) come from AudioRingBufferC.h,
// which is compiled as C and linkable from any language.
//
// The C++ classes and functions add portable DSP algorithm implementations
// that use those C types as their data contract.

#pragma once

#include <stdint.h>

// -----------------------------------------------------------------------
// C ABI types — shared with AudioRingBufferC (C → Swift bridging)
// AudioRingBufferC.h lives outside Core/ to avoid moving existing code.
// The build system adds its include path via -I or target_include_directories.
//
// DSP class headers:
//   CircuitBass.h    — VirtualCircuitBassDSP (full circuit bass model)
//   HighExciter.h    — HighExciterDSP (high-frequency harmonic exciter)
//   (future) Spatializer.h
// -----------------------------------------------------------------------
#include "AudioRingBufferC.h"

// -----------------------------------------------------------------------
// C++ DSP implementations — namespace lowend
// All classes are realtime-safe after construction:
//   - No heap allocation in process() or update()
//   - No locks, no syscalls, no exceptions
//   - Coefficients are precomputed offline via DSPPrecompute
// -----------------------------------------------------------------------
#ifdef __cplusplus

#include <cmath>

namespace lowend {

enum class DSPModel : uint32_t {
    clean = 0,
    circuit = 1,
    highExciter = 2
};

using DSPSettings = LCDSPSettings;

// ======================================================================
// Biquad — Direct Form I biquad filter
//
// Matches the Swift Biquad struct (main.swift lines 2196-2236):
//   output = b0 * input + z1
//   z1 = b1 * input - a1 * output + z2
//   z2 = b2 * input - a2 * output
// ======================================================================
class Biquad {
public:
    Biquad() = default;

    /// Update coefficients (realtime-safe: field copy only).
    void update(const LCBiquadCoefficients& coeffs);

    /// Process one sample.
    float process(float input);

    /// Zero the state (z1 = z2 = 0). Does not change coefficients.
    void reset();

    // --- Static coefficient generators (not realtime-safe) ---

    /// Low-shelf biquad. gainDb positive = boost.
    static LCBiquadCoefficients makeLowShelf(float sampleRate,
                                             float frequency,
                                             float q,
                                             float gainDb);

    /// Low-pass biquad.
    static LCBiquadCoefficients makeLowPass(float sampleRate,
                                            float frequency,
                                            float q);

    /// High-pass biquad.
    static LCBiquadCoefficients makeHighPass(float sampleRate,
                                             float frequency,
                                             float q);

private:
    // Coefficients
    float b0_ = 1.0f;
    float b1_ = 0.0f;
    float b2_ = 0.0f;
    float a1_ = 0.0f;
    float a2_ = 0.0f;
    // State
    float z1_ = 0.0f;
    float z2_ = 0.0f;
};

// ======================================================================
// OnePole — RC-style one-pole lowpass filter
//
// Matches the Swift RcLowPass class (main.swift lines 2291-2310):
//   z += alpha * (input - z)
// ======================================================================
class OnePole {
public:
    OnePole() = default;

    /// Update alpha (realtime-safe).
    void update(float alpha);

    /// Process one sample.
    float process(float input);

    /// Zero the state.
    void reset();

    /// Compute alpha from sample rate and cutoff frequency.
    ///   alpha = 1 - exp(-2 * pi * frequency / sampleRate)
    static float makeRcAlpha(float sampleRate, float frequency);

private:
    float alpha_ = 0.0f;
    float z_ = 0.0f;
};

// ======================================================================
// DSPPrecompute — offline coefficient calculation
//
// Matches the Swift DSPPrecompute enum (main.swift lines 2033-2193).
// All functions are NOT realtime-safe — call them from the UI/control
// thread and push the result to the audio thread via a control queue.
// ======================================================================
struct DSPPrecompute {
    /// Build a full LCDSPSettings struct from user-friendly parameters.
    /// This mirrors Swift DSPPrecompute.makeDSPSettings().
    static LCDSPSettings makeDSPSettings(float sampleRate,
                                         float intensity,
                                         float body,
                                         float outputDb,
                                         uint32_t dspModel,
                                         uint32_t exciterOversamplingMode = 0);

    /// Build a full LCSpatialSettings struct from user-friendly spatial parameters.
    /// This mirrors Swift DSPPrecompute.makeSpatialSettings().
    static LCSpatialSettings makeSpatialSettings(float sampleRate,
                                                 float listenerX,
                                                 float listenerZ,
                                                 float speakerWidth,
                                                 float amount,
                                                 bool enabled);

private:
    static float clamp(float value, float lower, float upper);
    static float makePolynomialSoftClip(float input);
    static float distance(float ax, float az, float bx, float bz);
    static float inverseDistanceGain(float meters);
    static LCSpatialPathSettings makeSpatialPath(float distanceOffset,
                                                  float gain,
                                                  float sampleRate);
};

} // namespace lowend

#endif // __cplusplus
