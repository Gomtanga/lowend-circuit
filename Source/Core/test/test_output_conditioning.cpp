// test_output_conditioning.cpp — checks for the portable output-conditioning
// stage and its polyphase upsampler.
//
// Expected values come from the documented contract, not from the implementation:
//
//   * The prototype low-pass is defined relative to the input period, its
//     polyphase branches sum to exactly 1 (unity DC gain), and the FIR is
//     linear-phase with tapsPerPhase * factor group delay. A constant therefore
//     passes through unchanged, at any block split and with either branch.
//   * Bypass is the reference behaviour's identity path: an untouched copy at the
//     input frame count, with no headroom applied.
//   * Active live PCM 2x is headroom, then a 2x polyphase upsample, then a
//     non-finite guard.
//
// No check reads a golden sample out of the implementation. Every expected value
// below is either an input value, an arithmetic identity, or a bound derived from
// the filter's documented unity-DC-gain and finite-impulse-response properties.

#include <Core/OutputConditioning.h>
#include <Core/PcmResampler.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <vector>

namespace {

int failures = 0;

// Literal pi rather than M_PI: the repository's Core sources use a literal, and
// MSVC only exposes M_PI behind _USE_MATH_DEFINES.
constexpr double kPi = 3.14159265358979323846;

void check(bool condition, const char* message) {
    if (!condition) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

void checkClose(float actual, float expected, float tolerance, const char* message) {
    if (!(std::fabs(actual - expected) <= tolerance)) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s (actual %.9g, expected %.9g)\n",
                     message, static_cast<double>(actual), static_cast<double>(expected));
    }
}

constexpr float kSampleRate = 48000.0f;
constexpr uint32_t kFrames = 1024;

// Live PCM 2x settings with unity headroom, so output levels are attributable to
// the filter alone unless a check sets a gain on purpose.
LCOutputConditioningSettings liveSettings(float headroomGain = 1.0f,
                                          uint32_t filterMode = 0) {
    LCOutputConditioningSettings settings {};
    settings.enabled = 1;
    settings.outputMode = 1;  // pcmOversampling
    settings.oversamplingFactor = 2;
    settings.filterMode = filterMode;
    settings.headroomGain = headroomGain;
    settings.ditherEnabled = 0;
    settings.noiseShapingEnabled = 0;
    settings.dsdMode = 0;
    return settings;
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Bypass identity: the output is a bit-identical copy of the input and the
//    frame count is unchanged. Covered for the disabled mode and for every mode
//    the live path must not act on (dither, DSD, 4x, 8x).
// ─────────────────────────────────────────────────────────────────────────────
void testBypassIsBitExact() {
    std::vector<float> left(kFrames);
    std::vector<float> right(kFrames);
    for (uint32_t i = 0; i < kFrames; ++i) {
        left[i] = std::sin(0.05f * static_cast<float>(i)) * 0.7f;
        right[i] = -std::cos(0.03f * static_cast<float>(i)) * 0.4f;
    }

    struct BypassCase {
        uint32_t enabled;
        uint32_t outputMode;
        uint32_t factor;
    };
    const BypassCase cases[] = {
        { 0, 1, 2 },  // disabled
        { 1, 0, 2 },  // outputMode bypass
        { 1, 2, 2 },  // dither
        { 1, 3, 2 },  // experimental DSD
        { 1, 1, 4 },  // 4x is offline
        { 1, 1, 8 },  // 8x is offline
    };

    for (const BypassCase& sample : cases) {
        lowend::OutputConditioning conditioning;
        if (!conditioning.prepare(kSampleRate, kFrames)) {
            check(false, "prepare accepted a valid configuration");
            return;
        }
        LCOutputConditioningSettings settings = liveSettings(0.5f);
        settings.enabled = sample.enabled;
        settings.outputMode = sample.outputMode;
        settings.oversamplingFactor = sample.factor;
        const bool active = conditioning.update(settings);
        if (active) {
            check(false, "the live path stayed inactive for a non-2x mode");
            return;
        }

        std::vector<float> outLeft(kFrames, -123.0f);
        std::vector<float> outRight(kFrames, -123.0f);
        const uint32_t outFrames =
            conditioning.process(left.data(), right.data(), kFrames,
                                 outLeft.data(), outRight.data());
        if (outFrames != kFrames) {
            check(false, "bypass returned the input frame count");
            return;
        }
        // Bit-identical, so the comparison is exact, and the untouched sentinel
        // catches an out-of-range write.
        if (outLeft != left || outRight != right) {
            check(false, "bypass copied the input bit-exactly");
            return;
        }
        // Headroom is applied only on the active path, so a 0.5 gain must not have
        // scaled the bypass copy.
    }
    check(true, "bypass copies verbatim at the input frame count for every non-2x mode");
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Frame count: active 2x produces exactly inputFrames * 2 output frames on
//    both channels (the oversampled buffer is longer; only the reported count is
//    the contract).
// ─────────────────────────────────────────────────────────────────────────────
void testActiveFrameCount() {
    for (uint32_t frames : { 1u, 32u, 256u, 1024u }) {
        lowend::OutputConditioning conditioning;
        if (!conditioning.prepare(kSampleRate, kFrames) || !conditioning.update(liveSettings())) {
            check(false, "prepare/update accepted the live 2x configuration");
            return;
        }

        std::vector<float> left(frames, 0.25f);
        std::vector<float> right(frames, -0.25f);
        std::vector<float> outLeft(conditioning.maxOutputFrames(frames), 0.0f);
        std::vector<float> outRight(conditioning.maxOutputFrames(frames), 0.0f);

        const uint32_t outFrames =
            conditioning.process(left.data(), right.data(), frames,
                                 outLeft.data(), outRight.data());
        check(outFrames == frames * 2, "active 2x reports inputFrames * 2 output frames");
        check(conditioning.maxOutputFrames(frames) >= frames * 2,
              "maxOutputFrames covers the active requirement");
        // Nothing past the reported count may be inspected, but the caller's
        // buffer must at least exist at that size — which the indexing above
        // proves: a smaller buffer would have been a heap overflow.
    }
    check(true, "active frame counts follow the 2x contract");
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Non-finite input never reaches the output. A NaN or an infinity in the
//    input, and a non-finite headroom gain, must all leave the output finite.
// ─────────────────────────────────────────────────────────────────────────────
void testNonFiniteNeverReachesTheOutput() {
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();

    lowend::OutputConditioning conditioning;
    if (!conditioning.prepare(kSampleRate, kFrames) || !conditioning.update(liveSettings())) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }

    std::vector<float> left(kFrames, 0.3f);
    std::vector<float> right(kFrames, 0.3f);
    left[100] = nan;
    right[200] = inf;
    left[500] = -inf;

    std::vector<float> outLeft(conditioning.maxOutputFrames(kFrames), 0.0f);
    std::vector<float> outRight(conditioning.maxOutputFrames(kFrames), 0.0f);
    const uint32_t outFrames =
        conditioning.process(left.data(), right.data(), kFrames,
                             outLeft.data(), outRight.data());
    if (outFrames == 0) {
        check(false, "a non-finite input sample still produces output frames");
        return;
    }
    for (uint32_t i = 0; i < outFrames; ++i) {
        if (!std::isfinite(outLeft[i]) || !std::isfinite(outRight[i])) {
            check(false, "a non-finite input sample is replaced by 0 in the output");
            return;
        }
    }
    check(true, "non-finite input is replaced by 0 in the output");

    // A non-finite gain is treated as silence, not as a poison value.
    lowend::OutputConditioning gainConditioning;
    if (!gainConditioning.prepare(kSampleRate, kFrames)) {
        check(false, "prepare accepted a valid configuration");
        return;
    }
    LCOutputConditioningSettings settings = liveSettings(nan);
    if (!gainConditioning.update(settings)) {
        check(false, "a non-finite gain does not deactivate the live path");
        return;
    }
    std::vector<float> constant(kFrames, 0.5f);
    std::vector<float> gainLeft(gainConditioning.maxOutputFrames(kFrames), 0.0f);
    std::vector<float> gainRight(gainConditioning.maxOutputFrames(kFrames), 0.0f);
    const uint32_t gainFrames =
        gainConditioning.process(constant.data(), constant.data(), kFrames,
                                 gainLeft.data(), gainRight.data());
    if (gainFrames != kFrames * 2) {
        check(false, "a non-finite gain still runs the active 2x path");
        return;
    }
    for (uint32_t i = 0; i < gainFrames; ++i) {
        if (!std::isfinite(gainLeft[i]) || !std::isfinite(gainRight[i])) {
            check(false, "a non-finite gain produces a finite output");
            return;
        }
    }
    // Silence in, silence out: a zero gain zeroes the whole path.
    for (uint32_t i = 0; i < gainFrames; ++i) {
        if (gainLeft[i] != 0.0f || gainRight[i] != 0.0f) {
            check(false, "a non-finite gain falls back to silence");
            return;
        }
    }
    check(true, "a non-finite gain falls back to silence");
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Headroom accuracy and unity DC gain on the active path. The per-phase
//    normalization is what makes each polyphase branch sum to exactly 1, so a
//    constant input must come out at exactly input * gain — not merely close. The
//    tolerance is therefore *relative* and tight: without the normalization the
//    short branch's phase sums are off by ~6 ppm, which this catches (the
//    Blackman-windowed truncated prototype is close to 1 per phase, so an
//    absolute tolerance cannot see the difference).
// ─────────────────────────────────────────────────────────────────────────────
void testUnityDcGainAndHeadroom() {
    // Three blocks: the first two flush the filter's startup transient (the
    // history begins at zero), the third is fully inside the steady state.
    const float amplitude = 0.5f;
    for (float gain : { 1.0f, 0.5f, 0.25f }) {
        for (uint32_t filterMode : { 0u, 1u }) {
            lowend::OutputConditioning conditioning;
            if (!conditioning.prepare(kSampleRate, kFrames)
                || !conditioning.update(liveSettings(gain, filterMode))) {
                check(false, "prepare/update accepted the live 2x configuration");
                return;
            }

            std::vector<float> input(kFrames, amplitude);
            std::vector<float> outLeft(conditioning.maxOutputFrames(kFrames), 0.0f);
            std::vector<float> outRight(conditioning.maxOutputFrames(kFrames), 0.0f);

            uint32_t outFrames = 0;
            for (int block = 0; block < 3; ++block) {
                outFrames = conditioning.process(input.data(), input.data(), kFrames,
                                                 outLeft.data(), outRight.data());
            }
            if (outFrames != kFrames * 2) {
                check(false, "the active path reports inputFrames * 2");
                return;
            }

            // Accumulate in double: the point is to measure the filter's gain, not
            // the float summation noise of the test itself.
            const float expected = amplitude * gain;
            for (uint32_t channel = 0; channel < 2; ++channel) {
                const std::vector<float>& out = (channel == 0) ? outLeft : outRight;
                double sum = 0.0;
                for (uint32_t i = outFrames - 256; i < outFrames; ++i) {
                    sum += static_cast<double>(out[i]);
                }
                const double mean = sum / 256.0;
                const double relativeError = std::fabs(mean - expected) / expected;
                if (!(relativeError < 1e-6)) {
                    check(false, "a constant input passes at exactly amplitude * gain "
                                 "(unity DC gain per phase)");
                    return;
                }
            }
        }
    }
    check(true, "unity DC gain holds and headroom gain matches input * gain exactly");
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. 1 kHz sine quality at 2x: the output is finite, has a positive RMS, and its
//    average (DC) matches the input's DC — the filter has unity DC gain and no
//    rectification.
// ─────────────────────────────────────────────────────────────────────────────
void testSineQuality() {
    const double frequency = 1000.0;
    const double amplitude = 0.8;
    const float gain = 0.5f;

    lowend::OutputConditioning conditioning;
    if (!conditioning.prepare(kSampleRate, kFrames)
        || !conditioning.update(liveSettings(gain, 1))) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }

    // A sine whose DC is zero, plus a deliberate constant offset so a
    // rectification bug (a lost sign) is caught by the DC comparison.
    const float dcOffset = 0.1f;
    std::vector<float> input(kFrames);
    double inputSum = 0.0;
    for (uint32_t i = 0; i < kFrames; ++i) {
        const double value =
            dcOffset + amplitude * std::sin(2.0 * kPi * frequency * i / kSampleRate);
        input[i] = static_cast<float>(value);
        inputSum += input[i];
    }
    const double inputDc = inputSum / kFrames;

    std::vector<float> outLeft(conditioning.maxOutputFrames(kFrames), 0.0f);
    std::vector<float> outRight(conditioning.maxOutputFrames(kFrames), 0.0f);
    // One warm-up block first, so the measured block is inside the steady state.
    conditioning.process(input.data(), input.data(), kFrames, outLeft.data(), outRight.data());
    const uint32_t outFrames =
        conditioning.process(input.data(), input.data(), kFrames,
                             outLeft.data(), outRight.data());
    if (outFrames != kFrames * 2) {
        check(false, "the active path reports inputFrames * 2");
        return;
    }

    double energy = 0.0;
    double outputSum = 0.0;
    for (uint32_t i = 0; i < outFrames; ++i) {
        if (!std::isfinite(outLeft[i]) || !std::isfinite(outRight[i])) {
            check(false, "a 1 kHz sine produces a finite output");
            return;
        }
        energy += static_cast<double>(outLeft[i]) * outLeft[i];
        outputSum += outLeft[i];
    }
    const double rms = std::sqrt(energy / outFrames);
    check(rms > 0.0, "a 1 kHz sine produces a non-negative RMS");
    check(std::isfinite(rms), "a 1 kHz sine produces a finite RMS");
    // The DC of the output is the input DC scaled by the gain: unity DC gain
    // through the FIR, then the headroom trim.
    checkClose(static_cast<float>(outputSum / outFrames), static_cast<float>(inputDc) * gain,
               2e-3f, "a 1 kHz sine preserves its DC offset through the 2x path");
    check(true, "a 1 kHz sine survives the 2x path with finite, scaled output");
}

// ─────────────────────────────────────────────────────────────────────────────
// 5b. Impulse response: a delta at input sample c must come out as one
//     symmetric linear-phase response of tapsPerPhase * factor samples starting
//     at output frame c * factor. That is derived from the documented design
//     (sinc × symmetric Blackman window, reversed per phase, linear-phase FIR),
//     not read from the tables:
//       * symmetry about the response centre — out[c*factor + k] == out[c*factor + (L-1-k)];
//       * centroid (L-1)/2, the group delay of a linear-phase FIR;
//       * sum == factor, because the prototype's sinc has unit area per input
//         sample and the polyphase branches sum to 1 across phases;
//       * nothing outside [c*factor, c*factor + L).
// ─────────────────────────────────────────────────────────────────────────────
void testImpulseIsLinearPhase() {
    const uint32_t total = 4096;
    const uint32_t centre = 2048;
    for (uint32_t filterMode : { 0u, 1u }) {
        lowend::PcmResampler resampler(total);
        if (!resampler.prepare(kSampleRate, 2, filterMode)) {
            check(false, "the resampler accepted filter mode 0 or 1");
            return;
        }
        const uint32_t taps = (filterMode == 1) ? lowend::PcmResampler::longTapsPerPhase
                                                : lowend::PcmResampler::shortTapsPerPhase;
        const uint32_t length = taps * 2;  // group delay in output frames

        std::vector<float> input(total, 0.0f);
        input[centre] = 1.0f;
        std::vector<float> output(total * 2, 0.0f);
        if (resampler.processChannel(input.data(), total, output.data()) != total * 2) {
            check(false, "the resampler reported the 2x frame count");
            return;
        }

        double sum = 0.0;
        double centroid = 0.0;
        double peak = 0.0;
        for (uint32_t k = 0; k < length; ++k) {
            const double value = output[centre * 2 + k];
            sum += value;
            centroid += static_cast<double>(k) * value;
            peak = std::max(peak, std::fabs(value));
        }
        if (!(peak > 0.0)) {
            check(false, "an impulse produces a non-zero response");
            return;
        }
        // Linear phase: symmetric about (length - 1) / 2.
        double worstAsymmetry = 0.0;
        for (uint32_t k = 0; k < length; ++k) {
            const double a = output[centre * 2 + k];
            const double b = output[centre * 2 + (length - 1 - k)];
            worstAsymmetry = std::max(worstAsymmetry, std::fabs(a - b));
        }
        check(worstAsymmetry / peak < 1e-5, "the impulse response is symmetric (linear phase)");
        check(std::fabs(centroid / sum - (static_cast<double>(length) - 1.0) / 2.0) < 1e-2,
              "the impulse response centroid is the linear-phase group delay");
        // Unity DC gain across the polyphase branches: a unit impulse carries unit
        // area per input sample, and the 2x output holds twice as many samples.
        check(std::fabs(sum - 2.0) < 1e-4, "the impulse response sums to the 2x factor");
        // The response is confined to its own window: a wrong anchor or a stale
        // sample would leak energy outside it.
        double outside = 0.0;
        for (uint32_t i = 0; i < total * 2; ++i) {
            if (i >= centre * 2 && i < centre * 2 + length) {
                continue;
            }
            outside = std::max(outside, std::fabs(static_cast<double>(output[i])));
        }
        check(outside / peak < 1e-6, "the impulse response does not leak outside its window");
    }
    check(true, "the impulse response is a linear-phase FIR confined to tapsPerPhase * factor");
}

// Independent reference for the documented polyphase design, re-derived from the
// reference implementation's design comments (not from Core's tables):
//
//   * prototype: h[n] = sinc((n - c)/factor) * Blackman(n), c = (length - 1)/2,
//     length = factor * tapsPerPhase, Blackman = 0.42 - 0.5 cos(2*pi*n/(L-1))
//     + 0.08 cos(4*pi*n/(L-1))  [cut-off at pi/factor input-rate radians]
//   * per-phase unity DC gain: each branch's taps are divided by their own sum
//   * causal polyphase convolution: for output frame i = j*factor + p,
//         y[i] = sum over m in [0, taps) of h[p + m*factor] / phaseSum(p) * x[j - m]
//     with x[k] = 0 for k < 0. (Zero-stuffing the input by `factor` and
//     convolving with h gives exactly this, because i - (p + m*factor) is always
//     a multiple of factor.)
//
// A phase-permutation or a tap-order change moves samples in this model, so it
// pins the phase/lag relationship that a statistic like "symmetric" cannot.
class ReferenceResampler {
public:
    ReferenceResampler(uint32_t factor, uint32_t tapsPerPhase) {
        const uint32_t length = factor * tapsPerPhase;
        const double centre = (static_cast<double>(length) - 1.0) / 2.0;
        prototype_.assign(length, 0.0);
        for (uint32_t n = 0; n < length; ++n) {
            const double x = (static_cast<double>(n) - centre) / static_cast<double>(factor);
            const double sinc = (std::fabs(x) < 1e-12) ? 1.0 : std::sin(kPi * x) / (kPi * x);
            const double w = 0.42
                - 0.5 * std::cos(2.0 * kPi * static_cast<double>(n)
                                 / static_cast<double>(length - 1))
                + 0.08 * std::cos(4.0 * kPi * static_cast<double>(n)
                                  / static_cast<double>(length - 1));
            prototype_[n] = sinc * w;
        }
        phaseSum_.assign(factor, 0.0);
        for (uint32_t p = 0; p < factor; ++p) {
            double sum = 0.0;
            for (uint32_t m = 0; m < tapsPerPhase; ++m) {
                sum += prototype_[p + m * factor];
            }
            phaseSum_[p] = sum;
        }
    }

    // Output frame `i` for a stream whose samples before index 0 are zero.
    double sample(const std::vector<float>& input, uint32_t factor,
                  uint32_t tapsPerPhase, uint32_t i) const {
        const uint32_t j = i / factor;
        const uint32_t p = i % factor;
        double sum = 0.0;
        for (uint32_t m = 0; m < tapsPerPhase; ++m) {
            if (m > j) {
                break;  // x[j - m] is history, zero for a single-call stream
            }
            sum += prototype_[p + m * factor] / phaseSum_[p]
                * static_cast<double>(input[j - m]);
        }
        return sum;
    }

private:
    std::vector<double> prototype_;
    std::vector<double> phaseSum_;
};

// ─────────────────────────────────────────────────────────────────────────────
// 5c. Sample-exact agreement with the independently derived reference model
//     above. This is the check that pins the phase/lag relationship: the
//     statistic-only checks in 5b cannot see a phase permutation.
// ─────────────────────────────────────────────────────────────────────────────
void testMatchesIndependentReferenceModel() {
    const uint32_t factor = 2;
    const uint32_t total = 4096;
    std::vector<float> input(total);
    for (uint32_t i = 0; i < total; ++i) {
        input[i] = 0.8f * std::sin(0.013f * static_cast<float>(i))
            + 0.3f * std::cos(0.37f * static_cast<float>(i));
    }

    for (uint32_t filterMode : { 0u, 1u }) {
        const uint32_t taps = (filterMode == 1) ? lowend::PcmResampler::longTapsPerPhase
                                                : lowend::PcmResampler::shortTapsPerPhase;
        ReferenceResampler reference(factor, taps);

        lowend::PcmResampler resampler(total);
        if (!resampler.prepare(kSampleRate, factor, filterMode)) {
            check(false, "the resampler accepted filter mode 0 or 1");
            return;
        }
        std::vector<float> output(total * factor, 0.0f);
        if (resampler.processChannel(input.data(), total, output.data()) != total * factor) {
            check(false, "the resampler reported the 2x frame count");
            return;
        }

        // The first `taps` output frames depend only on the block's own samples
        // (the history is zero), so the reference is exact without modelling
        // any prior state.
        const uint32_t checked = taps * factor;
        for (uint32_t i = 0; i < checked; ++i) {
            const double expected = reference.sample(input, factor, taps, i);
            const double actual = static_cast<double>(output[i]);
            if (!(std::fabs(actual - expected) <= 1e-5)) {
                check(false, "the output matches the independently derived polyphase model");
                return;
            }
        }
    }
    check(true, "the output matches the independently derived polyphase reference model");
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Unsupported factor: prepare() rejects anything that is not 2, 4 or 8, and
//    leaves the previous configuration usable.
// ─────────────────────────────────────────────────────────────────────────────
void testUnsupportedFactorIsRejected() {
    lowend::PcmResampler resampler(64);
    check(!resampler.prepare(kSampleRate, 0, 0), "factor 0 is rejected");
    check(!resampler.prepare(kSampleRate, 1, 0), "factor 1 is rejected");
    check(!resampler.prepare(kSampleRate, 3, 0), "factor 3 is rejected");
    check(!resampler.prepare(kSampleRate, 16, 0), "factor 16 is rejected");
    check(!resampler.prepare(kSampleRate, 2, 3), "filter mode above 2 is rejected");
    check(!resampler.prepare(0.0, 2, 0), "a zero sample rate is rejected");
    check(!resampler.prepare(-48000.0, 2, 0), "a negative sample rate is rejected");
    check(!resampler.prepare(std::numeric_limits<double>::quiet_NaN(), 2, 0),
          "a non-finite sample rate is rejected");

    // A rejected prepare() must not disarm a working configuration.
    if (!resampler.prepare(kSampleRate, 2, 0)) {
        check(false, "factor 2 is accepted");
        return;
    }
    if (resampler.prepare(kSampleRate, 3, 0)) {
        check(false, "an unsupported factor is rejected even after a good prepare");
        return;
    }
    check(resampler.factor() == 2, "a rejected prepare keeps the previous factor");

    const float input = 0.25f;
    float output[2] = { -1.0f, -1.0f };
    check(resampler.processChannel(&input, 1, output) == 2,
          "the previous configuration still processes after a rejected prepare");
    check(resampler.latencyFrames() == lowend::PcmResampler::shortTapsPerPhase * 2,
          "the short branch reports tapsPerPhase * factor latency");
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Oversized block: process() returns 0 and must not write a single output
//    sample (so the caller's buffer is untouched).
// ─────────────────────────────────────────────────────────────────────────────
void testOversizedBlockIsRejectedWithoutWriting() {
    const uint32_t maxInputFrames = 256;
    lowend::OutputConditioning conditioning;
    if (!conditioning.prepare(kSampleRate, maxInputFrames)) {
        check(false, "prepare accepted a valid configuration");
        return;
    }

    // Oversized while active.
    if (!conditioning.update(liveSettings(0.5f))) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }
    std::vector<float> input(maxInputFrames + 1, 0.4f);
    std::vector<float> outLeft(maxInputFrames * 4, 42.0f);
    std::vector<float> outRight(maxInputFrames * 4, 42.0f);
    const uint32_t activeFrames =
        conditioning.process(input.data(), input.data(), maxInputFrames + 1,
                             outLeft.data(), outRight.data());
    check(activeFrames == 0, "an oversized active block returns 0");
    for (uint32_t i = 0; i < maxInputFrames * 4; ++i) {
        if (outLeft[i] != 42.0f || outRight[i] != 42.0f) {
            check(false, "an oversized block does not write the output");
            return;
        }
    }
    // A zero-frame block is degenerate and must also return 0 without writing.
    const uint32_t emptyFrames =
        conditioning.process(input.data(), input.data(), 0, outLeft.data(), outRight.data());
    check(emptyFrames == 0, "a zero-frame block returns 0");
    for (uint32_t i = 0; i < maxInputFrames * 4; ++i) {
        if (outLeft[i] != 42.0f || outRight[i] != 42.0f) {
            check(false, "a zero-frame block does not write the output");
            return;
        }
    }

    // Oversized while bypassing: same rule.
    LCOutputConditioningSettings bypass = liveSettings();
    bypass.enabled = 0;
    conditioning.update(bypass);
    const uint32_t bypassFrames =
        conditioning.process(input.data(), input.data(), maxInputFrames + 1,
                             outLeft.data(), outRight.data());
    check(bypassFrames == 0, "an oversized bypass block returns 0");
    for (uint32_t i = 0; i < maxInputFrames * 4; ++i) {
        if (outLeft[i] != 42.0f || outRight[i] != 42.0f) {
            check(false, "an oversized bypass block does not write the output");
            return;
        }
    }
    check(true, "oversized and empty blocks are rejected without writing");
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. Reset determinism: the same input after reset() produces the same output as
//    from a fresh instance, and a reset mid-stream removes the effect of the
//    earlier blocks.
// ─────────────────────────────────────────────────────────────────────────────
void testResetIsDeterministic() {
    std::vector<float> input(kFrames);
    for (uint32_t i = 0; i < kFrames; ++i) {
        input[i] = 0.6f * std::sin(0.11f * static_cast<float>(i));
    }

    lowend::OutputConditioning conditioning;
    if (!conditioning.prepare(kSampleRate, kFrames)
        || !conditioning.update(liveSettings(0.75f, 1))) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }

    const uint32_t capacity = conditioning.maxOutputFrames(kFrames);
    std::vector<float> firstLeft(capacity, 0.0f);
    std::vector<float> firstRight(capacity, 0.0f);
    std::vector<float> secondLeft(capacity, 0.0f);
    std::vector<float> secondRight(capacity, 0.0f);

    conditioning.process(input.data(), input.data(), kFrames,
                         firstLeft.data(), firstRight.data());
    conditioning.reset();
    const uint32_t outFrames =
        conditioning.process(input.data(), input.data(), kFrames,
                             secondLeft.data(), secondRight.data());
    if (outFrames != kFrames * 2) {
        check(false, "the active path reports inputFrames * 2");
        return;
    }

    // A fresh instance fed the same block must agree: reset() restores the
    // initial state exactly.
    lowend::OutputConditioning fresh;
    if (!fresh.prepare(kSampleRate, kFrames) || !fresh.update(liveSettings(0.75f, 1))) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }
    std::vector<float> freshLeft(capacity, 0.0f);
    std::vector<float> freshRight(capacity, 0.0f);
    const uint32_t freshFrames =
        fresh.process(input.data(), input.data(), kFrames, freshLeft.data(), freshRight.data());

    if (freshFrames != outFrames) {
        check(false, "a fresh instance reports the same frame count as a reset one");
        return;
    }
    for (uint32_t i = 0; i < outFrames; ++i) {
        if (secondLeft[i] != freshLeft[i] || secondRight[i] != freshRight[i]) {
            check(false, "reset() restores the output of a fresh instance exactly");
            return;
        }
    }
    check(true, "reset() is deterministic and matches a fresh instance");
}

// ─────────────────────────────────────────────────────────────────────────────
// 8b. Re-entering the live path starts from a clean filter state, and a bad
//     headroom value does not silence the path permanently.
//
//     The reference clears the FIR history when the live activation changes, so
//     the reactivated path must behave exactly like a fresh one rather than
//     carrying the previous block's tail. It also sanitizes the headroom gain
//     when the snapshot is applied — before it can reach the filter — so a
//     non-finite gain cannot poison the per-channel history and keep the output
//     silent after a good gain arrives.
// ─────────────────────────────────────────────────────────────────────────────
void testActivationResetsAndGainRecovers() {
    std::vector<float> loud(kFrames, 0.9f);
    std::vector<float> quiet(kFrames, 0.05f);

    lowend::OutputConditioning conditioning;
    if (!conditioning.prepare(kSampleRate, kFrames)
        || !conditioning.update(liveSettings(1.0f))) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }
    const uint32_t capacity = conditioning.maxOutputFrames(kFrames);
    std::vector<float> scratchLeft(capacity, 0.0f);
    std::vector<float> scratchRight(capacity, 0.0f);
    std::vector<float> outLeft(capacity, 0.0f);
    std::vector<float> outRight(capacity, 0.0f);

    // Drive the filter hard so its history is far from zero, then leave and
    // re-enter the live path.
    conditioning.process(loud.data(), loud.data(), kFrames, scratchLeft.data(),
                         scratchRight.data());
    LCOutputConditioningSettings bypass = liveSettings();
    bypass.enabled = 0;
    conditioning.update(bypass);
    if (!conditioning.update(liveSettings(1.0f))) {
        check(false, "the live path reactivates after bypass");
        return;
    }
    const uint32_t outFrames =
        conditioning.process(quiet.data(), quiet.data(), kFrames, outLeft.data(), outRight.data());
    if (outFrames != kFrames * 2) {
        check(false, "the reactivated path reports inputFrames * 2");
        return;
    }

    // A fresh instance that never saw the loud block must produce the same
    // samples: reactivation cleared the history rather than replaying it.
    lowend::OutputConditioning fresh;
    if (!fresh.prepare(kSampleRate, kFrames) || !fresh.update(liveSettings(1.0f))) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }
    std::vector<float> freshLeft(capacity, 0.0f);
    std::vector<float> freshRight(capacity, 0.0f);
    const uint32_t freshFrames =
        fresh.process(quiet.data(), quiet.data(), kFrames, freshLeft.data(), freshRight.data());
    if (freshFrames != outFrames) {
        check(false, "the reactivated path reports the fresh frame count");
        return;
    }
    for (uint32_t i = 0; i < outFrames; ++i) {
        if (outLeft[i] != freshLeft[i] || outRight[i] != freshRight[i]) {
            check(false, "reactivation clears the FIR history (matches a fresh instance)");
            return;
        }
    }
    check(true, "reactivation clears the FIR history");

    // A non-finite gain is sanitized at update() time, not left to poison the
    // history: restoring a finite gain must bring the audio back without a reset.
    // The poisoned block drives a whole 127-sample history window, so an
    // unsanitized NaN would still be inside the FIR when the next block runs.
    lowend::OutputConditioning recovery;
    if (!recovery.prepare(kSampleRate, kFrames)
        || !recovery.update(liveSettings(std::numeric_limits<float>::quiet_NaN()))) {
        check(false, "a non-finite gain does not deactivate the live path");
        return;
    }
    std::vector<float> recLeft(capacity, 0.0f);
    std::vector<float> recRight(capacity, 0.0f);
    for (int block = 0; block < 3; ++block) {
        recovery.process(quiet.data(), quiet.data(), kFrames, recLeft.data(), recRight.data());
    }
    if (!recovery.update(liveSettings(1.0f))) {
        check(false, "a finite gain keeps the live path active");
        return;
    }
    const uint32_t recoveredFrames =
        recovery.process(quiet.data(), quiet.data(), kFrames, recLeft.data(), recRight.data());
    if (recoveredFrames != kFrames * 2) {
        check(false, "the recovered path reports inputFrames * 2");
        return;
    }
    bool anyAudible = false;
    for (uint32_t i = 0; i < recoveredFrames; ++i) {
        if (!std::isfinite(recLeft[i]) || !std::isfinite(recRight[i])) {
            check(false, "the recovered output stays finite");
            return;
        }
        if (recLeft[i] != 0.0f || recRight[i] != 0.0f) {
            anyAudible = true;
        }
    }
    check(anyAudible, "a bad gain does not permanently silence the path");

    // The sharp oracle: a gain of 0 writes silence into the history, so restoring
    // a finite gain must reproduce a fresh instance's output exactly. If the NaN
    // reached the history instead of being sanitized on the way in, the first
    // ~254 output frames would differ (they would be the finite guard's zeros
    // rather than the filter's own transient).
    lowend::OutputConditioning untouched;
    if (!untouched.prepare(kSampleRate, kFrames) || !untouched.update(liveSettings(1.0f))) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }
    std::vector<float> untouchedLeft(capacity, 0.0f);
    std::vector<float> untouchedRight(capacity, 0.0f);
    const uint32_t untouchedFrames = untouched.process(quiet.data(), quiet.data(), kFrames,
                                                       untouchedLeft.data(), untouchedRight.data());
    if (untouchedFrames != recoveredFrames) {
        check(false, "the recovered path reports the fresh frame count");
        return;
    }
    for (uint32_t i = 0; i < recoveredFrames; ++i) {
        if (recLeft[i] != untouchedLeft[i] || recRight[i] != untouchedRight[i]) {
            check(false, "a sanitized gain leaves the FIR history clean (matches a fresh instance)");
            return;
        }
    }
    check(true, "a sanitized gain leaves the FIR history clean");
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. Block continuity. This is the load-bearing check: splitting one stream into
//    blocks must not change the samples, because the FIR keeps 127 input samples
//    of history across calls. A dropped history tail, a wrong stride or a stale
//    window shows up as a difference at every block boundary.
// ─────────────────────────────────────────────────────────────────────────────
void testBlockContinuity() {
    const uint32_t total = 4096;
    std::vector<float> left(total);
    std::vector<float> right(total);
    for (uint32_t i = 0; i < total; ++i) {
        left[i] = 0.7f * std::sin(0.017f * static_cast<float>(i))
            + 0.2f * std::cos(0.31f * static_cast<float>(i));
        right[i] = -0.5f * std::cos(0.023f * static_cast<float>(i));
    }

    // Reference: one call for the whole stream. A short block flushes the
    // start-up transient so both sides begin in the same state.
    lowend::OutputConditioning whole;
    if (!whole.prepare(kSampleRate, total) || !whole.update(liveSettings(0.8f, 0))) {
        check(false, "prepare/update accepted the live 2x configuration");
        return;
    }
    const uint32_t wholeCapacity = whole.maxOutputFrames(total);
    std::vector<float> wholeLeft(wholeCapacity, 0.0f);
    std::vector<float> wholeRight(wholeCapacity, 0.0f);
    const uint32_t wholeFrames =
        whole.process(left.data(), right.data(), total, wholeLeft.data(), wholeRight.data());
    if (wholeFrames != total * 2) {
        check(false, "the active path reports inputFrames * 2");
        return;
    }

    // Split: the same stream in blocks of several different sizes, including a
    // size much shorter than the 127-sample history and a non-divisor of it.
    const uint32_t blockSizes[] = { 1, 3, 64, 200, 1024 };
    for (uint32_t blockSize : blockSizes) {
        lowend::OutputConditioning split;
        if (!split.prepare(kSampleRate, total) || !split.update(liveSettings(0.8f, 0))) {
            check(false, "prepare/update accepted the live 2x configuration");
            return;
        }
        std::vector<float> splitLeft(wholeCapacity, 0.0f);
        std::vector<float> splitRight(wholeCapacity, 0.0f);

        uint32_t offset = 0;
        uint32_t written = 0;
        bool ok = true;
        while (offset < total && ok) {
            const uint32_t remaining = total - offset;
            const uint32_t frames = remaining < blockSize ? remaining : blockSize;
            const uint32_t produced = split.process(left.data() + offset, right.data() + offset,
                                                    frames,
                                                    splitLeft.data() + written,
                                                    splitRight.data() + written);
            if (produced != frames * 2) {
                check(false, "each split block reports frames * 2");
                ok = false;
                break;
            }
            offset += frames;
            written += produced;
        }
        if (!ok) {
            return;
        }
        if (written != wholeFrames) {
            check(false, "split processing writes the same total frame count");
            return;
        }
        for (uint32_t i = 0; i < wholeFrames; ++i) {
            if (splitLeft[i] != wholeLeft[i] || splitRight[i] != wholeRight[i]) {
                check(false, "block-split output matches single-shot output exactly");
                return;
            }
        }
    }

    // The same property for the resampler alone, at the sample level and on both
    // branches: a filter change must also keep the history aligned.
    for (uint32_t filterMode : { 0u, 1u }) {
        lowend::PcmResampler single(total);
        lowend::PcmResampler split(total);
        if (!single.prepare(kSampleRate, 2, filterMode) || !split.prepare(kSampleRate, 2, filterMode)) {
            check(false, "the resampler accepted filter mode 0 or 1");
            return;
        }
        std::vector<float> singleOut(total * 2, 0.0f);
        std::vector<float> splitOut(total * 2, 0.0f);
        single.processChannel(left.data(), total, singleOut.data());
        for (uint32_t offset = 0; offset < total; offset += 7) {
            const uint32_t frames = (total - offset < 7) ? (total - offset) : 7;
            split.processChannel(left.data() + offset, frames, splitOut.data() + offset * 2);
        }
        for (uint32_t i = 0; i < total * 2; ++i) {
            if (splitOut[i] != singleOut[i]) {
                check(false, "resampler block splitting is sample-exact");
                return;
            }
        }
    }

    check(true, "block splitting is sample-exact through the FIR history");

    // A block larger than the constructor's maxInputFrames is refused rather than
    // silently truncated, and the caller's buffer is left untouched. This is the
    // failure mode that reads as "no audio" at runtime, so it is asserted rather
    // than assumed: processChannel returns 0 and writes nothing.
    {
        lowend::PcmResampler bounded(64);
        if (!bounded.prepare(kSampleRate, 2, 0)) {
            check(false, "the resampler accepted the bounded configuration");
            return;
        }
        std::vector<float> sentinel(256, 123.0f);
        const uint32_t produced = bounded.processChannel(left.data(), 200, sentinel.data());
        check(produced == 0, "an oversized block is refused");
        bool untouched = true;
        for (float value : sentinel) {
            if (value != 123.0f) {
                untouched = false;
                break;
            }
        }
        check(untouched, "a refused block leaves the output buffer untouched");

        // The same instance must still process a block that does fit.
        std::vector<float> ok(256, 0.0f);
        check(bounded.processChannel(left.data(), 64, ok.data()) == 128,
              "a block within the constructor bound is processed");
    }
}

} // namespace

int main() {
    testBypassIsBitExact();
    testActiveFrameCount();
    testNonFiniteNeverReachesTheOutput();
    testUnityDcGainAndHeadroom();
    testSineQuality();
    testImpulseIsLinearPhase();
    testMatchesIndependentReferenceModel();
    testUnsupportedFactorIsRejected();
    testOversizedBlockIsRejectedWithoutWriting();
    testResetIsDeterministic();
    testActivationResetsAndGainRecovers();
    testBlockContinuity();

    if (failures == 0) {
        std::printf("test_output_conditioning: all checks passed\n");
    }
    return failures == 0 ? 0 : 1;
}
