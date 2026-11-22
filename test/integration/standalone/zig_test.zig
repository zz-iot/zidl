//! Drives the C functions exportCAbi exports for
//! standalone.idl, through their C signatures, and the Zig statics and
//! constructors generated with `--zig-provider-module`.

const std = @import("std");
const zb = @import("zidl_bindings");
const provider = @import("provider");
const S = @import("standalone").S;

comptime {
    _ = provider;
}

const H = ?*anyopaque;
extern fn S_Engine_create() H;
extern fn S_Engine_create_with_allocator(allocator: ?*const zb.ZidlAllocator) H;
extern fn S_Engine_create_with(cfg: ?*const S.ConfigCAbi, pins: i32) H;
extern fn S_Engine_create_with_with_allocator(allocator: ?*const zb.ZidlAllocator, cfg: ?*const S.ConfigCAbi, pins: i32) H;
extern fn S_Engine_destroy(self: H) S.ReturnCode_t;
extern fn S_Engine_release(self: H) void;
extern fn S_Engine_get_workers(self: H) i32;
extern fn S_Engine_unpin(self: H) S.ReturnCode_t;
extern fn S_Guard_create() H;
extern fn S_Guard_destroy(self: H) S.ReturnCode_t;
extern fn S_Guard_as_S_Condition(self: H) H;
extern fn S_Condition_get_trigger_value(self: H) bool;
extern fn S_Guard_set_trigger_value(self: H, value: bool) S.ReturnCode_t;
extern fn S_Holder_create() H;
extern fn S_Holder_destroy(self: H) S.ReturnCode_t;
extern fn S_Holder_hold(self: H, cond: H) S.ReturnCode_t;
extern fn S_Holder_held(self: H) H;
extern fn S_Registry_get_instance() H;
extern fn S_Registry_delete_instance() S.ReturnCode_t;
extern fn S_Registry_is_trigger_set(cond: H) bool;
extern fn S_Registry_get_generation(self: H) i32;
extern fn S_Registry_pin(self: H, on: bool) S.ReturnCode_t;

const testing = std.testing;

fn expectStats(live: i32, destroys: i32, releases: i32) !void {
    const s = provider.test_stats();
    try testing.expectEqual(live, s.live);
    try testing.expectEqual(destroys, s.destroys);
    try testing.expectEqual(releases, s.releases);
}

test "a constructor's object is released by its destructor" {
    provider.test_stats_reset();
    const e = S_Engine_create().?;
    try expectStats(1, 0, 0);
    try testing.expectEqual(@as(i32, 1), S_Engine_get_workers(e));
    try testing.expectEqual(S.RETCODE_OK, S_Engine_destroy(e));
    try expectStats(0, 1, 0);
}

test "constructor arguments cross the C ABI, and a failed constructor returns null" {
    provider.test_stats_reset();
    var cfg: S.ConfigCAbi = .{ .workers = 3, .name = "pool" };
    const e = S_Engine_create_with(&cfg, 1).?;
    try testing.expectEqual(@as(i32, 3), S_Engine_get_workers(e));
    // The strict destroy refuses while pinned and leaves the object alone.
    try testing.expectEqual(S.RETCODE_PRECONDITION_NOT_MET, S_Engine_destroy(e));
    try expectStats(1, 0, 0);
    try testing.expectEqual(S.RETCODE_OK, S_Engine_unpin(e));
    try testing.expectEqual(S.RETCODE_OK, S_Engine_destroy(e));
    try expectStats(0, 1, 0);

    cfg.workers = 0;
    try testing.expect(S_Engine_create_with(&cfg, 0) == null);
    // A null struct argument means its IDL defaults (workers = 0 here).
    try testing.expect(S_Engine_create_with(null, 0) == null);
    try expectStats(0, 1, 0);
}

test "the finalizer releases an object its destructor would refuse" {
    provider.test_stats_reset();
    var cfg: S.ConfigCAbi = .{ .workers = 2 };
    const e = S_Engine_create_with(&cfg, 5).?;
    S_Engine_release(e);
    try expectStats(0, 0, 1);
}

const Counting = struct {
    allocs: usize = 0,
    frees: usize = 0,
    fail: bool = false,

    fn alloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx.?));
        if (self.fail) return null;
        self.allocs += 1;
        return std.heap.c_allocator.rawAlloc(len, .fromByteUnits(alignment), @returnAddress());
    }
    fn resize(ctx: ?*anyopaque, ptr: ?[*]u8, old_len: usize, new_len: usize, alignment: usize) callconv(.c) bool {
        _ = ctx;
        return std.heap.c_allocator.rawResize(ptr.?[0..old_len], .fromByteUnits(alignment), new_len, @returnAddress());
    }
    fn free(ctx: ?*anyopaque, ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void {
        const self: *Counting = @ptrCast(@alignCast(ctx.?));
        const p = ptr orelse return;
        self.frees += 1;
        std.heap.c_allocator.rawFree(p[0..len], .fromByteUnits(alignment), @returnAddress());
    }
    fn zidl(self: *Counting) zb.ZidlAllocator {
        return .{ .ctx = self, .alloc = alloc, .resize = resize, .free = free };
    }
};

test "the _with_allocator form allocates the object through the caller's allocator" {
    provider.test_stats_reset();
    var counting: Counting = .{};
    const za = counting.zidl();
    const e = S_Engine_create_with_allocator(&za).?;
    // The object, then its box once the export handed out a handle.
    try testing.expectEqual(@as(usize, 2), counting.allocs);
    S_Engine_release(e);
    try testing.expectEqual(@as(usize, 2), counting.frees);

    var cfg: S.ConfigCAbi = .{ .workers = 4 };
    counting.fail = true;
    try testing.expect(S_Engine_create_with_with_allocator(&za, &cfg, 0) == null);
    try expectStats(0, 0, 1);
}

test "a shared-box family member's constructor returns its family's one handle" {
    provider.test_stats_reset();
    const g = S_Guard_create().?;
    // Upcasting a shared box returns the same handle, not a second one.
    const c = S_Guard_as_S_Condition(g).?;
    try testing.expectEqual(g, c);
    try testing.expectEqual(S.RETCODE_OK, S_Guard_set_trigger_value(g, true));
    try testing.expect(S_Condition_get_trigger_value(c));
    try testing.expectEqual(S.RETCODE_OK, S_Guard_destroy(g));
    try expectStats(0, 1, 0);
}

test "a NULL object is the provider's nil" {
    provider.test_stats_reset();
    try testing.expectEqual(@as(i32, -1), S_Engine_get_workers(null));
    try testing.expectEqual(S.RETCODE_BAD_PARAMETER, S_Engine_destroy(null));
    try testing.expectEqual(S.RETCODE_BAD_PARAMETER, S_Engine_unpin(null));
    S_Engine_release(null);
    try testing.expect(!S_Condition_get_trigger_value(null));
    try testing.expectEqual(S.RETCODE_BAD_PARAMETER, S_Guard_set_trigger_value(null, true));
    try testing.expect(S_Holder_held(null) == null);
    try expectStats(0, 0, 0);
}

test "an upcast of NULL is NULL" {
    try testing.expect(S_Guard_as_S_Condition(null) == null);
}

test "a nil result goes out as NULL, and a NULL argument comes in as the nil" {
    provider.test_stats_reset();
    const h = S_Holder_create().?;
    // Nothing held yet: the provider's nil Condition.
    try testing.expect(S_Holder_held(h) == null);
    // The provider calls through the nil a NULL condition becomes.
    try testing.expectEqual(S.RETCODE_OK, S_Holder_hold(h, null));
    try testing.expect(S_Holder_held(h) == null);

    const g = S_Guard_create().?;
    const c = S_Guard_as_S_Condition(g).?;
    try testing.expectEqual(S.RETCODE_OK, S_Holder_hold(h, c));
    try testing.expectEqual(c, S_Holder_held(h).?);
    try testing.expectEqual(S.RETCODE_OK, S_Guard_destroy(g));
    try testing.expectEqual(S.RETCODE_OK, S_Holder_destroy(h));
    try expectStats(0, 2, 0);
}

test "a static returns the provider's singleton until delete_instance" {
    provider.test_stats_reset();
    try testing.expectEqual(S.RETCODE_OK, S_Registry_delete_instance());
    const r = S_Registry_get_instance().?;
    try testing.expectEqual(r, S_Registry_get_instance().?);
    try expectStats(1, 0, 0);
    const generation = S_Registry_get_generation(r);
    try testing.expectEqual(S.RETCODE_OK, S_Registry_pin(r, true));
    try testing.expectEqual(S.RETCODE_PRECONDITION_NOT_MET, S_Registry_delete_instance());
    try expectStats(1, 0, 0);
    try testing.expectEqual(S.RETCODE_OK, S_Registry_pin(r, false));
    try testing.expectEqual(S.RETCODE_OK, S_Registry_delete_instance());
    try expectStats(0, 1, 0);
    const next = S_Registry_get_instance().?;
    try testing.expectEqual(generation + 1, S_Registry_get_generation(next));
    try testing.expectEqual(S.RETCODE_OK, S_Registry_delete_instance());
    try expectStats(0, 2, 0);
}

test "a static's arguments cross the C ABI, NULL as the provider's nil" {
    provider.test_stats_reset();
    try testing.expect(!S_Registry_is_trigger_set(null));
    const g = S_Guard_create().?;
    try testing.expect(!S_Registry_is_trigger_set(S_Guard_as_S_Condition(g)));
    try testing.expectEqual(S.RETCODE_OK, S_Guard_set_trigger_value(g, true));
    try testing.expect(S_Registry_is_trigger_set(S_Guard_as_S_Condition(g)));
    try testing.expectEqual(S.RETCODE_OK, S_Guard_destroy(g));
}

// ── The Zig statics and constructors ───────────────────────────────────────

test "a Zig constructor calls the provider's, allocating through the given allocator" {
    provider.test_stats_reset();
    const e = try S.Engine.create(testing.allocator);
    try testing.expectEqual(@as(i32, 1), e.get_workers());
    try testing.expectEqual(S.RETCODE_OK, e.destroy());

    const pinned = try S.Engine.create_with(testing.allocator, .{ .workers = 3, .name = "pool" }, 1);
    try testing.expectEqual(@as(i32, 3), pinned.get_workers());
    try testing.expectEqual(S.RETCODE_PRECONDITION_NOT_MET, pinned.destroy());
    try testing.expectEqual(S.RETCODE_OK, pinned.unpin());
    try testing.expectEqual(S.RETCODE_OK, pinned.destroy());

    try testing.expectError(error.InvalidConfig, S.Engine.create_with(testing.allocator, .{}, 0));

    const g = try S.Guard.create(testing.allocator);
    try testing.expectEqual(S.RETCODE_OK, g.destroy());
    try expectStats(0, 3, 0);
}

test "a Zig static reaches the same singleton as the C function" {
    provider.test_stats_reset();
    try testing.expectEqual(S.RETCODE_OK, S.Registry.delete_instance());
    const r = S.Registry.get_instance();
    try testing.expectEqual(r.ptr, S.Registry.get_instance().ptr);
    try testing.expectEqual(r.vtable.get_c_abi_handle(r.ptr), S_Registry_get_instance().?);
    try expectStats(1, 0, 0);
    const generation = r.get_generation();
    try testing.expectEqual(S.RETCODE_OK, r.pin(true));
    try testing.expectEqual(S.RETCODE_PRECONDITION_NOT_MET, S.Registry.delete_instance());
    try testing.expectEqual(S.RETCODE_OK, r.pin(false));
    try testing.expectEqual(S.RETCODE_OK, S.Registry.delete_instance());
    try expectStats(0, 1, 0);
    const next = S.Registry.get_instance();
    try testing.expectEqual(generation + 1, next.get_generation());
    try testing.expectEqual(S.RETCODE_OK, S.Registry.delete_instance());
    try expectStats(0, 2, 0);
}

test "a Zig static's interface argument reaches the provider" {
    provider.test_stats_reset();
    const g = try S.Guard.create(testing.allocator);
    try testing.expect(!S.Registry.is_trigger_set(g.as_Condition()));
    try testing.expectEqual(S.RETCODE_OK, g.set_trigger_value(true));
    try testing.expect(S.Registry.is_trigger_set(g.as_Condition()));
    try testing.expectEqual(S.RETCODE_OK, g.destroy());
}
