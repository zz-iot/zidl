//! Entity handle boxing for the `--zig-generate-c-api` C-ABI export layer.
//!
//! zidl's Zig backend represents every IDL `interface` (entity) value natively
//! as a fat pointer: `extern struct { ptr: *anyopaque, vtable: *const Vtable }`.
//! This is the idiomatic Zig shape (matching `std.mem.Allocator`) and is never
//! boxed — Zig-native code and pure-Zig consumers of generated interfaces always
//! use the fat-pointer type directly.
//!
//! The C backend, however, emits a single opaque pointer per entity interface
//! (`typedef struct Foo_s *Foo;`), matching the OMG C PSM binding. `EntityBox`
//! bridges the two: it's a small heap-allocated box holding the real
//! `{ptr, vtable}` pair, and the generated `--zig-generate-c-api` export
//! functions box/unbox at exactly the C-ABI boundary, nowhere else. Because the
//! box always holds whichever vtable a native call actually returned (real or
//! the nil-entity sentinel), this preserves correct nil-entity dispatch — unlike
//! a devirtualized scheme that would assume a single statically-known vtable.

const std = @import("std");

pub const EntityBox = struct {
    ptr: *anyopaque,
    vtable: *const anyopaque,
};

/// Shared "no entity" sentinel address. A generated C-ABI export wrapper for
/// an entity-interface `.in_` op param that's allowed to be absent (an
/// optional filter/condition, not a required receiver) constructs a fat
/// pointer whose `.ptr` is this exact address when the incoming C-ABI
/// pointer was NULL, instead of ever dereferencing a null box — see
/// `emitCApiOp` in the Zig backend. Consuming native code's own nil-entity
/// check (comparing `.ptr` against this same address — e.g. zzdds's
/// `nil.isNil`, which reuses this exact constant) must run before it ever
/// touches such a value's `.vtable`, which is deliberately left `undefined`
/// in that case.
pub var nil_storage: u8 = 0;
pub const NIL_PTR: *anyopaque = @ptrCast(&nil_storage);

// Keep the public box contents unchanged; retirement is allocation metadata.
const BoxStorage = struct {
    entity: EntityBox,
    retired: std.atomic.Value(bool) = .init(false),
};

fn storageOf(handle: *anyopaque) *BoxStorage {
    const entity: *EntityBox = @ptrCast(@alignCast(handle));
    return @fieldParentPtr("entity", entity);
}

/// Allocate a box holding `ptr`/`vtable` and return it as an opaque C-ABI handle.
pub fn boxEntity(alloc: std.mem.Allocator, ptr: *anyopaque, vtable: *const anyopaque) !*anyopaque {
    const storage = try alloc.create(BoxStorage);
    storage.* = .{ .entity = .{ .ptr = ptr, .vtable = vtable } };
    return @ptrCast(&storage.entity);
}

/// Read a box's contents back out without reconstructing a typed value.
pub fn unboxEntity(handle: *anyopaque) EntityBox {
    const box: *EntityBox = @ptrCast(@alignCast(handle));
    return box.*;
}

/// Reconstruct the native fat-pointer entity value `T` (an
/// `extern struct { ptr: *anyopaque, vtable: *const SomeVtable }`) from a boxed
/// C-ABI handle.
pub fn unboxAs(comptime T: type, handle: *anyopaque) T {
    const box = unboxEntity(handle);
    return .{ .ptr = box.ptr, .vtable = @ptrCast(@alignCast(box.vtable)) };
}

/// Like `unboxAs`, but for `@shared_c_abi_box` interfaces (see
/// `ir.hasSharedCAbiBox`'s doc comment in zidl), whose box holds a `T.CAbiViews`
/// pointer instead of a bare `T.Vtable` pointer — one physical box shared
/// across every interface view a concrete impl presents, rather than one box
/// per view.
///
/// `T.CAbiViews` nests its primary base's own `CAbiViews` as its first field,
/// recursively (`extern struct` guarantees first-field-at-offset-0, so this
/// composes through arbitrary depth). That's what makes this safe: whatever
/// the box's *actual* leaf type's `CAbiViews` looks like, reinterpreting its
/// pointer as `*const T.CAbiViews` for any ancestor `T` reached by always
/// following the primary base correctly lands on `T`'s own `flat_vtable`
/// field — verified for the two-levels-deep case by a real Zig 0.16.0 spike
/// (see zidl/docs/design/binding-c-abi-identity.md).
///
/// This is the whole fix for the C-ABI cross-view identity bug that section
/// describes: since every ancestor view's `get_c_abi_handle` implementation
/// shares one cache and passes the *same* `CAbiViews` pointer to it (see that
/// section's Phase 1), two different interface views of the same concrete
/// object now unbox from the *same* box address, not two independently
/// allocated ones.
pub fn unboxAsView(comptime T: type, handle: *anyopaque) T {
    const box = unboxEntity(handle);
    const views: *const T.CAbiViews = @ptrCast(@alignCast(box.vtable));
    return .{ .ptr = box.ptr, .vtable = views.flat_vtable };
}

/// Free a box previously created by `boxEntity`. Does not touch whatever
/// `box.ptr` refers to — that's the concrete entity implementation's own
/// lifetime, freed separately by the native `deinit`/delete path.
///
/// Reports the handle to every handle-retire observer first (see
/// `observeHandleRetire`), so a binding can drop its wrapper for the handle
/// before the allocator can hand the address to another entity.
pub fn freeEntityBox(alloc: std.mem.Allocator, handle: *anyopaque) void {
    retireEntityBox(handle);
    alloc.destroy(storageOf(handle));
}

/// Mark a boxEntity allocation logically deleted, notifying observers once.
/// Storage must remain alive until all native users and observers finish.
pub fn retireEntityBox(handle: *anyopaque) void {
    if (!storageOf(handle).retired.swap(true, .acq_rel)) notifyHandleRetired(handle);
}

/// Query a live boxEntity allocation. This does not pin its storage.
pub fn isEntityBoxRetired(handle: *anyopaque) bool {
    return storageOf(handle).retired.load(.acquire);
}

// ── Handle-retire observers ───────────────────────────────────────────────────
//
// The provider side of zidl's handle-retire contract
// (zidl/docs/design/handle-lifetime.md). A language binding that caches one
// wrapper per C-ABI handle registers an observer; every handle this runtime
// frees is reported to every observer before its memory is released.
//
// This package has no mutex, so the table is lock-free: blocks of slots,
// appended as needed and never freed. A slot's state word carries a generation
// that changes with every registration, so a removal acts only on the
// registration it matched. A notification counts itself in the slot's `busy`
// while it calls the observer, so removing an observer waits only for calls to
// that observer.

/// Called with the observer's own context and the handle being retired. Runs
/// on whatever thread frees the handle, possibly concurrently with other
/// calls. It must not call back into the provider, block, or run application
/// code; it may take the binding's own short internal locks.
pub const HandleRetiredFn = *const fn (ctx: ?*anyopaque, handle: *anyopaque) callconv(.c) void;

const state_free: u32 = 0;
const state_changing: u32 = 1;
const state_live: u32 = 2;
const state_mask: u32 = 3;

const Slot = struct {
    /// generation << 2 | state.
    state: std.atomic.Value(u32) = .init(state_free),
    busy: std.atomic.Value(u32) = .init(0),
    func: std.atomic.Value(?HandleRetiredFn) = .init(null),
    ctx: std.atomic.Value(?*anyopaque) = .init(null),
};

const block_len = 16;

const Block = struct {
    slots: [block_len]Slot = @splat(.{}),
    next: std.atomic.Value(?*Block) = .init(null),
};

var first_block: Block = .{};

/// Registers `func`/`ctx` as a handle-retire observer. Returns false only if
/// the table needed to grow and allocation failed. Registering the same pair
/// twice gets two notifications.
pub fn observeHandleRetire(func: HandleRetiredFn, ctx: ?*anyopaque) bool {
    var block: *Block = &first_block;
    while (true) {
        for (&block.slots) |*slot| {
            const s = slot.state.load(.acquire);
            if (s & state_mask != state_free) continue;
            const claimed = ((s >> 2) +% 1) << 2 | state_changing;
            if (slot.state.cmpxchgStrong(s, claimed, .acq_rel, .monotonic) != null) continue;
            slot.func.store(func, .release);
            slot.ctx.store(ctx, .release);
            slot.state.store((claimed & ~state_mask) | state_live, .seq_cst);
            return true;
        }
        if (block.next.load(.acquire)) |next| {
            block = next;
            continue;
        }
        const grown = std.heap.page_allocator.create(Block) catch return false;
        grown.* = .{};
        if (block.next.cmpxchgStrong(null, grown, .acq_rel, .acquire)) |winner| {
            std.heap.page_allocator.destroy(grown);
            block = winner.?;
        } else {
            block = grown;
        }
    }
}

/// Removes one registration of `func`/`ctx`, then waits for calls to it
/// already under way to finish, so the observer is not running when this
/// returns. Must not be called from inside an observer. Returns false if the
/// pair was not registered.
pub fn unobserveHandleRetire(func: HandleRetiredFn, ctx: ?*anyopaque) bool {
    var it: ?*Block = &first_block;
    while (it) |block| : (it = block.next.load(.acquire)) {
        for (&block.slots) |*slot| {
            const s = slot.state.load(.acquire);
            if (s & state_mask != state_live) continue;
            if (slot.func.load(.acquire) != func or slot.ctx.load(.acquire) != ctx) continue;
            // Only this exact registration: the generation in `s` changes if
            // it was removed and the slot reused since the reads above.
            const changing = (s & ~state_mask) | state_changing;
            if (slot.state.cmpxchgStrong(s, changing, .seq_cst, .monotonic) != null) continue;
            while (slot.busy.load(.seq_cst) != 0) std.atomic.spinLoopHint();
            slot.func.store(null, .release);
            slot.ctx.store(null, .release);
            slot.state.store((s & ~state_mask) | state_free, .release);
            return true;
        }
    }
    return false;
}

/// Reports `handle` to every observer. `freeEntityBox` calls this; a provider
/// that retires handles some other way (its own boxes, or reusing a handle's
/// address for a different object) must call it before the address can name
/// anything else.
pub fn notifyHandleRetired(handle: *anyopaque) void {
    var it: ?*Block = &first_block;
    while (it) |block| : (it = block.next.load(.acquire)) {
        for (&block.slots) |*slot| {
            const s = slot.state.load(.seq_cst);
            if (s & state_mask != state_live) continue;
            _ = slot.busy.fetchAdd(1, .seq_cst);
            defer _ = slot.busy.fetchSub(1, .seq_cst);
            // A removal that began before `busy` was raised is not waiting
            // for this call: skip.
            if (slot.state.load(.seq_cst) != s) continue;
            if (slot.func.load(.acquire)) |f| f(slot.ctx.load(.acquire), handle);
        }
    }
}

/// Exports the C entry points a binding generated with
/// `--handle-retire-hook=<name>` links against:
///
///     int  <name>_observe(void (*fn)(void *ctx, void *handle), void *ctx);
///     int  <name>_unobserve(void (*fn)(void *ctx, void *handle), void *ctx);
///     int  <name>_is_retired(void *handle);
///
/// Observe/unobserve return 0 on success, nonzero otherwise. The query returns
/// nonzero for retired handles and only accepts boxEntity allocations.
/// Call from a `comptime` block
/// in the library that owns this runtime instance, so the observers it
/// registers see that instance's frees: `comptime { zidl_bindings.exportHandleRetireHook("mylib_handle_retire"); }`.
pub fn exportHandleRetireHook(comptime name: []const u8) void {
    const S = struct {
        fn isRetired(handle: ?*anyopaque) callconv(.c) c_int {
            return if (handle) |h| @intFromBool(isEntityBoxRetired(h)) else 1;
        }
        fn observe(func: ?HandleRetiredFn, ctx: ?*anyopaque) callconv(.c) c_int {
            const f = func orelse return 1;
            return if (observeHandleRetire(f, ctx)) 0 else 1;
        }
        fn unobserve(func: ?HandleRetiredFn, ctx: ?*anyopaque) callconv(.c) c_int {
            const f = func orelse return 1;
            return if (unobserveHandleRetire(f, ctx)) 0 else 1;
        }
    };
    @export(&S.isRetired, .{ .name = name ++ "_is_retired" });
    @export(&S.observe, .{ .name = name ++ "_observe" });
    @export(&S.unobserve, .{ .name = name ++ "_unobserve" });
}

test "freeEntityBox reports the handle to observers before freeing it" {
    const Rec = struct {
        var seen: ?*anyopaque = null;
        var count: usize = 0;
        fn on(ctx: ?*anyopaque, handle: *anyopaque) callconv(.c) void {
            std.debug.assert(ctx == @as(?*anyopaque, @ptrFromInt(0x10)));
            seen = handle;
            count += 1;
        }
    };
    const ctx: ?*anyopaque = @ptrFromInt(0x10);
    try std.testing.expect(observeHandleRetire(&Rec.on, ctx));
    var target: u8 = 0;
    const h = try boxEntity(std.testing.allocator, @ptrCast(&target), @ptrCast(&target));
    freeEntityBox(std.testing.allocator, h);
    try std.testing.expectEqual(h, Rec.seen.?);
    try std.testing.expectEqual(@as(usize, 1), Rec.count);

    try std.testing.expect(unobserveHandleRetire(&Rec.on, ctx));
    try std.testing.expect(!unobserveHandleRetire(&Rec.on, ctx));
    const h2 = try boxEntity(std.testing.allocator, @ptrCast(&target), @ptrCast(&target));
    freeEntityBox(std.testing.allocator, h2);
    try std.testing.expectEqual(@as(usize, 1), Rec.count);
}

test "the observer table grows past one block, and a removal frees only its own slot" {
    const Count = struct {
        var calls: usize = 0;
        fn on(_: ?*anyopaque, _: *anyopaque) callconv(.c) void {
            calls += 1;
        }
    };
    const n = block_len * 2 + 3;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try std.testing.expect(observeHandleRetire(&Count.on, @ptrFromInt(i + 1)));
    }
    var target: u8 = 0;
    notifyHandleRetired(@ptrCast(&target));
    try std.testing.expectEqual(@as(usize, n), Count.calls);

    // Remove one, register another (it may take the freed slot), then remove
    // the first again: the newcomer must stay registered.
    try std.testing.expect(unobserveHandleRetire(&Count.on, @ptrFromInt(1)));
    try std.testing.expect(observeHandleRetire(&Count.on, @ptrFromInt(0x1000)));
    try std.testing.expect(!unobserveHandleRetire(&Count.on, @ptrFromInt(1)));
    Count.calls = 0;
    notifyHandleRetired(@ptrCast(&target));
    try std.testing.expectEqual(@as(usize, n), Count.calls);

    i = 1;
    while (i < n) : (i += 1) {
        try std.testing.expect(unobserveHandleRetire(&Count.on, @ptrFromInt(i + 1)));
    }
    try std.testing.expect(unobserveHandleRetire(&Count.on, @ptrFromInt(0x1000)));
    Count.calls = 0;
    notifyHandleRetired(@ptrCast(&target));
    try std.testing.expectEqual(@as(usize, 0), Count.calls);
}

test "logical retirement persists until free and notifies once" {
    comptime exportHandleRetireHook("zidl_bindings_test_retirement");
    const Hook = struct {
        extern fn zidl_bindings_test_retirement_is_retired(handle: ?*anyopaque) callconv(.c) c_int;
    };
    try std.testing.expectEqual(@as(c_int, 1), Hook.zidl_bindings_test_retirement_is_retired(null));
    const Observer = struct {
        var count: usize = 0;
        fn on(_: ?*anyopaque, handle: *anyopaque) callconv(.c) void {
            std.debug.assert(isEntityBoxRetired(handle));
            count += 1;
        }
    };
    Observer.count = 0;
    try std.testing.expect(observeHandleRetire(Observer.on, null));
    defer _ = unobserveHandleRetire(Observer.on, null);
    var value: u8 = 0;
    const handle = try boxEntity(std.testing.allocator, &value, &value);
    try std.testing.expect(!isEntityBoxRetired(handle));
    try std.testing.expectEqual(@as(c_int, 0), Hook.zidl_bindings_test_retirement_is_retired(handle));
    retireEntityBox(handle);
    retireEntityBox(handle);
    try std.testing.expect(isEntityBoxRetired(handle));
    try std.testing.expectEqual(@as(c_int, 1), Hook.zidl_bindings_test_retirement_is_retired(handle));
    try std.testing.expectEqual(@as(*anyopaque, &value), unboxEntity(handle).ptr);
    try std.testing.expectEqual(@as(usize, 1), Observer.count);
    freeEntityBox(std.testing.allocator, handle);
    try std.testing.expectEqual(@as(usize, 1), Observer.count);
}

test "concurrent logical retirement notifies once" {
    const Observer = struct {
        var count: std.atomic.Value(usize) = .init(0);
        fn on(_: ?*anyopaque, _: *anyopaque) callconv(.c) void {
            _ = count.fetchAdd(1, .monotonic);
        }
    };
    Observer.count.store(0, .monotonic);
    try std.testing.expect(observeHandleRetire(Observer.on, null));
    defer _ = unobserveHandleRetire(Observer.on, null);
    var value: u8 = 0;
    const handle = try boxEntity(std.testing.allocator, &value, &value);
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer {
        for (threads[0..started]) |thread| thread.join();
        freeEntityBox(std.testing.allocator, handle);
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, retireEntityBox, .{handle});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    try std.testing.expect(isEntityBoxRetired(handle));
    try std.testing.expectEqual(@as(usize, 1), Observer.count.load(.acquire));
}
