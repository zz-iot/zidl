#include "zidl_cdr.h"
#include <string.h>

#define CHECK(x) do { if (!(x)) return __LINE__; } while (0)

static size_t unhex(uint8_t *out, const char *hex) {
    size_t n = 0;
    while (*hex) {
        unsigned hi = (unsigned)(*hex <= '9' ? *hex - '0' : *hex - 'a' + 10);
        unsigned lo;
        ++hex;
        lo = (unsigned)(*hex <= '9' ? *hex - '0' : *hex - 'a' + 10);
        ++hex;
        out[n++] = (uint8_t)((hi << 4) | lo);
    }
    return n;
}

static int sample(ZidlCdrWriter *w) {
    ZidlCdrOptionalWrite s;
    int rc = zidl_cdr_write_encap(w);
    if (rc) return rc;
    rc = zidl_cdr_begin_optional_write(w, 0x3f01, true, true, &s);
    if (rc) return rc;
    rc = zidl_cdr_write_u8(w, 0xa5);
    if (!rc) rc = zidl_cdr_write_u64(w, UINT64_C(0x0102030405060708));
    if (rc) { zidl_cdr_cancel_optional_write(w, &s); return rc; }
    rc = zidl_cdr_end_optional_write(w, &s);
    if (rc) return rc;
    rc = zidl_cdr_write_u64(w, UINT64_C(0x1122334455667788));
    if (rc) return rc;
    rc = zidl_cdr_begin_optional_write(w, 0, false, false, &s);
    if (rc) return rc;
    return zidl_cdr_end_optional_write(w, &s);
}

static int read_sample(ZidlCdrReader *r) {
    ZidlCdrOptionalRead s;
    bool present;
    uint8_t a;
    uint64_t b;
    int rc = zidl_cdr_begin_optional_read(r, 0x3f01, &s, &present);
    if (rc) return rc;
    if (!present) { zidl_cdr_end_optional_read(r, &s); return ZIDL_CDR_INVALID; }
    rc = zidl_cdr_read_u8(r, &a);
    if (!rc) rc = zidl_cdr_read_u64(r, &b);
    zidl_cdr_end_optional_read(r, &s);
    if (rc) return rc;
    if (a != 0xa5 || b != UINT64_C(0x0102030405060708)) return ZIDL_CDR_INVALID;
    rc = zidl_cdr_read_u64(r, &b);
    if (rc) return rc;
    if (b != UINT64_C(0x1122334455667788)) return ZIDL_CDR_INVALID;
    rc = zidl_cdr_begin_optional_read(r, 0, &s, &present);
    if (rc) return rc;
    zidl_cdr_end_optional_read(r, &s);
    return present ? ZIDL_CDR_INVALID : ZIDL_CDR_OK;
}

/* These wire witnesses are specified independently of either codec. */
int optional_wire_tests(void) {
    const char *vectors[2][2] = {
        {"00010000017f0800013f004010000000a5000000000000000807060504030201000000008877665544332211017f08000000000000000000",
         "000000007f01000840003f0100000010a50000000000000001020304050607080000000011223344556677887f0100080000000000000000"},
        {"0007000001a500000807060504030201887766554433221100",
         "0006000001a500000102030405060708112233445566778800"}
    };
    int version, order, mode;
    for (version = 1; version <= 2; ++version) for (order = 0; order <= 1; ++order) {
        uint8_t expected[80], actual[80];
        size_t len = unhex(expected, vectors[version - 1][order]);
        ZidlCdrReader r;
        for (mode = 0; mode < 3; ++mode) {
            ZidlCdrWriter w;
            if (mode == 0) CHECK(zidl_cdr_writer_init(&w, version) == 0);
            else if (mode == 1) zidl_cdr_writer_init_fixed(&w, actual, sizeof actual, version);
            else zidl_cdr_writer_init_counting(&w, version);
            zidl_cdr_writer_set_byte_order(&w, order);
            CHECK(sample(&w) == 0);
            CHECK(w.len == len && w.pos == len - 4);
            if (mode != 2) CHECK(memcmp(w.buf, expected, len) == 0);
            if (mode == 0) zidl_cdr_writer_deinit(&w);
        }
        CHECK(zidl_cdr_reader_init(&r, expected, len) == 0);
        CHECK(read_sample(&r) == 0 && r.pos == len && r.data == expected);
        {
            size_t n;
            for (n = 4; n < len; ++n) {
                CHECK(zidl_cdr_reader_init(&r, expected, n) == 0);
                CHECK(read_sample(&r) != 0);
                CHECK(r.data == expected && r.data_len == n && r.pos <= n);
            }
        }
    }
    {
        /* Short headers accept ID 0 and the upper short-ID boundary. */
        uint8_t bytes[40];
        size_t len = unhex(bytes, "00010000000008000807060504030201007f0000");
        ZidlCdrReader r;
        ZidlCdrOptionalRead s;
        uint64_t value;
        bool present;
        CHECK(zidl_cdr_reader_init(&r, bytes, len) == 0);
        CHECK(zidl_cdr_begin_optional_read(&r, 0, &s, &present) == 0 && present);
        CHECK(zidl_cdr_read_u64(&r, &value) == 0 && value == UINT64_C(0x0102030405060708));
        CHECK(zidl_cdr_read_u64(&r, &value) == ZIDL_CDR_TRUNCATED);
        zidl_cdr_end_optional_read(&r, &s);
        CHECK(zidl_cdr_begin_optional_read(&r, 0x3f00, &s, &present) == 0 && !present);
        zidl_cdr_end_optional_read(&r, &s);
        CHECK(r.pos == len);
    }
    {
        /* Nested frames restore both origins even after a bounded read fails. */
        uint8_t bytes[80];
        ZidlCdrWriter w;
        ZidlCdrReader r;
        ZidlCdrOptionalWrite outer, inner;
        ZidlCdrOptionalRead a, b;
        bool present;
        uint64_t value;
        zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, 1);
        CHECK(zidl_cdr_write_encap(&w) == 0);
        CHECK(zidl_cdr_begin_optional_write(&w, 3, false, true, &outer) == 0);
        CHECK(zidl_cdr_write_u8(&w, 7) == 0);
        CHECK(zidl_cdr_begin_optional_write(&w, 4, false, true, &inner) == 0);
        CHECK(zidl_cdr_write_u64(&w, 42) == 0);
        CHECK(zidl_cdr_end_optional_write(&w, &inner) == 0);
        CHECK(zidl_cdr_end_optional_write(&w, &outer) == 0);
        CHECK(zidl_cdr_write_u64(&w, 99) == 0);
        CHECK(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
        CHECK(zidl_cdr_begin_optional_read(&r, 3, &a, &present) == 0 && present);
        CHECK(zidl_cdr_skip(&r, 1) == 0);
        CHECK(zidl_cdr_begin_optional_read(&r, 4, &b, &present) == 0 && present);
        CHECK(zidl_cdr_read_u64(&r, &value) == 0 && value == 42);
        CHECK(zidl_cdr_read_u64(&r, &value) == ZIDL_CDR_TRUNCATED);
        zidl_cdr_end_optional_read(&r, &b);
        zidl_cdr_end_optional_read(&r, &a);
        CHECK(zidl_cdr_read_u64(&r, &value) == 0 && value == 99);
    }
    {
        const char *invalid[] = {
            "0001000001800000", "00010000023f0000",
            "00010000017f04000000000000000000",
            "00010000017f08000000008000000000", "0001000001000000"
        };
        size_t i;
        for (i = 0; i < sizeof invalid / sizeof *invalid; ++i) {
            uint8_t bytes[40];
            ZidlCdrReader r;
            ZidlCdrOptionalRead scope;
            bool present;
            size_t len = unhex(bytes, invalid[i]);
            CHECK(zidl_cdr_reader_init(&r, bytes, len) == 0);
            CHECK(zidl_cdr_begin_optional_read(&r, 0, &scope, &present) == ZIDL_CDR_INVALID);
        }
    }
    {
        ZidlCdrWriter w;
        ZidlCdrOptionalWrite scope;
        uint8_t large[65553];
        size_t i;
        zidl_cdr_writer_init_fixed(&w, large, sizeof large, 1);
        CHECK(zidl_cdr_write_encap(&w) == 0);
        CHECK(zidl_cdr_begin_optional_write(&w, 0x0fffffff, false, true, &scope) == 0);
        for (i = 0; i < 65537; ++i) CHECK(zidl_cdr_write_u8(&w, 0) == 0);
        CHECK(zidl_cdr_end_optional_write(&w, &scope) == 0);
        CHECK(large[12] == 1 && large[13] == 0 && large[14] == 1 && large[15] == 0);
        zidl_cdr_writer_init_counting(&w, 1);
        CHECK(zidl_cdr_write_encap(&w) == 0);
        CHECK(zidl_cdr_begin_optional_write(&w, 0x0fffffff, false, true, &scope) == 0);
        for (i = 0; i < 65537; ++i) CHECK(zidl_cdr_write_u8(&w, 0) == 0);
        CHECK(zidl_cdr_end_optional_write(&w, &scope) == 0);
        CHECK(w.len == 16 + 65537 && w.pos == 12 + 65537);
        CHECK(zidl_cdr_begin_optional_write(&w, 0x10000000, false, true, &scope) == ZIDL_CDR_INVALID);
        if (SIZE_MAX > UINT32_MAX) {
            CHECK(zidl_cdr_begin_optional_write(&w, 7, false, true, &scope) == 0);
            w.len = scope.value_start + (size_t)UINT32_MAX + 1;
            CHECK(zidl_cdr_end_optional_write(&w, &scope) == ZIDL_CDR_OVERFLOW);
            CHECK(w.pos == w.len - 4);
        }
    }
    {
        uint8_t bytes[17];
        ZidlCdrWriter w;
        ZidlCdrOptionalWrite scope, invalid = { 19, 16, 12 };
        zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, 1);
        CHECK(zidl_cdr_write_encap(&w) == 0);
        CHECK(zidl_cdr_begin_optional_write(&w, 7, false, true, &scope) == 0);
        CHECK(zidl_cdr_write_u8(&w, 42) == 0);
        CHECK(zidl_cdr_write_u64(&w, 99) == ZIDL_CDR_OVERFLOW);
        zidl_cdr_cancel_optional_write(&w, &scope);
        CHECK(w.pos == 13 && w.len == 17);
        CHECK(zidl_cdr_end_optional_write(&w, &invalid) == ZIDL_CDR_INVALID);
        CHECK(w.pos == 13 && w.len == 17);
    }
    return 0;
}

typedef struct { char c; ZidlCdrOptionalWrite scope; } OptionalWriteAligned;
typedef struct { char c; ZidlCdrOptionalRead scope; } OptionalReadAligned;
void optional_layout(size_t *out) {
    out[0] = sizeof(ZidlCdrOptionalWrite);
    out[1] = offsetof(OptionalWriteAligned, scope);
    out[2] = offsetof(ZidlCdrOptionalWrite, length_offset);
    out[3] = offsetof(ZidlCdrOptionalWrite, value_start);
    out[4] = offsetof(ZidlCdrOptionalWrite, parent_pos);
    out[5] = sizeof(ZidlCdrOptionalRead);
    out[6] = offsetof(OptionalReadAligned, scope);
    out[7] = offsetof(ZidlCdrOptionalRead, parent);
    out[8] = offsetof(ZidlCdrOptionalRead, end);
}
