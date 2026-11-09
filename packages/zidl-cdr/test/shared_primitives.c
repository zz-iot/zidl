/* Independent C compiler view of the public ABI and a real foreign caller. */
#include "zidl_cdr.h"
#include <stddef.h>

void shared_primitives_layout(size_t out[17]) {
    out[0] = sizeof(ZidlCdrWriter);
    out[1] = _Alignof(ZidlCdrWriter);
    out[2] = offsetof(ZidlCdrWriter, buf);
    out[3] = offsetof(ZidlCdrWriter, cap);
    out[4] = offsetof(ZidlCdrWriter, len);
    out[5] = offsetof(ZidlCdrWriter, pos);
    out[6] = offsetof(ZidlCdrWriter, xcdr_version);
    out[7] = offsetof(ZidlCdrWriter, byte_order);
    out[8] = offsetof(ZidlCdrWriter, grow_fn);
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

#ifdef ZIDL_CDR_SHARED_CONSUMER
#include <string.h>

/* Link this with a normal C compiler against the staged archive. */
int main(void) {
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
    for (mode = 0; mode < 3; mode++) {
        ZidlCdrWriter w;
        int rc;
        if (mode == 0) {
            if (zidl_cdr_writer_init(&w, ZIDL_XCDR2)) return 1;
        } else if (mode == 1) {
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
        zidl_cdr_writer_deinit(&w);
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
