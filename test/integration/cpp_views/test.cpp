// Generated C++ view types (--generate-views) decode in place: viewed members
// match what was serialized in both byte orders and XCDR versions, owned
// members decode as in the struct, optionals follow presence, a failed decode
// leaves the view reset, a bounded string's bound is enforced and a string's
// @default is kept when a mutable sample omits it.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "views.hpp"
#include "named.hpp"

static int version, order;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "%s:%d: CHECK(%s) failed (version %d, order %d)\n", __FILE__, __LINE__, #c, version, order); std::exit(1); } } while (0)

// Allocated storage: views read elements in place only from storage with no
// declared type.
static uint8_t *bytes = static_cast<uint8_t *>(std::malloc(4096));

static bool host_le() {
    const uint16_t probe = 1;
    uint8_t first;
    std::memcpy(&first, &probe, 1);
    return first == 1;
}

static bool swaps() { return host_le() != (order == ZIDL_CDR_LE); }

static void begin(ZidlCdrWriter *w) {
    zidl_cdr_writer_init_fixed(w, bytes, 4096, version);
    zidl_cdr_writer_set_byte_order(w, order);
    (void)zidl_cdr_write_encap(w);
}

template <typename T, typename F>
static size_t encode(const T &value, F serialize) {
    ZidlCdrWriter w;
    begin(&w);
    CHECK(serialize(&w, &value) == 0);
    return w.len;
}

template <typename V, typename F>
static int decode(size_t len, V *view, F deserialize) {
    ZidlCdrReader r;
    CHECK(zidl_cdr_reader_init(&r, bytes, len) == 0);
    const int rc = deserialize(&r, view);
    if (rc == 0) CHECK(r.pos == len);
    return rc;
}

template <typename T>
static bool same(const zidl::PrimitivesView<T> &view, const std::vector<T> &want) {
    if (view.to_vector() != want) return false;
    // In place exactly when unswapped and aligned in memory: CDR aligns
    // relative to the payload, which starts 4 bytes into the buffer, so XCDR1
    // eight-byte elements are not.
    const T *native = view.as_native();
    const bool aligned = reinterpret_cast<uintptr_t>(view.c_view().data) % alignof(T) == 0;
    if (want.empty() || (swaps() && sizeof(T) > 1) || !aligned) return native == nullptr;
    return native != nullptr && std::memcmp(native, want.data(), want.size() * sizeof(T)) == 0;
}

static void final_frame() {
    views::FinalFrame v{};
    v.first = 9;
    v.name = "frame";
    v.tag = "tag8";
    v.data = {1, 2, 3, 4, 5};
    v.samples = {1.5, -2.25, 1e300};
    for (int i = 0; i < 6; ++i) v.grid[i / 3][i % 3] = i * 11 - 20;
    v.flags = {true, false};
    v.labels = {"a", "bc"};
    v.nested.id = 42;
    v.nested.label = "inner";
    v.nested.weights = {0.5f, 4.0f};
    v.note = "a note";
    v.extra = std::vector<int32_t>{7, -8, 9};

    size_t len = encode(v, views_FinalFrame_serialize);
    views::FinalFrameView view;
    CHECK(decode(len, &view, views_FinalFrame_deserialize_view) == 0);
    // Zero-copy strings and views of the input.
    CHECK(view.first == 9 && view.name == "frame" && view.tag == "tag8");
    CHECK(view.name.data() >= reinterpret_cast<const char *>(bytes) && view.name.data() < reinterpret_cast<const char *>(bytes) + len);
    CHECK(same(view.data, {1, 2, 3, 4, 5}));
    CHECK(view.samples.swapped() == swaps() && same(view.samples, {1.5, -2.25, 1e300}));
    std::vector<int32_t> grid;
    for (int i = 0; i < 6; ++i) grid.push_back(i * 11 - 20);
    CHECK(same(view.grid, grid));
    // Owned members, decoded as in the struct.
    CHECK(view.flags == std::vector<bool>({true, false}));
    CHECK(view.labels.size() == 2 && view.labels[1] == "bc");
    // A nested view.
    CHECK(view.nested.id == 42 && view.nested.label == "inner" && same(view.nested.weights, {0.5f, 4.0f}));
    // Present optionals.
    CHECK(view.note && *view.note == "a note");
    CHECK(view.extra && same(*view.extra, {7, -8, 9}));

    // Absent optionals.
    v.note.reset();
    v.extra.reset();
    len = encode(v, views_FinalFrame_serialize);
    CHECK(decode(len, &view, views_FinalFrame_deserialize_view) == 0);
    CHECK(!view.note && !view.extra);

    // A failed decode resets the view, owning nothing.
    CHECK(decode(len - 1, &view, views_FinalFrame_deserialize_view) != 0);
    CHECK(view.name.empty() && view.data.empty() && view.labels.empty() && view.flags.empty() && view.nested.label.empty());
}

static void append_frame() {
    views::AppendFrame v{};
    v.name = "appended";
    v.data = {9, 8, 7};
    v.nested.code = -5;
    v.nested.codes = {0x1234, 0xabcd};
    v.stamps = std::vector<int64_t>{-1, 0x0102030405060708LL};
    views::AppendFrameView view;
    CHECK(decode(encode(v, views_AppendFrame_serialize), &view, views_AppendFrame_deserialize_view) == 0);
    CHECK(view.name == "appended" && same(view.data, {9, 8, 7}));
    CHECK(view.nested.code == -5 && same(view.nested.codes, {0x1234, 0xabcd}));
    CHECK(view.stamps && same(*view.stamps, {-1, 0x0102030405060708LL}));
}

static void mutable_frame() {
    views::MutableFrame v{};
    v.name = "mutable";
    v.data = {4, 3, 2, 1};
    v.nested.id = 7;
    v.nested.label = "deep";
    v.nested.weights = {2.5f};
    v.count = 31;
    views::MutableFrameView view;
    CHECK(decode(encode(v, views_MutableFrame_serialize), &view, views_MutableFrame_deserialize_view) == 0);
    CHECK(view.name == "mutable" && same(view.data, {4, 3, 2, 1}));
    CHECK(view.nested.id == 7 && view.nested.label == "deep" && same(view.nested.weights, {2.5f}));
    CHECK(view.count && *view.count == 31);
}

static void derived() {
    views::Derived v{};
    v.id = "base-id";
    v.stamps = {11, -22};
    v.pixels = {1, 2, 65535};
    views::DerivedView view;
    CHECK(decode(encode(v, views_Derived_serialize), &view, views_Derived_deserialize_view) == 0);
    const views::BaseView &base = view;
    CHECK(base.id == "base-id" && same(base.stamps, {11, -22}));
    CHECK(same(view.pixels, {1, 2, 65535}));
}

static void bounded() {
    views::WideTag wide{};
    views::NarrowTagView view;
    wide.tag = "too long";
    CHECK(decode(encode(wide, views_WideTag_serialize), &view, views_NarrowTag_deserialize_view) == ZIDL_CDR_INVALID);
    CHECK(view.tag.empty());
    wide.tag = "ok";
    CHECK(decode(encode(wide, views_WideTag_serialize), &view, views_NarrowTag_deserialize_view) == 0 && view.tag == "ok");
}

static void defaults() {
    // An older sample, from before `label` and `maybe`.
    views::DefaultsOld old{};
    old.name = "n";
    old.data = {1};
    const size_t len = encode(old, views_DefaultsOld_serialize);
    views::DefaultsView view;
    CHECK(decode(len, &view, views_Defaults_deserialize_view) == 0);
    views::Defaults owned{};
    ZidlCdrReader r;
    CHECK(zidl_cdr_reader_init(&r, bytes, len) == 0 && views_Defaults_deserialize(&r, &owned) == 0);
    CHECK(view.name == "n" && view.label == owned.label && view.label == "fallback");
    // A mutable omission disengages an optional, as in the struct.
    CHECK(view.maybe.has_value() == owned.maybe.has_value());
}

// A default naming a constant is kept too.
static void named_default() {
    named::Old old{};
    old.name = "n";
    const size_t len = encode(old, named_Old_serialize);
    named::NewView view;
    CHECK(decode(len, &view, named_New_deserialize_view) == 0);
    CHECK(view.name == "n" && view.label == named::FALLBACK && view.label == "named fallback");
    // An omitted optional is disengaged, as in the struct.
    CHECK(!view.maybe);
}

int main() {
    for (order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order) {
        for (version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
            final_frame();
            append_frame();
            derived();
            bounded();
        }
        // XCDR1 has no ordinary mutable encoding.
        version = ZIDL_XCDR2;
        mutable_frame();
        defaults();
        named_default();
    }
    std::free(bytes);
    std::puts("cpp views: all checks passed");
    return 0;
}
