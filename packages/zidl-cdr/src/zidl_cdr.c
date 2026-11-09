/*
 * zidl-cdr — Standalone C99 CDR library implementation.
 *
 * Alignment rule (matches zidl-rt):
 *   CDR alignment is measured from the start of the CDR payload.
 *   ZidlCdrWriter.pos resets to 0 after zidl_cdr_write_encap(); subsequent
 *   primitives align relative to that reset point.
 *
 *   - XCDR1: natural alignment, capped at 8 bytes.
 *   - XCDR2: natural alignment, capped at 4 bytes.
 *
 * Writers default to little-endian.  The reader byte-swaps big-endian streams
 * on read.
 */

#include "zidl_cdr.h"

#include <stdlib.h>   /* malloc, realloc, free */
#include <string.h>   /* memcpy, strlen */

/* ── Internal helpers ────────────────────────────────────────────────────── */

/** Alignment cap: XCDR2 → min(size,4); XCDR1 and PL_CDR → min(size,8). */
#ifndef ZIDL_CDR_SHARED_PRIMITIVES
static size_t align_cap(int xcdr_version, size_t wire_size) {
    size_t cap = (xcdr_version == ZIDL_XCDR2) ? 4u : 8u;
    return (wire_size < cap) ? wire_size : cap;
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

/* ── Writer ──────────────────────────────────────────────────────────────── */

static int writer_grow_default(ZidlCdrWriter *w, size_t needed) {
    if (needed > SIZE_MAX - w->len) return ZIDL_CDR_OVERFLOW;
    size_t required = w->len + needed;
    size_t new_cap = w->cap == 0 ? 64u : w->cap;
    while (new_cap < required) {
        if (new_cap > SIZE_MAX / 2u) { new_cap = required; break; }
        new_cap *= 2u;
    }
    // Routes through the registered allocator (zidl_cdr_set_allocator), same
    // as the read/decode side -- falls back to libc realloc only if none is
    // registered. It's the caller's responsibility to register an allocator
    // whose backing store is large enough for whatever it serializes.
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

#ifdef ZIDL_CDR_SHARED_PRIMITIVES
/* Internal storage bridge. Wire encoding lives in the shared Zig core. */
int zidl_cdr_shared_write_bytes(ZidlCdrWriter *w, const uint8_t *bytes, size_t n) {
    return writer_write_bytes(w, bytes, n);
}
#endif

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
static void writer_store_u32_at(const ZidlCdrWriter *w, size_t offset, uint32_t v) {
    /* Counting mode: no buffer to patch; the byte count already advanced
     * when the placeholder was written, patching doesn't change len/pos. */
    if (!w->buf) return;
    if (w->byte_order == ZIDL_CDR_BE) {
        w->buf[offset + 0] = (uint8_t)(v >> 24);
        w->buf[offset + 1] = (uint8_t)(v >> 16);
        w->buf[offset + 2] = (uint8_t)(v >> 8);
        w->buf[offset + 3] = (uint8_t)(v);
    } else {
        w->buf[offset + 0] = (uint8_t)(v);
        w->buf[offset + 1] = (uint8_t)(v >> 8);
        w->buf[offset + 2] = (uint8_t)(v >> 16);
        w->buf[offset + 3] = (uint8_t)(v >> 24);
    }
}

static int writer_pad(ZidlCdrWriter *w, size_t boundary) {
    size_t rem = w->pos % boundary;
    if (rem == 0) return ZIDL_CDR_OK;
    size_t pad = boundary - rem;
    /* Emit zero padding bytes. */
    static const uint8_t zeros[8] = {0,0,0,0,0,0,0,0};
    return writer_write_bytes(w, zeros, pad);
}

/* ── Encapsulation header ─────────────────────────────────────────────────── */

static int write_encap_id(ZidlCdrWriter *w, uint16_t id);

int zidl_cdr_write_encap_kind(ZidlCdrWriter *w, int extensibility) {
    if (w->xcdr_version != ZIDL_XCDR2 || extensibility == ZIDL_EXT_FINAL) return zidl_cdr_write_encap(w);
    int be = w->byte_order == ZIDL_CDR_BE;
    uint16_t id = extensibility == ZIDL_EXT_MUTABLE
        ? (uint16_t)(be ? ZIDL_ENCAP_PL_CDR2_BE : ZIDL_ENCAP_PL_CDR2_LE)
        : (uint16_t)(be ? ZIDL_ENCAP_D_CDR2_BE : ZIDL_ENCAP_D_CDR2_LE);
    return write_encap_id(w, id);
}

int zidl_cdr_write_encap(ZidlCdrWriter *w) {
    uint16_t id;
    if (w->xcdr_version == ZIDL_XCDR1) {
        id = (uint16_t)(w->byte_order == ZIDL_CDR_BE ? ZIDL_ENCAP_CDR1_BE : ZIDL_ENCAP_CDR1_LE);
    } else if (w->xcdr_version == ZIDL_PL_CDR) {
        id = (uint16_t)(w->byte_order == ZIDL_CDR_BE ? ZIDL_ENCAP_PL_CDR_BE : ZIDL_ENCAP_PL_CDR_LE);
    } else {
        id = (uint16_t)(w->byte_order == ZIDL_CDR_BE ? ZIDL_ENCAP_CDR2_BE : ZIDL_ENCAP_CDR2_LE);
    }
    return write_encap_id(w, id);
}

static int write_encap_id(ZidlCdrWriter *w, uint16_t id) {
    uint8_t hdr[4] = {
        (uint8_t)(id >> 8),    /* high byte first (big-endian repr ID per RTPS spec) */
        (uint8_t)(id & 0xFFu),
        0x00u,                  /* options — unused */
        0x00u,
    };
    int rc = writer_ensure(w, 4);
    if (rc) return rc;
    if (w->buf) memcpy(w->buf + w->len, hdr, 4);
    w->len += 4;
    /* Reset CDR payload position: alignment is measured from payload start. */
    w->pos = 0;
    return ZIDL_CDR_OK;
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

/* ── Primitive writes ─────────────────────────────────────────────────────── */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_write_u8(ZidlCdrWriter *w, uint8_t v) {
    return writer_write_bytes(w, &v, 1);
}
int zidl_cdr_write_i8(ZidlCdrWriter *w, int8_t v) {
    return zidl_cdr_write_u8(w, (uint8_t)v);
}
int zidl_cdr_write_bool(ZidlCdrWriter *w, bool v) {
    uint8_t b = v ? 1u : 0u;
    return writer_write_bytes(w, &b, 1);
}
int zidl_cdr_write_char(ZidlCdrWriter *w, char v) {
    return writer_write_bytes(w, (const uint8_t *)&v, 1);
}
int zidl_cdr_write_u16(ZidlCdrWriter *w, uint16_t v) {
    int rc = writer_pad(w, align_cap(w->xcdr_version, 2));
    if (rc) return rc;
    uint8_t b[2];
    if (w->byte_order == ZIDL_CDR_BE) {
        b[0] = (uint8_t)(v >> 8);
        b[1] = (uint8_t)(v & 0xFFu);
    } else {
        b[0] = (uint8_t)(v & 0xFFu);
        b[1] = (uint8_t)(v >> 8);
    }
    return writer_write_bytes(w, b, 2);
}
int zidl_cdr_write_i16(ZidlCdrWriter *w, int16_t v) {
    return zidl_cdr_write_u16(w, (uint16_t)v);
}
int zidl_cdr_write_u32(ZidlCdrWriter *w, uint32_t v) {
    int rc = writer_pad(w, align_cap(w->xcdr_version, 4));
    if (rc) return rc;
    uint8_t b[4];
    if (w->byte_order == ZIDL_CDR_BE) {
        b[0] = (uint8_t)(v >> 24);
        b[1] = (uint8_t)(v >> 16);
        b[2] = (uint8_t)(v >> 8);
        b[3] = (uint8_t)(v);
    } else {
        b[0] = (uint8_t)(v);
        b[1] = (uint8_t)(v >> 8);
        b[2] = (uint8_t)(v >> 16);
        b[3] = (uint8_t)(v >> 24);
    }
    return writer_write_bytes(w, b, 4);
}
int zidl_cdr_write_i32(ZidlCdrWriter *w, int32_t v) {
    return zidl_cdr_write_u32(w, (uint32_t)v);
}
int zidl_cdr_write_f32(ZidlCdrWriter *w, float v) {
    uint32_t bits;
    memcpy(&bits, &v, 4);
    return zidl_cdr_write_u32(w, bits);
}
int zidl_cdr_write_u64(ZidlCdrWriter *w, uint64_t v) {
    int rc = writer_pad(w, align_cap(w->xcdr_version, 8));
    if (rc) return rc;
    uint8_t b[8];
    if (w->byte_order == ZIDL_CDR_BE) {
        b[0] = (uint8_t)(v >> 56);
        b[1] = (uint8_t)(v >> 48);
        b[2] = (uint8_t)(v >> 40);
        b[3] = (uint8_t)(v >> 32);
        b[4] = (uint8_t)(v >> 24);
        b[5] = (uint8_t)(v >> 16);
        b[6] = (uint8_t)(v >> 8);
        b[7] = (uint8_t)(v);
    } else {
        b[0] = (uint8_t)(v);
        b[1] = (uint8_t)(v >> 8);
        b[2] = (uint8_t)(v >> 16);
        b[3] = (uint8_t)(v >> 24);
        b[4] = (uint8_t)(v >> 32);
        b[5] = (uint8_t)(v >> 40);
        b[6] = (uint8_t)(v >> 48);
        b[7] = (uint8_t)(v >> 56);
    }
    return writer_write_bytes(w, b, 8);
}
int zidl_cdr_write_i64(ZidlCdrWriter *w, int64_t v) {
    return zidl_cdr_write_u64(w, (uint64_t)v);
}
int zidl_cdr_write_f64(ZidlCdrWriter *w, double v) {
    uint64_t bits;
    memcpy(&bits, &v, 8);
    return zidl_cdr_write_u64(w, bits);
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
/* Two limbs keep the temporary C99 reference independent of Zig's u128. */
static void fixed_accumulate(uint64_t *hi, uint64_t *lo, uint8_t digit) {
    uint64_t low = (*lo & UINT32_MAX) * 10u + digit;
    uint64_t high = (*lo >> 32) * 10u + (low >> 32);
    *lo = (high << 32) | (low & UINT32_MAX);
    *hi = *hi * 10u + (high >> 32);
}

static double fixed_to_double(uint64_t hi, uint64_t lo) {
    unsigned bit = 0, shift;
    uint64_t top = hi, significant, remainder, half;
    if (!hi) return (double)lo;
    while (top >>= 1) ++bit;
    shift = bit + 64u - 52u;
    significant = (hi << (64u - shift)) | (lo >> shift);
    remainder = lo & ((UINT64_C(1) << shift) - 1u);
    half = UINT64_C(1) << (shift - 1u);
    if (remainder > half || (remainder == half && (significant & 1u))) ++significant;
    return (double)significant * (double)(UINT64_C(1) << shift);
}

int zidl_cdr_write_fixed(ZidlCdrWriter *w, uint8_t digits, uint8_t scale, double value) {
    uint8_t decimal[31] = {0}, buf[16] = {0};
    uint64_t hi = 0, lo = 1, bits, mantissa;
    double factor = 1.0, rounded, limit;
    unsigned i, n, pad;
    int exponent, bit, nonzero = 0;
    if (digits < 1 || digits > 31 || scale > digits || value != value) return ZIDL_CDR_INVALID;
    for (i = 0; i < digits; ++i) fixed_accumulate(&hi, &lo, 0);
    limit = fixed_to_double(hi, lo);
    for (i = 0; i < scale; ++i) factor *= 10.0;
    rounded = (value < 0 ? -value : value) * factor + 0.5;
    if (rounded >= limit) {
        memset(decimal, 9, digits);
    } else {
        /* Extract the binary integer into decimal digits without a wide cast. */
        memcpy(&bits, &rounded, sizeof bits);
        exponent = (int)((bits >> 52) & 0x7ffu) - 1023;
        mantissa = (bits & UINT64_C(0x000fffffffffffff)) | (UINT64_C(1) << 52);
        for (bit = exponent; bit >= 0; --bit) {
            int source_bit = bit + 52 - exponent;
            unsigned carry = source_bit >= 0 ? (unsigned)((mantissa >> source_bit) & 1u) : 0;
            for (i = digits; i > 0; --i) {
                unsigned digit = decimal[i - 1] * 2u + carry;
                decimal[i - 1] = (uint8_t)(digit % 10u); carry = digit / 10u;
            }
        }
    }
    n = digits / 2u + 1u;
    pad = digits % 2u == 0;
    for (i = 0; i < digits; ++i) {
        unsigned nibble = pad + i;
        nonzero |= decimal[i];
        buf[nibble / 2] |= (uint8_t)(decimal[i] << (nibble % 2 == 0 ? 4 : 0));
    }
    buf[n - 1] |= value < 0 && nonzero ? 0xdu : 0xcu;
    return writer_write_bytes(w, buf, n);
}
#endif

/* ── String / wstring writes ─────────────────────────────────────────────── */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_write_string(ZidlCdrWriter *w, const char *s, uint32_t len) {
    int rc = zidl_cdr_write_u32(w, len + 1u);
    if (rc) return rc;
    rc = writer_write_bytes(w, (const uint8_t *)s, len);
    if (rc) return rc;
    uint8_t nul = 0u;
    return writer_write_bytes(w, &nul, 1);
}

int zidl_cdr_write_wstring(ZidlCdrWriter *w, const uint16_t *s, uint32_t len) {
    return zidl_cdr_write_key_wstring(w, s, len);
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

/* ── DHEADER ─────────────────────────────────────────────────────────────── */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_write_dheader(ZidlCdrWriter *w, uint32_t payload_size) {
    return zidl_cdr_write_u32(w, payload_size);
}

int zidl_cdr_reserve_dheader(ZidlCdrWriter *w, size_t *out_offset) {
    /* Align first: the offset must name the 4-byte placeholder itself, not
     * any padding written before it. */
    int rc = writer_pad(w, align_cap(w->xcdr_version, 4));
    if (rc) return rc;
    *out_offset = w->len;
    return zidl_cdr_write_u32(w, 0);
}

void zidl_cdr_patch_dheader(ZidlCdrWriter *w, size_t dheader_offset) {
    uint32_t payload = (uint32_t)(w->len - dheader_offset - 4u);
    writer_store_u32_at(w, dheader_offset, payload);
}

int zidl_cdr_reserve_dheader_maybe(ZidlCdrWriter *w, size_t *out_offset) {
    if (w->xcdr_version != ZIDL_XCDR2) {
        /* XCDR1 and PL_CDR do not use DHEADER */
        *out_offset = (size_t)-1; /* SIZE_MAX equivalent */
        return ZIDL_CDR_OK;
    }
    return zidl_cdr_reserve_dheader(w, out_offset);
}

void zidl_cdr_patch_dheader_maybe(ZidlCdrWriter *w, size_t dheader_offset) {
    if (dheader_offset == (size_t)-1) return;
    zidl_cdr_patch_dheader(w, dheader_offset);
}

/* ── Reader ──────────────────────────────────────────────────────────────── */

int zidl_cdr_reader_init(ZidlCdrReader *r, const uint8_t *data, size_t data_len) {
    if (data_len < 4) return ZIDL_CDR_INVALID;
    uint16_t id = (uint16_t)(((uint16_t)data[0] << 8) | (uint16_t)data[1]);
    r->is_pl_cdr = 0;
    switch (id) {
        case ZIDL_ENCAP_CDR1_LE:   r->byte_order = ZIDL_CDR_LE; r->xcdr_version = ZIDL_XCDR1; break;
        case ZIDL_ENCAP_CDR1_BE:   r->byte_order = ZIDL_CDR_BE; r->xcdr_version = ZIDL_XCDR1; break;
        case ZIDL_ENCAP_CDR2_LE:   r->byte_order = ZIDL_CDR_LE; r->xcdr_version = ZIDL_XCDR2; break;
        case ZIDL_ENCAP_CDR2_BE:   r->byte_order = ZIDL_CDR_BE; r->xcdr_version = ZIDL_XCDR2; break;
        /* XCDR2 appendable / mutable representations: same framing rules as
         * CDR2 here (the DHEADER / EMHEADERs follow from the type). */
        case ZIDL_ENCAP_D_CDR2_LE:
        case ZIDL_ENCAP_PL_CDR2_LE: r->byte_order = ZIDL_CDR_LE; r->xcdr_version = ZIDL_XCDR2; break;
        case ZIDL_ENCAP_D_CDR2_BE:
        case ZIDL_ENCAP_PL_CDR2_BE: r->byte_order = ZIDL_CDR_BE; r->xcdr_version = ZIDL_XCDR2; break;
        case ZIDL_ENCAP_PL_CDR_LE: r->byte_order = ZIDL_CDR_LE; r->xcdr_version = ZIDL_XCDR1;
                                    r->is_pl_cdr = 1; break;
        case ZIDL_ENCAP_PL_CDR_BE: r->byte_order = ZIDL_CDR_BE; r->xcdr_version = ZIDL_XCDR1;
                                    r->is_pl_cdr = 1; break;
        default: return ZIDL_CDR_INVALID;
    }
    r->data     = data;
    r->data_len = data_len;
    r->pos      = 4; /* CDR payload starts after the 4-byte encap header */
    return ZIDL_CDR_OK;
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
static int reader_align_pos(ZidlCdrReader *r, size_t boundary) {
    /*
     * CDR alignment is measured from the start of the CDR payload, which
     * begins after the 4-byte encap header (r->pos == 4 at payload start).
     * So the effective payload offset is (r->pos - 4).
     */
    size_t cdr_pos = r->pos - 4u;
    size_t rem     = cdr_pos % boundary;
    if (rem != 0) r->pos += boundary - rem;
    /*
     * A truncated sample can end inside the alignment padding, leaving pos past
     * the buffer. Clamp so `pos <= data_len` stays invariant -- the next
     * read/skip then reports ZIDL_CDR_TRUNCATED instead of the `data_len - pos`
     * bounds checks underflowing and letting a later read run off the end.
     */
    if (r->pos > r->data_len) r->pos = r->data_len;
    return ZIDL_CDR_OK;
}

#endif

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
static int reader_read_slice(ZidlCdrReader *r, size_t n, const uint8_t **out) {
    /* r->pos <= r->data_len is invariant (init, every advance, seek_to, and the
     * clamp in reader_align_pos all enforce it), so `data_len - pos` cannot
     * underflow -- and comparing against it, rather than `pos + n`, cannot
     * overflow for a hostile n. */
    if (r->pos > r->data_len || n > r->data_len - r->pos) return ZIDL_CDR_TRUNCATED;
    *out     = r->data + r->pos;
    r->pos  += n;
    return ZIDL_CDR_OK;
}
#endif

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
static uint16_t maybe_swap16(const ZidlCdrReader *r, uint16_t raw) {
    if (r->byte_order == ZIDL_CDR_LE) return raw;
    return (uint16_t)((raw >> 8) | (raw << 8));
}
static uint32_t maybe_swap32(const ZidlCdrReader *r, uint32_t raw) {
    if (r->byte_order == ZIDL_CDR_LE) return raw;
    return ((raw & 0x000000FFu) << 24) |
           ((raw & 0x0000FF00u) <<  8) |
           ((raw & 0x00FF0000u) >>  8) |
           ((raw & 0xFF000000u) >> 24);
}
static uint64_t maybe_swap64(const ZidlCdrReader *r, uint64_t raw) {
    if (r->byte_order == ZIDL_CDR_LE) return raw;
    return ((raw & UINT64_C(0x00000000000000FF)) << 56) |
           ((raw & UINT64_C(0x000000000000FF00)) << 40) |
           ((raw & UINT64_C(0x0000000000FF0000)) << 24) |
           ((raw & UINT64_C(0x00000000FF000000)) <<  8) |
           ((raw & UINT64_C(0x000000FF00000000)) >>  8) |
           ((raw & UINT64_C(0x0000FF0000000000)) >> 24) |
           ((raw & UINT64_C(0x00FF000000000000)) >> 40) |
           ((raw & UINT64_C(0xFF00000000000000)) >> 56);
}

/* ── Primitive reads ─────────────────────────────────────────────────────── */

int zidl_cdr_read_u8(ZidlCdrReader *r, uint8_t *out) {
    const uint8_t *p;
    int rc = reader_read_slice(r, 1, &p);
    if (rc) return rc;
    *out = p[0];
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_i8(ZidlCdrReader *r, int8_t *out) {
    uint8_t v;
    int rc = zidl_cdr_read_u8(r, &v);
    if (rc) return rc;
    *out = (int8_t)v;
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_bool(ZidlCdrReader *r, bool *out) {
    uint8_t v;
    int rc = zidl_cdr_read_u8(r, &v);
    if (rc) return rc;
    if (v > 1u) return ZIDL_CDR_INVALID;
    *out = (v == 1u);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_char(ZidlCdrReader *r, char *out) {
    return zidl_cdr_read_u8(r, (uint8_t *)out);
}
int zidl_cdr_read_u16(ZidlCdrReader *r, uint16_t *out) {
    reader_align_pos(r, align_cap(r->xcdr_version, 2));
    const uint8_t *p;
    int rc = reader_read_slice(r, 2, &p);
    if (rc) return rc;
    uint16_t raw = (uint16_t)p[0] | ((uint16_t)p[1] << 8);
    *out = maybe_swap16(r, raw);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_i16(ZidlCdrReader *r, int16_t *out) {
    uint16_t v;
    int rc = zidl_cdr_read_u16(r, &v);
    if (rc) return rc;
    *out = (int16_t)v;
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_u32(ZidlCdrReader *r, uint32_t *out) {
    reader_align_pos(r, align_cap(r->xcdr_version, 4));
    const uint8_t *p;
    int rc = reader_read_slice(r, 4, &p);
    if (rc) return rc;
    uint32_t raw = (uint32_t)p[0]        |
                  ((uint32_t)p[1] << 8)  |
                  ((uint32_t)p[2] << 16) |
                  ((uint32_t)p[3] << 24);
    *out = maybe_swap32(r, raw);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_i32(ZidlCdrReader *r, int32_t *out) {
    uint32_t v;
    int rc = zidl_cdr_read_u32(r, &v);
    if (rc) return rc;
    *out = (int32_t)v;
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_f32(ZidlCdrReader *r, float *out) {
    uint32_t bits;
    int rc = zidl_cdr_read_u32(r, &bits);
    if (rc) return rc;
    memcpy(out, &bits, 4);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_u64(ZidlCdrReader *r, uint64_t *out) {
    reader_align_pos(r, align_cap(r->xcdr_version, 8));
    const uint8_t *p;
    int rc = reader_read_slice(r, 8, &p);
    if (rc) return rc;
    uint64_t raw = (uint64_t)p[0]        |
                  ((uint64_t)p[1] << 8)  |
                  ((uint64_t)p[2] << 16) |
                  ((uint64_t)p[3] << 24) |
                  ((uint64_t)p[4] << 32) |
                  ((uint64_t)p[5] << 40) |
                  ((uint64_t)p[6] << 48) |
                  ((uint64_t)p[7] << 56);
    *out = maybe_swap64(r, raw);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_i64(ZidlCdrReader *r, int64_t *out) {
    uint64_t v;
    int rc = zidl_cdr_read_u64(r, &v);
    if (rc) return rc;
    *out = (int64_t)v;
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_f64(ZidlCdrReader *r, double *out) {
    uint64_t bits;
    int rc = zidl_cdr_read_u64(r, &bits);
    if (rc) return rc;
    memcpy(out, &bits, 8);
    return ZIDL_CDR_OK;
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_read_fixed(ZidlCdrReader *r, uint8_t digits, uint8_t scale, double *out) {
    uint64_t hi = 0, lo = 0;
    unsigned n, pad, i;
    uint8_t sign;
    const uint8_t *buf;
    double factor = 1.0, result;
    int rc;
    if (digits < 1 || digits > 31 || scale > digits) return ZIDL_CDR_INVALID;
    n = digits / 2u + 1u; pad = digits % 2u == 0;
    rc = reader_read_slice(r, n, &buf);
    if (rc) return rc;
    if (pad && (buf[0] >> 4) != 0) return ZIDL_CDR_INVALID;
    for (i = 0; i < digits; ++i) {
        unsigned nibble = pad + i;
        uint8_t digit = (uint8_t)((buf[nibble / 2] >> (nibble % 2 == 0 ? 4 : 0)) & 0xfu);
        if (digit > 9) return ZIDL_CDR_INVALID;
        fixed_accumulate(&hi, &lo, digit);
    }
    sign = buf[n - 1] & 0xfu;
    if (sign != 0xc && sign != 0xd) return ZIDL_CDR_INVALID;
    for (i = 0; i < scale; ++i) factor *= 10.0;
    result = fixed_to_double(hi, lo) / factor;
    *out = sign == 0xd ? -result : result;
    return ZIDL_CDR_OK;
}
#endif

/* ── Allocator ───────────────────────────────────────────────────────────── */

/*
 * Fixed conservative alignment requested for every zidl_cdr_alloc/free call,
 * regardless of what's being stored. No IDL primitive or struct needs more
 * than 8-byte natural alignment (the widest IDL primitives — double,
 * (u)int64_t — are 8 bytes; a struct's alignment is the max of its
 * members', so it can't exceed that either), so a fixed 8 is provably
 * sufficient without needing C11's _Alignof (this file targets C99) or
 * threading a per-element alignment value through every call site,
 * including the ones generated per-type by the C backend.
 */
#define ZIDL_CDR_ALLOC_ALIGN ((size_t)8)

/* NULL means "use libc malloc/free" — the default, and what every allocation
 * made before the first zidl_cdr_set_allocator() call uses.
 *
 * volatile does NOT make this thread-safe on its own — the documented
 * contract (zidl_cdr_set_allocator's doc comment) still requires the
 * caller to register the allocator once at startup, before any other
 * thread starts decoding, since volatile provides no atomicity or memory
 * ordering guarantee across cores. What it does provide: without it nothing
 * stops a compiler from proving that no *visible* store to g_allocator
 * occurs within a long call (e.g. zidl_cdr_read_wstring's per-character
 * loop) and caching its value across that whole call, especially once
 * inlined under LTO — a real risk even for within-contract usage (set,
 * decode, later reset for a different pass), not just the cross-thread
 * misuse the documented contract already disclaims. */
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

/* ── String / wstring reads ──────────────────────────────────────────────── */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_read_string_zerocopy(ZidlCdrReader *r, const char **out, uint32_t *out_len) {
    uint32_t len; /* byte count including NUL */
    int rc = zidl_cdr_read_u32(r, &len);
    if (rc) return rc;
    if (len == 0) return ZIDL_CDR_INVALID;
    const uint8_t *p;
    rc = reader_read_slice(r, len, &p);
    if (rc) return rc;
    *out     = (const char *)p;
    *out_len = len - 1u; /* exclude NUL */
    return ZIDL_CDR_OK;
}

int zidl_cdr_read_string(ZidlCdrReader *r, char **out) {
    const char *p;
    uint32_t    len;
    int rc = zidl_cdr_read_string_zerocopy(r, &p, &len);
    if (rc) return rc;
    /* Reject an embedded NUL before the content ends: IDL string semantics
     * are C-string-like (NUL-terminated) already, so wire content with a
     * NUL before the final byte is malformed, not merely unusual — and
     * rejecting it here is what makes zidl_cdr_free_str's strlen(s)+1 size
     * reconstruction provably correct for every string this function ever
     * successfully returns, rather than merely correct for well-formed
     * ones. Checked against the source bytes before allocating anything. */
    if (len > 0 && memchr(p, '\0', len) != NULL) return ZIDL_CDR_INVALID;
    char *buf = (char *)zidl_cdr_alloc(len + 1u);
    if (!buf) return ZIDL_CDR_OVERFLOW;
    memcpy(buf, p, len);
    buf[len] = '\0';
    *out = buf;
    return ZIDL_CDR_OK;
}

/* Allocation-free wide span validation; interior zero code units are valid. */
int zidl_cdr_skip_wstring(ZidlCdrReader *r) {
    uint32_t count;
    int rc = zidl_cdr_read_u32(r, &count);
    if (rc) return rc;
    if (count & 1u) return ZIDL_CDR_INVALID;
    if (r->pos > r->data_len || (size_t)count > r->data_len - r->pos)
        return ZIDL_CDR_TRUNCATED;
    r->pos += count;
    return ZIDL_CDR_OK;
}

int zidl_cdr_read_wstring(ZidlCdrReader *r, uint16_t **out, uint32_t *out_len) {
    ZidlCdrReader probe = *r;
    int rc = zidl_cdr_skip_wstring(&probe);
    if (rc) { r->pos = probe.pos; return rc; }
    uint32_t byte_count;
    rc = zidl_cdr_read_u32(r, &byte_count);
    if (rc) return rc;
    size_t start = r->pos;
    r->pos = probe.pos;
    uint32_t count = byte_count / 2u;
    /* Owned C strings append a local sentinel and cannot contain interior NUL.
     * Validate the whole span before allocating; the wire has no terminator. */
    for (uint32_t i = 0; i < count; i++) {
        size_t pos = start + (size_t)i * 2u;
        if (!r->data[pos] && !r->data[pos + 1u]) return ZIDL_CDR_INVALID;
    }
    size_t size = (size_t)byte_count + sizeof(uint16_t);
    if (size < byte_count) return ZIDL_CDR_OVERFLOW;
    uint16_t *buf = (uint16_t *)zidl_cdr_alloc(size);
    if (!buf) return ZIDL_CDR_OVERFLOW;
    ZidlCdrReader content = *r;
    content.pos = start;
    for (uint32_t i = 0; i < count; i++) {
        rc = zidl_cdr_read_u16(&content, &buf[i]);
        if (rc) { zidl_cdr_free(buf, size); return rc; }
    }
    buf[count] = 0;
    *out = buf;
    *out_len = count;
    return ZIDL_CDR_OK;
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

/* ── XCDR2 framing ───────────────────────────────────────────────────────── */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_read_dheader(ZidlCdrReader *r, uint32_t *out) {
    return zidl_cdr_read_u32(r, out);
}

int zidl_cdr_skip_dheader_if_xcdr2(ZidlCdrReader *r) {
    if (r->xcdr_version == ZIDL_XCDR2) {
        uint32_t dummy;
        return zidl_cdr_read_dheader(r, &dummy);
    }
    return ZIDL_CDR_OK;
}

int zidl_cdr_read_emheader(ZidlCdrReader *r, ZidlEmHeader *out) {
    uint32_t word;
    int rc = zidl_cdr_read_u32(r, &word);
    if (rc) return rc;
    out->must_understand = (word & 0x80000000u) != 0;
    out->lc       = (uint8_t)((word >> 28) & 0x7u);
    out->member_id = word & 0x0FFFFFFFu;
    switch (out->lc) {
        case 0: out->payload_bytes = 1u; break;
        case 1: out->payload_bytes = 2u; break;
        case 2: out->payload_bytes = 4u; break;
        case 3: out->payload_bytes = 8u; break;
        case 4:
            /* A separate NEXTINT holding the member's byte length. */
            rc = zidl_cdr_read_u32(r, &out->payload_bytes);
            if (rc) return rc;
            break;
        default: {
            /* LC 5-7: the NEXTINT is the first word of the member value (its
             * DHEADER, string length or sequence length), so peek it and leave
             * the reader at the start of the value (XTypes 1.3 7.4.3.4.8). */
            size_t start = r->pos;
            uint32_t nextint;
            rc = zidl_cdr_read_u32(r, &nextint);
            if (rc) return rc;
            r->pos = start;
            unsigned shift = out->lc == 5 ? 0u : out->lc == 6 ? 2u : 3u;
            uint64_t bytes = ((uint64_t)nextint << shift) + 4u;
            if (bytes > UINT32_MAX) return ZIDL_CDR_INVALID;
            out->payload_bytes = (uint32_t)bytes;
            break;
        }
    }
    return ZIDL_CDR_OK;
}

int zidl_cdr_write_emheader(ZidlCdrWriter *w, uint32_t member_id,
                             bool must_understand, uint8_t lc) {
    uint32_t mu  = must_understand ? 0x80000000u : 0u;
    uint32_t word = mu | ((uint32_t)(lc & 0x7u) << 28) | (member_id & 0x0FFFFFFFu);
    return zidl_cdr_write_u32(w, word);
}

int zidl_cdr_reserve_emheader(ZidlCdrWriter *w, uint32_t member_id,
                               bool must_understand, size_t *out_nextint_offset) {
    uint32_t mu  = must_understand ? 0x80000000u : 0u;
    /* LC=4: NEXTINT encodes payload byte count directly */
    uint32_t word = mu | (4u << 28) | (member_id & 0x0FFFFFFFu);
    int rc = zidl_cdr_write_u32(w, word);
    if (rc) return rc;
    *out_nextint_offset = w->len;
    return zidl_cdr_write_u32(w, 0); /* placeholder NEXTINT */
}

void zidl_cdr_patch_emheader(ZidlCdrWriter *w, size_t nextint_offset,
                              size_t payload_start) {
    uint32_t payload_bytes = (uint32_t)(w->len - payload_start);
    writer_store_u32_at(w, nextint_offset, payload_bytes);
}

int zidl_cdr_read_mutable_dheader(ZidlCdrReader *r, size_t *out_end_pos) {
    uint32_t size;
    int rc = zidl_cdr_read_dheader(r, &size);
    if (rc) return rc;
    *out_end_pos = r->pos + (size_t)size;
    return ZIDL_CDR_OK;
}

bool zidl_cdr_mutable_has_more(const ZidlCdrReader *r, size_t end_pos) {
    return r->pos < end_pos;
}

int zidl_cdr_skip_emheader_payload(ZidlCdrReader *r, const ZidlEmHeader *emh) {
    if (emh->lc < 4) {
        /* Align to the primitive size before skipping */
        size_t cap = align_cap(r->xcdr_version, emh->payload_bytes);
        int rc = reader_align_pos(r, cap);
        if (rc) return rc;
    }
    return zidl_cdr_skip(r, emh->payload_bytes);
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

/* ── Utility ─────────────────────────────────────────────────────────────── */

size_t zidl_cdr_remaining(const ZidlCdrReader *r) {
    return (r->pos < r->data_len) ? (r->data_len - r->pos) : 0;
}

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_skip(ZidlCdrReader *r, size_t n) {
    /* `n > data_len - pos` rather than `pos + n > data_len`: pos <= data_len is
     * invariant (see reader_read_slice), so the subtraction is safe, and this
     * cannot wrap for a hostile n (e.g. an overflowed sequence byte count) the
     * way `pos + n` would. */
    if (n > r->data_len - r->pos) return ZIDL_CDR_TRUNCATED;
    r->pos += n;
    return ZIDL_CDR_OK;
}

int zidl_cdr_skip_primitives(ZidlCdrReader *r, uint32_t count, size_t elem_wire_size) {
    /* An empty sequence emits no elements and therefore no leading element
     * alignment padding -- only the length prefix (already consumed by the
     * caller). Aligning here would skip bytes that belong to the next member.
     * A fixed-size array always has count >= 1, so this only guards sequences. */
    if (count == 0) return ZIDL_CDR_OK;
    if (elem_wire_size > 1)
        reader_align_pos(r, align_cap(r->xcdr_version, elem_wire_size));
    /* (size_t)count * elem_wire_size can wrap on a 32-bit size_t for a
     * hostile wire-provided length; reject rather than skip a truncated body. */
    if (elem_wire_size != 0 && count > ((size_t)-1) / elem_wire_size)
        return ZIDL_CDR_TRUNCATED;
    return zidl_cdr_skip(r, (size_t)count * elem_wire_size);
}

int zidl_cdr_seek_to(ZidlCdrReader *r, size_t abs_pos) {
    if (abs_pos > r->data_len) return ZIDL_CDR_TRUNCATED;
    r->pos = abs_pos;
    return ZIDL_CDR_OK;
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

/* ── MD5 / key hash ─────────────────────────────────────────────────────── */

typedef struct ZidlMd5Ctx {
    uint32_t h[4];
    uint64_t bit_len;
    uint8_t  block[64];
    size_t   block_len;
} ZidlMd5Ctx;

static uint32_t md5_rotl(uint32_t x, uint32_t c) {
    return (x << c) | (x >> (32u - c));
}

static uint32_t md5_load32_le(const uint8_t *p) {
    return ((uint32_t)p[0]) |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static void md5_store32_le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void md5_transform(ZidlMd5Ctx *ctx, const uint8_t block[64]) {
    static const uint32_t s[64] = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    };
    static const uint32_t k[64] = {
        0xd76aa478u, 0xe8c7b756u, 0x242070dbu, 0xc1bdceeeu,
        0xf57c0fafu, 0x4787c62au, 0xa8304613u, 0xfd469501u,
        0x698098d8u, 0x8b44f7afu, 0xffff5bb1u, 0x895cd7beu,
        0x6b901122u, 0xfd987193u, 0xa679438eu, 0x49b40821u,
        0xf61e2562u, 0xc040b340u, 0x265e5a51u, 0xe9b6c7aau,
        0xd62f105du, 0x02441453u, 0xd8a1e681u, 0xe7d3fbc8u,
        0x21e1cde6u, 0xc33707d6u, 0xf4d50d87u, 0x455a14edu,
        0xa9e3e905u, 0xfcefa3f8u, 0x676f02d9u, 0x8d2a4c8au,
        0xfffa3942u, 0x8771f681u, 0x6d9d6122u, 0xfde5380cu,
        0xa4beea44u, 0x4bdecfa9u, 0xf6bb4b60u, 0xbebfbc70u,
        0x289b7ec6u, 0xeaa127fau, 0xd4ef3085u, 0x04881d05u,
        0xd9d4d039u, 0xe6db99e5u, 0x1fa27cf8u, 0xc4ac5665u,
        0xf4292244u, 0x432aff97u, 0xab9423a7u, 0xfc93a039u,
        0x655b59c3u, 0x8f0ccc92u, 0xffeff47du, 0x85845dd1u,
        0x6fa87e4fu, 0xfe2ce6e0u, 0xa3014314u, 0x4e0811a1u,
        0xf7537e82u, 0xbd3af235u, 0x2ad7d2bbu, 0xeb86d391u,
    };
    uint32_t m[16];
    for (int i = 0; i < 16; i++) m[i] = md5_load32_le(block + (size_t)i * 4u);

    uint32_t a = ctx->h[0];
    uint32_t b = ctx->h[1];
    uint32_t c = ctx->h[2];
    uint32_t d = ctx->h[3];

    for (uint32_t i = 0; i < 64u; i++) {
        uint32_t f, g;
        if (i < 16u) {
            f = (b & c) | ((~b) & d);
            g = i;
        } else if (i < 32u) {
            f = (d & b) | ((~d) & c);
            g = (5u * i + 1u) & 15u;
        } else if (i < 48u) {
            f = b ^ c ^ d;
            g = (3u * i + 5u) & 15u;
        } else {
            f = c ^ (b | (~d));
            g = (7u * i) & 15u;
        }
        uint32_t tmp = d;
        d = c;
        c = b;
        b = b + md5_rotl(a + f + k[i] + m[g], s[i]);
        a = tmp;
    }

    ctx->h[0] += a;
    ctx->h[1] += b;
    ctx->h[2] += c;
    ctx->h[3] += d;
}

static void md5_init(ZidlMd5Ctx *ctx) {
    ctx->h[0] = 0x67452301u;
    ctx->h[1] = 0xefcdab89u;
    ctx->h[2] = 0x98badcfeu;
    ctx->h[3] = 0x10325476u;
    ctx->bit_len = 0;
    ctx->block_len = 0;
}

static void md5_update(ZidlMd5Ctx *ctx, const uint8_t *data, size_t len) {
    ctx->bit_len += (uint64_t)len * 8u;
    while (len > 0) {
        size_t n = 64u - ctx->block_len;
        if (n > len) n = len;
        memcpy(ctx->block + ctx->block_len, data, n);
        ctx->block_len += n;
        data += n;
        len -= n;
        if (ctx->block_len == 64u) {
            md5_transform(ctx, ctx->block);
            ctx->block_len = 0;
        }
    }
}

static void md5_final(ZidlMd5Ctx *ctx, uint8_t out[16]) {
    uint64_t bit_len = ctx->bit_len;
    uint8_t one = 0x80u;
    uint8_t zero = 0u;
    md5_update(ctx, &one, 1);
    while (ctx->block_len != 56u) md5_update(ctx, &zero, 1);

    uint8_t len_bytes[8];
    for (int i = 0; i < 8; i++) len_bytes[i] = (uint8_t)(bit_len >> (8u * (uint32_t)i));
    md5_update(ctx, len_bytes, 8);

    for (int i = 0; i < 4; i++) md5_store32_le(out + (size_t)i * 4u, ctx->h[i]);
}

void zidl_md5(const uint8_t *data, size_t len, uint8_t out[16]) {
    ZidlMd5Ctx ctx;
    md5_init(&ctx);
    md5_update(&ctx, data, len);
    md5_final(&ctx, out);
}

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
void zidl_cdr_compute_key_hash(const uint8_t *serialized_key, size_t len, uint8_t out[16]) {
    if (len <= 16u) {
        memset(out, 0, 16u);
        if (len > 0) memcpy(out, serialized_key, len);
        return;
    }
    zidl_md5(serialized_key, len, out);
}

void zidl_cdr_compute_key_hash_for_type(const uint8_t *key, size_t len, bool force_md5, uint8_t out[16]) {
    if (force_md5) zidl_md5(key, len, out);
    else zidl_cdr_compute_key_hash(key, len, out);
}
int zidl_cdr_write_key_wstring_length(ZidlCdrWriter *w, uint32_t len) {
    if (len > UINT32_MAX / 2u) return ZIDL_CDR_OVERFLOW;
    return zidl_cdr_write_u32(w, len * 2u);
}
int zidl_cdr_write_key_wstring(ZidlCdrWriter *w, const uint16_t *value, uint32_t len) {
    if (len > UINT32_MAX / 2u) return ZIDL_CDR_OVERFLOW;
    if (len && !value) return ZIDL_CDR_INVALID;
    int rc = zidl_cdr_write_key_wstring_length(w, len);
    if (rc) return rc;
    for (uint32_t i = 0; i < len; i++) {
        rc = zidl_cdr_write_u16(w, value[i]);
        if (rc) return rc;
    }
    return ZIDL_CDR_OK;
}
#endif

/* ── PL_CDR writer ───────────────────────────────────────────────────────── */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_pl_write_encap(ZidlCdrWriter *w) {
    static const uint8_t hdr[4] = { 0x00u, 0x03u, 0x00u, 0x00u };
    int rc = writer_ensure(w, 4);
    if (rc) return rc;
    if (w->buf) memcpy(w->buf + w->len, hdr, 4);
    w->len += 4;
    w->pos  = 0;
    return ZIDL_CDR_OK;
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_pl_reserve_param(ZidlCdrWriter *w, uint16_t pid,
                               ZidlPlParamHandle *out_handle) {
    /* Write pid as LE u16; we're always at a 4-byte boundary, so no padding needed */
    int rc = zidl_cdr_write_u16(w, pid);
    if (rc) return rc;
    out_handle->len_offset = w->len;
    rc = zidl_cdr_write_u16(w, 0u); /* placeholder length */
    if (rc) return rc;
    out_handle->buf_value_start = w->len;
    return ZIDL_CDR_OK;
}

int zidl_cdr_pl_patch_param(ZidlCdrWriter *w, ZidlPlParamHandle handle) {
    size_t raw_bytes = w->len - handle.buf_value_start;
    size_t rem       = raw_bytes % 4u;
    size_t pad       = (rem == 0u) ? 0u : (4u - rem);
    if (pad > 0u) {
        static const uint8_t zeros[4] = {0,0,0,0};
        int rc = writer_write_bytes(w, zeros, pad);
        if (rc) return rc;
    }
    uint16_t padded = (uint16_t)(raw_bytes + pad);
    if (w->buf) {
        w->buf[handle.len_offset]     = (uint8_t)(padded & 0xFFu);
        w->buf[handle.len_offset + 1] = (uint8_t)(padded >> 8);
    }
    return ZIDL_CDR_OK;
}

int zidl_cdr_pl_write_sentinel(ZidlCdrWriter *w) {
    static const uint8_t sentinel[4] = { 0x01u, 0x00u, 0x00u, 0x00u };
    int rc = writer_ensure(w, 4);
    if (rc) return rc;
    if (w->buf) memcpy(w->buf + w->len, sentinel, 4);
    w->len += 4;
    w->pos += 4;
    return ZIDL_CDR_OK;
}

/* ── PL_CDR reader ───────────────────────────────────────────────────────── */

int zidl_cdr_pl_read_param(ZidlCdrReader *r, ZidlPlParam *out) {
    uint16_t pid, len;
    int rc = zidl_cdr_read_u16(r, &pid);
    if (rc) return rc;
    rc = zidl_cdr_read_u16(r, &len);
    if (rc) return rc;
    out->pid      = pid;
    out->byte_len = len;
    /* end_pos = current pos + round_up_4(len) */
    size_t padded = ((size_t)len + 3u) & ~(size_t)3u;
    out->end_pos  = r->pos + padded;
    return ZIDL_CDR_OK;
}

#endif /* ZIDL_CDR_SHARED_PRIMITIVES */

#ifndef ZIDL_CDR_SHARED_PRIMITIVES
/* Additive checked APIs are also available with the independent C reference. */
static int checked_patch(ZidlCdrWriter *w, size_t offset, size_t start) {
    if (offset > w->len || 4u > w->len - offset || start != offset + 4u)
        return ZIDL_CDR_INVALID;
    if (w->buf && w->len > w->cap) return ZIDL_CDR_INVALID;
#if SIZE_MAX > UINT32_MAX
    if (w->len - start > UINT32_MAX) return ZIDL_CDR_OVERFLOW;
#endif
    writer_store_u32_at(w, offset, (uint32_t)(w->len - start));
    return ZIDL_CDR_OK;
}
int zidl_cdr_patch_dheader_checked(ZidlCdrWriter *w, size_t offset) {
    if (offset > w->len || 4u > w->len - offset) return ZIDL_CDR_INVALID;
    return checked_patch(w, offset, offset + 4u);
}
int zidl_cdr_patch_emheader_checked(ZidlCdrWriter *w, size_t offset, size_t start) {
    return checked_patch(w, offset, start);
}
int zidl_cdr_reader_limit(const ZidlCdrReader *r, size_t end, ZidlCdrReader *out) {
    if (end > r->data_len || r->pos > end) return ZIDL_CDR_TRUNCATED;
    *out = *r;
    out->data_len = end;
    return ZIDL_CDR_OK;
}
int zidl_cdr_emheader_end(const ZidlCdrReader *r, const ZidlEmHeader *em, size_t *out) {
    size_t pos = r->pos;
    if (em->lc > 7u) return ZIDL_CDR_INVALID;
    if (pos > r->data_len) return ZIDL_CDR_TRUNCATED;
    if (em->lc < 4u) {
        if (em->payload_bytes != (1u << em->lc)) return ZIDL_CDR_INVALID;
        if (pos < 4u) return ZIDL_CDR_TRUNCATED;
        size_t boundary = align_cap(r->xcdr_version, em->payload_bytes);
        size_t rem = (pos - 4u) % boundary;
        size_t pad = rem ? boundary - rem : 0u;
        if (pad > r->data_len - pos) return ZIDL_CDR_TRUNCATED;
        pos += pad;
    }
    if (em->payload_bytes > r->data_len - pos) return ZIDL_CDR_TRUNCATED;
    *out = pos + em->payload_bytes;
    return ZIDL_CDR_OK;
}
#endif


#ifndef ZIDL_CDR_SHARED_PRIMITIVES
int zidl_cdr_begin_optional_write(ZidlCdrWriter *w, uint32_t id, bool mu,
                                  bool present, ZidlCdrOptionalWrite *scope) {
    int rc;
    size_t pad;
    static const uint8_t zeros[4] = {0};
    if (id > 0x0fffffffu) return ZIDL_CDR_INVALID;
    if (w->xcdr_version == ZIDL_XCDR2) {
        rc = zidl_cdr_write_bool(w, present);
        if (rc) return rc;
        scope->length_offset = SIZE_MAX;
        scope->value_start = scope->parent_pos = 0;
        return ZIDL_CDR_OK;
    }
    pad = (4u - w->pos % 4u) % 4u;
    rc = writer_write_bytes(w, zeros, pad);
    if (rc) return rc;
    rc = zidl_cdr_write_u16(w, 0x7f01u);
    if (rc) return rc;
    rc = zidl_cdr_write_u16(w, 8);
    if (rc) return rc;
    rc = zidl_cdr_write_u32(w, id | (mu ? 0x40000000u : 0));
    if (rc) return rc;
    scope->length_offset = w->len;
    rc = zidl_cdr_write_u32(w, 0);
    if (rc) return rc;
    scope->value_start = w->len;
    scope->parent_pos = w->pos;
    w->pos = 0;
    return ZIDL_CDR_OK;
}

static bool optional_write_valid(const ZidlCdrWriter *w, const ZidlCdrOptionalWrite *s) {
    return s->value_start <= w->len && s->parent_pos <= s->value_start &&
        s->length_offset <= s->value_start && s->value_start - s->length_offset == 4;
}
void zidl_cdr_cancel_optional_write(ZidlCdrWriter *w, const ZidlCdrOptionalWrite *s) {
    if (s->length_offset != SIZE_MAX && optional_write_valid(w, s))
        w->pos = s->parent_pos + (w->len - s->value_start);
}
int zidl_cdr_end_optional_write(ZidlCdrWriter *w, const ZidlCdrOptionalWrite *s) {
    uint32_t size;
    if (s->length_offset == SIZE_MAX) return ZIDL_CDR_OK;
    if (!optional_write_valid(w, s)) return ZIDL_CDR_INVALID;
    zidl_cdr_cancel_optional_write(w, s);
    if (w->len - s->value_start > UINT32_MAX) return ZIDL_CDR_OVERFLOW;
    size = (uint32_t)(w->len - s->value_start);
    if (w->buf) {
        size_t i;
        if (w->len > w->cap) return ZIDL_CDR_INVALID;
        for (i = 0; i < 4; ++i)
            w->buf[s->length_offset + i] = (uint8_t)(size >> (8 * (w->byte_order == ZIDL_CDR_BE ? 3 - i : i)));
    }
    return ZIDL_CDR_OK;
}

int zidl_cdr_begin_optional_read(ZidlCdrReader *r, uint32_t id,
                                 ZidlCdrOptionalRead *s, bool *present) {
    uint16_t pid, short_size;
    uint32_t actual, size;
    size_t start, end;
    int rc;
    if (id > 0x0fffffffu) return ZIDL_CDR_INVALID;
    if (r->xcdr_version == ZIDL_XCDR2) {
        rc = zidl_cdr_read_bool(r, present);
        if (rc) return rc;
        s->parent = *r;
        s->end = SIZE_MAX;
        return ZIDL_CDR_OK;
    }
    rc = reader_align_pos(r, 4);
    if (rc) return rc;
    rc = zidl_cdr_read_u16(r, &pid);
    if (rc) return rc;
    rc = zidl_cdr_read_u16(r, &short_size);
    if (rc) return rc;
    if (pid & 0x8000u) return ZIDL_CDR_INVALID;
    actual = pid & 0x3fffu;
    size = short_size;
    if (actual == 0x3f01u) {
        if (short_size != 8) return ZIDL_CDR_INVALID;
        rc = zidl_cdr_read_u32(r, &actual);
        if (rc) return rc;
        if (actual & 0x80000000u) return ZIDL_CDR_INVALID;
        actual &= 0x0fffffffu;
        rc = zidl_cdr_read_u32(r, &size);
        if (rc) return rc;
    } else if (actual > 0x3f00u) return ZIDL_CDR_INVALID;
    if (actual != id) return ZIDL_CDR_INVALID;
    start = r->pos;
    if (start > r->data_len || size > r->data_len - start) return ZIDL_CDR_TRUNCATED;
    end = start + size;
    s->parent = *r;
    s->parent.pos = s->end = end;
    r->data += start - 4;
    r->data_len = 4 + (size_t)size;
    r->pos = 4;
    *present = size != 0;
    return ZIDL_CDR_OK;
}
void zidl_cdr_end_optional_read(ZidlCdrReader *r, const ZidlCdrOptionalRead *s) {
    size_t pos = r->pos;
    *r = s->parent;
    if (s->end == SIZE_MAX) r->pos = pos;
}
#endif
