#include "StageProbe.h"
#include <malloc/malloc.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Separate image: dyld must interpose these imported allocator/lock symbols.
// -fno-builtin preserves the deliberately unused allocation canaries.
void stage_canary_calls(void) {
    void *a = malloc(31); memset(a, 0x42, 31); a = realloc(a, 63); free(a);
    void *b = calloc(3, 19); free(b);
    malloc_zone_t *z = malloc_default_zone();
    void *c = malloc_zone_malloc(z, 47); c = malloc_zone_realloc(z, c, 93); malloc_zone_free(z, c);
    void *d = malloc_zone_calloc(z, 5, 17); malloc_zone_free(z, d);
    pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&m); pthread_mutex_unlock(&m);
    pthread_mutex_trylock(&m); pthread_mutex_unlock(&m); pthread_mutex_destroy(&m);
    os_unfair_lock l = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&l); os_unfair_lock_unlock(&l);
    if (os_unfair_lock_trylock(&l)) os_unfair_lock_unlock(&l);
    void *e = aligned_alloc(64, 128); free(e);
    if (posix_memalign(&e, 64, 128) == 0) free(e);
    e = malloc_zone_memalign(z, 64, 128); malloc_zone_free(z, e);
    e = malloc_type_malloc(64, 1); e = malloc_type_realloc(e, 128, 1); free(e);
    e = malloc_type_calloc(2, 64, 1); free(e);
    e = malloc_type_aligned_alloc(64, 128, 1); free(e);
    if (malloc_type_posix_memalign(&e, 64, 128, 1) == 0) free(e);
    e = malloc_type_zone_malloc(z, 64, 1); e = malloc_type_zone_realloc(z, e, 128, 1); malloc_zone_free(z, e);
    e = malloc_type_zone_calloc(z, 2, 64, 1); malloc_zone_free(z, e);
    e = malloc_type_zone_memalign(z, 64, 128, 1); malloc_zone_free(z, e);
    e = malloc_zone_malloc_with_options(z, 64, 128, MALLOC_ZONE_MALLOC_OPTION_NONE); malloc_zone_free(z, e);
    e = malloc_type_zone_malloc_with_options(z, 64, 128, 1, MALLOC_ZONE_MALLOC_OPTION_NONE); malloc_zone_free(z, e);
}

float stage_canary_touch(float *p) {
    p[0] = 42; p[4095] = 37;
    return p[0] + p[4095];
}
