#ifdef SPLIT
#include "Second_Nested_Packet.hpp"
#include "shapes_all.hpp"
#else
#include "shapes.hpp"
#endif
#include <cassert>
#include <type_traits>
#include <utility>
static_assert(std::is_same<First::Tag, First::Kind>::value, "qualified alias");
static_assert(std::is_same<Second::Nested::Alias, First::Nested::Packet>::value,
              "cross-module alias");
static_assert(!std::is_same<First::Nested::Data, Second::Nested::Data>::value,
              "distinct modules");
extern "C" int Second_Nested_Packet_deserialize(ZidlCdrReader *,
                                                Second::Nested::Packet *);
int main() {
  for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version)
    for (int order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order) {
      Second::Nested::Data data{};
      data.original.text = "cross module";
      data.root_value.value = 42;
      data.tag = Second::Nested::Kind::One;
      uint8_t bytes[2048];
      ZidlCdrWriter w;
      zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);
      zidl_cdr_writer_set_byte_order(&w, order);
      assert(!zidl_cdr_write_encap(&w) &&
             !Second_Nested_Data_serialize(&w, &data));
      Second::Nested::Data decoded{};
      ZidlCdrReader r;
      assert(!zidl_cdr_reader_init(&r, bytes, w.len) &&
             !Second_Nested_Data_deserialize(&r, &decoded));
      assert(decoded.original.text == data.original.text &&
             decoded.root_value.value == 42 && decoded.tag == data.tag);
    }
  for (int order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order)
    for (int arm = 0; arm < 2; ++arm) {
      Second::Nested::Packet source{};
      source.incoming.choice._d(arm ? First::Kind::One : First::Kind::Zero);
      if (arm) {
        First::Nested::Data record{};
        record.text = "owning record";
        source.incoming.choice.record(record);
      } else
        source.incoming.choice.text("owning text");
      First::Nested::Data row{};
      row.text = "row";
      source.incoming.entries.push_back(row);
      source.other.original.text = "other";
      source.other.root_value.value = 7;
      Second::Nested::Packet copy = source;
      Second::Nested::Packet moved = std::move(copy);
      uint8_t bytes[2048];
      ZidlCdrWriter w;
      zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, ZIDL_XCDR2);
      zidl_cdr_writer_set_byte_order(&w, order);
      assert(!zidl_cdr_write_encap(&w) &&
             !Second_Nested_Packet_serialize(&w, &moved));
      Second::Nested::Packet out{};
      ZidlCdrReader r;
      assert(!zidl_cdr_reader_init(&r, bytes, w.len) &&
             !Second_Nested_Packet_deserialize(&r, &out));
      assert(out.incoming.entries.size() == 1 &&
             out.incoming.entries[0].text == "row" && out.other.root_value.value == 7);
      if (arm)
        assert(out.incoming.choice.record().text == "owning record");
      else
        assert(out.incoming.choice.text() == "owning text");
    }
}
