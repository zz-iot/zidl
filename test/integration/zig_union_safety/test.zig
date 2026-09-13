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
