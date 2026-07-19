/**
 * zidl_allocator.h — Shared C allocator-vtable ABI for zidl-generated code and
 * zidl-based DDS implementations (e.g. zzdds).
 *
 * A caller-supplied `ZidlAllocator` lets embedded/real-time C and C++ consumers
 * replace every heap allocation crossing the C ABI — participant/entity
 * bootstrap, CDR string/sequence decode, etc. — with their own strategy
 * (static pool, slab allocator, bump allocator) instead of being locked to
 * libc malloc/free.
 *
 * This type is intentionally defined once, in this dependency-free header, and
 * reused unmodified by every layer that needs an allocator hook (zzdds's C-ABI
 * bootstrap, zidl-cdr's own string/sequence decode) rather than each layer
 * inventing its own incompatible vtable shape.
 *
 * `alloc`/`resize`/`free` mirror the shape of Zig's `std.mem.Allocator.VTable`
 * (alloc/resize/free split) so a Zig-side adapter is a mechanical,
 * allocation-free translation — see `zidl-rt`'s `allocator.zig`.
 *
 * Contract:
 *   - `ctx` is opaque to the callee; passed back unchanged on every call.
 *   - `alloc(ctx, len, alignment)` returns a pointer to at least `len` bytes
 *     aligned to `alignment` (a power of two), or NULL on failure. Must never
 *     return NULL for `len == 0` in a way indistinguishable from failure —
 *     callers treat NULL as OOM.
 *   - `resize(ctx, ptr, old_len, new_len, alignment)` attempts to grow or
 *     shrink the allocation at `ptr` *in place* (never moves it). Returns
 *     true on success (the pointer is still valid, now sized `new_len`) or
 *     false if an in-place resize isn't possible — the caller then falls
 *     back to alloc-new + copy + free. A trivial conforming implementation
 *     may always return false.
 *   - `free(ctx, ptr, len, alignment)` releases a pointer previously returned
 *     by `alloc` (with its current size after any successful `resize`
 *     calls). Must accept `ptr == NULL` as a no-op.
 *   - The struct itself (not just `ctx`) must outlive every object created
 *     through it — the same lifetime discipline already used for
 *     `zzdds_register_type_support_c`'s callback pointer. Nothing that
 *     consumes a `ZidlAllocator` copies it internally.
 */
#ifndef ZIDL_ALLOCATOR_H
#define ZIDL_ALLOCATOR_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZidlAllocator {
    void *ctx;
    void *(*alloc)(void *ctx, size_t len, size_t alignment);
    bool  (*resize)(void *ctx, void *ptr, size_t old_len, size_t new_len, size_t alignment);
    void  (*free)(void *ctx, void *ptr, size_t len, size_t alignment);
} ZidlAllocator;

#ifdef __cplusplus
}
#endif

#endif /* ZIDL_ALLOCATOR_H */
