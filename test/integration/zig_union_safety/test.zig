// Compile-and-run regression test for the union deinit/error-safety fix.
//
// Before the fix, generated union `deserializeInto` wrote the new
// discriminant into `out._d` before decoding the case payload into `out._u`.
// A truncated/malformed payload could then fail mid-case-decode, leaving
// `out._d` pointing at a heap-owning case whose `out._u` storage was still
// Zig `undefined` (unions have no per-field safe default the way struct
// members do). The `errdefer out.deinit(allocator)` added in the same PR
// would then free that undefined memory — a real invalid-free / memory
// corruption, not just a leak. The fix: decode the discriminant into a local
// and only commit `out._d` once the whole function is about to succeed, so a
// mid-decode failure never leaves `out._d` pointing at a case `out._u`
// doesn't actually hold.

const std = @import("std");
const testing = std.testing;
const zidl_rt = @import("zidl_rt");
const fixture = @import("fixture");

fn truncatedEncoding(comptime T: type, value: T, chop: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try T.serialize(&writer, value);
    const full = try buf.toOwnedSlice(testing.allocator);
    errdefer testing.allocator.free(full);
    try testing.expect(full.len > chop);
    const truncated = try testing.allocator.dupe(u8, full[0 .. full.len - chop]);
    testing.allocator.free(full);
    return truncated;
}

test "FinalStrUnion: truncated string case leaves _d at its safe default, deinit is a no-op" {
    const payload = try truncatedEncoding(fixture.FinalStrUnion, .{ ._d = 99, ._u = .{ .s = "hello world" } }, 4);
    defer testing.allocator.free(payload);

    var reader = try zidl_rt.CdrReader.init(payload);
    var out: fixture.FinalStrUnion = .{};
    try testing.expectError(
        error.EndOfStream,
        fixture.FinalStrUnion.deserializeInto(&out, &reader, testing.allocator),
    );

    // The discriminant must still be the untouched default (0 => the
    // non-owning `i` case) -- not 99, which would point `deinit()` at the
    // `s` case whose `_u` storage was never actually written.
    try testing.expectEqual(@as(i32, 0), out._d);
    out.deinit(testing.allocator); // must not crash (testing.allocator would catch an invalid free)
}

test "MutableStrUnion: truncated string case leaves _d at its safe default, deinit is a no-op" {
    const payload = try truncatedEncoding(fixture.MutableStrUnion, .{ ._d = 1, ._u = .{ .s = "hello world" } }, 4);
    defer testing.allocator.free(payload);

    var reader = try zidl_rt.CdrReader.init(payload);
    var out: fixture.MutableStrUnion = .{};
    try testing.expectError(
        error.EndOfStream,
        fixture.MutableStrUnion.deserializeInto(&out, &reader, testing.allocator),
    );

    try testing.expectEqual(@as(i32, 0), out._d);
    out.deinit(testing.allocator);
}

test "MutableStrUnion: a payload published earlier in the EMHEADER loop survives a later, unrelated read failure" {
    // Regression for a second review round: committing `out._d` only once,
    // after the whole EMHEADER loop finishes, left it stale relative to an
    // `out._u` an *earlier* iteration already published -- so a *later*
    // iteration's failure would leak that payload (or, worse, free it
    // through whatever case the stale discriminant happened to select). The
    // fix commits `out._d` atomically with `out._u`, inside the same case
    // arm, so it never lags behind a real publish.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try fixture.MutableStrUnion.serialize(&writer, .{ ._d = 1, ._u = .{ .s = "hello world" } });

    // Corrupt the DHEADER (the 4 bytes right after the 4-byte encap header)
    // to claim 4 more bytes of payload than actually follow, then append 4
    // bytes that always decode as an invalid EMHEADER (`lc == 7`). This
    // forces a THIRD loop iteration to fail *after* the real discriminant
    // and case-value EMHEADERs (iterations 1-2) already ran and published to
    // out._d/out._u.
    var declared: u32 = std.mem.readInt(u32, buf.items[4..8], .little);
    declared += 4;
    std.mem.writeInt(u32, buf.items[4..8], declared, .little);
    try buf.appendSlice(testing.allocator, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF });

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var out: fixture.MutableStrUnion = .{};
    try testing.expectError(
        error.InvalidEmheader,
        fixture.MutableStrUnion.deserializeInto(&out, &reader, testing.allocator),
    );

    // `deserializeInto`'s own internal `errdefer out.deinit(allocator)` has
    // already run by the time it returns the error -- so `out._u.s` is
    // already freed and reset to `""` (that's the self-cleaning contract
    // from the first review round), which is why this test does NOT assert
    // its content. What it does prove: `out._d` still reads 1 (`deinit()`
    // never resets the discriminant, only the payload it owns) -- if the
    // pre-fix bug were present, `out._d` would have stayed at its stale
    // pre-loop default (0) when the internal errdefer fired, so `deinit()`
    // would have cleaned the non-owning `i` arm instead and silently leaked
    // "hello world". `testing.allocator` is a leak-checking allocator: this
    // whole test fails at teardown if that leak happens, without needing to
    // inspect `out._u.s` directly.
    try testing.expectEqual(@as(i32, 1), out._d);
    out.deinit(testing.allocator); // idempotent no-op -- proves it, doesn't need to
}

test "FinalStrUnion: successful decode of the string case still round-trips and deinits cleanly" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try fixture.FinalStrUnion.serialize(&writer, .{ ._d = 99, ._u = .{ .s = "hello world" } });

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var out: fixture.FinalStrUnion = .{};
    try fixture.FinalStrUnion.deserializeInto(&out, &reader, testing.allocator);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 99), out._d);
    try testing.expectEqualStrings("hello world", out._u.s);
}
