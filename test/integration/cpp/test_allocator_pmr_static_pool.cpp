// Integration test for zidl_allocator_pmr.hpp's opt-in
// ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE mode (bare-metal / no-heap targets).
// Compiled and run by `zig build integration-test`.
//
// Overrides global operator new/delete to abort, proving that with the
// static-pool macro defined, setCppAllocator's own bookkeeping never touches
// the heap -- the one spot in the header not already routed through a
// caller-supplied ZidlAllocator (factory bootstrap and
// _getOrCreate/wrapFactoryHandle both already are).
#define ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE 4
#include "zidl_allocator_pmr.hpp"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <memory>

void* operator new(std::size_t) {
    std::fprintf(stderr, "FAIL: global operator new was called in static-pool mode\n");
    std::abort();
}
void operator delete(void*) noexcept {
    std::fprintf(stderr, "FAIL: global operator delete was called in static-pool mode\n");
    std::abort();
}
void operator delete(void*, std::size_t) noexcept {
    std::fprintf(stderr, "FAIL: global operator delete(sized) was called in static-pool mode\n");
    std::abort();
}

struct Widget {
    int x;
    explicit Widget(int v) : x(v) {}
};

int main() {
    static size_t alloc_calls = 0;
    static size_t free_calls = 0;
    struct Fns {
        static void* alloc(void*, size_t len, size_t) { alloc_calls++; return std::malloc(len); }
        static bool resize(void*, void*, size_t, size_t, size_t) { return false; }
        static void free_(void*, void* p, size_t, size_t) { free_calls++; std::free(p); }
    };
    ZidlAllocator za{nullptr, Fns::alloc, Fns::resize, Fns::free_};

    // setCppAllocator's own bookkeeping must not call global operator new.
    zidl::setCppAllocator(&za);
    {
        auto sp = std::allocate_shared<Widget>(
            std::pmr::polymorphic_allocator<Widget>(std::pmr::get_default_resource()), 7);
        assert(sp->x == 7);
        assert(alloc_calls == 1);
    }
    assert(free_calls == 1);

    // Re-registering (within the pool bound) must also avoid global new.
    ZidlAllocator zb{nullptr, Fns::alloc, Fns::resize, Fns::free_};
    zidl::setCppAllocator(&zb);
    {
        auto sp = std::allocate_shared<Widget>(
            std::pmr::polymorphic_allocator<Widget>(std::pmr::get_default_resource()), 8);
        assert(sp->x == 8);
        assert(alloc_calls == 2);
    }
    assert(free_calls == 2);

    zidl::setCppAllocator(nullptr);

    std::printf("test_allocator_pmr_static_pool: OK\n");
    return 0;
}
