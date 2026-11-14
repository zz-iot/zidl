#ifdef SPLIT
#include "bools_all.h"
#else
#include "bools.h"
#endif
#include <assert.h>
#include <string.h>
#define CHECK(T, EXT, MUTABLE)                                                 \
  do {                                                                         \
    for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {         \
      if (MUTABLE && version == ZIDL_XCDR1)                                    \
        continue;                                                              \
      for (int order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order)             \
        for (int disc = 0; disc < 2; ++disc) {                                 \
          T source = {0};                                                      \
          source._d = disc;                                                    \
          if (disc)                                                            \
            source._u.text = "boolean union value";                            \
          else                                                                 \
            source._u.number = 42;                                             \
          uint8_t bytes[256];                                                  \
          ZidlCdrWriter w;                                                     \
          zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);        \
          zidl_cdr_writer_set_byte_order(&w, order);                           \
          assert(!zidl_cdr_write_encap_kind(&w, EXT) &&                        \
                 !T##_serialize(&w, &source));                                 \
          ZidlCdrWriter count;                                                 \
          zidl_cdr_writer_init_counting(&count, version);                      \
          zidl_cdr_writer_set_byte_order(&count, order);                       \
          assert(!zidl_cdr_write_encap_kind(&count, EXT) &&                    \
                 !T##_serialize(&count, &source) && count.len == w.len);       \
          ZidlCdrReader r;                                                     \
          T out = {0};                                                         \
          assert(!zidl_cdr_reader_init(&r, bytes, w.len) &&                    \
                 !T##_deserialize(&r, &out));                                  \
          assert(out._d == disc && r.pos == w.len);                            \
          if (disc)                                                            \
            assert(!strcmp(out._u.text, source._u.text));                      \
          else                                                                 \
            assert(out._u.number == 42);                                       \
          T##_free(&out);                                                      \
          assert(!zidl_cdr_reader_init(&r, bytes, w.len) && !T##_skip(&r) &&   \
                 r.pos == w.len);                                              \
          for (size_t cut = 4; cut < w.len; ++cut) {                           \
            T partial = {0};                                                   \
            assert(!zidl_cdr_reader_init(&r, bytes, cut));                     \
            assert(T##_deserialize(&r, &partial) != 0);                        \
            T##_free(&partial);                                                \
          }                                                                    \
        }                                                                      \
    }                                                                          \
  } while (0)
int main(void) {
  CHECK(BoolSafety_FinalValue, ZIDL_EXT_FINAL, 0);
  CHECK(BoolSafety_AppendValue, ZIDL_EXT_APPENDABLE, 0);
  CHECK(BoolSafety_MutableValue, ZIDL_EXT_MUTABLE, 1);
  BoolSafety_Exhaustive input = {0};
  input._d = true;
  input._u.other = 7;
  uint8_t bytes[64];
  ZidlCdrWriter w;
  zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, ZIDL_XCDR2);
  assert(!zidl_cdr_write_encap(&w) &&
         !BoolSafety_Exhaustive_serialize(&w, &input));
  BoolSafety_Exhaustive out = {0};
  ZidlCdrReader r;
  assert(!zidl_cdr_reader_init(&r, bytes, w.len) &&
         !BoolSafety_Exhaustive_deserialize(&r, &out) && out._d &&
         out._u.other == 7);
  return 0;
}
