/* Generated view types (--generate-views) decode in place: viewed members
 * match what was serialized in both byte orders and XCDR versions, owned
 * members decode as in the struct, optionals follow presence, a failed decode
 * leaves the view zeroed, and a bounded string's bound is enforced. */
#include <stdio.h>
#include <string.h>
#include "views.h"
#include "wide_defaults.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: CHECK(%s) failed (version %d, order %d)\n", __FILE__, __LINE__, #c, version, order); return 1; } } while (0)

static uint8_t bytes[4096];

static bool host_le(void) {
    const uint16_t probe = 1;
    return *(const uint8_t *)&probe == 1;
}

/* Whether a stream in `order` has its multi-byte elements swapped. */
static bool swaps(int order) {
    return host_le() != (order == ZIDL_CDR_LE);
}

static void begin(ZidlCdrWriter *w, int version, int order) {
    zidl_cdr_writer_init_fixed(w, bytes, sizeof bytes, version);
    zidl_cdr_writer_set_byte_order(w, order);
    (void)zidl_cdr_write_encap(w);
}

static int final_frame(int version, int order) {
    char name[] = "frame", note[] = "a note", inner_label[] = "inner";
    char label_a[] = "a", label_b[] = "bc";
    uint8_t data[5] = { 1, 2, 3, 4, 5 };
    double samples[3] = { 1.5, -2.25, 1e300 }, samples_out[3];
    bool flags[2] = { true, false };
    char *labels[2] = { label_a, label_b };
    float weights[2] = { 0.5f, 4.0f }, weights_out[2];
    int32_t extra[3] = { 7, -8, 9 }, extra_out[3], grid_out[6];
    views_FinalFrame v;
    views_FinalFrame_default(&v);
    v.first = 9;
    v.name = name;
    strcpy(v.tag, "tag8");
    v.data = (uint8_t_seq){ 5, 5, data, false };
    v.samples = (double_seq){ 3, 3, samples, false };
    for (int i = 0; i < 6; ++i) v.grid[i / 3][i % 3] = i * 11 - 20;
    v.flags = (bool_seq){ 2, 2, flags, false };
    v.labels = (string_seq){ 2, 2, labels, false };
    v.nested.id = 42;
    v.nested.label = inner_label;
    v.nested.weights = (float_seq){ 2, 2, weights, false };
    v._present = 3;
    v.note = note;
    v.extra = (int32_t_seq){ 3, 3, extra, false };

    ZidlCdrWriter w;
    ZidlCdrReader r;
    views_FinalFrameView view;
    begin(&w, version, order);
    CHECK(views_FinalFrame_serialize(&w, &v) == 0);
    CHECK(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
    CHECK(views_FinalFrame_deserialize_view(&r, &view) == 0);
    CHECK(r.pos == w.len);

    /* Zero-copy strings and views of the input. */
    CHECK(view.first == 9);
    CHECK(strcmp(view.name, "frame") == 0 && strcmp(view.tag, "tag8") == 0);
    CHECK(view.name >= (const char *)bytes && view.name < (const char *)bytes + w.len);
    CHECK(view.data.count == 5 && view.data.elem_size == 1 && !view.data.swapped);
    CHECK(ZIDL_CDR_VIEW_AS(&view.data, uint8_t) != NULL && memcmp(view.data.data, data, 5) == 0);
    CHECK(view.samples.count == 3 && view.samples.elem_size == 8 && view.samples.swapped == swaps(order));
    CHECK(zidl_cdr_view_copy(&view.samples, samples_out) == 0 && memcmp(samples_out, samples, sizeof samples) == 0);
    CHECK(view.grid.count == 6 && view.grid.elem_size == 4);
    CHECK(zidl_cdr_view_copy(&view.grid, grid_out) == 0);
    for (int i = 0; i < 6; ++i) CHECK(grid_out[i] == i * 11 - 20);
    /* Owned members, decoded as in the struct. */
    CHECK(view.flags._length == 2 && view.flags._buffer[0] && !view.flags._buffer[1]);
    CHECK(view.labels._length == 2 && strcmp(view.labels._buffer[1], "bc") == 0);
    /* A nested view. */
    CHECK(view.nested.id == 42 && strcmp(view.nested.label, "inner") == 0);
    CHECK(view.nested.weights.count == 2 && zidl_cdr_view_copy(&view.nested.weights, weights_out) == 0);
    CHECK(memcmp(weights_out, weights, sizeof weights) == 0);
    /* Present optionals. */
    CHECK(view._present == 3 && strcmp(view.note, "a note") == 0);
    CHECK(view.extra.count == 3 && zidl_cdr_view_copy(&view.extra, extra_out) == 0);
    CHECK(memcmp(extra_out, extra, sizeof extra) == 0);
    views_FinalFrameView_free(&view);
    CHECK(view.name == NULL && view.labels._buffer == NULL);

    /* Absent optionals. */
    v._present = 0;
    begin(&w, version, order);
    CHECK(views_FinalFrame_serialize(&w, &v) == 0);
    CHECK(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
    CHECK(views_FinalFrame_deserialize_view(&r, &view) == 0);
    CHECK(view._present == 0 && view.note == NULL && view.extra.count == 0);
    views_FinalFrameView_free(&view);

    /* A failed decode leaves the view zeroed, owning nothing. */
    CHECK(zidl_cdr_reader_init(&r, bytes, w.len - 1) == 0);
    CHECK(views_FinalFrame_deserialize_view(&r, &view) != 0);
    CHECK(view.name == NULL && view.data.data == NULL && view.labels._buffer == NULL && view.flags._buffer == NULL);
    views_FinalFrameView_free(&view);
    return 0;
}

static int append_frame(int version, int order) {
    char name[] = "appended";
    uint8_t data[3] = { 9, 8, 7 };
    uint16_t codes[2] = { 0x1234, 0xabcd }, codes_out[2];
    int64_t stamps[2] = { -1, 0x0102030405060708LL }, stamps_out[2];
    views_AppendFrame v;
    views_AppendFrame_default(&v);
    v.name = name;
    v.data = (uint8_t_seq){ 3, 3, data, false };
    v.nested.code = -5;
    v.nested.codes = (uint16_t_seq){ 2, 2, codes, false };
    v._present = 1;
    v.stamps = (int64_t_seq){ 2, 2, stamps, false };

    ZidlCdrWriter w;
    ZidlCdrReader r;
    views_AppendFrameView view;
    begin(&w, version, order);
    CHECK(views_AppendFrame_serialize(&w, &v) == 0);
    CHECK(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
    CHECK(views_AppendFrame_deserialize_view(&r, &view) == 0);
    CHECK(strcmp(view.name, "appended") == 0 && view.data.count == 3 && memcmp(view.data.data, data, 3) == 0);
    CHECK(view.nested.code == -5 && zidl_cdr_view_copy(&view.nested.codes, codes_out) == 0);
    CHECK(memcmp(codes_out, codes, sizeof codes) == 0);
    CHECK(view._present == 1 && zidl_cdr_view_copy(&view.stamps, stamps_out) == 0);
    CHECK(memcmp(stamps_out, stamps, sizeof stamps) == 0);
    views_AppendFrameView_free(&view);
    return 0;
}

static int mutable_frame(int version, int order) {
    char name[] = "mutable", inner_label[] = "deep";
    uint8_t data[4] = { 4, 3, 2, 1 };
    float weights[1] = { 2.5f }, weights_out[1];
    views_MutableFrame v;
    views_MutableFrame_default(&v);
    v.name = name;
    v.data = (uint8_t_seq){ 4, 4, data, false };
    v.nested.id = 7;
    v.nested.label = inner_label;
    v.nested.weights = (float_seq){ 1, 1, weights, false };
    v._present = 1;
    v.count = 31;

    ZidlCdrWriter w;
    ZidlCdrReader r;
    views_MutableFrameView view;
    begin(&w, version, order);
    CHECK(views_MutableFrame_serialize(&w, &v) == 0);
    CHECK(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
    CHECK(views_MutableFrame_deserialize_view(&r, &view) == 0);
    CHECK(strcmp(view.name, "mutable") == 0 && view.data.count == 4 && memcmp(view.data.data, data, 4) == 0);
    CHECK(view.nested.id == 7 && strcmp(view.nested.label, "deep") == 0);
    CHECK(zidl_cdr_view_copy(&view.nested.weights, weights_out) == 0 && weights_out[0] == 2.5f);
    CHECK(view._present == 1 && view.count == 31);
    views_MutableFrameView_free(&view);
    return 0;
}

static int derived(int version, int order) {
    char id[] = "base-id";
    int64_t stamps[2] = { 11, -22 }, stamps_out[2];
    uint16_t pixels[3] = { 1, 2, 65535 }, pixels_out[3];
    views_Derived v;
    views_Derived_default(&v);
    v._base.id = id;
    v._base.stamps = (int64_t_seq){ 2, 2, stamps, false };
    v.pixels = (uint16_t_seq){ 3, 3, pixels, false };

    ZidlCdrWriter w;
    ZidlCdrReader r;
    views_DerivedView view;
    begin(&w, version, order);
    CHECK(views_Derived_serialize(&w, &v) == 0);
    CHECK(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
    CHECK(views_Derived_deserialize_view(&r, &view) == 0);
    CHECK(strcmp(view._base.id, "base-id") == 0);
    CHECK(zidl_cdr_view_copy(&view._base.stamps, stamps_out) == 0 && memcmp(stamps_out, stamps, sizeof stamps) == 0);
    CHECK(zidl_cdr_view_copy(&view.pixels, pixels_out) == 0 && memcmp(pixels_out, pixels, sizeof pixels) == 0);
    views_DerivedView_free(&view);
    return 0;
}

static int bounded(int version, int order) {
    char long_tag[] = "too long", short_tag[] = "ok";
    views_WideTag wide;
    views_WideTag_default(&wide);
    ZidlCdrWriter w;
    ZidlCdrReader r;
    views_NarrowTagView view;
    wide.tag = long_tag;
    begin(&w, version, order);
    CHECK(views_WideTag_serialize(&w, &wide) == 0);
    CHECK(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
    CHECK(views_NarrowTag_deserialize_view(&r, &view) == ZIDL_CDR_INVALID && view.tag == NULL);
    wide.tag = short_tag;
    begin(&w, version, order);
    CHECK(views_WideTag_serialize(&w, &wide) == 0);
    CHECK(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
    CHECK(views_NarrowTag_deserialize_view(&r, &view) == 0 && strcmp(view.tag, "ok") == 0);
    views_NarrowTagView_free(&view);
    return 0;
}

/* Defaults: a literal and a constant's (views do not apply defaults in C,
 * as the struct's decoder does not, but the struct's own defaults hold). */
static int defaults(int version, int order) {
    views_Defaults d;
    views_Defaults_default(&d);
    CHECK(d.label && strcmp(d.label, "fallback") == 0);
    CHECK(d.named && strcmp(d.named, "named fallback") == 0);
    views_Defaults_free(&d);
    return 0;
}

/* Wide string defaults copy their UTF-16 units: allocated for an unbounded
 * member (freed by _free), in place for a bounded one. */
static int wide_defaults(int version, int order) {
    static const uint16_t hi[] = { 'h', 'i', 0 }, lit[] = { 'l', 'i', 't', 0 }, o[] = { 'o', 0 };
    wd_WideDefaults d;
    wd_WideDefaults_default(&d);
    CHECK(d.named && memcmp(d.named, hi, sizeof hi) == 0);
    CHECK(d.literal && memcmp(d.literal, lit, sizeof lit) == 0);
    CHECK(memcmp(d.bounded, hi, sizeof hi) == 0);
    CHECK((d._present & 1u) && d.maybe && memcmp(d.maybe, o, sizeof o) == 0);
    wd_WideDefaults_free(&d);
    return 0;
}

int main(void) {
    for (int order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order) {
        for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
            if (final_frame(version, order) || append_frame(version, order) ||
                derived(version, order) || bounded(version, order)) return 1;
        }
        /* XCDR1 has no ordinary mutable encoding. */
        if (mutable_frame(ZIDL_XCDR2, order) || defaults(ZIDL_XCDR2, order) || wide_defaults(ZIDL_XCDR2, order)) return 1;
    }
    puts("views: all checks passed");
    return 0;
}
