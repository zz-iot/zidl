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
 */
#ifndef ZIDL_ALLOCATOR_PMR_HPP
#define ZIDL_ALLOCATOR_PMR_HPP

#include "zidl_allocator.h"

#include <cstddef>
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
    explicit ZidlAllocatorResource(const ZidlAllocator* allocator) noexcept
        : allocator_(allocator)
    {}

private:
    const ZidlAllocator* allocator_;

    void* do_allocate(std::size_t bytes, std::size_t alignment) override {
        void* p = allocator_ ? allocator_->alloc(allocator_->ctx, bytes, alignment) : nullptr;
        if (!p) throw std::bad_alloc();
        return p;
    }

    void do_deallocate(void* p, std::size_t bytes, std::size_t alignment) override {
        if (allocator_) allocator_->free(allocator_->ctx, p, bytes, alignment);
    }

    bool do_is_equal(const std::pmr::memory_resource& other) const noexcept override {
        auto* o = dynamic_cast<const ZidlAllocatorResource*>(&other);
        return o && o->allocator_ == allocator_;
    }
};

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
 * allocates a small (sizeof(ZidlAllocatorResource)-ish) ZidlAllocatorResource
 * via plain `new` and deliberately never frees it — re-registration is a
 * rare, startup/admin-time operation, and outstanding objects must keep a
 * valid resource to deallocate through for as long as they're alive, so
 * there's no earlier-than-"never" safe point to reclaim it.
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
    std::pmr::set_default_resource(new ZidlAllocatorResource(allocator));
}

} // namespace zidl

#endif /* ZIDL_ALLOCATOR_PMR_HPP */
