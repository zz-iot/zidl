/* Known-answer checks for the C backend against reference encodings of
 * ka.idl from an independent XTypes implementation (vectors.txt; its path is
 * argv[1]).
 *
 * For each top-level type, in each reference encoding:
 *   - zidl encodes the sample to exactly the reference bytes, including the
 *     representation id the type's extensibility selects (for Mut only the
 *     id: the reference uses EMHEADER length codes 5-7 where zidl writes 4);
 *   - the reference bytes decode to a value that re-encodes to zidl's encoding
 *     of the same sample (the encoder being checked against the reference,
 *     that pins the decode);
 *   - every truncated input fails, and every allocation failure is handled,
 *     with `_free` releasing exactly what was allocated (tracking allocator).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ka.h"

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond);  \
            exit(1);                                                                  \
        }                                                                             \
    } while (0)

/* ── Tracking allocator ─────────────────────────────────────────────────── */

#define MAX_LIVE 4096

static struct { void *p; size_t n; } live[MAX_LIVE];
static size_t live_count;
static long fail_after = -1;

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

/* ── Vectors ────────────────────────────────────────────────────────────── */

static char vectors[1 << 16];

static void load_vectors(const char *path) {
    FILE *f = fopen(path, "rb");
    CHECK(f != NULL);
    size_t n = fread(vectors, 1, sizeof vectors - 1, f);
    fclose(f);
    vectors[n] = 0;
}

/* Decode the hex after "<kind> <name> xcdr<n> " into `out`; returns its length. */
static size_t vector_hex(const char *kind, const char *name, int xcdr, uint8_t *out, size_t cap) {
    char key[64];
    snprintf(key, sizeof key, "%s %s xcdr%d ", kind, name, xcdr);
    const char *line = strstr(vectors, key);
    CHECK(line != NULL);
    const char *hex = line + strlen(key);
    size_t n = 0;
    while (hex[0] && hex[0] != '\n') {
        unsigned b;
        CHECK(sscanf(hex, "%2x", &b) == 1);
        CHECK(n < cap);
        out[n++] = (uint8_t)b;
        hex += 2;
    }
    return n;
}

/* The reference sample: the representation id the reference writes for this
 * type and encoding, then the payload. Returns the total length. */
static size_t vector(const char *name, int xcdr, uint8_t *out, size_t cap) {
    CHECK(vector_hex("encap", name, xcdr, out, cap) == 2);
    out[2] = out[3] = 0x00;
    return 4 + vector_hex("data", name, xcdr, out + 4, cap - 4);
}

/* ── Samples (borrowed storage, _release == false) ──────────────────────── */

#define SEQ(T, arr) ((T){ sizeof(arr) / sizeof((arr)[0]), sizeof(arr) / sizeof((arr)[0]), (arr), false })
#define EMPTY(T) ((T){ 0, 0, NULL, false })

static int32_t p_long[] = {1, -2, 3};
static uint8_t p_octet[] = {1, 2, 3};
static bool p_bool[] = {true, false};
static int64_t p_ll[] = {1, -1};
static double p_dbl[] = {1.5};
static int16_t p_short[] = {7, -8, 9};

static KA_Prims prims(void) {
    KA_Prims v;
    memset(&v, 0, sizeof v);
    v.s_long = SEQ(int32_t_seq, p_long);
    v.s_octet = SEQ(uint8_t_seq, p_octet);
    v.s_bool = SEQ(bool_seq, p_bool);
    v.s_ll = SEQ(int64_t_seq, p_ll);
    v.s_dbl = SEQ(double_seq, p_dbl);
    v.s_short = SEQ(int16_t_seq, p_short);
    v.a_long[0][0] = 1;
    v.a_long[0][1] = 2;
    v.a_long[1][0] = 3;
    v.a_long[1][1] = 4;
    return v;
}

static char *np_str[] = {"a", "bc"};
static char np_bstr[][6] = {"xy", "z"};
static char np_ubstr[][6] = {"uv", "", "w"};
static KA_Color np_enum[] = {KA_Color_GREEN, KA_Color_BLUE};
static KA_Flags np_bm[] = {KA_Flags_F0 | KA_Flags_F2, KA_Flags_F1};
static KA_Named np_struct[] = {{"n1", 1}, {"n2", 2}};
static KA_NamedA np_astruct[] = {{"x"}};
static KA_U np_union[2];
static char *np_tseq[] = {"t"};

static KA_NonPrims non_prims(void) {
    np_union[0]._d = 1;
    np_union[0]._u.i = 7;
    np_union[1]._d = 2;
    np_union[1]._u.s = "u";
    KA_NonPrims v;
    memset(&v, 0, sizeof v);
    v.s_str = SEQ(string_seq, np_str);
    v.s_bstr = SEQ(string5_seq, np_bstr);
    v.s_ubstr = SEQ(string5_seq, np_ubstr);
    v.s_enum = SEQ(KA_Color_seq, np_enum);
    v.s_bm = SEQ(KA_Flags_seq, np_bm);
    v.s_struct = SEQ(KA_Named_seq, np_struct);
    v.s_astruct = SEQ(KA_NamedA_seq, np_astruct);
    v.s_union = SEQ(KA_U_seq, np_union);
    v.t_seq = SEQ(KA_StrSeq, np_tseq);
    return v;
}

static int32_t n_r0[] = {1, 2}, n_r1[] = {3};
static int32_t_seq n_seq[2];
static int32_t n_t0[] = {4};
static KA_LongSeq n_tseq[2];
static char *n_s0[] = {"a"}, *n_s1[] = {"b", "c"};
static string_seq n_seq_str[2];
static KA_Named n_st0[] = {{"q", 1}};
static KA_Named_seq n_seq_struct[1];
static KA_Triple n_arr[] = {{1, 2, 3}, {4, 5, 6}};
static KA_Triple n_barr[] = {{7, 8, 9}};

static KA_Nested nested(void) {
    n_seq[0] = SEQ(int32_t_seq, n_r0);
    n_seq[1] = SEQ(int32_t_seq, n_r1);
    n_tseq[0] = SEQ(KA_LongSeq, n_t0);
    n_tseq[1] = EMPTY(KA_LongSeq);
    n_seq_str[0] = SEQ(string_seq, n_s0);
    n_seq_str[1] = SEQ(string_seq, n_s1);
    n_seq_struct[0] = SEQ(KA_Named_seq, n_st0);
    KA_Nested v;
    memset(&v, 0, sizeof v);
    v.s_seq = SEQ(int32_t_seq_seq, n_seq);
    v.s_tseq = SEQ(KA_LongSeq_seq, n_tseq);
    v.s_seq_str = SEQ(string_seq_seq, n_seq_str);
    v.s_seq_struct = SEQ(KA_Named_seq_seq, n_seq_struct);
    v.s_arr = SEQ(KA_Triple_seq, n_arr);
    v.s_barr = SEQ(KA_Triple_seq, n_barr);
    return v;
}

static int32_t a_s0[] = {1}, a_s1[] = {2, 3};

static KA_Arrays arrays(void) {
    KA_Arrays v;
    memset(&v, 0, sizeof v);
    v.a_str[0] = "p";
    v.a_str[1] = "q";
    v.a_enum[0] = KA_Color_BLUE;
    v.a_enum[1] = KA_Color_RED;
    v.a_struct[0] = (KA_Named){"s1", 1};
    v.a_struct[1] = (KA_Named){"s2", 2};
    v.a_str2[0][0] = "w";
    v.a_str2[0][1] = "x";
    v.a_str2[1][0] = "y";
    v.a_str2[1][1] = "z";
    for (int i = 0; i < 2; i++)
        for (int j = 0; j < 3; j++) v.a_tarr[i][j] = i * 3 + j + 1;
    v.a_seq[0] = SEQ(KA_LongSeq, a_s0);
    v.a_seq[1] = SEQ(KA_LongSeq, a_s1);
    return v;
}

static KA_Named app_extra[] = {{"e", 5}};

static KA_App app(void) {
    KA_App v;
    memset(&v, 0, sizeof v);
    v.np = non_prims();
    v.extra = SEQ(KA_Named_seq, app_extra);
    return v;
}

static char *m_str[] = {"m"};
static int32_t m_long[] = {1, 2};
static uint8_t m_octet[] = {9};
static int64_t m_ll[] = {5};
static int16_t m_short[] = {3};
static KA_Named m_struct[] = {{"k", 4}};

static KA_Mut mut(void) {
    KA_Mut v;
    memset(&v, 0, sizeof v);
    v.s_str = SEQ(string_seq, m_str);
    v.s_long = SEQ(int32_t_seq, m_long);
    v.s_octet = SEQ(uint8_t_seq, m_octet);
    v.s_ll = SEQ(int64_t_seq, m_ll);
    v.s_short = SEQ(int16_t_seq, m_short);
    v.s_struct = SEQ(KA_Named_seq, m_struct);
    v.name = "nm";
    v.a_long[0] = 6;
    v.a_long[1] = 7;
    v.a_struct[0] = (KA_Named){"a", 1};
    v.a_struct[1] = (KA_Named){"b", 2};
    v.nest = nested();
    return v;
}

/* ── Checks ─────────────────────────────────────────────────────────────── */

typedef struct {
    uint8_t buf[2048];
    size_t len; /* including the encapsulation header */
} Bytes;

/* `ext` is the type's ZIDL_EXT_* extensibility (as annotated in ka.idl): it
 * selects the XCDR2 representation id. */
#define ENCODE(T, value, xcdr, ext, out)                                              \
    do {                                                                              \
        ZidlCdrWriter w_;                                                             \
        zidl_cdr_writer_init_fixed(&w_, (out).buf, sizeof (out).buf,                  \
                                   (xcdr) == 1 ? ZIDL_XCDR1 : ZIDL_XCDR2);            \
        CHECK(zidl_cdr_write_encap_kind(&w_, (ext)) == 0);                            \
        CHECK(T##_serialize(&w_, &(value)) == 0);                                     \
        (out).len = w_.pos + 4;                                                       \
    } while (0)

#define DECODE(T, bytes, len, out, rc)                                                \
    do {                                                                              \
        ZidlCdrReader r_;                                                             \
        memset(&(out), 0, sizeof(out));                                               \
        if (zidl_cdr_reader_init(&r_, (bytes), (len)) != 0) {                        \
            (rc) = -1;                                                                \
        } else {                                                                      \
            (rc) = T##_deserialize(&r_, &(out));                                      \
            if ((rc) == 0 && r_.pos != (len)) (rc) = -2; /* trailing bytes */         \
        }                                                                             \
    } while (0)

#define CHECK_TYPE(T, name, ext, sample_expr, xcdr, compare_bytes)                    \
    do {                                                                              \
        T sample_ = (sample_expr);                                                    \
        static Bytes reference_, ours_, again_;                                         \
        reference_.len = vector(name, xcdr, reference_.buf, sizeof reference_.buf);         \
        ENCODE(T, sample_, xcdr, ext, ours_);                                         \
        /* Representation id always; the payload too, except for Mut. */             \
        CHECK(memcmp(ours_.buf, reference_.buf, 4) == 0);                             \
        if (compare_bytes) {                                                          \
            CHECK(ours_.len == reference_.len);                                       \
            CHECK(memcmp(ours_.buf, reference_.buf, ours_.len) == 0);                 \
        }                                                                             \
        T got_;                                                                       \
        int rc_;                                                                      \
        DECODE(T, reference_.buf, reference_.len, got_, rc_);                             \
        CHECK(rc_ == 0);                                                              \
        ENCODE(T, got_, xcdr, ext, again_);                                           \
        CHECK(again_.len == ours_.len && memcmp(again_.buf, ours_.buf, ours_.len) == 0); \
        T##_free(&got_);                                                              \
        CHECK(live_count == 0);                                                       \
        for (size_t cut_ = 0; cut_ < reference_.len; cut_++) {                          \
            DECODE(T, reference_.buf, cut_, got_, rc_);                                 \
            CHECK(rc_ != 0);                                                          \
            T##_free(&got_);                                                          \
            CHECK(live_count == 0);                                                   \
        }                                                                             \
        for (long k_ = 0;; k_++) {                                                    \
            fail_after = k_;                                                          \
            DECODE(T, reference_.buf, reference_.len, got_, rc_);                         \
            fail_after = -1;                                                          \
            T##_free(&got_);                                                          \
            CHECK(live_count == 0);                                                   \
            if (rc_ == 0) break;                                                      \
            CHECK(k_ < 10000);                                                        \
        }                                                                             \
        printf("  %-9s xcdr%d ok\n", name, xcdr);                                     \
    } while (0)

int main(int argc, char **argv) {
    CHECK(argc == 2);
    load_vectors(argv[1]);
    zidl_cdr_set_allocator(&tracking);
    for (int xcdr = 1; xcdr <= 2; xcdr++) {
        CHECK_TYPE(KA_Prims, "Prims", ZIDL_EXT_FINAL, prims(), xcdr, 1);
        CHECK_TYPE(KA_NonPrims, "NonPrims", ZIDL_EXT_FINAL, non_prims(), xcdr, 1);
        CHECK_TYPE(KA_Nested, "Nested", ZIDL_EXT_FINAL, nested(), xcdr, 1);
        CHECK_TYPE(KA_Arrays, "Arrays", ZIDL_EXT_FINAL, arrays(), xcdr, 1);
        CHECK_TYPE(KA_App, "App", ZIDL_EXT_APPENDABLE, app(), xcdr, 1);
    }
    CHECK_TYPE(KA_Mut, "Mut", ZIDL_EXT_MUTABLE, mut(), 2, 0);
    zidl_cdr_set_allocator(NULL);
    printf("xcdr_known_answer C: all checks passed\n");
    return 0;
}
