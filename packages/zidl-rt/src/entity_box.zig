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

/// Allocate a box holding `ptr`/`vtable` and return it as an opaque C-ABI handle.
pub fn boxEntity(alloc: std.mem.Allocator, ptr: *anyopaque, vtable: *const anyopaque) !*anyopaque {
    const box = try alloc.create(EntityBox);
    box.* = .{ .ptr = ptr, .vtable = vtable };
    return @ptrCast(box);
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
    notifyHandleRetired(handle);
    const box: *EntityBox = @ptrCast(@alignCast(handle));
    alloc.destroy(box);
}

// ── Handle-retire observers ───────────────────────────────────────────────────
//
// The provider side of zidl's handle-retire contract
// (zidl/docs/design/handle-lifetime.md). A language binding that caches one
// wrapper per C-ABI handle registers an observer; every handle this runtime
// frees is reported to every observer before its memory is released.
//
// A fixed table rather than a list, because this package has no mutex: a slot
// is claimed with a CAS, and a notification counts itself in `active` so that
// removing an observer can wait for calls already under way.

/// Called with the observer's own context and the handle being retired. Runs
/// on whatever thread frees the handle, possibly concurrently with other
/// calls. It must not call back into the provider, block, or run application
/// code; it may take the binding's own short internal locks.
pub const HandleRetiredFn = *const fn (ctx: ?*anyopaque, handle: *anyopaque) callconv(.c) void;

/// Most observers one runtime instance accepts. One per binding per IDL file
/// is the expected use, so a handful.
pub const max_handle_retire_observers = 16;

const Slot = struct {
    /// 0 free, 1 being changed, 2 live.
    state: std.atomic.Value(u8) = .init(0),
    func: ?HandleRetiredFn = null,
    ctx: ?*anyopaque = null,
};

var observer_slots: [max_handle_retire_observers]Slot = @splat(.{});
var active_notifications: std.atomic.Value(u32) = .init(0);

/// Registers `func`/`ctx` as a handle-retire observer. Returns false if the
/// table is full. Registering the same pair twice gets two notifications.
pub fn observeHandleRetire(func: HandleRetiredFn, ctx: ?*anyopaque) bool {
    for (&observer_slots) |*slot| {
        if (slot.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            slot.func = func;
            slot.ctx = ctx;
            slot.state.store(2, .release);
            return true;
        }
    }
    return false;
}

/// Removes one registration of `func`/`ctx`, then waits for notifications
/// already under way to finish, so the observer is not running when this
/// returns. Must not be called from inside an observer. Returns false if the
/// pair was not registered.
pub fn unobserveHandleRetire(func: HandleRetiredFn, ctx: ?*anyopaque) bool {
    for (&observer_slots) |*slot| {
        if (slot.state.load(.acquire) != 2) continue;
        if (slot.func != func or slot.ctx != ctx) continue;
        if (slot.state.cmpxchgStrong(2, 1, .acquire, .monotonic) != null) continue;
        while (active_notifications.load(.acquire) != 0) std.atomic.spinLoopHint();
        slot.func = null;
        slot.ctx = null;
        slot.state.store(0, .release);
        return true;
    }
    return false;
}

/// Reports `handle` to every observer. `freeEntityBox` calls this; a provider
/// that retires handles some other way (its own boxes, or reusing a handle's
/// address for a different object) must call it before the address can name
/// anything else.
pub fn notifyHandleRetired(handle: *anyopaque) void {
    _ = active_notifications.fetchAdd(1, .acq_rel);
    defer _ = active_notifications.fetchSub(1, .acq_rel);
    for (&observer_slots) |*slot| {
        if (slot.state.load(.acquire) != 2) continue;
        if (slot.func) |f| f(slot.ctx, handle);
    }
}

/// Exports the C entry points a binding generated with
/// `--handle-retire-hook=<name>` links against:
///
///     int  <name>_observe(void (*fn)(void *ctx, void *handle), void *ctx);
///     int  <name>_unobserve(void (*fn)(void *ctx, void *handle), void *ctx);
///
/// Both return 0 on success, nonzero otherwise. Call from a `comptime` block
/// in the library that owns this runtime instance, so the observers it
/// registers see that instance's frees: `comptime { zidl_rt.exportHandleRetireHook("mylib_handle_retire"); }`.
pub fn exportHandleRetireHook(comptime name: []const u8) void {
    const S = struct {
        fn observe(func: ?HandleRetiredFn, ctx: ?*anyopaque) callconv(.c) c_int {
            const f = func orelse return 1;
            return if (observeHandleRetire(f, ctx)) 0 else 1;
        }
        fn unobserve(func: ?HandleRetiredFn, ctx: ?*anyopaque) callconv(.c) c_int {
            const f = func orelse return 1;
            return if (unobserveHandleRetire(f, ctx)) 0 else 1;
        }
    };
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

test "the observer table rejects registrations once full" {
    const Noop = struct {
        fn on(_: ?*anyopaque, _: *anyopaque) callconv(.c) void {}
    };
    var i: usize = 0;
    while (i < max_handle_retire_observers) : (i += 1) {
        try std.testing.expect(observeHandleRetire(&Noop.on, @ptrFromInt(i + 1)));
    }
    try std.testing.expect(!observeHandleRetire(&Noop.on, @ptrFromInt(0x99)));
    i = 0;
    while (i < max_handle_retire_observers) : (i += 1) {
        try std.testing.expect(unobserveHandleRetire(&Noop.on, @ptrFromInt(i + 1)));
    }
}
