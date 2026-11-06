//! Shared wire operations; storage and errors belong to the sink.
//! Keep padding separate so fixed-buffer failures preserve cursor behavior.

const cursor = @import("cdr_cursor.zig");

pub fn writeUnsigned(sink: anytype, comptime T: type, value: T, pos: usize, alignment_cap: usize, order: ByteOrder) !void {
    const size = @sizeOf(T);
    const boundary = @min(size, alignment_cap);
    const pad = (boundary - pos % boundary) % boundary;
    const zeros: [8]u8 = @splat(0);
    if (pad != 0) try sink.writeBytes(zeros[0..pad]);
    const bytes = encodeUnsigned(T, value, order);
    try sink.writeBytes(&bytes);
}

pub fn encodeUnsigned(comptime T: type, value: T, order: ByteOrder) [@sizeOf(T)]u8 {
    const size = @sizeOf(T);
    var bytes: [size]u8 = undefined;
    inline for (0..size) |i| {
        const shift: usize = if (order == .little) i else size - 1 - i;
        bytes[i] = @truncate(value >> @intCast(shift * 8));
    }
    return bytes;
}

pub fn readUnsigned(comptime T: type, data: []const u8, pos: *usize, origin: usize, alignment_cap: usize, order: ByteOrder) error{EndOfStream}!T {
    const size = @sizeOf(T);
    if (size > 1) try cursor.alignPosition(pos, data.len, origin, @min(size, alignment_cap));
    const bytes = try cursor.readSlice(data, pos, size);
    var value: T = 0;
    inline for (0..size) |i| {
        const shift: usize = if (order == .little) i else size - 1 - i;
        value |= @as(T, bytes[i]) << @intCast(shift * 8);
    }
    return value;
}

pub fn readBool(data: []const u8, pos: *usize) error{ EndOfStream, InvalidBool }!bool {
    const value = try readUnsigned(u8, data, pos, 0, 1, .little);
    if (value > 1) return error.InvalidBool;
    return value == 1;
}
