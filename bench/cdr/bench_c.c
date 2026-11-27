/* The C side of `zig build bench-cdr`: the same message through the
 * run-time C ABI, and through per-instance exports the library does not
 * build. Neither call is inlined across the language boundary. */
#include <stdint.h>
#include <stddef.h>
#include "zidl_cdr.h"

int bench_x2le_write_u8(void *w, uint8_t v);
int bench_x2le_write_u16(void *w, uint16_t v);
int bench_x2le_write_u32(void *w, uint32_t v);
int bench_x2le_write_u64(void *w, uint64_t v);
int bench_x2le_write_f64(void *w, double v);
int bench_x2le_write_string(void *w, const char *s, uint32_t len);
void bench_x2le_init(void *w, uint8_t *buf, size_t cap);
size_t bench_x2le_len(void *w);
int bench_x2lec_write_u8(void *w, uint8_t v);
int bench_x2lec_write_u16(void *w, uint16_t v);
int bench_x2lec_write_u32(void *w, uint32_t v);
int bench_x2lec_write_u64(void *w, uint64_t v);
int bench_x2lec_write_f64(void *w, double v);
int bench_x2lec_write_string(void *w, const char *s, uint32_t len);
void bench_x2lec_init(void *w);
size_t bench_x2lec_len(void *w);

/* The message once, through either instance's exports: P is the prefix. */
#define SPECIAL_MESSAGE(P, s, seed) do { \
    P##_write_u8(s, (uint8_t)(seed)); \
    P##_write_f64(s, (double)(seed)); \
    P##_write_u16(s, (uint16_t)((seed) >> 3)); \
    P##_write_u64(s, (seed) * 31); \
    P##_write_u32(s, (uint32_t)(int32_t)(seed)); \
    P##_write_u8(s, 7); \
    P##_write_u64(s, (uint64_t)(-(int64_t)((seed) & 0xffff))); \
    P##_write_string(s, "sensor-frame-0042", 17); \
    P##_write_u8(s, ((seed) & 1) == 0); \
    for (uint32_t i = 0; i < 64; i++) P##_write_u32(s, i ^ (uint32_t)(seed)); \
    for (uint32_t i = 0; i < 32; i++) { \
        P##_write_u8(s, (uint8_t)i); \
        P##_write_f64(s, (double)i * 0.5); \
    } \
} while (0)

static void runtime_message(ZidlCdrWriter *w, uint64_t seed) {
    zidl_cdr_write_u8(w, (uint8_t)seed);
    zidl_cdr_write_f64(w, (double)seed);
    zidl_cdr_write_u16(w, (uint16_t)(seed >> 3));
    zidl_cdr_write_u64(w, seed * 31);
    zidl_cdr_write_i32(w, (int32_t)seed);
    zidl_cdr_write_u8(w, 7);
    zidl_cdr_write_i64(w, -(int64_t)(seed & 0xffff));
    zidl_cdr_write_string(w, "sensor-frame-0042", 17);
    zidl_cdr_write_bool(w, (seed & 1) == 0);
    for (uint32_t i = 0; i < 64; i++) zidl_cdr_write_u32(w, i ^ (uint32_t)seed);
    for (uint32_t i = 0; i < 32; i++) {
        zidl_cdr_write_u8(w, (uint8_t)i);
        zidl_cdr_write_f64(w, (double)i * 0.5);
    }
}

size_t bench_c_runtime(uint8_t *buf, size_t cap, uint64_t seed) {
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, buf, cap, ZIDL_XCDR2);
    runtime_message(&w, seed);
    return w.len;
}

size_t bench_c_special(void *s, uint8_t *buf, size_t cap, uint64_t seed) {
    bench_x2le_init(s, buf, cap);
    SPECIAL_MESSAGE(bench_x2le, s, seed);
    return bench_x2le_len(s);
}

size_t bench_c_runtime_count_fixed(uint8_t *buf, size_t cap, uint64_t seed) {
    ZidlCdrWriter w;
    zidl_cdr_writer_init_counting(&w, ZIDL_XCDR2);
    runtime_message(&w, seed);
    if (w.len > cap) return 0;
    zidl_cdr_writer_init_fixed(&w, buf, w.len, ZIDL_XCDR2);
    runtime_message(&w, seed);
    return w.len;
}

size_t bench_c_mixed_count_fixed(void *s, uint8_t *buf, size_t cap, uint64_t seed) {
    ZidlCdrWriter w;
    zidl_cdr_writer_init_counting(&w, ZIDL_XCDR2);
    runtime_message(&w, seed);
    if (w.len > cap) return 0;
    bench_x2le_init(s, buf, w.len);
    SPECIAL_MESSAGE(bench_x2le, s, seed);
    return bench_x2le_len(s);
}

size_t bench_c_special_count_fixed(void *s, uint8_t *buf, size_t cap, uint64_t seed) {
    bench_x2lec_init(s);
    SPECIAL_MESSAGE(bench_x2lec, s, seed);
    size_t len = bench_x2lec_len(s);
    if (len > cap) return 0;
    bench_x2le_init(s, buf, len);
    SPECIAL_MESSAGE(bench_x2le, s, seed);
    return bench_x2le_len(s);
}
