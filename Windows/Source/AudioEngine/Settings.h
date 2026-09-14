// Settings.h — user-facing DSP settings, normalization, and spatial planning.
//
// These rules mirror the macOS CLI (SystemAudioProcessor/Sources/.../
// AudioSettings.swift) so both platforms accept the same values and clamp them
// the same way. Nothing here touches the audio thread.

#pragma once

#include "AudioRingBufferC.h"

#include <cstdint>
#include <string>

namespace lowend::win {

// Numeric values match DSPModel in Source/Core/include/Core/Core.h.
namespace dsp_model {
inline constexpr uint32_t clean = 0;
inline constexpr uint32_t circuit = 1;
inline constexpr uint32_t high_exciter = 2;
} // namespace dsp_model

// Numeric values match ExciterOversamplingMode in the macOS CLI.
namespace oversampling_mode {
inline constexpr uint32_t automatic = 0;
inline constexpr uint32_t one_x = 1;
inline constexpr uint32_t two_x = 2;
inline constexpr uint32_t four_x = 4;
} // namespace oversampling_mode

struct Settings {
    uint32_t dspModel = dsp_model::circuit;
    float intensity = 55.0f;   // 0..100
    float body = 30.0f;        // 0..100
    float outputDb = -1.5f;    // -18..6
    uint32_t exciterOversamplingMode = oversampling_mode::automatic;

    // Shared-mode device buffer request. Both the loopback capture and the
    // render client are opened with this period.
    uint32_t bufferMs = 20;

    bool spatialEnabled = false;
    float listenerX = 0.0f;      // -3..3 m
    float listenerZ = 0.0f;      // -2.8..2.8 m
    float speakerWidth = 1.65f;  // 0.6..3 m
    float space = 35.0f;         // 0..100
};

// Clamp every value into its documented range. Non-finite input falls back to
// the same defaults the macOS CLI uses, so NaN/Inf can never reach the DSP.
Settings normalized(const Settings& settings);

bool isFinite(float value);

// Parse --model. Accepts clean, circuit, highexciter (also "exciter"), ignoring
// case and '-', '_', ' ' separators.
bool parseDSPModel(const std::string& text, uint32_t& model);

// Parse --exciter-os. Accepts auto, 1, 1x, 2, 2x, 4, 4x (case-insensitive).
bool parseOversamplingMode(const std::string& text, uint32_t& mode);

const char* dspModelName(uint32_t model);
const char* oversamplingModeName(uint32_t mode);

// ─── Spatial planning (control thread) ───────────────────────────────
// The geometry is authoritative in Source/Core/src/SpatialGeometry.cpp and is
// reached through lowend::DSPPrecompute::makeSpatialSettings, so the Windows
// build does not carry its own copy of the delay/gain maths. The result is the
// same C ABI struct the running spatial stage consumes.
//
// Returns a disabled setting for a non-finite or unsupported request.
LCSpatialSettings makeSpatialSettings(float sampleRate, const Settings& settings);

} // namespace lowend::win
