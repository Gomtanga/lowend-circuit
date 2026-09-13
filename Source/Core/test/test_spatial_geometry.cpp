#include <Core/Core.h>
#include <Core/SpatialGeometry.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>

namespace {
int failures = 0;
void check(bool value, const char* message) {
    if (!value) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        ++failures;
    }
}
bool near(float a, float b, float tolerance = 0.00001f) {
    return std::isfinite(a) && std::isfinite(b) && std::fabs(a - b) <= tolerance;
}
}

int main() {
    const float rates[] = { 8000, 44100, 48000, 88200, 96000, 176400,
        192000, 352800, 384000, 705600, 768000 };
    for (float rate : rates) {
        for (float x : { -3.0f, 0.0f, 3.0f }) {
            for (float z : { -2.8f, 0.0f, 1.8f, 2.8f }) {
                for (float width : { 0.6f, 1.65f, 3.0f }) {
                    for (float amount : { 0.0f, 35.0f, 100.0f }) {
                        LCSpatialGeometryInput input { 1, x, z, width, amount };
                        LCSpatialGeometryResult result{}, mirror{};
                        check(lowend::calculateSpatialGeometry(rate, input,
                            LC_SPATIAL_DEFAULT_DELAY_CAPACITY, result), "valid grid input accepted");
                        input.listenerX = -x;
                        check(lowend::calculateSpatialGeometry(rate, input,
                            LC_SPATIAL_DEFAULT_DELAY_CAPACITY, mirror), "mirrored input accepted");
                        check(near(result.ll.gain, mirror.rr.gain)
                            && near(result.lr.gain, mirror.rl.gain), "left/right mirror gain");
                        check(result.ll.appliedDelaySamples == mirror.rr.appliedDelaySamples
                            && result.lr.appliedDelaySamples == mirror.rl.appliedDelaySamples,
                            "left/right mirror delay");
                        uint32_t minimumDelay = UINT32_MAX;
                        for (const auto* path : { &result.ll, &result.lr, &result.rl, &result.rr }) {
                            minimumDelay = std::min(minimumDelay, path->appliedDelaySamples);
                            check(std::isfinite(path->gain) && path->gain > 0,
                                  "path gain finite and positive");
                            check(path->effectiveDistanceMeters >= 0.12f,
                                  "effective distance lower bound");
                            check(path->appliedDelaySamples == path->requestedDelaySamples,
                                  "supported geometry fits default delay capacity");
                            check(near(path->appliedDelayMs,
                                float(path->appliedDelaySamples) / rate * 1000),
                                "displayed ms derives from applied integer samples");
                        }
                        check(minimumDelay == 0, "shortest path has exactly zero relative delay");
                        check(result.settings.ll.delaySamples == result.ll.appliedDelaySamples
                            && result.settings.lr.delaySamples == result.lr.appliedDelaySamples
                            && result.settings.rl.delaySamples == result.rl.appliedDelaySamples
                            && result.settings.rr.delaySamples == result.rr.appliedDelaySamples,
                            "audio POD and preview delay are identical");
                        check(result.settings.ll.gain == result.ll.gain
                            && result.settings.lr.gain == result.lr.gain
                            && result.settings.rl.gain == result.rl.gain
                            && result.settings.rr.gain == result.rr.gain,
                            "audio POD and preview gain are identical");
                    }
                }
            }
        }
    }

    LCSpatialGeometryInput input { 1, 3, 1.8f, 3, 100 };
    LCSpatialGeometryResult result{};
    check(lowend::calculateSpatialGeometry(768000, input, 8192, result), "maximum rate accepted");
    check(result.lr.requestedDelaySamples == 7120 && result.lr.appliedDelaySamples == 7120,
          "maximum path offset has independently calculated 7120 samples");
    check(lowend::calculateSpatialGeometry(384000, input, 2048, result), "small capacity accepted");
    check(result.lr.requestedDelaySamples == 3560 && result.lr.appliedDelaySamples == 2047
        && result.settings.lr.delaySamples == 2047, "clamped applied delay is disclosed and carried to audio");

    input = { 1, -0.21f, 1.8f, 0.6f, 35 };
    check(lowend::calculateSpatialGeometry(48000, input, 8192, result), "coincident source and ear accepted");
    check(result.ll.rawDistanceMeters < 0.000001f && result.ll.effectiveDistanceMeters == 0.12f,
          "geometric zero and DSP distance floor are distinct");

    input = { 1, 99, -99, 99, 200 };
    check(lowend::calculateSpatialGeometry(48000, input, 8192, result), "finite controls clamp");
    check(near(result.leftEar.x, 2.91f) && near(result.leftEar.z, -2.8f)
        && result.rightSpeaker.x == 1.5f && result.amount == 1,
        "all position, width, and amount bounds applied");

    for (float invalid : { 0.0f, -1.0f, 768001.0f,
        std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity() }) {
        check(!lowend::calculateSpatialGeometry(invalid, input, 8192, result),
              "invalid sample rate rejected");
        check(result.sampleRate == 0 && result.settings.enabled == 0,
              "invalid call clears stale result");
    }
    input.listenerX = std::numeric_limits<float>::quiet_NaN();
    check(!lowend::calculateSpatialGeometry(48000, input, 8192, result), "NaN position rejected");
    input.listenerX = 0;
    check(!lowend::calculateSpatialGeometry(48000, input, 1, result), "invalid capacity rejected");
    input.enabled = 0;
    check(lowend::calculateSpatialGeometry(48000, input, 8192, result)
        && result.settings.enabled == 0, "disabled geometry still available for preview");
    const auto legacy = lowend::DSPPrecompute::makeSpatialSettings(48000,
        input.listenerX, input.listenerZ, input.speakerWidth, input.amount, false);
    check(legacy.lr.delaySamples == result.settings.lr.delaySamples
        && legacy.lr.gain == result.settings.lr.gain,
        "legacy spatial precompute delegates to the authoritative geometry");

    std::printf("test_spatial_geometry: %d failure(s)\n", failures);
    return failures ? 1 : 0;
}
