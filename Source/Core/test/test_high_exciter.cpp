// test_high_exciter.cpp — Golden reference tests for HighExciter
//
// Reference implementation: main.swift HighExciterDSP (lines 2441-2510)
//
// The Swift implementation is the canonical reference because the JUCE
// plugin had no HighExciter model (JUCE targets were removed in 2026-08).
//
// Golden values are computed analytically for the harmonic polynomial:
//   harmonic = driven² + 0.5 * driven³
//   output = clamp(input + harmonic * wetMix)

#include <Core/HighExciter.h>
#include <cstdio>
#include <cmath>
#include <initializer_list>
#include <limits>

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

    // Measure the actual second-harmonic band of an 8 kHz sine after settling.
    // Comparing the last negative alternating input against positive amplitude
    // used to let a completely bypassed implementation pass this test.
    double harmonicReal = 0, harmonicImaginary = 0;
    constexpr int measuredFrames = 48000;
    for (int i = 0; i < measuredFrames * 2; ++i) {
        const double phase = 2.0 * 3.14159265358979323846 * 8000.0 * i / 48000.0;
        const float input = 0.5f * static_cast<float>(std::sin(phase));
        float output = 0, right = 0;
        he.process(input, input, output, right);
        if (i >= measuredFrames) {
            const double difference = output - input;
            harmonicReal += difference * std::cos(phase * 2);
            harmonicImaginary -= difference * std::sin(phase * 2);
        }
    }
    const double amplitude = 2 * std::hypot(harmonicReal, harmonicImaginary) / measuredFrames;
    TEST("exciter adds measurable 16 kHz AC harmonic", amplitude > 0.001);
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
        if (!std::isfinite(l) || !std::isfinite(r)
            || l < -1.5f || l > 1.5f || r < -1.5f || r > 1.5f) {
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
    TEST("zero drive → exact dry bypass", l == input && r == input);
}

static void test_wet_dc_rejection() {
    for (float rate : { 44100.f, 48000.f, 96000.f, 192000.f, 768000.f }) {
        for (uint32_t factor : { 1u, 2u, 4u }) {
            const auto settings = lowend::DSPPrecompute::makeDSPSettings(rate, 100, 100, 0, 2, factor);
            lowend::HighExciter exciter;
            exciter.update(settings);
            const int frames = static_cast<int>(rate);
            const double frequency = std::fmin(12000.0, static_cast<double>(rate) * 0.25);
            double mean = 0;
            bool finite = true;
            for (int frame = 0; frame < frames * 2; ++frame) {
                const float input = static_cast<float>(0.5 * std::sin(
                    2.0 * 3.14159265358979323846 * frequency * frame / rate));
                float left = 0, right = 0;
                exciter.process(input, input, left, right);
                finite = finite && std::isfinite(left) && std::isfinite(right);
                if (frame >= frames) mean += left;
            }
            mean /= frames;
            TEST("exciter output finite across rates/modes", finite);
            TEST("steady-state wet DC below 0.00002 FS", std::fabs(mean) < 0.00002);
            // Natural signal -> silence, without reset. The wet DC blocker
            // must retain its initial tail and then decay; clearing history at
            // silence would conceal a state-transition defect.
            double earlyPeak = 0, latePeak = 0, lateMean = 0;
            const int silenceFrames = frames * 3 / 4;
            int lateCount = 0;
            for (int frame = 0; frame < silenceFrames; ++frame) {
                float left = 0, right = 0;
                exciter.process(0, 0, left, right);
                finite = finite && std::isfinite(left) && std::isfinite(right);
                if (frame < frames / 100) earlyPeak = std::fmax(earlyPeak, std::fabs(left));
                if (frame >= frames / 2) {
                    latePeak = std::fmax(latePeak, std::fabs(left));
                    lateMean += left;
                    ++lateCount;
                }
            }
            TEST("natural silence keeps a measurable initial wet tail", earlyPeak > 0.00001);
            // A 5 Hz pole has decayed by exp(-2*pi*5*.5) ~= 1.5e-7
            // after 0.5 s. 2e-6 FS includes Float/filter residual margin.
            TEST("natural silence is finite and below -114 dBFS after 0.5 s",
                 finite && latePeak < 0.000002 && std::fabs(lateMean / lateCount) < 0.000002);
            TEST("natural silence tail decays by more than 60 dB", latePeak < earlyPeak * 0.001);
            exciter.reset();
            float left = 1, right = 1;
            exciter.process(0, 0, left, right);
            TEST("reset clears DC-blocker history", left == 0 && right == 0);
        }
    }
}

static void test_nonfinite_input() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(48000, 100, 100, 0, 2);
    lowend::HighExciter exciter;
    exciter.update(settings);
    for (float input : { std::numeric_limits<float>::quiet_NaN(),
        std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity() }) {
        float left = 0, right = 0;
        exciter.process(input, input, left, right);
        TEST("nonfinite input does not poison filters", left == 0 && right == 0);
    }
}

static void test_factor_crossfade() {
    const auto oldSettings = lowend::DSPPrecompute::makeDSPSettings(48000, 100, 100, 0, 2, 4);
    const auto nextSettings = lowend::DSPPrecompute::makeDSPSettings(48000, 100, 100, 0, 2, 1);
    auto warmSettings = nextSettings;
    warmSettings.exciterDrive = 0;
    lowend::HighExciter actual, oldReference, newReference;
    actual.update(oldSettings); oldReference.update(oldSettings); newReference.update(warmSettings);
    for (int frame = 0; frame < 1024; ++frame) {
        const float input = float(0.5 * std::sin(2 * std::acos(-1.0) * 8000 * frame / 48000));
        float left = 0, right = 0;
        actual.process(input, input, left, right);
        oldReference.process(input, input, left, right);
        newReference.process(input, input, left, right);
    }
    actual.update(nextSettings);
    newReference.update(nextSettings);
    for (int frame = 0; frame < 256; ++frame) {
        const float input = float(0.5 * std::sin(2 * std::acos(-1.0) * 8000 * (frame + 1024) / 48000));
        float left = 0, right = 0, oldOut = 0, newOut = 0;
        oldReference.process(input, input, oldOut, right);
        newReference.process(input, input, newOut, right);
        actual.process(input, input, left, right);
        const float mix = float(frame + 1) / 256;
        const float expected = oldOut + (newOut - oldOut) * mix;
        TEST("factor transition keeps the previous wet path throughout crossfade",
             std::fabs(left - expected) < 0.000002f);
    }
    actual.update(oldSettings);
    for (int frame = 0; frame < 49000; ++frame) {
        if (frame == 32) actual.update(nextSettings);
        if (frame == 64) actual.update(oldSettings);
        const float input = float(0.5 * std::sin(2 * std::acos(-1.0) * 8000 * (frame + 1280) / 48000));
        float left = 0, right = 0, expected = 0;
        actual.process(input, input, left, right);
        oldReference.process(input, input, expected, right);
        if (frame >= 48000) TEST("factor latest pending target converges",
                                std::fabs(left - expected) < 0.0001f);
    }
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
    test_wet_dc_rejection();
    test_nonfinite_input();
    test_factor_crossfade();

    std::printf("\n%d tests, %d failures\n", tests, failures);
    return failures > 0 ? 1 : 0;
}
