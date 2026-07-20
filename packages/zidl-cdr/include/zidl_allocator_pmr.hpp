/**
 * zidl_allocator_pmr.hpp — Bridges a ZidlAllocator (the shared C
 * allocator-vtable ABI, zidl_allocator.h) into std::pmr, for C++ code that
 * wants standard-library allocator-aware construction (std::allocate_shared,
 * pmr containers) to honor a caller's custom allocation strategy instead of
 * the global allocator.
 *
 * Design note: this uses std::pmr, which commits to exception-based OOM
 * signaling (std::pmr::memory_resource::allocate() is specified to throw,
 * not return null) — a deliberate departure from ZidlAllocator's own C-level
 * contract (graceful nullptr return) and from zidl-cdr's/zidl-rt's Zig
 * adapter's graceful-failure behavior. Under a `-fno-exceptions` build this
 * degrades to std::terminate() on OOM rather than a checkable failure — an
 * accepted, well-precedented embedded C++ pattern (matching how libstdc++'s
 * own `operator new` behaves under -fno-exceptions), but a real behavior
 * difference from the rest of the allocator story, not a silent one.
 *
 * If a consumer needs graceful (non-throwing, non-terminating) OOM handling
 * for C++ entity-wrapper construction specifically, that is intentionally
 * NOT what this header provides — it would need a from-scratch
 * placement-new-based construction path bypassing std::pmr and the C++
 * `Allocator` named requirement entirely, since that requirement's
 * throw-on-failure contract applies to any conforming allocator, not just
 * this one. Not built here; flagged as a deliberately deferred option.
 *
 * Bare-metal note: setCppAllocator's own bookkeeping (installing a
 * ZidlAllocatorResource per registration) uses global `operator new` by
 * default — the one spot in this header not itself routed through a
 * caller-supplied ZidlAllocator. This is a one-time, bounded, startup/admin
 * allocation (not hot-path), which is often an acceptable tradeoff even on
 * constrained targets. For toolchains with no heap at all, define
 * ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE to an integer before including this
 * header to switch setCppAllocator to placement-new into a fixed-size static
 * pool instead — see the macro's own doc comment below for the bound this
 * imposes.
 */
#ifndef ZIDL_ALLOCATOR_PMR_HPP
#define ZIDL_ALLOCATOR_PMR_HPP

#include "zidl_allocator.h"

#include <cassert>
#include <cstddef>
#include <cstdlib>
#include <memory_resource>
#include <new>

namespace zidl {

/**
 * A std::pmr::memory_resource backed by a ZidlAllocator, bound permanently
 * to that ZidlAllocator at construction — NOT read from a mutable slot that
 * could change later. This is deliberate: std::pmr::polymorphic_allocator
 * (and the control block std::allocate_shared builds from one) stores a
 * `memory_resource*` by value, captured once at allocation time, and keeps
 * using that same resource for the matching deallocate call for the whole
 * lifetime of the allocated object. If this resource's target allocator
 * could change after the fact (e.g. via a mutable global slot read
 * dynamically in do_deallocate), an intervening setCppAllocator() call for a
 * *different* ZidlAllocator would silently redirect frees for
 * still-outstanding objects to the new allocator instead of the one that
 * actually allocated them — undefined behavior, and silent heap corruption
 * for any allocator that validates ownership (pool allocators,
 * bounds-checkers, sanitizers) — exactly the kind of allocator this API
 * targets. Binding the allocator at construction and never changing it
 * closes that hole structurally rather than by convention.
 *
 * Prefer setCppAllocator over constructing this directly.
 */
class ZidlAllocatorResource final : public std::pmr::memory_resource {
public:
    // `allocator` must be non-null. setCppAllocator (below) only ever
    // constructs this with a non-null allocator (its own nullptr case takes
    // a separate branch that never reaches here); this precondition only
    // matters for a caller directly constructing this class, which is
    // discouraged but not made unrepresentable by the type itself. Asserts
    // rather than silently tolerating null so misuse fails at the
    // construction site instead of surfacing later as a puzzling
    // silently-dropped deallocate() call.
    explicit ZidlAllocatorResource(const ZidlAllocator* allocator) noexcept
        : allocator_(allocator)
    {
        assert(allocator_ != nullptr);
    }

private:
    const ZidlAllocator* allocator_;

    // The `allocator_ ? ... : nullptr` / `if (allocator_)` guards below are
    // defense-in-depth for NDEBUG builds (where the constructor's assert is
    // compiled out) reaching this class via direct construction with
    // nullptr, not a supported code path: do_allocate throws immediately
    // rather than returning a pointer, which makes do_deallocate's guard
    // provably unreachable for any memory legitimately obtained from this
    // instance.
    void* do_allocate(std::size_t bytes, std::size_t alignment) override {
        void* p = allocator_ ? allocator_->alloc(allocator_->ctx, bytes, alignment) : nullptr;
        if (!p) throw std::bad_alloc();
        return p;
    }

    void do_deallocate(void* p, std::size_t bytes, std::size_t alignment) override {
        if (allocator_) allocator_->free(allocator_->ctx, p, bytes, alignment);
    }

    // Pointer identity, not a dynamic_cast-based "same underlying
    // ZidlAllocator" check: dynamic_cast requires RTTI, which embedded/RT
    // builds routinely disable (-fno-rtti) -- exactly the audience this
    // header targets. Nothing in this codebase's actual usage
    // (std::allocate_shared for entity wrappers) depends on two distinct
    // ZidlAllocatorResource instances wrapping the same ZidlAllocator*
    // comparing equal; is_equal only matters for pmr-container operations
    // (e.g. swap/move-assignment across allocators), not in play here. Pure
    // identity is RTTI-free and never wrong, just more conservative than a
    // by-value comparison would be.
    bool do_is_equal(const std::pmr::memory_resource& other) const noexcept override {
        return this == &other;
    }
};

#if defined(ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE)

namespace detail {

/**
 * Placement-news a ZidlAllocatorResource into a fixed-size pool of static
 * storage instead of the heap, for setCppAllocator below when
 * ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE is defined. A slot, once used, is never
 * reclaimed or reused within the process's lifetime — reusing one behind a
 * still-outstanding object would resurrect exactly the wrong-allocator-freed
 * bug that binding ZidlAllocatorResource permanently at construction (above)
 * was built to close. Bounding the pool trades that risk for a hard, static
 * cap on how many times setCppAllocator(non-null) can be called over the
 * process's lifetime — acceptable given re-registration is a rare,
 * startup/admin-time operation, not something done in a loop.
 */
inline ZidlAllocatorResource* allocateStaticPoolResource(const ZidlAllocator* allocator) {
    constexpr std::size_t kPoolSize = (ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE);
    alignas(ZidlAllocatorResource) static unsigned char pool[kPoolSize][sizeof(ZidlAllocatorResource)];
    static std::size_t next = 0;
    // assert() alone is not enough here: it's compiled out under -DNDEBUG,
    // which is the normal production/release build mode for the embedded
    // targets this macro exists for -- exactly the configuration where
    // silently indexing pool[next] past its bound (corrupting whatever
    // static/global storage happens to follow it) would be worst. The
    // assert below still gives a descriptive failure in debug builds; the
    // explicit check+abort right after it is unconditional and never
    // compiled away, so release builds fail loudly instead of corrupting
    // memory.
    assert(next < kPoolSize &&
        "zidl_allocator_pmr.hpp: ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE exceeded -- "
        "increase the pool size, or reduce how many times setCppAllocator "
        "is called with a non-null allocator over the process's lifetime");
    if (next >= kPoolSize) {
        std::abort();
    }
    void* slot = pool[next++];
    return ::new (slot) ZidlAllocatorResource(allocator);
}

} // namespace detail

#endif // ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE

/**
 * Register `allocator` as the process-wide default for std::pmr-based C++
 * allocation in generated code (entity wrapper objects via _getOrCreate, and
 * zzdds's hand-written factory bookkeeping) — a thin wrapper over
 * std::pmr::set_default_resource with the same concurrency contract (not
 * safe to call while another thread is allocating; call once at startup).
 *
 * Re-registering with a different `allocator` takes effect immediately for
 * *new* allocations: every call after this one picks it up via
 * std::pmr::get_default_resource(). It does NOT retroactively change how
 * already-outstanding objects get freed — each object's shared_ptr control
 * block captured a specific ZidlAllocatorResource (bound to whichever
 * ZidlAllocator was registered when that object was allocated) and keeps
 * freeing through it for its whole lifetime, exactly as it must for
 * allocators that validate ownership on free. Each non-null call here
 * installs a small (sizeof(ZidlAllocatorResource)-ish) ZidlAllocatorResource
 * and deliberately never frees it — re-registration is a rare,
 * startup/admin-time operation, and outstanding objects must keep a valid
 * resource to deallocate through for as long as they're alive, so there's no
 * earlier-than-"never" safe point to reclaim it. By default this comes from
 * plain `new`; if ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE is defined before this
 * header is included, it instead comes from a fixed-size static pool (see
 * that macro's doc comment above) for toolchains with no heap at all —
 * setCppAllocator itself is the only place in this header not already routed
 * through a caller-supplied ZidlAllocator (factory bootstrap and
 * _getOrCreate/wrapFactoryHandle both already are), so it's the one gap this
 * macro closes.
 *
 * Pass nullptr to restore std::pmr's own default (std::pmr::new_delete_resource,
 * i.e. ordinary global operator new/delete) — matching the NULL-means-default
 * convention used throughout zzdds_create_factory_with_allocator and
 * zidl_cdr_set_allocator, rather than std::pmr's own nullptr-to-set_default_resource
 * shorthand being a coincidence you'd have to already know about.
 *
 * `allocator` (if non-null) must outlive every allocation made through it —
 * in practice, the remaining lifetime of the process, same as
 * zidl_cdr_set_allocator's contract.
 */
inline void setCppAllocator(const ZidlAllocator* allocator) {
    if (!allocator) {
        std::pmr::set_default_resource(nullptr); // restores new_delete_resource
        return;
    }
#if defined(ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE)
    std::pmr::set_default_resource(detail::allocateStaticPoolResource(allocator));
#else
    std::pmr::set_default_resource(new ZidlAllocatorResource(allocator));
#endif
}

} // namespace zidl

#endif /* ZIDL_ALLOCATOR_PMR_HPP */
