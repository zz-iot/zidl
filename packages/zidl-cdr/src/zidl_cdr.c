/* C ABI writer setup and allocator support; writes live in the native Zig core. */

#include "zidl_cdr.h"

#include <stdlib.h>   /* malloc, realloc, free */
#include <string.h>   /* memcpy, strlen */

/* The native core's Zig runtime calls ntdll directly. An MSVC-ABI archive
 * names it as a default library so MSVC consumers need not list it. */
#if defined(_WIN32) && defined(_MSC_VER)
#pragma comment(lib, "ntdll")
#endif

/* ── Writer ──────────────────────────────────────────────────────────────── */

static void writer_init(ZidlCdrWriter *w, uint8_t *buf, size_t cap, int xcdr_version) {
    w->buf          = buf;
    w->cap          = cap;
    w->len          = 0;
    w->pos          = 0;
    w->xcdr_version = xcdr_version;
    w->byte_order   = ZIDL_CDR_LE;
    w->hash         = NULL;
}

void zidl_cdr_writer_init_fixed(ZidlCdrWriter *w, uint8_t *buf, size_t cap, int xcdr_version) {
    writer_init(w, buf, cap, xcdr_version);
}

void zidl_cdr_writer_init_counting(ZidlCdrWriter *w, int xcdr_version) {
    writer_init(w, NULL, 0, xcdr_version);
}

void zidl_cdr_writer_set_byte_order(ZidlCdrWriter *w, int byte_order) {
    w->byte_order = byte_order;
}

int zidl_cdr_writer_is_counting(const ZidlCdrWriter *w) {
    return !w->buf && !w->hash;
}

int zidl_cdr_serialize_alloc(int xcdr_version, int byte_order, ZidlCdrSerializeFn fn,
                             const void *ctx, uint8_t **out, size_t *out_len) {
    ZidlCdrWriter w;
    zidl_cdr_writer_init_counting(&w, xcdr_version);
    zidl_cdr_writer_set_byte_order(&w, byte_order);
    int rc = fn(&w, ctx);
    if (rc) return rc;
    const size_t counted = w.len;
    if (counted == 0) {
        *out = NULL;
        *out_len = 0;
        return ZIDL_CDR_OK;
    }
    uint8_t *buf = (uint8_t *)zidl_cdr_alloc(counted);
    if (!buf) return ZIDL_CDR_OVERFLOW;
    zidl_cdr_writer_init_fixed(&w, buf, counted, xcdr_version);
    zidl_cdr_writer_set_byte_order(&w, byte_order);
    rc = fn(&w, ctx);
    if (!rc && w.len != counted) rc = ZIDL_CDR_INVALID;
    if (rc) {
        zidl_cdr_free(buf, counted);
        return rc;
    }
    *out = buf;
    *out_len = counted;
    return ZIDL_CDR_OK;
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
