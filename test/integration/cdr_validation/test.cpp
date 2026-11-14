// Count STL allocations during rejected decodes. Cap individual allocations
// so a regression with UINT32_MAX stays deterministic instead of exhausting RAM.
#include <cstdlib>
#include <new>
static size_t cpp_allocation_calls;
static bool count_cpp_allocations;
void *operator new(size_t n) {
    if (count_cpp_allocations) {
        ++cpp_allocation_calls;
        if (n > 4096) throw std::bad_alloc();
    }
    if (void *p = std::malloc(n ? n : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, size_t) noexcept { std::free(p); }
#include "test.c"
