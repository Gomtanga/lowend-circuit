#ifndef AUDIO_RING_BUFFER_C_H
#define AUDIO_RING_BUFFER_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LCLockFreeRingBuffer LCLockFreeRingBuffer;

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

#ifdef __cplusplus
}
#endif

#endif
