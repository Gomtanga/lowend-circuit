#pragma once

#include "AudioRingBufferC.h"

// A C-compatible result for control/UI work. Only `settings` belongs in the
// realtime control queue; the remaining fields explain the same computation.
enum {
    LC_SPATIAL_DEFAULT_DELAY_CAPACITY = 8192,
    LC_SPATIAL_MAX_SAMPLE_RATE = 768000
};

typedef struct {
    uint32_t enabled;
    float listenerX;
    float listenerZ;
    float speakerWidth;
    float amount;
} LCSpatialGeometryInput;

typedef struct {
    float x;
    float z;
} LCSpatialPoint;

typedef struct {
    float rawDistanceMeters;
    float effectiveDistanceMeters;
    float distanceOffsetMeters;
    float gain;
    uint32_t requestedDelaySamples;
    uint32_t appliedDelaySamples;
    float appliedDelayMs;
} LCSpatialPathGeometry;

typedef struct {
    LCSpatialPoint leftSpeaker;
    LCSpatialPoint rightSpeaker;
    LCSpatialPoint leftEar;
    LCSpatialPoint rightEar;
    LCSpatialPathGeometry ll;
    LCSpatialPathGeometry lr;
    LCSpatialPathGeometry rl;
    LCSpatialPathGeometry rr;
    float crossfeed;
    float amount;
    float sampleRate;
    uint32_t delayCapacity;
    LCSpatialSettings settings;
} LCSpatialGeometryResult;

#ifdef __cplusplus
namespace lowend {

// Returns false and clears result for non-finite controls, an unsupported rate,
// or invalid capacity. Finite out-of-range controls are clamped. Pure control-
// thread work: no allocation, mutable globals, or audio-engine dependencies.
bool calculateSpatialGeometry(float sampleRate,
                              const LCSpatialGeometryInput& input,
                              uint32_t delayCapacity,
                              LCSpatialGeometryResult& result) noexcept;

} // namespace lowend
#endif
