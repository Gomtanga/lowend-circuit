// Black-box tonal measurement gates plus opt-in CSV characterization.
// Run with --csv-directory EXISTING_DIRECTORY for the extended report.
#include <Core/CircuitBass.h>
#include <Core/HighExciter.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

namespace {
constexpr double pi = 3.14159265358979323846;
int failures = 0;
void check(bool ok, const char* message) {
    if (!ok) { ++failures; std::fprintf(stderr, "FAIL: %s\n", message); }
}
double db(double amplitude) { return 20 * std::log10(std::max(amplitude, 1e-15)); }

// Controlled counterfactual: the current filters, settings, gain and protector,
// changing ONLY the saturation plateau back to +/-1. This is not a full
// df07c6c reference (that revision also used Float coefficients, for example).
class LegacyPlateauCircuit {
    LCDSPSettings settings;
    lowend::Biquad64 shelf, pre, de;
    lowend::OnePole bass, sub;
public:
    size_t outside = 0;
    explicit LegacyPlateauCircuit(const LCDSPSettings& s) : settings(s) {
        shelf.update(s.preciseShelf); pre.update(s.preciseTransformerPreEmphasis);
        de.update(s.preciseTransformerDeEmphasis);
        bass.update(s.bassAlpha); sub.update(s.subAlpha);
    }
    float process(float input) {
        const float shaped = shelf.process(input) + sub.process(input) * settings.bodyInjectionGain;
        const float headroom = shaped * settings.circuitHeadroomGain;
        const float circuitInput = headroom + bass.process(input) * settings.virtualFeedbackGain
            * settings.circuitHeadroomGain;
        const float biased = pre.process(circuitInput) * settings.transformerDrive + settings.transformerAsymmetry;
        if (std::fabs(biased) > 1) ++outside;
        const float clipped = biased > 1 ? 1 : biased < -1 ? -1
            : biased - biased * biased * biased * 0.33333334f;
        const float saturated = (clipped - settings.transformerBiasOffset) * settings.transformerMakeupGain;
        const float blended = headroom + (de.process(saturated) - headroom) * settings.wetMix;
        const float value = blended * settings.circuitMakeupGain * settings.outputGain;
        const float magnitude = std::fabs(value);
        if (magnitude <= 0.8f) return value;
        if (magnitude >= 1.2f) return std::copysign(1.f, value);
        const float t = (magnitude - 0.8f) / (1.2f - 0.8f);
        return std::copysign(0.8f + (1.f - 0.8f) * (2.f * t - t * t), value);
    }
};

// Unwindowed radix-2 DFT: exact-bin tones after settling need no window.
// Keeping the transform local makes amplitude normalization inspectable.
void fft(std::vector<std::complex<double>>& values) {
    const size_t n = values.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(values[i], values[j]);
    }
    for (size_t length = 2; length <= n; length <<= 1) {
        const std::complex<double> step = std::polar(1.0, -2 * pi / length);
        for (size_t begin = 0; begin < n; begin += length) {
            std::complex<double> phase = 1;
            for (size_t j = 0; j < length / 2; ++j) {
                const auto even = values[begin + j];
                const auto odd = phase * values[begin + j + length / 2];
                values[begin + j] = even + odd;
                values[begin + j + length / 2] = even - odd;
                phase *= step;
            }
        }
    }
}
double binAmplitude(const std::vector<std::complex<double>>& values, size_t bin) {
    const double weight = bin == 0 || bin == values.size() / 2 ? 1 : 2;
    return weight * std::abs(values[bin]) / values.size();
}
void calibration() {
    constexpr size_t count = 32768, bin = 713;
    std::vector<std::complex<double>> signal(count);
    double timeEnergy = 0;
    for (size_t i = 0; i < count; ++i) {
        const double value = 0.125 + 0.25 * std::sin(2 * pi * bin * i / count);
        signal[i] = value; timeEnergy += value * value;
    }
    fft(signal);
    double frequencyEnergy = 0;
    for (const auto value : signal) frequencyEnergy += std::norm(value);
    check(std::fabs(binAmplitude(signal, bin) - 0.25) < 1e-10, "FFT peak sine normalization");
    check(std::fabs(binAmplitude(signal, 0) - 0.125) < 1e-10, "FFT DC normalization");
    check(std::fabs(timeEnergy / count - frequencyEnergy / (count * count)) < 1e-10,
          "FFT Parseval normalization");
}

void circuitSweeps() {
    // Actual complete processor: continuous logarithmic 20 -> 500 Hz sweep.
    // Quiet input stays inside the unchanged cubic region. A global makeup
    // change would fail the equality gate even if continuity still passed.
    for (float intensity : {22.f, 55.f, 100.f}) {
        for (float amplitude : {0.01f, 0.8f}) {
            const auto settings = lowend::DSPPrecompute::makeDSPSettings(48000, intensity, 30, 0, 1);
            lowend::CircuitBass actual; actual.update(settings);
            LegacyPlateauCircuit previous(settings);
            double phase = 0, maximumDifference = 0, peak = 0;
            bool finite = true;
            for (int frame = 0; frame < 96000; ++frame) {
                const double frequency = 20 * std::pow(25.0, double(frame) / 95999);
                phase += 2 * pi * frequency / 48000;
                const float input = amplitude * float(std::sin(phase));
                float output = 0, right = 0; actual.process(input, input, output, right);
                const float prior = previous.process(input);
                finite = finite && std::isfinite(output) && std::isfinite(right);
                peak = std::max(peak, double(std::fabs(output)));
                maximumDifference = std::max(maximumDifference, double(std::fabs(output - prior)));
            }
            check(finite && peak <= 1, "Circuit low-bass sweep finite and bounded");
            if (amplitude < 0.1) {
                check(previous.outside == 0, "quiet sweep stays inside unchanged cubic region");
                check(maximumDifference < 2e-7, "quiet sweep preserves response without global gain compensation");
                check(peak > amplitude * 0.5, "quiet sweep is not muted");
            }
        }
    }
}

void circuitReport(const std::string& directory) {
    std::ofstream csv(directory + "/circuit-stepped-sweep.csv");
    check(bool(csv), "open Circuit CSV");
    csv.precision(12);
    csv << "rate,intensity,body,amplitude,frequency,new_rms,new_peak,old_plateau_rms,old_plateau_peak,new_fundamental_gain_db,thd_2_to_5_db,old_to_new_level_match_db,level_matched_residual_db,max_sample_difference,plateau_samples\n";
    for (float rate : {48000.f, 192000.f, 768000.f})
    for (float intensity : {22.f, 55.f, 100.f})
    for (float amplitude : {0.01f, 0.1f, 0.5f, 0.9f})
    for (double frequency : {20., 40., 60., 80., 120., 200., 320., 500.}) {
        const auto settings = lowend::DSPPrecompute::makeDSPSettings(rate, intensity, 30, 0, 1);
        lowend::CircuitBass actual; actual.update(settings);
        LegacyPlateauCircuit previous(settings);
        const int count = int(rate) / 4; // 0.25 s settle + 0.25 s measurement; all exact cycles.
        std::complex<double> phase = 1;
        const auto step = std::polar(1.0, 2 * pi * frequency / rate);
        std::array<std::complex<double>, 5> harmonics{};
        double newEnergy = 0, oldEnergy = 0, cross = 0, newPeak = 0, oldPeak = 0, maximumDifference = 0;
        bool finite = true;
        for (int frame = 0; frame < count * 2; ++frame) {
            const float input = amplitude * float(phase.imag());
            float output = 0, right = 0; actual.process(input, input, output, right);
            const float prior = previous.process(input);
            finite = finite && std::isfinite(output) && std::isfinite(prior);
            if (frame >= count) {
                newEnergy += double(output) * output; oldEnergy += double(prior) * prior;
                cross += double(output) * prior;
                newPeak = std::max(newPeak, double(std::fabs(output))); oldPeak = std::max(oldPeak, double(std::fabs(prior)));
                maximumDifference = std::max(maximumDifference, double(std::fabs(output - prior)));
                std::complex<double> multiple = std::conj(phase);
                for (auto& harmonic : harmonics) { harmonic += double(output) * multiple; multiple *= std::conj(phase); }
            }
            phase *= step;
        }
        check(finite && newPeak <= 1, "Circuit stepped sweep finite and bounded");
        const double newRMS = std::sqrt(newEnergy / count), oldRMS = std::sqrt(oldEnergy / count);
        const double gain = newRMS / oldRMS;
        const double residual = std::sqrt(std::max(0.0, (newEnergy + gain * gain * oldEnergy - 2 * gain * cross) / count));
        double harmonicEnergy = 0;
        for (size_t h = 1; h < harmonics.size(); ++h) harmonicEnergy += std::norm(harmonics[h]);
        csv << rate << ',' << intensity << ",30," << amplitude << ',' << frequency << ',' << newRMS << ',' << newPeak << ','
            << oldRMS << ',' << oldPeak << ',' << db(2 * std::abs(harmonics[0]) / count / amplitude) << ','
            << db(std::sqrt(harmonicEnergy) / std::abs(harmonics[0])) << ',' << db(gain) << ',' << db(residual / newRMS) << ','
            << maximumDifference << ',' << previous.outside << '\n';
    }
}

void exciterReport(const std::string& directory) {
    std::ofstream csv(directory + "/exciter-harmonics-alias.csv");
    check(bool(csv), "open Exciter CSV");
    csv.precision(12);
    csv << "rate,requested_factor,actual_factor,amplitude,frequency,fft_frames,output_peak,dc_dbfs,wet_fundamental_dbfs,harmonic,unfolded_frequency,observed_frequency,classification,amplitude_dbfs\n";
    constexpr size_t count = 32768;
    for (float rate : {44100.f, 48000.f, 96000.f})
    for (double target : {9000., 13000., 18000.})
    for (uint32_t factor : {1u, 2u, 4u}) {
        const size_t inputBin = size_t(std::llround(target * count / rate));
        const double frequency = double(inputBin) * rate / count;
        const auto settings = lowend::DSPPrecompute::makeDSPSettings(rate, 100, 100, 0, 2, factor);
        lowend::HighExciter actual; actual.update(settings);
        const size_t settle = (size_t(rate) / count + 1) * count; // >1 s, full periods.
        std::vector<std::complex<double>> wet(count);
        double peak = 0;
        for (size_t frame = 0; frame < settle + count; ++frame) {
            const float input = float(0.25 * std::sin(2 * pi * inputBin * (frame % count) / count));
            float output = 0, right = 0; actual.process(input, input, output, right);
            check(std::isfinite(output) && std::isfinite(right), "Exciter spectrum finite");
            if (frame >= settle) { wet[frame - settle] = double(output) - input; peak = std::max(peak, double(std::fabs(output))); }
        }
        check(peak < 0.99, "Exciter alias fixture excludes final output clipping");
        fft(wet);
        for (size_t harmonic : {2u, 3u}) {
            const size_t wrapped = harmonic * inputBin % count;
            const size_t observedBin = std::min(wrapped, count - wrapped);
            check(observedBin != inputBin && observedBin != 0 && observedBin != count / 2,
                  "Exciter fixture harmonics do not collide with input/DC/Nyquist");
            csv << rate << ',' << factor << ',' << settings.exciterOversampleFactor << ",0.25," << frequency << ',' << count << ',' << peak << ','
                << db(binAmplitude(wet, 0)) << ',' << db(binAmplitude(wet, inputBin)) << ',' << harmonic << ','
                << harmonic * frequency << ',' << double(observedBin) * rate / count << ','
                << (harmonic * frequency > rate / 2 ? "aliased" : "in_band") << ',' << db(binAmplitude(wet, observedBin)) << '\n';
        }
    }
}
}

int main(int argc, char** argv) {
    calibration();
    circuitSweeps();
    if (argc == 3 && std::string(argv[1]) == "--csv-directory") {
        circuitReport(argv[2]);
        exciterReport(argv[2]);
    } else if (argc != 1) {
        std::fprintf(stderr, "usage: test_tonal_measurements [--csv-directory EXISTING_DIRECTORY]\n");
        return 2;
    }
    std::printf("Tonal measurements: FFT calibration and Circuit 20-500 Hz sweep; %d failure(s)\n", failures);
    return failures ? 1 : 0;
}
