#include "../include/Core/SpatialGeometry.h"

#include <algorithm>
#include <cmath>

namespace lowend {
namespace {

float pathDistance(const LCSpatialPoint& source, const LCSpatialPoint& ear) {
    const float dx = source.x - ear.x;
    const float dz = source.z - ear.z;
    return std::sqrt(dx * dx + dz * dz);
}

float distanceGain(float effectiveDistance) {
    return 1.0f / std::fmax(0.45f + effectiveDistance * 0.62f, 0.2f);
}

void finishPath(LCSpatialPathGeometry& path,
                float minimumDistance,
                float gain,
                float sampleRate,
                uint32_t delayCapacity) {
    path.distanceOffsetMeters = path.effectiveDistanceMeters - minimumDistance;
    path.gain = gain;
    // Inputs are bounded above, so this positive rounded value fits UInt32.
    path.requestedDelaySamples = static_cast<uint32_t>(
        std::fmax(path.distanceOffsetMeters, 0.0f) / 343.0f * sampleRate + 0.5f);
    path.appliedDelaySamples = std::min(path.requestedDelaySamples, delayCapacity - 1u);
    path.appliedDelayMs = static_cast<float>(path.appliedDelaySamples) / sampleRate * 1000.0f;
}

LCSpatialPathSettings audioPath(const LCSpatialPathGeometry& path) {
    return { path.appliedDelaySamples, path.gain };
}

} // namespace

bool calculateSpatialGeometry(float sampleRate,
                              const LCSpatialGeometryInput& input,
                              uint32_t delayCapacity,
                              LCSpatialGeometryResult& result) noexcept {
    result = {};
    if (!std::isfinite(sampleRate) || sampleRate < 8000.0f
        || sampleRate > static_cast<float>(LC_SPATIAL_MAX_SAMPLE_RATE)
        || delayCapacity < 2u
        || !std::isfinite(input.listenerX) || !std::isfinite(input.listenerZ)
        || !std::isfinite(input.speakerWidth) || !std::isfinite(input.amount)) {
        return false;
    }

    const float width = std::clamp(input.speakerWidth, 0.6f, 3.0f);
    const float x = std::clamp(input.listenerX, -3.0f, 3.0f);
    const float z = std::clamp(input.listenerZ, -2.8f, 2.8f);
    result.leftSpeaker = { -width / 2.0f, 1.8f };
    result.rightSpeaker = { width / 2.0f, 1.8f };
    result.leftEar = { x - 0.09f, z };
    result.rightEar = { x + 0.09f, z };
    result.amount = std::clamp(input.amount / 100.0f, 0.0f, 1.0f);
    result.crossfeed = 0.16f + result.amount * 0.30f;
    result.sampleRate = sampleRate;
    result.delayCapacity = delayCapacity;

    result.ll.rawDistanceMeters = pathDistance(result.leftSpeaker, result.leftEar);
    result.lr.rawDistanceMeters = pathDistance(result.leftSpeaker, result.rightEar);
    result.rl.rawDistanceMeters = pathDistance(result.rightSpeaker, result.leftEar);
    result.rr.rawDistanceMeters = pathDistance(result.rightSpeaker, result.rightEar);
    for (LCSpatialPathGeometry* path : { &result.ll, &result.lr, &result.rl, &result.rr }) {
        path->effectiveDistanceMeters = std::fmax(path->rawDistanceMeters, 0.12f);
    }
    const float minimumDistance = std::min({ result.ll.effectiveDistanceMeters,
        result.lr.effectiveDistanceMeters, result.rl.effectiveDistanceMeters,
        result.rr.effectiveDistanceMeters });
    const float llGain = distanceGain(result.ll.effectiveDistanceMeters);
    const float rrGain = distanceGain(result.rr.effectiveDistanceMeters);
    const float lrGain = distanceGain(result.lr.effectiveDistanceMeters) * result.crossfeed;
    const float rlGain = distanceGain(result.rl.effectiveDistanceMeters) * result.crossfeed;
    const float normalizer = 1.0f / std::fmax((llGain + rrGain) * 0.5f, 0.001f);
    finishPath(result.ll, minimumDistance, llGain * normalizer, sampleRate, delayCapacity);
    finishPath(result.lr, minimumDistance, lrGain * normalizer, sampleRate, delayCapacity);
    finishPath(result.rl, minimumDistance, rlGain * normalizer, sampleRate, delayCapacity);
    finishPath(result.rr, minimumDistance, rrGain * normalizer, sampleRate, delayCapacity);
    result.settings.enabled = input.enabled != 0 ? 1u : 0u;
    result.settings.amount = result.amount;
    result.settings.ll = audioPath(result.ll);
    result.settings.lr = audioPath(result.lr);
    result.settings.rl = audioPath(result.rl);
    result.settings.rr = audioPath(result.rr);
    return true;
}

} // namespace lowend
