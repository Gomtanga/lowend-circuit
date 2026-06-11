#include "include/LowEndDSPCoreC.h"

#include "../../../Source/Core/src/Core.cpp"
#include "../../../Source/Core/src/CircuitBass.cpp"
#include "../../../Source/Core/src/HighExciter.cpp"
#include "../../../Source/Core/src/Processor.cpp"

#include <new>

struct LCDSPCore {
    lowend::Processor processor;
};

LCDSPCore *lc_dsp_core_create(void) {
    return new (std::nothrow) LCDSPCore();
}

void lc_dsp_core_destroy(LCDSPCore *core) {
    delete core;
}

void lc_dsp_core_prepare(LCDSPCore *core, double sampleRate, uint32_t maxChannels) {
    if (core == nullptr) {
        return;
    }
    core->processor.prepare(sampleRate, maxChannels);
}

void lc_dsp_core_precompute(float sampleRate,
                            float intensity,
                            float body,
                            float outputDb,
                            uint32_t dspModel,
                            LCDSPSettings *settings) {
    if (settings == nullptr) {
        return;
    }
    *settings = lowend::DSPPrecompute::makeDSPSettings(
        sampleRate, intensity, body, outputDb, dspModel);
}

void lc_dsp_core_precompute_with_oversampling(float sampleRate,
                                              float intensity,
                                              float body,
                                              float outputDb,
                                              uint32_t dspModel,
                                              uint32_t exciterOversamplingMode,
                                              LCDSPSettings *settings) {
    if (settings == nullptr) {
        return;
    }
    *settings = lowend::DSPPrecompute::makeDSPSettings(
        sampleRate, intensity, body, outputDb, dspModel, exciterOversamplingMode);
}

void lc_dsp_core_update(LCDSPCore *core, const LCDSPSettings *settings) {
    if (core == nullptr || settings == nullptr) {
        return;
    }
    core->processor.update(*settings);
}

void lc_dsp_core_process_stereo(LCDSPCore *core,
                                float *left,
                                float *right,
                                uint32_t frameCount) {
    if (core == nullptr || left == nullptr || right == nullptr || frameCount == 0) {
        return;
    }
    float* channels[] = { left, right };
    core->processor.process(channels, frameCount);
}

void lc_dsp_core_reset(LCDSPCore *core) {
    if (core == nullptr) {
        return;
    }
    core->processor.reset();
}
