// test_biquad.cpp — Golden reference tests for Biquad
//
// Golden values are computed analytically from the Direct Form I formula:
//   output = b0 * input + z1
//   z1 = b1 * input - a1 * output + z2
//   z2 = b2 * input - a2 * output
//
// These are NOT captured from a running system — they are derived from
// the filter math itself, so they serve as a cross-platform truth anchor.

#include <Core/Core.h>
#include <cstdio>
#include <cmath>

// Helper: check two floats are close (ULP-aware for golden tests)
static bool approx(float actual, float expected, float tolerance = 1e-6f) {
    return std::fabs(actual - expected) <= tolerance;
}

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
// 1. Impulse response — known coefficients
//    b0=0.5, b1=0.3, b2=0.1, a1=-0.2, a2=0.1
//
//    Expected output (computed by hand above):
//      tick 0 → 0.5
//      tick 1 → 0.4
//      tick 2 → 0.13
//      tick 3 → -0.014
// ============================================================
static void test_impulse_response() {
    LCBiquadCoefficients c{};
    c.b0 = 0.5f; c.b1 = 0.3f; c.b2 = 0.1f;
    c.a1 = -0.2f; c.a2 = 0.1f;

    lowend::Biquad bq;
    bq.update(c);

    const float impulse[] = { 1.0f, 0.0f, 0.0f, 0.0f, 0.0f };
    float output[5];

    for (int i = 0; i < 5; ++i) {
        output[i] = bq.process(impulse[i]);
    }

    TEST("impulse[0] == 0.5", approx(output[0], 0.5f));
    TEST("impulse[1] == 0.4", approx(output[1], 0.4f));
    TEST("impulse[2] == 0.13", approx(output[2], 0.13f));
    TEST("impulse[3] == -0.014", approx(output[3], -0.014f, 1e-5f));

    // Check that reset() zeros the state
    bq.reset();
    float after_reset = bq.process(0.0f);
    TEST("after reset → 0", approx(after_reset, 0.0f));
}

// ============================================================
// 2. Reset after processing — state isolation
// ============================================================
static void test_reset_isolation() {
    LCBiquadCoefficients c{};
    c.b0 = 0.5f;
    lowend::Biquad bq;
    bq.update(c);

    bq.process(1.0f);  // state is now non-zero
    bq.reset();
    float out = bq.process(0.0f);
    TEST("reset clears state", approx(out, 0.0f));
}

// ============================================================
// 3. Low-shelf DC gain
//    At DC (frequency → 0), a low-shelf with gainDb > 0 should
//    amplify a constant input by gainDb.
// ============================================================
static void test_lowshelf_dc_gain() {
    float sampleRate = 48000.0f;
    auto coeffs = lowend::Biquad::makeLowShelf(sampleRate, 100.0f, 0.72f, 6.0f);

    // DC means constant input. For a biquad, the DC gain is:
    //   H(0) = (b0 + b1 + b2) / (1 + a1 + a2)
    float dcGain = (coeffs.b0 + coeffs.b1 + coeffs.b2) /
                   (1.0f + coeffs.a1 + coeffs.a2);
    float expectedDb = 20.0f * std::log10(std::fabs(dcGain));

    TEST("low-shelf DC gain ≈ +6 dB", approx(expectedDb, 6.0f, 0.5f));
}

// ============================================================
// 4. Low-pass DC gain
//    At DC, a low-pass should pass the signal unchanged (0 dB).
// ============================================================
static void test_lowpass_dc_gain() {
    float sampleRate = 48000.0f;
    auto coeffs = lowend::Biquad::makeLowPass(sampleRate, 1000.0f, 0.707f);

    float dcGain = (coeffs.b0 + coeffs.b1 + coeffs.b2) /
                   (1.0f + coeffs.a1 + coeffs.a2);
    float expectedDb = 20.0f * std::log10(std::fabs(dcGain));

    TEST("low-pass DC gain ≈ 0 dB", approx(expectedDb, 0.0f, 1.0f));
}

// ============================================================
// 5. High-pass DC rejection
//    At DC, a high-pass should block the signal entirely.
// ============================================================
static void test_highpass_dc_rejection() {
    float sampleRate = 48000.0f;
    auto coeffs = lowend::Biquad::makeHighPass(sampleRate, 1000.0f, 0.707f);

    float dcGain = (coeffs.b0 + coeffs.b1 + coeffs.b2) /
                   (1.0f + coeffs.a1 + coeffs.a2);

    TEST("high-pass DC gain ≈ 0 (rejection)", std::fabs(dcGain) < 0.001f);
}

// ============================================================
// 6. OnePole impulse response
//    alpha=0.5 → impulse response: [0.5, 0.25, 0.125, ...]
//    z += alpha * (input - z)
//
//    tick 0: z = 0 + 0.5 * (1 - 0) = 0.5
//    tick 1: z = 0.5 + 0.5 * (0 - 0.5) = 0.25
//    tick 2: z = 0.25 + 0.5 * (0 - 0.25) = 0.125
// ============================================================
static void test_onepole_impulse() {
    lowend::OnePole op;
    op.update(0.5f);

    float impulse[] = { 1.0f, 0.0f, 0.0f, 0.0f };

    TEST("onepole[0] == 0.5", approx(op.process(impulse[0]), 0.5f));
    TEST("onepole[1] == 0.25", approx(op.process(impulse[1]), 0.25f));
    TEST("onepole[2] == 0.125", approx(op.process(impulse[2]), 0.125f));

    op.reset();
    TEST("onepole reset → 0", approx(op.process(0.0f), 0.0f));
}

// ============================================================
// 7. OnePole makeRcAlpha
//    alpha = 1 - exp(-2 * pi * freq / sampleRate)
//    48000 Hz, 100 Hz → alpha ≈ 0.0130
// ============================================================
static void test_onepole_alpha() {
    float alpha = lowend::OnePole::makeRcAlpha(48000.0f, 100.0f);
    float expected = 1.0f - std::exp(-2.0f * 3.141592653589793f * 100.0f / 48000.0f);
    TEST("makeRcAlpha(48k, 100Hz)", approx(alpha, expected, 1e-6f));
}

// ============================================================
// 8. Nyquist clamping: frequency near Nyquist should clamp
// ============================================================
static void test_onepole_nyquist_clamp() {
    float alpha = lowend::OnePole::makeRcAlpha(48000.0f, 48000.0f);
    // Should clamp to 48000 * 0.45 = 21600 Hz
    float clamped = 21600.0f;
    float expected = 1.0f - std::exp(-2.0f * 3.141592653589793f * clamped / 48000.0f);
    TEST("makeRcAlpha nyquist clamp", approx(alpha, expected, 1e-6f));
}

int main() {
    std::printf("=== Biquad & OnePole Golden Tests ===\n\n");

    test_impulse_response();
    test_reset_isolation();
    test_lowshelf_dc_gain();
    test_lowpass_dc_gain();
    test_highpass_dc_rejection();
    test_onepole_impulse();
    test_onepole_alpha();
    test_onepole_nyquist_clamp();

    std::printf("\n%d tests, %d failures\n", tests, failures);
    return failures > 0 ? 1 : 0;
}
