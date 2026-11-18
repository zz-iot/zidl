//! Drives the C functions exportCAbi exports for
//! standalone.idl, through their C signatures.

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
extern fn S_Engine_destroy(self: *anyopaque) S.ReturnCode_t;
extern fn S_Engine_release(self: *anyopaque) void;
extern fn S_Engine_get_workers(self: *anyopaque) i32;
extern fn S_Engine_unpin(self: *anyopaque) S.ReturnCode_t;
extern fn S_Guard_create() H;
extern fn S_Guard_destroy(self: *anyopaque) S.ReturnCode_t;
extern fn S_Guard_as_S_Condition(self: *anyopaque) *anyopaque;
extern fn S_Condition_get_trigger_value(self: *anyopaque) bool;
extern fn S_Guard_set_trigger_value(self: *anyopaque, value: bool) S.ReturnCode_t;

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
    const c = S_Guard_as_S_Condition(g);
    try testing.expectEqual(g, c);
    try testing.expectEqual(S.RETCODE_OK, S_Guard_set_trigger_value(g, true));
    try testing.expect(S_Condition_get_trigger_value(c));
    try testing.expectEqual(S.RETCODE_OK, S_Guard_destroy(g));
    try expectStats(0, 1, 0);
}
