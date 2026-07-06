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

/// Free a box previously created by `boxEntity`. Does not touch whatever
/// `box.ptr` refers to — that's the concrete entity implementation's own
/// lifetime, freed separately by the native `deinit`/delete path.
pub fn freeEntityBox(alloc: std.mem.Allocator, handle: *anyopaque) void {
    const box: *EntityBox = @ptrCast(@alignCast(handle));
    alloc.destroy(box);
}
