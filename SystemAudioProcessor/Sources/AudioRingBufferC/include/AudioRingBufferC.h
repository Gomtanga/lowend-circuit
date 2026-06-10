#ifndef AUDIO_RING_BUFFER_C_H
#define AUDIO_RING_BUFFER_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LCLockFreeRingBuffer LCLockFreeRingBuffer;
typedef struct LCControlEventQueue LCControlEventQueue;
typedef struct LCSpectrumSnapshot LCSpectrumSnapshot;

enum {
    LC_SPECTRUM_BIN_COUNT = 128
};

enum {
    LC_CONTROL_EVENT_DSP = 1,
    LC_CONTROL_EVENT_SPATIAL = 2
};

typedef struct {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
} LCBiquadCoefficients;

typedef struct {
    float intensity;
    float body;
    float outputGain;
    float headroomGain;
    uint32_t dspModel;
    LCBiquadCoefficients shelf;
    float warmthAmount;
    float virtualFeedbackGain;
    float bodyInjectionGain;
    float circuitHeadroomGain;
    float drive;
    float wetMix;
    float bassAlpha;
    float subAlpha;
    LCBiquadCoefficients transformerPreEmphasis;
    LCBiquadCoefficients transformerDeEmphasis;
    float transformerDrive;
    float transformerAsymmetry;
    float transformerBiasOffset;
    float transformerMakeupGain;
    LCBiquadCoefficients exciterHighPass;
    float exciterDrive;
    float exciterWetMix;
    uint32_t exciterOversampleFactor;
    LCBiquadCoefficients exciterStage1LowPass1;
    LCBiquadCoefficients exciterStage1LowPass2;
    LCBiquadCoefficients exciterStage2LowPass1;
    LCBiquadCoefficients exciterStage2LowPass2;
} LCDSPSettings;

typedef struct {
    uint32_t delaySamples;
    float gain;
} LCSpatialPathSettings;

typedef struct {
    uint32_t enabled;
    float amount;
    LCSpatialPathSettings ll;
    LCSpatialPathSettings lr;
    LCSpatialPathSettings rl;
    LCSpatialPathSettings rr;
} LCSpatialSettings;

typedef struct {
    uint32_t type;
    LCDSPSettings dsp;
    LCSpatialSettings spatial;
} LCControlEvent;

LCLockFreeRingBuffer *lc_ring_buffer_create(uint32_t requestedCapacitySamples);
void lc_ring_buffer_destroy(LCLockFreeRingBuffer *ringBuffer);
uint32_t lc_ring_buffer_capacity(const LCLockFreeRingBuffer *ringBuffer);
uint32_t lc_ring_buffer_available(const LCLockFreeRingBuffer *ringBuffer);
uint32_t lc_ring_buffer_write_available(const LCLockFreeRingBuffer *ringBuffer);
uint32_t lc_ring_buffer_push(LCLockFreeRingBuffer *ringBuffer, const float *samples, uint32_t sampleCount);
uint32_t lc_ring_buffer_push_stereo_frame(LCLockFreeRingBuffer *ringBuffer, float left, float right);
uint32_t lc_ring_buffer_pop(LCLockFreeRingBuffer *ringBuffer, float *destination, uint32_t sampleCount);
uint32_t lc_ring_buffer_pop_deinterleaved_stereo(LCLockFreeRingBuffer *ringBuffer,
                                                 float *left,
                                                 float *right,
                                                 uint32_t frameCount);
uint64_t lc_ring_buffer_dropped_write_samples(const LCLockFreeRingBuffer *ringBuffer);
uint64_t lc_ring_buffer_underrun_samples(const LCLockFreeRingBuffer *ringBuffer);
void lc_ring_buffer_reset_diagnostics(LCLockFreeRingBuffer *ringBuffer);
void lc_ring_buffer_clear(LCLockFreeRingBuffer *ringBuffer);

LCControlEventQueue *lc_control_event_queue_create(uint32_t requestedCapacityEvents);
void lc_control_event_queue_destroy(LCControlEventQueue *queue);
uint32_t lc_control_event_queue_push(LCControlEventQueue *queue, const LCControlEvent *event);
uint32_t lc_control_event_queue_pop(LCControlEventQueue *queue, LCControlEvent *event);
uint32_t lc_control_event_queue_available(const LCControlEventQueue *queue);

LCSpectrumSnapshot *lc_spectrum_snapshot_create(void);
void lc_spectrum_snapshot_destroy(LCSpectrumSnapshot *snapshot);
void lc_spectrum_snapshot_publish(LCSpectrumSnapshot *snapshot, const float *values, uint32_t count);
uint32_t lc_spectrum_snapshot_copy(const LCSpectrumSnapshot *snapshot, float *destination, uint32_t count);
uint32_t lc_spectrum_snapshot_copy_if_new(const LCSpectrumSnapshot *snapshot,
                                          float *destination,
                                          uint32_t count,
                                          uint64_t previousSequence,
                                          uint64_t *newSequence);
void lc_spectrum_snapshot_set_active(LCSpectrumSnapshot *snapshot, uint32_t active);
uint32_t lc_spectrum_snapshot_is_active(const LCSpectrumSnapshot *snapshot);
void lc_spectrum_snapshot_clear(LCSpectrumSnapshot *snapshot);

#ifdef __cplusplus
}
#endif

#endif
