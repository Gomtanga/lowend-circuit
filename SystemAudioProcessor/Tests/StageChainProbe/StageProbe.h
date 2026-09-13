#pragma once
#include <stdint.h>
typedef struct {
    uint64_t mallocCalls, callocCalls, reallocCalls, freeCalls;
    uint64_t zoneMallocCalls, zoneCallocCalls, zoneReallocCalls;
    uint64_t mutexLockCalls, mutexTryLockCalls, unfairLockCalls, unfairTryLockCalls;
    uint64_t otherAllocatorCalls;
} StageProbeCounts;
typedef struct { uint64_t wallTicks, cpuNanos; } StageProbeClock;
void stage_probe_begin(void);
StageProbeCounts stage_probe_end(void);
StageProbeClock stage_probe_clock(void);
double stage_probe_nanoseconds_per_tick(void);
void stage_canary_calls(void);
float stage_canary_touch(float *pointer);
void stage_probe_enable_trace(void);
void stage_probe_print_trace(void);
typedef void (*StageProbeThreadFunction)(void *context);
int stage_probe_on_fresh_thread(void *context, StageProbeThreadFunction function);
