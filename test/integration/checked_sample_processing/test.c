#include <assert.h>
#include <stdlib.h>
#include <string.h>
#ifdef __cplusplus
#include "shapes.hpp"
#else
#include "shapes.h"
static size_t live;
static long budget = -1;
static void *allocate(size_t n) {
  if (budget == 0)
    return NULL;
  if (budget > 0)
    --budget;
  void *p = malloc(n ? n : 1);
  if (p)
    ++live;
  return p;
}
static void release(void *p) {
  if (p) {
    assert(live);
    --live;
    free(p);
  }
}
#endif
static void *c_allocate(void *c, size_t n, size_t a) {
  (void)c;
  (void)a;
#ifdef __cplusplus
  try {
    return allocate(n);
  } catch (const std::bad_alloc &) {
    return NULL;
  } catch (const std::length_error &) {
    return NULL;
  }
#else
  return allocate(n);
#endif
}
static bool c_resize(void *c, void *p, size_t old, size_t n, size_t a) {
  (void)c;
  (void)p;
  (void)old;
  (void)n;
  (void)a;
  return false;
}
static void c_release(void *c, void *p, size_t n, size_t a) {
  (void)c;
  (void)n;
  (void)a;
  release(p);
}
static void word(uint8_t *p, unsigned n, int le) {
  for (int i = 0; i < 4; i++)
    p[i] = (uint8_t)(n >> (8 * (le ? i : 3 - i)));
}
typedef int (*Process)(const uint8_t *, size_t, int, uint8_t *);
static int run(Process process, const uint8_t *bytes, size_t n, int key_only,
               int expected) {
  uint8_t hash[16];
  memset(hash, 0xa5, sizeof hash);
  int rc = process(bytes, n, key_only, hash);
  if (expected != -99)
    assert(rc == expected);
  for (size_t i = 0; i < sizeof hash; i++)
    assert(hash[i] == (rc ? 0xa5 : 0));
  assert(live == 0);
  return rc;
}
int main(void) {
#ifdef __cplusplus
  Resource resource;
  auto *prior = std::pmr::set_default_resource(&resource);
#endif
  ZidlAllocator a = {NULL, c_allocate, c_resize, c_release};
  zidl_cdr_set_allocator(&a);
  for (int version = 1; version <= 2; version++)
    for (int le = 0; le < 2; le++) {
      /* Keyless appendable lifecycle data has an empty XCDR2 DHEADER. */
      uint8_t lifecycle[32];
      ZidlCdrWriter lifecycle_writer;
      zidl_cdr_writer_init_fixed(&lifecycle_writer, lifecycle, sizeof lifecycle, version);
      zidl_cdr_writer_set_byte_order(&lifecycle_writer, le ? ZIDL_CDR_LE : ZIDL_CDR_BE);
      assert(zidl_cdr_write_encap_kind(&lifecycle_writer, ZIDL_EXT_APPENDABLE) == 0);
      size_t key_header;
      assert(zidl_cdr_reserve_dheader_maybe(&lifecycle_writer, &key_header) == 0);
      if (key_header != (size_t)-1) assert(zidl_cdr_patch_dheader_checked(&lifecycle_writer, key_header) == 0);
      run(Processing_KeylessAppendable_process_sample_from_cdr, lifecycle, lifecycle_writer.len, 1, 0);
      if (version == ZIDL_XCDR2) {
        for (size_t cut = 4; cut < lifecycle_writer.len; ++cut)
          assert(run(Processing_KeylessAppendable_process_sample_from_cdr, lifecycle, cut, 1, -99) != 0);
        assert(zidl_cdr_write_i32(&lifecycle_writer, 7) == 0);
        assert(zidl_cdr_patch_dheader_checked(&lifecycle_writer, key_header) == 0);
        run(Processing_KeylessAppendable_process_sample_from_cdr, lifecycle, lifecycle_writer.len, 1, ZIDL_CDR_INVALID);
      }
#ifdef __cplusplus
      Processing::KeylessAppendable ordinary{};
#else
      Processing_KeylessAppendable ordinary = {0};
#endif
      ordinary.number = 7;
      zidl_cdr_writer_init_fixed(&lifecycle_writer, lifecycle, sizeof lifecycle, version);
      zidl_cdr_writer_set_byte_order(&lifecycle_writer, le ? ZIDL_CDR_LE : ZIDL_CDR_BE);
      assert(zidl_cdr_write_encap_kind(&lifecycle_writer, ZIDL_EXT_APPENDABLE) == 0);
      assert(Processing_KeylessAppendable_serialize(&lifecycle_writer, &ordinary) == 0);
      run(Processing_KeylessAppendable_process_sample_from_cdr, lifecycle, lifecycle_writer.len, 0, 0);
      if (version == ZIDL_XCDR1) {
        const uint8_t unsupported_mutable[8] = {0, (uint8_t)(le ? 1 : 0), 0, 0, 0, 0, 0, 0};
        for (int key_only = 0; key_only < 2; ++key_only) {
          run(Processing_Evolving_process_sample_from_cdr, unsupported_mutable, 4, key_only, ZIDL_CDR_INVALID);
          run(Processing_Evolving_process_sample_from_cdr, unsupported_mutable, 8, key_only, ZIDL_CDR_INVALID);
        }
      }
      uint8_t bytes[128] = {0};
      bytes[1] = (uint8_t)(version == 2 ? (le ? 7 : 6) : (le ? 1 : 0));
      word(bytes + 4, 0, le);
      word(bytes + 8, 65, le);
      memset(bytes + 12, 'x', 64);
      bytes[76] = 0;
      run(Processing_Owned_process_sample_from_cdr, bytes, 77, 0, 0);
      for (size_t cut = 4; cut < 77; cut++)
        assert(run(Processing_Owned_process_sample_from_cdr, bytes, cut, 0,
                   -99) != 0);
      for (long limit = 0;; limit++) {
        budget = limit;
        int rc =
            run(Processing_Owned_process_sample_from_cdr, bytes, 77, 0, -99);
        budget = -1;
        if (!rc)
          break;
        assert(rc == ZIDL_CDR_OVERFLOW && limit < 32);
      }
      run(Processing_Owned_process_sample_from_cdr, bytes, 80, 0, 0);
      bytes[79] = 1;
      run(Processing_Owned_process_sample_from_cdr, bytes, 80, 0,
          ZIDL_CDR_INVALID);
      bytes[79] = 0;
      run(Processing_Owned_process_sample_from_cdr, bytes, 8, 1, 0);
      assert(run(Processing_Owned_process_sample_from_cdr, bytes, 8, 0, -99) !=
             0);
      run(Processing_Owned_process_sample_from_cdr, bytes, 77, -1,
          ZIDL_CDR_INVALID);
      uint8_t nonzero[16];
      word(bytes + 4, 7, le);
      assert(Processing_Owned_process_sample_from_cdr(bytes, 77, 0, nonzero) ==
             0);
      assert(nonzero[0] == 0 && nonzero[1] == 0 && nonzero[2] == 0 &&
             nonzero[3] == 7);
      for (size_t i = 4; i < 16; i++)
        assert(nonzero[i] == 0);
      assert(live == 0);
      word(bytes + 4, 0, le);
      uint8_t keyless[128] = {0};
      memcpy(keyless, bytes, 4);
      memcpy(keyless + 4, bytes + 8, 69);
      run(Processing_Keyless_process_sample_from_cdr, keyless, 73, 0, 0);
      assert(run(Processing_Keyless_process_sample_from_cdr, keyless, 4, 0,
                 -99) != 0);
      run(Processing_Keyless_process_sample_from_cdr, keyless, 4, 1, 0);
      for (long limit = 0;; limit++) {
        budget = limit;
        int rc = run(Processing_Keyless_process_sample_from_cdr, keyless, 73, 0,
                     -99);
        budget = -1;
        if (!rc)
          break;
        assert(rc == ZIDL_CDR_OVERFLOW && limit < 32);
      }
    }
  const uint8_t evolving[] = {0, 11, 0, 0, 0, 0, 0, 0};
  run(Processing_Evolving_process_sample_from_cdr, evolving, sizeof evolving, 0,
      0);
  zidl_cdr_set_allocator(NULL);
#ifdef __cplusplus
  std::pmr::set_default_resource(prior);
#endif
  return 0;
}
