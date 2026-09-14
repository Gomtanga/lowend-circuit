// Settings.cpp — normalization, argument parsing, and spatial planning.
//
// Every rule here is a port of the macOS CLI (AudioSettings.swift and the
// argument parser in main.swift) so a value accepted on one platform is
// accepted with the same meaning on the other. All of this runs on the control
// thread: the audio thread receives finished LCSpatialSettings through the
// control queue and never re-derives any of it.

#include "AudioEngine/Settings.h"

#include "Core/Core.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>

namespace lowend::win {
namespace {

// Shared-mode WASAPI streams run on the engine's own period, which is about
// 10 ms for a typical endpoint, and the audio engine refuses requests shorter
// than 3 ms. Beyond ~500 ms the stream stops behaving like a live route: every
// notification carries an audible amount of latency and the engine's ring
// buffer, not the device period, is what actually governs smoothness. A value
// outside that window is a typo rather than an intent, so it falls back to the
// documented default instead of being clamped to an extreme nobody asked for.
constexpr uint32_t minBufferMs = 3;
constexpr uint32_t maxBufferMs = 500;
constexpr uint32_t defaultBufferMs = 20;

// The macOS CLI clamps with min(max(value, lower), upper) and substitutes a
// fallback for non-finite input, so NaN/Inf can never reach the DSP.
float finiteClamp(float value, float lower, float upper, float fallback) {
    return isFinite(value) ? std::min(std::max(value, lower), upper) : fallback;
}

char asciiLower(char raw) {
    return static_cast<char>(std::tolower(static_cast<unsigned char>(raw)));
}

bool isSeparator(char character) {
    return character == '-' || character == '_' || character == ' ';
}

// The macOS --exciter-os switch only lowercases its token.
std::string lowercased(const std::string& text) {
    std::string result;
    result.reserve(text.size());
    for (const char raw : text) {
        result.push_back(asciiLower(raw));
    }
    return result;
}

// Mirrors Settings.DSPModel.fromArgument() on macOS: case is ignored and '-',
// '_' and ' ' are dropped, so "high-exciter" and "High Exciter" are the same
// token as "highexciter".
std::string canonicalModelArgument(const std::string& text) {
    std::string result;
    result.reserve(text.size());
    for (const char raw : text) {
        if (!isSeparator(raw)) {
            result.push_back(asciiLower(raw));
        }
    }
    return result;
}

bool isKnownDSPModel(uint32_t model) {
    return model == dsp_model::clean || model == dsp_model::circuit
        || model == dsp_model::high_exciter;
}

bool isKnownOversamplingMode(uint32_t mode) {
    return mode == oversampling_mode::automatic || mode == oversampling_mode::one_x
        || mode == oversampling_mode::two_x || mode == oversampling_mode::four_x;
}

} // namespace

bool isFinite(float value) {
    return std::isfinite(value);
}

Settings normalized(const Settings& settings) {
    Settings result = settings;

    result.intensity = finiteClamp(settings.intensity, 0.0f, 100.0f, 55.0f);
    result.body = finiteClamp(settings.body, 0.0f, 100.0f, 30.0f);
    result.outputDb = finiteClamp(settings.outputDb, -18.0f, 6.0f, -1.5f);

    // A DSP model is an enum selector, not a numeric control: an out-of-range
    // value cannot be clamped into something the user meant, so the engine
    // falls back to the model the macOS CLI defaults to.
    if (!isKnownDSPModel(settings.dspModel)) {
        result.dspModel = dsp_model::circuit;
    }
    if (!isKnownOversamplingMode(settings.exciterOversamplingMode)) {
        result.exciterOversamplingMode = oversampling_mode::automatic;
    }

    if (settings.bufferMs < minBufferMs || settings.bufferMs > maxBufferMs) {
        result.bufferMs = defaultBufferMs;
    }

    result.listenerX = finiteClamp(settings.listenerX, -3.0f, 3.0f, 0.0f);
    result.listenerZ = finiteClamp(settings.listenerZ, -2.8f, 2.8f, 0.0f);
    result.speakerWidth = finiteClamp(settings.speakerWidth, 0.6f, 3.0f, 1.65f);
    result.space = finiteClamp(settings.space, 0.0f, 100.0f, 35.0f);

    // spatialEnabled is a switch, not a range: it is never clamped.
    return result;
}

bool parseDSPModel(const std::string& text, uint32_t& model) {
    const std::string cleaned = canonicalModelArgument(text);
    if (cleaned == "clean") {
        model = dsp_model::clean;
        return true;
    }
    if (cleaned == "circuit") {
        model = dsp_model::circuit;
        return true;
    }
    if (cleaned == "highexciter" || cleaned == "exciter") {
        model = dsp_model::high_exciter;
        return true;
    }
    return false;
}

bool parseOversamplingMode(const std::string& text, uint32_t& mode) {
    // macOS lowercases but does not strip separators here, so "1x" is a token
    // and "1 x" is not.
    const std::string cleaned = lowercased(text);
    if (cleaned == "auto") {
        mode = oversampling_mode::automatic;
        return true;
    }
    if (cleaned == "1" || cleaned == "1x") {
        mode = oversampling_mode::one_x;
        return true;
    }
    if (cleaned == "2" || cleaned == "2x") {
        mode = oversampling_mode::two_x;
        return true;
    }
    if (cleaned == "4" || cleaned == "4x") {
        mode = oversampling_mode::four_x;
        return true;
    }
    return false;
}

const char* dspModelName(uint32_t model) {
    // These spellings match DSPModel.displayName on macOS so both platforms
    // print the same labels.
    switch (model) {
        case dsp_model::clean: return "Clean";
        case dsp_model::circuit: return "Circuit";
        case dsp_model::high_exciter: return "HighExciter";
        // Model 0 is the bypass path, so an unrecognized value describes a
        // stage that is not shaping the signal, not a distinct third model.
        default: return "Clean";
    }
}

const char* oversamplingModeName(uint32_t mode) {
    switch (mode) {
        case oversampling_mode::automatic: return "auto";
        case oversampling_mode::one_x: return "1x";
        case oversampling_mode::two_x: return "2x";
        case oversampling_mode::four_x: return "4x";
        default: return "auto";
    }
}

LCSpatialSettings makeSpatialSettings(float sampleRate, const Settings& settings) {
    // Authoritative geometry: SpatialGeometry.cpp through DSPPrecompute, exactly
    // as the macOS engine calls it. Every distance, delay and gain rule
    // therefore lives in one place for both platforms, and the result is the C
    // POD the portable lowend::SpatialProcessor consumes directly.
    //
    // The values are normalized first so a caller that never normalized cannot
    // hand NaN/Inf to the geometry; the geometry would reject those and return
    // a disabled result either way, but normalizing keeps a finite
    // out-of-range control meaning what it means everywhere else.
    const Settings s = normalized(settings);
    return lowend::DSPPrecompute::makeSpatialSettings(
        sampleRate,
        s.listenerX,
        s.listenerZ,
        s.speakerWidth,
        s.space,
        s.spatialEnabled);
}

} // namespace lowend::win
