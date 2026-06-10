#include <Core/Processor.h>

#include <cmath>
#include <cstdio>
#include <initializer_list>

int main() {
    int failures = 0;
    auto check = [&failures](bool condition, const char* message) {
        if (!condition) {
            std::fprintf(stderr, "FAIL: %s\n", message);
            ++failures;
        }
    };

    lowend::Processor processor;
    processor.prepare(96000.0, 2);
    auto clean = lowend::DSPPrecompute::makeDSPSettings(96000.0f, 0, 0, 0, 0);
    processor.update(clean);

    float left[] = { 0.25f, -0.5f, 0.75f };
    float right[] = { -0.25f, 0.5f, -0.75f };
    float* channels[] = { left, right };
    processor.process(channels, 3);
    check(left[0] == 0.25f && right[2] == -0.75f, "Clean must be bit-identical");

    auto exciter = lowend::DSPPrecompute::makeDSPSettings(96000.0f, 100, 100, 0, 2);
    check(exciter.exciterOversampleFactor == 2, "96 kHz must precompute 2x oversampling");
    processor.update(exciter);
    for (int i = 0; i < 512; ++i) {
        left[0] = (i & 1) == 0 ? 0.3f : -0.3f;
        right[0] = left[0];
        processor.process(channels, 1);
        check(std::isfinite(left[0]) && std::isfinite(right[0]), "Exciter output must remain finite");
    }

    auto highRate = lowend::DSPPrecompute::makeDSPSettings(768000.0f, 100, 100, 0, 2);
    check(highRate.exciterOversampleFactor == 1, "768 kHz must use 1x");

    const float sampleRates[] = { 44100.0f, 48000.0f, 96000.0f, 192000.0f, 768000.0f };
    for (float sampleRate : sampleRates) {
        processor.prepare(sampleRate, 2);
        for (uint32_t model : { 1u, 2u }) {
            auto settings = lowend::DSPPrecompute::makeDSPSettings(
                sampleRate, 55.0f, 30.0f, -1.5f, model);
            processor.update(settings);
            for (int i = 0; i < 2048; ++i) {
                float phase = static_cast<float>(i % 97) / 97.0f;
                left[0] = std::sin(phase * 6.28318530718f) * 0.5f;
                right[0] = std::cos(phase * 6.28318530718f) * 0.5f;
                processor.process(channels, 1);
                check(std::isfinite(left[0]) && std::isfinite(right[0]),
                      "all supported rates and models must remain finite");
            }
            processor.reset();
        }
    }

    if (failures == 0) {
        std::printf("test_processor: all checks passed\n");
    }
    return failures == 0 ? 0 : 1;
}
