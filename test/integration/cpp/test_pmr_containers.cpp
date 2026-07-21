// Integration test for the --cpp-pmr-containers backend flag: proves that
// generated struct fields (std::pmr::string/std::pmr::vector, for both
// bounded and unbounded string/sequence fields) actually route allocation
// through zidl::setCppAllocator, and default to ordinary new/libc when
// unregistered. Compiled and run by `zig build integration-test`.
//
// Uses the shared test/golden/types.idl Sample struct (str: unbounded
// string, bstr: bounded string<32>, nums: unbounded sequence<long>),
// generated fresh at build time with --cpp-pmr-containers (not a checked-in
// golden -- this flag's own golden coverage lives in cpp.zig's unit tests).

#include "types.hpp"
#include "zidl_allocator_pmr.hpp"

#include <cassert>
#include <cstdio>
#include <cstdlib>

static size_t alloc_calls = 0, free_calls = 0;
static void* track_alloc(void*, size_t len, size_t) { alloc_calls++; return std::malloc(len); }
static bool track_resize(void*, void*, size_t, size_t, size_t) { return false; }
static void track_free(void*, void* p, size_t, size_t) { free_calls++; std::free(p); }

int main() {
    // Before registering: default resource, untracked.
    {
        Sample s{};
        s.str = "unbounded string field, long enough to defeat SSO";
        s.bstr = "bounded field";
        s.nums = {1, 2, 3, 4, 5};
    }
    assert(alloc_calls == 0 && free_calls == 0);

    ZidlAllocator za{nullptr, track_alloc, track_resize, track_free};
    zidl::setCppAllocator(&za);
    {
        Sample s{};
        s.str = "unbounded string field, long enough to defeat SSO";
        s.bstr = "bounded field";
        s.nums = {1, 2, 3, 4, 5};
        assert(s.str.size() > 0);
        assert(s.nums.size() == 5);
        assert(alloc_calls > 0);
    }
    assert(free_calls > 0);
    assert(alloc_calls == free_calls);
    zidl::setCppAllocator(nullptr);

    std::printf("test_pmr_containers: OK (%zu allocs, %zu frees)\n", alloc_calls, free_calls);
    return 0;
}
