/* Generated builder types (--generate-views) write the same bytes as the
 * struct: a builder is counted, then serialized into a fixed buffer, its
 * reservations filled in place in host order and committed, and the result
 * matches _serialize of the equivalent struct in both byte orders and XCDR
 * versions. Absent optionals reserve nothing, counts are checked against
 * their bounds, and a builder's key hash matches the struct's. */
#include <stdio.h>
#include <string.h>
#include "views.h"
#include "builders.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: CHECK(%s) failed (version %d, order %d)\n", __FILE__, __LINE__, #c, version, order); return 1; } } while (0)

static uint8_t expected[4096], built[4096];
static size_t expected_len;

static void begin(ZidlCdrWriter *w, uint8_t *buf, int version, int order) {
    zidl_cdr_writer_init_fixed(w, buf, 4096, version);
    zidl_cdr_writer_set_byte_order(w, order);
    (void)zidl_cdr_write_encap(w);
}

static void begin_counting(ZidlCdrWriter *w, int version, int order) {
    zidl_cdr_writer_init_counting(w, version);
    zidl_cdr_writer_set_byte_order(w, order);
    (void)zidl_cdr_write_encap(w);
}

/* Fills a reservation with host values, as an application would. */
static int fill(ZidlCdrWriter *w, const ZidlCdrReservation *res, const void *values) {
    void *dest = zidl_cdr_reservation_data(w, res);
    if (res->count == 0) return dest == NULL ? 0 : 1;
    if (dest == NULL) return 1;
    memcpy(dest, values, res->count * res->elem_size);
    return 0;
}

/* Counts, then serializes a builder: the two passes agree. */
#define BUILD(type, b, w) do { \
        ZidlCdrWriter _cw; \
        begin_counting(&_cw, version, order); \
        CHECK(type##_serialize_builder(&_cw, (b)) == 0); \
        begin((w), built, version, order); \
        CHECK(type##_serialize_builder((w), (b)) == 0); \
        CHECK((w)->len == _cw.len); \
    } while (0)

#define EXPECT(type, v) do { \
        ZidlCdrWriter _ew; \
        begin(&_ew, expected, version, order); \
        CHECK(type##_serialize(&_ew, (v)) == 0); \
        expected_len = _ew.len; \
    } while (0)

static int final_frame(int version, int order) {
    char name[] = "frame", note[] = "a note", inner_label[] = "inner";
    char label_a[] = "a", label_b[] = "bc";
    uint8_t data[5] = { 1, 2, 3, 4, 5 };
    double samples[3] = { 1.5, -2.25, 1e300 };
    bool flags[2] = { true, false };
    char *labels[2] = { label_a, label_b };
    float weights[2] = { 0.5f, 4.0f };
    int32_t extra[3] = { 7, -8, 9 }, grid[6];
    views_FinalFrame v;
    views_FinalFrame_default(&v);
    v.first = 9;
    v.name = name;
    strcpy(v.tag, "tag8");
    v.data = (uint8_t_seq){ 5, 5, data, false };
    v.samples = (double_seq){ 3, 3, samples, false };
    for (int i = 0; i < 6; ++i) {
        grid[i] = i * 11 - 20;
        v.grid[i / 3][i % 3] = grid[i];
    }
    v.flags = (bool_seq){ 2, 2, flags, false };
    v.labels = (string_seq){ 2, 2, labels, false };
    v.nested.id = 42;
    v.nested.label = inner_label;
    v.nested.weights = (float_seq){ 2, 2, weights, false };
    v._present = 3;
    v.note = note;
    v.extra = (int32_t_seq){ 3, 3, extra, false };

    views_FinalFrameBuilder b;
    memset(&b, 0, sizeof b);
    b.first = 9;
    b.name = "frame";
    b.tag = "tag8";
    b.data.count = 5;
    b.samples.count = 3;
    b.flags = v.flags;
    b.labels = v.labels;
    b.nested.id = 42;
    b.nested.label = "inner";
    b.nested.weights.count = 2;
    b._present = 3;
    b.note = "a note";
    b.extra.count = 3;

    ZidlCdrWriter w;
    EXPECT(views_FinalFrame, &v);
    BUILD(views_FinalFrame, &b, &w);
    CHECK(b.grid.count == 6 && b.grid.elem_size == 4);
    CHECK(fill(&w, &b.data, data) == 0 && fill(&w, &b.samples, samples) == 0 && fill(&w, &b.grid, grid) == 0);
    CHECK(fill(&w, &b.nested.weights, weights) == 0 && fill(&w, &b.extra, extra) == 0);
    CHECK(views_FinalFrame_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);
    /* Committing again cannot swap the elements back. */
    CHECK(views_FinalFrame_commit_builder(&w, &b) == 0);
    CHECK(memcmp(built, expected, expected_len) == 0);

    /* Absent optionals: nothing reserved, so nothing to fill. */
    v._present = 0;
    b._present = 0;
    b.note = NULL;
    EXPECT(views_FinalFrame, &v);
    BUILD(views_FinalFrame, &b, &w);
    CHECK(b.extra.count == 0 && zidl_cdr_reservation_data(&w, &b.extra) == NULL);
    CHECK(fill(&w, &b.data, data) == 0 && fill(&w, &b.samples, samples) == 0 && fill(&w, &b.grid, grid) == 0);
    CHECK(fill(&w, &b.nested.weights, weights) == 0);
    CHECK(views_FinalFrame_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);

    /* A bounded string over its bound fails while counting. */
    {
        ZidlCdrWriter cw;
        b.tag = "too long!";
        begin_counting(&cw, version, order);
        CHECK(views_FinalFrame_serialize_builder(&cw, &b) == ZIDL_CDR_INVALID);
    }
    return 0;
}

static int append_frame(int version, int order) {
    uint8_t data[3] = { 9, 8, 7 };
    uint16_t codes[2] = { 0x1234, 0xabcd };
    int64_t stamps[2] = { -1, 0x0102030405060708LL };
    char name[] = "appended";
    views_AppendFrame v;
    views_AppendFrame_default(&v);
    v.name = name;
    v.data = (uint8_t_seq){ 3, 3, data, false };
    v.nested.code = -5;
    v.nested.codes = (uint16_t_seq){ 2, 2, codes, false };
    v._present = 1;
    v.stamps = (int64_t_seq){ 2, 2, stamps, false };

    views_AppendFrameBuilder b;
    memset(&b, 0, sizeof b);
    b.name = "appended";
    b.data.count = 3;
    b.nested.code = -5;
    b.nested.codes.count = 2;
    b._present = 1;
    b.stamps.count = 2;

    ZidlCdrWriter w;
    EXPECT(views_AppendFrame, &v);
    BUILD(views_AppendFrame, &b, &w);
    CHECK(fill(&w, &b.data, data) == 0 && fill(&w, &b.nested.codes, codes) == 0 && fill(&w, &b.stamps, stamps) == 0);
    CHECK(views_AppendFrame_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);
    return 0;
}

static int mutable_frame(int version, int order) {
    uint8_t data[4] = { 4, 3, 2, 1 };
    float weights[1] = { 2.5f };
    char name[] = "mutable", inner_label[] = "deep";
    views_MutableFrame v;
    views_MutableFrame_default(&v);
    v.name = name;
    v.data = (uint8_t_seq){ 4, 4, data, false };
    v.nested.id = 7;
    v.nested.label = inner_label;
    v.nested.weights = (float_seq){ 1, 1, weights, false };
    v._present = 1;
    v.count = 31;

    views_MutableFrameBuilder b;
    memset(&b, 0, sizeof b);
    b.name = "mutable";
    b.data.count = 4;
    b.nested.id = 7;
    b.nested.label = "deep";
    b.nested.weights.count = 1;
    b._present = 1;
    b.count = 31;

    ZidlCdrWriter w;
    EXPECT(views_MutableFrame, &v);
    BUILD(views_MutableFrame, &b, &w);
    CHECK(fill(&w, &b.data, data) == 0 && fill(&w, &b.nested.weights, weights) == 0);
    CHECK(views_MutableFrame_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);
    return 0;
}

static int derived(int version, int order) {
    int64_t stamps[2] = { 11, -22 };
    uint16_t pixels[3] = { 1, 2, 65535 };
    char id[] = "base-id";
    views_Derived v;
    views_Derived_default(&v);
    v._base.id = id;
    v._base.stamps = (int64_t_seq){ 2, 2, stamps, false };
    v.pixels = (uint16_t_seq){ 3, 3, pixels, false };

    views_DerivedBuilder b;
    memset(&b, 0, sizeof b);
    b._base.id = "base-id";
    b._base.stamps.count = 2;
    b.pixels.count = 3;

    ZidlCdrWriter w;
    EXPECT(views_Derived, &v);
    BUILD(views_Derived, &b, &w);
    CHECK(fill(&w, &b._base.stamps, stamps) == 0 && fill(&w, &b.pixels, pixels) == 0);
    CHECK(views_Derived_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);
    return 0;
}

/* Key members are as declared, so a builder's key hash is the struct's. */
static int keyed(int version, int order) {
    int32_t ids[2] = { 5, -6 };
    float values[3] = { 1.0f, 2.0f, 3.0f };
    char name[] = "keyed", label[] = "label";
    uint8_t hash_v[16], hash_b[16];
    builders_Keyed v;
    builders_Keyed_default(&v);
    v.id = 77;
    v.name = name;
    v.ids = (int32_t_seq){ 2, 2, ids, false };
    v.origin.x = 3;
    v.origin.y = -4;
    v.values = (float_seq){ 3, 3, values, false };
    v.label = label;

    builders_KeyedBuilder b;
    memset(&b, 0, sizeof b);
    b.id = 77;
    b.name = name;
    b.ids = v.ids;
    b.origin = v.origin;
    b.values.count = 3;
    b.label = "label";

    ZidlCdrWriter w;
    EXPECT(builders_Keyed, &v);
    BUILD(builders_Keyed, &b, &w);
    CHECK(fill(&w, &b.values, values) == 0);
    CHECK(builders_Keyed_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);

    ZidlCdrKeyHash h;
    zidl_cdr_key_hash_init(&h);
    CHECK(builders_KeyedBuilder_serialize_key_holder(&h.writer, &b) == 0);
    zidl_cdr_key_hash_finish(&h, builders_Keyed_KEY_HASH_FORCE_MD5, hash_b);
    CHECK(builders_Keyed_compute_key_hash(&v, hash_v) == 0);
    CHECK(memcmp(hash_v, hash_b, 16) == 0);
    return 0;
}

static int key_derived(int version, int order) {
    uint8_t header[2] = { 0xaa, 0xbb }, blob[5] = { 1, 2, 3, 4, 5 };
    uint8_t hash_v[16], hash_b[16];
    builders_KeyDerived v;
    builders_KeyDerived_default(&v);
    v._base.site = 12;
    v._base.header = (uint8_t_seq){ 2, 2, header, false };
    strcpy(v.tag, "tag");
    v.blob = (uint8_t_seq){ 5, 5, blob, false };

    builders_KeyDerivedBuilder b;
    memset(&b, 0, sizeof b);
    b._base.site = 12;
    b._base.header.count = 2;
    strcpy(b.tag, "tag");
    b.blob.count = 5;

    ZidlCdrWriter w;
    EXPECT(builders_KeyDerived, &v);
    BUILD(builders_KeyDerived, &b, &w);
    CHECK(fill(&w, &b._base.header, header) == 0 && fill(&w, &b.blob, blob) == 0);
    CHECK(builders_KeyDerived_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);

    ZidlCdrKeyHash h;
    zidl_cdr_key_hash_init(&h);
    CHECK(builders_KeyDerivedBuilder_serialize_key_holder(&h.writer, &b) == 0);
    zidl_cdr_key_hash_finish(&h, builders_KeyDerived_KEY_HASH_FORCE_MD5, hash_b);
    CHECK(builders_KeyDerived_compute_key_hash(&v, hash_v) == 0);
    CHECK(memcmp(hash_v, hash_b, 16) == 0);
    return 0;
}

static int mutable_keyed(int version, int order) {
    double samples[2] = { 0.25, -8.0 };
    int16_t extra[3] = { -1, 2, -3 };
    builders_MutableKeyed v;
    builders_MutableKeyed_default(&v);
    v.serial = 0x0102030405060708ULL;
    v.samples = (double_seq){ 2, 2, samples, false };
    v._present = 1;
    v.extra = (int16_t_seq){ 3, 3, extra, false };

    builders_MutableKeyedBuilder b;
    memset(&b, 0, sizeof b);
    b.serial = v.serial;
    b.samples.count = 2;
    b._present = 1;
    b.extra.count = 3;

    ZidlCdrWriter w;
    EXPECT(builders_MutableKeyed, &v);
    BUILD(builders_MutableKeyed, &b, &w);
    CHECK(fill(&w, &b.samples, samples) == 0 && fill(&w, &b.extra, extra) == 0);
    CHECK(builders_MutableKeyed_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);

    /* Absent: the reservation is zeroed, whatever count it was given. */
    v._present = 0;
    b._present = 0;
    b.extra.count = 3;
    EXPECT(builders_MutableKeyed, &v);
    BUILD(builders_MutableKeyed, &b, &w);
    CHECK(b.extra.count == 0);
    CHECK(fill(&w, &b.samples, samples) == 0);
    CHECK(builders_MutableKeyed_commit_builder(&w, &b) == 0);
    CHECK(w.len == expected_len && memcmp(built, expected, expected_len) == 0);
    return 0;
}

static int bounded(int version, int order) {
    builders_BoundedBuilder b;
    ZidlCdrWriter cw;
    memset(&b, 0, sizeof b);
    b.few.count = 5;
    begin_counting(&cw, version, order);
    CHECK(builders_Bounded_serialize_builder(&cw, &b) == ZIDL_CDR_INVALID);
    b.few.count = 4;
    begin_counting(&cw, version, order);
    CHECK(builders_Bounded_serialize_builder(&cw, &b) == 0);
    return 0;
}

int main(void) {
    for (int order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order) {
        for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
            if (final_frame(version, order) || append_frame(version, order) || derived(version, order) ||
                keyed(version, order) || key_derived(version, order) || bounded(version, order)) return 1;
        }
        /* XCDR1 has no ordinary mutable encoding. */
        if (mutable_frame(ZIDL_XCDR2, order) || mutable_keyed(ZIDL_XCDR2, order)) return 1;
    }
    puts("builders: all checks passed");
    return 0;
}
