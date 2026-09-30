/* Compile-and-run checks for the C backend's sequences of struct/union
 * elements and aliases (see fixture.idl for the regressions covered).
 *
 * Every allocation goes through a tracking ZidlAllocator: fresh blocks are
 * filled with garbage (so reading an element the decoder never wrote is not
 * silently NULL), frees must match a live block and its size, and each check
 * ends with no live blocks. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fixture.h"

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            exit(1);                                                             \
        }                                                                        \
    } while (0)

/* ── Tracking allocator ─────────────────────────────────────────────────── */

#define MAX_LIVE 1024

static struct { void *p; size_t n; } live[MAX_LIVE];
static size_t live_count;
static long fail_after = -1; /* allocations left before failing; -1 = never */

static void *t_alloc(void *ctx, size_t n, size_t align) {
    (void)ctx;
    (void)align;
    if (fail_after == 0) return NULL;
    if (fail_after > 0) fail_after--;
    CHECK(live_count < MAX_LIVE);
    void *p = malloc(n ? n : 1);
    CHECK(p != NULL);
    memset(p, 0xA5, n);
    live[live_count].p = p;
    live[live_count].n = n;
    live_count++;
    return p;
}

static bool t_resize(void *ctx, void *p, size_t old_n, size_t new_n, size_t align) {
    (void)ctx;
    (void)p;
    (void)old_n;
    (void)new_n;
    (void)align;
    return false;
}

static void t_free(void *ctx, void *p, size_t n, size_t align) {
    (void)ctx;
    (void)align;
    for (size_t i = 0; i < live_count; i++) {
        if (live[i].p == p) {
            CHECK(live[i].n == n);
            live[i] = live[--live_count];
            free(p);
            return;
        }
    }
    CHECK(!"free of a pointer that is not a live allocation");
}

static const ZidlAllocator tracking = { NULL, t_alloc, t_resize, t_free };

#define CHECK_NO_LIVE() CHECK(live_count == 0)

/* ── Encode / decode helpers ────────────────────────────────────────────── */

typedef struct {
    uint8_t buf[1024];
    size_t len; /* including the 4-byte encapsulation header */
} Wire;

#define ENCODE(T, value, wire)                                             \
    do {                                                                   \
        ZidlCdrWriter w_;                                                  \
        zidl_cdr_writer_init_fixed(&w_, (wire).buf, sizeof (wire).buf, ZIDL_XCDR2); \
        CHECK(zidl_cdr_write_encap(&w_) == 0);                             \
        CHECK(T##_serialize(&w_, &(value)) == 0);                          \
        (wire).len = w_.pos + 4;                                           \
    } while (0)

/* Decode the first `len` bytes of `wire` into a zeroed `out`; yields the rc. */
#define DECODE(T, wire, len, out, rc)                                      \
    do {                                                                   \
        ZidlCdrReader r_;                                                  \
        memset(&(out), 0, sizeof(out));                                    \
        if (zidl_cdr_reader_init(&r_, (wire).buf, (len)) != 0) {           \
            (rc) = -1;                                                     \
        } else {                                                           \
            (rc) = T##_deserialize(&r_, &(out));                           \
        }                                                                  \
    } while (0)

/* Decoding every strict prefix must fail, and `_free` on the partial result
 * must release exactly what was allocated -- never-read elements included.
 * Then every allocation-failure point must also leave a freeable value. */
#define CHECK_FAILURE_PATHS(T, wire)                                       \
    do {                                                                   \
        T out_;                                                            \
        int rc_;                                                           \
        for (size_t cut_ = 0; cut_ < (wire).len; cut_++) {                 \
            DECODE(T, wire, cut_, out_, rc_);                              \
            CHECK(rc_ != 0);                                               \
            T##_free(&out_);                                               \
            CHECK_NO_LIVE();                                               \
        }                                                                  \
        for (long k_ = 0;; k_++) {                                         \
            fail_after = k_;                                               \
            DECODE(T, wire, (wire).len, out_, rc_);                        \
            fail_after = -1;                                               \
            T##_free(&out_);                                               \
            CHECK_NO_LIVE();                                               \
            if (rc_ == 0) break;                                           \
            CHECK(k_ < 1000);                                              \
        }                                                                  \
    } while (0)

static Named names3[3] = { { "alpha", 1 }, { "beta", 2 }, { "gamma", 3 } };

static Named_seq borrowed_names(uint32_t n) {
    Named_seq s = { n, n, names3, false };
    return s;
}

static void check_names(const Named_seq *s, uint32_t n) {
    CHECK(s->_length == n);
    CHECK(s->_release);
    for (uint32_t i = 0; i < n; i++) {
        CHECK(strcmp(s->_buffer[i].label, names3[i].label) == 0);
        CHECK(s->_buffer[i].id == names3[i].id);
    }
}

/* ── Tests ──────────────────────────────────────────────────────────────── */

static void test_unbounded_and_typedef_holders(void) {
    Wire wire;
    int rc;

    UnboundedHolder u = { borrowed_names(3) };
    ENCODE(UnboundedHolder, u, wire);
    UnboundedHolder u_out;
    DECODE(UnboundedHolder, wire, wire.len, u_out, rc);
    CHECK(rc == 0);
    check_names(&u_out.items, 3);
    UnboundedHolder_free(&u_out);
    CHECK_NO_LIVE();
    CHECK_FAILURE_PATHS(UnboundedHolder, wire);

    TypedefUnboundedHolder t = { borrowed_names(3) };
    ENCODE(TypedefUnboundedHolder, t, wire);
    TypedefUnboundedHolder t_out;
    DECODE(TypedefUnboundedHolder, wire, wire.len, t_out, rc);
    CHECK(rc == 0);
    check_names(&t_out.items, 3);
    /* The typedef's own _free (declared in the header) must link and free. */
    NamedSeq_free(&t_out.items);
    CHECK_NO_LIVE();
    CHECK_FAILURE_PATHS(TypedefUnboundedHolder, wire);
}

static void test_bounded_holders(void) {
    Wire wire;
    int rc;

    NamedHolder n = { borrowed_names(3), 7 };
    ENCODE(NamedHolder, n, wire);
    NamedHolder n_out;
    DECODE(NamedHolder, wire, wire.len, n_out, rc);
    CHECK(rc == 0);
    check_names(&n_out.items, 3);
    CHECK(n_out.tail == 7);
    NamedHolder_free(&n_out);
    CHECK_NO_LIVE();
    CHECK_FAILURE_PATHS(NamedHolder, wire);

    TypedefBoundedHolder tb = { borrowed_names(2) };
    ENCODE(TypedefBoundedHolder, tb, wire);
    CHECK_FAILURE_PATHS(TypedefBoundedHolder, wire);

    Outer o = { { borrowed_names(2), 9 }, 11 };
    ENCODE(Outer, o, wire);
    Outer o_out;
    DECODE(Outer, wire, wire.len, o_out, rc);
    CHECK(rc == 0);
    check_names(&o_out.inner.items, 2);
    CHECK(o_out.inner.tail == 9 && o_out.x == 11);
    Outer_free(&o_out);
    CHECK_NO_LIVE();
    CHECK_FAILURE_PATHS(Outer, wire);
}

static void test_union_elements_and_cases(void) {
    Wire wire;
    int rc;

    Choice choices[3];
    memset(choices, 0, sizeof choices);
    choices[0]._d = 0;
    choices[0]._u.i = 5;
    choices[1]._d = 1;
    choices[1]._u.s = "text";
    choices[2]._d = 1;
    choices[2]._u.s = "more";
    ChoiceHolder c = { { 3, 3, choices, false } };
    ENCODE(ChoiceHolder, c, wire);
    ChoiceHolder c_out;
    DECODE(ChoiceHolder, wire, wire.len, c_out, rc);
    CHECK(rc == 0);
    CHECK(c_out.choices._length == 3);
    CHECK(c_out.choices._buffer[0]._d == 0 && c_out.choices._buffer[0]._u.i == 5);
    CHECK(strcmp(c_out.choices._buffer[1]._u.s, "text") == 0);
    ChoiceHolder_free(&c_out);
    CHECK_NO_LIVE();
    CHECK_FAILURE_PATHS(ChoiceHolder, wire);

    PeopleCase p;
    memset(&p, 0, sizeof p);
    p._d = 1;
    p._u.people = borrowed_names(2);
    ENCODE(PeopleCase, p, wire);
    PeopleCase p_out;
    DECODE(PeopleCase, wire, wire.len, p_out, rc);
    CHECK(rc == 0);
    CHECK(p_out._d == 1);
    check_names(&p_out._u.people, 2);
    PeopleCase_free(&p_out);
    CHECK_NO_LIVE();
    CHECK_FAILURE_PATHS(PeopleCase, wire);
}

static void test_union_skip_consumes_the_union(void) {
    /* `_skip` must switch on the discriminant it just read (it used to read
     * into a shadowing local and switch on an uninitialized one). */
    Choice cases[2];
    memset(cases, 0, sizeof cases);
    cases[0]._d = 0;
    cases[0]._u.i = 42;
    cases[1]._d = 1;
    cases[1]._u.s = "skipped text";
    for (int i = 0; i < 2; i++) {
        Wire wire;
        ENCODE(Choice, cases[i], wire);
        ZidlCdrReader r;
        CHECK(zidl_cdr_reader_init(&r, wire.buf, wire.len) == 0);
        CHECK(Choice_skip(&r) == 0);
        CHECK(r.pos == wire.len);
    }
}

static void test_optional_member(void) {
    Wire wire;
    int rc;

    OptionalHolder o;
    memset(&o, 0, sizeof o);
    o._present = 1;
    o.maybe = borrowed_names(2);
    ENCODE(OptionalHolder, o, wire);
    OptionalHolder o_out;
    DECODE(OptionalHolder, wire, wire.len, o_out, rc);
    CHECK(rc == 0);
    CHECK(OptionalHolder_has_maybe(&o_out));
    check_names(&o_out.maybe, 2);
    OptionalHolder_free(&o_out);
    CHECK_NO_LIVE();
    CHECK_FAILURE_PATHS(OptionalHolder, wire);
}

static void test_alias_elements(void) {
    Wire wire;
    int rc;

    Label labels[2] = { "one", "two" };
    PointAlias2 points[2] = { { 1, 2 }, { 3, 4 } };
    ChoiceAlias choices[1];
    memset(choices, 0, sizeof choices);
    choices[0]._d = 1;
    choices[0]._u.s = "aliased";
    ColorAlias colors[2] = { Color_GREEN, Color_BLUE };
    char *more[1] = { "extra" };

    AliasElementHolder a;
    memset(&a, 0, sizeof a);
    a.labels._buffer = labels;
    a.labels._length = a.labels._maximum = 2;
    a.points._buffer = points;
    a.points._length = a.points._maximum = 2;
    a.choices._buffer = choices;
    a.choices._length = a.choices._maximum = 1;
    a.colors._buffer = colors;
    a.colors._length = a.colors._maximum = 2;
    a.more._buffer = more;
    a.more._length = a.more._maximum = 1;
    ENCODE(AliasElementHolder, a, wire);

    AliasElementHolder a_out;
    DECODE(AliasElementHolder, wire, wire.len, a_out, rc);
    CHECK(rc == 0);
    CHECK(a_out.labels._length == 2 && strcmp(a_out.labels._buffer[1], "two") == 0);
    CHECK(a_out.points._length == 2 && a_out.points._buffer[1].y == 4);
    CHECK(a_out.choices._length == 1 && strcmp(a_out.choices._buffer[0]._u.s, "aliased") == 0);
    CHECK(a_out.colors._length == 2 && a_out.colors._buffer[1] == Color_BLUE);
    CHECK(a_out.more._length == 1 && strcmp(a_out.more._buffer[0], "extra") == 0);
    /* The string-sequence typedef's own _free must link and free too. */
    LabelList_free(&a_out.more);
    memset(&a_out.more, 0, sizeof a_out.more);
    AliasElementHolder_free(&a_out);
    CHECK_NO_LIVE();
    CHECK_FAILURE_PATHS(AliasElementHolder, wire);
}

static void test_borrowed_sequence_is_not_freed(void) {
    /* _release == false: _free must touch neither the buffer nor elements. */
    UnboundedHolder u = { borrowed_names(3) };
    UnboundedHolder_free(&u);
    CHECK(strcmp(names3[2].label, "gamma") == 0);
    CHECK_NO_LIVE();
}

int main(void) {
    zidl_cdr_set_allocator(&tracking);
    test_unbounded_and_typedef_holders();
    test_bounded_holders();
    test_union_elements_and_cases();
    test_union_skip_consumes_the_union();
    test_optional_member();
    test_alias_elements();
    test_borrowed_sequence_is_not_freed();
    zidl_cdr_set_allocator(NULL);
    printf("sequence_elements C: all checks passed\n");
    return 0;
}
