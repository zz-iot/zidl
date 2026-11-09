//! Generated-binding support: ownership, entity handles, allocator adapters and authoring.
const std = @import("std");
pub const allocator = @import("allocator.zig");
pub const entity_box = @import("entity_box.zig");
pub const owned = @import("owned.zig");
pub const authoring = @import("authoring.zig");
pub const EntityBox = entity_box.EntityBox;
pub const boxEntity = entity_box.boxEntity;
pub const unboxEntity = entity_box.unboxEntity;
pub const unboxAs = entity_box.unboxAs;
pub const unboxAsView = entity_box.unboxAsView;
pub const retireEntityBox = entity_box.retireEntityBox;
pub const isEntityBoxRetired = entity_box.isEntityBoxRetired;
pub const freeEntityBox = entity_box.freeEntityBox;
pub const HandleRetiredFn = entity_box.HandleRetiredFn;
pub const observeHandleRetire = entity_box.observeHandleRetire;
pub const unobserveHandleRetire = entity_box.unobserveHandleRetire;
pub const notifyHandleRetired = entity_box.notifyHandleRetired;
pub const exportHandleRetireHook = entity_box.exportHandleRetireHook;
pub const NIL_PTR = entity_box.NIL_PTR;
pub const ZidlAllocator = allocator.ZidlAllocator;
pub const toAllocator = allocator.toAllocator;
pub const SeqElem = owned.SeqElem;
pub const deinitOwned = owned.deinitOwned;
pub const cloneOwned = owned.cloneOwned;

test {
    std.testing.refAllDecls(@This());
}
