//! String wire mechanics. Allocation and owned C-string policy stay in adapters.
const std = @import("std");
const primitives = @import("cdr_primitives.zig");
const cursor = @import("cdr_cursor.zig");

pub fn wireLength(content_len: usize) error{Overflow}!u32 {
    if (content_len >= std.math.maxInt(u32)) return error.Overflow;
    return @intCast(content_len + 1);
}

pub fn wideWireBytes(content_len: usize) error{Overflow}!usize {
    if (content_len > std.math.maxInt(u32) / 2) return error.Overflow;
    return content_len * 2;
}

pub fn writeString(sink: anytype, value: []const u8) !void {
    const count = try wireLength(value.len);
    try sink.writeU32(count);
    if (value.len != 0) try sink.writeBytes(value);
    try sink.writeBytes(&.{0});
}

pub fn writeWstringLength(sink: anytype, len: usize) !void {
    try sink.writeU32(@intCast(try wideWireBytes(len)));
}

pub fn writeWstring(sink: anytype, value: []const u16) !void {
    try writeWstringLength(sink, value.len);
    for (value) |wc| try sink.writeU16(wc);
}

pub fn readString(data: []const u8, pos: *usize, cap: usize, order: primitives.ByteOrder) error{ EndOfStream, InvalidString }![]const u8 {
    const count = try primitives.readUnsigned(u32, data, pos, 4, cap, order);
    if (count == 0) return error.InvalidString;
    const bytes = try cursor.readSlice(data, pos, count);
    if (bytes[bytes.len - 1] != 0) return error.InvalidString;
    return bytes[0 .. bytes.len - 1];
}

/// Validated borrowed UTF-16 wire bytes, without a terminator. This view never casts
/// input bytes to u16 pointers, so physically unaligned input is supported.
pub const WstringView = struct {
    encoded: []const u8,
    order: primitives.ByteOrder,

    pub fn len(self: WstringView) usize {
        return self.encoded.len / 2;
    }

    pub fn codeUnit(self: WstringView, index: usize) u16 {
        std.debug.assert(index < self.len());
        var pos = index * 2;
        return primitives.readUnsigned(u16, self.encoded, &pos, 0, 2, self.order) catch unreachable;
    }
};

pub fn readWstring(data: []const u8, pos: *usize, cap: usize, order: primitives.ByteOrder) error{ EndOfStream, InvalidString }!WstringView {
    const count = try primitives.readUnsigned(u32, data, pos, 4, cap, order);
    if (count % 2 != 0) return error.InvalidString;
    const bytes = try cursor.readSlice(data, pos, count);
    return .{ .encoded = bytes, .order = order };
}

test "string count and wide byte sizing reject overflow before writing or slicing" {
    const testing = std.testing;
    try testing.expectError(error.Overflow, wireLength(std.math.maxInt(u32)));
    try testing.expectError(error.Overflow, wireLength(std.math.maxInt(usize)));
    try testing.expectEqual(@as(u32, 1), try wireLength(0));
    try testing.expectEqual(@as(usize, 0), try wideWireBytes(0));
    try testing.expectEqual(@as(usize, 0xfffffffe), try wideWireBytes(0x7fffffff));
    try testing.expectError(error.Overflow, wideWireBytes(0x80000000));
}
