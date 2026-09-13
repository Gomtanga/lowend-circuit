#include "StageProbe.h"
#include <mach/mach_time.h>
#include <malloc/malloc.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <execinfo.h>
#include <stdio.h>

// This dylib is linked only into the dedicated, offline probe executable.
// Check an ordinary static flag before touching any thread identity: Darwin's
// dynamic TLS initialization can itself lock during process startup. Only the
// selected measuring thread writes these preallocated counters.
static atomic_int active;
static _Atomic(pthread_t) selectedThread;
static StageProbeCounts counts;
static int traceEnabled, traceDepth;
static void *traceFrames[32];
static void capture_first_trace(void) {
    if (traceEnabled && traceDepth == 0) {
        traceDepth = -1;
        atomic_store_explicit(&active, 0, memory_order_release);
        traceDepth = backtrace(traceFrames, 32);
        atomic_store_explicit(&active, 1, memory_order_release);
    }
}
#define RECORD(field) do { \
    if (atomic_load_explicit(&active, memory_order_acquire) && \
        pthread_equal(pthread_self(), atomic_load_explicit(&selectedThread, memory_order_relaxed))) { counts.field++; capture_first_trace(); } \
} while (0)
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *newFunction; const void *oldFunction; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&original };

static void *probe_malloc(size_t n) { RECORD(mallocCalls); return malloc(n); }
static void *probe_calloc(size_t n, size_t s) { RECORD(callocCalls); return calloc(n, s); }
static void *probe_realloc(void *p, size_t n) { RECORD(reallocCalls); return realloc(p, n); }
static void probe_free(void *p) { RECORD(freeCalls); free(p); }
static void *probe_zone_malloc(malloc_zone_t *z, size_t n) { RECORD(zoneMallocCalls); return malloc_zone_malloc(z, n); }
static void *probe_zone_calloc(malloc_zone_t *z, size_t n, size_t s) { RECORD(zoneCallocCalls); return malloc_zone_calloc(z, n, s); }
static void *probe_zone_realloc(malloc_zone_t *z, void *p, size_t n) { RECORD(zoneReallocCalls); return malloc_zone_realloc(z, p, n); }
static int probe_mutex_lock(pthread_mutex_t *m) { RECORD(mutexLockCalls); return pthread_mutex_lock(m); }
static int probe_mutex_trylock(pthread_mutex_t *m) { RECORD(mutexTryLockCalls); return pthread_mutex_trylock(m); }
static void probe_unfair_lock(os_unfair_lock_t l) { RECORD(unfairLockCalls); os_unfair_lock_lock(l); }
static bool probe_unfair_trylock(os_unfair_lock_t l) { RECORD(unfairTryLockCalls); return os_unfair_lock_trylock(l); }
INTERPOSE(probe_malloc, malloc)
INTERPOSE(probe_calloc, calloc)
INTERPOSE(probe_realloc, realloc)
INTERPOSE(probe_free, free)
INTERPOSE(probe_zone_malloc, malloc_zone_malloc)
INTERPOSE(probe_zone_calloc, malloc_zone_calloc)
INTERPOSE(probe_zone_realloc, malloc_zone_realloc)
INTERPOSE(probe_mutex_lock, pthread_mutex_lock)
INTERPOSE(probe_mutex_trylock, pthread_mutex_trylock)
INTERPOSE(probe_unfair_lock, os_unfair_lock_lock)
INTERPOSE(probe_unfair_trylock, os_unfair_lock_trylock)
static void * probe_aligned_alloc(size_t a, size_t n) { RECORD(otherAllocatorCalls); return aligned_alloc(a, n); }
INTERPOSE(probe_aligned_alloc, aligned_alloc)
static int probe_posix_memalign(void **p, size_t a, size_t n) { RECORD(otherAllocatorCalls); return posix_memalign(p, a, n); }
INTERPOSE(probe_posix_memalign, posix_memalign)
static void * probe_malloc_zone_memalign(malloc_zone_t *z, size_t a, size_t n) { RECORD(otherAllocatorCalls); return malloc_zone_memalign(z, a, n); }
INTERPOSE(probe_malloc_zone_memalign, malloc_zone_memalign)
static void * probe_malloc_type_malloc(size_t n, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_malloc(n, t); }
INTERPOSE(probe_malloc_type_malloc, malloc_type_malloc)
static void * probe_malloc_type_calloc(size_t n, size_t s, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_calloc(n, s, t); }
INTERPOSE(probe_malloc_type_calloc, malloc_type_calloc)
static void * probe_malloc_type_realloc(void *p, size_t n, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_realloc(p, n, t); }
INTERPOSE(probe_malloc_type_realloc, malloc_type_realloc)
static void * probe_malloc_type_aligned_alloc(size_t a, size_t n, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_aligned_alloc(a, n, t); }
INTERPOSE(probe_malloc_type_aligned_alloc, malloc_type_aligned_alloc)
static int probe_malloc_type_posix_memalign(void **p, size_t a, size_t n, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_posix_memalign(p, a, n, t); }
INTERPOSE(probe_malloc_type_posix_memalign, malloc_type_posix_memalign)
static void * probe_malloc_type_zone_malloc(malloc_zone_t *z, size_t n, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_zone_malloc(z, n, t); }
INTERPOSE(probe_malloc_type_zone_malloc, malloc_type_zone_malloc)
static void * probe_malloc_type_zone_calloc(malloc_zone_t *z, size_t n, size_t s, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_zone_calloc(z, n, s, t); }
INTERPOSE(probe_malloc_type_zone_calloc, malloc_type_zone_calloc)
static void * probe_malloc_type_zone_realloc(malloc_zone_t *z, void *p, size_t n, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_zone_realloc(z, p, n, t); }
INTERPOSE(probe_malloc_type_zone_realloc, malloc_type_zone_realloc)
static void * probe_malloc_type_zone_memalign(malloc_zone_t *z, size_t a, size_t n, malloc_type_id_t t) { RECORD(otherAllocatorCalls); return malloc_type_zone_memalign(z, a, n, t); }
INTERPOSE(probe_malloc_type_zone_memalign, malloc_type_zone_memalign)
static void * probe_malloc_zone_malloc_with_options(malloc_zone_t *z, size_t a, size_t n, malloc_zone_malloc_options_t o) { RECORD(otherAllocatorCalls); return malloc_zone_malloc_with_options(z, a, n, o); }
INTERPOSE(probe_malloc_zone_malloc_with_options, malloc_zone_malloc_with_options)
static void * probe_malloc_type_zone_malloc_with_options(malloc_zone_t *z, size_t a, size_t n, malloc_type_id_t t, malloc_zone_malloc_options_t o) { RECORD(otherAllocatorCalls); return malloc_type_zone_malloc_with_options(z, a, n, t, o); }
INTERPOSE(probe_malloc_type_zone_malloc_with_options, malloc_type_zone_malloc_with_options)

void stage_probe_begin(void) {
    atomic_store_explicit(&active, 0, memory_order_release);
    atomic_store_explicit(&selectedThread, pthread_self(), memory_order_relaxed);
    memset(&counts, 0, sizeof(counts));
    atomic_store_explicit(&active, 1, memory_order_release);
}
StageProbeCounts stage_probe_end(void) {
    atomic_store_explicit(&active, 0, memory_order_release); return counts;
}
StageProbeClock stage_probe_clock(void) {
    struct timespec t = {0};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return (StageProbeClock){ mach_absolute_time(), (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec };
}
double stage_probe_nanoseconds_per_tick(void) {
    mach_timebase_info_data_t t; mach_timebase_info(&t);
    return (double)t.numer / (double)t.denom;
}
void stage_probe_enable_trace(void) {
    void *warmup[32]; backtrace(warmup, 32);
    traceDepth = 0; traceEnabled = 1;
}
void stage_probe_print_trace(void) {
    if (traceDepth > 0) {
        fprintf(stderr, "First measured intercepted call; DIAGNOSTIC RUN ONLY, exclude these timings:\n");
        backtrace_symbols_fd(traceFrames, traceDepth, 2);
    }
    traceEnabled = 0;
}
typedef struct { void *context; StageProbeThreadFunction function; } ProbeThreadArgs;
static void *fresh_thread_entry(void *opaque) {
    ProbeThreadArgs *args = opaque;
    args->function(args->context);
    return NULL;
}
int stage_probe_on_fresh_thread(void *context, StageProbeThreadFunction function) {
    ProbeThreadArgs args = { context, function };
    pthread_t thread;
    int result = pthread_create(&thread, NULL, fresh_thread_entry, &args);
    if (result != 0) return result;
    return pthread_join(thread, NULL);
}
