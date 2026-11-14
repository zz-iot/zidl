#include <assert.h>
#include <string.h>
#include <stdlib.h>
#ifdef __cplusplus
extern "C" {
#endif
#include "types.h"
#ifdef __cplusplus
}
#endif
#ifdef Bounded_Optional_set_text
#error array aliases must not have scalar setters
#endif
#ifdef Bounded_Optional_set_wide
#error wide array aliases must not have scalar setters
#endif
#ifdef Bounded_Optional_set_rows
#error array typedefs must not have scalar setters
#endif
#define MAX_LIVE 1024

static struct { void *p; size_t n; } live[MAX_LIVE];
static size_t live_count;
static long fail_after = -1; /* allocations left before failing; -1 = never */

static void *t_alloc(void *ctx, size_t n, size_t align) {
    (void)ctx;
    (void)align;
    if (fail_after == 0) return NULL;
    if (fail_after > 0) fail_after--;
    assert(live_count < MAX_LIVE);
    void *p = malloc(n ? n : 1);
    assert(p != NULL);
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
            assert(live[i].n == n);
            live[i] = live[--live_count];
            free(p);
            return;
        }
    }
    assert(!"free of a pointer that is not a live allocation");
}

static const ZidlAllocator tracking = { NULL, t_alloc, t_resize, t_free };


int main(void) {
    zidl_cdr_set_allocator(&tracking);
    Bounded_Defaults defaults;
    Bounded_Defaults_default(&defaults);
    assert(!strcmp(defaults.text, "ABCD") && !strcmp(defaults.other, "WXYZ"));
    assert(defaults.wide[0]==0xd83d && defaults.wide[1]==0xde00 && defaults.wide[2]==0);
    Bounded_Sample value;
    Bounded_Alias texts[2] = { "ABCD", "WXYZ" };
    Bounded_WideAlias wides[2] = { {0x1234, 0x4567, 0}, {0x789a, 0x1234, 0} };
    memset(&value, 0, sizeof value);
    assert(sizeof value.text == 5 && sizeof value.wide == 6);
    assert(sizeof value.cells == 20 && sizeof value.wides == 12);
    strcpy(value.selected._u.text, "WXYZ");
    strcpy(value.text, "ABCD");
    memcpy(value.wide, wides[0], sizeof value.wide);
    for (int i=0; i<2; i++) {
        memcpy(value.wides[i], wides[i], sizeof wides[i]);
        for (int j=0; j<2; j++) strcpy(value.cells[i][j], texts[j]);
    }
    value.texts._buffer=texts; value.texts._length=2; value.texts._maximum=2;
    value.wideTexts._buffer=wides; value.wideTexts._length=2; value.wideTexts._maximum=2;
    for (int version=ZIDL_XCDR1; version<=ZIDL_XCDR2; version++) {
        for (int order=ZIDL_CDR_LE; order<=ZIDL_CDR_BE; order++) {
            uint8_t bytes[512];
            ZidlCdrWriter w;
            zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);
            zidl_cdr_writer_set_byte_order(&w, order);
            assert(zidl_cdr_write_encap(&w)==0);
            assert(Bounded_Sample_serialize(&w, &value)==0);
            for (size_t n=4; n<=w.len; n++) {
                Bounded_Sample decoded;
                ZidlCdrReader r;
                memset(&decoded, 0, sizeof decoded);
                assert(zidl_cdr_reader_init(&r, bytes, n)==0);
                int rc=Bounded_Sample_deserialize(&r, &decoded);
                if (n<w.len) assert(rc!=0);
                else {
                    assert(rc==0 && r.pos==n);
                    assert(!strcmp(decoded.selected._u.text, "WXYZ"));
                    assert(!memcmp(value.text, decoded.text, sizeof value.text));
                    assert(!memcmp(value.wide, decoded.wide, sizeof value.wide));
                    assert(!memcmp(value.cells, decoded.cells, sizeof value.cells));
                    assert(!memcmp(value.wides, decoded.wides, sizeof value.wides));
                    assert(decoded.texts._length==2 && decoded.wideTexts._length==2);
                    assert(!memcmp(texts, decoded.texts._buffer, sizeof texts));
                    assert(!memcmp(wides, decoded.wideTexts._buffer, sizeof wides));
                }
                Bounded_Sample_free(&decoded);
                assert(live_count==0);
            }
            /* Fail each allocation, including temporary wide-string storage,
             * until a decode succeeds. Every partial result remains freeable. */
            for (long budget=0; ; budget++) {
                Bounded_Sample decoded;
                ZidlCdrReader r;
                memset(&decoded, 0, sizeof decoded);
                fail_after=budget;
                assert(zidl_cdr_reader_init(&r, bytes, w.len)==0);
                int rc=Bounded_Sample_deserialize(&r, &decoded);
                assert(r.pos<=w.len);
                Bounded_Sample_free(&decoded);
                assert(live_count==0);
                fail_after=-1;
                if (rc==0) break;
                assert(budget<32);
            }
        }
    }
    zidl_cdr_set_allocator(NULL);
    return 0;
}
