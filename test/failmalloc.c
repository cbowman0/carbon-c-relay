/*
 * failmalloc.c — LD_PRELOAD library for malloc/strdup failure injection
 *
 * Randomly returns NULL from malloc, calloc, realloc, and strdup after
 * a configurable number of successful allocations. Used to test error
 * handling paths (B3, B5, B6, B7).
 *
 * Environment variables:
 *   FAILMALLOC_THRESHOLD   Number of successful allocations before failures
 *                          start. Default: 500.
 *   FAILMALLOC_PROBABILITY Probability (0-100) of any given allocation failing
 *                          once the threshold is reached. Default: 5 (5%).
 *
 * Build:
 *   gcc -shared -fPIC -o failmalloc.so failmalloc.c -ldl
 *
 * Use:
 *   LD_PRELOAD=./test/failmalloc.so FAILMALLOC_THRESHOLD=200 ./relay -f ...
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>

static void *(*real_malloc)(size_t) = NULL;
static void *(*real_calloc)(size_t, size_t) = NULL;
static void *(*real_realloc)(void *, size_t) = NULL;
static char *(*real_strdup)(const char *) = NULL;

static unsigned long alloc_count = 0;
static unsigned long threshold = 500;
static int probability = 5;
static int initialised = 0;

/* Use a static buffer for calloc during init to avoid recursion */
static char init_buf[4096];
static int init_buf_used = 0;

static void
fm_init(void)
{
    if (initialised)
        return;
    initialised = 1;

    real_malloc  = dlsym(RTLD_NEXT, "malloc");
    real_calloc  = dlsym(RTLD_NEXT, "calloc");
    real_realloc = dlsym(RTLD_NEXT, "realloc");
    real_strdup  = dlsym(RTLD_NEXT, "strdup");

    const char *t = getenv("FAILMALLOC_THRESHOLD");
    if (t != NULL)
        threshold = (unsigned long)atol(t);

    const char *p = getenv("FAILMALLOC_PROBABILITY");
    if (p != NULL)
        probability = atoi(p);

    fprintf(stderr, "[failmalloc] threshold=%lu probability=%d%%\n",
            threshold, probability);
}

static int
should_fail(void)
{
    if (!initialised)
        fm_init();
    alloc_count++;
    if (alloc_count <= threshold)
        return 0;
    return (rand() % 100) < probability;
}

void *
malloc(size_t size)
{
    if (!initialised)
        fm_init();
    if (should_fail()) {
        fprintf(stderr, "[failmalloc] malloc(%zu) -> NULL (injection #%lu)\n",
                size, alloc_count);
        return NULL;
    }
    return real_malloc(size);
}

void *
calloc(size_t nmemb, size_t size)
{
    /* During dlsym() init, real_calloc is not yet available */
    if (real_calloc == NULL) {
        size_t total = nmemb * size;
        if (init_buf_used + (int)total <= (int)sizeof(init_buf)) {
            void *ptr = init_buf + init_buf_used;
            init_buf_used += (int)total;
            memset(ptr, 0, total);
            return ptr;
        }
        return NULL;
    }
    if (should_fail()) {
        fprintf(stderr, "[failmalloc] calloc(%zu,%zu) -> NULL (injection #%lu)\n",
                nmemb, size, alloc_count);
        return NULL;
    }
    return real_calloc(nmemb, size);
}

void *
realloc(void *ptr, size_t size)
{
    if (!initialised)
        fm_init();
    if (size > 0 && should_fail()) {
        fprintf(stderr, "[failmalloc] realloc(%zu) -> NULL (injection #%lu)\n",
                size, alloc_count);
        return NULL;
    }
    return real_realloc(ptr, size);
}

char *
strdup(const char *s)
{
    if (!initialised)
        fm_init();
    if (should_fail()) {
        fprintf(stderr, "[failmalloc] strdup(\"%s\") -> NULL (injection #%lu)\n",
                s ? s : "(null)", alloc_count);
        return NULL;
    }
    return real_strdup(s);
}
