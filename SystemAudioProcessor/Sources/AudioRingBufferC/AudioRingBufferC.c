#include "AudioRingBufferC.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct LCLockFreeRingBuffer {
    float *storage;
    uint32_t capacity;
    uint32_t mask;
    atomic_uint_fast64_t readIndex;
    atomic_uint_fast64_t writeIndex;
};

struct LCControlEventQueue {
    LCControlEvent *storage;
    uint32_t capacity;
    uint32_t mask;
    atomic_uint_fast64_t readIndex;
    atomic_uint_fast64_t writeIndex;
};

static uint32_t next_power_of_two(uint32_t value) {
    if (value < 2) {
        return 2;
    }

    value--;
    value |= value >> 1;
    value |= value >> 2;
    value |= value >> 4;
    value |= value >> 8;
    value |= value >> 16;
    value++;
    return value;
}

LCLockFreeRingBuffer *lc_ring_buffer_create(uint32_t requestedCapacitySamples) {
    LCLockFreeRingBuffer *ringBuffer = (LCLockFreeRingBuffer *)calloc(1, sizeof(LCLockFreeRingBuffer));
    if (ringBuffer == NULL) {
        return NULL;
    }

    const uint32_t capacity = next_power_of_two(requestedCapacitySamples);
    ringBuffer->storage = (float *)calloc(capacity, sizeof(float));
    if (ringBuffer->storage == NULL) {
        free(ringBuffer);
        return NULL;
    }

    ringBuffer->capacity = capacity;
    ringBuffer->mask = capacity - 1;
    atomic_init(&ringBuffer->readIndex, 0);
    atomic_init(&ringBuffer->writeIndex, 0);
    return ringBuffer;
}

void lc_ring_buffer_destroy(LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return;
    }

    free(ringBuffer->storage);
    free(ringBuffer);
}

uint32_t lc_ring_buffer_capacity(const LCLockFreeRingBuffer *ringBuffer) {
    return ringBuffer == NULL ? 0 : ringBuffer->capacity;
}

uint32_t lc_ring_buffer_available(const LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_acquire);
    const uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_acquire);
    const uint64_t available = writeIndex - readIndex;
    return available > ringBuffer->capacity ? ringBuffer->capacity : (uint32_t)available;
}

uint32_t lc_ring_buffer_write_available(const LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    return ringBuffer->capacity - lc_ring_buffer_available(ringBuffer);
}

uint32_t lc_ring_buffer_push(LCLockFreeRingBuffer *ringBuffer, const float *samples, uint32_t sampleCount) {
    if (ringBuffer == NULL || samples == NULL || sampleCount == 0) {
        return 0;
    }

    const uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_acquire);
    uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_relaxed);
    const uint64_t available = writeIndex - readIndex;
    const uint32_t writable = available >= ringBuffer->capacity ? 0 : ringBuffer->capacity - (uint32_t)available;
    const uint32_t samplesToWrite = sampleCount < writable ? sampleCount : writable;

    if (samplesToWrite == 0) {
        return 0;
    }

    for (uint32_t index = 0; index < samplesToWrite; ++index) {
        ringBuffer->storage[(writeIndex + index) & ringBuffer->mask] = samples[index];
    }

    atomic_store_explicit(&ringBuffer->writeIndex, writeIndex + samplesToWrite, memory_order_release);
    return samplesToWrite;
}

uint32_t lc_ring_buffer_push_stereo_frame(LCLockFreeRingBuffer *ringBuffer, float left, float right) {
    if (ringBuffer == NULL) {
        return 0;
    }

    const uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_acquire);
    const uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_relaxed);
    const uint64_t available = writeIndex - readIndex;

    if (available + 2 > ringBuffer->capacity) {
        return 0;
    }

    ringBuffer->storage[writeIndex & ringBuffer->mask] = left;
    ringBuffer->storage[(writeIndex + 1) & ringBuffer->mask] = right;
    atomic_store_explicit(&ringBuffer->writeIndex, writeIndex + 2, memory_order_release);
    return 2;
}

uint32_t lc_ring_buffer_pop(LCLockFreeRingBuffer *ringBuffer, float *destination, uint32_t sampleCount) {
    if (ringBuffer == NULL || destination == NULL || sampleCount == 0) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_acquire);
    uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_relaxed);
    const uint64_t available = writeIndex - readIndex;
    const uint32_t readable = available < sampleCount ? (uint32_t)available : sampleCount;

    for (uint32_t index = 0; index < readable; ++index) {
        destination[index] = ringBuffer->storage[(readIndex + index) & ringBuffer->mask];
    }

    if (readable < sampleCount) {
        memset(destination + readable, 0, (sampleCount - readable) * sizeof(float));
    }

    atomic_store_explicit(&ringBuffer->readIndex, readIndex + readable, memory_order_release);
    return readable;
}

uint32_t lc_ring_buffer_pop_deinterleaved_stereo(LCLockFreeRingBuffer *ringBuffer,
                                                 float *left,
                                                 float *right,
                                                 uint32_t frameCount) {
    if (ringBuffer == NULL || left == NULL || right == NULL || frameCount == 0) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_acquire);
    uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_relaxed);
    const uint64_t availableSamples = writeIndex - readIndex;
    const uint32_t availableFrames = (uint32_t)(availableSamples / 2);
    const uint32_t readableFrames = availableFrames < frameCount ? availableFrames : frameCount;

    for (uint32_t frame = 0; frame < readableFrames; ++frame) {
        left[frame] = ringBuffer->storage[(readIndex + frame * 2) & ringBuffer->mask];
        right[frame] = ringBuffer->storage[(readIndex + frame * 2 + 1) & ringBuffer->mask];
    }

    if (readableFrames < frameCount) {
        memset(left + readableFrames, 0, (frameCount - readableFrames) * sizeof(float));
        memset(right + readableFrames, 0, (frameCount - readableFrames) * sizeof(float));
    }

    atomic_store_explicit(&ringBuffer->readIndex, readIndex + readableFrames * 2, memory_order_release);
    return readableFrames;
}

void lc_ring_buffer_clear(LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return;
    }

    memset(ringBuffer->storage, 0, ringBuffer->capacity * sizeof(float));
    atomic_store_explicit(&ringBuffer->readIndex, 0, memory_order_release);
    atomic_store_explicit(&ringBuffer->writeIndex, 0, memory_order_release);
}

LCControlEventQueue *lc_control_event_queue_create(uint32_t requestedCapacityEvents) {
    LCControlEventQueue *queue = (LCControlEventQueue *)calloc(1, sizeof(LCControlEventQueue));
    if (queue == NULL) {
        return NULL;
    }

    const uint32_t capacity = next_power_of_two(requestedCapacityEvents);
    queue->storage = (LCControlEvent *)calloc(capacity, sizeof(LCControlEvent));
    if (queue->storage == NULL) {
        free(queue);
        return NULL;
    }

    queue->capacity = capacity;
    queue->mask = capacity - 1;
    atomic_init(&queue->readIndex, 0);
    atomic_init(&queue->writeIndex, 0);
    return queue;
}

void lc_control_event_queue_destroy(LCControlEventQueue *queue) {
    if (queue == NULL) {
        return;
    }

    free(queue->storage);
    free(queue);
}

uint32_t lc_control_event_queue_push(LCControlEventQueue *queue, const LCControlEvent *event) {
    if (queue == NULL || event == NULL) {
        return 0;
    }

    const uint64_t readIndex = atomic_load_explicit(&queue->readIndex, memory_order_acquire);
    const uint64_t writeIndex = atomic_load_explicit(&queue->writeIndex, memory_order_relaxed);

    if (writeIndex - readIndex >= queue->capacity) {
        return 0;
    }

    queue->storage[writeIndex & queue->mask] = *event;
    atomic_store_explicit(&queue->writeIndex, writeIndex + 1, memory_order_release);
    return 1;
}

uint32_t lc_control_event_queue_pop(LCControlEventQueue *queue, LCControlEvent *event) {
    if (queue == NULL || event == NULL) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&queue->writeIndex, memory_order_acquire);
    const uint64_t readIndex = atomic_load_explicit(&queue->readIndex, memory_order_relaxed);

    if (writeIndex == readIndex) {
        return 0;
    }

    *event = queue->storage[readIndex & queue->mask];
    atomic_store_explicit(&queue->readIndex, readIndex + 1, memory_order_release);
    return 1;
}

uint32_t lc_control_event_queue_available(const LCControlEventQueue *queue) {
    if (queue == NULL) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&queue->writeIndex, memory_order_acquire);
    const uint64_t readIndex = atomic_load_explicit(&queue->readIndex, memory_order_acquire);
    const uint64_t available = writeIndex - readIndex;
    return available > queue->capacity ? queue->capacity : (uint32_t)available;
}
