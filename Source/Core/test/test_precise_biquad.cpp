#include <Core/Core.h>

#include <cmath>
#include <complex>
#include <cstdio>
#include <initializer_list>

namespace {
int failures = 0;
void check(bool value, const char* message) {
    if (!value) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        ++failures;
    }
}

// Independent long-double transfer-function oracle. Tests the exported
// coefficients against the intended response, rather than another Float port.
long double referenceGain(long double sampleRate, long double cutoff,
                          long double gainDb, long double frequency) {
    const long double pi = std::acos(-1.0L);
    const long double a = std::pow(10.0L, gainDb / 40.0L);
    const long double w = 2 * pi * cutoff / sampleRate;
    const long double cosine = std::cos(w);
    const long double beta = std::sqrt(a) * std::sin(w) / 0.72L;
    const long double a0 = (a + 1) + (a - 1) * cosine + beta;
    const long double b0 = a * ((a + 1) - (a - 1) * cosine + beta) / a0;
    const long double b1 = 2 * a * ((a - 1) - (a + 1) * cosine) / a0;
    const long double b2 = a * ((a + 1) - (a - 1) * cosine - beta) / a0;
    const long double a1 = -2 * ((a - 1) + (a + 1) * cosine) / a0;
    const long double a2 = ((a + 1) + (a - 1) * cosine - beta) / a0;
    const auto z = std::exp(std::complex<long double>(0, -2 * pi * frequency / sampleRate));
    return 20 * std::log10(std::abs((b0 + b1 * z + b2 * z * z)
        / (1.0L + a1 * z + a2 * z * z)));
}

double actualGain(const LCBiquadCoefficients64& c, double rate, double frequency) {
    const auto z = std::exp(std::complex<double>(0,
        -2 * std::acos(-1.0) * frequency / rate));
    return 20 * std::log10(std::abs((c.b0 + c.b1 * z + c.b2 * z * z)
        / (1.0 + c.a1 * z + c.a2 * z * z)));
}
}

int main() {
    double maximumErrorDb = 0;
    for (float rate : { 44100.f, 48000.f, 96000.f, 192000.f, 384000.f, 768000.f }) {
        for (float intensity : { 0.f, 22.f, 55.f, 100.f }) {
            const auto settings = lowend::DSPPrecompute::makeDSPSettings(rate, intensity, 30, 0, 1);
            check(settings.preciseCircuitCoefficientsEnabled == 1,
                  "precompute enables precise circuit coefficients");
            const float normalIntensity = intensity / 100;
            const float shelfFrequency = 68.f + normalIntensity * 24.f;
            const float shelfDb = normalIntensity * 6.5f;
            const float transformerFrequency = 78.f + normalIntensity * 10.f + 0.3f * 24.f;
            const float transformerDb = 0.7f + normalIntensity * 2.2f + 0.3f * 0.7f;
            struct Fixture { LCBiquadCoefficients64 c; float cutoff; float gain; };
            for (const auto& fixture : {
                Fixture { settings.preciseShelf, shelfFrequency, shelfDb },
                Fixture { settings.preciseTransformerPreEmphasis, transformerFrequency, transformerDb },
                Fixture { settings.preciseTransformerDeEmphasis, transformerFrequency, -transformerDb } }) {
                for (double frequency : { 0.0, 20.0, 55.0, 100.0, 200.0 }) {
                    const double expected = static_cast<double>(referenceGain(rate,
                        fixture.cutoff, fixture.gain, frequency));
                    const double actual = actualGain(fixture.c, rate, frequency);
                    const double error = std::fabs(actual - expected);
                    maximumErrorDb = std::fmax(maximumErrorDb, error);
                    check(std::isfinite(actual) && error < 0.0001,
                          "precise low-frequency response within 0.0001 dB of independent oracle");
                }
            }
        }
    }

    // Exercise actual Double filter state at the previous worst-case rate.
    // The second second contains exactly 55 cycles, after a one-second settle.
    constexpr float rate = 768000.f;
    for (float intensity : { 22.f, 55.f, 100.f }) {
        const auto settings = lowend::DSPPrecompute::makeDSPSettings(rate, intensity, 30, 0, 1);
        lowend::Biquad64 filter;
        filter.update(settings.preciseShelf);
        double energy = 0;
        bool finite = true;
        for (int frame = 0; frame < 1536000; ++frame) {
            const float input = static_cast<float>(0.05 * std::sin(2 * std::acos(-1.0) * 55 * frame / rate));
            const float output = filter.process(input);
            finite = finite && std::isfinite(output);
            if (frame >= 768000) energy += static_cast<double>(output) * output;
        }
        const double gainDb = 20 * std::log10(std::sqrt(energy / 768000) / (0.05 / std::sqrt(2.0)));
        const double expected = actualGain(settings.preciseShelf, rate, 55);
        check(finite && std::fabs(gainDb - expected) < 0.001,
              "768 kHz processed sine agrees with precise response within 0.001 dB");
        filter.reset();
        check(filter.process(0) == 0, "precise filter reset clears state");
    }
    std::printf("test_precise_biquad: maximum coefficient response error %.9g dB; %d failure(s)\n",
                maximumErrorDb, failures);
    return failures ? 1 : 0;
}
