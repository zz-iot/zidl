/* Shared compiled C/C++ tests: every rejected sequence must fail before its
 * container allocates. A stack writer keeps test construction allocation-free. */
#ifdef __cplusplus
#define SEQ_TYPE(name) Validation::name
#define SEQ_ALLOCATIONS cpp_allocation_calls
#define SEQ_TRACK(value) (count_cpp_allocations = (value))
#else
#define SEQ_TYPE(name) Validation_##name
#define SEQ_ALLOCATIONS allocation_calls
#define SEQ_TRACK(value) ((void)(value))
#endif

#define CHECK_SEQUENCE(name, expected) do { \
    SEQ_TYPE(name) out = INIT; \
    ZidlCdrReader reader; \
    assert(zidl_cdr_reader_init(&reader, bytes, w.len) == 0); \
    size_t before = SEQ_ALLOCATIONS; \
    SEQ_TRACK(true); \
    int result = Validation_##name##_deserialize(&reader, &out); \
    SEQ_TRACK(false); \
    assert(result == (expected)); \
    if (result) assert(SEQ_ALLOCATIONS == before); \
    else { \
        uint8_t encoded[256]; \
        ZidlCdrWriter roundtrip; \
        zidl_cdr_writer_init_fixed(&roundtrip, encoded, sizeof encoded, version); \
        zidl_cdr_writer_set_byte_order(&roundtrip, order); \
        assert(zidl_cdr_write_encap(&roundtrip) == 0); \
        assert(Validation_##name##_serialize(&roundtrip, &out) == 0); \
        assert(roundtrip.len == w.len && !memcmp(encoded, bytes, w.len)); \
    } \
    FREE(name, out); \
    assert(live_count == 0); \
    assert(zidl_cdr_reader_init(&reader, bytes, w.len) == 0); \
    assert(Validation_##name##_skip(&reader) == (expected)); \
} while (0)

static size_t sequence_start(ZidlCdrWriter *w, bool delimited, uint32_t count) {
    size_t header = (size_t)-1;
    if (delimited) assert(zidl_cdr_reserve_dheader_maybe(w, &header) == 0);
    assert(zidl_cdr_write_u32(w, count) == 0);
    return header;
}
static void sequence_end(ZidlCdrWriter *w, size_t header) {
    if (header != (size_t)-1) assert(zidl_cdr_patch_dheader_checked(w, header) == 0);
}
#define START_WIRE() do { \
    zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version); \
    zidl_cdr_writer_set_byte_order(&w, order); \
    assert(zidl_cdr_write_encap(&w) == 0); \
} while (0)

static void sequence_validation(void) {
    const ZidlAllocator allocator = { NULL, tracked_alloc, tracked_resize, tracked_free };
    zidl_cdr_set_allocator(&allocator);
    for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; version++) {
        for (int order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; order++) {
            uint8_t bytes[256];
            ZidlCdrWriter w;
            /* Typedef of a bounded sequence of aliased primitives: zero, maximum,
             * over-bound with a complete payload, and a hostile count. */
            const uint32_t counts[] = { 0, 2, 3, UINT32_MAX };
            for (size_t i = 0; i < sizeof counts / sizeof *counts; i++) {
                START_WIRE();
                sequence_start(&w, false, counts[i]);
                if (counts[i] < 4) for (uint32_t j = 0; j < counts[i]; j++)
                    assert(zidl_cdr_write_i32(&w, (int32_t)j) == 0);
                CHECK_SEQUENCE(SeqBounded, i < 2 ? ZIDL_CDR_OK : ZIDL_CDR_INVALID);
            }
            /* Unbounded fixed-width values: account for 8-byte XCDR1 alignment,
             * and reject impossible extents before resizing/allocating. */
            START_WIRE();
            sequence_start(&w, false, UINT32_MAX);
            CHECK_SEQUENCE(SeqUnbounded, ZIDL_CDR_TRUNCATED);
            START_WIRE();
            sequence_start(&w, false, 2);
            assert(zidl_cdr_write_i64(&w, 7) == 0);
            CHECK_SEQUENCE(SeqUnbounded, ZIDL_CDR_TRUNCATED);
            assert(zidl_cdr_write_i64(&w, 8) == 0);
            CHECK_SEQUENCE(SeqUnbounded, ZIDL_CDR_OK);

            /* Walk variable-size elements, including a truncated second string. */
            START_WIRE();
            size_t header = sequence_start(&w, true, 2);
            assert(zidl_cdr_write_string(&w, "first", 5) == 0);
            assert(zidl_cdr_write_u32(&w, 10) == 0);
            sequence_end(&w, header);
            CHECK_SEQUENCE(SeqStrings, ZIDL_CDR_TRUNCATED);
            START_WIRE();
            header = sequence_start(&w, true, 2);
            assert(zidl_cdr_write_string(&w, "first", 5) == 0);
            assert(zidl_cdr_write_string(&w, "second", 6) == 0);
            sequence_end(&w, header);
            CHECK_SEQUENCE(SeqStrings, ZIDL_CDR_OK);
            if (version == ZIDL_XCDR2) {
                /* The second string is physically present but outside the
                 * collection's declared extent. Do not allocate from it. */
                memset(bytes + header, 0, 4);
                bytes[header + (order == ZIDL_CDR_LE ? 0 : 3)] = 14;
                CHECK_SEQUENCE(SeqStrings, ZIDL_CDR_TRUNCATED);
            }
            START_WIRE();
            header = sequence_start(&w, true, 3);
            sequence_end(&w, header);
            CHECK_SEQUENCE(SeqStrings, ZIDL_CDR_INVALID);

            /* A nested sequence and a struct containing that same sequence have
             * identical wire bytes. Check both inline and named skip dispatch. */
            for (uint32_t inner = 2; inner <= 3; inner++) {
                START_WIRE();
                header = sequence_start(&w, true, 1);
                sequence_start(&w, false, inner);
                for (uint32_t j = 0; j < inner; j++)
                    assert(zidl_cdr_write_i32(&w, (int32_t)j) == 0);
                sequence_end(&w, header);
                CHECK_SEQUENCE(SeqNested, inner == 2 ? ZIDL_CDR_OK : ZIDL_CDR_INVALID);
                CHECK_SEQUENCE(SeqStructs, inner == 2 ? ZIDL_CDR_OK : ZIDL_CDR_INVALID);
            }

            /* Sequence preflight must follow nested key projection rather than
             * requiring the element's omitted non-key fields. */
            for (int key_only = 0; key_only < 2; ++key_only) {
                START_WIRE();
                size_t header = sequence_start(&w, true, 2);
                for (int i = 0; i < 2; ++i) {
                    assert(zidl_cdr_write_i32(&w, 10 + i) == 0);
                    if (!key_only) assert(zidl_cdr_write_i32(&w, 99) == 0);
                }
                sequence_end(&w, header);
                SEQ_TYPE(KeySequence) value = INIT;
                ZidlCdrReader projected;
                assert(zidl_cdr_reader_init(&projected, bytes, w.len) == 0);
                assert((key_only ? Validation_KeySequence_deserialize_key_value(&projected, &value)
                                 : Validation_KeySequence_deserialize(&projected, &value)) == 0);
                assert(projected.pos == w.len);
                uint8_t expected[16], actual[16];
                assert(Validation_KeySequence_compute_key_hash(&value, expected) == 0);
                assert((key_only ? Validation_KeySequence_compute_key_hash_from_cdr_key_only(bytes, w.len, actual)
                                 : Validation_KeySequence_compute_key_hash_from_cdr(bytes, w.len, actual)) == 0);
                assert(!memcmp(expected, actual, 16));
                FREE(KeySequence, value);
                assert(live_count == 0);
            }

            /* A failed probe after an already decoded owning field remains
             * safe to free; key-hash traversal must clean its temporary too. */
            START_WIRE();
            assert(zidl_cdr_write_string(&w, "owned", 5) == 0);
            sequence_start(&w, false, 3);
            SEQ_TYPE(SeqCleanup) cleanup = INIT;
            ZidlCdrReader reader;
            assert(zidl_cdr_reader_init(&reader, bytes, w.len) == 0);
            assert(Validation_SeqCleanup_deserialize(&reader, &cleanup) == ZIDL_CDR_INVALID);
            FREE(SeqCleanup, cleanup);
            uint8_t hash[16];
            assert(Validation_SeqCleanup_compute_key_hash_from_cdr_key_only(bytes, w.len, hash) == ZIDL_CDR_INVALID);
            assert(live_count == 0);
        }
    }
    zidl_cdr_set_allocator(NULL);
}
