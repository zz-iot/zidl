/* C ABI storage and allocator support; wire operations live in the native Zig core. */

#include "zidl_cdr.h"

#include <stdlib.h>   /* malloc, realloc, free */
#include <string.h>   /* memcpy, strlen */

/* ── Writer ──────────────────────────────────────────────────────────────── */

static int writer_grow_default(ZidlCdrWriter *w, size_t needed) {
    if (needed > SIZE_MAX - w->len) return ZIDL_CDR_OVERFLOW;
    size_t required = w->len + needed;
    size_t new_cap = w->cap == 0 ? 64u : w->cap;
    while (new_cap < required) {
        if (new_cap > SIZE_MAX / 2u) { new_cap = required; break; }
        new_cap *= 2u;
    }
    /* Buffer growth uses the same registered allocator as decoding. */
    uint8_t *p = (uint8_t *)zidl_cdr_realloc(w->buf, w->cap, new_cap);
    if (!p) return ZIDL_CDR_OVERFLOW;
    w->buf = p;
    w->cap = new_cap;
    return ZIDL_CDR_OK;
}

int zidl_cdr_writer_init(ZidlCdrWriter *w, int xcdr_version) {
    w->buf          = NULL;
    w->cap          = 0;
    w->len          = 0;
    w->pos          = 0;
    w->xcdr_version = xcdr_version;
    w->byte_order   = ZIDL_CDR_LE;
    w->grow_fn      = writer_grow_default;
    return ZIDL_CDR_OK;
}

void zidl_cdr_writer_init_fixed(ZidlCdrWriter *w, uint8_t *buf, size_t cap, int xcdr_version) {
    w->buf          = buf;
    w->cap          = cap;
    w->len          = 0;
    w->pos          = 0;
    w->xcdr_version = xcdr_version;
    w->byte_order   = ZIDL_CDR_LE;
    w->grow_fn      = NULL;
}

void zidl_cdr_writer_init_counting(ZidlCdrWriter *w, int xcdr_version) {
    w->buf          = NULL;
    w->cap          = 0;
    w->len          = 0;
    w->pos          = 0;
    w->xcdr_version = xcdr_version;
    w->byte_order   = ZIDL_CDR_LE;
    w->grow_fn      = NULL;
}

void zidl_cdr_writer_deinit(ZidlCdrWriter *w) {
    if (w->grow_fn == writer_grow_default) {
        zidl_cdr_free(w->buf, w->cap);
        w->buf = NULL;
        w->cap = 0;
        w->len = 0;
    }
}

void zidl_cdr_writer_set_byte_order(ZidlCdrWriter *w, int byte_order) {
    w->byte_order = byte_order;
}

static int writer_ensure(ZidlCdrWriter *w, size_t n) {
    if (n > SIZE_MAX - w->len || n > SIZE_MAX - w->pos) return ZIDL_CDR_OVERFLOW;
    /* Counting mode only needs the counter bounds above. */
    if (!w->buf && !w->grow_fn) return ZIDL_CDR_OK;
    if (w->len + n <= w->cap) return ZIDL_CDR_OK;
    if (!w->grow_fn) return ZIDL_CDR_OVERFLOW;
    return w->grow_fn(w, n);
}

static int writer_write_bytes(ZidlCdrWriter *w, const uint8_t *bytes, size_t n) {
    int rc = writer_ensure(w, n);
    if (rc) return rc;
    if (w->buf && n) memcpy(w->buf + w->len, bytes, n);
    w->len += n;
    w->pos += n;
    return ZIDL_CDR_OK;
}

/* Internal storage bridge. Wire encoding lives in the shared Zig core. */
int zidl_cdr_shared_write_bytes(ZidlCdrWriter *w, const uint8_t *bytes, size_t n) {
    return writer_write_bytes(w, bytes, n);
}

/* ── Allocator ───────────────────────────────────────────────────────────── */

/* Preserve the C ABI allocator's fixed eight-byte alignment. */
#define ZIDL_CDR_ALLOC_ALIGN ((size_t)8)

/* NULL uses libc. Register before worker threads start; volatile is not synchronization. */
static const ZidlAllocator *volatile g_allocator = NULL;

void zidl_cdr_set_allocator(const ZidlAllocator *allocator) {
    g_allocator = allocator;
}

const ZidlAllocator *zidl_cdr_get_allocator(void) {
    return (const ZidlAllocator *)g_allocator;
}

void *zidl_cdr_alloc(size_t n) {
    if (g_allocator) return g_allocator->alloc(g_allocator->ctx, n, ZIDL_CDR_ALLOC_ALIGN);
    return malloc(n);
}

void zidl_cdr_free(void *p, size_t n) {
    if (!p) return;
    if (g_allocator) { g_allocator->free(g_allocator->ctx, p, n, ZIDL_CDR_ALLOC_ALIGN); return; }
    free(p);
}

char *zidl_cdr_strdup(const char *s) {
    size_t n = strlen(s) + 1u;
    char *buf = (char *)zidl_cdr_alloc(n);
    if (!buf) return NULL;
    memcpy(buf, s, n);
    return buf;
}

void *zidl_cdr_realloc(void *ptr, size_t old_len, size_t new_len) {
    if (!g_allocator) return realloc(ptr, new_len);
    if (ptr && g_allocator->resize(g_allocator->ctx, ptr, old_len, new_len, ZIDL_CDR_ALLOC_ALIGN)) {
        return ptr;
    }
    void *new_ptr = g_allocator->alloc(g_allocator->ctx, new_len, ZIDL_CDR_ALLOC_ALIGN);
    if (!new_ptr) return NULL;
    if (ptr) {
        size_t copy_len = old_len < new_len ? old_len : new_len;
        memcpy(new_ptr, ptr, copy_len);
        g_allocator->free(g_allocator->ctx, ptr, old_len, ZIDL_CDR_ALLOC_ALIGN);
    }
    return new_ptr;
}

void zidl_cdr_free_str(char *s) {
    if (!s) return;
    zidl_cdr_free(s, strlen(s) + 1u);
}

void zidl_cdr_free_wstr(uint16_t *s) {
    if (!s) return;
    uint32_t n = 0;
    while (s[n] != 0) n++;
    zidl_cdr_free(s, (n + 1u) * sizeof(uint16_t));
}

size_t zidl_cdr_remaining(const ZidlCdrReader *r) {
    return (r->pos < r->data_len) ? (r->data_len - r->pos) : 0;
}
