//! Compatibility umbrella for zidl-cdr and zidl-bindings.
const std = @import("std");
pub const EntityBox = @import("zidl_bindings").EntityBox;
pub const boxEntity = @import("zidl_bindings").boxEntity;
pub const unboxEntity = @import("zidl_bindings").unboxEntity;
pub const unboxAs = @import("zidl_bindings").unboxAs;
pub const unboxAsView = @import("zidl_bindings").unboxAsView;
pub const retireEntityBox = @import("zidl_bindings").retireEntityBox;
pub const isEntityBoxRetired = @import("zidl_bindings").isEntityBoxRetired;
pub const freeEntityBox = @import("zidl_bindings").freeEntityBox;
pub const HandleRetiredFn = @import("zidl_bindings").HandleRetiredFn;
pub const observeHandleRetire = @import("zidl_bindings").observeHandleRetire;
pub const unobserveHandleRetire = @import("zidl_bindings").unobserveHandleRetire;
pub const notifyHandleRetired = @import("zidl_bindings").notifyHandleRetired;
pub const exportHandleRetireHook = @import("zidl_bindings").exportHandleRetireHook;
pub const NIL_PTR = @import("zidl_bindings").NIL_PTR;
pub const ZidlAllocator = @import("zidl_bindings").ZidlAllocator;
pub const toAllocator = @import("zidl_bindings").toAllocator;
pub const XcdrVersion = @import("zidl_cdr").XcdrVersion;
pub const ByteOrder = @import("zidl_cdr").ByteOrder;
pub const cdr_primitives = @import("zidl_cdr").cdr_primitives;
pub const cdr_cursor = @import("zidl_cdr").cdr_cursor;
pub const cdr_strings = @import("zidl_cdr").cdr_strings;
pub const cdr_framing = @import("zidl_cdr").cdr_framing;
pub const PrimitiveWriter = @import("zidl_cdr").PrimitiveWriter;
pub const CdrWriter = @import("zidl_cdr").CdrWriter;
pub const CdrReader = @import("zidl_cdr").CdrReader;
pub const BoundedArray = @import("zidl_cdr").BoundedArray;
pub const authoring = @import("zidl_bindings").authoring;
pub const SeqElem = @import("zidl_bindings").SeqElem;
pub const deinitOwned = @import("zidl_bindings").deinitOwned;
pub const cloneOwned = @import("zidl_bindings").cloneOwned;
pub const KeyHashWriter = @import("zidl_cdr").KeyHashWriter;
pub const PlCdrWriter = @import("zidl_cdr").PlCdrWriter;
pub const PlMode = @import("zidl_cdr").PlMode;
pub const PlParam = @import("zidl_cdr").PlParam;
pub const RawParam = @import("zidl_cdr").RawParam;
pub const ENCAP_CDR1_LE = @import("zidl_cdr").ENCAP_CDR1_LE;
pub const ENCAP_CDR1_BE = @import("zidl_cdr").ENCAP_CDR1_BE;
pub const ENCAP_CDR2_LE = @import("zidl_cdr").ENCAP_CDR2_LE;
pub const ENCAP_CDR2_BE = @import("zidl_cdr").ENCAP_CDR2_BE;
pub const ENCAP_PL_CDR_LE = @import("zidl_cdr").ENCAP_PL_CDR_LE;
pub const ENCAP_PL_CDR_BE = @import("zidl_cdr").ENCAP_PL_CDR_BE;
pub const cdr_keys = @import("zidl_cdr").cdr_keys;
pub const cdr_fixed = @import("zidl_cdr").cdr_fixed;

test {
    std.testing.refAllDecls(@This());
}

test "compatibility aliases preserve canonical types" {
    const codec = @import("zidl_cdr");
    const bindings = @import("zidl_bindings");
    inline for (.{ "CdrReader", "PrimitiveWriter", "KeyHashWriter", "PlCdrWriter", "RawParam", "ByteOrder", "XcdrVersion" }) |name| {
        try std.testing.expect(@field(@This(), name) == @field(codec, name));
    }
    try std.testing.expect(CdrWriter(.xcdr1) == codec.CdrWriter(.xcdr1));
    try std.testing.expect(CdrWriter(.xcdr2) == codec.CdrWriter(.xcdr2));
    try std.testing.expect(BoundedArray(u8, 7) == codec.BoundedArray(u8, 7));
    try std.testing.expect(NIL_PTR == bindings.NIL_PTR);
    try std.testing.expect(EntityBox == bindings.EntityBox);
    try std.testing.expect(ZidlAllocator == bindings.ZidlAllocator);
    try std.testing.expect(authoring.Spec == bindings.authoring.Spec);
}

test "compatibility aliases share the canonical handle registry" {
    const bindings = @import("zidl_bindings");
    const Observer = struct {
        fn notify(ctx: ?*anyopaque, _: *anyopaque) callconv(.c) void {
            const count: *usize = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    };
    var count: usize = 0;
    var object: u8 = 0;
    const handle = try boxEntity(std.testing.allocator, @ptrCast(&object), @ptrCast(&object));
    defer freeEntityBox(std.testing.allocator, handle);
    try std.testing.expect(observeHandleRetire(Observer.notify, &count));
    defer _ = bindings.unobserveHandleRetire(Observer.notify, &count);
    bindings.retireEntityBox(handle);
    try std.testing.expect(isEntityBoxRetired(handle));
    retireEntityBox(handle);
    try std.testing.expectEqual(@as(usize, 1), count);
}
