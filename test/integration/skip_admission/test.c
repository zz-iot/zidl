#include <assert.h>
#include <string.h>
#ifdef __cplusplus
#include "shapes.hpp"
#define TYPE(name) Traversal::name
#define INIT                                                                   \
  {                                                                            \
  }
#else
#include "shapes.h"
#define TYPE(name) Traversal_##name
#define INIT {0}
#endif
static const uint8_t missing_disc[] = {0, 7, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0};
static const uint8_t unknown_mu[] = {0, 7, 0,  0, 7, 0,    0,  0, 8, 0,
                                     0, 0, 50, 0, 0, 0xa0, 42, 0, 0, 0};
static const uint8_t valid[] = {0, 7, 0, 0, 7, 0,    0,  0, 8, 0,
                                0, 0, 1, 0, 0, 0x20, 42, 0, 0, 0};
#define CHECK(NAME, BYTES)                                                     \
  do {                                                                         \
    ZidlCdrReader r;                                                           \
    TYPE(NAME) out = INIT;                                                     \
    assert(!zidl_cdr_reader_init(&r, BYTES, sizeof BYTES) &&                   \
           !Traversal_##NAME##_skip(&r) && r.pos == sizeof BYTES);             \
    assert(!zidl_cdr_reader_init(&r, BYTES, sizeof BYTES) &&                   \
           Traversal_##NAME##_deserialize(&r, &out) != 0);                     \
    uint8_t hash[16];                                                          \
    memset(hash, 0xa5, sizeof hash);                                           \
    assert(Traversal_##NAME##_compute_key_hash_from_cdr(BYTES, sizeof BYTES,   \
                                                        hash) != 0);           \
    for (size_t i = 0; i < sizeof hash; ++i)                                   \
      assert(hash[i] == 0xa5);                                                 \
    for (size_t cut = 4; cut < sizeof BYTES; ++cut) {                          \
      assert(!zidl_cdr_reader_init(&r, BYTES, cut) &&                          \
             Traversal_##NAME##_skip(&r) != 0 && r.pos <= cut);                \
    }                                                                          \
  } while (0)
static const uint8_t bad_map[] = {0, 7, 0, 0, 12, 0, 0, 0, 1, 0,
                                  0, 0, 7, 0, 0,  0, 0, 0, 0, 0};
int main(void) {
  TYPE(MapTopic) map_value = INIT;
  ZidlCdrReader map_reader;
  assert(!zidl_cdr_reader_init(&map_reader, bad_map, sizeof bad_map) &&
         !Traversal_MapTopic_skip(&map_reader));
  assert(!zidl_cdr_reader_init(&map_reader, bad_map, sizeof bad_map) &&
         Traversal_MapTopic_deserialize(&map_reader, &map_value) != 0);
#ifndef __cplusplus
  Traversal_MapTopic_free(&map_value);
#endif
  CHECK(UnionTopic, missing_disc);
  CHECK(StructTopic, unknown_mu);
  TYPE(StructTopic) out = INIT;
  ZidlCdrReader r;
  assert(!zidl_cdr_reader_init(&r, valid, sizeof valid) &&
         !Traversal_StructTopic_deserialize(&r, &out));
  uint8_t hash[16];
  assert(!Traversal_StructTopic_compute_key_hash_from_cdr(valid, sizeof valid,
                                                          hash));
  assert(hash[0] == 0 && hash[1] == 0 && hash[2] == 0 && hash[3] == 7);
  return 0;
}
