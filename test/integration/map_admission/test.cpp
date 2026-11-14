#include "shapes.hpp"
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <memory_resource>
#include <new>
static long budget = -1;
static size_t live;
static void *alloc(size_t n) {
  if (budget == 0)
    throw std::bad_alloc();
  if (budget > 0)
    --budget;
  void *p = std::malloc(n ? n : 1);
  if (!p)
    throw std::bad_alloc();
  ++live;
  return p;
}
static void release(void *p) {
  if (p) {
    --live;
    std::free(p);
  }
}
void *operator new(size_t n) { return alloc(n); }
void *operator new[](size_t n) { return alloc(n); }
void operator delete(void *p) noexcept { release(p); }
void operator delete[](void *p) noexcept { release(p); }
void operator delete(void *p, size_t) noexcept { release(p); }
void operator delete[](void *p, size_t) noexcept { release(p); }
struct Resource : std::pmr::memory_resource {
  void *do_allocate(size_t n, size_t) override { return alloc(n); }
  void do_deallocate(void *p, size_t, size_t) override { release(p); }
  bool do_is_equal(const std::pmr::memory_resource &o) const noexcept override {
    return this == &o;
  }
};
static const uint8_t bytes[] = {0, 7, 0,   0, 18, 0,   0, 0, 1, 0, 0,
                                0, 2, 0,   0, 0,  'k', 0, 0, 0, 2, 0,
                                0, 0, 'v', 0, 0,  0,   7, 0, 0, 0};
static int run(const uint8_t *p, size_t n) {
  MapAudit::Owned out{};
  ZidlCdrReader r;
  assert(!zidl_cdr_reader_init(&r, p, n));
  int rc = MapAudit_Owned_deserialize(&r, &out);
  if (!rc) {
    assert(out.values.size() == 1 && out.values.begin()->second == "v" &&
           out.tail == 7);
    uint8_t b[128];
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, b, sizeof b, ZIDL_XCDR2);
    assert(!zidl_cdr_write_encap(&w));
    assert(!MapAudit_Owned_serialize(&w, &out));
    assert(w.len == sizeof bytes && !std::memcmp(b, bytes, w.len));
  }
  return rc;
}
static void other() {
  const uint8_t nested[] = {0, 7, 0,   0,  30, 0, 0, 0, 1, 0, 0,   0, 9,
                            0, 0, 0,   18, 0,  0, 0, 1, 0, 0, 0,   2, 0,
                            0, 0, 'k', 0,  0,  0, 2, 0, 0, 0, 'v', 0};
  for (long limit = 0;; ++limit) {
    int rc;
    {
      MapAudit::Nested out{};
      ZidlCdrReader r;
      assert(!zidl_cdr_reader_init(&r, nested, sizeof nested));
      budget = limit;
      rc = MapAudit_Nested_deserialize(&r, &out);
      budget = -1;
      if (!rc) {
        assert(out.values.at(9).at("k") == "v");
        uint8_t b[128];
        ZidlCdrWriter w;
        zidl_cdr_writer_init_fixed(&w, b, sizeof b, ZIDL_XCDR2);
        assert(!zidl_cdr_write_encap(&w) &&
               !MapAudit_Nested_serialize(&w, &out));
        assert(w.len == sizeof nested && !std::memcmp(b, nested, w.len));
      }
    }
    assert(!live);
    if (!rc)
      break;
    assert(rc == ZIDL_CDR_OVERFLOW && limit < 30);
  }
  const uint8_t num[] = {0, 7, 0,  0, 1, 0, 0, 0, 1, 0,
                         0, 0, 42, 0, 0, 0, 7, 0, 0, 0};
  {
    MapAudit::Numeric out{};
    ZidlCdrReader r;
    assert(!zidl_cdr_reader_init(&r, num, sizeof num) &&
           !MapAudit_Numeric_deserialize(&r, &out));
    assert(out.values.at(1) == 42 && out.tail == 7);
    uint8_t b[128];
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, b, sizeof b, ZIDL_XCDR2);
    assert(!zidl_cdr_write_encap(&w) && !MapAudit_Numeric_serialize(&w, &out));
    assert(w.len == sizeof num && !std::memcmp(b, num, w.len));
  }
  uint8_t be[sizeof bytes];
  std::memcpy(be, bytes, sizeof bytes);
  be[1] = 6;
  for (size_t offset : {4, 8, 12, 20, 28}) {
    for (int j = 0; j < 2; j++) {
      uint8_t tmp = be[offset + j];
      be[offset + j] = be[offset + 3 - j];
      be[offset + 3 - j] = tmp;
    }
  }
  {
    MapAudit::Owned out{};
    ZidlCdrReader r;
    assert(!zidl_cdr_reader_init(&r, be, sizeof be) &&
           !MapAudit_Owned_deserialize(&r, &out));
    assert(out.values.at("k") == "v");
  }
}
int main() {
  Resource resource;
  auto *old = std::pmr::set_default_resource(&resource);
  other();
  assert(!live);
  assert(!run(bytes, sizeof bytes));
  assert(!live);
  for (size_t n = 4; n < sizeof bytes; n++) {
    assert(run(bytes, n));
    assert(!live);
  }
  for (long n = 0;; n++) {
    budget = n;
    int rc = run(bytes, sizeof bytes);
    budget = -1;
    assert(!live);
    if (!rc)
      break;
    assert(rc == ZIDL_CDR_OVERFLOW && n < 30);
  }
  uint8_t dup[48];
  std::memcpy(dup, bytes, 12);
  dup[4] = 34;
  dup[8] = 2;
  std::memcpy(dup + 12, bytes + 12, 16);
  std::memcpy(dup + 28, bytes + 12, 16);
  std::memcpy(dup + 44, bytes + 28, 4);
  assert(run(dup, sizeof dup) == ZIDL_CDR_INVALID);
  assert(!live);
  uint8_t huge[sizeof bytes];
  std::memcpy(huge, bytes, sizeof bytes);
  std::memset(huge + 8, 0xff, 4);
  assert(run(huge, sizeof huge) == ZIDL_CDR_INVALID);
  assert(!live);
  std::pmr::set_default_resource(old);
}
