// Generated C++ builder types (--generate-views) write the same bytes as the
// struct: a builder is counted, then serialized into a fixed buffer, its
// reservations filled in place in host order and committed, and the result
// matches _serialize of the equivalent struct in both byte orders and XCDR
// versions. Absent optionals reserve nothing, counts and strings are checked
// against their bounds, and a builder's key hash matches the struct's.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "views.hpp"
#include "builders.hpp"

static int version, order;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "%s:%d: CHECK(%s) failed (version %d, order %d)\n", __FILE__, __LINE__, #c, version, order); std::exit(1); } } while (0)

// Allocated storage, as a write loan is: elements are written in place.
static uint8_t *built = static_cast<uint8_t *>(std::malloc(4096));
static uint8_t expected[4096];

static void begin(ZidlCdrWriter *w, uint8_t *buf) {
    zidl_cdr_writer_init_fixed(w, buf, 4096, version);
    zidl_cdr_writer_set_byte_order(w, order);
    (void)zidl_cdr_write_encap(w);
}

// Counts, then serializes a builder into `built`: the two passes agree.
template <class B, class F>
static void build(ZidlCdrWriter *w, B &b, F serialize) {
    ZidlCdrWriter cw;
    zidl_cdr_writer_init_counting(&cw, version);
    zidl_cdr_writer_set_byte_order(&cw, order);
    (void)zidl_cdr_write_encap(&cw);
    CHECK(serialize(&cw, &b) == 0);
    begin(w, built);
    CHECK(serialize(w, &b) == 0);
    CHECK(w->len == cw.len);
}

template <class V, class F>
static size_t expect(const V &v, F serialize) {
    ZidlCdrWriter w;
    begin(&w, expected);
    CHECK(serialize(&w, &v) == 0);
    return w.len;
}

// Fills a reservation as an application would: in place when it can.
template <class T>
static void fill(::zidl::PrimitivesReservation<T> &res, const T *values) {
    if (T *p = res.as_native()) {
        for (size_t i = 0; i < res.size(); ++i) p[i] = values[i];
    } else {
        res.copy_from(values);
    }
}

static void final_frame() {
    const uint8_t data[5] = { 1, 2, 3, 4, 5 };
    const double samples[3] = { 1.5, -2.25, 1e300 };
    const float weights[2] = { 0.5f, 4.0f };
    const int32_t extra[3] = { 7, -8, 9 };
    int32_t grid[6];
    views::FinalFrame v;
    v.first = 9;
    v.name = "frame";
    v.tag = "tag8";
    v.data.assign(data, data + 5);
    v.samples.assign(samples, samples + 3);
    for (int i = 0; i < 6; ++i) {
        grid[i] = i * 11 - 20;
        v.grid[i / 3][i % 3] = grid[i];
    }
    v.flags = { true, false };
    v.labels = { "a", "bc" };
    v.nested.id = 42;
    v.nested.label = "inner";
    v.nested.weights.assign(weights, weights + 2);
    v.note = "a note";
    v.extra.emplace(extra, extra + 3);

    views::FinalFrameBuilder b;
    b.first = 9;
    b.name = "frame";
    b.tag = "tag8";
    b.data.resize(5);
    b.samples.resize(3);
    b.flags = v.flags;
    b.labels = v.labels;
    b.nested.id = 42;
    b.nested.label = "inner";
    b.nested.weights.resize(2);
    b.note = "a note";
    b.extra.emplace(3);

    ZidlCdrWriter w;
    const size_t len = expect(v, views_FinalFrame_serialize);
    build(&w, b, views_FinalFrame_serialize_builder);
    CHECK(b.grid.size() == 6 && b.data.data() != nullptr);
    fill(b.data, data);
    fill(b.samples, samples);
    fill(b.grid, grid);
    fill(b.nested.weights, weights);
    fill(*b.extra, extra);
    CHECK(views_FinalFrame_commit_builder(&w, &b) == 0);
    CHECK(w.len == len && std::memcmp(built, expected, len) == 0);

    // Absent optionals reserve nothing.
    v.note.reset();
    v.extra.reset();
    b.note.reset();
    b.extra.reset();
    const size_t absent = expect(v, views_FinalFrame_serialize);
    build(&w, b, views_FinalFrame_serialize_builder);
    fill(b.data, data);
    fill(b.samples, samples);
    fill(b.grid, grid);
    fill(b.nested.weights, weights);
    CHECK(views_FinalFrame_commit_builder(&w, &b) == 0);
    CHECK(w.len == absent && std::memcmp(built, expected, absent) == 0);

    // A bounded string over its bound fails while counting.
    ZidlCdrWriter cw;
    zidl_cdr_writer_init_counting(&cw, version);
    b.tag = "too long!";
    CHECK(views_FinalFrame_serialize_builder(&cw, &b) == ZIDL_CDR_INVALID);
}

static void mutable_frame() {
    const uint8_t data[4] = { 4, 3, 2, 1 };
    const float weights[1] = { 2.5f };
    views::MutableFrame v;
    v.name = "mutable";
    v.data.assign(data, data + 4);
    v.nested.id = 7;
    v.nested.label = "deep";
    v.nested.weights.assign(weights, weights + 1);
    v.count = 31;

    views::MutableFrameBuilder b;
    b.name = "mutable";
    b.data.resize(4);
    b.nested.id = 7;
    b.nested.label = "deep";
    b.nested.weights.resize(1);
    b.count = 31;

    ZidlCdrWriter w;
    const size_t len = expect(v, views_MutableFrame_serialize);
    build(&w, b, views_MutableFrame_serialize_builder);
    fill(b.data, data);
    fill(b.nested.weights, weights);
    CHECK(views_MutableFrame_commit_builder(&w, &b) == 0);
    CHECK(w.len == len && std::memcmp(built, expected, len) == 0);
}

static void derived() {
    const int64_t stamps[2] = { 11, -22 };
    const uint16_t pixels[3] = { 1, 2, 65535 };
    views::Derived v;
    v.id = "base-id";
    v.stamps.assign(stamps, stamps + 2);
    v.pixels.assign(pixels, pixels + 3);

    views::DerivedBuilder b;
    b.id = "base-id";
    b.stamps.resize(2);
    b.pixels.resize(3);

    ZidlCdrWriter w;
    const size_t len = expect(v, views_Derived_serialize);
    build(&w, b, views_Derived_serialize_builder);
    fill(b.stamps, stamps);
    fill(b.pixels, pixels);
    CHECK(views_Derived_commit_builder(&w, &b) == 0);
    CHECK(w.len == len && std::memcmp(built, expected, len) == 0);
}

// Key members are as declared, so a builder's key hash is the struct's.
static void keyed() {
    const float values[3] = { 1.0f, 2.0f, 3.0f };
    builders::Keyed v;
    v.id = 77;
    v.name = "keyed";
    v.ids = { 5, -6 };
    v.origin.x = 3;
    v.origin.y = -4;
    v.values.assign(values, values + 3);
    v.label = "label";

    builders::KeyedBuilder b;
    b.id = 77;
    b.name = "keyed";
    b.ids = v.ids;
    b.origin = v.origin;
    b.values.resize(3);
    b.label = "label";

    ZidlCdrWriter w;
    const size_t len = expect(v, builders_Keyed_serialize);
    build(&w, b, builders_Keyed_serialize_builder);
    fill(b.values, values);
    CHECK(builders_Keyed_commit_builder(&w, &b) == 0);
    CHECK(w.len == len && std::memcmp(built, expected, len) == 0);

    uint8_t hash_v[16], hash_b[16];
    ZidlCdrKeyHash h;
    zidl_cdr_key_hash_init(&h);
    CHECK(builders_KeyedBuilder_serialize_key_holder(&h.writer, &b) == 0);
    zidl_cdr_key_hash_finish(&h, builders_Keyed_KEY_HASH_FORCE_MD5, hash_b);
    CHECK(builders_Keyed_compute_key_hash(&v, hash_v) == 0);
    CHECK(std::memcmp(hash_v, hash_b, 16) == 0);
}

static void key_derived() {
    const uint8_t header[2] = { 0xaa, 0xbb }, blob[5] = { 1, 2, 3, 4, 5 };
    builders::KeyDerived v;
    v.site = 12;
    v.header.assign(header, header + 2);
    v.tag = "tag";
    v.blob.assign(blob, blob + 5);

    builders::KeyDerivedBuilder b;
    b.site = 12;
    b.header.resize(2);
    b.tag = "tag";
    b.blob.resize(5);

    ZidlCdrWriter w;
    const size_t len = expect(v, builders_KeyDerived_serialize);
    build(&w, b, builders_KeyDerived_serialize_builder);
    fill(b.header, header);
    fill(b.blob, blob);
    CHECK(builders_KeyDerived_commit_builder(&w, &b) == 0);
    CHECK(w.len == len && std::memcmp(built, expected, len) == 0);

    uint8_t hash_v[16], hash_b[16];
    ZidlCdrKeyHash h;
    zidl_cdr_key_hash_init(&h);
    CHECK(builders_KeyDerivedBuilder_serialize_key_holder(&h.writer, &b) == 0);
    zidl_cdr_key_hash_finish(&h, builders_KeyDerived_KEY_HASH_FORCE_MD5, hash_b);
    CHECK(builders_KeyDerived_compute_key_hash(&v, hash_v) == 0);
    CHECK(std::memcmp(hash_v, hash_b, 16) == 0);
}

static void mutable_keyed() {
    const double samples[2] = { 0.25, -8.0 };
    const int16_t extra[3] = { -1, 2, -3 };
    builders::MutableKeyed v;
    v.serial = 0x0102030405060708ULL;
    v.samples.assign(samples, samples + 2);
    v.extra.emplace(extra, extra + 3);

    builders::MutableKeyedBuilder b;
    b.serial = v.serial;
    b.samples.resize(2);
    b.extra.emplace(3);

    ZidlCdrWriter w;
    const size_t len = expect(v, builders_MutableKeyed_serialize);
    build(&w, b, builders_MutableKeyed_serialize_builder);
    fill(b.samples, samples);
    fill(*b.extra, extra);
    CHECK(builders_MutableKeyed_commit_builder(&w, &b) == 0);
    CHECK(w.len == len && std::memcmp(built, expected, len) == 0);
}

static void bounded() {
    builders::BoundedBuilder b;
    ZidlCdrWriter cw;
    b.few.resize(5);
    zidl_cdr_writer_init_counting(&cw, version);
    CHECK(builders_Bounded_serialize_builder(&cw, &b) == ZIDL_CDR_INVALID);
    b.few.resize(4);
    zidl_cdr_writer_init_counting(&cw, version);
    CHECK(builders_Bounded_serialize_builder(&cw, &b) == 0);
}

int main() {
    for (order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order) {
        for (version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
            final_frame();
            derived();
            keyed();
            key_derived();
            bounded();
        }
        // XCDR1 has no ordinary mutable encoding.
        version = ZIDL_XCDR2;
        mutable_frame();
        mutable_keyed();
    }
    std::puts("cpp builders: all checks passed");
    return 0;
}
