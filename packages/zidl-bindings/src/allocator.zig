//! Bridges a caller-supplied `ZidlAllocator` (the shared C allocator-vtable
//! ABI defined in `zidl-cdr`'s `zidl_allocator.h`) into a Zig
//! `std.mem.Allocator`, for Zig code sitting behind a C ABI that wants to
//! honor a caller's custom allocation strategy (static pool, slab allocator)
//! instead of being locked to a hardcoded default.
//!
//! `ZidlAllocator` is mirrored here as an `extern struct` rather than pulled
//! in via a C header/translate-c step — the shape is small and stable, and
//! this keeps binding support a pure-Zig package with no C build dependency.
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

/// The least alignment this adapter passes to a `ZidlAllocator`: the eight
/// bytes zidl-cdr's C side passes for every block it allocates or frees.
/// Generated C and Zig code free each other's blocks (a C caller frees a
/// sequence a Zig provider filled, and the other way round), and an
/// allocator may need a block's free to carry the alignment it was
/// allocated with.
pub const min_alignment: usize = 8;

fn cAlignment(alignment: std.mem.Alignment) usize {
    return @max(alignment.toByteUnits(), min_alignment);
}

fn vtAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const z = asZidlAllocator(ptr);
    return z.alloc(z.ctx, len, cAlignment(alignment));
}

fn vtResize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ret_addr;
    const z = asZidlAllocator(ptr);
    return z.resize(z.ctx, memory.ptr, memory.len, new_len, cAlignment(alignment));
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
    z.free(z.ctx, memory.ptr, memory.len, cAlignment(alignment));
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
    // Align against the buffer's actual absolute address, not an offset
    // relative to it — pool.buf.ptr itself isn't guaranteed aligned to
    // `alignment` (only ever exercised with u8/alignment=1 today, but this
    // is the exact failure mode the ZidlAllocator contract exists to catch).
    const base = @intFromPtr(pool.buf.ptr);
    const aligned_abs = std.mem.alignForward(usize, base + pool.used, alignment);
    const aligned_start = aligned_abs - base;
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

test "toAllocator: alignment > 1 returns a genuinely aligned pointer even when the pool's base isn't" {
    // storage is 8-aligned, but slicing off the first byte guarantees the
    // pool's own base address is NOT a multiple of 8. Computing alignment
    // relative to an offset from that base (instead of the real absolute
    // address) would silently return a misaligned pointer here — this is
    // the exact scenario the fix (align against @intFromPtr(pool.buf.ptr),
    // not against pool.used alone) exists to catch.
    var storage: [264]u8 align(8) = undefined;
    const misaligned_base = storage[1..];
    try testing.expect(@intFromPtr(misaligned_base.ptr) % 8 != 0);

    var pool = FixedPoolCtx{ .buf = misaligned_base };
    const c_alloc = testZidlAllocator(&pool);
    const alloc = toAllocator(&c_alloc);

    const vals = try alloc.alloc(u64, 4);
    defer alloc.free(vals);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(vals.ptr) % @alignOf(u64));
}

// Records the alignment of each call, and fails a free whose alignment is
// not the one its block was allocated with.
const AlignmentRecorder = struct {
    buf: [256]u8 align(16) = undefined,
    used: usize = 0,
    alloc_alignment: usize = 0,
    free_alignment: usize = 0,

    fn alloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8 {
        const self: *AlignmentRecorder = @ptrCast(@alignCast(ctx.?));
        const start = std.mem.alignForward(usize, self.used, alignment);
        if (start + len > self.buf.len) return null;
        self.used = start + len;
        self.alloc_alignment = alignment;
        return self.buf[start..].ptr;
    }

    fn resize(_: ?*anyopaque, _: ?[*]u8, _: usize, _: usize, _: usize) callconv(.c) bool {
        return false;
    }

    fn free(ctx: ?*anyopaque, _: ?[*]u8, _: usize, alignment: usize) callconv(.c) void {
        const self: *AlignmentRecorder = @ptrCast(@alignCast(ctx.?));
        self.free_alignment = alignment;
    }
};

test "toAllocator: passes at least zidl-cdr's eight-byte alignment, the same on alloc and free" {
    var rec: AlignmentRecorder = .{};
    const c_alloc: ZidlAllocator = .{ .ctx = &rec, .alloc = AlignmentRecorder.alloc, .resize = AlignmentRecorder.resize, .free = AlignmentRecorder.free };
    const alloc = toAllocator(&c_alloc);

    // A string, as zidl-cdr's C side would free it.
    const s = try alloc.dupeSentinel(u8, "abc", 0);
    try testing.expectEqual(min_alignment, rec.alloc_alignment);
    alloc.free(s);
    try testing.expectEqual(min_alignment, rec.free_alignment);

    // A type aligned past eight keeps its own alignment.
    const wide = try alloc.alignedAlloc(u8, .@"16", 4);
    try testing.expectEqual(@as(usize, 16), rec.alloc_alignment);
    alloc.free(wide);
    try testing.expectEqual(@as(usize, 16), rec.free_alignment);
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
