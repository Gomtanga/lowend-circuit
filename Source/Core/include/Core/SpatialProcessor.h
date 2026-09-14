// SpatialProcessor.h — stereo spatial stage.
//
// Direct port of the macOS Spatializer
// (SystemAudioProcessor/Sources/SystemAudioProcessor/SpatialDSP.swift). The
// algorithm is platform-independent — delay taps, a crossfade and an activation
// blend, with no audio-API dependency — so it lives in Core and both apps share
// one implementation instead of keeping a copy each.
//
// The geometry is not computed here. SpatialGeometry.cpp is the authority for
// speaker/ear distances, delays and gains; a control thread turns user controls
// into an LCSpatialSettings and hands it over through update().
//
// Audio-thread contract: process() allocates nothing, takes no locks, logs
// nothing, and computes nothing but the taps themselves. Storage is allocated
// once in the constructor and only ever indexed.

#pragma once

#include "AudioRingBufferC.h"
#include "SpatialGeometry.h"

#include <cstdint>

namespace lowend {

// One channel's delay line.
class DelayLine {
public:
    // Relative distance is bounded to 3.18 m, which is 7,121 samples at
    // 768 kHz, so every delay calculateSpatialGeometry() can request fits with
    // room to spare. Taking the value from the geometry header keeps the two
    // from drifting apart.
    static constexpr uint32_t capacity = LC_SPATIAL_DEFAULT_DELAY_CAPACITY;

    DelayLine();
    ~DelayLine();
    DelayLine(const DelayLine&) = delete;
    DelayLine& operator=(const DelayLine&) = delete;

    void write(float input);
    float read(uint32_t delaySamples) const;
    void advance();
    float process(float input, uint32_t delaySamples);
    void reset();

private:
    float* buffer_;
    uint32_t writeIndex_ = 0;
};

class SpatialProcessor {
public:
    static constexpr uint32_t delayCapacity = DelayLine::capacity;

    // Length of a settings crossfade, in frames. Matches Spatializer.
    // transitionFrames on macOS: long enough (about 5.3 ms at 48 kHz) that a
    // delay retarget cannot click, short enough that a control change still
    // reads as immediate. The value is fixed so both platforms fade over the
    // same number of frames.
    static constexpr uint32_t transitionFrames = 256;

    SpatialProcessor();
    ~SpatialProcessor();
    SpatialProcessor(const SpatialProcessor&) = delete;
    SpatialProcessor& operator=(const SpatialProcessor&) = delete;

    // Control thread, while quiescent. The stage derives everything it needs
    // from the sample counts in a settings struct, so this only marks the stage
    // as ready; it exists because a caller needs one place to initialize it.
    void prepare(float sampleRate);

    // Control thread. Queues a new plan; the audio thread crossfades over
    // transitionFrames. A second request during a fade replaces the single
    // pending plan rather than restarting the fade.
    void update(const LCSpatialSettings& settings);

    // Audio thread. One stereo frame in place.
    void process(float& left, float& right);

    // Control thread, while quiescent.
    void reset();

private:
    struct Path {
        uint32_t delay = 0;
        float gain = 1.0f;
    };
    struct Paths {
        Path ll, lr, rl, rr;
    };

    Paths pathsFromSettings(const LCSpatialSettings& settings) const;

    DelayLine leftHistory_;
    DelayLine rightHistory_;
    Paths current_ {};
    Paths target_ {};
    Paths pending_ {};
    bool hasPending_ = false;
    uint32_t transitionRemaining_ = 0;
    float amount_ = 0.0f;
    float targetAmount_ = 0.0f;
    float activation_ = 0.0f;
    float targetActivation_ = 0.0f;
    uint32_t mixRemaining_ = 0;
    bool initialized_ = false;
};

} // namespace lowend
