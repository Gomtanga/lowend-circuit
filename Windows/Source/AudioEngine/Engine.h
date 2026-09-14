// Engine.h — capture → DSP → render pipeline.
//
// The engine owns two device-driven threads (WASAPI capture and render) joined
// by the shared SPSC ring from AudioRingBufferC.c. DSP runs on the render
// thread, which pops the ring and calls lowend::Processor.
//
// Threading contract:
//   - start()/stop()/requestReconfigure() are control-thread operations.
//   - run/processOnce are the only audio-thread entry points.
//   - Settings are exchanged through a lock-free control event queue; the
//     audio thread never allocates, locks, logs, or computes coefficients.

#pragma once

#include "AudioEngine/Devices.h"
#include "AudioEngine/Settings.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace lowend::win {

struct EngineOptions {
    // Capture side. Flow::render + loopback captures the endpoint's own output
    // (system audio). Flow::capture records a real input device.
    DataFlow captureFlow = DataFlow::render;
    bool loopback = true;
    std::string captureDeviceId;  // empty = default endpoint of that flow

    // Render side. Always an output endpoint.
    std::string renderDeviceId;   // empty = default output endpoint

    uint32_t bufferMs = 20;
};

// A point-in-time view of the running engine, safe to read from any thread.
struct EngineStats {
    uint32_t captureSampleRate = 0;
    uint32_t renderSampleRate = 0;
    uint32_t captureBufferFrames = 0;
    uint32_t renderBufferFrames = 0;
    double renderPeriodMs = 0.0;
    uint32_t renderChannels = 0;

    // Latency the audio engine reports for each stream, in milliseconds. This is
    // what WASAPI's GetStreamLatency() returns — the delay through the audio
    // engine and the endpoint — not the total path latency a listener observes.
    // The engine's own ring buffer and DSP add to it, so it is a floor, not a
    // measurement of the whole route.
    double captureStreamLatencyMs = 0.0;
    double renderStreamLatencyMs = 0.0;

    // Ring diagnostics from AudioRingBufferC.c.
    uint64_t droppedSamples = 0;   // capture overrun: DSP thread fell behind
    uint64_t underrunSamples = 0;  // render starvation: capture fell behind
    uint64_t totalWrittenSamples = 0;
    uint64_t totalReadSamples = 0;
    uint32_t ringCapacitySamples = 0;
    uint32_t ringAvailableSamples = 0;

    // Non-zero when the engine is in a degraded state.
    uint32_t captureErrors = 0;
    uint32_t renderErrors = 0;
    uint32_t resyncCount = 0;      // capture restarts after device loss/discontinuity
    uint32_t processCallbacks = 0;

    // Device-failure recovery. A recoverable failure reopens the endpoint and
    // keeps the stream alive; `deviceReopenAttempts` counts the tries and
    // `recoveredStreams` the ones that succeeded. `givingUp` is set when a
    // failure was classified as unrecoverable, or when the bounded retry budget
    // for a lost device ran out — the engine then stops rather than retrying
    // forever.
    uint32_t deviceReopenAttempts = 0;
    uint32_t recoveredStreams = 0;
    bool givingUp = false;

    bool running = false;
    bool captureIsLoopback = false;
    uint32_t activeDSPModel = 2;   // placeholder; overwritten in Engine.cpp
    bool usingSharedMode = true;
};

class Engine {
public:
    explicit Engine(EngineOptions options);
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    // Control thread. Applies normalized settings before the first block.
    bool start(const Settings& settings, std::string& error);
    // Control thread. Idempotent; safe with no running threads.
    void stop();

    // Control thread. Queues a settings snapshot for the audio thread. Returns
    // false when the queue is full; the previous settings stay in effect.
    bool requestSettings(const Settings& settings);

    // Any thread.
    EngineStats stats() const;
    bool isRunning() const { return running_.load(std::memory_order_acquire); }

    // Audio-thread entry point. Exposed so offline checks can drive the exact
    // production path without a device: the render thread calls exactly this to
    // run one block through the DSP stage. Not safe to call while running.
    void processBlock(const float* left, const float* right, uint32_t frames);

private:
    void runCapture();
    void runRender();

    struct Impl;
    Impl* impl_;

    std::atomic<bool> running_ { false };
    std::thread captureThread_;
    std::thread renderThread_;
};

// Human-readable one-line summary of the negotiated route.
std::string describeRoute(const EngineStats& stats, const EngineOptions& options);

} // namespace lowend::win