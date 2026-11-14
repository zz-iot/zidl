#include <cassert>
#include <cstddef>
#include <cstdlib>
#include <memory_resource>
#include <new>
#include <stdexcept>
static size_t live;
static long budget = -1;
static bool synth_lengths;
static void *allocate(size_t n) {
  if (budget == 0) {
    budget = -1; // Let construction of the injected exception allocate.
    if (synth_lengths)
      throw std::length_error("injected");
    throw std::bad_alloc();
  }
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
    assert(live);
    --live;
    std::free(p);
  }
}
void *operator new(size_t n) { return allocate(n); }
void *operator new[](size_t n) { return allocate(n); }
void operator delete(void *p) noexcept { release(p); }
void operator delete[](void *p) noexcept { release(p); }
void operator delete(void *p, size_t) noexcept { release(p); }
void operator delete[](void *p, size_t) noexcept { release(p); }
struct Resource : std::pmr::memory_resource {
  void *do_allocate(size_t n, size_t) override { return ::allocate(n); }
  void do_deallocate(void *p, size_t, size_t) override { ::release(p); }
  bool do_is_equal(const std::pmr::memory_resource &o) const noexcept override {
    return this == &o;
  }
};
#define main run_suite
#include "test.c"
#undef main
int main() {
  assert(run_suite() == 0);
  synth_lengths = true;
  assert(run_suite() == 0);
}
