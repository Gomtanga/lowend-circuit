// test_precompute.cpp — Sanity tests for DSPPrecompute
//
// These tests verify that makeDSPSettings and makeSpatialSettings
// produce structurally valid output. Exact golden values would need
// a cross-implementation comparison against the Swift reference.
//
// The Swift implementation (DSPPrecompute in main.swift) is the
// intended reference — once Core is used in both paths, the same
// golden values will apply everywhere.

#include <Core/Core.h>
#include <cstdio>
#include <cmath>

static int failures = 0;
static int tests = 0;

#define TEST(name, expr) do { \
    ++tests; \
    if (!(expr)) { \
        std::fprintf(stderr, "  FAIL: %s\n", name); \
        ++failures; \
    } \
} while(0)

// ============================================================
// 1. makeDSPSettings with typical values (Circuit, intensity=55, body=30)
// ============================================================
static void test_dsp_settings_typical() {
    auto s = lowend::DSPPrecompute::makeDSPSettings(48000.0f, 55.0f, 30.0f, -1.5f, 1);

    TEST("intensity in [0,1]", s.intensity >= 0.0f && s.intensity <= 1.0f);
    TEST("body in [0,1]", s.body >= 0.0f && s.body <= 1.0f);
    TEST("outputGain > 0", s.outputGain > 0.0f);
    TEST("headroomGain in (0,1]", s.headroomGain > 0.0f && s.headroomGain <= 1.0f);
    TEST("dspModel == 1 (Circuit)", s.dspModel == 1);
    TEST("shelf b0 nonzero", std::fabs(s.shelf.b0) > 0.0f);
    TEST("wetMix in [0,0.54]", s.wetMix >= 0.0f && s.wetMix <= 0.54f);
    TEST("bassAlpha in (0,1)", s.bassAlpha > 0.0f && s.bassAlpha < 1.0f);
    TEST("subAlpha in (0,1)", s.subAlpha > 0.0f && s.subAlpha < 1.0f);
    TEST("exciterDrive == 0 for Circuit", s.exciterDrive == 0.0f);
    TEST("exciterWetMix == 0 for Circuit", s.exciterWetMix == 0.0f);
}

// ============================================================
// 2. makeDSPSettings with HighExciter — exciter params should be set
// ============================================================
static void test_dsp_settings_highexciter() {
    auto s = lowend::DSPPrecompute::makeDSPSettings(48000.0f, 50.0f, 20.0f, -1.5f, 2);

    TEST("dspModel == 2 (HighExciter)", s.dspModel == 2);
    TEST("exciterDrive > 0 for HighExciter", s.exciterDrive > 0.0f);
    TEST("exciterWetMix > 0 for HighExciter", s.exciterWetMix > 0.0f);
}

// ============================================================
// 3. makeDSPSettings at boundaries (intensity=0, body=0)
// ============================================================
static void test_dsp_settings_minimum() {
    auto s = lowend::DSPPrecompute::makeDSPSettings(48000.0f, 0.0f, 0.0f, 0.0f, 0);

    TEST("min intensity == 0", s.intensity == 0.0f);
    TEST("min body == 0", s.body == 0.0f);
    TEST("outputGain == 1 at 0dB", std::fabs(s.outputGain - 1.0f) < 0.001f);
    TEST("wetMix == 0 at min", s.wetMix == 0.0f);
    TEST("virtualFeedbackGain == 0", s.virtualFeedbackGain == 0.0f);
    TEST("bodyInjectionGain == 0", s.bodyInjectionGain == 0.0f);
}

// ============================================================
// 4. makeDSPSettings at boundaries (intensity=100, body=100)
// ============================================================
static void test_dsp_settings_maximum() {
    auto s = lowend::DSPPrecompute::makeDSPSettings(48000.0f, 100.0f, 100.0f, 6.0f, 1);

    TEST("max intensity == 1", std::fabs(s.intensity - 1.0f) < 0.001f);
    TEST("max body == 1", std::fabs(s.body - 1.0f) < 0.001f);
    TEST("outputGain > 1 at +6dB", s.outputGain > 1.0f);
    TEST("headroomGain < 1", s.headroomGain < 1.0f);
    TEST("bassAlpha larger with high intensity",
         s.bassAlpha > lowend::OnePole::makeRcAlpha(48000.0f, 72.0f));
}

// ============================================================
// 5. makeDSPSettings sample rate independence check
//    44.1k vs 96k should produce different coefficients
// ============================================================
static void test_dsp_settings_sample_rate() {
    // Use a mid-range frequency (1 kHz) to produce clearly different coefficients
    auto s44 = lowend::DSPPrecompute::makeDSPSettings(44100.0f, 55.0f, 30.0f, -1.5f, 1);
    auto s96 = lowend::DSPPrecompute::makeDSPSettings(96000.0f, 55.0f, 30.0f, -1.5f, 1);

    // bassAlpha should differ with sample rate
    TEST("bassAlpha differs with sample rate",
         std::fabs(s44.bassAlpha - s96.bassAlpha) > 0.001f);
}

// ============================================================
// 6. makeSpatialSettings — structural validity
// ============================================================
static void test_spatial_settings_default() {
    auto s = lowend::DSPPrecompute::makeSpatialSettings(
        48000.0f,   // sampleRate
        0.0f,       // listenerX
        0.0f,       // listenerZ
        1.65f,      // speakerWidth
        35.0f,      // amount
        true        // enabled
    );

    TEST("spatial enabled", s.enabled == 1);
    TEST("spatial amount in [0,1]", s.amount >= 0.0f && s.amount <= 1.0f);
    TEST("spatial LL gain > 0", s.ll.gain > 0.0f);
    TEST("spatial RR gain > 0", s.rr.gain > 0.0f);
    TEST("spatial LR gain > 0", s.lr.gain > 0.0f);
    TEST("spatial RL gain > 0", s.rl.gain > 0.0f);
}

// ============================================================
// 7. makeSpatialSettings disabled
// ============================================================
static void test_spatial_settings_disabled() {
    auto s = lowend::DSPPrecompute::makeSpatialSettings(
        48000.0f, 0.0f, 0.0f, 1.65f, 35.0f, false);
    TEST("spatial disabled", s.enabled == 0);
}

int main() {
    std::printf("=== DSPPrecompute Sanity Tests ===\n\n");

    test_dsp_settings_typical();
    test_dsp_settings_highexciter();
    test_dsp_settings_minimum();
    test_dsp_settings_maximum();
    test_dsp_settings_sample_rate();
    test_spatial_settings_default();
    test_spatial_settings_disabled();

    std::printf("\n%d tests, %d failures\n", tests, failures);
    return failures > 0 ? 1 : 0;
}
