#ifndef GHOSTTEX_MATH_H
#define GHOSTTEX_MATH_H
#include <stddef.h>
#include <stdint.h>

/* ABI 1; all pointers are borrowed only for the call except image ownership.
 * RGBA8 is tightly packed, straight alpha, sRGB. Baseline is pixels from top.
 * Keep each context on one host thread; completion callbacks may run on the
 * scheduler thread. Destroy waits out callbacks before returning.
 */
typedef struct {
    uint32_t struct_size, version;
    float font_px;
    uint32_t max_width, max_height, display;
    uint8_t color[4];
} GhosttexMathOptions;

typedef struct {
    uint32_t width, height, stride;
    float baseline;
    const uint8_t *data;
    size_t len;
    void *owner;
    uint8_t error[256];
} GhosttexMathImage;

typedef struct GhosttexMathContext GhosttexMathContext;
typedef void (*GhosttexMathWake)(void *userdata);
typedef struct {
    uint64_t renders, cache_hits, canceled, failures;
    uint64_t render_ns, cpu_bytes, queued;
} GhosttexMathStats;

uint32_t ghosttex_math_abi_version(void);
/* Synchronous development API. The application uses the isolated worker API. */
int ghosttex_math_render(const uint8_t *, size_t, const GhosttexMathOptions *, GhosttexMathImage *);
/* Release every successful result once, in place. A second free in place is
 * harmless. Never free copies of an owning result or use the host allocator. */
void ghosttex_math_free(GhosttexMathImage *);
GhosttexMathContext *ghosttex_math_context_create(GhosttexMathWake, void *, const uint8_t *worker_path, size_t path_len);
void ghosttex_math_context_destroy(GhosttexMathContext *);
void ghosttex_math_frame_begin(GhosttexMathContext *);
/* 0=image, 1=failure, 2=pending/queue full. Finish releases obsolete leases. */
int ghosttex_math_request(GhosttexMathContext *, const uint8_t *, size_t,
                         const GhosttexMathOptions *, GhosttexMathImage *, uint64_t *ticket);
void ghosttex_math_frame_finish(GhosttexMathContext *);
void ghosttex_math_stats(GhosttexMathContext *, GhosttexMathStats *);
#endif
