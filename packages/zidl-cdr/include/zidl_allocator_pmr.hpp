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

namespace detail {

/// Process-wide slot holding the currently-registered ZidlAllocator (or
/// nullptr). A function-local static reference rather than a plain global so
/// this stays header-only with no companion .cpp translation unit to link.
/// Not synchronized — same concurrency contract as setCppAllocator below and
/// as zidl_cdr_set_allocator's (register once at startup, before any other
/// thread allocates).
inline const ZidlAllocator*& cppAllocatorSlot() noexcept {
    static const ZidlAllocator* slot = nullptr;
    return slot;
}

} // namespace detail

/**
 * A std::pmr::memory_resource backed by a ZidlAllocator, read from the
 * process-wide slot set by setCppAllocator (below) — not captured at
 * construction time, so the single static instance setCppAllocator installs
 * stays correct across repeated setCppAllocator calls with a different
 * ZidlAllocator, rather than freezing whatever was current the first time
 * this class was instantiated.
 *
 * Prefer setCppAllocator over constructing this directly; it exists as a
 * named type mainly so do_is_equal has something concrete to compare.
 */
class ZidlAllocatorResource final : public std::pmr::memory_resource {
private:
    void* do_allocate(std::size_t bytes, std::size_t alignment) override {
        const ZidlAllocator* a = detail::cppAllocatorSlot();
        void* p = a ? a->alloc(a->ctx, bytes, alignment) : nullptr;
        if (!p) throw std::bad_alloc();
        return p;
    }

    void do_deallocate(void* p, std::size_t bytes, std::size_t alignment) override {
        const ZidlAllocator* a = detail::cppAllocatorSlot();
        if (a) a->free(a->ctx, p, bytes, alignment);
    }

    bool do_is_equal(const std::pmr::memory_resource& other) const noexcept override {
        // Only ever one instance in practice (the static in setCppAllocator),
        // so identity is exact, not an approximation.
        return this == &other;
    }
};

/**
 * Register `allocator` as the process-wide default for std::pmr-based C++
 * allocation in generated code (entity wrapper objects via _getOrCreate, and
 * zzdds's hand-written factory bookkeeping) — a thin wrapper over
 * std::pmr::set_default_resource with the same concurrency contract (not
 * safe to call while another thread is allocating; call once at startup).
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
    detail::cppAllocatorSlot() = allocator;
    static ZidlAllocatorResource resource;
    std::pmr::set_default_resource(&resource);
}

} // namespace zidl

#endif /* ZIDL_ALLOCATOR_PMR_HPP */
