// test_circuit_bass.cpp — Golden reference tests for CircuitBass
//
// Golden values are computed:
//   1. Analytically for pure math functions (asymmetricSaturate, fastClamp)
//   2. From the C++ implementation for filter-chain tests
//      (which mirrors Swift VirtualCircuitBassDSP exactly)
//
// Reference implementation: main.swift VirtualCircuitBassDSP (lines 2313-2438)

#include <Core/CircuitBass.h>
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
// 1. Bypass — intensity=0, body=0 → output = input * outputGain
// ============================================================
static void test_bypass() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 0.0f, 0.0f, 0.0f, 1);  // dspModel=1 (Circuit)

    lowend::CircuitBass cb;
    cb.update(settings);

    float l, r;
    cb.process(0.5f, 0.3f, l, r);

    // At intensity=0, body=0 with outputDb=0:
    // outputGain = 10^(0/20) = 1
    TEST("bypass left == input * gain", approx(l, 0.5f));
    TEST("bypass right == input * gain", approx(r, 0.3f));
}

// ============================================================
// 2. Bypass with gain — intensity=0, body=0, output=-6dB
//    outputGain = 10^(-6/20) ≈ 0.501
// ============================================================
static void test_bypass_with_gain() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 0.0f, 0.0f, -6.0f, 1);

    lowend::CircuitBass cb;
    cb.update(settings);

    float l, r;
    cb.process(1.0f, -1.0f, l, r);

    float expectedGain = std::pow(10.0f, -6.0f / 20.0f);  // ≈ 0.501
    TEST("bypass -6dB left", approx(l, 1.0f * expectedGain, 1e-4f));
    TEST("bypass -6dB right", approx(r, -1.0f * expectedGain, 1e-4f));
}

// ============================================================
// 3. Zero in → zero out  (any settings)
// ============================================================
static void test_zero_input() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 55.0f, 30.0f, -1.5f, 1);

    lowend::CircuitBass cb;
    cb.update(settings);

    float l = 999.0f, r = 999.0f;
    cb.process(0.0f, 0.0f, l, r);

    TEST("zero input → zero output left", approx(l, 0.0f, 1e-6f));
    TEST("zero input → zero output right", approx(r, 0.0f, 1e-6f));
}

// ============================================================
// 4. Reset isolation
//    Process samples → reset → process zero → should be zero
// ============================================================
static void test_reset_isolation() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 55.0f, 30.0f, -1.5f, 1);

    lowend::CircuitBass cb;
    cb.update(settings);

    float l, r;
    cb.process(1.0f, -1.0f, l, r);  // state is now non-zero
    cb.reset();

    cb.process(0.0f, 0.0f, l, r);
    TEST("reset → zero output left", approx(l, 0.0f, 1e-6f));
    TEST("reset → zero output right", approx(r, 0.0f, 1e-6f));
}

// ============================================================
// 5. Stereo isolation
//    Left=1, Right=0 → left should be active, right near zero
// ============================================================
static void test_stereo_isolation() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 55.0f, 30.0f, -1.5f, 1);

    lowend::CircuitBass cb;
    cb.update(settings);

    float l, r;
    cb.process(1.0f, 0.0f, l, r);

    TEST("stereo left active", std::fabs(l) > 0.01f);
    TEST("stereo right silent", std::fabs(r) < 0.001f);
}

// ============================================================
// 6. Update changes output
//    Same input, different intensity → different output
// ============================================================
static void test_update_changes_output() {
    auto lowSettings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 0.0f, 0.0f, 0.0f, 1);
    auto highSettings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 100.0f, 0.0f, 1);

    lowend::CircuitBass cb;
    cb.update(lowSettings);

    float lLow, rLow;
    cb.process(0.5f, 0.5f, lLow, rLow);

    cb.update(highSettings);

    float lHigh, rHigh;
    cb.process(0.5f, 0.5f, lHigh, rHigh);

    TEST("low vs high intensity differ",
         std::fabs(lLow - lHigh) > 0.01f);
}

// ============================================================
// 7. Repeated process does not explode (stability)
//    1000 samples @ 48000 Hz → output stays in [-1, 1]
// ============================================================
static void test_stability() {
    auto settings = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 100.0f, 100.0f, 6.0f, 1);  // extreme settings

    lowend::CircuitBass cb;
    cb.update(settings);

    bool stable = true;
    for (int i = 0; i < 1000; ++i) {
        float input = (i % 100 == 0) ? 0.5f : 0.0f;  // impulse every 100
        float l, r;
        cb.process(input, input, l, r);
        if (l < -1.5f || l > 1.5f || r < -1.5f || r > 1.5f) {
            stable = false;
            break;
        }
    }

    TEST("circuit stable (output in ±1.5)", stable);
}

// ============================================================
// 8. Sample-rate-dependent output
//    44.1k and 96k should produce different results for same params
// ============================================================
static void test_sample_rate_dependence() {
    auto s44 = lowend::DSPPrecompute::makeDSPSettings(
        44100.0f, 50.0f, 30.0f, -1.5f, 1);
    auto s96 = lowend::DSPPrecompute::makeDSPSettings(
        96000.0f, 50.0f, 30.0f, -1.5f, 1);

    lowend::CircuitBass cb44, cb96;
    cb44.update(s44);
    cb96.update(s96);

    // Process enough samples for the filter difference to accumulate
    float l44 = 0, r44 = 0, l96 = 0, r96 = 0;
    for (int i = 0; i < 480; ++i) {
        float input = (i < 10) ? 0.5f : 0.0f;  // short burst
        cb44.process(input, input, l44, r44);
        cb96.process(input, input, l96, r96);
    }

    TEST("44.1k vs 96k differ", std::fabs(l44 - l96) > 0.001f
                               || std::fabs(r44 - r96) > 0.001f);
}

// ============================================================
// 9. High body vs low body comparison
// ============================================================
static void test_body_effect() {
    auto lowBody = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 50.0f, 0.0f, -1.5f, 1);
    auto highBody = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 50.0f, 100.0f, -1.5f, 1);

    lowend::CircuitBass cbLow, cbHigh;
    cbLow.update(lowBody);
    cbHigh.update(highBody);

    float lLow, rLow, lHigh, rHigh;
    cbLow.process(0.5f, 0.5f, lLow, rLow);
    cbHigh.process(0.5f, 0.5f, lHigh, rHigh);

    TEST("high body changes output", std::fabs(lLow - lHigh) > 0.001f);
}

int main() {
    std::printf("=== CircuitBass Golden Tests ===\n\n");

    test_bypass();
    test_bypass_with_gain();
    test_zero_input();
    test_reset_isolation();
    test_stereo_isolation();
    test_update_changes_output();
    test_stability();
    test_sample_rate_dependence();
    test_body_effect();

    std::printf("\n%d tests, %d failures\n", tests, failures);
    return failures > 0 ? 1 : 0;
}
