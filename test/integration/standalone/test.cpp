// Drives standalone.idl's generated C++ binding against the Zig provider:
// static constructors, ownership by the creating wrapper, the strict
// destructor, the fallback release, and family identity.
#include "standalone_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <memory>

namespace {

struct Stats {
    int32_t live;
    int32_t destroys;
    int32_t releases;
};

}  // namespace

extern "C" Stats test_stats(void);
extern "C" void test_stats_reset(void);

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, \
                         #cond);                                                 \
            std::abort();                                                        \
        }                                                                        \
    } while (0)

static void expect_stats(int32_t live, int32_t destroys, int32_t releases) {
    Stats s = test_stats();
    if (s.live != live || s.destroys != destroys || s.releases != releases) {
        std::fprintf(stderr, "stats: live %d destroys %d releases %d, expected %d %d %d\n",
                     s.live, s.destroys, s.releases, live, destroys, releases);
        std::abort();
    }
}

// Dropping the creator's last reference runs the finalizer.
static void test_drop_runs_finalizer() {
    test_stats_reset();
    {
        auto e = S::Engine::create();
        CHECK(e);
        CHECK(e->get_workers() == 1);
        expect_stats(1, 0, 0);
    }
    expect_stats(0, 0, 1);
}

// A destroyed object is not released again when its wrapper goes, and the
// wrapper answers later calls without reaching the provider.
static void test_destroy_then_drop() {
    test_stats_reset();
    S::Config cfg{};
    cfg.workers = 3;
    auto e = S::Engine::create_with(cfg, 1);
    CHECK(e);
    CHECK(e->get_workers() == 3);
    CHECK(e->destroy() == S::RETCODE_PRECONDITION_NOT_MET);
    expect_stats(1, 0, 0);
    CHECK(e->unpin() == S::RETCODE_OK);
    CHECK(e->destroy() == S::RETCODE_OK);
    expect_stats(0, 1, 0);
    CHECK(e->destroy() == S::RETCODE_ALREADY_DELETED);
#ifndef STANDALONE_NO_RETIRE_HOOK
    // Only the retire hook guards the interface's other operations.
    CHECK(e->get_workers() == 0);
#endif
    e.reset();
    expect_stats(0, 1, 0);
}

// An explicit finalizer call is the release; dropping adds nothing.
static void test_release_then_drop() {
    test_stats_reset();
    S::Config cfg{};
    cfg.workers = 2;
    auto e = S::Engine::create_with(cfg, 4);
    CHECK(e);
    e->release();
    expect_stats(0, 0, 1);
    e.reset();
    expect_stats(0, 0, 1);
}

static void test_failed_constructor() {
    test_stats_reset();
    S::Config cfg{};
    CHECK(!S::Engine::create_with(cfg, 0));
    expect_stats(0, 0, 0);
}

struct Counting {
    int allocs = 0;
    int frees = 0;
    static void* alloc(void* ctx, size_t len, size_t alignment) {
        static_cast<Counting*>(ctx)->allocs++;
        return std::aligned_alloc(alignment < sizeof(void*) ? sizeof(void*) : alignment,
                                  (len + alignment - 1) / alignment * alignment);
    }
    static bool resize(void*, void*, size_t, size_t, size_t) { return false; }
    static void free(void* ctx, void* ptr, size_t, size_t) {
        if (!ptr) return;
        static_cast<Counting*>(ctx)->frees++;
        std::free(ptr);
    }
};

static void test_allocator_overload() {
    test_stats_reset();
    Counting counting;
    ZidlAllocator za{&counting, &Counting::alloc, &Counting::resize, &Counting::free};
    {
        auto e = S::Engine::create(&za);
        CHECK(e);
        CHECK(counting.allocs == 2);
    }
    CHECK(counting.frees == 2);
    expect_stats(0, 0, 1);
}

// The wrapper Guard::create returns is the one its family's cache hands
// back for the same handle, through the Condition root.
static void test_family_identity() {
    test_stats_reset();
    {
        auto g = S::Guard::create();
        auto h = S::Holder::create();
        CHECK(g && h);
        CHECK(h->hold(g) == S::RETCODE_OK);
        std::shared_ptr<S::Condition> c = h->held();
        CHECK(c.get() == static_cast<S::Condition*>(g.get()));
        CHECK(g->set_trigger_value(true) == S::RETCODE_OK);
        CHECK(c->get_trigger_value());
        expect_stats(2, 0, 0);
    }
    // Guard and Holder have no finalizer, so dropping runs their destructor.
    expect_stats(0, 2, 0);
}

int main() {
    test_drop_runs_finalizer();
    test_destroy_then_drop();
    test_release_then_drop();
    test_failed_constructor();
    test_allocator_overload();
    test_family_identity();
    std::puts("standalone construction: C++ checks passed");
    return 0;
}
