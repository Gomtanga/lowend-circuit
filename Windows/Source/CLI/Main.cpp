// Main.cpp — entry point for the Windows CLI.
//
// Commands:
//   lowend_windows                      run capture → DSP → render until Ctrl-C
//   lowend_windows --list-devices       enumerate endpoints (no audio starts)
//   lowend_windows --dump-settings      print resolved settings and DSP plans
//   lowend_windows --self-test          offline checks (no audio device)
//   lowend_windows --help               usage
//
// Running the engine needs two distinct endpoints: a render endpoint to capture
// through loopback and a render endpoint to play back to. Capturing and playing
// through the same endpoint would feed the processed signal back into its own
// capture, so the default picks the default output for capture and, when only
// one output exists, reports that instead of producing a feedback loop.

#include "AudioEngine/Engine.h"
#include "AudioEngine/SelfTest.h"
#include "AudioEngine/DspStage.h"
#include "CLI/CommandLine.h"
#include "Core/Core.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
// WIN32_LEAN_AND_MEAN / NOMINMAX come from the build system so every translation
// unit agrees; redefining them here would warn.
#include <objbase.h>
#include <windows.h>
#endif

namespace {

using namespace lowend::win;

std::atomic<bool> g_stopRequested { false };

#ifdef _WIN32
BOOL WINAPI consoleHandler(DWORD signal) {
    if (signal == CTRL_C_EVENT || signal == CTRL_BREAK_EVENT || signal == CTRL_CLOSE_EVENT) {
        g_stopRequested.store(true, std::memory_order_release);
        return TRUE;
    }
    return FALSE;
}
#endif

void printResolvedSettings(const Settings& settings) {
    std::printf("DSP settings (normalized)\n");
    std::printf("  model            %s (%u)\n", dspModelName(settings.dspModel), settings.dspModel);
    std::printf("  intensity        %.2f\n", static_cast<double>(settings.intensity));
    std::printf("  body             %.2f\n", static_cast<double>(settings.body));
    std::printf("  output           %.2f dB\n", static_cast<double>(settings.outputDb));
    std::printf("  exciter-os       %s (%u)\n",
                oversamplingModeName(settings.exciterOversamplingMode),
                settings.exciterOversamplingMode);
    std::printf("  buffer-ms        %u\n", settings.bufferMs);
    std::printf("  spatial          %s\n", settings.spatialEnabled ? "on" : "off");
    std::printf("  listener         x=%.2f z=%.2f\n",
                static_cast<double>(settings.listenerX),
                static_cast<double>(settings.listenerZ));
    std::printf("  stage-width      %.2f\n", static_cast<double>(settings.speakerWidth));
    std::printf("  space            %.2f\n", static_cast<double>(settings.space));
}

// Shows that the DSP coefficients are recomputed per rate, which is the
// property Phase 3 sample-rate validation depends on. Computed with the same
// DSPPrecompute the running engine uses.
void printDspPlans(const Settings& settings) {
    const float rates[] = { 44100.0f, 48000.0f, 88200.0f, 96000.0f, 192000.0f, 768000.0f };
    std::printf("\nDSP plan per sample rate (authoritative Source/Core DSPPrecompute)\n");
    std::printf("  %-8s %-9s %-10s %-10s %-12s\n",
                "rate", "exciter", "wetMix", "hrGain", "shelfFreqHz");
    for (float rate : rates) {
        const LCDSPSettings dsp = lowend::DSPPrecompute::makeDSPSettings(
            rate, settings.intensity, settings.body, settings.outputDb,
            settings.dspModel, settings.exciterOversamplingMode);
        // The shelf corner is not stored directly; recover the intent from the
        // documented formula in Core.cpp so the dump stays meaningful when the
        // formula changes. This is a display value only.
        const float normalIntensity = settings.intensity / 100.0f;
        const float shelfFreq = 68.0f + normalIntensity * 24.0f;
        std::printf("  %-8.0f %-9u %-10.4f %-10.4f %-12.1f\n",
                    static_cast<double>(rate),
                    dsp.exciterOversampleFactor,
                    static_cast<double>(dsp.wetMix),
                    static_cast<double>(dsp.headroomGain),
                    static_cast<double>(shelfFreq));
    }

    if (settings.spatialEnabled) {
        std::printf("\nSpatial plan per sample rate (Source/Core SpatialGeometry)\n");
        std::printf("  %-8s %-10s %-10s %-10s %-10s %-8s\n",
                    "rate", "ll", "lr", "rl", "rr", "xfeed");
        for (float rate : rates) {
            const LCSpatialSettings plan = makeSpatialSettings(rate, settings);
            std::printf("  %-8.0f %-10u %-10u %-10u %-10u %-8.3f\n",
                        static_cast<double>(rate),
                        plan.ll.delaySamples, plan.lr.delaySamples,
                        plan.rl.delaySamples, plan.rr.delaySamples,
                        static_cast<double>(plan.amount));
        }
    }
}

int runListDevices() {
    std::string error;
    const std::vector<DeviceInfo> outputs = listDevices(DataFlow::render, error);
    if (!error.empty()) {
        std::fprintf(stderr, "Device enumeration failed: %s\n", error.c_str());
        return 1;
    }
    std::string captureError;
    const std::vector<DeviceInfo> inputs = listDevices(DataFlow::capture, captureError);
    if (!captureError.empty()) {
        std::fprintf(stderr, "Capture device enumeration failed: %s\n", captureError.c_str());
        return 1;
    }
    std::fputs(formatDeviceList(outputs, inputs).c_str(), stdout);
    return 0;
}

// Judgement only: resolves the selected endpoints against what the machine has
// and reports whether the pair can run, without opening a stream. This is the
// same decision the engine applies at start, taken before anything is played —
// and, unlike the engine, it can say *why* an id did not resolve, because it
// still has the requested id and both enumerated lists.
int runRouteCheck(const CommandLine& commandLine) {
    std::string error;
    const std::vector<DeviceInfo> outputs = listDevices(DataFlow::render, error);
    if (!error.empty()) {
        std::fprintf(stderr, "Device enumeration failed: %s\n", error.c_str());
        return 1;
    }
    std::string captureError;
    const std::vector<DeviceInfo> inputs = listDevices(DataFlow::capture, captureError);
    if (!captureError.empty()) {
        std::fprintf(stderr, "Capture device enumeration failed: %s\n", captureError.c_str());
        return 1;
    }

    RouteSelection selection;
    selection.captureId = commandLine.engine.captureDeviceId;
    selection.renderId = commandLine.engine.renderDeviceId;
    selection.captureFlow = commandLine.engine.captureFlow;
    selection.loopback = commandLine.engine.loopback;

    const RouteDiagnosis diagnosis = diagnoseRoute(selection, outputs, inputs);
    std::fputs(formatRouteCheck(selection, diagnosis).c_str(), stdout);
    // A refused route is a failed check, not a warning: a script that gates on
    // this must not treat "refused" as "fine".
    return diagnosis.ok() ? 0 : 1;
}

// Sends a known, unprotected tone to one named endpoint, then exits.
//
// Verification needs a signal source that is not "whatever the machine's default
// output is": the cable route is measured by playing into the cable's playback
// side, and the whole point of that route is that the OS default output *is* the
// cable. Windows' own tone players write to the default endpoint, so a
// controlled source has to name its endpoint itself.
//
// The tone does not pass through the DSP: it is the input to a route, and
// measuring a route against a processed source would prove nothing. The level is
// fixed and printed before the first sample is written, and nothing here changes
// a volume.

// Writes captured frames to a 16-bit PCM WAV file.
//
// This exists for verification, not for the audio path: a check that claims to
// have measured the pitch at the end of a route has to have had the samples, and
// a peak summary cannot answer that. 16-bit PCM is written rather than the float
// samples so any reader (including Python's own `wave` module) can open the file;
// the quantisation is far below anything a level or frequency measurement cares
// about, and nothing here feeds back into the engine.
//
// Only --monitor reaches this, and the monitor loop is the CLI's own thread, not
// a WASAPI callback, so the file I/O is not in an audio callback.
class WavDump {
public:
    ~WavDump() { close(); }

    bool open(const std::string& path, uint32_t sampleRate, std::string& error) {
        // A stream rather than std::fopen: the C runtime marks fopen deprecated
        // under /W4, and this build is kept warning-free.
        file_.open(path, std::ios::binary | std::ios::trunc);
        if (!file_) {
            error = "could not open " + path + " for writing";
            return false;
        }
        sampleRate_ = sampleRate == 0 ? 48000u : sampleRate;
        // The header carries sizes that are only known at the end, so a
        // placeholder is written now and patched in close().
        writeHeader(0);
        return true;
    }

    void write(const float* left, const float* right, uint32_t frames) {
        if (!file_) {
            return;
        }
        for (uint32_t i = 0; i < frames; ++i) {
            writeSample(left[i]);
            writeSample(right[i]);
        }
        frames_ += frames;
    }

    void close() {
        if (!file_) {
            return;
        }
        file_.flush();
        file_.seekp(0);
        writeHeader(frames_);
        file_.close();
    }

    uint64_t frames() const { return frames_; }

private:
    static int16_t toPcm(float sample) {
        // Clamped before scaling: a full-scale sample times 32767 is inside the
        // range, but a sample above 1.0 (which the DSP can produce before its
        // output gain) would wrap to the opposite sign and turn a peak into a
        // click in the dump.
        if (sample > 1.0f) sample = 1.0f;
        if (sample < -1.0f) sample = -1.0f;
        return static_cast<int16_t>(sample * 32767.0f);
    }

    void writeSample(float sample) {
        const int16_t value = toPcm(sample);
        const char bytes[2] = {
            static_cast<char>(value & 0xff),
            static_cast<char>((value >> 8) & 0xff),
        };
        file_.write(bytes, sizeof(bytes));
    }

    void writeHeader(uint64_t frames) {
        const uint64_t dataBytes = frames * 2u * 2u;  // stereo, 16-bit
        // A canonical WAV header has 32-bit sizes. The --monitor window is capped
        // at 600 s, which even at 768 kHz stays under 4 GB, so the cast cannot
        // lose a size this command can produce.
        const uint32_t data32 = static_cast<uint32_t>(dataBytes);
        const uint32_t byteRate = sampleRate_ * 2u * 2u;
        unsigned char header[44] = {};
        const auto put32 = [&](int offset, uint32_t value) {
            header[offset] = static_cast<unsigned char>(value & 0xff);
            header[offset + 1] = static_cast<unsigned char>((value >> 8) & 0xff);
            header[offset + 2] = static_cast<unsigned char>((value >> 16) & 0xff);
            header[offset + 3] = static_cast<unsigned char>((value >> 24) & 0xff);
        };
        const auto put16 = [&](int offset, uint16_t value) {
            header[offset] = static_cast<unsigned char>(value & 0xff);
            header[offset + 1] = static_cast<unsigned char>((value >> 8) & 0xff);
        };
        std::memcpy(header, "RIFF", 4);
        put32(4, 36u + data32);
        std::memcpy(header + 8, "WAVEfmt ", 8);
        put32(16, 16u);                                   // fmt chunk size
        put16(20, 1u);                                    // PCM
        put16(22, 2u);                                    // channels
        put32(24, sampleRate_);
        put32(28, byteRate);
        put16(32, 4u);                                    // block align
        put16(34, 16u);                                   // bits per sample
        std::memcpy(header + 36, "data", 4);
        put32(40, data32);
        file_.write(reinterpret_cast<const char*>(header), sizeof(header));
    }

    std::ofstream file_;
    uint32_t sampleRate_ = 48000;
    uint64_t frames_ = 0;
};

int runPlayTone(const CommandLine& commandLine) {
    WasapiRender::Options options;
    options.deviceId = commandLine.engine.renderDeviceId;
    options.bufferMs = commandLine.settings.bufferMs;
    // 0 means "the endpoint's own mix rate": the tone is generated at the rate
    // the endpoint consumes, so no conversion sits inside the source.
    options.requestedSampleRate = 0;

    WasapiRender render;
    std::string error;
    if (!render.open(options, error)) {
        std::fprintf(stderr, "Failed to open the tone endpoint: %s\n", error.c_str());
        return 1;
    }

    const WasapiFormat format = render.format();
    if (format.sampleRate == 0 || format.channels == 0) {
        std::fprintf(stderr, "The tone endpoint reported no usable format.\n");
        render.close();
        return 1;
    }

    // Printed before anything is written, and flushed: the user has to be able to
    // see what will make a sound, through which endpoint, and at what level.
    std::printf("Playing a %.1f Hz stereo tone at amplitude %.2f for %d s\n",
                toneFrequencyHz, toneAmplitude, commandLine.toneSeconds);
    std::printf("  endpoint: %s\n",
                render.openedDeviceName().empty() ? "(unnamed)"
                                                  : render.openedDeviceName().c_str());
    std::printf("  id:       %s\n", render.openedDeviceId().c_str());
    std::printf("  format:   %u Hz, %u ch, %u-frame period%s\n",
                format.sampleRate, format.channels, render.bufferFrames(),
                commandLine.engine.renderDeviceId.empty() ? " (default output)" : "");
    std::fflush(stdout);

    const uint32_t block = render.bufferFrames() == 0 ? 512u
        : (render.bufferFrames() > maxBlockFrames ? maxBlockFrames : render.bufferFrames());
    std::vector<float> left(block);
    std::vector<float> right(block);

    const double totalFrames =
        static_cast<double>(commandLine.toneSeconds) * static_cast<double>(format.sampleRate);
    uint64_t written = 0;
    double peak = 0.0;
    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(commandLine.toneSeconds);

    while (written < static_cast<uint64_t>(totalFrames)
           && std::chrono::steady_clock::now() < deadline) {
        uint32_t frames = block;
        if (written + frames > static_cast<uint64_t>(totalFrames)) {
            frames = static_cast<uint32_t>(static_cast<uint64_t>(totalFrames) - written);
        }
        for (uint32_t i = 0; i < frames; ++i) {
            // Phase continues across blocks so the tone has no discontinuity at
            // a block boundary, which a peak measurement would not notice but a
            // listener or a spectrum would.
            const double phase = 2.0 * 3.14159265358979323846 * toneFrequencyHz
                * static_cast<double>(written + i) / static_cast<double>(format.sampleRate);
            const float sample = static_cast<float>(toneAmplitude * std::sin(phase));
            left[i] = sample;
            right[i] = sample;
            // Measured from the samples that were actually generated rather than
            // reported from the constant: the number a verification run compares
            // against has to be what left this process.
            const double magnitude = std::fabs(static_cast<double>(sample));
            if (magnitude > peak) {
                peak = magnitude;
            }
        }
        if (!render.write(left.data(), right.data(), frames, &error)) {
            std::fprintf(stderr, "The tone endpoint stopped accepting audio: %s\n", error.c_str());
            render.close();
            return 1;
        }
        written += frames;
    }

    // Leave the endpoint's buffer filled rather than draining: a render endpoint
    // that runs dry while still open is what produces a click at the end.
    render.writeSilence(render.bufferFrames(), &error);
    render.close();

    const double seconds = static_cast<double>(written) / static_cast<double>(format.sampleRate);
    std::printf("  wrote:    %llu frames (%.2f s), peak %.6f, both channels\n",
                static_cast<unsigned long long>(written), seconds, peak);
    return 0;
}

int runEngine(const CommandLine& commandLine) {
    EngineOptions options = commandLine.engine;
    const Settings& settings = commandLine.settings;
    const bool verbose = commandLine.verbose;

    printResolvedSettings(settings);

    Engine engine(options);
    std::string error;
    if (!engine.start(settings, error)) {
        std::fprintf(stderr, "Failed to start audio processing: %s\n", error.c_str());
        return 1;
    }

    const EngineStats initial = engine.stats();
    std::printf("\n%s\n", describeRoute(initial, options).c_str());
    std::printf("LowEnd Windows audio processing is running. Press Ctrl-C to stop.\n");
    std::fflush(stdout);

#ifdef _WIN32
    SetConsoleCtrlHandler(consoleHandler, TRUE);
#endif

    // --verbose reports progress while the engine runs. The interval is a
    // reporting cadence only: the audio threads never touch this path, and the
    // counters read here are the lock-free snapshots the ring already publishes.
    if (verbose) {
        std::printf("\n%-10s %-14s %-12s %-10s %-9s %s\n",
                    "elapsed", "frames", "dropped", "underrun", "recovered", "buffered");
    }
    auto started = std::chrono::steady_clock::now();
    auto lastReport = started;

    while (!g_stopRequested.load(std::memory_order_acquire) && engine.isRunning()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        if (!verbose) {
            continue;
        }
        const auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastReport).count() < 2000) {
            continue;
        }
        lastReport = now;
        const EngineStats live = engine.stats();
        std::printf("%-10.1f %-14llu %-12llu %-10llu %-9u %u\n",
                    std::chrono::duration<double>(now - started).count(),
                    static_cast<unsigned long long>(live.totalReadSamples / 2),
                    static_cast<unsigned long long>(live.droppedSamples),
                    static_cast<unsigned long long>(live.underrunSamples),
                    live.recoveredStreams,
                    live.ringAvailableSamples);
        std::fflush(stdout);
    }

    if (verbose) {
        std::printf("\n");
    }
    std::printf("Stopping...\n");
    engine.stop();

    const EngineStats finalStats = engine.stats();
    std::printf("Capture errors   %u\n", finalStats.captureErrors);
    std::printf("Render errors    %u\n", finalStats.renderErrors);
    std::printf("Resyncs          %u\n", finalStats.resyncCount);
    std::printf("Dropped samples  %llu\n", static_cast<unsigned long long>(finalStats.droppedSamples));
    std::printf("Underrun samples %llu\n", static_cast<unsigned long long>(finalStats.underrunSamples));
    std::printf("Processed frames %llu\n",
                static_cast<unsigned long long>(finalStats.totalReadSamples / 2));

    // Device recovery is reported separately from plain errors: an endpoint that
    // came back is a different outcome from one that ended the stream.
    if (finalStats.deviceReopenAttempts != 0 || finalStats.recoveredStreams != 0) {
        std::printf("Reopen attempts  %u\n", finalStats.deviceReopenAttempts);
        std::printf("Recovered        %u\n", finalStats.recoveredStreams);
    }
    if (finalStats.givingUp) {
        std::fprintf(stderr,
                     "Audio processing stopped: the device failed in a way that cannot be"
                     " recovered by reopening it.\n");
    }

    // Report the accumulated shortfall as time so a nonzero counter is
    // interpretable: a few milliseconds is clock drift between two independent
    // devices, while a growing value means the capture side is not keeping up.
    if (finalStats.underrunSamples != 0 && finalStats.renderSampleRate != 0) {
        const double underrunMs = static_cast<double>(finalStats.underrunSamples) / 2.0
            / static_cast<double>(finalStats.renderSampleRate) * 1000.0;
        std::printf("Underrun time    %.1f ms\n", underrunMs);
    }

    if (finalStats.captureErrors != 0 || finalStats.renderErrors != 0) {
        std::fprintf(stderr, "Audio processing ended with device errors.\n");
        return 1;
    }
    return 0;
}

// Capture-only diagnostic. Answers "is this endpoint actually delivering audio,
// and does the DSP chain move real samples?" without opening a render endpoint,
// which matters when the captured endpoint is the machine's only output.
//
// The DSP still runs on every captured block, so this exercises the same
// processing path the live engine uses; only the final device write is absent.
int runMonitor(const CommandLine& commandLine) {
    WasapiCapture::Options options;
    options.deviceId = commandLine.engine.captureDeviceId;
    options.flow = commandLine.engine.captureFlow;
    // A render endpoint can only be captured through loopback, and a capture
    // endpoint cannot use the flag at all.
    options.loopback = commandLine.engine.captureFlow == DataFlow::render
        || commandLine.engine.loopback;
    options.bufferMs = commandLine.settings.bufferMs;

    WasapiCapture capture;
    std::string error;
    if (!capture.open(options, error)) {
        std::fprintf(stderr, "Failed to open the capture endpoint: %s\n", error.c_str());
        return 1;
    }

    const WasapiFormat format = capture.format();
    std::printf("Monitoring %s \"%s\" for %d s\n",
                capture.isLoopback() ? "loopback of" : "input",
                capture.openedDeviceName().empty() ? "(unnamed)" : capture.openedDeviceName().c_str(),
                commandLine.monitorSeconds);
    std::printf("  negotiated: %u Hz, %u ch, %u-bit, %u-frame period\n",
                format.sampleRate, format.channels, format.bitsPerSample,
                capture.bufferFrames());
    // Flushed because this runs for seconds: on a redirected pipe a buffered
    // header would only appear when the process exits, leaving a hang with no
    // visible progress at all.
    std::fflush(stdout);

    DspStage stage;
    if (!stage.prepare(format.sampleRate, 2, error)) {
        std::fprintf(stderr, "Failed to prepare the DSP stage: %s\n", error.c_str());
        capture.close();
        return 1;
    }
    if (!stage.applySettings(commandLine.settings)) {
        std::fprintf(stderr, "Failed to queue the DSP settings.\n");
        capture.close();
        return 1;
    }

    // Local scratch, sized once. The capture client already bounds a packet to
    // maxBlockFrames, and DspStage splits anything larger.
    std::vector<float> left(maxBlockFrames);
    std::vector<float> right(maxBlockFrames);

    // Optional capture dump, opened after the endpoint so the file's format is
    // the negotiated one. A dump that cannot be opened fails the command: a
    // verification run that silently produced no file would be worse than one
    // that stopped.
    WavDump dump;
    if (!commandLine.monitorDumpPath.empty()) {
        if (!dump.open(commandLine.monitorDumpPath, format.sampleRate, error)) {
            std::fprintf(stderr, "Failed to open the capture dump: %s\n", error.c_str());
            capture.close();
            return 1;
        }
        std::printf("  dump:      %s (16-bit PCM, written after the run)\n",
                    commandLine.monitorDumpPath.c_str());
    }

    uint64_t frames = 0;
    uint64_t silentPackets = 0;
    uint64_t packets = 0;
    uint64_t discontinuities = 0;
    // Measured per channel: a stereo stream can carry signal in one channel
    // only, and a single combined figure cannot tell that apart from silence.
    double peakLeft = 0.0;
    double peakRight = 0.0;
    double energy = 0.0;
    uint64_t energySamples = 0;

    // Measured after the DSP, so the report can show the processing applied to
    // real captured audio. Kept separate from the input figures: comparing the
    // two is what distinguishes "the core is in the path" from "audio arrived".
    double outputPeakLeft = 0.0;
    double outputPeakRight = 0.0;
    double outputEnergy = 0.0;
    uint64_t outputSamples = 0;
    // The wider of the two channels, for the "is anything playing at all" test
    // and the gain comparison.
    double peak = 0.0;
    double outputPeak = 0.0;

    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::seconds(commandLine.monitorSeconds);
    const auto started = std::chrono::steady_clock::now();

    // acquire() blocks until the endpoint produces a packet, and an idle
    // endpoint can go a long time without producing one — a loopback capture of
    // an output that is playing nothing is silence, not a steady packet stream.
    // A bounded observation therefore cannot rely on acquire() returning on its
    // own: this watchdog closes the endpoint at the deadline, which is the
    // documented way to wake a parked acquire().
    std::atomic<bool> finished { false };
    std::thread watchdog([&capture, &deadline, &finished] {
        while (!finished.load(std::memory_order_acquire)) {
            if (std::chrono::steady_clock::now() >= deadline) {
                capture.close();
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    });

    double lastReported = 0.0;
    for (;;) {
        if (std::chrono::steady_clock::now() >= deadline) {
            break;
        }
        if (!capture.acquire(&error)) {
            // Either the watchdog closed the endpoint at the deadline, or the
            // device failed. Both end the observation; the watchdog path is
            // recognised by having reached the deadline.
            if (std::chrono::steady_clock::now() < deadline) {
                std::fprintf(stderr, "Capture stopped early: %s\n", error.c_str());
                finished.store(true, std::memory_order_release);
                watchdog.join();
                capture.close();
                return 1;
            }
            break;
        }

        // One line per observed second, so a run that stalls while waiting for
        // packets is visible instead of looking like a hung process.
        const double elapsed =
            std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        if (elapsed - lastReported >= 1.0) {
            lastReported = elapsed;
            std::printf("  %4.1f s  packets %llu  frames %llu  peak %.6f\n",
                        elapsed,
                        static_cast<unsigned long long>(packets),
                        static_cast<unsigned long long>(frames),
                        peak);
            std::fflush(stdout);
        }

        const uint32_t count = capture.frameCount();
        const float* sourceLeft = capture.left();
        const float* sourceRight = capture.right();
        const bool discontinuity = capture.isDiscontinuity();
        capture.release();

        if (count == 0 || sourceLeft == nullptr || sourceRight == nullptr) {
            continue;
        }

        ++packets;
        if (discontinuity) {
            ++discontinuities;
            // A repositioned stream no longer continues the previous one, so the
            // filter state starts clean rather than bridging the gap.
            stage.resetForDiscontinuity();
        }

        bool packetSilent = true;
        for (uint32_t i = 0; i < count; ++i) {
            left[i] = sourceLeft[i];
            right[i] = sourceRight[i];
            // Both channels are measured. Reading only the left one made a
            // right-channel-only signal look like pure silence, and the report
            // then told the user the endpoint produced no audio at all — a false
            // statement about a stream that was carrying signal.
            const double leftMagnitude = std::fabs(static_cast<double>(sourceLeft[i]));
            const double rightMagnitude = std::fabs(static_cast<double>(sourceRight[i]));
            if (leftMagnitude > peakLeft) peakLeft = leftMagnitude;
            if (rightMagnitude > peakRight) peakRight = rightMagnitude;
            if (leftMagnitude > 1.0e-6 || rightMagnitude > 1.0e-6) packetSilent = false;
            energy += leftMagnitude * leftMagnitude + rightMagnitude * rightMagnitude;
        }
        energySamples += count * 2u;
        if (packetSilent) ++silentPackets;
        frames += count;
        // The captured samples, before the DSP: this is what the endpoint at the
        // far end of a route delivered, which is what a verification run measures.
        dump.write(left.data(), right.data(), count);

        stage.processBlock(left.data(), right.data(), count);

        // Measured after the DSP, not before: this is what lets the report show
        // the processing actually happening to real captured audio. Input-only
        // levels would prove the endpoint delivers audio but say nothing about
        // whether the core is in the path.
        for (uint32_t i = 0; i < count; ++i) {
            const double outLeftMagnitude = std::fabs(static_cast<double>(left[i]));
            const double outRightMagnitude = std::fabs(static_cast<double>(right[i]));
            if (outLeftMagnitude > outputPeakLeft) outputPeakLeft = outLeftMagnitude;
            if (outRightMagnitude > outputPeakRight) outputPeakRight = outRightMagnitude;
            outputEnergy += outLeftMagnitude * outLeftMagnitude
                          + outRightMagnitude * outRightMagnitude;
            outputSamples += 2u;
        }
    }

    // The loop left because the deadline passed or the endpoint closed; either
    // way the watchdog is done, and close() is idempotent.
    finished.store(true, std::memory_order_release);
    watchdog.join();
    capture.close();
    // Closed before the report so the file is complete when the summary names it.
    dump.close();

    const double seconds = static_cast<double>(frames) / (format.sampleRate == 0 ? 1 : format.sampleRate);
    const double rms = energySamples == 0 ? 0.0 : std::sqrt(energy / static_cast<double>(energySamples));
    const double outputRms =
        outputSamples == 0 ? 0.0 : std::sqrt(outputEnergy / static_cast<double>(outputSamples));
    // The combined peak is the wider channel: it is what answers "is anything
    // playing at all", which a per-channel figure cannot decide on its own.
    peak = std::max(peakLeft, peakRight);
    outputPeak = std::max(outputPeakLeft, outputPeakRight);
    const bool rightSilent = peakLeft > 1.0e-6 && peakRight <= 1.0e-6;
    const bool leftSilent = peakRight > 1.0e-6 && peakLeft <= 1.0e-6;

    std::printf("  packets:       %llu (%llu silent, %llu discontinuous)\n",
                static_cast<unsigned long long>(packets),
                static_cast<unsigned long long>(silentPackets),
                static_cast<unsigned long long>(discontinuities));
    std::printf("  frames:        %llu (%.2f s)\n",
                static_cast<unsigned long long>(frames), seconds);
    std::printf("  input peak:    %.6f  (L %.6f, R %.6f)\n", peak, peakLeft, peakRight);
    std::printf("  input RMS:     %.6f\n", rms);
    std::printf("  output peak:   %.6f  (L %.6f, R %.6f)\n",
                outputPeak, outputPeakLeft, outputPeakRight);
    std::printf("  output RMS:    %.6f\n", outputRms);
    std::printf("  DSP:           %s, %u applied revision(s)\n",
                dspModelName(stage.activeModel()),
                static_cast<unsigned>(stage.appliedRevision()));
    if (!commandLine.monitorDumpPath.empty()) {
        std::printf("  dump:          %s (%llu frames written)\n",
                    commandLine.monitorDumpPath.c_str(),
                    static_cast<unsigned long long>(dump.frames()));
    }

    if (packets != 0 && peak > 1.0e-9) {
        // Both numbers come from the same captured audio, so their difference is
        // the DSP's contribution rather than a difference between two runs.
        const double gain = outputRms / rms;
        std::printf("  DSP gain:      %.2fx (%+.1f dB) relative to input\n",
                    gain, 20.0 * std::log10(gain > 0.0 ? gain : 1.0e-12));
    }

    if (packets == 0) {
        std::fprintf(stderr, "The endpoint delivered no packets; it is not providing audio.\n");
        return 1;
    }
    if (rightSilent || leftSilent) {
        // Not silence, but not a normal stereo stream either: saying "pure
        // silence" here would be false, and staying quiet about it would hide a
        // channel that is not being delivered.
        std::printf("\nOne channel carried no signal for the whole window (%s). The other\n"
                    "channel did, so the endpoint is delivering audio; a mono source, a\n"
                    "mono endpoint, or a source panned to one side all look like this.\n",
                    rightSilent ? "right" : "left");
    } else if (peak == 0.0) {
        // A real observation, not a failure: a loopback endpoint with nothing
        // playing legitimately produces silence. Say so rather than implying a
        // broken route.
        std::printf("\nThe endpoint produced pure silence for the whole window. For a loopback\n"
                    "capture that means nothing was playing on it; for an input endpoint it\n"
                    "means the device delivered no signal.\n");
    }
    return 0;
}

} // namespace

int main(int argc, char** argv) {
#ifdef _WIN32
    // COM must be initialized per thread. The CLI opens devices on this thread
    // and the engine's own threads initialize their own apartment, so the MTA
    // here only covers enumeration and device setup done before start().
    // RPC_E_CHANGED_MODE means another component already chose an apartment;
    // that is not a failure for our use.
    const HRESULT comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
#endif

    const CommandLine commandLine = parseCommandLine(argc, argv);
    const Settings settings = normalized(commandLine.settings);
    CommandLine resolved = commandLine;
    resolved.settings = settings;

    // Releases the COM apartment only when this thread initialized it, so an
    // outer owner that already initialized COM is left untouched.
    const auto finish = [comResult](int code) {
#ifdef _WIN32
        if (SUCCEEDED(comResult)) {
            CoUninitialize();
        }
#endif
        return code;
    };

    if (!commandLine.rejectionReasons.empty()) {
        for (const std::string& reason : commandLine.rejectionReasons) {
            std::fprintf(stderr, "%s\n", reason.c_str());
        }
        std::fputs(usageText().c_str(), stderr);
        return finish(1);
    }

    switch (commandLine.command) {
        case Command::help:
            std::fputs(usageText().c_str(), stdout);
            return finish(0);
        case Command::listDevices:
            return finish(runListDevices());
        case Command::dumpSettings:
            printResolvedSettings(settings);
            printDspPlans(settings);
            return finish(0);
        case Command::selfTest:
            return finish(runSelfTest() == 0 ? 0 : 1);
        case Command::routeCheck:
            return finish(runRouteCheck(resolved));
        case Command::playTone:
            return finish(runPlayTone(resolved));
        case Command::monitor:
            return finish(runMonitor(resolved));
        case Command::run:
            break;
    }
    return finish(runEngine(resolved));
}
