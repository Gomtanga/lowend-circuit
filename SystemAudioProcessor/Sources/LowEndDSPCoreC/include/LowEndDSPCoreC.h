#ifndef LOW_END_DSP_CORE_C_H
#define LOW_END_DSP_CORE_C_H

#include <stdint.h>
#include "AudioRingBufferC.h"
#include "../../../../Source/Core/include/Core/SpatialGeometry.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LCDSPCore LCDSPCore;

// One processor has one serialized owner: prepare/update/process/reset/destroy
// must never overlap on the same instance. In a real-time host, create/prepare
// and destroy run on the control thread while callbacks are quiescent; apply
// a precomputed update on the processing thread at a block boundary. The API
// provides no internal synchronization or lifetime management for its caller.
// Prepare before processing, with a finite supported rate and maxChannels >= 2
// for process_stereo. Stereo arrays are writable, non-overlapping caller-owned
// buffers containing at least frameCount floats, valid until the call returns.
// NULL core/buffer and zero-frame process calls are ignored. NULL create result
// denotes allocation failure. Destroy is valid only after all possible users
// (including registered callbacks) can no longer obtain the instance.
LCDSPCore *lc_dsp_core_create(void);
void lc_dsp_core_destroy(LCDSPCore *core);
void lc_dsp_core_prepare(LCDSPCore *core, double sampleRate, uint32_t maxChannels);
// Precompute is independent of a processor and may run on a UI/control thread.
// Each caller exclusively owns its output POD during the call; publish the whole
// completed snapshot to the audio owner. Settings use the headers from the same
// build and are not a stable on-disk or cross-version ABI. NULL output is ignored.
void lc_dsp_core_precompute(float sampleRate,
                            float intensity,
                            float body,
                            float outputDb,
                            uint32_t dspModel,
                            LCDSPSettings *settings);
void lc_dsp_core_precompute_with_oversampling(float sampleRate,
                                              float intensity,
                                              float body,
                                              float outputDb,
                                              uint32_t dspModel,
                                              uint32_t exciterOversamplingMode,
                                              LCDSPSettings *settings);
void lc_dsp_core_update(LCDSPCore *core, const LCDSPSettings *settings);
void lc_dsp_core_process_stereo(LCDSPCore *core,
                                float *left,
                                float *right,
                                uint32_t frameCount);
void lc_dsp_core_reset(LCDSPCore *core);

// Control/UI-thread geometry snapshot. Returns 1 on success, 0 for an invalid
// argument. Invalid input clears a non-null result; no C++ exception escapes.
uint32_t lc_spatial_geometry_precompute(float sampleRate,
                                       const LCSpatialGeometryInput *input,
                                       uint32_t delayCapacity,
                                       LCSpatialGeometryResult *result);

#ifdef __cplusplus
}
#endif

#endif
