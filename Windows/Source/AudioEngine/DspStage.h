// DspStage.h — the DSP half of the Windows engine, with no device dependency.
//
// This is the only place the Windows build drives lowend::Processor. It owns
// the model processor, the spatial processor, and the lock-free settings queue
// that connects a control thread to the audio thread.
//
// Realtime contract (matches Source/Core/README.md and the macOS engine):
//   - processBlock() allocates nothing, takes no locks, logs nothing, and
//     performs no coefficient mathematics.
//   - All coefficients are computed by the control thread and handed over as a
//     plain LCDSPSettings POD through LCControlEventQueue.
//   - The audio thread acknowledges a revision only after applying it.

#pragma once

#include "Core/Core.h"
#include "Core/Processor.h"
#include "Core/SpatialGeometry.h"
#include "Core/SpatialProcessor.h"
#include "AudioRingBufferC.h"
#include "AudioEngine/Settings.h"

#include <cstdint>
#include <string>

namespace lowend::win {

// Largest block the stage accepts. Matches the macOS engine's 8,192-frame
// scratch capacity and bounds every internal buffer.
inline constexpr uint32_t maxBlockFrames = 8192;

class DspStage {
public:
    DspStage();
    ~DspStage();
    DspStage(const DspStage&) = delete;
    DspStage& operator=(const DspStage&) = delete;

    // Control thread, before audio starts.
    bool prepare(uint32_t sampleRate, uint32_t channels, std::string& error);

    // Control thread. Recomputes coefficients from `settings` and queues the
    // result. Returns false when the queue is full, leaving the previous
    // settings in effect. Also queues the spatial plan for the same rate.
    bool applySettings(const Settings& settings);

    // Audio thread. Applies every queued settings revision, then processes one
    // stereo block in place.
    void processBlock(float* left, float* right, uint32_t frames);

    // Audio thread. Applies queued settings without processing audio. Called on
    // a discontinuous packet so the DSP state is reset instead of bridging the
    // gap.
    void resetForDiscontinuity();

    // Control thread. Clears filter state.
    void reset();

    uint32_t sampleRate() const { return sampleRate_; }
    uint32_t channelCount() const { return channels_; }

    // Counts applied settings revisions; lets a caller observe that a queued
    // change actually reached the audio thread.
    uint64_t appliedRevision() const;

    // Model currently running in the DSP bank (DSPModel numeric value).
    uint32_t activeModel() const { return activeModel_; }

private:
    // Control thread. Queues an already-computed plan. Only applySettings()
    // calls this: the plan has to be derived from the same rate the stage was
    // prepared with, so a caller outside the class has no reason to build one.
    bool queueSettings(const LCDSPSettings& dsp, const LCSpatialSettings& spatial);

    lowend::Processor processor_;
    lowend::SpatialProcessor spatial_;
    LCControlEventQueue* controlQueue_ = nullptr;
    float spatialLeft_[maxBlockFrames] {};
    float spatialRight_[maxBlockFrames] {};
    uint32_t sampleRate_ = 48000;
    uint32_t channels_ = 2;
    uint32_t activeModel_ = dsp_model::circuit;
    bool prepared_ = false;
};

} // namespace lowend::win
