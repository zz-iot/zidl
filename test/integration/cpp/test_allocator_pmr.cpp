// Integration test for zidl_allocator_pmr.hpp (ZidlAllocator <-> std::pmr
// bridge). Compiled and run by `zig build integration-test`.
//
// Covers the Greptile-flagged regression on PR #28: re-registering
// setCppAllocator() with a different ZidlAllocator must not redirect frees
// of already-outstanding objects to the new allocator.

#include "zidl_allocator_pmr.hpp"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <memory>

struct Widget {
    int x;
    explicit Widget(int v) : x(v) {}
};

static void test_basic_routing_and_default_restore() {
    static size_t alloc_calls = 0;
    static size_t free_calls = 0;
    alloc_calls = 0;
    free_calls = 0;
    struct Fns {
        static void* alloc(void*, size_t len, size_t) { alloc_calls++; return std::malloc(len); }
        static bool resize(void*, void*, size_t, size_t, size_t) { return false; }
        static void free_(void*, void* p, size_t, size_t) { free_calls++; std::free(p); }
    };
    ZidlAllocator za{nullptr, Fns::alloc, Fns::resize, Fns::free_};

    {
        auto sp = std::allocate_shared<Widget>(
            std::pmr::polymorphic_allocator<Widget>(std::pmr::get_default_resource()), 1);
        assert(sp->x == 1);
    }
    assert(alloc_calls == 0 && free_calls == 0);

    zidl::setCppAllocator(&za);
    {
        auto sp = std::allocate_shared<Widget>(
            std::pmr::polymorphic_allocator<Widget>(std::pmr::get_default_resource()), 42);
        assert(sp->x == 42);
        assert(alloc_calls == 1);
    }
    assert(free_calls == 1);

    zidl::setCppAllocator(nullptr);
    {
        auto sp = std::allocate_shared<Widget>(
            std::pmr::polymorphic_allocator<Widget>(std::pmr::get_default_resource()), 9);
        (void)sp;
    }
    assert(alloc_calls == 1 && free_calls == 1); // no new tracked calls
}

// Regression test for PR #28's Greptile P1 finding: an object allocated
// under allocator A must keep freeing through A even after a later
// setCppAllocator() call swaps the process-wide default to allocator B.
static void test_reregistration_does_not_redirect_outstanding_frees() {
    static size_t a_alloc = 0, a_free = 0;
    static size_t b_alloc = 0, b_free = 0;
    a_alloc = a_free = b_alloc = b_free = 0;
    struct A {
        static void* alloc(void*, size_t len, size_t) { a_alloc++; return std::malloc(len); }
        static bool resize(void*, void*, size_t, size_t, size_t) { return false; }
        static void free_(void*, void* p, size_t, size_t) { a_free++; std::free(p); }
    };
    struct B {
        static void* alloc(void*, size_t len, size_t) { b_alloc++; return std::malloc(len); }
        static bool resize(void*, void*, size_t, size_t, size_t) { return false; }
        static void free_(void*, void* p, size_t, size_t) { b_free++; std::free(p); }
    };
    ZidlAllocator za{nullptr, A::alloc, A::resize, A::free_};
    ZidlAllocator zb{nullptr, B::alloc, B::resize, B::free_};

    zidl::setCppAllocator(&za);
    auto sp_a = std::allocate_shared<Widget>(
        std::pmr::polymorphic_allocator<Widget>(std::pmr::get_default_resource()), 1);
    assert(a_alloc == 1 && a_free == 0 && b_alloc == 0 && b_free == 0);

    // Re-register B while sp_a (allocated under A) is still alive.
    zidl::setCppAllocator(&zb);

    // New allocations pick up B immediately.
    auto sp_b = std::allocate_shared<Widget>(
        std::pmr::polymorphic_allocator<Widget>(std::pmr::get_default_resource()), 2);
    assert(b_alloc == 1);

    // Freeing sp_a (allocated under A, before re-registration) must call
    // A's free, not B's.
    sp_a.reset();
    assert(a_free == 1);
    assert(b_free == 0);

    sp_b.reset();
    assert(b_free == 1);
    assert(a_free == 1); // unchanged

    // Restore the default before returning: the pmr default resource
    // currently installed wraps &zb, a local about to go out of scope, and
    // the leaked ZidlAllocatorResource holding that pointer would otherwise
    // outlive it as a dangling reference.
    zidl::setCppAllocator(nullptr);
}

int main() {
    test_basic_routing_and_default_restore();
    test_reregistration_does_not_redirect_outstanding_frees();
    std::cout << "test_allocator_pmr: OK\n";
    return 0;
}
