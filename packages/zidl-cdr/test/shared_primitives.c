/* Independent C compiler view of the public ABI and a real foreign caller. */
#include "zidl_cdr.h"
#include <stddef.h>
#include <string.h>

void shared_primitives_layout(size_t out[17]) {
    out[0] = sizeof(ZidlCdrWriter);
    out[1] = _Alignof(ZidlCdrWriter);
    out[2] = offsetof(ZidlCdrWriter, buf);
    out[3] = offsetof(ZidlCdrWriter, cap);
    out[4] = offsetof(ZidlCdrWriter, len);
    out[5] = offsetof(ZidlCdrWriter, pos);
    out[6] = offsetof(ZidlCdrWriter, xcdr_version);
    out[7] = offsetof(ZidlCdrWriter, byte_order);
    out[8] = offsetof(ZidlCdrWriter, hash);
    out[9] = sizeof(ZidlCdrReader);
    out[10] = _Alignof(ZidlCdrReader);
    out[11] = offsetof(ZidlCdrReader, data);
    out[12] = offsetof(ZidlCdrReader, data_len);
    out[13] = offsetof(ZidlCdrReader, pos);
    out[14] = offsetof(ZidlCdrReader, byte_order);
    out[15] = offsetof(ZidlCdrReader, xcdr_version);
    out[16] = offsetof(ZidlCdrReader, is_pl_cdr);
}

int shared_primitives_sample(ZidlCdrWriter *w) {
    int rc;
#define WRITE(name, value) do { rc = zidl_cdr_write_##name(w, value); if (rc) return rc; } while (0)
    WRITE(u8, 0xab);
    WRITE(i8, -2);
    WRITE(bool, true);
    WRITE(char, 'Q');
    WRITE(u16, 0x1234);
    WRITE(i16, -3);
    WRITE(u32, 0x12345678);
    WRITE(i32, -4);
    WRITE(f32, 1.5f);
    WRITE(u64, UINT64_C(0x0102030405060708));
    WRITE(i64, -5);
    WRITE(f64, 2.5);
#undef WRITE
    return ZIDL_CDR_OK;
}

int shared_primitives_read_sample(ZidlCdrReader *r) {
    int rc;
#define READ(name, type, expected) do { \
    type value; \
    rc = zidl_cdr_read_##name(r, &value); \
    if (rc) return rc; \
    if (value != (expected)) return -100; \
} while (0)
    READ(u8, uint8_t, 0xab);
    READ(i8, int8_t, -2);
    READ(bool, bool, true);
    READ(char, char, 'Q');
    READ(u16, uint16_t, 0x1234);
    READ(i16, int16_t, -3);
    READ(u32, uint32_t, 0x12345678);
    READ(i32, int32_t, -4);
    READ(f32, float, 1.5f);
    READ(u64, uint64_t, UINT64_C(0x0102030405060708));
    READ(i64, int64_t, -5);
    READ(f64, double, 2.5);
#undef READ
    return ZIDL_CDR_OK;
}

int shared_strings_sample(ZidlCdrWriter *w) {
    static const uint16_t wide[] = { 0x1234, 'Z' };
    int rc = zidl_cdr_write_u8(w, 0xa5);
    if (!rc) rc = zidl_cdr_write_string(w, "hi", 2);
    if (!rc) rc = zidl_cdr_write_wstring(w, wide, 2);
    if (!rc) rc = zidl_cdr_write_string(w, NULL, 0);
    if (!rc) rc = zidl_cdr_write_wstring(w, NULL, 0);
    return rc;
}

int shared_strings_read_sample(ZidlCdrReader *r) {
    uint8_t marker;
    const char *borrowed;
    uint32_t len;
    uint16_t *wide;
    char *empty;
    int matches;
    int rc = zidl_cdr_read_u8(r, &marker);
    if (rc) return rc;
    if (marker != 0xa5) return -100;
    rc = zidl_cdr_read_string_zerocopy(r, &borrowed, &len);
    if (rc) return rc;
    if (len != 2 || borrowed[0] != 'h' || borrowed[1] != 'i') return -100;
    rc = zidl_cdr_read_wstring(r, &wide, &len);
    if (rc) return rc;
    matches = len == 2 && wide[0] == 0x1234 && wide[1] == 'Z' && wide[2] == 0;
    zidl_cdr_free_wstr(wide);
    if (!matches) return -100;
    rc = zidl_cdr_read_string(r, &empty);
    if (rc) return rc;
    matches = empty[0] == 0;
    zidl_cdr_free_str(empty);
    if (!matches) return -100;
    rc = zidl_cdr_read_wstring(r, &wide, &len);
    if (rc) return rc;
    matches = len == 0 && wide[0] == 0;
    zidl_cdr_free_wstr(wide);
    return matches ? ZIDL_CDR_OK : -100;
}

void shared_framing_layout(size_t out[6]) {
    out[0] = sizeof(ZidlEmHeader);
    out[1] = _Alignof(ZidlEmHeader);
    out[2] = offsetof(ZidlEmHeader, member_id);
    out[3] = offsetof(ZidlEmHeader, must_understand);
    out[4] = offsetof(ZidlEmHeader, lc);
    out[5] = offsetof(ZidlEmHeader, payload_bytes);
}

void shared_pl_layout(size_t out[9]) {
    out[0] = sizeof(ZidlPlParamHandle);
    out[1] = _Alignof(ZidlPlParamHandle);
    out[2] = offsetof(ZidlPlParamHandle, len_offset);
    out[3] = offsetof(ZidlPlParamHandle, buf_value_start);
    out[4] = sizeof(ZidlPlParam);
    out[5] = _Alignof(ZidlPlParam);
    out[6] = offsetof(ZidlPlParam, pid);
    out[7] = offsetof(ZidlPlParam, byte_len);
    out[8] = offsetof(ZidlPlParam, end_pos);
}

int shared_pl_sample(ZidlCdrWriter *w) {
    ZidlPlParamHandle handle;
    int rc = zidl_cdr_pl_write_encap(w);
    if (!rc) rc = zidl_cdr_pl_reserve_param(w, 0x10, &handle);
    if (!rc) rc = zidl_cdr_write_u8(w, 0xa5);
    if (!rc) rc = zidl_cdr_pl_patch_param(w, handle);
    if (!rc) rc = zidl_cdr_pl_write_sentinel(w);
    return rc;
}

int shared_framing_sample(ZidlCdrWriter *w) {
    size_t dh, em, start;
    int rc = zidl_cdr_write_encap_kind(w, ZIDL_EXT_MUTABLE);
    if (!rc) rc = zidl_cdr_reserve_dheader(w, &dh);
    if (!rc) rc = zidl_cdr_write_emheader(w, 5, true, 2);
    if (!rc) rc = zidl_cdr_write_u32(w, 0x12345678);
    if (!rc) rc = zidl_cdr_reserve_emheader(w, 9, false, &em);
    if (rc) return rc;
    start = w->len;
    rc = zidl_cdr_write_u8(w, 0xa5);
    if (!rc) rc = zidl_cdr_write_u16(w, 0x1234);
    if (!rc) rc = zidl_cdr_patch_emheader_checked(w, em, start);
    if (!rc) rc = zidl_cdr_patch_dheader_checked(w, dh);
    return rc;
}

int shared_framing_read_sample(ZidlCdrReader *r) {
    size_t end, member_end;
    ZidlCdrReader parent, member;
    ZidlEmHeader em;
    uint32_t a;
    uint8_t b;
    uint16_t c;
    int rc = zidl_cdr_read_mutable_dheader(r, &end);
    if (!rc) rc = zidl_cdr_reader_limit(r, end, &parent);
    if (!rc) rc = zidl_cdr_read_emheader(&parent, &em);
    if (rc) return rc;
    if (em.member_id != 5 || !em.must_understand || em.payload_bytes != 4) return -100;
    rc = zidl_cdr_emheader_end(&parent, &em, &member_end);
    if (!rc) rc = zidl_cdr_reader_limit(&parent, member_end, &member);
    if (!rc) rc = zidl_cdr_read_u32(&member, &a);
    if (rc) return rc;
    if (a != 0x12345678) return -100;
    rc = zidl_cdr_seek_to(&parent, member_end);
    if (!rc) rc = zidl_cdr_read_emheader(&parent, &em);
    if (rc) return rc;
    if (em.member_id != 9 || em.lc != 4 || em.payload_bytes != 4) return -100;
    rc = zidl_cdr_emheader_end(&parent, &em, &member_end);
    if (!rc) rc = zidl_cdr_reader_limit(&parent, member_end, &member);
    if (!rc) rc = zidl_cdr_read_u8(&member, &b);
    if (!rc) rc = zidl_cdr_read_u16(&member, &c);
    if (rc) return rc;
    if (b != 0xa5 || c != 0x1234 || member.pos != end) return -100;
    return zidl_cdr_seek_to(r, end);
}


int bulk_primitive_arrays(void) {
    for (int version = ZIDL_XCDR1; version <= ZIDL_PL_CDR; ++version) {
        for (int endian = ZIDL_CDR_LE; endian <= ZIDL_CDR_BE; ++endian) {
#define CHECK_ARRAY(name, type, a, b, c) do { \
    const type values[] = { a, b, c }; \
    type decoded[3] = { 0 }; \
    uint8_t scalar_buf[64], bulk_buf[64]; \
    ZidlCdrWriter scalar, bulk, counting; \
    ZidlCdrReader reader; \
    zidl_cdr_writer_init_fixed(&scalar, scalar_buf, sizeof scalar_buf, version); \
    zidl_cdr_writer_init_fixed(&bulk, bulk_buf, sizeof bulk_buf, version); \
    zidl_cdr_writer_init_counting(&counting, version); \
    zidl_cdr_writer_set_byte_order(&scalar, endian); \
    zidl_cdr_writer_set_byte_order(&bulk, endian); \
    if (zidl_cdr_write_encap(&scalar) || zidl_cdr_write_encap(&bulk) || \
        zidl_cdr_write_encap(&counting) || zidl_cdr_write_u8(&scalar, 42) || \
        zidl_cdr_write_u8(&bulk, 42) || zidl_cdr_write_u8(&counting, 42)) return 26; \
    for (size_t i = 0; i < 3; ++i) \
        if (zidl_cdr_write_##name(&scalar, values[i])) return 27; \
    if (zidl_cdr_write_##name##_array(&bulk, NULL, 0) || \
        zidl_cdr_write_##name##_array(&bulk, values, 3) || \
        zidl_cdr_write_##name##_array(&counting, NULL, 3)) return 28; \
    if (bulk.len != scalar.len || counting.len != scalar.len || \
        memcmp(bulk_buf, scalar_buf, bulk.len) != 0) return 29; \
    if (zidl_cdr_reader_init(&reader, bulk_buf, bulk.len - 1) || \
        zidl_cdr_skip(&reader, 1) || \
        zidl_cdr_read_##name##_array(&reader, decoded, 3) != ZIDL_CDR_TRUNCATED || \
        reader.pos != 5 || decoded[0] != 0) return 30; \
    if (zidl_cdr_reader_init(&reader, bulk_buf, bulk.len) || \
        zidl_cdr_skip(&reader, 1) || zidl_cdr_read_##name##_array(&reader, NULL, 0) || \
        zidl_cdr_read_##name##_array(&reader, decoded, 3) || \
        reader.pos != bulk.len || memcmp(values, decoded, sizeof values) != 0) return 31; \
    zidl_cdr_writer_init_fixed(&bulk, bulk_buf, scalar.len - 1, version); \
    if (zidl_cdr_write_encap(&bulk) || zidl_cdr_write_u8(&bulk, 42) || \
        zidl_cdr_write_##name##_array(&bulk, values, 3) != ZIDL_CDR_OVERFLOW || \
        bulk.len != 5 || bulk.pos != 1) return 32; \
} while (0)
            CHECK_ARRAY(u8, uint8_t, 0xab, 0, 0xfe);
            CHECK_ARRAY(i8, int8_t, -2, 3, INT8_MIN);
            CHECK_ARRAY(u16, uint16_t, 0xabcd, 0, UINT16_MAX);
            CHECK_ARRAY(i16, int16_t, -2, 0x1234, INT16_MIN);
            CHECK_ARRAY(u32, uint32_t, 0x12345678, 0, UINT32_MAX);
            CHECK_ARRAY(i32, int32_t, -4, 0x12345678, INT32_MIN);
            CHECK_ARRAY(u64, uint64_t, UINT64_C(0x123456789abcdef0), 0, UINT64_MAX);
            CHECK_ARRAY(i64, int64_t, -8, INT64_C(0x123456789abcdef0), INT64_MIN);
            CHECK_ARRAY(f32, float, 1.25f, -0.0f, -5.5f);
            CHECK_ARRAY(f64, double, 1.25, -0.0, -5.5);
#undef CHECK_ARRAY
        }
    }
    {
        ZidlCdrWriter w;
        ZidlCdrReader r, limited;
        static uint8_t storage[4 + 4 + 2048 * 4];
        uint32_t values[2048], decoded[2048];
        for (size_t i = 0; i < 2048; ++i) values[i] = (uint32_t)(i * 17);
        zidl_cdr_writer_init_fixed(&w, storage, sizeof storage, ZIDL_XCDR1);
        int status = 0;
        if (zidl_cdr_write_encap(&w) ||
            zidl_cdr_write_u32_array(&w, NULL, 1) != ZIDL_CDR_INVALID ||
            zidl_cdr_write_u32_array(&w, values, SIZE_MAX) != ZIDL_CDR_OVERFLOW ||
            zidl_cdr_write_primitives(&w, values, 0, 3) != ZIDL_CDR_INVALID || w.len != 4 ||
            zidl_cdr_write_u32_array(&w, values, 2048) ||
            zidl_cdr_reader_init(&r, w.buf, w.len) ||
            zidl_cdr_read_u32_array(&r, NULL, 1) != ZIDL_CDR_INVALID ||
            zidl_cdr_read_u32_array(&r, decoded, SIZE_MAX) != ZIDL_CDR_TRUNCATED || r.pos != 4 ||
            zidl_cdr_reader_limit(&r, w.len - 1, &limited) ||
            zidl_cdr_read_u32_array(&limited, decoded, 2048) != ZIDL_CDR_TRUNCATED ||
            limited.pos != 4 || zidl_cdr_read_u32_array(&r, decoded, 2048) ||
            memcmp(values, decoded, sizeof values)) status = 34;
        if (status) return status;
    }
    {
        const bool values[] = { true, false, true };
        bool decoded[] = { false, true, false };
        uint8_t bytes[7];
        ZidlCdrWriter w;
        ZidlCdrReader r;
        zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, ZIDL_XCDR1);
        if (zidl_cdr_write_encap(&w) || zidl_cdr_write_bool_array(&w, values, 3) ||
            bytes[4] != 1 || bytes[5] != 0 || bytes[6] != 1) return 35;
        bytes[6] = 2;
        if (zidl_cdr_reader_init(&r, bytes, w.len) ||
            zidl_cdr_read_bool_array(&r, decoded, 3) != ZIDL_CDR_INVALID ||
            r.pos != 4 || decoded[0] || !decoded[1] || decoded[2]) return 36;
        bytes[6] = 1;
        if (zidl_cdr_read_bool_array(&r, decoded, 3) || r.pos != 7 ||
            !decoded[0] || decoded[1] || !decoded[2]) return 37;
    }
    for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
        for (int endian = ZIDL_CDR_LE; endian <= ZIDL_CDR_BE; ++endian) {
            const double values[] = { 1.5, -2.25, 1e300 };
            double decoded[3] = { 0 };
            uint8_t bytes[64];
            ZidlCdrWriter w;
            ZidlCdrReader r, limited;
            uint32_t count = 99;
            zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);
            zidl_cdr_writer_set_byte_order(&w, endian);
            /* After a u8, the length and the elements are padded. */
            if (zidl_cdr_write_encap(&w) || zidl_cdr_write_u8(&w, 7) ||
                zidl_cdr_write_u32(&w, 3) || zidl_cdr_write_f64_array(&w, values, 3) ||
                zidl_cdr_reader_init(&r, bytes, w.len) || zidl_cdr_skip(&r, 1)) return 38;
            const size_t at_length = r.pos;
            /* Over the bound, another width or no count: INVALID, unchanged. */
            if (zidl_cdr_read_sequence_count(&r, 8, 2, &count) != ZIDL_CDR_INVALID ||
                zidl_cdr_read_sequence_count(&r, 3, 0, &count) != ZIDL_CDR_INVALID ||
                zidl_cdr_read_sequence_count(&r, 8, 0, NULL) != ZIDL_CDR_INVALID ||
                r.pos != at_length || count != 99) return 39;
            /* Elements one byte short: TRUNCATED, unchanged. */
            if (zidl_cdr_reader_limit(&r, w.len - 1, &limited) ||
                zidl_cdr_read_sequence_count(&limited, 8, 0, &count) != ZIDL_CDR_TRUNCATED ||
                limited.pos != at_length || count != 99) return 40;
            /* Within the bound, it reads only the length, in the writer's byte
             * order; the elements follow. */
            if (zidl_cdr_read_sequence_count(&r, 8, 3, &count) || count != 3 ||
                r.pos != at_length + 3 + 4 ||
                zidl_cdr_read_primitives(&r, decoded, count, 8) || r.pos != w.len ||
                memcmp(values, decoded, sizeof values) != 0) return 41;
        }
    }
    {
        const uint16_t probe = 1;
        const bool host_le = *(const uint8_t *)&probe == 1;
        for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
            for (int endian = ZIDL_CDR_LE; endian <= ZIDL_CDR_BE; ++endian) {
                const double values[] = { 1.5, -2.25, 1e300 };
                const uint8_t octets[] = { 9, 8, 7, 6, 5 };
                double copied[3] = { 0 };
                uint8_t bytes[96];
                ZidlCdrWriter w;
                ZidlCdrReader r, limited;
                ZidlCdrPrimitivesView v = { bytes, 77, 77, true }, o;
                zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);
                zidl_cdr_writer_set_byte_order(&w, endian);
                if (zidl_cdr_write_encap(&w) || zidl_cdr_write_u8(&w, 7) ||
                    zidl_cdr_write_f64_array(&w, values, 3) ||
                    zidl_cdr_write_u8_array(&w, octets, 5) ||
                    zidl_cdr_reader_init(&r, bytes, w.len) || zidl_cdr_skip(&r, 1)) return 42;
                const size_t at = r.pos;
                /* Another width, no view, or doubles cut short: the reader
                 * and the view are unchanged. */
                if (zidl_cdr_read_primitives_view(&r, 3, 3, &v) != ZIDL_CDR_INVALID ||
                    zidl_cdr_read_primitives_view(&r, 3, 8, NULL) != ZIDL_CDR_INVALID ||
                    zidl_cdr_reader_limit(&r, w.len - 6, &limited) ||
                    zidl_cdr_read_primitives_view(&limited, 3, 8, &v) != ZIDL_CDR_TRUNCATED ||
                    r.pos != at || limited.pos != at || v.data != bytes ||
                    v.count != 77 || v.elem_size != 77 || !v.swapped) return 43;
                /* The doubles, in the stream's byte order. */
                if (zidl_cdr_read_primitives_view(&r, 3, 8, &v) || v.count != 3 ||
                    v.elem_size != 8 || !v.data ||
                    v.swapped != (host_le != (endian == ZIDL_CDR_LE))) return 44;
                /* In place only unswapped and aligned in memory; a type of
                 * another size never. The copy always gives the values.
                 * `bytes` is declared storage, so the pointer is compared with
                 * memcmp, which reads bytes, never dereferenced as doubles. */
                const double *native = ZIDL_CDR_VIEW_AS(&v, double);
                const bool usable = !v.swapped && ((uintptr_t)v.data % _Alignof(double)) == 0;
                if ((native != NULL) != usable ||
                    (native && (const void *)native != (const void *)v.data) ||
                    (native && memcmp(native, values, sizeof values) != 0) ||
                    ZIDL_CDR_VIEW_AS(&v, float) != NULL ||
                    zidl_cdr_view_copy(&v, copied) ||
                    memcmp(copied, values, sizeof values) != 0) return 45;
                /* Octets are never swapped and always usable in place. */
                if (zidl_cdr_read_primitives_view(&r, 5, 1, &o) || o.swapped ||
                    ZIDL_CDR_VIEW_AS(&o, uint8_t) == NULL ||
                    memcmp(o.data, octets, sizeof octets) != 0 || r.pos != w.len) return 46;
                /* An empty view consumes and copies nothing; a view of
                 * another width is refused. */
                if (zidl_cdr_read_primitives_view(&r, 0, 8, &v) || v.data || v.count ||
                    zidl_cdr_view_copy(&v, NULL) || r.pos != w.len) return 47;
                v.count = 1;
                v.elem_size = 3;
                v.data = bytes;
                if (zidl_cdr_view_copy(&v, copied) != ZIDL_CDR_INVALID ||
                    zidl_cdr_view_copy(NULL, copied) != ZIDL_CDR_INVALID) return 48;
            }
        }
    }
    {
        /* ZIDL_CDR_VIEW_AS on views built over a buffer of known alignment:
         * a pointer exactly when the elements are the type's size, unswapped
         * and aligned for it. Pointers are only compared, never read through. */
        _Alignas(8) static const uint8_t storage[32];
        ZidlCdrPrimitivesView v = { storage, 2, 8, false };
        if ((const void *)ZIDL_CDR_VIEW_AS(&v, double) != (const void *)storage ||
            (const void *)ZIDL_CDR_VIEW_AS(&v, uint64_t) != (const void *)storage ||
            ZIDL_CDR_VIEW_AS(&v, float) != NULL) return 49;
        v.swapped = true;
        if (ZIDL_CDR_VIEW_AS(&v, double) != NULL) return 50;
        v.swapped = false;
        v.data = storage + 4;
        if (_Alignof(double) == 8 && ZIDL_CDR_VIEW_AS(&v, double) != NULL) return 51;
        v.elem_size = 2;
        v.data = storage + 1;
        if (ZIDL_CDR_VIEW_AS(&v, uint16_t) != NULL) return 52;
        v.data = storage + 2;
        if ((const void *)ZIDL_CDR_VIEW_AS(&v, uint16_t) != (const void *)(storage + 2)) return 53;
        v.elem_size = 1;
        v.data = storage + 3;
        v.swapped = false;
        if ((const void *)ZIDL_CDR_VIEW_AS(&v, uint8_t) != (const void *)(storage + 3)) return 54;
    }
    {
        const uint16_t probe = 1;
        const bool host_le = *(const uint8_t *)&probe == 1;
        static uint32_t more[1024];
        for (size_t i = 0; i < 1024; ++i) more[i] = (uint32_t)(i * 7);
        for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
            for (int endian = ZIDL_CDR_LE; endian <= ZIDL_CDR_BE; ++endian) {
                const double values[] = { 1.5, -2.25, 1e300 };
                static uint8_t bulk_storage[4608], scalar_storage[4608];
                ZidlCdrWriter bulk, scalar;
                ZidlCdrReservation res, empty;
                uint8_t *data;
                int status = 0;
                zidl_cdr_writer_init_fixed(&bulk, bulk_storage, sizeof bulk_storage, version);
                zidl_cdr_writer_init_fixed(&scalar, scalar_storage, sizeof scalar_storage, version);
                zidl_cdr_writer_set_byte_order(&bulk, endian);
                zidl_cdr_writer_set_byte_order(&scalar, endian);
                if (zidl_cdr_write_encap(&bulk) || zidl_cdr_write_encap(&scalar) ||
                    zidl_cdr_write_u8(&bulk, 7) || zidl_cdr_write_u8(&scalar, 7)) status = 56;
                /* Another width or no reservation: INVALID. An empty one
                 * reserves nothing, has no data and commits. */
                else if (zidl_cdr_reserve_primitives(&bulk, 1, 3, &res) != ZIDL_CDR_INVALID ||
                         zidl_cdr_reserve_primitives(&bulk, 1, 8, NULL) != ZIDL_CDR_INVALID ||
                         zidl_cdr_reserve_primitives(&bulk, 0, 8, &empty) || empty.count ||
                         zidl_cdr_reservation_data(&bulk, &empty) != NULL ||
                         zidl_cdr_commit_primitives(&bulk, &empty) || !empty.committed ||
                         bulk.len != scalar.len) status = 57;
                /* Reserved, then more is written; the elements are found by
                 * offset, filled late with host values and committed into the
                 * writer's byte order. */
                else if (zidl_cdr_reserve_primitives(&bulk, 3, 8, &res) || res.count != 3 ||
                         res.elem_size != 8 || res.committed ||
                         res.swap != (host_le != (endian == ZIDL_CDR_LE)) ||
                         zidl_cdr_write_f64_array(&scalar, values, 3) ||
                         zidl_cdr_write_u32_array(&bulk, more, 1024) ||
                         zidl_cdr_write_u32_array(&scalar, more, 1024) ||
                         (data = (uint8_t *)zidl_cdr_reservation_data(&bulk, &res)) == NULL) status = 58;
                else {
                    memcpy(data, values, sizeof values);
                    /* Once: a repeated commit cannot swap the bytes back. */
                    if (zidl_cdr_commit_primitives(&bulk, &res) || !res.committed ||
                        zidl_cdr_commit_primitives(&bulk, &res) ||
                        bulk.len != scalar.len || memcmp(bulk.buf, scalar.buf, bulk.len) != 0) status = 59;
                }
                /* A reservation past what the writer has written is refused. */
                if (!status) {
                    ZidlCdrReservation forged = { bulk.len - 4, 1, 8, true, false };
                    if (zidl_cdr_reservation_data(&bulk, &forged) != NULL ||
                        zidl_cdr_commit_primitives(&bulk, &forged) != ZIDL_CDR_INVALID ||
                        forged.committed || zidl_cdr_commit_primitives(NULL, &res) != ZIDL_CDR_INVALID ||
                        zidl_cdr_commit_primitives(&bulk, NULL) != ZIDL_CDR_INVALID) status = 60;
                }
                if (status) return status;
            }
        }
        {
            /* A fixed writer without room: OVERFLOW, writer and reservation
             * unchanged. A counting writer counts the elements, with no data. */
            uint8_t bytes[16];
            ZidlCdrWriter w, counting;
            ZidlCdrReservation res = { 77, 77, 77, true, true };
            zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, ZIDL_XCDR1);
            zidl_cdr_writer_init_counting(&counting, ZIDL_XCDR1);
            if (zidl_cdr_write_encap(&w) || zidl_cdr_write_u8(&w, 7) ||
                zidl_cdr_reserve_primitives(&w, 2, 8, &res) != ZIDL_CDR_OVERFLOW ||
                w.len != 5 || w.pos != 1 || res.offset != 77 || res.count != 77 ||
                res.elem_size != 77 || !res.swap || !res.committed) return 61;
            if (zidl_cdr_write_encap(&counting) || zidl_cdr_write_u8(&counting, 7) ||
                zidl_cdr_reserve_primitives(&counting, 2, 8, &res) || res.count != 2 ||
                zidl_cdr_reservation_data(&counting, &res) != NULL ||
                zidl_cdr_commit_primitives(&counting, &res) || !res.committed ||
                counting.len != 4 + 8 + 16) return 62;
        }
    }
    return 0;
}

#ifdef ZIDL_CDR_SHARED_CONSUMER
/* Link this with a normal C compiler against the staged archive. */
int main(void) {
    const int bulk_status = bulk_primitive_arrays();
    if (bulk_status) return bulk_status;
    extern int fixed_external_contract(void);
    { int rc = fixed_external_contract(); if (rc) return 100 + rc; }

    {
        static const uint8_t wide[] = { 0, 7, 0, 0, 2, 0, 0, 0, 'A', 0 };
        ZidlCdrReader r;
        if (zidl_cdr_reader_init(&r, wide, sizeof wide)) return 30;
        if (zidl_cdr_skip_wstring(&r) || r.pos != sizeof wide) return 31;
    }
    static const uint8_t expected[12] = {
        0xab, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8
    };
    uint8_t buffer[12];
    int mode;
    for (mode = 1; mode < 3; mode++) {
        ZidlCdrWriter w;
        int rc;
        if (mode == 1) {
            zidl_cdr_writer_init_fixed(&w, buffer, sizeof buffer, ZIDL_XCDR2);
        } else {
            zidl_cdr_writer_init_counting(&w, ZIDL_XCDR2);
        }
        zidl_cdr_writer_set_byte_order(&w, ZIDL_CDR_BE);
        rc = zidl_cdr_write_u8(&w, 0xab);
        if (!rc) rc = zidl_cdr_write_u64(&w, UINT64_C(0x0102030405060708));
        if (rc || w.len != sizeof expected || w.pos != sizeof expected) return 2;
        if (mode != 2 && memcmp(w.buf, expected, sizeof expected)) return 3;
        if (mode == 2 && w.buf != NULL) return 4;
    }
    {
        static const uint8_t stream[] = {
            0, 6, 0, 0, 0xab, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8
        };
        ZidlCdrReader r;
        uint8_t a;
        uint64_t b;
        if (zidl_cdr_reader_init(&r, stream, sizeof stream)) return 5;
        if (zidl_cdr_read_u8(&r, &a) || a != 0xab) return 6;
        if (zidl_cdr_read_u64(&r, &b) || b != UINT64_C(0x0102030405060708)) return 7;
        if (r.pos != sizeof stream) return 8;
    }
    {
        uint8_t strings[42] = { 0, 7, 0, 0 };
        ZidlCdrWriter w;
        ZidlCdrReader r;
        zidl_cdr_writer_init_fixed(&w, strings + 4, sizeof strings - 4, ZIDL_XCDR2);
        if (shared_strings_sample(&w)) return 9;
        if (zidl_cdr_reader_init(&r, strings, 4 + w.len)) return 10;
        if (shared_strings_read_sample(&r)) return 11;
        if (r.pos != 4 + w.len) return 12;
    }
    {
        uint8_t frame[28];
        ZidlCdrWriter w;
        ZidlCdrReader r;
        zidl_cdr_writer_init_fixed(&w, frame, sizeof frame, ZIDL_XCDR2);
        zidl_cdr_writer_set_byte_order(&w, ZIDL_CDR_BE);
        if (shared_framing_sample(&w)) return 13;
        if (zidl_cdr_reader_init(&r, frame, w.len)) return 14;
        if (shared_framing_read_sample(&r) || r.pos != w.len) return 15;
    }
    {
        uint8_t parameters[16];
        ZidlCdrWriter w;
        ZidlCdrReader r;
        ZidlPlParam parameter;
        zidl_cdr_writer_init_fixed(&w, parameters, sizeof parameters, ZIDL_PL_CDR);
        if (shared_pl_sample(&w)) return 16;
        if (zidl_cdr_reader_init(&r, parameters, w.len)) return 17;
        if (zidl_cdr_pl_read_param(&r, &parameter)) return 18;
        if (parameter.pid != 0x10 || parameter.byte_len != 4 || parameter.end_pos != 12) return 19;
    }
    {
        uint8_t bytes[8], hash[16];
        const uint16_t wide[] = { 0x41, 0x1234 };
        ZidlCdrWriter w;
        zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, ZIDL_XCDR2);
        zidl_cdr_writer_set_byte_order(&w, ZIDL_CDR_BE);
        if (zidl_cdr_write_key_wstring(&w, wide, 2) || w.len != 8) return 20;
        if (bytes[3] != 4 || bytes[4] != 0 || bytes[5] != 0x41 || bytes[6] != 0x12 || bytes[7] != 0x34) return 21;
        zidl_cdr_compute_key_hash_for_type(bytes, sizeof bytes, false, hash);
        if (memcmp(bytes, hash, sizeof bytes)) return 22;
        zidl_cdr_compute_key_hash_for_type(bytes, sizeof bytes, true, hash);
        zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, ZIDL_XCDR2);
        if (zidl_cdr_write_key_wstring_length(&w, 0) || w.len != 4) return 23;
    }
    return 0;
}
#endif
