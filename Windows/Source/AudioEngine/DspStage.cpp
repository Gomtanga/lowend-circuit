// DspStage.cpp — the DSP half of the Windows engine.
//
// Threading shape, as described in the header:
//   - The control thread computes every coefficient (DSPPrecompute, spatial
//     geometry) and hands the results over as plain C PODs through the
//     lock-free control event queue.
//   - The audio thread only copies fields, calls into lowend::Processor and
//     lowend::SpatialProcessor, and acknowledges the revision it just applied.
//
// processBlock() therefore performs no allocation, takes no lock, logs
// nothing, and computes no coefficients.

#include "AudioEngine/DspStage.h"

#include <string>

namespace lowend::win {
namespace {

// Source/Core/src/SpatialGeometry.cpp only defines geometry for 8 kHz..768 kHz,
// and lowend::Processor::prepare() silently substitutes 48 kHz for anything
// outside its own support window. Rejecting an out-of-range rate keeps both
// stages on the clock the caller asked for instead of quietly processing at a
// different one.
constexpr uint32_t minSampleRate = 8000;
constexpr uint32_t maxSampleRate = 768000;

// The control thread can queue several edits (CLI start-up, a UI drag) before
// the audio thread drains them. 16 leaves headroom over that burst and costs a
// fixed amount of memory, not audio-thread work.
constexpr uint32_t controlQueueCapacity = 16;

// Audio thread. Applies every queued revision in FIFO order. The revision is
// acknowledged only after its settings are live, which is what lets a control
// thread observe that its change reached the DSP.
void applyQueuedEvents(LCControlEventQueue* queue,
                       lowend::Processor& processor,
                       lowend::SpatialProcessor& spatial,
                       uint32_t& activeModel) {
    if (queue == nullptr) {
        return;
    }
    LCControlEvent event {};
    while (lc_control_event_queue_pop(queue, &event) != 0) {
        if ((event.type & LC_CONTROL_EVENT_DSP) != 0) {
            processor.update(event.dsp);
            // The reported model must be the one the audio thread actually
            // switched to, so it changes here and not in applySettings().
            activeModel = event.dsp.dspModel;
        }
        if ((event.type & LC_CONTROL_EVENT_SPATIAL) != 0) {
            // The spatial stage takes the C ABI POD directly, so the audio
            // thread only copies fields: the geometry ran on the control
            // thread when the event was built.
            spatial.update(event.spatial);
        }
        lc_control_event_queue_acknowledge(queue, event.revision);
    }
}

} // namespace

DspStage::DspStage()
    : controlQueue_(lc_control_event_queue_create(controlQueueCapacity)) {}

DspStage::~DspStage() {
    lc_control_event_queue_destroy(controlQueue_);
}

bool DspStage::prepare(uint32_t sampleRate, uint32_t channels, std::string& error) {
    if (sampleRate < minSampleRate || sampleRate > maxSampleRate) {
        error = "unsupported sample rate " + std::to_string(sampleRate)
            + " Hz; supported range is " + std::to_string(minSampleRate) + ".."
            + std::to_string(maxSampleRate) + " Hz";
        return false;
    }
    if (channels < 1u || channels > lowend::Processor::maxSupportedChannels) {
        error = "unsupported channel count " + std::to_string(channels)
            + "; the DSP stage handles 1 or 2 channels";
        return false;
    }
    if (controlQueue_ == nullptr) {
        // Without the queue the stage could never receive settings; failing
        // here keeps the caller from running a silently inert engine.
        error = "control event queue allocation failed";
        return false;
    }

    processor_.prepare(static_cast<double>(sampleRate), channels);
    spatial_.prepare(static_cast<float>(sampleRate));

    sampleRate_ = sampleRate;
    channels_ = channels;
    prepared_ = true;
    return true;
}

bool DspStage::applySettings(const Settings& settings) {
    // The caller is expected to have normalized already; doing it again is
    // free here (control thread) and guarantees no NaN/Inf can reach the DSP
    // even if a future caller forgets.
    const Settings s = normalized(settings);

    LCDSPSettings dsp = lowend::DSPPrecompute::makeDSPSettings(
        static_cast<float>(sampleRate_),
        s.intensity,
        s.body,
        s.outputDb,
        s.dspModel,
        s.exciterOversamplingMode);

    // The authoritative geometry is Source/Core's, and the spatial stage now
    // consumes the same C POD the queue carries, so the plan never has to be
    // translated into a Windows-side shape.
    const LCSpatialSettings spatial = makeSpatialSettings(static_cast<float>(sampleRate_), s);

    // activeModel_ is deliberately not touched here: it must report what the
    // audio thread runs, and the audio thread updates it when it applies this
    // event.
    return queueSettings(dsp, spatial);
}

bool DspStage::queueSettings(const LCDSPSettings& dsp, const LCSpatialSettings& spatial) {
    if (controlQueue_ == nullptr) {
        return false;
    }

    LCControlEvent event {};
    event.type = LC_CONTROL_EVENT_DSP | LC_CONTROL_EVENT_SPATIAL;
    // `revision` is an observation token: the audio thread publishes it back
    // through acknowledge() once the settings are live. Deriving it from the
    // last acknowledged value keeps it monotonic for every drained batch. A
    // repeated value is harmless — a revision only exists while its event sits
    // in the queue, so two events can never carry the same token at the same
    // time, and the audio thread still applies them in FIFO order with the
    // newest one winning.
    event.revision = lc_control_event_queue_applied_revision(controlQueue_) + 1;
    event.dsp = dsp;
    event.spatial = spatial;

    // A full queue keeps the previous settings in effect; the caller decides
    // whether to retry.
    return lc_control_event_queue_push(controlQueue_, &event) != 0;
}

void DspStage::processBlock(float* left, float* right, uint32_t frames) {
    if (left == nullptr || frames == 0 || !prepared_) {
        return;
    }

    // A mono caller may legitimately pass a null right channel. Duplicating
    // left keeps the block audible instead of dropping it; lowend::Processor
    // re-derives mono from channelCount_ on its own.
    const bool hasRight = right != nullptr;
    float* const rightChannel = hasRight ? right : left;

    applyQueuedEvents(controlQueue_, processor_, spatial_, activeModel_);

    // Oversized blocks are split rather than truncated. The scratch buffers and
    // the processor's block handling are sized for maxBlockFrames, but silently
    // dropping the excess would discard audio and, worse, desynchronise the
    // spatial delay lines from the stream. Chunking keeps every frame processed
    // in order, and the split points are invisible to the DSP because the
    // filters are stateful across calls.
    uint32_t processed = 0;
    while (processed < frames) {
        const uint32_t chunk = std::min(frames - processed, maxBlockFrames);

        // Processor reads the channel count it was prepared with, so handing it
        // both pointers is correct for mono too.
        float* channels[2] = { left + processed, rightChannel + processed };
        processor_.process(channels, chunk);

        // Spatial always runs, even while it is disabled: the delay lines must
        // keep advancing, otherwise re-enabling the stage would replay a stale
        // tail from whenever it was last active. Bypass is bit-exact and cheap
        // in lowend::SpatialProcessor itself.
        //
        // Each frame is staged through the scratch buffers instead of being fed
        // to process() as caller storage. The spatial stage cross-feeds one
        // channel into the other, so its two in/out references must both still
        // hold the post-DSP input when it starts writing; staging also
        // guarantees the two references never alias, which a duplicated mono
        // channel would otherwise make true.
        for (uint32_t frame = 0; frame < chunk; ++frame) {
            spatialLeft_[frame] = left[processed + frame];
            spatialRight_[frame] = rightChannel[processed + frame];
            spatial_.process(spatialLeft_[frame], spatialRight_[frame]);
            left[processed + frame] = spatialLeft_[frame];
            if (hasRight) {
                right[processed + frame] = spatialRight_[frame];
            }
        }

        processed += chunk;
    }
}

void DspStage::resetForDiscontinuity() {
    // Apply queued settings first: a plan queued before the discontinuity
    // describes the route that is about to continue, and resetting after it
    // means the new plan's state is the one that starts clean.
    applyQueuedEvents(controlQueue_, processor_, spatial_, activeModel_);
    processor_.reset();
    spatial_.reset();
}

void DspStage::reset() {
    processor_.reset();
    spatial_.reset();
}

uint64_t DspStage::appliedRevision() const {
    return lc_control_event_queue_applied_revision(controlQueue_);
}

} // namespace lowend::win
