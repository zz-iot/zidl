//! Bridges a caller-supplied `ZidlAllocator` (the shared C allocator-vtable
//! ABI defined in `zidl-cdr`'s `zidl_allocator.h`) into a Zig
//! `std.mem.Allocator`, for Zig code sitting behind a C ABI that wants to
//! honor a caller's custom allocation strategy (static pool, slab allocator)
//! instead of being locked to a hardcoded default.
//!
//! `ZidlAllocator` is mirrored here as an `extern struct` rather than pulled
//! in via a C header/translate-c step — the shape is small and stable, and
//! this keeps zidl-rt a pure-Zig package with no C build dependency.
//!
//! Critical property: `toAllocator` allocates nothing. The returned
//! `std.mem.Allocator.ptr` points directly at the caller's own
//! `*const ZidlAllocator` (the caller owns and must keep that struct alive
//! for at least as long as the returned Allocator is used); `vtable` points
//! at a single process-wide `static const` translation table. This matters
//! for a genuine zero-allocation bootstrap: if this adapter itself heap-boxed
//! anything to represent the caller's allocator, a caller whose own `alloc`
//! is a fixed-capacity static pool with no spare room for our bookkeeping
//! would be defeated before their allocator ever ran.

const std = @import("std");

pub const ZidlAllocator = extern struct {
    ctx: ?*anyopaque,
    alloc: *const fn (ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8,
    resize: *const fn (ctx: ?*anyopaque, ptr: ?[*]u8, old_len: usize, new_len: usize, alignment: usize) callconv(.c) bool,
    free: *const fn (ctx: ?*anyopaque, ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void,
};

fn asZidlAllocator(ptr: *anyopaque) *const ZidlAllocator {
    return @ptrCast(@alignCast(ptr));
}

fn vtAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const z = asZidlAllocator(ptr);
    return z.alloc(z.ctx, len, alignment.toByteUnits());
}

fn vtResize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ret_addr;
    const z = asZidlAllocator(ptr);
    return z.resize(z.ctx, memory.ptr, memory.len, new_len, alignment.toByteUnits());
}

fn vtRemap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    // No separate C-ABI "remap" concept — a successful in-place resize IS a
    // remap (same pointer, new size); a failed one means the caller must
    // fall back to alloc-new + copy + free, same as returning null here.
    if (vtResize(ptr, memory, alignment, new_len, ret_addr)) return memory.ptr;
    return null;
}

fn vtFree(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    const z = asZidlAllocator(ptr);
    z.free(z.ctx, memory.ptr, memory.len, alignment.toByteUnits());
}

const vtable = std.mem.Allocator.VTable{
    .alloc = vtAlloc,
    .resize = vtResize,
    .remap = vtRemap,
    .free = vtFree,
};

/// Wrap a caller-owned `ZidlAllocator` as a `std.mem.Allocator`. Allocates
/// nothing (see module doc); `c_alloc` must outlive the returned Allocator.
pub fn toAllocator(c_alloc: *const ZidlAllocator) std.mem.Allocator {
    return .{ .ptr = @ptrCast(@constCast(c_alloc)), .vtable = &vtable };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A trivial fixed-buffer C-shaped allocator, standing in for a real static
/// pool a C caller would supply, to exercise `toAllocator` without needing an
/// actual C compiler in this package's own test suite.
const FixedPoolCtx = struct {
    buf: []u8,
    used: usize = 0,
};

fn poolAlloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8 {
    const pool: *FixedPoolCtx = @ptrCast(@alignCast(ctx.?));
    const aligned_start = std.mem.alignForward(usize, pool.used, alignment);
    if (aligned_start + len > pool.buf.len) return null;
    pool.used = aligned_start + len;
    return @ptrCast(pool.buf.ptr + aligned_start);
}

fn poolResize(ctx: ?*anyopaque, ptr: ?[*]u8, old_len: usize, new_len: usize, alignment: usize) callconv(.c) bool {
    _ = ctx;
    _ = ptr;
    _ = alignment;
    // Trivial conforming implementation: only ever "succeeds" when shrinking.
    return new_len <= old_len;
}

fn poolFree(ctx: ?*anyopaque, ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void {
    // Bump allocator: no-op free, matching the documented contract that
    // free() must accept every pointer alloc() returned without requiring
    // the callee to reclaim anything.
    _ = ctx;
    _ = ptr;
    _ = len;
    _ = alignment;
}

fn testZidlAllocator(pool: *FixedPoolCtx) ZidlAllocator {
    return .{
        .ctx = pool,
        .alloc = poolAlloc,
        .resize = poolResize,
        .free = poolFree,
    };
}

test "toAllocator: alloc/free round-trip through the C vtable" {
    var buf: [256]u8 = undefined;
    var pool = FixedPoolCtx{ .buf = &buf };
    const c_alloc = testZidlAllocator(&pool);
    const alloc = toAllocator(&c_alloc);

    const mem = try alloc.alloc(u8, 16);
    defer alloc.free(mem);
    try testing.expectEqual(@as(usize, 16), mem.len);
    @memset(mem, 0xAB);
    try testing.expect(pool.used >= 16);
}

test "toAllocator: OOM surfaces as error.OutOfMemory, not a crash" {
    var buf: [8]u8 = undefined;
    var pool = FixedPoolCtx{ .buf = &buf };
    const c_alloc = testZidlAllocator(&pool);
    const alloc = toAllocator(&c_alloc);

    try testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1024));
}

test "toAllocator: shrink-in-place resize succeeds, grow falls back" {
    var buf: [256]u8 = undefined;
    var pool = FixedPoolCtx{ .buf = &buf };
    const c_alloc = testZidlAllocator(&pool);
    const alloc = toAllocator(&c_alloc);

    var mem = try alloc.alloc(u8, 32);
    defer alloc.free(mem);
    try testing.expect(alloc.resize(mem, 16));
    mem = mem[0..16];
    // Growing past the trivial pool's "always false" resize forces realloc,
    // exercised via std.mem.Allocator.realloc's alloc+copy+free fallback.
    const grown = try alloc.realloc(mem, 64);
    try testing.expectEqual(@as(usize, 64), grown.len);
    alloc.free(grown);
}

test "toAllocator: no allocation is performed to represent the adapter itself" {
    // toAllocator must be a pure value construction — calling it twice for
    // the same ZidlAllocator must not touch the pool at all.
    var buf: [64]u8 = undefined;
    var pool = FixedPoolCtx{ .buf = &buf };
    const c_alloc = testZidlAllocator(&pool);
    _ = toAllocator(&c_alloc);
    _ = toAllocator(&c_alloc);
    try testing.expectEqual(@as(usize, 0), pool.used);
}
