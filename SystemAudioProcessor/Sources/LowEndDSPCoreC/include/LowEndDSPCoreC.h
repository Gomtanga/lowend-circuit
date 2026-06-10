#ifndef LOW_END_DSP_CORE_C_H
#define LOW_END_DSP_CORE_C_H

#include <stdint.h>
#include "AudioRingBufferC.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LCDSPCore LCDSPCore;

LCDSPCore *lc_dsp_core_create(void);
void lc_dsp_core_destroy(LCDSPCore *core);
void lc_dsp_core_prepare(LCDSPCore *core, double sampleRate, uint32_t maxChannels);
void lc_dsp_core_precompute(float sampleRate,
                            float intensity,
                            float body,
                            float outputDb,
                            uint32_t dspModel,
                            LCDSPSettings *settings);
void lc_dsp_core_update(LCDSPCore *core, const LCDSPSettings *settings);
void lc_dsp_core_process_stereo(LCDSPCore *core,
                                float *left,
                                float *right,
                                uint32_t frameCount);
void lc_dsp_core_reset(LCDSPCore *core);

#ifdef __cplusplus
}
#endif

#endif
