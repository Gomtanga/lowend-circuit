// Engine.cpp — the live capture → DSP → render pipeline.
//
// Two device-driven threads joined by the lock-free ring from
// AudioRingBufferC.c:
//   capture thread   WasapiCapture::acquire() → interleave → ring push
//   render thread    ring pop → DspStage::processBlock() → WasapiRender::write()
//
// Ownership rules that decide the shape below:
//   - DspStage (and therefore lowend::Processor) is owned by the render thread.
//     The capture thread never calls into it, not even to reset it after a
//     discontinuity: it records the break through the ring's discard request
//     and the render thread resets the state when it consumes that request.
//   - The ring is single-producer/single-consumer, which is exactly the pair of
//     threads above; nothing else touches it while they run.
//   - Both device threads are audio threads: no allocation, no locks, no
//     logging. Every buffer they need is allocated before they start.

#include "AudioEngine/Engine.h"

#include "AudioEngine/DspStage.h"
#include "AudioEngine/RecoveryPolicy.h"
#include "AudioEngine/RouteDiagnosis.h"

#include <windows.h>
#include <objbase.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace lowend::win {
namespace {

// Write size used when the render endpoint reports no usable period. The value
// only has to be a sane cadence: the DSP scratch is bounded by maxBlockFrames
// either way.
constexpr uint32_t defaultRenderBlockFrames = 512;

// Fallback shared-mode period when neither the settings nor the engine options
// carry one. WASAPI accepts 0 as "device default", but the CLI always has a
// concrete number and reporting it back is more useful than reporting 0.
constexpr uint32_t defaultBufferMs = 20;

} // namespace

struct Engine::Impl {
    explicit Impl(EngineOptions engineOptions)
        : dsp(std::make_unique<DspStage>()),
          options(std::move(engineOptions)),
          captureInterleaved(maxBlockFrames * 2),
          renderLeft(maxBlockFrames),
          renderRight(maxBlockFrames) {}

    WasapiCapture capture;
    WasapiRender render;
    LCLockFreeRingBuffer* ring = nullptr;
    std::unique_ptr<DspStage> dsp;
    EngineOptions options;

    // The options each client was opened with, kept so a lost endpoint can be
    // reopened with the same request. Filled by start() before the threads run.
    WasapiCapture::Options captureOptions;
    WasapiRender::Options renderOptions;

    // Device-failure recovery state. `givingUp` records that a failure was
    // classified unrecoverable or that the retry budget ran out, so a caller can
    // tell a deliberate stop from a stream that ended because the device died.
    std::atomic<uint32_t> deviceReopenAttempts { 0 };
    std::atomic<uint32_t> recoveredStreams { 0 };
    std::atomic<bool> givingUp { false };

    // Set by the control thread before the threads are woken, and by stop() to
    // ask both loops to leave. The loops poll it instead of blocking on a
    // condvar: an audio thread may not take a lock.
    std::atomic<bool> stopping { false };

    std::atomic<uint32_t> captureErrors { 0 };
    std::atomic<uint32_t> renderErrors { 0 };
    // Hash of the endpoint each side currently holds, 0 when it holds none. The
    // two sides are owned by different audio threads, so a hash is published
    // here rather than the id being read across threads: `openedDeviceId()`
    // returns a reference into a string the owning thread rewrites on every
    // open and close. See endpointsCollide() in RecoveryPolicy.h.
    std::atomic<uint64_t> captureEndpointHash { 0 };
    std::atomic<uint64_t> renderEndpointHash { 0 };
    // Key of the virtual pass-through device each side belongs to, 0 when the side
    // is not one side of such a device. Kept next to the endpoint hashes because
    // it answers the other half of the same question: a virtual cable's two sides
    // are *different* endpoint ids on one signal path, so comparing ids alone
    // would call that route safe and let the engine process its own output.
    std::atomic<uint64_t> capturePassThroughKey { 0 };
    std::atomic<uint64_t> renderPassThroughKey { 0 };
    std::atomic<uint32_t> resyncCount { 0 };
    std::atomic<uint32_t> processCallbacks { 0 };

    // Ring diagnostics captured by stop() just before the ring is destroyed.
    // A caller reads stats() after stop() returns, so these have to outlive the
    // ring; `haveFinalRingStats` says they are valid and should be preferred.
    std::atomic<bool> haveFinalRingStats { false };
    std::atomic<uint64_t> finalDroppedSamples { 0 };
    std::atomic<uint64_t> finalUnderrunSamples { 0 };
    std::atomic<uint64_t> finalTotalWritten { 0 };
    std::atomic<uint64_t> finalTotalRead { 0 };
    std::atomic<uint32_t> finalRingCapacity { 0 };

    // The negotiated route, published by start() on the control thread so
    // stats() can report it from any thread without calling into the device
    // objects (which are control-thread-only surfaces).
    std::atomic<uint32_t> captureSampleRate { 0 };
    std::atomic<uint32_t> renderSampleRate { 0 };
    std::atomic<uint32_t> captureBufferFrames { 0 };
    std::atomic<uint32_t> renderBufferFrames { 0 };
    std::atomic<uint32_t> renderChannels { 0 };
    std::atomic<double> renderPeriodMs { 0.0 };
    std::atomic<double> captureStreamLatencyMs { 0.0 };
    std::atomic<double> renderStreamLatencyMs { 0.0 };
    std::atomic<bool> captureIsLoopback { false };

    // Render-thread write size. Written by start() before the thread exists.
    uint32_t renderBlockFrames = defaultRenderBlockFrames;

    // Scratch, sized once in the constructor. `captureInterleaved` is the
    // capture thread's interleave buffer (the ring is fed interleaved, and only
    // the consumer side deinterleaves); the render pair is what the render
    // thread pops into and hands to the DSP stage. The same pair also backs the
    // offline entry points, which cannot run concurrently with the render
    // thread by construction.
    std::vector<float> captureInterleaved;
    std::vector<float> renderLeft;
    std::vector<float> renderRight;
};

Engine::Engine(EngineOptions options)
    : impl_(new Impl(std::move(options))) {}

Engine::~Engine() {
    stop();
    delete impl_;
}

bool Engine::start(const Settings& settings, std::string& error) {
    error.clear();
    Impl& impl = *impl_;

    if (running_.load(std::memory_order_acquire)) {
        error = "the engine is already running";
        return false;
    }

    // Settings document the shared-mode period both clients are opened with;
    // EngineOptions.bufferMs is the CLI-level default for a caller that never
    // filled the settings in.
    uint32_t bufferMs = settings.bufferMs;
    if (bufferMs == 0) {
        bufferMs = impl.options.bufferMs;
    }
    if (bufferMs == 0) {
        bufferMs = defaultBufferMs;
    }


    WasapiCapture::Options captureOptions;
    captureOptions.deviceId = impl.options.captureDeviceId;
    captureOptions.flow = impl.options.captureFlow;
    // Capturing a render endpoint is only legal through loopback: without the
    // flag GetService(IAudioCaptureClient) fails with
    // AUDCLNT_E_WRONG_ENDPOINT_TYPE. So the two are not independent — a
    // render-flow capture is a loopback by definition. The CLI already maps
    // --loopback off onto DataFlow::capture, so forcing the flag here cannot
    // override a request to record a real input; it only keeps a render flow
    // from being opened in a combination WASAPI does not support.
    captureOptions.loopback = impl.options.captureFlow == DataFlow::render || impl.options.loopback;
    captureOptions.bufferMs = bufferMs;

    // The capture side is opened first because it sets the rate the DSP runs at.
    if (!impl.capture.open(captureOptions, error)) {
        return false;
    }
    // Kept for the recovery path: a lost endpoint is reopened with the request
    // that worked, not with a fresh default.
    impl.captureOptions = captureOptions;

    const WasapiFormat captureFormat = impl.capture.format();
    if (captureFormat.sampleRate == 0) {
        error = "the capture endpoint reported no usable sample rate";
        impl.capture.close();
        return false;
    }

    WasapiRender::Options renderOptions;
    renderOptions.deviceId = impl.options.renderDeviceId;
    renderOptions.bufferMs = bufferMs;
    // Ask the render stream for the capture rate instead of accepting the
    // render endpoint's mix rate. When they differ, the audio engine inserts a
    // channel matrixer and a sample rate converter between our stream and the
    // mix format (AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, plus SRC_DEFAULT_QUALITY
    // because this audio is meant to be heard). That keeps the DSP running at
    // exactly the rate the capture device produced, so no pitch shift can be
    // introduced by feeding one rate's samples into another rate's client —
    // which is what a plain format mismatch would cause. The DSP still runs at
    // the capture rate end to end; only the final handoff to the endpoint is
    // converted, by Microsoft's documented converter.
    renderOptions.requestedSampleRate = captureFormat.sampleRate;

    if (!impl.render.open(renderOptions, error)) {
        impl.capture.close();
        return false;
    }
    impl.renderOptions = renderOptions;

    const WasapiFormat renderFormat = impl.render.format();

    // Capture and render must be different endpoints. WASAPI loopback copies
    // the output stream into the capture buffer *in addition to* sending it to
    // the render pin, so it does not replace the original audio. Playing the
    // processed result back to the endpoint being captured therefore feeds the
    // engine's own output into its own capture: a closed loop with nothing in
    // WASAPI to break it, which grows without bound instead of settling.
    //
    // This compares the endpoints open() actually resolved, not the requested
    // ids. An empty request means "the default endpoint", and the default
    // output used for both loopback capture and render resolves to the same
    // endpoint — a self-loop that a comparison of the requested strings would
    // see as two different requests. Both opens have succeeded here and no
    // thread or ring exists yet, so reporting the failure costs nothing to undo.
    const std::string& captureEndpoint = impl.capture.openedDeviceId();
    const std::string& renderEndpoint = impl.render.openedDeviceId();
    // Published before the audio threads start, so a reopen on either side can
    // compare against the other endpoint through atomics rather than reading a
    // string the other thread owns.
    impl.captureEndpointHash.store(endpointHash(captureEndpoint), std::memory_order_release);
    impl.renderEndpointHash.store(endpointHash(renderEndpoint), std::memory_order_release);
    impl.capturePassThroughKey.store(virtualPassThroughKey(impl.capture.openedIdentity()),
                                     std::memory_order_release);
    impl.renderPassThroughKey.store(virtualPassThroughKey(impl.render.openedIdentity()),
                                    std::memory_order_release);
    if (!captureEndpoint.empty() && captureEndpoint == renderEndpoint) {
        error = "capture and render resolved to the same endpoint ("
            + impl.render.openedDeviceName()
            + "); loopback copies the output stream instead of replacing it, so the processed"
              " result would be captured again as input. Pass --device with a different output"
              " endpoint to break the loop.";
        impl.capture.close();
        impl.render.close();
        return false;
    }

    // The other half of the same rule: two *different* endpoint ids can still be
    // one signal path when they are the playback and recording sides of one
    // virtual audio cable, because everything written to the playback side comes
    // back on the recording side. Refusing here is the only place this can be
    // caught before audio flows, and the check is repeated after every reopen
    // because an empty requested id re-resolves the default endpoint each time.
    if (passThroughKeysCollide(impl.capturePassThroughKey.load(std::memory_order_acquire),
                               impl.renderPassThroughKey.load(std::memory_order_acquire))) {
        error = "capture (" + impl.capture.openedDeviceName() + ") and render ("
            + impl.render.openedDeviceName()
            + ") are the two sides of one virtual audio device, so the processed output would"
              " come straight back as input and the engine would process its own signal forever."
              " Use one side of that cable and a physical device on the other: capture the cable's"
              " recording side with --input-device and render to the output device with --device,"
              " or the reverse.";
        impl.capture.close();
        impl.render.close();
        return false;
    }

    // The render stream asked for the capture rate, so the engine expects the
    // endpoint to hold up its side of that request. If the stream still came
    // back at a different rate, the conversion the request depends on did not
    // happen, and feeding the DSP's output into it would replay every sample at
    // the wrong rate — an audible pitch shift rather than a subtle artefact.
    // Refusing is the honest outcome; there is no second mechanism to fall back
    // on, because this engine deliberately carries no resampler of its own.
    if (renderFormat.sampleRate != captureFormat.sampleRate) {
        error = "the render endpoint opened at "
            + std::to_string(renderFormat.sampleRate)
            + " Hz after being asked for the capture rate "
            + std::to_string(captureFormat.sampleRate)
            + " Hz, so the audio engine did not perform the rate conversion this route"
              " relies on; choose a render endpoint that supports the capture rate";
        impl.capture.close();
        impl.render.close();
        return false;
    }

    const uint32_t sampleRate = captureFormat.sampleRate;

    if (!impl.dsp->prepare(sampleRate, 2, error)) {
        impl.capture.close();
        impl.render.close();
        return false;
    }
    if (!impl.dsp->applySettings(settings)) {
        // The stage refuses only when its control queue allocation failed, but
        // starting with silently unapplied settings would run a different model
        // than the caller asked for.
        error = "failed to queue the initial DSP settings";
        impl.capture.close();
        impl.render.close();
        return false;
    }

    // ~1 s of stereo backlog at the capture rate (the ring rounds up to a power
    // of two). Deep enough that a scheduling hiccup on either side does not
    // immediately become a drop or an underrun. prepare() bounds the rate, so
    // this cannot overflow.
    impl.ring = lc_ring_buffer_create(sampleRate * 2u);
    if (impl.ring == nullptr) {
        error = "ring buffer allocation failed";
        impl.capture.close();
        impl.render.close();
        return false;
    }

    uint32_t renderBlock = impl.render.bufferFrames();
    if (renderBlock == 0 || renderBlock > maxBlockFrames) {
        renderBlock = defaultRenderBlockFrames;
    }
    impl.renderBlockFrames = renderBlock;

    // A fresh run reports only its own activity; the counters describe the
    // stream that is about to start, not a previous session.
    impl.captureErrors.store(0, std::memory_order_relaxed);
    impl.renderErrors.store(0, std::memory_order_relaxed);
    impl.resyncCount.store(0, std::memory_order_relaxed);
    impl.processCallbacks.store(0, std::memory_order_relaxed);
    impl.deviceReopenAttempts.store(0, std::memory_order_relaxed);
    impl.recoveredStreams.store(0, std::memory_order_relaxed);
    impl.givingUp.store(false, std::memory_order_relaxed);
    // A new run replaces the previous session's preserved counters; they are
    // only a fallback for reading stats() after stop().
    impl.haveFinalRingStats.store(false, std::memory_order_release);

    impl.captureSampleRate.store(captureFormat.sampleRate, std::memory_order_relaxed);
    impl.renderSampleRate.store(renderFormat.sampleRate, std::memory_order_relaxed);
    impl.captureBufferFrames.store(impl.capture.bufferFrames(), std::memory_order_relaxed);
    impl.renderBufferFrames.store(impl.render.bufferFrames(), std::memory_order_relaxed);
    impl.renderChannels.store(renderFormat.channels, std::memory_order_relaxed);
    impl.renderPeriodMs.store(impl.render.periodMs(), std::memory_order_relaxed);
    impl.captureStreamLatencyMs.store(impl.capture.streamLatencyMs(), std::memory_order_relaxed);
    impl.renderStreamLatencyMs.store(impl.render.streamLatencyMs(), std::memory_order_relaxed);
    impl.captureIsLoopback.store(impl.capture.isLoopback(), std::memory_order_relaxed);

    impl.stopping.store(false, std::memory_order_release);
    running_.store(true, std::memory_order_release);

    captureThread_ = std::thread(&Engine::runCapture, this);
    renderThread_ = std::thread(&Engine::runRender, this);
    return true;
}

void Engine::stop() {
    Impl& impl = *impl_;

    impl.stopping.store(true, std::memory_order_release);
    if (impl.render.isOpen()) {
        // Unblocks a write() that is waiting for the endpoint to drain. Guarded
        // on isOpen() so a stop() before the first start() cannot leave a stop
        // request behind for the next run to observe.
        impl.render.requestStop();
    }
    running_.store(false, std::memory_order_release);

    // The capture client is closed *before* the join. Its contract makes close()
    // the way a capture thread parked inside acquire() is woken: the device
    // event is signalled and the in-flight acquire() returns false. Joining
    // first would leave the thread waiting for a packet that never comes.
    // close() is documented as safe to call repeatedly and against an endpoint
    // that is not open.
    impl.capture.close();

    if (captureThread_.joinable()) {
        captureThread_.join();
    }
    if (renderThread_.joinable()) {
        renderThread_.join();
    }

    impl.render.close();
    // No endpoint is held once the streams are down, so nothing can collide.
    // Leaving a hash set would make the next run's first reopen compare against
    // an endpoint from a session that has already ended.
    impl.captureEndpointHash.store(0, std::memory_order_release);
    impl.renderEndpointHash.store(0, std::memory_order_release);
    impl.capturePassThroughKey.store(0, std::memory_order_release);
    impl.renderPassThroughKey.store(0, std::memory_order_release);

    // Publish the ring diagnostics before the ring is destroyed. stats() is the
    // only way a caller learns what happened during the run, and a caller
    // naturally reads it after stop() returns — so the counters must outlive the
    // ring they came from. Without this, every stopped session would report zero
    // frames processed and zero drops regardless of what actually occurred.
    if (impl.ring != nullptr) {
        impl.finalDroppedSamples.store(lc_ring_buffer_dropped_write_samples(impl.ring),
                                       std::memory_order_relaxed);
        impl.finalUnderrunSamples.store(lc_ring_buffer_underrun_samples(impl.ring),
                                        std::memory_order_relaxed);
        impl.finalTotalWritten.store(lc_ring_buffer_total_written_samples(impl.ring),
                                     std::memory_order_relaxed);
        impl.finalTotalRead.store(lc_ring_buffer_total_read_samples(impl.ring),
                                  std::memory_order_relaxed);
        impl.haveFinalRingStats.store(true, std::memory_order_release);
        impl.finalRingCapacity.store(lc_ring_buffer_capacity(impl.ring), std::memory_order_relaxed);

        lc_ring_buffer_destroy(impl.ring);
        impl.ring = nullptr;
    }
    impl.dsp->reset();
}

bool Engine::requestSettings(const Settings& settings) {
    // The stage re-normalizes, recomputes every coefficient, and queues the
    // result; the audio thread applies it at its next block boundary.
    return impl_->dsp->applySettings(settings);
}

EngineStats Engine::stats() const {
    const Impl& impl = *impl_;
    EngineStats stats;

    stats.captureSampleRate = impl.captureSampleRate.load(std::memory_order_relaxed);
    stats.renderSampleRate = impl.renderSampleRate.load(std::memory_order_relaxed);
    stats.captureBufferFrames = impl.captureBufferFrames.load(std::memory_order_relaxed);
    stats.renderBufferFrames = impl.renderBufferFrames.load(std::memory_order_relaxed);
    stats.renderPeriodMs = impl.renderPeriodMs.load(std::memory_order_relaxed);
    stats.renderChannels = impl.renderChannels.load(std::memory_order_relaxed);
    stats.captureStreamLatencyMs = impl.captureStreamLatencyMs.load(std::memory_order_relaxed);
    stats.renderStreamLatencyMs = impl.renderStreamLatencyMs.load(std::memory_order_relaxed);

    if (impl.ring != nullptr) {
        stats.droppedSamples = lc_ring_buffer_dropped_write_samples(impl.ring);
        stats.underrunSamples = lc_ring_buffer_underrun_samples(impl.ring);
        stats.totalWrittenSamples = lc_ring_buffer_total_written_samples(impl.ring);
        stats.totalReadSamples = lc_ring_buffer_total_read_samples(impl.ring);
        stats.ringCapacitySamples = lc_ring_buffer_capacity(impl.ring);
        stats.ringAvailableSamples = lc_ring_buffer_available(impl.ring);
    } else if (impl.haveFinalRingStats.load(std::memory_order_acquire)) {
        // The run ended and stop() already destroyed the ring; report the
        // counters it preserved so a caller reading stats() after stop() still
        // sees what happened. Nothing is buffered once the ring is gone.
        stats.droppedSamples = impl.finalDroppedSamples.load(std::memory_order_relaxed);
        stats.underrunSamples = impl.finalUnderrunSamples.load(std::memory_order_relaxed);
        stats.totalWrittenSamples = impl.finalTotalWritten.load(std::memory_order_relaxed);
        stats.totalReadSamples = impl.finalTotalRead.load(std::memory_order_relaxed);
        stats.ringCapacitySamples = impl.finalRingCapacity.load(std::memory_order_relaxed);
        stats.ringAvailableSamples = 0;
    }

    stats.captureErrors = impl.captureErrors.load(std::memory_order_relaxed);
    stats.renderErrors = impl.renderErrors.load(std::memory_order_relaxed);
    stats.resyncCount = impl.resyncCount.load(std::memory_order_relaxed);
    stats.processCallbacks = impl.processCallbacks.load(std::memory_order_relaxed);
    stats.deviceReopenAttempts = impl.deviceReopenAttempts.load(std::memory_order_relaxed);
    stats.recoveredStreams = impl.recoveredStreams.load(std::memory_order_relaxed);
    stats.givingUp = impl.givingUp.load(std::memory_order_acquire);

    stats.running = running_.load(std::memory_order_acquire);
    stats.captureIsLoopback = impl.captureIsLoopback.load(std::memory_order_relaxed);
    // Reported from the stage rather than from the last request: it must name
    // the model the audio thread is actually running.
    stats.activeDSPModel = impl.dsp->activeModel();
    // Exclusive mode is not implemented; the clients are always opened shared.
    stats.usingSharedMode = true;
    return stats;
}

void Engine::runCapture() {
    Impl& impl = *impl_;

    // COM apartments are per-thread: a std::thread does not inherit the
    // creating thread's apartment. The audio client was activated on the
    // control thread, and an object created in the multi-threaded apartment can
    // be used from any MTA thread without marshalling, so this thread joins the
    // MTA itself. RPC_E_CHANGED_MODE means the thread already lives in another
    // apartment — a success for our purposes, and in that case this thread did
    // not create the apartment and must not uninitialize it.
    const HRESULT comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool ownsApartment = SUCCEEDED(comResult);

    // The device layer writes a human-readable message here, and only when it
    // fails. Building that text on the audio thread is acceptable because the
    // stream is already stopping; the steady-state packet loop below stays
    // allocation-free.
    std::string errorText;

    float* const interleaved = impl.captureInterleaved.data();

    // Reopen budget for one failure sequence; reset once a packet arrives again.
    RecoveryPolicy recovery;

    // The failure that ended the last operation, consumed by the next pass and
    // cleared as it is read, so a stale cause cannot decide a later pass.
    DeviceError lastFailure = DeviceError::none;

    while (!impl.stopping.load(std::memory_order_acquire)) {
        // The decision is made by nextLoopStep(), which the offline checks
        // exercise directly, so the loop body only carries out what was decided.
        const bool open = impl.capture.isOpen();
        const DeviceError lost = open ? DeviceError::none : lastFailure;
        lastFailure = DeviceError::none;

        switch (nextLoopStep(open, lost, recovery.attempts())) {
            case LoopStep::run:
                break;
            case LoopStep::stop:
                impl.captureErrors.fetch_add(1, std::memory_order_relaxed);
                if (lost == DeviceError::fatal || recovery.attempts() >= maxDeviceReopenAttempts) {
                    impl.givingUp.store(true, std::memory_order_release);
                }
                impl.stopping.store(true, std::memory_order_release);
                break;
            case LoopStep::attemptOpen: {
                recovery.noteAttempt();
                impl.deviceReopenAttempts.fetch_add(1, std::memory_order_relaxed);

                // Bounded and interruptible: a stop request must not wait out the
                // backoff.
                const uint32_t delayMs = reopenDelayMs(recovery.attempts());
                for (uint32_t waited = 0;
                     waited < delayMs && !impl.stopping.load(std::memory_order_acquire);
                     waited += 20) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
                if (impl.stopping.load(std::memory_order_acquire)) {
                    break;
                }

                impl.capture.close();  // idempotent; the object may already be closed
                impl.captureEndpointHash.store(0, std::memory_order_release);
                impl.capturePassThroughKey.store(0, std::memory_order_release);
                std::string reopenError;
                if (impl.capture.open(impl.captureOptions, reopenError)) {
                    impl.captureEndpointHash.store(
                        endpointHash(impl.capture.openedDeviceId()),
                        std::memory_order_release);
                    impl.capturePassThroughKey.store(
                        virtualPassThroughKey(impl.capture.openedIdentity()),
                        std::memory_order_release);
                    // The mirror of the check in runRender(): if only capture
                    // failed, render is still holding its endpoint, and an empty
                    // requested id means this open just re-resolved the default
                    // one. Landing on the endpoint render is using — or on the
                    // other side of the cable render is using — would close the
                    // feedback loop, so stop instead of continuing.
                    if (routeFormsFeedbackLoop(
                            impl.captureEndpointHash.load(std::memory_order_acquire),
                            impl.renderEndpointHash.load(std::memory_order_acquire),
                            impl.capturePassThroughKey.load(std::memory_order_acquire),
                            impl.renderPassThroughKey.load(std::memory_order_acquire))) {
                        impl.capture.close();
                        impl.captureEndpointHash.store(0, std::memory_order_release);
                        impl.capturePassThroughKey.store(0, std::memory_order_release);
                        impl.givingUp.store(true, std::memory_order_release);
                        impl.stopping.store(true, std::memory_order_release);
                        continue;
                    }
                    impl.recoveredStreams.fetch_add(1, std::memory_order_relaxed);
                    // The stream is a new one: the buffered backlog and the filter
                    // state belong to the audio that ended, so the render side
                    // discards and restarts rather than bridging the gap.
                    lc_ring_buffer_request_discard(impl.ring);
                    recovery.reset();
                } else {
                    // Remember why, so the next pass decides from it: a fatal
                    // cause stops the stream, a recoverable one retries.
                    lastFailure = impl.capture.lastError();
                }
                continue;
            }
        }
        if (impl.stopping.load(std::memory_order_acquire)) {
            break;
        }

        if (!impl.capture.acquire(&errorText)) {
            if (impl.stopping.load(std::memory_order_acquire)) {
                // A stop request also makes acquire() return false. That is an
                // orderly shutdown, not a device failure, and counting it would
                // make every Ctrl-C look like a broken endpoint.
                break;
            }

            impl.captureErrors.fetch_add(1, std::memory_order_relaxed);
            lastFailure = impl.capture.lastError();
            // Tear down a lost endpoint so the next pass reopens it. A failure
            // that cannot be retried leaves the object open and stops above.
            if (lastFailure == DeviceError::deviceLost) {
                impl.capture.close();
                // This side holds no endpoint now, so it cannot collide with the
                // other one until it opens again.
                impl.captureEndpointHash.store(0, std::memory_order_release);
                impl.capturePassThroughKey.store(0, std::memory_order_release);
            }
            continue;
        }

        // A delivered packet means the endpoint is healthy again.
        recovery.reset();

        const float* left = impl.capture.left();
        const float* right = impl.capture.right();
        uint32_t frames = impl.capture.frameCount();
        if (frames > maxBlockFrames) {
            // The capture client clamps oversized packets to its own capacity
            // and documents the drop; clamping again keeps the interleave
            // scratch in bounds if a packet ever arrives larger than that.
            frames = maxBlockFrames;
        }

        if (left == nullptr || right == nullptr) {
            // Only reachable if a packet carried no channel data. Push silence
            // rather than a stale buffer, so the ring timeline stays aligned.
            std::fill_n(interleaved, static_cast<std::size_t>(frames) * 2, 0.0f);
        } else {
            for (uint32_t frame = 0; frame < frames; ++frame) {
                interleaved[frame * 2] = left[frame];
                interleaved[frame * 2 + 1] = right[frame];
            }
        }

        // Read the flag before releasing: it describes this packet, and the
        // packet pointer is invalid afterwards.
        const bool discontinuity = impl.capture.isDiscontinuity();
        impl.capture.release();

        if (frames > 0) {
            // The ring's consumer side deinterleaves, so the producer hands
            // over L,R,L,R. A short push means the DSP fell behind; the ring
            // counts the dropped samples itself (droppedSamples).
            lc_ring_buffer_push(impl.ring, interleaved, frames * 2);
        }

        if (discontinuity) {
            // The device repositioned, so the buffered backlog no longer
            // continues the stream. The DSP belongs to the render thread, so
            // only the request is recorded here; consuming it there both drops
            // the stale backlog and gives the filter reset a single owner.
            lc_ring_buffer_request_discard(impl.ring);
        }
    }

    if (ownsApartment) {
        CoUninitialize();
    }
}

void Engine::runRender() {
    Impl& impl = *impl_;

    // See runCapture(): an MTA object may be used from any MTA thread, which is
    // why the control thread's IAudioRenderClient is usable here after this
    // thread joins the apartment.
    const HRESULT comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool ownsApartment = SUCCEEDED(comResult);

    std::string errorText;

    const uint32_t blockFrames = impl.renderBlockFrames;
    float* const left = impl.renderLeft.data();
    float* const right = impl.renderRight.data();

    // Reopen budget for one failure sequence; reset once a block lands again.
    RecoveryPolicy recovery;

    // The failure that ended the last operation; consumed and cleared by the
    // next pass, as in the capture loop.
    DeviceError lastFailure = DeviceError::none;

    while (!impl.stopping.load(std::memory_order_acquire)) {
        // Same structure as the capture loop: nextLoopStep() decides, this loop
        // acts. See RecoveryPolicy.h for why a closed endpoint is reopened
        // before anything else.
        const bool open = impl.render.isOpen();
        const DeviceError lost = open ? DeviceError::none : lastFailure;
        lastFailure = DeviceError::none;

        switch (nextLoopStep(open, lost, recovery.attempts())) {
            case LoopStep::run:
                break;
            case LoopStep::stop:
                impl.renderErrors.fetch_add(1, std::memory_order_relaxed);
                if (lost == DeviceError::fatal || recovery.attempts() >= maxDeviceReopenAttempts) {
                    impl.givingUp.store(true, std::memory_order_release);
                }
                impl.stopping.store(true, std::memory_order_release);
                break;
            case LoopStep::attemptOpen: {
                recovery.noteAttempt();
                impl.deviceReopenAttempts.fetch_add(1, std::memory_order_relaxed);

                const uint32_t delayMs = reopenDelayMs(recovery.attempts());
                for (uint32_t waited = 0;
                     waited < delayMs && !impl.stopping.load(std::memory_order_acquire);
                     waited += 20) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
                if (impl.stopping.load(std::memory_order_acquire)) {
                    break;
                }

                impl.render.close();  // idempotent
                impl.renderEndpointHash.store(0, std::memory_order_release);
                impl.renderPassThroughKey.store(0, std::memory_order_release);
                std::string reopenError;
                if (impl.render.open(impl.renderOptions, reopenError)) {
                    impl.renderEndpointHash.store(
                        endpointHash(impl.render.openedDeviceId()),
                        std::memory_order_release);
                    impl.renderPassThroughKey.store(
                        virtualPassThroughKey(impl.render.openedIdentity()),
                        std::memory_order_release);
                    // An empty requested id means "the default endpoint", which
                    // open() re-resolves every time. A default-device change
                    // while this stream was recovering can therefore land render
                    // on the endpoint capture is already holding — or on the
                    // other side of the cable capture is holding — and the
                    // start-time check could not have seen that. Left alone it
                    // is the unbounded feedback loop the start-time check exists
                    // to prevent, so the stream stops here instead.
                    if (routeFormsFeedbackLoop(
                            impl.captureEndpointHash.load(std::memory_order_acquire),
                            impl.renderEndpointHash.load(std::memory_order_acquire),
                            impl.capturePassThroughKey.load(std::memory_order_acquire),
                            impl.renderPassThroughKey.load(std::memory_order_acquire))) {
                        impl.render.close();
                        impl.renderEndpointHash.store(0, std::memory_order_release);
                        impl.renderPassThroughKey.store(0, std::memory_order_release);
                        impl.givingUp.store(true, std::memory_order_release);
                        impl.stopping.store(true, std::memory_order_release);
                        continue;
                    }
                    // The endpoint restarted, so its buffer is empty again: refill
                    // it with silence before resuming, otherwise the first writes
                    // would be heard as a burst of stale samples.
                    impl.render.writeSilence(impl.render.bufferFrames(), &reopenError);
                    impl.recoveredStreams.fetch_add(1, std::memory_order_relaxed);
                    recovery.reset();
                } else {
                    lastFailure = impl.render.lastError();
                }
                continue;
            }
        }
        if (impl.stopping.load(std::memory_order_acquire)) {
            break;
        }

        // Handle the capture thread's discard request first: the reset must
        // happen before the pop that follows it, so the state starts clean on
        // the first block of the new stream.
        if (lc_ring_buffer_consume_discard_request(impl.ring) != 0) {
            impl.dsp->resetForDiscontinuity();
            impl.resyncCount.fetch_add(1, std::memory_order_relaxed);
        }

        // Underrun needs no handling here: the ring zero-fills the shortfall,
        // counts it as underrunSamples, and the render side keeps its cadence
        // instead of stalling the endpoint.
        lc_ring_buffer_pop_deinterleaved_stereo(impl.ring, left, right, blockFrames);

        impl.dsp->processBlock(left, right, blockFrames);
        impl.processCallbacks.fetch_add(1, std::memory_order_relaxed);

        if (!impl.render.write(left, right, blockFrames, &errorText)) {
            if (impl.stopping.load(std::memory_order_acquire)) {
                // write() returns false for a stop request as well; that is the
                // normal way this loop ends.
                break;
            }

            impl.renderErrors.fetch_add(1, std::memory_order_relaxed);
            lastFailure = impl.render.lastError();
            if (lastFailure == DeviceError::deviceLost) {
                impl.render.close();
                // This side holds no endpoint now, so it cannot collide with the
                // other one until it opens again.
                impl.renderEndpointHash.store(0, std::memory_order_release);
                impl.renderPassThroughKey.store(0, std::memory_order_release);
            }
            continue;
        }

        // A written block means the endpoint is healthy again.
        recovery.reset();
    }

    if (ownsApartment) {
        CoUninitialize();
    }
}

void Engine::processBlock(const float* left, const float* right, uint32_t frames) {
    if (running_.load(std::memory_order_acquire)) {
        // While the engine runs, the render thread owns the DSP stage and the
        // ring. A second driver would interleave two block streams into the
        // same filter state, so the offline entry points stand down.
        return;
    }
    if (left == nullptr || frames == 0) {
        return;
    }

    const uint32_t count = frames > maxBlockFrames ? maxBlockFrames : frames;
    // The stage processes in place, so the const qualifier only says the engine
    // keeps no reference to the caller's buffers. The caller passes scratch it
    // owns and has finished with, which is the same contract the render thread
    // has with its block buffers; the cast is what expresses that here.
    impl_->dsp->processBlock(const_cast<float*>(left),
                             const_cast<float*>(right != nullptr ? right : left),
                             count);
}

std::string describeRoute(const EngineStats& stats, const EngineOptions& options) {
    if (stats.captureSampleRate == 0 && stats.renderSampleRate == 0) {
        return "route: not negotiated (the engine has not started)";
    }

    // The stats carry the negotiated numbers but no endpoint names; the options
    // are the only source of identity available here. Loopback follows the same
    // rule the engine opens with: a render-flow capture always is one. Falling
    // back to that rule keeps the line truthful for a caller that assembled the
    // stats itself instead of reading them from a running engine.
    const bool loopback = stats.running
        ? stats.captureIsLoopback
        : options.captureFlow == DataFlow::render;
    const std::string captureName = options.captureDeviceId.empty()
        ? (loopback ? "default output" : "default input")
        : options.captureDeviceId;
    const std::string renderName =
        options.renderDeviceId.empty() ? "default output" : options.renderDeviceId;

    // The buffer duration is the part of the latency that is actually
    // measurable here: it is the negotiated frame count over the stream rate.
    // GetStreamLatency() reports 0 on many shared-mode endpoints (it does on
    // this workstation), so the buffer is reported alongside it rather than
    // being replaced by a zero.
    const double captureBufferMs = stats.captureSampleRate == 0 ? 0.0
        : static_cast<double>(stats.captureBufferFrames) * 1000.0 / stats.captureSampleRate;
    const double renderBufferMs = stats.renderSampleRate == 0 ? 0.0
        : static_cast<double>(stats.renderBufferFrames) * 1000.0 / stats.renderSampleRate;

    char text[640];
    std::snprintf(text, sizeof(text),
                  "capture: %s \"%s\" @ %u Hz (%u frames, %.1f ms buffer, engine latency %.1f ms)"
                  " → render: \"%s\" @ %u Hz (%u frames, %.1f ms buffer, %.1f ms period,"
                  " engine latency %.1f ms) [%s]",
                  loopback ? "loopback" : "input",
                  captureName.c_str(),
                  stats.captureSampleRate,
                  stats.captureBufferFrames,
                  captureBufferMs,
                  stats.captureStreamLatencyMs,
                  renderName.c_str(),
                  stats.renderSampleRate,
                  stats.renderBufferFrames,
                  renderBufferMs,
                  stats.renderPeriodMs,
                  stats.renderStreamLatencyMs,
                  stats.usingSharedMode ? "shared" : "exclusive");

    std::string result(text);

    // What the reported latency is, and what it is not. The buffer duration is
    // the negotiated buffer over the stream rate; GetStreamLatency() covers the
    // audio engine and the endpoint when the endpoint reports it. Ring
    // buffering, DSP and the two device clocks add to the total path latency,
    // which is not measured here.
    result += "\n  note: the buffer duration is the negotiated buffer at the stream rate."
              " The engine latency figure is what WASAPI reports (audio engine + endpoint),"
              " and is 0 when the endpoint does not provide it. Ring buffering and DSP add"
              " to the total path latency, which is not measured here.";

    // Two properties of loopback that decide whether a run is a useful
    // processing chain at all, so the line states them instead of leaving the
    // user to infer them from "loopback" alone:
    //   - the captured stream is a copy of the output, so the original keeps
    //     playing to its own endpoint (this route does not replace it);
    //   - the tap sits before volume and mute, so muting the endpoint does not
    //     silence what is being processed.
    if (loopback) {
        result += "\n  note: the original audio still plays to its own endpoint — this"
                  " route adds processed output rather than replacing it.";
        result += "\n  note: loopback taps the output before volume and mute, so system"
                  " volume and mute are not reflected in what is captured.";
    }
    return result;
}

} // namespace lowend::win
