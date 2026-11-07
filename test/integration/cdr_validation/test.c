/* Also compiled as C++. Only the generated source redirects checked patch calls
 * to these fault injectors, so a failure must travel through the real codec. */
#include <assert.h>
#include <string.h>
#include <stdlib.h>
#ifdef __cplusplus
#include "validation.hpp"
typedef Validation::App App;
typedef Validation::Mut Mut;
typedef Validation::Collections Collections;
#else
#include "validation.h"
typedef Validation_App App;
typedef Validation_Mut Mut;
typedef Validation_Collections Collections;
#endif

static int fail_dheader, fail_emheader;
#ifdef __cplusplus
extern "C" {
#endif
int validation_patch_dheader(ZidlCdrWriter *w, size_t offset) {
    return fail_dheader ? ZIDL_CDR_OVERFLOW : zidl_cdr_patch_dheader_checked(w, offset);
}
int validation_patch_emheader(ZidlCdrWriter *w, size_t offset, size_t start) {
    return fail_emheader ? ZIDL_CDR_OVERFLOW : zidl_cdr_patch_emheader_checked(w, offset, start);
}

#ifdef __cplusplus
}
#endif

static void patches(void) {
    App app = { 42 };
#ifdef __cplusplus
    Mut mut{};
    mut.text = "hello";
    Collections coll{};
    coll.text.push_back("hello");
#else
    Mut mut = { (char *)"hello" };
    char *items[] = { (char *)"hello" };
    Collections coll = { { 1, 1, items, false } };
#endif
    for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; version++) {
        ZidlCdrWriter w;
        fail_dheader = 1;
        fail_emheader = 0;
        zidl_cdr_writer_init_counting(&w, version);
        assert(Validation_App_serialize(&w, &app) == (version == ZIDL_XCDR2 ? ZIDL_CDR_OVERFLOW : ZIDL_CDR_OK));
        zidl_cdr_writer_init_counting(&w, version);
        assert(Validation_App_serialize_key(&w, &app) == (version == ZIDL_XCDR2 ? ZIDL_CDR_OVERFLOW : ZIDL_CDR_OK));
        zidl_cdr_writer_init_counting(&w, version);
        assert(Validation_Collections_serialize(&w, &coll) == (version == ZIDL_XCDR2 ? ZIDL_CDR_OVERFLOW : ZIDL_CDR_OK));
    }
    for (int which = 0; which < 2; which++) {
        ZidlCdrWriter w;
        zidl_cdr_writer_init_counting(&w, ZIDL_XCDR2);
        fail_dheader = which;
        fail_emheader = !which;
        assert(Validation_Mut_serialize(&w, &mut) == ZIDL_CDR_OVERFLOW);
    }
    fail_dheader = fail_emheader = 0;
}

static void wide_strings(void) {
    for (int le = 0; le < 2; le++) {
        /* Two content units (including an embedded NUL), then id. */
        uint8_t data[] = { 0, 6, 0, 0, 0, 0, 0, 0, 0, 'A', 0, 0, 0, 0, 0, 7 };
        data[1] += (uint8_t)le;
        data[le ? 4 : 7] = 4;
        if (le) { data[8] = 'A'; data[9] = 0; data[12] = 7; data[15] = 0; }
        ZidlCdrReader r;
        assert(zidl_cdr_reader_init(&r, data, sizeof data) == 0);
        assert(Validation_Wide_skip(&r) == 0 && r.pos == sizeof data);
        for (size_t len = 4; len < sizeof data; len++) {
            assert(zidl_cdr_reader_init(&r, data, len) == 0);
            assert(Validation_Wide_skip(&r) == ZIDL_CDR_TRUNCATED);
        }
#ifdef __cplusplus
        Validation::Wide value{};
        assert(zidl_cdr_reader_init(&r, data, sizeof data) == 0);
        assert(Validation_Wide_deserialize(&r, &value) == 0);
        assert(value.text.size() == 2 && value.text[0] == L'A' && value.text[1] == 0 && value.id == 7);
#endif
        data[le ? 4 : 7] = 3;
        assert(zidl_cdr_reader_init(&r, data, sizeof data) == 0);
        assert(Validation_Wide_skip(&r) == ZIDL_CDR_INVALID);
#ifdef __cplusplus
        value.text = L"unchanged";
        assert(zidl_cdr_reader_init(&r, data, sizeof data) == 0);
        assert(Validation_Wide_deserialize(&r, &value) == ZIDL_CDR_INVALID);
        assert(value.text == L"unchanged");
        /* A modest oversized length must fail before resize,
         * remaining safe even if preflight regresses. */
        memset(data + 4, 0, 4);
        data[le ? 4 : 7] = 0xfe;
        data[le ? 5 : 6] = 0xff;
        assert(zidl_cdr_reader_init(&r, data, sizeof data) == 0);
        assert(Validation_Wide_deserialize(&r, &value) == ZIDL_CDR_TRUNCATED);
        assert(value.text == L"unchanged");
#endif
    }
}

#ifdef __cplusplus
typedef Validation::AppParent AppParent;
typedef Validation::MutParent MutParent;
typedef Validation::CollParent CollParent;
typedef Validation::ArrayFields ArrayFields;
typedef Validation::UnionParent UnionParent;
#define INIT {}
#define FREE(name, value) ((void)0)
#else
typedef Validation_AppParent AppParent;
typedef Validation_MutParent MutParent;
typedef Validation_CollParent CollParent;
typedef Validation_ArrayFields ArrayFields;
typedef Validation_UnionParent UnionParent;
#define INIT {0}
#define FREE(name, value) Validation_##name##_free(&(value))
#endif

/* Track exact C allocation/free sizes across malformed nested frames. */
static struct { void *p; size_t n; } live_blocks[16];
static size_t live_count;
static void *tracked_alloc(void *ctx, size_t n, size_t alignment) {
    (void)ctx; (void)alignment;
    assert(live_count < 16);
    void *p = malloc(n);
    assert(p);
    live_blocks[live_count].p = p;
    live_blocks[live_count++].n = n;
    return p;
}
static bool tracked_resize(void *ctx, void *p, size_t old_n, size_t new_n, size_t alignment) {
    (void)ctx; (void)p; (void)old_n; (void)new_n; (void)alignment;
    return false;
}
static void tracked_free(void *ctx, void *p, size_t n, size_t alignment) {
    (void)ctx; (void)alignment;
    size_t i = 0;
    while (i < live_count && live_blocks[i].p != p) i++;
    assert(i < live_count && live_blocks[i].n == n);
    live_blocks[i] = live_blocks[--live_count];
    free(p);
}

static void frame_boundaries(void) {
    const ZidlAllocator allocator = { NULL, tracked_alloc, tracked_resize, tracked_free };
    zidl_cdr_set_allocator(&allocator);
    ZidlCdrReader r;
    /* Inner appendable frame has a future field before the parent's tail. */
    uint8_t app[] = { 0,7,0,0, 8,0,0,0, 42,0,0,0, 99,0,0,0, 7,0,0,0 };
    AppParent a = INIT;
    assert(zidl_cdr_reader_init(&r, app, sizeof app) == 0);
    assert(Validation_AppParent_deserialize(&r, &a) == 0);
    assert(a.inner.value == 42 && a.tail == 7 && r.pos == sizeof app && r.data_len == sizeof app);
    app[4] = 2; // Bytes for the known field still exist beyond the declared end.
    a.tail = 0;
    assert(zidl_cdr_reader_init(&r, app, sizeof app) == 0);
    assert(Validation_AppParent_deserialize(&r, &a) == ZIDL_CDR_TRUNCATED);
    assert(a.tail == 0 && r.pos <= 10 && r.data_len == sizeof app);
    App key = INIT;
    assert(zidl_cdr_reader_init(&r, app, sizeof app) == 0);
    assert(Validation_App_deserialize_key(&r, &key) == ZIDL_CDR_TRUNCATED);
    assert(r.pos <= 10 && r.data_len == sizeof app);

    /* Both outer DHEADER and individual NEXTINT must constrain string reads. */
    uint8_t mut[] = { 0,7,0,0, 16,0,0,0, 0,0,0,0x40, 8,0,0,0, 2,0,0,0, 'x',0,0,0, 7,0,0,0 };
    MutParent m = INIT;
    assert(zidl_cdr_reader_init(&r, mut, sizeof mut) == 0);
    assert(Validation_MutParent_deserialize(&r, &m) == 0);
    assert(m.tail == 7 && r.pos == sizeof mut && r.data_len == sizeof mut);
    FREE(MutParent, m);
    for (int bad = 0; bad < 3; bad++) {
        MutParent out = INIT;
        mut[4] = bad == 0 ? 4 : 16;
        mut[8] = bad == 2 ? 99 : 0;
        mut[12] = bad == 1 ? 4 : (bad == 2 ? 12 : 8);
        size_t limit = bad == 0 ? 12 : (bad == 1 ? 20 : 24);
        assert(zidl_cdr_reader_init(&r, mut, sizeof mut) == 0);
        assert(Validation_MutParent_deserialize(&r, &out) == ZIDL_CDR_TRUNCATED);
        assert(out.tail == 0 && r.pos <= limit && r.data_len == sizeof mut);
        FREE(MutParent, out);
    }

    /* A non-primitive sequence needs its own window even in a final parent. */
    uint8_t coll[] = { 0,7,0,0, 10,0,0,0, 1,0,0,0, 2,0,0,0, 'x',0,0,0, 7,0,0,0 };
    CollParent c = INIT;
    assert(zidl_cdr_reader_init(&r, coll, sizeof coll) == 0);
    assert(Validation_CollParent_deserialize(&r, &c) == 0);
    assert(c.tail == 7 && r.pos == sizeof coll && r.data_len == sizeof coll);
    FREE(CollParent, c);
    coll[4] = 8;
    CollParent bad_c = INIT;
    assert(zidl_cdr_reader_init(&r, coll, sizeof coll) == 0);
    assert(Validation_CollParent_deserialize(&r, &bad_c) == ZIDL_CDR_TRUNCATED);
    assert(bad_c.tail == 0 && r.pos <= 16 && r.data_len == sizeof coll);
    FREE(CollParent, bad_c);
    assert(zidl_cdr_reader_init(&r, coll, sizeof coll) == 0);
    assert(Validation_CollParent_skip(&r) == ZIDL_CDR_TRUNCATED);
    assert(r.pos <= 16 && r.data_len == sizeof coll);

    /* One DHEADER bounds the complete array, before the parent's next field. */
    uint8_t array[] = { 0,7,0,0, 14,0,0,0, 2,0,0,0, 'a',0,0,0, 2,0,0,0, 'b',0,0,0, 7,0,0,0 };
    ArrayFields arr = INIT;
    assert(zidl_cdr_reader_init(&r, array, sizeof array) == 0);
    assert(Validation_ArrayFields_deserialize(&r, &arr) == 0);
    assert(arr.tail == 7 && r.pos == sizeof array && r.data_len == sizeof array);
    FREE(ArrayFields, arr);
    array[4] = 12;
    ArrayFields bad_arr = INIT;
    assert(zidl_cdr_reader_init(&r, array, sizeof array) == 0);
    assert(Validation_ArrayFields_deserialize(&r, &bad_arr) == ZIDL_CDR_TRUNCATED);
    assert(bad_arr.tail == 0 && r.pos <= 20 && r.data_len == sizeof array);
    FREE(ArrayFields, bad_arr);
    assert(zidl_cdr_reader_init(&r, array, sizeof array) == 0);
    assert(Validation_ArrayFields_skip(&r) == ZIDL_CDR_TRUNCATED);
    assert(r.pos <= 20 && r.data_len == sizeof array);

    uint8_t uni[] = { 0,7,0,0, 20,0,0,0, 0,0,0,0x20, 0,0,0,0, 1,0,0,0x40, 4,0,0,0, 42,0,0,0, 7,0,0,0 };
    UnionParent u = INIT;
    assert(zidl_cdr_reader_init(&r, uni, sizeof uni) == 0);
    assert(Validation_UnionParent_deserialize(&r, &u) == 0);
    assert(u.tail == 7 && r.pos == sizeof uni && r.data_len == sizeof uni);
    uni[20] = 2;
    assert(zidl_cdr_reader_init(&r, uni, sizeof uni) == 0);
    assert(Validation_UnionParent_deserialize(&r, &u) == ZIDL_CDR_TRUNCATED);
    assert(r.pos <= 26 && r.data_len == sizeof uni);

    /* Key-only hashing must release a decoded key if later framing fails. */
    uint8_t key_wire[] = { 0,9,0,0, 4,0,0,0, 2,0,0,0, 'x',0,0,0 };
    uint8_t hash[16];
    assert(Validation_AppText_compute_key_hash_from_cdr_key_only(key_wire, sizeof key_wire, hash) == ZIDL_CDR_TRUNCATED);
    uint8_t mut_key[] = { 0,11,0,0, 20,0,0,0, 0,0,0,0x40, 6,0,0,0, 2,0,0,0, 'x',0,0,0, 1,0,0,0x20, 7,0,0,0 };
    assert(Validation_MutKey_compute_key_hash_from_cdr_key_only(mut_key, sizeof mut_key, hash) == ZIDL_CDR_TRUNCATED);
    assert(live_count == 0);
    zidl_cdr_set_allocator(NULL);
}

#ifdef __cplusplus
typedef Validation::Small Small;
typedef Validation::Medium Medium;
typedef Validation::Narrow Narrow;
typedef Validation::NarrowLast NarrowLast;
#else
typedef Validation_Small Small;
typedef Validation_Medium Medium;
typedef Validation_Narrow Narrow;
typedef Validation_NarrowLast NarrowLast;
#endif

static void narrow_enums(void) {
    for (int order=ZIDL_CDR_LE; order<=ZIDL_CDR_BE; order++) {
        uint8_t bytes[64], expected[]={0,11,0,0,5,0,0,0,0,0,0,0,1};
        expected[1]=(order==ZIDL_CDR_LE ? 11 : 10);
        expected[4]=(order==ZIDL_CDR_LE ? 5 : 0);
        expected[7]=(order==ZIDL_CDR_LE ? 0 : 5);
        NarrowLast last=INIT, decoded_last=INIT;
        last.only=(Small)1;
        ZidlCdrWriter w;
        zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,ZIDL_XCDR2);
        zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap_kind(&w,ZIDL_EXT_MUTABLE)==0);
        assert(Validation_NarrowLast_serialize(&w,&last)==0);
        assert(w.len==sizeof expected && !memcmp(bytes,expected,sizeof expected));
        ZidlCdrReader r;
        assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);
        assert(Validation_NarrowLast_deserialize(&r,&decoded_last)==0);
        assert(decoded_last.only==last.only && r.pos==w.len);
        assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);
        assert(Validation_NarrowLast_skip(&r)==0 && r.pos==w.len);

        Narrow value=INIT, decoded=INIT;
        value.first=(Small)1; value.second=(Medium)1; value.tail=7;
        zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,ZIDL_XCDR2);
        zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap_kind(&w,ZIDL_EXT_MUTABLE)==0);
        assert(Validation_Narrow_serialize(&w,&value)==0);
        assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);
        assert(Validation_Narrow_deserialize(&r,&decoded)==0);
        assert(decoded.first==value.first && decoded.second==value.second && decoded.tail==7 && r.pos==w.len);
        assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);
        assert(Validation_Narrow_skip(&r)==0 && r.pos==w.len);
    }
}

int main(void) {
    narrow_enums();
    patches();
    wide_strings();
    frame_boundaries();
    return 0;
}
