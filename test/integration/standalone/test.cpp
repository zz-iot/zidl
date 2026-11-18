// Drives standalone.idl's generated C++ binding against the Zig provider:
// static constructors, ownership by the creating wrapper, the strict
// destructor, the fallback release, family identity, and @static operations.
#include "standalone_impl.hpp"

#include <atomic>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <memory_resource>
#include <new>
#include <vector>

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

// TSan's runtime defines the global operator new/delete, so a replacement
// cannot link there; the global-new check runs in the other builds.
#if defined(__SANITIZE_THREAD__)
#define STANDALONE_COUNT_GLOBAL_NEW 0
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define STANDALONE_COUNT_GLOBAL_NEW 0
#endif
#endif
#ifndef STANDALONE_COUNT_GLOBAL_NEW
#define STANDALONE_COUNT_GLOBAL_NEW 1
#endif

#if STANDALONE_COUNT_GLOBAL_NEW
// Counts the global operator new, which a create() under a pmr default
// resource must not reach.
static std::atomic<int> g_global_news{0};

void* operator new(std::size_t n) {
    g_global_news.fetch_add(1, std::memory_order_relaxed);
    if (void* p = std::malloc(n ? n : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
#endif

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

// Holder's first create(), under a pmr default resource, allocates its
// wrapper and its identity-cache entry from that resource, never from the
// global operator new. The pool is never destroyed: Holder's cache keeps it.
static void test_create_without_global_new() {
#if STANDALONE_COUNT_GLOBAL_NEW
    test_stats_reset();
    alignas(std::max_align_t) static unsigned char buf[64 * 1024];
    static std::pmr::monotonic_buffer_resource pool(buf, sizeof buf);
    std::pmr::memory_resource* prev = std::pmr::set_default_resource(&pool);
    const int before = g_global_news.load();
    {
        auto h = S::Holder::create();
        CHECK(h);
    }
    const int after = g_global_news.load();
    std::pmr::set_default_resource(prev);
    CHECK(after == before);
    expect_stats(0, 1, 0);
#endif
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
    CHECK(e->get_workers() == 0);
    CHECK(e->unpin() == S::RETCODE_ALREADY_DELETED);
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
    e->release();
    CHECK(e->get_workers() == 0);
    CHECK(e->destroy() == S::RETCODE_ALREADY_DELETED);
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
    // Aligned operator new, not aligned_alloc, which the Windows CRT lacks.
    static void* alloc(void* ctx, size_t len, size_t alignment) {
        static_cast<Counting*>(ctx)->allocs++;
        return ::operator new(len, std::align_val_t(alignment), std::nothrow);
    }
    static bool resize(void*, void*, size_t, size_t, size_t) { return false; }
    static void free(void* ctx, void* ptr, size_t, size_t alignment) {
        if (!ptr) return;
        static_cast<Counting*>(ctx)->frees++;
        ::operator delete(ptr, std::align_val_t(alignment));
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
// A nil result comes back as nullptr, and nullptr goes in as the provider's
// nil, which the provider can call through.
static void test_nil() {
    test_stats_reset();
    {
        auto h = S::Holder::create();
        CHECK(h);
        CHECK(!h->held());
        CHECK(h->hold(nullptr) == S::RETCODE_OK);
        CHECK(!h->held());
    }
    expect_stats(0, 1, 0);
}

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

// A destroyed guard's address comes back for the next one. Every old
// wrapper stays alive, so a family cache that kept released handles would
// hand one of them back.
static void test_reused_address() {
    test_stats_reset();
    std::vector<std::shared_ptr<S::Guard>> kept;
    for (int i = 0; i < 16; i++) {
        auto g = S::Guard::create();
        CHECK(g);
        for (auto& old : kept) CHECK(old != g);
        CHECK(g->set_trigger_value(true) == S::RETCODE_OK);
        CHECK(g->destroy() == S::RETCODE_OK);
        kept.push_back(g);
    }
    kept.clear();
    expect_stats(0, 16, 0);
}

// Boxing the new object throws: the factory releases the object before the
// exception leaves it. The identity cache already exists (earlier tests), so
// only the wrapper's allocation fails.
static void test_boxing_throws() {
    test_stats_reset();
    std::pmr::memory_resource* prev = std::pmr::set_default_resource(std::pmr::null_memory_resource());
    bool threw = false;
    try {
        (void)S::Engine::create();
    } catch (const std::bad_alloc&) {
        threw = true;
    }
    std::pmr::set_default_resource(prev);
    CHECK(threw);
    expect_stats(0, 0, 1);
}

// The @static singleton: every get_instance() returns the same, borrowed
// wrapper, which dropping does not release; delete_instance() refuses while
// it is pinned, and the next get_instance() creates a new one.
static void test_static_singleton() {
    test_stats_reset();
    CHECK(S::Registry::delete_instance() == S::RETCODE_OK);
    std::shared_ptr<S::Registry> r = S::Registry::get_instance();
    CHECK(r);
    CHECK(S::Registry::get_instance() == r);
    const int32_t generation = r->get_generation();
    r.reset();
    expect_stats(1, 0, 0);
    r = S::Registry::get_instance();
    CHECK(r->get_generation() == generation);
    CHECK(r->pin(true) == S::RETCODE_OK);
    CHECK(S::Registry::delete_instance() == S::RETCODE_PRECONDITION_NOT_MET);
    CHECK(r->pin(false) == S::RETCODE_OK);
    CHECK(S::Registry::delete_instance() == S::RETCODE_OK);
    expect_stats(0, 1, 0);
#ifndef STANDALONE_NO_RETIRE_HOOK
    // The provider freed it: the retire hook retired the wrapper.
    CHECK(r->pin(true) == S::RETCODE_ALREADY_DELETED);
#endif
    // Without the retire hook, nothing evicts the deleted instance's wrapper,
    // so drop it before its address can come back.
    r.reset();
    r = S::Registry::get_instance();
    CHECK(r && r->get_generation() == generation + 1);
    CHECK(S::Registry::delete_instance() == S::RETCODE_OK);
    expect_stats(0, 2, 0);
}

// A static's interface argument converts like any operation's, and an empty
// pointer goes in as the provider's nil.
static void test_static_arguments() {
    test_stats_reset();
    CHECK(!S::Registry::is_trigger_set(nullptr));
    {
        auto g = S::Guard::create();
        CHECK(g);
        CHECK(!S::Registry::is_trigger_set(g));
        CHECK(g->set_trigger_value(true) == S::RETCODE_OK);
        CHECK(S::Registry::is_trigger_set(g));
    }
    expect_stats(0, 1, 0);
}

int main() {
    // First: any earlier release would reach Holder's cache through the
    // retire observer and create it under the old default resource.
    test_create_without_global_new();
    test_drop_runs_finalizer();
    test_destroy_then_drop();
    test_release_then_drop();
    test_failed_constructor();
    test_allocator_overload();
    test_nil();
    test_family_identity();
    test_reused_address();
    test_boxing_throws();
    test_static_singleton();
    test_static_arguments();
    std::puts("standalone construction: C++ checks passed");
    return 0;
}
