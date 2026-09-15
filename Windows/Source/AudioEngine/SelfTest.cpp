// SelfTest.cpp — offline checks for the Windows processing chain.
//
// Scope: the DSP stage, the spatial stage, the lock-free ring and control
// queue, argument parsing, settings normalization, and the routing rules that
// decide whether a capture/render pair can run. Every check runs the production
// code path, not a re-implementation.
//
// Explicitly out of scope: opening a WASAPI endpoint, negotiated period and
// latency, Bluetooth behaviour, device switching, and listening quality. Those
// require real hardware and are covered by Phase 3 validation.

#include "AudioEngine/SelfTest.h"

#include "AudioEngine/DspStage.h"
#include "AudioEngine/Devices.h"
#include "AudioEngine/RecoveryPolicy.h"
#include "AudioEngine/RouteDiagnosis.h"
#include "AudioEngine/Settings.h"
#include "CLI/CommandLine.h"
#include "Core/Core.h"
#include "Core/OutputConditioning.h"
#include "Core/SpatialProcessor.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

namespace lowend::win {
namespace {

int g_failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        ++g_failures;
        std::printf("  FAIL: %s\n", message);
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────

constexpr float kPi = 3.14159265358979323846f;

void fillSine(float* left, float* right, uint32_t frames, float sampleRate,
              float frequency, float amplitude) {
    for (uint32_t i = 0; i < frames; ++i) {
        const float value = amplitude * std::sin(2.0f * kPi * frequency * static_cast<float>(i) / sampleRate);
        left[i] = value;
        right[i] = value;
    }
}

double rms(const float* data, uint32_t frames, uint32_t skip = 0) {
    double total = 0.0;
    uint32_t count = 0;
    for (uint32_t i = skip; i < frames; ++i) {
        total += static_cast<double>(data[i]) * static_cast<double>(data[i]);
        ++count;
    }
    return count == 0 ? 0.0 : std::sqrt(total / static_cast<double>(count));
}

bool allFinite(const float* data, uint32_t frames) {
    for (uint32_t i = 0; i < frames; ++i) {
        if (!std::isfinite(data[i])) return false;
    }
    return true;
}

float peakMagnitude(const float* data, uint32_t frames) {
    float peak = 0.0f;
    for (uint32_t i = 0; i < frames; ++i) {
        peak = std::max(peak, std::fabs(data[i]));
    }
    return peak;
}

// Single-bin DFT (Goertzel). Measures one frequency precisely, which is what
// proves that a nonlinear stage produced a specific harmonic: a harmonic
// product appears at a frequency where the dry sine had no energy.
float toneMagnitude(const float* data, uint32_t frames, float sampleRate, float frequency) {
    const float omega = 2.0f * kPi * frequency / sampleRate;
    const float cosine = std::cos(omega);
    const float sine = std::sin(omega);
    const float coefficient = 2.0f * cosine;
    float s1 = 0.0f;
    float s2 = 0.0f;
    for (uint32_t i = 0; i < frames; ++i) {
        const float s0 = data[i] + coefficient * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    const float real = s1 - s2 * cosine;
    const float imaginary = s2 * sine;
    return std::sqrt(real * real + imaginary * imaginary) / (static_cast<float>(frames) * 0.5f);
}

// Band energy ratio: measures how much of the signal sits below `cutoff`
// relative to total energy, using a simple one-pole low/high split. Enough to
// prove that Circuit changes the low end and HighExciter changes the high end.
struct BandSplit {
    double lowEnergy = 0.0;
    double highEnergy = 0.0;
};

BandSplit splitBands(const float* data, uint32_t frames, float sampleRate, float cutoffHz) {
    const float alpha = 1.0f - std::exp(-2.0f * kPi * cutoffHz / sampleRate);
    float lowState = 0.0f;
    BandSplit result;
    for (uint32_t i = 0; i < frames; ++i) {
        lowState += alpha * (data[i] - lowState);
        const float high = data[i] - lowState;
        result.lowEnergy += static_cast<double>(lowState) * static_cast<double>(lowState);
        result.highEnergy += static_cast<double>(high) * static_cast<double>(high);
    }
    return result;
}

// ─── Settings ────────────────────────────────────────────────────────

void checkNormalization() {
    std::printf("settings normalization\n");

    Settings extreme;
    extreme.intensity = 1.0e9f;
    extreme.body = -1.0e9f;
    extreme.outputDb = 500.0f;
    extreme.listenerX = 100.0f;
    extreme.listenerZ = -100.0f;
    extreme.speakerWidth = 100.0f;
    extreme.space = 1000.0f;
    const Settings clamped = normalized(extreme);
    check(clamped.intensity == 100.0f, "intensity clamps to 100");
    check(clamped.body == 0.0f, "body clamps to 0");
    check(clamped.outputDb == 6.0f, "output clamps to +6 dB");
    check(clamped.listenerX == 3.0f, "listenerX clamps to 3 m");
    check(clamped.listenerZ == -2.8f, "listenerZ clamps to -2.8 m");
    check(clamped.speakerWidth == 3.0f, "speakerWidth clamps to 3 m");
    check(clamped.space == 100.0f, "space clamps to 100");

    // Non-finite values must fall back to the macOS defaults rather than
    // reaching the DSP as NaN.
    Settings nonFinite;
    nonFinite.intensity = std::nanf("");
    nonFinite.body = std::numeric_limits<float>::infinity();
    nonFinite.outputDb = -std::numeric_limits<float>::infinity();
    nonFinite.listenerX = std::nanf("");
    const Settings fallback = normalized(nonFinite);
    check(fallback.intensity == 55.0f, "NaN intensity falls back to 55");
    check(fallback.body == 30.0f, "Inf body falls back to 30");
    check(fallback.outputDb == -1.5f, "-Inf output falls back to -1.5 dB");
    check(fallback.listenerX == 0.0f, "NaN listenerX falls back to 0");

    Settings unknownModel;
    unknownModel.dspModel = 42;
    unknownModel.exciterOversamplingMode = 7;
    const Settings corrected = normalized(unknownModel);
    check(corrected.dspModel == dsp_model::circuit, "unknown model falls back to Circuit");
    check(corrected.exciterOversamplingMode == oversampling_mode::automatic,
          "unknown oversampling mode falls back to auto");
}

void checkArgumentParsing() {
    std::printf("argument parsing\n");

    uint32_t model = 99;
    check(parseDSPModel("HighExciter", model) && model == dsp_model::high_exciter,
          "model parsing accepts HighExciter");
    check(parseDSPModel("high-exciter", model) && model == dsp_model::high_exciter,
          "model parsing ignores separators");
    check(parseDSPModel("exciter", model) && model == dsp_model::high_exciter,
          "model parsing accepts the exciter alias");
    check(parseDSPModel("clean", model) && model == dsp_model::clean, "model parsing accepts clean");
    check(!parseDSPModel("bass", model), "model parsing rejects unknown values");

    uint32_t oversampling = 99;
    check(parseOversamplingMode("auto", oversampling) && oversampling == 0, "auto oversampling");
    check(parseOversamplingMode("4x", oversampling) && oversampling == 4, "4x oversampling");
    check(parseOversamplingMode("2", oversampling) && oversampling == 2, "bare 2 oversampling");
    check(!parseOversamplingMode("3x", oversampling), "oversampling rejects 3x");

    // Invalid input must be reported, never silently accepted, and must not
    // select a runnable command.
    const char* const invalidCases[][4] = {
        { "lowend_windows", "--intensity", "inf" },
        { "lowend_windows", "--output", "nan" },
        { "lowend_windows", "--listener-x", "NaN" },
        { "lowend_windows", "--stage-width", "-Infinity" },
        { "lowend_windows", "--spatial", "maybe" },
        { "lowend_windows", "--model", "bass" },
        { "lowend_windows", "--exciter-os", "3x" },
        { "lowend_windows", "--intensity", "notanumber" },
        { "lowend_windows", "--device" },
        { "lowend_windows", "--unknown-flag" },
        { "lowend_windows", "--self-test", "--device", "x" },
        { "lowend_windows", "--list-devices", "--model", "circuit" },
        { "lowend_windows", "--self-test", "--list-devices" },
    };
    for (const auto& testCase : invalidCases) {
        std::vector<char*> argv;
        for (const char* token : testCase) {
            if (token == nullptr) break;
            argv.push_back(const_cast<char*>(token));
        }
        const CommandLine parsed = parseCommandLine(static_cast<int>(argv.size()), argv.data());
        check(!parsed.rejectionReasons.empty(), "invalid arguments are rejected");
    }

    // A numeric argument must consume the entire token.
    {
        const char* argv[] = { "lowend_windows", "--intensity", "55abc" };
        const CommandLine parsed = parseCommandLine(3, const_cast<char**>(argv));
        check(!parsed.rejectionReasons.empty(), "partially numeric arguments are rejected");
    }

    // Valid input must be accepted and normalized.
    {
        const char* argv[] = { "lowend_windows", "--model", "circuit", "--intensity", "42",
                               "--body", "18", "--output", "-1.8", "--spatial", "on",
                               "--space", "20", "--buffer-ms", "10" };
        const CommandLine parsed = parseCommandLine(static_cast<int>(sizeof(argv) / sizeof(argv[0])),
                                                    const_cast<char**>(argv));
        check(parsed.rejectionReasons.empty(), "valid arguments are accepted");
        check(parsed.command == Command::run, "valid arguments select the run command");
        check(parsed.settings.intensity == 42.0f, "intensity is parsed");
        check(parsed.settings.outputDb == -1.8f, "output dB is parsed");
        check(parsed.settings.spatialEnabled, "spatial on is parsed");
        check(parsed.settings.space == 20.0f, "space is parsed");
        check(parsed.settings.bufferMs == 10, "buffer-ms is parsed");
    }

    // --input-device switches capture to a real input and disables loopback.
    {
        const char* argv[] = { "lowend_windows", "--input-device", "{abc}" };
        const CommandLine parsed = parseCommandLine(3, const_cast<char**>(argv));
        check(parsed.engine.captureFlow == DataFlow::capture, "input-device selects capture flow");
        check(!parsed.engine.loopback, "input-device disables loopback");
        check(parsed.engine.captureDeviceId == "{abc}", "input-device id is stored");
    }

    // --help must be a runnable, non-rejected command.
    {
        const char* argv[] = { "lowend_windows", "--help" };
        const CommandLine parsed = parseCommandLine(2, const_cast<char**>(argv));
        check(parsed.command == Command::help && parsed.rejectionReasons.empty(),
              "help is accepted alone");
        check(usageText().find("--list-devices") != std::string::npos, "usage documents --list-devices");
        check(usageText().find("--self-test") != std::string::npos, "usage documents --self-test");
    }
}

// ─── DSP stage ───────────────────────────────────────────────────────

void checkCleanIsBypass() {
    std::printf("DSP stage: Clean model\n");

    DspStage stage;
    std::string error;
    check(stage.prepare(48000, 2, error), "stage prepares at 48 kHz");

    Settings settings;
    settings.dspModel = dsp_model::clean;
    settings.intensity = 0.0f;
    settings.body = 0.0f;
    settings.outputDb = 0.0f;
    check(stage.applySettings(settings), "clean settings are queued");

    std::vector<float> left(512), right(512);
    fillSine(left.data(), right.data(), 512, 48000.0f, 1000.0f, 0.5f);
    const std::vector<float> originalLeft = left;
    stage.processBlock(left.data(), right.data(), 512);

    bool identical = true;
    for (size_t i = 0; i < left.size(); ++i) {
        if (left[i] != originalLeft[i]) {
            identical = false;
            break;
        }
    }
    check(identical, "Clean model is bit-identical to dry input");
}

void checkCircuitShapesLowEnd() {
    std::printf("DSP stage: Circuit model\n");

    DspStage stage;
    std::string error;
    check(stage.prepare(48000, 2, error), "stage prepares at 48 kHz");

    Settings settings;
    settings.dspModel = dsp_model::circuit;
    settings.intensity = 100.0f;
    settings.body = 100.0f;
    settings.outputDb = 0.0f;
    check(stage.applySettings(settings), "circuit settings are queued");

    // 60 Hz sits inside the low-shelf/body band.
    const uint32_t frames = 16384;
    std::vector<float> lowLeft(frames), lowRight(frames);
    fillSine(lowLeft.data(), lowRight.data(), frames, 48000.0f, 60.0f, 0.25f);
    const BandSplit dryLowBand = splitBands(lowLeft.data(), frames, 48000.0f, 200.0f);
    const float dryFundamental = toneMagnitude(lowLeft.data(), frames, 48000.0f, 60.0f);
    // A clean 60 Hz sine has essentially no energy at its harmonics.
    const float dryThirdHarmonic = toneMagnitude(lowLeft.data(), frames, 48000.0f, 180.0f);

    stage.processBlock(lowLeft.data(), lowRight.data(), frames);
    check(allFinite(lowLeft.data(), frames), "circuit output stays finite");

    // The shelf boosts the fundamental, so raw low-band energy must rise. The
    // ratio of low to high band is deliberately not used: the same nonlinear
    // stage that adds bass also adds harmonics, which pushes that ratio down
    // even as the low end gets louder.
    const BandSplit wetLowBand = splitBands(lowLeft.data(), frames, 48000.0f, 200.0f);
    check(wetLowBand.lowEnergy > dryLowBand.lowEnergy * 1.1,
          "circuit adds low-band energy below 200 Hz");

    // The asymmetric transformer stage must generate measurable harmonics. A
    // harmonic that was effectively absent in the input proves the nonlinear
    // stage ran, which a loudness-only check cannot show.
    const float wetThirdHarmonic = toneMagnitude(lowLeft.data(), frames, 48000.0f, 180.0f);
    check(wetThirdHarmonic > dryThirdHarmonic * 20.0f,
          "circuit generates a 3rd harmonic the dry input did not have");
    check(wetThirdHarmonic > 1.0e-4f, "the generated 3rd harmonic is measurable");

    const float wetFundamental = toneMagnitude(lowLeft.data(), frames, 48000.0f, 60.0f);
    if (!(wetFundamental > dryFundamental * 1.1f)) {
        std::printf("  note: dry 60 Hz = %.6f, wet 60 Hz = %.6f (ratio %.3f)\n",
                    static_cast<double>(dryFundamental), static_cast<double>(wetFundamental),
                    static_cast<double>(wetFundamental / dryFundamental));
    }
    check(wetFundamental > dryFundamental * 1.1f, "circuit boosts the 60 Hz fundamental");

    // Headroom: a loud input must not exceed full scale.
    std::vector<float> loudLeft(4096), loudRight(4096);
    fillSine(loudLeft.data(), loudRight.data(), 4096, 48000.0f, 45.0f, 0.98f);
    stage.processBlock(loudLeft.data(), loudRight.data(), 4096);
    check(peakMagnitude(loudLeft.data(), 4096) <= 1.0f,
          "circuit output protection keeps the peak at or below full scale");

    // The body control injects the 38 Hz sub-bass pole. Raising Body with the
    // same intensity must increase the fundamental's level. Measured at 45 Hz
    // with intensity held at the default so the body contribution dominates.
    const auto fundamentalAt = [](float body) {
        DspStage local;
        std::string localError;
        local.prepare(48000, 2, localError);
        Settings value;
        value.dspModel = dsp_model::circuit;
        value.intensity = 55.0f;
        value.body = body;
        value.outputDb = 0.0f;
        local.applySettings(value);
        std::vector<float> l(16384), r(16384);
        fillSine(l.data(), r.data(), 16384, 48000.0f, 45.0f, 0.3f);
        local.processBlock(l.data(), r.data(), 16384);
        return toneMagnitude(l.data(), 16384, 48000.0f, 45.0f);
    };
    const float noBody = fundamentalAt(0.0f);
    const float fullBody = fundamentalAt(100.0f);
    check(fullBody > noBody * 1.01f, "raising Body increases the sub-bass fundamental");
    check(noBody > 0.0f, "the sub-bass measurement is meaningful");
}

void checkExciterOversamplingPolicy() {
    std::printf("DSP stage: HighExciter oversampling policy\n");

    struct RateCase {
        float sampleRate;
        uint32_t expectedAutoFactor;
    };
    const RateCase rateCases[] = {
        { 44100.0f, 4 }, { 48000.0f, 4 }, { 88200.0f, 2 }, { 96000.0f, 2 },
        { 176400.0f, 1 }, { 192000.0f, 1 }, { 768000.0f, 1 },
    };
    for (const RateCase& rateCase : rateCases) {
        const LCDSPSettings dsp = lowend::DSPPrecompute::makeDSPSettings(
            rateCase.sampleRate, 100.0f, 100.0f, 0.0f, dsp_model::high_exciter,
            oversampling_mode::automatic);
        check(dsp.exciterOversampleFactor == rateCase.expectedAutoFactor,
              "auto oversampling matches the documented rate policy");
    }

    // Manual 4x must respect the 384 kHz internal ceiling.
    const LCDSPSettings limited = lowend::DSPPrecompute::makeDSPSettings(
        192000.0f, 100.0f, 100.0f, 0.0f, dsp_model::high_exciter, oversampling_mode::four_x);
    check(limited.exciterOversampleFactor == 2, "manual 4x at 192 kHz is limited to 2x");
    const LCDSPSettings at96k = lowend::DSPPrecompute::makeDSPSettings(
        96000.0f, 100.0f, 100.0f, 0.0f, dsp_model::high_exciter, oversampling_mode::four_x);
    check(at96k.exciterOversampleFactor == 4, "manual 4x at 96 kHz is honored");
}

void checkExciterAddsHighHarmonics() {
    std::printf("DSP stage: HighExciter processing\n");

    // Wet Mix 0 must return the dry signal untouched. This is a documented
    // contract of the oversampling stage: the dry path never enters the
    // interpolation/decimation filters.
    {
        DspStage stage;
        std::string error;
        check(stage.prepare(48000, 2, error), "stage prepares at 48 kHz");
        Settings dryMix;
        dryMix.dspModel = dsp_model::high_exciter;
        dryMix.intensity = 100.0f;  // drive, but no wet
        dryMix.body = 0.0f;         // wet mix 0
        dryMix.outputDb = 0.0f;
        check(stage.applySettings(dryMix), "zero-wet exciter settings are queued");

        std::vector<float> left(4096), right(4096);
        fillSine(left.data(), right.data(), 4096, 48000.0f, 15000.0f, 0.5f);
        const std::vector<float> originalLeft = left;
        stage.processBlock(left.data(), right.data(), 4096);
        bool identical = true;
        for (size_t i = 0; i < left.size(); ++i) {
            if (left[i] != originalLeft[i]) {
                identical = false;
                break;
            }
        }
        check(identical, "Wet Mix 0 is bit-identical to the dry signal");
    }

    const auto process15k = [](uint32_t oversamplingMode, std::vector<float>& left, std::vector<float>& right) {
        DspStage stage;
        std::string error;
        stage.prepare(48000, 2, error);
        Settings settings;
        settings.dspModel = dsp_model::high_exciter;
        settings.intensity = 100.0f;  // drive
        settings.body = 100.0f;       // wet mix
        settings.outputDb = 0.0f;
        settings.exciterOversamplingMode = oversamplingMode;
        stage.applySettings(settings);
        fillSine(left.data(), right.data(), static_cast<uint32_t>(left.size()), 48000.0f, 15000.0f, 0.5f);
        stage.processBlock(left.data(), right.data(), static_cast<uint32_t>(left.size()));
    };

    const uint32_t frames = 16384;
    std::vector<float> oversampledLeft(frames), oversampledRight(frames);
    std::vector<float> plainLeft(frames), plainRight(frames);
    process15k(oversampling_mode::automatic, oversampledLeft, oversampledRight);  // 4x at 48 kHz
    process15k(oversampling_mode::one_x, plainLeft, plainRight);

    check(allFinite(oversampledLeft.data(), frames), "4x exciter output stays finite");
    check(allFinite(plainLeft.data(), frames), "1x exciter output stays finite");
    check(rms(oversampledLeft.data(), frames, 2048) > 0.0, "4x exciter produces output");

    // A 15 kHz sine driven into a polynomial nonlinearity generates harmonics
    // at 30 kHz and 45 kHz. At 1x those fold back into the audible band as
    // aliases (18 kHz and 3 kHz). The 4x path low-passes before decimation, so
    // the same harmonics are attenuated instead of aliased. Measuring the alias
    // bins is what proves the oversampling stage is doing its job.
    //
    // The margin is large — roughly two orders of magnitude — because the
    // anti-alias filter rejects the folded products rather than attenuating them
    // slightly. A threshold well below the observed gap still fails if the
    // oversampling stage is bypassed, which is the regression this guards.
    const float alias4xLow = toneMagnitude(oversampledLeft.data(), frames, 48000.0f, 3000.0f);
    const float alias1xLow = toneMagnitude(plainLeft.data(), frames, 48000.0f, 3000.0f);
    check(alias1xLow > alias4xLow * 10.0f,
          "4x oversampling reduces the 3 kHz alias of the 45 kHz harmonic");

    const float alias4xHigh = toneMagnitude(oversampledLeft.data(), frames, 48000.0f, 18000.0f);
    const float alias1xHigh = toneMagnitude(plainLeft.data(), frames, 48000.0f, 18000.0f);
    check(alias1xHigh > alias4xHigh * 10.0f,
          "4x oversampling reduces the 18 kHz alias of the 30 kHz harmonic");

    // The harmonic content must be real: drive 0 must not add the alias the
    // driven signal produces.
    std::vector<float> undrivenLeft(frames), undrivenRight(frames);
    {
        DspStage stage;
        std::string error;
        stage.prepare(48000, 2, error);
        Settings settings;
        settings.dspModel = dsp_model::high_exciter;
        settings.intensity = 0.0f;  // no drive
        settings.body = 100.0f;     // full wet
        settings.outputDb = 0.0f;
        settings.exciterOversamplingMode = oversampling_mode::one_x;
        stage.applySettings(settings);
        fillSine(undrivenLeft.data(), undrivenRight.data(), frames, 48000.0f, 15000.0f, 0.5f);
        stage.processBlock(undrivenLeft.data(), undrivenRight.data(), frames);
    }
    const float undrivenAlias = toneMagnitude(undrivenLeft.data(), frames, 48000.0f, 3000.0f);
    check(alias1xLow > undrivenAlias + 1.0e-5f, "exciter drive is what creates the alias product");
}

void checkModelTransition() {
    std::printf("DSP stage: model transition\n");

    DspStage stage;
    std::string error;
    check(stage.prepare(48000, 2, error), "stage prepares at 48 kHz");

    Settings clean;
    clean.dspModel = dsp_model::clean;
    clean.intensity = 0.0f;
    clean.body = 0.0f;
    clean.outputDb = 0.0f;
    check(stage.applySettings(clean), "clean settings are queued");

    std::vector<float> left(256), right(256);
    fillSine(left.data(), right.data(), 256, 48000.0f, 1000.0f, 0.25f);
    stage.processBlock(left.data(), right.data(), 256);

    Settings circuit;
    circuit.dspModel = dsp_model::circuit;
    circuit.intensity = 100.0f;
    circuit.body = 60.0f;
    circuit.outputDb = 0.0f;
    check(stage.applySettings(circuit), "circuit settings are queued after clean");

    // The first block after a model change is a crossfade, so it must stay
    // finite and bounded instead of clicking to full scale.
    std::vector<float> transitionLeft(256), transitionRight(256);
    fillSine(transitionLeft.data(), transitionRight.data(), 256, 48000.0f, 1000.0f, 0.25f);
    stage.processBlock(transitionLeft.data(), transitionRight.data(), 256);
    check(allFinite(transitionLeft.data(), 256), "transition output stays finite");
    float peak = 0.0f;
    for (float value : transitionLeft) peak = std::max(peak, std::fabs(value));
    check(peak < 2.0f, "transition stays bounded during the crossfade");

    std::vector<float> settledLeft(2048), settledRight(2048);
    fillSine(settledLeft.data(), settledRight.data(), 2048, 48000.0f, 60.0f, 0.25f);
    stage.processBlock(settledLeft.data(), settledRight.data(), 2048);
    check(stage.activeModel() == dsp_model::circuit, "active model reports circuit after the fade");
    check(stage.appliedRevision() > 0, "queued settings reached the audio thread");
}

void checkRepeatedRetargets() {
    std::printf("DSP stage: repeated retargets\n");

    DspStage stage;
    std::string error;
    check(stage.prepare(48000, 2, error), "stage prepares at 48 kHz");

    std::vector<float> left(512), right(512);

    Settings base;
    base.dspModel = dsp_model::circuit;
    base.intensity = 80.0f;
    base.body = 40.0f;
    base.outputDb = 0.0f;
    check(stage.applySettings(base), "initial settings are queued");
    fillSine(left.data(), right.data(), 512, 48000.0f, 80.0f, 0.25f);
    stage.processBlock(left.data(), right.data(), 512);

    // Queue several changes back to back. The engine must keep processing
    // instead of stalling, and the final state must be the last requested one.
    for (int i = 0; i < 8; ++i) {
        Settings next = base;
        next.intensity = 20.0f + static_cast<float>(i) * 5.0f;
        check(stage.applySettings(next), "retarget settings are queued");
    }

    Settings finalSettings = base;
    finalSettings.dspModel = dsp_model::clean;
    finalSettings.intensity = 0.0f;
    finalSettings.body = 0.0f;
    check(stage.applySettings(finalSettings), "final clean settings are queued");

    // Wait out the 256-frame fade plus the pending snapshot, then the last
    // requested model must be the active one.
    for (int block = 0; block < 8; ++block) {
        fillSine(left.data(), right.data(), 512, 48000.0f, 80.0f, 0.25f);
        stage.processBlock(left.data(), right.data(), 512);
    }
    check(stage.activeModel() == dsp_model::clean, "last requested model becomes active");
    check(allFinite(left.data(), 512), "retarget sequence keeps output finite");
}

// ─── Spatial stage ───────────────────────────────────────────────────

void checkSpatialGeometryPlan() {
    std::printf("spatial: geometry plan\n");

    Settings settings;
    settings.spatialEnabled = true;
    settings.listenerX = 0.0f;
    settings.listenerZ = 0.0f;
    settings.speakerWidth = 1.65f;
    settings.space = 35.0f;
    const LCSpatialSettings plan = makeSpatialSettings(48000.0f, settings);
    check(plan.enabled != 0, "centered listener produces an enabled plan");
    check(plan.amount > 0.0f && plan.amount <= 1.0f, "plan amount is normalized");
    check(plan.ll.delaySamples < lowend::SpatialProcessor::delayCapacity,
          "left path delay fits the capacity");
    check(plan.rr.delaySamples < lowend::SpatialProcessor::delayCapacity,
          "right path delay fits the capacity");
    check(plan.ll.gain > 0.0f && plan.rr.gain > 0.0f, "direct paths have gain");

    // Moving the listener right must change the left path delay.
    Settings moved = settings;
    moved.listenerX = 1.0f;
    const LCSpatialSettings movedPlan = makeSpatialSettings(48000.0f, moved);
    check(movedPlan.ll.delaySamples != plan.ll.delaySamples,
          "listener position changes the path delay");

    // Disabled spatial must collapse to a disabled setting.
    Settings disabled = settings;
    disabled.spatialEnabled = false;
    const LCSpatialSettings off = makeSpatialSettings(48000.0f, disabled);
    check(off.enabled == 0, "disabled spatial produces a disabled plan");

    // Unsupported sample rate must not produce a live plan.
    const LCSpatialSettings badRate = makeSpatialSettings(1000.0f, settings);
    check(badRate.enabled == 0, "unsupported sample rate disables spatial");

    // The geometry is shared with macOS, so the applied delay must never exceed
    // the capacity both delay lines are built with.
    Settings extreme;
    extreme.spatialEnabled = true;
    extreme.speakerWidth = 3.0f;
    extreme.listenerX = -3.0f;
    extreme.listenerZ = 2.8f;
    extreme.space = 100.0f;
    const LCSpatialSettings extremePlan = makeSpatialSettings(768000.0f, extreme);
    check(extremePlan.ll.delaySamples < lowend::SpatialProcessor::delayCapacity,
          "768 kHz plan fits the delay capacity");
    check(extremePlan.lr.delaySamples < lowend::SpatialProcessor::delayCapacity,
          "768 kHz crossfeed delay fits");
    check(extremePlan.rl.delaySamples < lowend::SpatialProcessor::delayCapacity,
          "768 kHz crossfeed delay fits");
    check(extremePlan.rr.delaySamples < lowend::SpatialProcessor::delayCapacity,
          "768 kHz plan fits the delay capacity");
}

void checkSpatialBypassAndActivation() {
    std::printf("spatial: bypass and activation\n");

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);

    LCSpatialSettings off {};
    off.enabled = 0;
    off.amount = 0.0f;
    spatial.update(off);

    float left = 0.5f;
    float right = -0.25f;
    spatial.process(left, right);
    check(left == 0.5f && right == -0.25f, "disabled spatial is bit-exact bypass");

    // After a fade to an active plan the output must differ but stay finite.
    Settings settings;
    settings.spatialEnabled = true;
    settings.space = 60.0f;
    const LCSpatialSettings active = makeSpatialSettings(48000.0f, settings);
    spatial.update(active);

    bool changed = false;
    for (int i = 0; i < 4096; ++i) {
        float l = std::sin(0.05f * static_cast<float>(i));
        float r = l;
        const float before = l;
        spatial.process(l, r);
        if (!std::isfinite(l) || !std::isfinite(r)) {
            check(false, "spatial output stays finite");
            return;
        }
        if (std::fabs(l - before) > 1.0e-6f) changed = true;
    }
    check(changed, "active spatial changes the signal");

    // Returning to bypass must be exact again once the fade completes.
    spatial.update(off);
    for (uint32_t i = 0; i < lowend::SpatialProcessor::transitionFrames * 2; ++i) {
        float l = 0.3f;
        float r = 0.3f;
        spatial.process(l, r);
    }
    float l = 0.3f;
    float r = 0.3f;
    spatial.process(l, r);
    check(std::fabs(l - 0.3f) < 1.0e-6f, "spatial returns to bypass after the fade");
}

void checkSpatialStaysFiniteAtHighRate() {
    std::printf("spatial: high-rate stability\n");

    lowend::SpatialProcessor spatial;
    spatial.prepare(768000.0f);

    Settings settings;
    settings.spatialEnabled = true;
    settings.speakerWidth = 3.0f;
    settings.listenerX = -3.0f;
    settings.listenerZ = 2.8f;
    settings.space = 100.0f;
    spatial.update(makeSpatialSettings(768000.0f, settings));

    for (int i = 0; i < 65536; ++i) {
        float l = 0.6f * std::sin(0.01f * static_cast<float>(i));
        float r = l;
        spatial.process(l, r);
        if (!std::isfinite(l) || !std::isfinite(r) || std::fabs(l) > 8.0f) {
            check(false, "768 kHz spatial output stays finite and bounded");
            return;
        }
    }
    check(true, "768 kHz spatial output stays finite and bounded");
}

// ─── Ring buffer and control queue ───────────────────────────────────

void checkRingBufferUnderrun() {
    std::printf("ring buffer: underrun and overrun accounting\n");

    LCLockFreeRingBuffer* ring = lc_ring_buffer_create(1024);
    check(ring != nullptr, "ring buffer is created");
    if (ring == nullptr) return;

    // The ring counts samples, not frames: 256 stereo frames is 512 interleaved
    // samples, so the producer hands over L,R pairs.
    constexpr uint32_t pushedFrames = 256;
    std::vector<float> interleaved(pushedFrames * 2);
    for (uint32_t frame = 0; frame < pushedFrames; ++frame) {
        interleaved[frame * 2] = 0.5f;
        interleaved[frame * 2 + 1] = -0.5f;
    }
    const uint32_t pushed = lc_ring_buffer_push(
        ring, interleaved.data(), static_cast<uint32_t>(interleaved.size()));
    check(pushed == interleaved.size(), "ring accepts a full write");

    // Asking for more frames than are available must zero-fill and count the
    // shortfall. The interleaved API works in frames; the diagnostics count the
    // missing samples, which is the frame shortfall times two channels.
    std::vector<float> outLeft(512, 1.0f), outRight(512, 1.0f);
    const uint32_t popped = lc_ring_buffer_pop_deinterleaved_stereo(
        ring, outLeft.data(), outRight.data(), 512);
    check(popped == pushedFrames, "pop reports the frames actually read");
    check(outLeft[255] == 0.5f, "available samples are returned");
    check(outLeft[256] == 0.0f && outRight[511] == 0.0f, "starved frames are zero-filled");
    check(lc_ring_buffer_underrun_samples(ring) == (512 - pushedFrames) * 2,
          "underrun accounting counts the missing samples, both channels");

    // Overrunning the ring must be reported rather than silently losing data.
    // The capacity rounds up to a power of two, so a 1024-sample request gives
    // room for exactly 1024 samples.
    std::vector<float> large(4096, 0.1f);
    const uint32_t overrun = lc_ring_buffer_push(ring, large.data(), static_cast<uint32_t>(large.size()));
    check(overrun == lc_ring_buffer_capacity(ring), "overrun write is truncated to the capacity");
    check(lc_ring_buffer_dropped_write_samples(ring) == 4096 - lc_ring_buffer_capacity(ring),
          "dropped-write accounting counts the rejected samples");

    lc_ring_buffer_destroy(ring);
}

void checkControlQueueRevision() {
    std::printf("control queue: revision acknowledgement\n");

    LCControlEventQueue* queue = lc_control_event_queue_create(8);
    check(queue != nullptr, "control queue is created");
    if (queue == nullptr) return;

    check(lc_control_event_queue_applied_revision(queue) == 0, "applied revision starts at zero");

    LCControlEvent event {};
    event.type = LC_CONTROL_EVENT_DSP;
    event.revision = 1;
    event.dsp = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 50.0f, 30.0f, 0.0f, dsp_model::circuit);
    check(lc_control_event_queue_push(queue, &event) == 1, "event is queued");

    LCControlEvent popped {};
    check(lc_control_event_queue_pop(queue, &popped) == 1, "event is dequeued");
    check(popped.revision == 1, "event revision round-trips");
    check(popped.dsp.dspModel == dsp_model::circuit, "event payload round-trips");
    check(lc_control_event_queue_applied_revision(queue) == 0,
          "revision is not applied before acknowledgement");
    lc_control_event_queue_acknowledge(queue, popped.revision);
    check(lc_control_event_queue_applied_revision(queue) == 1, "acknowledgement is published");

    lc_control_event_queue_destroy(queue);
}

void checkDspStageThreading() {
    std::printf("DSP stage: control thread to audio thread handoff\n");

    DspStage stage;
    std::string error;
    check(stage.prepare(48000, 2, error), "stage prepares");

    Settings first;
    first.dspModel = dsp_model::clean;
    first.intensity = 0.0f;
    first.body = 0.0f;
    first.outputDb = 0.0f;
    check(stage.applySettings(first), "first settings are queued");

    std::vector<float> left(128, 0.25f), right(128, 0.25f);
    stage.processBlock(left.data(), right.data(), 128);
    const uint64_t firstRevision = stage.appliedRevision();
    check(firstRevision == 1, "first revision is applied");

    Settings second = first;
    second.dspModel = dsp_model::circuit;
    second.intensity = 70.0f;
    check(stage.applySettings(second), "second settings are queued");
    check(stage.appliedRevision() == firstRevision,
          "queued settings are not applied until the audio thread runs");

    fillSine(left.data(), right.data(), 128, 48000.0f, 1000.0f, 0.3f);
    stage.processBlock(left.data(), right.data(), 128);
    check(stage.appliedRevision() == firstRevision + 1, "next block applies the queued revision");
    check(stage.activeModel() == dsp_model::circuit, "applied model is reported");
}

void checkDiscontinuityResetsState() {
    std::printf("DSP stage: discontinuity reset\n");

    DspStage stage;
    std::string error;
    check(stage.prepare(48000, 2, error), "stage prepares");

    Settings settings;
    settings.dspModel = dsp_model::circuit;
    settings.intensity = 100.0f;
    settings.body = 80.0f;
    settings.outputDb = 0.0f;
    check(stage.applySettings(settings), "settings are queued");

    const uint32_t frames = 2048;
    std::vector<float> left(frames), right(frames);
    fillSine(left.data(), right.data(), frames, 48000.0f, 50.0f, 0.5f);
    stage.processBlock(left.data(), right.data(), frames);
    check(allFinite(left.data(), frames), "steady-state output is finite");

    // A discontinuity must clear filter memory so a gap is not bridged.
    stage.resetForDiscontinuity();
    std::vector<float> silence(frames, 0.0f);
    stage.processBlock(silence.data(), silence.data(), frames);

    // After a reset, silence in must converge to silence out.
    std::vector<float> tail(2048, 0.0f);
    stage.processBlock(tail.data(), tail.data(), 2048);
    const double tailRms = rms(tail.data(), 2048, 512);
    check(tailRms < 1.0e-4, "reset collapses filter memory so silence decays to silence");
}

void checkRecoveryPolicy() {
    std::printf("recovery: device-failure policy\n");

    // An orderly stop reports no failure at all, so the engine must not treat it
    // as a device problem and must not count it as one.
    check(RecoveryPolicy::decide(DeviceError::none, 0) == RecoveryAction::none,
          "an unclassified failure is not a device error");

    // A lost endpoint is reopenable until the bounded budget runs out, then the
    // engine stops instead of spinning against a dead device.
    check(RecoveryPolicy::decide(DeviceError::deviceLost, 0) == RecoveryAction::reopen,
          "a lost device is reopened on the first failure");
    check(RecoveryPolicy::decide(DeviceError::deviceLost, maxDeviceReopenAttempts - 1)
              == RecoveryAction::reopen,
          "a lost device is still reopened on the last budgeted attempt");
    check(RecoveryPolicy::decide(DeviceError::deviceLost, maxDeviceReopenAttempts)
              == RecoveryAction::giveUp,
          "a lost device stops being retried once the budget is spent");
    check(RecoveryPolicy::decide(DeviceError::deviceLost, maxDeviceReopenAttempts + 5)
              == RecoveryAction::giveUp,
          "the budget cannot be exceeded");

    // A wrong request would fail identically on every reopen, so retrying it
    // only delays the inevitable while holding the audio thread.
    check(RecoveryPolicy::decide(DeviceError::fatal, 0) == RecoveryAction::giveUp,
          "an unrecoverable failure is not retried");

    // The backoff must start small and stay bounded, and must never grow without
    // limit for a large attempt count.
    check(reopenDelayMs(0) == 0, "there is no delay before the first attempt");
    check(reopenDelayMs(1) > 0, "reopen attempts are delayed");
    check(reopenDelayMs(2) > reopenDelayMs(1), "the delay grows between attempts");
    check(reopenDelayMs(1000) <= 1000, "the delay is capped");
    check(reopenDelayMs(maxDeviceReopenAttempts) <= 1000,
          "the delay stays capped for the whole budget");

    // The budget spans enough real time to cover a device that has to
    // re-enumerate, which is the case this exists for. The band is pinned
    // against the figure the header and the user documentation quote (about
    // 4.9 s): a floor-only check would pass for any larger budget, so it could
    // not catch the span drifting away from what the docs tell the user to
    // expect.
    uint32_t totalMs = 0;
    for (uint32_t attempt = 1; attempt <= maxDeviceReopenAttempts; ++attempt) {
        totalMs += reopenDelayMs(attempt);
    }
    check(totalMs >= 4500 && totalMs <= 5500,
          "the retry budget spans about 4.9 s of wall time, as documented");
    check(totalMs == 4850, "the retry budget matches the documented sum exactly");

    // The endpoint collision rule that both the start check and the reopen
    // checks rely on. Comparing hashes is what lets a reopen on one audio thread
    // test the other side's endpoint without reading a string that thread owns.
    //
    // These use the hash form rather than the ids themselves: the same id hashes
    // equal, different ids hash apart, and "no endpoint" (0) never matches, so a
    // side that is closed or failed to report its id cannot be read as a
    // collision. That last case is the one that matters - treating "unknown" as
    // a match would stop a healthy stream.
    const std::string defaultOutput = "{0.0.0.00000000}.{c8ab9a54-56f9-427b-b2a4-e4f28822f899}";
    const std::string otherOutput = "{0.0.0.00000000}.{889f15cf-7c47-42b5-9a7e-18c59fe8f0d2}";
    check(endpointsCollide(endpointHash(defaultOutput), endpointHash(defaultOutput)),
          "the same endpoint id collides");
    check(!endpointsCollide(endpointHash(defaultOutput), endpointHash(otherOutput)),
          "different endpoint ids do not collide");
    check(!endpointsCollide(0, 0), "two closed endpoints do not collide");
    check(!endpointsCollide(0, endpointHash(defaultOutput)),
          "a closed side does not collide with an open one");
    check(endpointHash("") == 0, "an absent id hashes to the no-endpoint value");
    check(endpointHash(defaultOutput) != 0, "a real id does not hash to the no-endpoint value");

    // The policy object tracks its own budget when a caller uses that form.
    RecoveryPolicy tracked;
    check(tracked.decide(DeviceError::deviceLost) == RecoveryAction::reopen,
          "a fresh policy reopens");
    for (uint32_t i = 0; i < maxDeviceReopenAttempts; ++i) {
        tracked.noteAttempt();
    }
    check(tracked.attempts() == maxDeviceReopenAttempts, "attempts are counted");
    check(tracked.decide(DeviceError::deviceLost) == RecoveryAction::giveUp,
          "a spent policy gives up");
    tracked.reset();
    check(tracked.decide(DeviceError::deviceLost) == RecoveryAction::reopen,
          "reset restores the budget for the next failure");
}

// Synthetic endpoints for the routing rules.
//
// The rules take the endpoints they judge rather than looking them up, so they
// can be covered here on a machine with no sound card — including the case that
// matters most and cannot be reproduced on demand: the two endpoints of one
// virtual audio cable, which have different ids and are still one signal path.
DeviceInfo syntheticEndpoint(const char* id, const char* name, const char* container, const char* bus,
                             bool isDefault, const char* formFactor = "Speakers") {
    DeviceInfo device;
    device.id = id;
    device.name = name;
    device.containerId = container;
    device.enumeratorName = bus;
    device.isDefault = isDefault;
    device.formFactor = formFactor;
    device.mixChannels = 2;
    device.mixSampleRate = 48000;
    device.mixBitsPerSample = 32;
    device.loopbackCapable = true;
    return device;
}

EndpointIdentity identityOfEndpoint(const DeviceInfo& device) {
    EndpointIdentity identity;
    identity.id = device.id;
    identity.containerId = device.containerId;
    identity.enumeratorName = device.enumeratorName;
    return identity;
}

void checkRouteFeedbackRule() {
    std::printf("routing: pass-through feedback rule\n");

    // A virtual audio cable. Both sides are root-enumerated (a driver instantiates
    // the device) and both belong to one device instance, which is what makes the
    // recording side carry whatever is played into the playback side.
    const std::string cableContainer = "{5b1a8f60-1c4c-4c2f-9a2b-0d0e6a2b7c31}";
    const DeviceInfo cablePlayback = syntheticEndpoint(
        "{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}", "CABLE Input",
        cableContainer.c_str(), "ROOT", false);
    const DeviceInfo cableRecording = syntheticEndpoint(
        "{0.0.1.00000000}.{22222222-2222-2222-2222-222222222222}", "CABLE Output",
        cableContainer.c_str(), "ROOT", false);
    // A physical output, on a hardware bus.
    const DeviceInfo physicalOutput = syntheticEndpoint(
        "{0.0.0.00000000}.{33333333-3333-3333-3333-333333333333}", "Fosi Audio ZH3",
        "{9d0c3dd0-2e9b-4f2a-8f4e-6b1f4a2d5c70}", "USB", true);
    // A USB headset: its microphone and its speakers share one device instance
    // and one bus, but they carry two independent signals.
    const std::string headsetContainer = "{0b6a2f14-8e3d-4d6a-9a17-2f3c4d5e6f70}";
    const DeviceInfo headsetSpeakers = syntheticEndpoint(
        "{0.0.0.00000000}.{44444444-4444-4444-4444-444444444444}", "Headset", 
        headsetContainer.c_str(), "USB", false, "Headphones");
    const DeviceInfo headsetMic = syntheticEndpoint(
        "{0.0.1.00000000}.{55555555-5555-5555-5555-555555555555}", "Headset Microphone",
        headsetContainer.c_str(), "USB", false, "Microphone");
    // A second, unrelated software device: a different instance, so a different
    // signal path even on the same bus.
    const DeviceInfo otherVirtual = syntheticEndpoint(
        "{0.0.0.00000000}.{66666666-6666-6666-6666-666666666666}", "Streaming Speakers",
        "{7c2f9a44-3d51-4b0e-8c22-1a9f0e5b6d80}", "ROOT", false);

    // The rule itself: two sides of one virtual device are one signal path even
    // though their endpoint ids differ. This is the case the endpoint-id check
    // cannot see, and the reason the check is not "different ids, therefore safe".
    check(passThroughKeysCollide(virtualPassThroughKey(identityOfEndpoint(cablePlayback)),
                                 virtualPassThroughKey(identityOfEndpoint(cableRecording))),
          "the playback and recording sides of one virtual cable collide");
    // One side of the cable against a physical output is the documented route and
    // must stay allowed.
    check(!passThroughKeysCollide(virtualPassThroughKey(identityOfEndpoint(cableRecording)),
                                  virtualPassThroughKey(identityOfEndpoint(physicalOutput))),
          "a cable's recording side does not collide with a physical output");
    check(!passThroughKeysCollide(virtualPassThroughKey(identityOfEndpoint(cablePlayback)),
                                  virtualPassThroughKey(identityOfEndpoint(physicalOutput))),
          "a cable's playback side does not collide with a physical output");
    // Hardware that shares one device instance is not a pass-through: refusing
    // these would break an ordinary headset microphone into its own speakers.
    check(!passThroughKeysCollide(virtualPassThroughKey(identityOfEndpoint(headsetMic)),
                                  virtualPassThroughKey(identityOfEndpoint(headsetSpeakers))),
          "a headset's microphone and speakers are not one signal path");
    check(!passThroughKeysCollide(virtualPassThroughKey(identityOfEndpoint(cablePlayback)),
                                  virtualPassThroughKey(identityOfEndpoint(otherVirtual))),
          "two different virtual devices do not collide");
    // Nothing identifiable: a closed side, or a container the property store did
    // not return. Treated as "cannot collide", because refusing a route on an
    // unreadable property would break working setups, while the endpoint-id check
    // still catches the same-endpoint case.
    EndpointIdentity unreadable = identityOfEndpoint(cablePlayback);
    unreadable.containerId.clear();
    check(virtualPassThroughKey(unreadable) == 0,
          "an endpoint whose container is unreadable has no pass-through key");
    check(!passThroughKeysCollide(virtualPassThroughKey(unreadable), 0),
          "an unidentifiable side never collides");
    check(virtualPassThroughKey(EndpointIdentity()) == 0,
          "an empty identity has no pass-through key");

    // The complete rule the engine applies, at start and after every reopen: the
    // two conditions are one predicate so the three call sites cannot drift.
    const uint64_t cableKey = virtualPassThroughKey(identityOfEndpoint(cablePlayback));
    const uint64_t recordingKey = virtualPassThroughKey(identityOfEndpoint(cableRecording));
    const uint64_t physicalKey = virtualPassThroughKey(identityOfEndpoint(physicalOutput));
    check(routeFormsFeedbackLoop(0, 0, cableKey, recordingKey),
          "the combined rule catches a cable used on both sides");
    check(routeFormsFeedbackLoop(endpointHash(physicalOutput.id), endpointHash(physicalOutput.id),
                                 0, 0),
          "the combined rule catches one endpoint used on both sides");
    check(!routeFormsFeedbackLoop(endpointHash(physicalOutput.id),
                                  endpointHash(cableRecording.id), recordingKey, physicalKey),
          "the documented cable route passes the combined rule");
    check(!routeFormsFeedbackLoop(0, 0, 0, 0),
          "two unidentifiable sides do not trip the combined rule");
}

void checkRouteSelectionDiagnosis() {
    std::printf("routing: endpoint selection and capture mode\n");

    const std::string cableContainer = "{5b1a8f60-1c4c-4c2f-9a2b-0d0e6a2b7c31}";
    const DeviceInfo physicalOutput = syntheticEndpoint(
        "{0.0.0.00000000}.{33333333-3333-3333-3333-333333333333}", "Fosi Audio ZH3",
        "{9d0c3dd0-2e9b-4f2a-8f4e-6b1f4a2d5c70}", "USB", true);
    const DeviceInfo cablePlayback = syntheticEndpoint(
        "{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}", "CABLE Input",
        cableContainer.c_str(), "ROOT", false);
    const DeviceInfo cableRecording = syntheticEndpoint(
        "{0.0.1.00000000}.{22222222-2222-2222-2222-222222222222}", "CABLE Output",
        cableContainer.c_str(), "ROOT", false);
    const DeviceInfo microphone = syntheticEndpoint(
        "{0.0.1.00000000}.{77777777-7777-7777-7777-777777777777}", "USB Microphone",
        "{1f3e5a2b-6c4d-4e8f-9a01-2b3c4d5e6f71}", "USB", true, "Microphone");

    const std::vector<DeviceInfo> outputs = { physicalOutput, cablePlayback };
    const std::vector<DeviceInfo> inputs = { microphone, cableRecording };

    RouteSelection inputToOutput;
    inputToOutput.captureId = microphone.id;
    inputToOutput.renderId = physicalOutput.id;
    inputToOutput.captureFlow = DataFlow::capture;
    inputToOutput.loopback = false;
    const RouteDiagnosis ready = diagnoseRoute(inputToOutput, outputs, inputs);
    check(ready.ok(), "a real input into a physical output is accepted");
    check(ready.haveCapture && ready.capture.id == microphone.id,
          "the accepted route reports the capture endpoint it resolved");
    check(ready.haveRender && ready.render.id == physicalOutput.id,
          "the accepted route reports the render endpoint it resolved");

    // The milestone route: the cable's recording side as an input, the physical
    // output for playback.
    RouteSelection cableToOutput = inputToOutput;
    cableToOutput.captureId = cableRecording.id;
    const RouteDiagnosis milestone = diagnoseRoute(cableToOutput, outputs, inputs);
    check(milestone.ok(), "the cable recording side into a physical output is accepted");
    bool mentionedMilestone = false;
    for (const std::string& note : milestone.notes) {
        if (note.find("installing a virtual audio driver") != std::string::npos) {
            mentionedMilestone = true;
        }
    }
    check(!mentionedMilestone,
          "a machine whose cable exists is not told to install one");

    // A cable used on both sides: different endpoint ids, one signal path.
    RouteSelection cableLoop = cableToOutput;
    cableLoop.renderId = cablePlayback.id;
    const RouteDiagnosis loop = diagnoseRoute(cableLoop, outputs, inputs);
    check(loop.issue == RouteIssue::virtualPassThroughPair,
          "a virtual cable used on both sides is refused as a pass-through pair");
    check(loop.cause.find("comes back on its recording side") != std::string::npos,
          "the cable refusal explains the signal path, not just the ids");
    check(loop.cause.find(cablePlayback.name) != std::string::npos &&
              loop.cause.find(cableRecording.name) != std::string::npos,
          "the cable refusal names both endpoints of the pair");

    // One endpoint on both sides.
    RouteSelection sameEndpoint = inputToOutput;
    sameEndpoint.captureFlow = DataFlow::render;
    sameEndpoint.loopback = true;
    sameEndpoint.captureId = physicalOutput.id;
    const RouteDiagnosis same = diagnoseRoute(sameEndpoint, outputs, inputs);
    check(same.issue == RouteIssue::sameEndpoint, "one endpoint on both sides is refused");

    // Which id failed has to be distinguishable: a device that was reinstalled
    // gets a new id, and nothing may fall back to another endpoint.
    RouteSelection missingCapture = inputToOutput;
    missingCapture.captureId = "{0.0.1.00000000}.{deadbeef-0000-0000-0000-000000000000}";
    const RouteDiagnosis missingInput = diagnoseRoute(missingCapture, outputs, inputs);
    check(missingInput.issue == RouteIssue::captureEndpointMissing,
          "an unknown capture id is reported as a missing endpoint");
    check(missingInput.cause.find("no endpoint with the requested capture id") != std::string::npos,
          "the missing capture id is reported by name, not replaced");
    check(missingInput.nextAction.find("reinstalled") != std::string::npos,
          "the advice says a reinstalled endpoint gets a new id");
    RouteSelection missingRender = inputToOutput;
    missingRender.renderId = "{0.0.0.00000000}.{deadbeef-0000-0000-0000-000000000001}";
    const RouteDiagnosis missingOutput = diagnoseRoute(missingRender, outputs, inputs);
    check(missingOutput.issue == RouteIssue::renderEndpointMissing,
          "an unknown render id is reported as a missing endpoint");

    // An endpoint that exists but belongs to the other flow is a capture-mode
    // problem, and the advice has to name the mode rather than the id.
    RouteSelection wrongMode;
    wrongMode.captureId = microphone.id;
    wrongMode.captureFlow = DataFlow::render;  // loopback, which only exists for outputs
    wrongMode.loopback = true;
    wrongMode.renderId = physicalOutput.id;
    const RouteDiagnosis mode = diagnoseRoute(wrongMode, outputs, inputs);
    check(mode.issue == RouteIssue::captureModeMismatch,
          "an input endpoint selected as a loopback capture is a mode mismatch");
    check(mode.nextAction.find("--input-device") != std::string::npos,
          "the mode mismatch advice names the flag that records an input");

    // The opposite direction: an output endpoint selected as a real input.
    RouteSelection reversedMode;
    reversedMode.captureId = physicalOutput.id;
    reversedMode.captureFlow = DataFlow::capture;
    reversedMode.loopback = false;
    reversedMode.renderId = cablePlayback.id;
    const RouteDiagnosis reversed = diagnoseRoute(reversedMode, outputs, inputs);
    check(reversed.issue == RouteIssue::captureModeMismatch,
          "an output endpoint selected as an input capture is a mode mismatch");

    // The default selection on a machine with one output is the same endpoint on
    // both sides; that is the guard's oldest case and must stay refused.
    RouteSelection defaults;
    const RouteDiagnosis defaultRoute = diagnoseRoute(defaults, outputs, inputs);
    check(defaultRoute.issue == RouteIssue::sameEndpoint,
          "the default loopback route on a single-output machine is refused");

    // Capturing a cable's playback side is a valid route, but not the milestone
    // route, so it is stated instead of silently accepted.
    RouteSelection playbackSide = inputToOutput;
    playbackSide.captureId = cablePlayback.id;
    playbackSide.captureFlow = DataFlow::render;
    playbackSide.loopback = true;
    const RouteDiagnosis playback = diagnoseRoute(playbackSide, outputs, inputs);
    check(playback.ok(), "capturing a cable's playback side is allowed");
    bool notedPlaybackSide = false;
    for (const std::string& note : playback.notes) {
        if (note.find("playback side") != std::string::npos) {
            notedPlaybackSide = true;
        }
    }
    check(notedPlaybackSide, "capturing a cable's playback side is called out");

    // With no cable at all, the milestone route is unavailable and that is said
    // once, with what it would take, instead of being discovered later.
    const std::vector<DeviceInfo> noCableOutputs = { physicalOutput };
    const std::vector<DeviceInfo> noCableInputs = { microphone };
    const RouteDiagnosis withoutCable = diagnoseRoute(inputToOutput, noCableOutputs, noCableInputs);
    check(withoutCable.ok(), "a route without a virtual cable is still usable");
    check(withoutCable.virtualCables.empty(),
          "a machine with no virtual cable reports no pairs");
    bool toldToInstall = false;
    for (const std::string& note : withoutCable.notes) {
        if (note.find("VB-CABLE") != std::string::npos &&
            note.find("consent") != std::string::npos) {
            toldToInstall = true;
        }
    }
    check(toldToInstall,
          "a missing virtual cable is reported with its install cost and consent requirement");

    // A machine whose only input endpoints are remote: the capture clock is not
    // the local audio clock, and that has to be said rather than assumed away.
    const DeviceInfo remoteInput = syntheticEndpoint(
        "{0.0.1.00000000}.{88888888-8888-8888-8888-888888888888}", "Network Input",
        "{2a4b6c8d-0e1f-4a2b-8c3d-4e5f60718293}", "ROOT", true, "Network");
    const std::vector<DeviceInfo> remoteInputs = { remoteInput };
    RouteSelection remoteRoute = inputToOutput;
    remoteRoute.captureId = remoteInput.id;
    const RouteDiagnosis remote = diagnoseRoute(remoteRoute, noCableOutputs, remoteInputs);
    check(remote.ok(), "a remote input endpoint is usable");
    bool notedRemote = false;
    for (const std::string& note : remote.notes) {
        if (note.find("remote/network") != std::string::npos &&
            note.find("--verbose") != std::string::npos) {
            notedRemote = true;
        }
    }
    check(notedRemote, "a remote-only capture environment is reported with what to measure");

    // The pairing the device list prints comes from the same rule.
    const std::vector<VirtualCable> found = findVirtualCables(outputs, inputs);
    check(found.size() == 1, "one virtual cable is found in a list that holds one");
    check(!found.empty() && found[0].playback.id == cablePlayback.id &&
              found[0].recording.id == cableRecording.id,
          "the found cable pairs the playback side with its recording side");
    check(findVirtualCables(noCableOutputs, noCableInputs).empty(),
          "no cable is found when the endpoints are not a pair");

    // The one case the guard cannot decide: both sides on a software bus, but
    // Windows reports them as different devices. It must be reported as
    // unidentifiable rather than treated as safe or refused as a loop.
    const DeviceInfo otherVirtual = syntheticEndpoint(
        "{0.0.0.00000000}.{99999999-9999-9999-9999-999999999999}", "Other Virtual Output",
        "{3c4d5e6f-7081-4a2b-9c8d-7e6f5a4b3c21}", "ROOT", false);
    const std::vector<DeviceInfo> otherVirtualOutputs = { otherVirtual };
    RouteSelection crossRoute;
    crossRoute.captureId = cableRecording.id;
    crossRoute.renderId = otherVirtual.id;
    crossRoute.captureFlow = DataFlow::capture;
    crossRoute.loopback = false;
    const RouteDiagnosis unidentified = diagnoseRoute(crossRoute, otherVirtualOutputs, inputs);
    check(unidentified.ok(), "a software-bus pair from different devices is not refused");
    check(isUnidentifiedSoftwarePair(cableRecording, otherVirtual),
          "two software-bus endpoints from different device instances are unidentified");
    bool warned = false;
    for (const std::string& note : unidentified.notes) {
        if (note.find("cannot be identified as the two sides of one virtual cable") !=
            std::string::npos) {
            warned = true;
        }
    }
    check(warned, "an unidentifiable software-bus pair is reported instead of assumed safe");
    check(!isUnidentifiedSoftwarePair(cableRecording, physicalOutput),
          "a software endpoint against a hardware endpoint is not reported as an unidentified pair");
    check(!isUnidentifiedSoftwarePair(cablePlayback, cableRecording),
          "the two sides of one cable are identified, not reported as unidentified");
}

void checkDeviceFailureClassification() {
    std::printf("recovery: real device-failure classification\n");

    // These use the device layer directly but need no audio hardware: every one
    // of them must fail, so they behave the same on a machine with no endpoints
    // (a CI runner) as on a workstation with several.
    //
    // Each assertion was checked against the real API before being relied on:
    //   * a syntactically valid id with no device behind it returns
    //     HRESULT_FROM_WIN32(ERROR_NOT_FOUND) from GetDevice();
    //   * a malformed id returns E_INVALIDARG from string validation, which
    //     happens before any endpoint is consulted, so it is the one case that
    //     cannot depend on what hardware exists.
    //
    // The one environmental assumption is that the device enumerator itself can
    // be created: these checks need the Windows Audio service to be running,
    // which it is on a normal desktop and on GitHub's windows-latest image. If
    // the service were absent, the first check would fail here — correctly, as
    // that is a broken test environment rather than a classification result.

    // A well-formed endpoint id with nothing behind it is exactly what reopening
    // a removed device looks like: IMMDeviceEnumerator::GetDevice answers with
    // HRESULT_FROM_WIN32(ERROR_NOT_FOUND). Recovery exists for this case, so it
    // must stay classified as a lost device — classifying it as fatal would make
    // the engine give up on the first reopen attempt and never use its budget.
    const std::string missing = "{0.0.0.00000000}.{11111111-2222-3333-4444-555555555555}";

    {
        WasapiCapture::Options options;
        options.bufferMs = 20;
        options.flow = DataFlow::render;
        options.loopback = true;
        options.deviceId = missing;
        WasapiCapture capture;
        std::string error;
        const bool opened = capture.open(options, error);
        check(!opened, "an absent capture endpoint does not open");
        check(capture.lastError() == DeviceError::deviceLost,
              "an absent capture endpoint is recoverable, not fatal");
        check(!error.empty(), "the failed open explains itself");
        // Destructor runs here: releasing the COM objects after a failed open is
        // the path that used to fault when the apartment did not outlive them.
        capture.close();
    }

    {
        WasapiRender::Options options;
        options.bufferMs = 20;
        options.deviceId = missing;
        WasapiRender render;
        std::string error;
        const bool opened = render.open(options, error);
        check(!opened, "an absent render endpoint does not open");
        check(render.lastError() == DeviceError::deviceLost,
              "an absent render endpoint is recoverable, not fatal");
        render.close();
    }

    // A request that is wrong on its face must be classified as fatal, without
    // depending on any endpoint existing. An id that is not even a valid
    // endpoint string is rejected before any device is consulted, so this
    // asserts the same thing on a workstation and on a device-less CI runner.
    //
    // This deliberately does not use a valid-but-unusable rate: that would have
    // to open the default endpoint first, and on a machine with no audio device
    // the missing default endpoint fails before the rate is ever looked at —
    // measuring the runner's lack of hardware instead of the classification.
    {
        WasapiRender::Options options;
        options.bufferMs = 20;
        options.deviceId = "not-an-endpoint-id";
        WasapiRender render;
        std::string error;
        const bool opened = render.open(options, error);
        check(!opened, "a malformed endpoint id does not open");
        check(render.lastError() == DeviceError::fatal,
              "a malformed endpoint id is unrecoverable");
        check(!error.empty(), "the rejection explains itself");
        render.close();
    }

    // A closed object must not keep reporting the failure that preceded the
    // close, or the engine would act on a stale error during the next start.
    {
        WasapiRender::Options options;
        options.bufferMs = 20;
        options.deviceId = missing;
        WasapiRender render;
        std::string error;
        render.open(options, error);
        render.close();
        check(render.lastError() == DeviceError::none,
              "a closed object reports no failure");
    }
}

void checkRecoveryLoopDecision() {
    std::printf("recovery: loop decision\n");

    // A healthy open endpoint does its normal work, and does not consume the
    // budget for a failure that has not happened.
    check(nextLoopStep(true, DeviceError::none, 0) == LoopStep::run,
          "an open endpoint with no failure runs");
    check(nextLoopStep(true, DeviceError::none, maxDeviceReopenAttempts) == LoopStep::run,
          "a spent budget does not stop a healthy endpoint");

    // A lost device on an open endpoint is reopened while the budget lasts.
    check(nextLoopStep(true, DeviceError::deviceLost, 0) == LoopStep::attemptOpen,
          "a lost device on an open endpoint is reopened");
    check(nextLoopStep(true, DeviceError::deviceLost, maxDeviceReopenAttempts - 1)
              == LoopStep::attemptOpen,
          "the last budgeted attempt still reopens");
    check(nextLoopStep(true, DeviceError::deviceLost, maxDeviceReopenAttempts) == LoopStep::stop,
          "a spent budget stops instead of reopening forever");

    // This is the case the loop used to get wrong: after a failed reopen the
    // endpoint is closed, and it must be retried rather than being treated as
    // usable or as a reason to stop.
    check(nextLoopStep(false, DeviceError::deviceLost, 0) == LoopStep::attemptOpen,
          "a still-absent endpoint after a failed reopen is retried");
    check(nextLoopStep(false, DeviceError::deviceLost, maxDeviceReopenAttempts - 1)
              == LoopStep::attemptOpen,
          "a failed reopen retries until the budget is spent");
    check(nextLoopStep(false, DeviceError::deviceLost, maxDeviceReopenAttempts) == LoopStep::stop,
          "a failed reopen stops once the budget is spent");

    // A fatal cause stops immediately, and does so even though a fatal reopen
    // failure leaves the endpoint closed. Treating "closed" as "retry" here
    // would spend the whole budget on a request that repeats identically.
    check(nextLoopStep(true, DeviceError::fatal, 0) == LoopStep::stop,
          "an unrecoverable failure on an open endpoint stops");
    check(nextLoopStep(false, DeviceError::fatal, 0) == LoopStep::stop,
          "an unrecoverable reopen failure stops instead of retrying");
    check(nextLoopStep(false, DeviceError::fatal, 1) == LoopStep::stop,
          "an unrecoverable reopen failure does not consume the budget");

    // A closed endpoint with no recorded failure is the initial state before the
    // first open, and must open rather than report a problem.
    check(nextLoopStep(false, DeviceError::none, 0) == LoopStep::attemptOpen,
          "a closed endpoint opens on the first pass");

    // The whole point of the budget: a device that stays away for every attempt
    // ends the stream rather than looping forever. Walk the sequence the engine
    // would take and assert it terminates.
    {
        uint32_t attempts = 0;
        LoopStep step = LoopStep::attemptOpen;
        bool open = false;
        uint32_t passes = 0;
        while (step == LoopStep::attemptOpen && passes < 100) {
            ++passes;
            ++attempts;
            // Every attempt fails: the endpoint stays closed.
            step = nextLoopStep(open, DeviceError::deviceLost, attempts);
        }
        check(step == LoopStep::stop, "a permanently absent device eventually stops the stream");
        check(attempts == maxDeviceReopenAttempts,
              "the engine makes exactly the budgeted number of attempts");
    }

    // And the other direction: a device that comes back is adopted on the next
    // pass, with the budget reset by the successful open.
    {
        const LoopStep afterRecovery = nextLoopStep(true, DeviceError::none, 0);
        check(afterRecovery == LoopStep::run,
              "a recovered endpoint resumes normal work");
    }
}

void checkSampleRateMatrix() {
    std::printf("DSP stage: sample rate matrix\n");

    const uint32_t rates[] = { 44100, 48000, 88200, 96000, 192000, 768000 };
    for (uint32_t rate : rates) {
        DspStage stage;
        std::string error;
        if (!stage.prepare(rate, 2, error)) {
            check(false, "stage prepares at every supported rate");
            continue;
        }
        Settings settings;
        settings.dspModel = dsp_model::circuit;
        settings.intensity = 60.0f;
        settings.body = 40.0f;
        settings.outputDb = -1.5f;
        if (!stage.applySettings(settings)) {
            check(false, "settings are queued at every supported rate");
            continue;
        }

        std::vector<float> left(2048), right(2048);
        fillSine(left.data(), right.data(), 2048, static_cast<float>(rate), 1000.0f, 0.4f);
        stage.processBlock(left.data(), right.data(), 2048);
        check(allFinite(left.data(), 2048), "output is finite at every supported rate");
        check(rms(left.data(), 2048, 512) > 0.0, "output is non-silent at every supported rate");
    }

    // Rates outside the DSP range must be rejected rather than silently
    // substituted, because spatial geometry only supports 8 kHz to 768 kHz.
    DspStage tooLow;
    std::string error;
    check(!tooLow.prepare(4000, 2, error), "unsupported low rate is rejected");
    DspStage tooHigh;
    check(!tooHigh.prepare(800000, 2, error), "unsupported high rate is rejected");
    DspStage noChannels;
    check(!noChannels.prepare(48000, 3, error), "more than two channels is rejected");
}

void checkDspStageMatchesPortableCore() {
    std::printf("DSP stage: parity with the portable Core\n");

    // The porting claim is that Windows runs the authoritative Source/Core DSP
    // rather than a parallel implementation, so the stage must not alter what
    // the Core produces. Everything below is deterministic - fixed input,
    // coefficient plans from DSPPrecompute, and filter state carried between
    // blocks exactly as the audio thread does - so the two paths must agree bit
    // for bit. A tolerance would hide a real divergence, which is what this
    // exists to catch.
    //
    // What this covers: the settings-to-plan translation, block chunking, the
    // spatial staging, and the control-queue handoff. What it does not: whether
    // those plans match macOS, which the Core tests and the Clang/GCC builds of
    // the same sources are the evidence for.
    constexpr uint32_t sampleRate = 48000;
    constexpr uint32_t channels = 2;
    constexpr uint32_t frames = maxBlockFrames * 2 + 37;  // forces the chunk split

    struct Case {
        const char* name;
        uint32_t model;
        bool spatial;
        float intensity;
        float body;
        float space;
        float speakerWidth;
        float listenerX;
    };
    const Case cases[] = {
        { "Circuit, spatial off", dsp_model::circuit, false, 70.0f, 40.0f, 35.0f, 1.65f, 0.0f },
        { "Circuit, spatial on", dsp_model::circuit, true, 70.0f, 40.0f, 60.0f, 2.20f, 0.8f },
        { "HighExciter, spatial on", dsp_model::high_exciter, true, 30.0f, 60.0f, 80.0f, 1.00f, -1.2f },
    };

    for (const Case& testCase : cases) {
        Settings settings;
        settings.dspModel = testCase.model;
        settings.intensity = testCase.intensity;
        settings.body = testCase.body;
        settings.outputDb = -1.5f;
        settings.spatialEnabled = testCase.spatial;
        settings.space = testCase.space;
        settings.speakerWidth = testCase.speakerWidth;
        settings.listenerX = testCase.listenerX;
        settings.listenerZ = 0.4f;
        const Settings normalizedSettings = normalized(settings);

        // The plan the stage itself would queue.
        const LCDSPSettings plan = lowend::DSPPrecompute::makeDSPSettings(
            static_cast<float>(sampleRate),
            normalizedSettings.intensity,
            normalizedSettings.body,
            normalizedSettings.outputDb,
            normalizedSettings.dspModel,
            normalizedSettings.exciterOversamplingMode);
        const LCSpatialSettings spatialPlan =
            makeSpatialSettings(static_cast<float>(sampleRate), normalizedSettings);

        // A: through DspStage (the path the audio thread runs).
        DspStage stage;
        std::string error;
        if (!stage.prepare(sampleRate, channels, error)) {
            check(false, "the stage prepares for the parity case");
            continue;
        }
        check(stage.applySettings(settings), "parity settings are queued");
        std::vector<float> stageLeft(frames), stageRight(frames);
        fillSine(stageLeft.data(), stageRight.data(), frames, 48000.0f, 90.0f, 0.4f);

        // B: the portable Core driven directly with the same plan.
        lowend::Processor processor;
        processor.prepare(static_cast<double>(sampleRate), channels);
        processor.update(plan);
        lowend::SpatialProcessor spatial;
        spatial.prepare(static_cast<float>(sampleRate));
        spatial.update(spatialPlan);
        std::vector<float> coreLeft(frames), coreRight(frames);
        fillSine(coreLeft.data(), coreRight.data(), frames, 48000.0f, 90.0f, 0.4f);

        // Both sides are driven in maxBlockFrames chunks, which is what the
        // stage does internally and what the Core's block handling is sized for.
        for (uint32_t start = 0; start < frames; start += maxBlockFrames) {
            const uint32_t chunk = std::min(frames - start, maxBlockFrames);

            stage.processBlock(stageLeft.data() + start, stageRight.data() + start, chunk);

            float* coreChannels[2] = { coreLeft.data() + start, coreRight.data() + start };
            processor.process(coreChannels, chunk);
            for (uint32_t frame = 0; frame < chunk; ++frame) {
                spatial.process(coreLeft[start + frame], coreRight[start + frame]);
            }
        }

        bool leftMatches = true;
        bool rightMatches = true;
        uint32_t firstMismatch = 0;
        for (uint32_t i = 0; i < frames; ++i) {
            if (stageLeft[i] != coreLeft[i]) {
                if (leftMatches) firstMismatch = i;
                leftMatches = false;
            }
            if (stageRight[i] != coreRight[i]) rightMatches = false;
        }

        if (!leftMatches) {
            std::printf("  parity case %s: first left mismatch at frame %u "
                        "(stage %.9g, core %.9g)\n",
                        testCase.name, firstMismatch,
                        static_cast<double>(stageLeft[firstMismatch]),
                        static_cast<double>(coreLeft[firstMismatch]));
        }
        check(leftMatches, "the stage's left channel is bit-identical to the portable Core");
        check(rightMatches, "the stage's right channel is bit-identical to the portable Core");
        // A silent match would prove nothing about the DSP running at all.
        check(peakMagnitude(stageLeft.data(), frames) > 1.0e-3f,
              "the parity case produced audible output");
    }
}

void checkDefaultConditioningIsInactiveAndExact() {
    std::printf("DSP stage: default output conditioning\n");

    // The Windows engine has no output-conditioning stage, and that is faithful
    // rather than a missing feature: macOS drives the live path through
    // `ResamplingOutputConditioningEngine.processLive`, which is documented as
    // "Bypass (verbatim copy) unless the live PCM 2x mode is active", and its
    // stored defaults are `isEnabled = false` with `outputMode = .bypass`. So at
    // the configuration a user actually starts with, the macOS stage is an
    // identity copy at the same frame count - exactly what omitting it produces.
    //
    // That equivalence depends on the Core behaviour below, so it is asserted
    // here instead of being left as a comment: if the bypass path ever stopped
    // being bit-exact, or started reporting a different frame count, the Windows
    // engine would silently diverge from macOS and nothing else would say so.
    lowend::OutputConditioning conditioning;
    std::string error;
    if (!conditioning.prepare(48000.0, maxBlockFrames)) {
        check(false, "output conditioning prepares at 48 kHz");
        return;
    }

    // The macOS defaults, field for field.
    LCOutputConditioningSettings settings {};
    settings.enabled = 0;            // OutputConditioningParameters.isEnabled = false
    settings.outputMode = 0;         // .bypass
    settings.oversamplingFactor = 2; // default factor, which does not matter while bypassed
    settings.filterMode = 1;         // .linearPhaseShort
    settings.headroomGain = 1.0f;
    settings.ditherEnabled = 0;
    settings.noiseShapingEnabled = 0;
    settings.dsdMode = 0;

    check(!conditioning.update(settings),
          "default output conditioning is inactive, matching the macOS defaults");

    const uint32_t frames = 1024;
    std::vector<float> left(frames), right(frames);
    fillSine(left.data(), right.data(), frames, 48000.0f, 90.0f, 0.4f);
    std::vector<float> outLeft(frames, -123.0f);
    std::vector<float> outRight(frames, -123.0f);
    const uint32_t outFrames = conditioning.process(left.data(), right.data(), frames,
                                                    outLeft.data(), outRight.data());
    check(outFrames == frames,
          "default conditioning keeps the frame count, so the rate is unchanged");
    check(outLeft == left && outRight == right,
          "default conditioning is a bit-exact copy, so omitting it changes no sample");
}

} // namespace

int runSelfTest() {
    g_failures = 0;
    std::printf("LowEnd Windows offline checks\n");
    std::printf("Scope: DSP stage, spatial stage, lock-free buffers, CLI parsing,\n");
    std::printf("       recovery policy, device-failure classification, and the routing\n");
    std::printf("       rules that judge a capture/render pair.\n");
    std::printf("The classification checks call the device layer but always expect it to\n");
    std::printf("fail, so they need no audio endpoint. Not covered: successful device\n");
    std::printf("opening, negotiated latency, Bluetooth, listening quality.\n\n");

    checkNormalization();
    checkArgumentParsing();
    checkCleanIsBypass();
    checkCircuitShapesLowEnd();
    checkExciterOversamplingPolicy();
    checkExciterAddsHighHarmonics();
    checkModelTransition();
    checkRepeatedRetargets();
    checkSpatialGeometryPlan();
    checkSpatialBypassAndActivation();
    checkSpatialStaysFiniteAtHighRate();
    checkRingBufferUnderrun();
    checkControlQueueRevision();
    checkDspStageThreading();
    checkDiscontinuityResetsState();
    checkRecoveryPolicy();
    checkRouteFeedbackRule();
    checkRouteSelectionDiagnosis();
    checkRecoveryLoopDecision();
    checkDeviceFailureClassification();
    checkSampleRateMatrix();
    checkDspStageMatchesPortableCore();
    checkDefaultConditioningIsInactiveAndExact();

    if (g_failures == 0) {
        std::printf("\nAll offline checks passed.\n");
        return 0;
    }
    std::printf("\n%d offline check(s) failed.\n", g_failures);
    return g_failures;
}

} // namespace lowend::win
