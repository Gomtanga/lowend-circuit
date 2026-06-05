#ifndef AUDIO_RING_BUFFER_C_H
#define AUDIO_RING_BUFFER_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LCLockFreeRingBuffer LCLockFreeRingBuffer;
typedef struct LCControlEventQueue LCControlEventQueue;

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
void lc_ring_buffer_clear(LCLockFreeRingBuffer *ringBuffer);

LCControlEventQueue *lc_control_event_queue_create(uint32_t requestedCapacityEvents);
void lc_control_event_queue_destroy(LCControlEventQueue *queue);
uint32_t lc_control_event_queue_push(LCControlEventQueue *queue, const LCControlEvent *event);
uint32_t lc_control_event_queue_pop(LCControlEventQueue *queue, LCControlEvent *event);
uint32_t lc_control_event_queue_available(const LCControlEventQueue *queue);

#ifdef __cplusplus
}
#endif

#endif
