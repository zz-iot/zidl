#ifdef SPLIT
#include "bools_all.hpp"
#else
#include "bools.hpp"
#endif
#include <cassert>
#include <cstring>
#include <utility>
template <class T>
void check(int ext, bool is_mutable, int (*write)(ZidlCdrWriter *, const T *),
           int (*read)(ZidlCdrReader *, T *), int (*skip)(ZidlCdrReader *)) {
  for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
    if (is_mutable && version == ZIDL_XCDR1)
      continue;
    for (int order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order)
      for (bool disc : {false, true}) {
        T source{};
        source._d(disc);
        if (disc)
          source.text("boolean union value");
        else
          source.number(42);
        T copy(source);
        T moved(std::move(copy));
        T assigned{};
        assigned = moved;
        copy = std::move(assigned);
        assert(copy._d() == disc);
        if (disc)
          assert(copy.text() == source.text());
        else
          assert(copy.number() == 42);
        copy._d(!disc);
        copy._d(disc);
        if (disc)
          copy.text(source.text());
        else
          copy.number(source.number());
        uint8_t bytes[256];
        ZidlCdrWriter w;
        zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);
        zidl_cdr_writer_set_byte_order(&w, order);
        assert(!zidl_cdr_write_encap_kind(&w, ext) && !write(&w, &copy));
        ZidlCdrWriter count;
        zidl_cdr_writer_init_counting(&count, version);
        zidl_cdr_writer_set_byte_order(&count, order);
        assert(!zidl_cdr_write_encap_kind(&count, ext) &&
               !write(&count, &copy) && count.len == w.len);
        ZidlCdrReader r;
        T out{};
        assert(!zidl_cdr_reader_init(&r, bytes, w.len) && !read(&r, &out) &&
               r.pos == w.len && out._d() == disc);
        if (disc)
          assert(out.text() == source.text());
        else
          assert(out.number() == 42);
        assert(!zidl_cdr_reader_init(&r, bytes, w.len) && !skip(&r) &&
               r.pos == w.len);
        for (size_t cut = 4; cut < w.len; ++cut) {
          T partial{};
          assert(!zidl_cdr_reader_init(&r, bytes, cut) &&
                 read(&r, &partial) != 0);
        }
      }
  }
}
int main() {
  check<BoolSafety_FinalValue>(
      ZIDL_EXT_FINAL, false, BoolSafety_FinalValue_serialize,
      BoolSafety_FinalValue_deserialize, BoolSafety_FinalValue_skip);
  check<BoolSafety_AppendValue>(
      ZIDL_EXT_APPENDABLE, false, BoolSafety_AppendValue_serialize,
      BoolSafety_AppendValue_deserialize, BoolSafety_AppendValue_skip);
  check<BoolSafety_MutableValue>(
      ZIDL_EXT_MUTABLE, true, BoolSafety_MutableValue_serialize,
      BoolSafety_MutableValue_deserialize, BoolSafety_MutableValue_skip);
  BoolSafety_Exhaustive input{};
  input._d(true);
  input.other(7);
  uint8_t bytes[64];
  ZidlCdrWriter w;
  zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, ZIDL_XCDR2);
  assert(!zidl_cdr_write_encap(&w) &&
         !BoolSafety_Exhaustive_serialize(&w, &input));
  BoolSafety_Exhaustive out{};
  ZidlCdrReader r;
  assert(!zidl_cdr_reader_init(&r, bytes, w.len) &&
         !BoolSafety_Exhaustive_deserialize(&r, &out) && out._d() &&
         out.other() == 7);
}
