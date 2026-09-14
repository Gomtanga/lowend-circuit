// OutputConditioning.h — portable live output-conditioning stage (PCM 2x).
//
// Port of the live half of the macOS `ResamplingOutputConditioningEngine`
// (SystemAudioProcessor/Sources/SystemAudioProcessor/ResamplingOutputConditioningEngine.swift):
// `processLive(input:inputFrames:output:)` plus the parameter handling in
// `updateSettings(_:precomputedHeadroomGain:)`. The offline halves of that
// engine — 4x/8x, dither/noise shaping, the delta-sigma modulator and the DoP
// packer — are deliberately not ported, because live scope on macOS is PCM 2x
// only.
//
// Live scope, stated once so no caller has to guess:
//
//     active = enabled && outputMode == pcmOversampling (1) && oversamplingFactor == 2
//     bypass = everything else: disabled, dither, experimental DSD, 4x, 8x
//
// Bypass is a verbatim copy at the input frame count. Whether an eligible
// device/rate combination exists (44.1k→88.2k, 48k→96k) is decided off the audio
// thread by the caller; this class only acts on the flattened snapshot it is
// handed, exactly like the reference.
//
// Signal flow when active:
//
//     headroom (pre-FIR gain) -> per-channel polyphase 2x -> non-finite guard -> out
//
// Realtime contract: process() allocates nothing, takes no lock, logs nothing and
// computes no coefficients. Coefficient work happens in update() on the control
// thread; every buffer is allocated in prepare().
//
// Non-finite handling, exactly as on macOS: a non-finite sample is replaced by 0
// in the *output*, but it is not scrubbed from the FIR history, so a channel that
// receives one stays silent until the next activation change or reset().
//
// The audio contract is de-interleaved stereo: the caller de-interleaves once and
// gets two per-channel output pointers back, rather than the reference's
// interleaved buffer.

#pragma once

#include "AudioRingBufferC.h"
#include "PcmResampler.h"

#include <cstdint>
#include <memory>
#include <vector>

namespace lowend {

class OutputConditioning {
public:
    // The only oversampling factor the live path supports; 4x and 8x are offline
    // on macOS and stay out of this port.
    static constexpr uint32_t liveFactor = 2;

    OutputConditioning();
    ~OutputConditioning();
    OutputConditioning(const OutputConditioning&) = delete;
    OutputConditioning& operator=(const OutputConditioning&) = delete;

    // Control thread, while quiescent. Allocates the per-channel working buffers
    // and the two resamplers for blocks of at most `maxInputFrames` frames.
    // Returns false when `inputSampleRate` is not a positive finite number or
    // `maxInputFrames` is 0. Re-preparing for a new block size (device
    // reconfiguration) discards the current activation, so push a settings
    // snapshot through update() before processing again.
    bool prepare(double inputSampleRate, uint32_t maxInputFrames);

    // Control thread. Applies a flattened settings snapshot: refreshes the
    // resampler configuration and the headroom gain, and returns whether the live
    // 2x path is actually active afterwards. Coefficients are built here and
    // never in process().
    bool update(const LCOutputConditioningSettings& settings);

    // Audio thread. Processes `inputFrames` de-interleaved stereo frames and
    // writes the result to outLeft/outRight, which must each hold at least
    // maxOutputFrames(inputFrames) samples. Returns the number of output frames
    // written: inputFrames on bypass, inputFrames * 2 while active, or 0 when the
    // block is empty or larger than the prepared maxInputFrames — in which case
    // nothing is written at all, matching the reference guard.
    uint32_t process(const float* left, const float* right, uint32_t inputFrames,
                     float* outLeft, float* outRight);

    // Largest output frame count this stage can require for a block: the larger
    // of the bypass and active requirements, so one caller buffer covers either
    // mode.
    uint32_t maxOutputFrames(uint32_t inputFrames) const;

    bool isActive() const { return active_; }

    // Control thread, while quiescent. Clears both channels' filter history.
    void reset();

private:
    std::vector<float> deinterleavedLeft_;
    std::vector<float> deinterleavedRight_;
    std::vector<float> oversampledLeft_;
    std::vector<float> oversampledRight_;
    std::unique_ptr<PcmResampler> leftResampler_;
    std::unique_ptr<PcmResampler> rightResampler_;
    double inputSampleRate_ = 0.0;
    uint32_t maxInputFrames_ = 0;
    float headroomGain_ = 1.0f;
    bool prepared_ = false;
    bool active_ = false;
};

} // namespace lowend
