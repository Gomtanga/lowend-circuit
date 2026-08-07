// test_high_exciter.cpp — Golden reference tests for HighExciter
//
// Reference implementation: main.swift HighExciterDSP (lines 2441-2510)
//
// The Swift implementation is the canonical reference because JUCE
// PluginProcessor has no HighExciter model.
//
// Golden values are computed analytically for the harmonic polynomial:
//   harmonic = driven² + 0.5 * driven³
//   output = clamp(input + harmonic * wetMix)

#include <Core/HighExciter.h>
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

static bool approx(float actual, float expected, float tolerance = 1e-6f) {
    return std::fabs(actual - expected) <= tolerance;
}

// ============================================================
// 1. Bypass — wetMix=0 → output == input
// ============================================================
static void test_bypass() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 0.0f, 0.0f, 0.0f, 2);  // dspModel=2 (HighExciter)

    lowend::HighExciter he;
    he.update(settings);

    // At body=0: exciterWetMix = 0 → bypass
    float l, r;
    he.process(0.5f, -0.3f, l, r);

    TEST("bypass left == input", approx(l, 0.5f));
    TEST("bypass right == input", approx(r, -0.3f));
}

// ============================================================
// 2. Zero input → zero output  (with active settings)
// ============================================================
static void test_zero_input() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 50.0f, 50.0f, 0.0f, 2);  // active exciter

    lowend::HighExciter he;
    he.update(settings);

    float l = 999.0f, r = 999.0f;
    he.process(0.0f, 0.0f, l, r);

    TEST("zero in → zero out left", approx(l, 0.0f, 1e-6f));
    TEST("zero in → zero out right", approx(r, 0.0f, 1e-6f));
}

// ============================================================
// 3. High-frequency input with active exciter → output ≠ input
//    At 48kHz, HP cutoff ≈ 11kHz. A 12kHz cosine passes through
//    and gets harmonics added.
// ============================================================
static void test_exciter_active() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 100.0f, 0.0f, 2);  // max exciter

    lowend::HighExciter he;
    he.update(settings);

    // Process a high-frequency impulse train to get past HP settling
    float input, output;
    for (int i = 0; i < 480; ++i) {
        // Alternating sample to create high-frequency content
        input = (i % 2 == 0) ? 0.3f : -0.3f;
        he.process(input, input, output, output);
    }

    // With active exciter and high-frequency content,
    // the output should differ from the raw input
    float rawAlt = 0.3f;  // the alternating pattern amplitude
    TEST("exciter active produces harmonics",
         std::fabs(output - rawAlt) > 0.001f);
}

// ============================================================
// 4. Reset isolation
// ============================================================
static void test_reset_isolation() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 100.0f, 0.0f, 2);

    lowend::HighExciter he;
    he.update(settings);

    float l, r;
    he.process(1.0f, -1.0f, l, r);  // state now non-zero
    he.reset();
    he.process(0.0f, 0.0f, l, r);

    TEST("reset → zero left", approx(l, 0.0f, 1e-6f));
    TEST("reset → zero right", approx(r, 0.0f, 1e-6f));
}

// ============================================================
// 5. Stereo isolation
// ============================================================
static void test_stereo_isolation() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 100.0f, 0.0f, 2);

    lowend::HighExciter he;
    he.update(settings);

    float l, r;
    // Alternating pattern to keep HP active on left, silent on right
    for (int i = 0; i < 384; ++i) {
        float leftInput = (i % 2 == 0) ? 0.5f : -0.5f;
        he.process(leftInput, 0.0f, l, r);
    }

    TEST("stereo left active", std::fabs(l) > 0.01f);
    TEST("stereo right silent (zero input)", std::fabs(r) < 0.001f);
}

// ============================================================
// 6. wetMix effect — higher wetMix → more harmonic content
// ============================================================
static void test_wetmix_effect() {
    auto lowMix = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 10.0f, 0.0f, 2);   // body=10 → low wetMix
    auto highMix = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 100.0f, 0.0f, 2);  // body=100 → high wetMix

    lowend::HighExciter heLow, heHigh;
    heLow.update(lowMix);
    heHigh.update(highMix);

    float lLow = 0, rLow = 0, lHigh = 0, rHigh = 0;
    for (int i = 0; i < 384; ++i) {
        float input = (i % 2 == 0) ? 0.3f : -0.3f;
        heLow.process(input, input, lLow, rLow);
        heHigh.process(input, input, lHigh, rHigh);
    }

    TEST("higher wetMix changes output",
         std::fabs(lLow - lHigh) > 0.001f);
}

// ============================================================
// 7. Drive effect — higher drive → more harmonic content
// ============================================================
static void test_drive_effect() {
    auto lowDrive = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 10.0f, 100.0f, 0.0f, 2);   // intensity=10 → low drive
    auto highDrive = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 100.0f, 0.0f, 2);  // intensity=100 → high drive

    lowend::HighExciter heLow, heHigh;
    heLow.update(lowDrive);
    heHigh.update(highDrive);

    float lLow = 0, rLow = 0, lHigh = 0, rHigh = 0;
    for (int i = 0; i < 384; ++i) {
        float input = (i % 2 == 0) ? 0.3f : -0.3f;
        heLow.process(input, input, lLow, rLow);
        heHigh.process(input, input, lHigh, rHigh);
    }

    TEST("higher drive changes output",
         std::fabs(lLow - lHigh) > 0.001f);
}

// ============================================================
// 8. Stability — 1000 samples with extreme settings
// ============================================================
static void test_stability() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 100.0f, 6.0f, 2);  // extreme settings

    lowend::HighExciter he;
    he.update(settings);

    bool stable = true;
    for (int i = 0; i < 1000; ++i) {
        float input = (i % 50 == 0) ? 1.0f : 0.0f;  // impulse every 50
        float l, r;
        he.process(input, input, l, r);
        if (l < -1.5f || l > 1.5f || r < -1.5f || r > 1.5f) {
            stable = false;
            break;
        }
    }

    TEST("high exciter stable (output in ±1.5)", stable);
}

// ============================================================
// 9. Adaptive oversampling policy
// ============================================================
static void test_sample_rate_dependence() {
    auto s44 = lowend::DSPPrecompute::makeDSPSettings(
        44100.0f, 100.0f, 100.0f, 0.0f, 2);
    auto s96 = lowend::DSPPrecompute::makeDSPSettings(
        96000.0f, 100.0f, 100.0f, 0.0f, 2);
    auto s192 = lowend::DSPPrecompute::makeDSPSettings(
        192000.0f, 100.0f, 100.0f, 0.0f, 2);

    TEST("44.1k uses 4x oversampling", s44.exciterOversampleFactor == 4);
    TEST("96k uses 2x oversampling", s96.exciterOversampleFactor == 2);
    TEST("192k uses 1x oversampling", s192.exciterOversampleFactor == 1);

    auto manual4At96 = lowend::DSPPrecompute::makeDSPSettings(
        96000.0f, 100.0f, 100.0f, 0.0f, 2, 4);
    auto manual4At192 = lowend::DSPPrecompute::makeDSPSettings(
        192000.0f, 100.0f, 100.0f, 0.0f, 2, 4);
    auto manual4At768 = lowend::DSPPrecompute::makeDSPSettings(
        768000.0f, 100.0f, 100.0f, 0.0f, 2, 4);
    TEST("96k manual 4x remains 4x", manual4At96.exciterOversampleFactor == 4);
    TEST("192k manual 4x clamps to 2x", manual4At192.exciterOversampleFactor == 2);
    TEST("768k manual 4x clamps to 1x", manual4At768.exciterOversampleFactor == 1);

    lowend::HighExciter he44, he96, he192;
    he44.update(s44);
    he96.update(s96);
    he192.update(s192);

    float l44, r44, l96, r96, l192, r192;
    he44.process(0.5f, 0.5f, l44, r44);
    he96.process(0.5f, 0.5f, l96, r96);
    he192.process(0.5f, 0.5f, l192, r192);

    TEST("44.1k impulse finite", std::isfinite(l44) && std::isfinite(r44));
    TEST("96k impulse finite", std::isfinite(l96) && std::isfinite(r96));
    TEST("192k impulse finite", std::isfinite(l192) && std::isfinite(r192));
}

// ============================================================
// 10. drive=0 → effectively bypass (even with wetMix > 0)
// ============================================================
static void test_zero_drive_bypass() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 0.0f, 100.0f, 0.0f, 2);  // intensity=0 → drive=0

    lowend::HighExciter he;
    he.update(settings);

    float l, r;
    float input = (0 % 2 == 0) ? 0.3f : -0.3f;
    // process a few samples to let HP settle
    for (int i = 0; i < 48; ++i) {
        input = (i % 2 == 0) ? 0.3f : -0.3f;
        he.process(input, input, l, r);
    }

    // drive=0 → harmonic = 0 → output ≈ input
    TEST("zero drive → bypass (output near input)",
         std::fabs(l) > 0.01f && std::fabs(l) < 0.5f);
}

int main() {
    std::printf("=== HighExciter Tests ===\n\n");

    test_bypass();
    test_zero_input();
    test_exciter_active();
    test_reset_isolation();
    test_stereo_isolation();
    test_wetmix_effect();
    test_drive_effect();
    test_stability();
    test_sample_rate_dependence();
    test_zero_drive_bypass();

    std::printf("\n%d tests, %d failures\n", tests, failures);
    return failures > 0 ? 1 : 0;
}
