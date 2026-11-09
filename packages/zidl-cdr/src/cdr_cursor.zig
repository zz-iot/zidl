//! Checked cursor operations shared by the native reader and C ABI adapter.
const std = @import("std");

pub fn advance(pos: *usize, len: usize, count: usize) error{EndOfStream}!usize {
    if (pos.* > len or count > len - pos.*) return error.EndOfStream;
    const start = pos.*;
    pos.* += count;
    return start;
}

pub fn readSlice(data: []const u8, pos: *usize, count: usize) error{EndOfStream}![]const u8 {
    const start = try advance(pos, data.len, count);
    return data[start..pos.*];
}

/// Match the existing C reader's partial progress on truncated padding: clamp
/// to the input end, then report truncation. Never subtract an invalid origin.
pub fn alignPosition(pos: *usize, len: usize, origin: usize, boundary: usize) error{EndOfStream}!void {
    if (pos.* > len or pos.* < origin or boundary == 0) return error.EndOfStream;
    const rem = (pos.* - origin) % boundary;
    const pad = if (rem == 0) 0 else boundary - rem;
    if (pad > len - pos.*) {
        pos.* = len;
        return error.EndOfStream;
    }
    pos.* += pad;
}

pub fn seek(pos: *usize, len: usize, target: usize) error{EndOfStream}!void {
    if (target > len) return error.EndOfStream;
    pos.* = target;
}

pub fn skipPrimitives(pos: *usize, len: usize, origin: usize, count: usize, wire_size: usize, alignment_cap: usize) error{ EndOfStream, InvalidPrimitiveSize }!void {
    // An empty sequence has no leading element padding.
    if (count == 0) return;
    switch (wire_size) {
        1, 2, 4, 8 => {},
        else => return error.InvalidPrimitiveSize,
    }
    if (wire_size > 1) try alignPosition(pos, len, origin, @min(wire_size, alignment_cap));
    const bytes = std.math.mul(usize, count, wire_size) catch return error.EndOfStream;
    _ = try advance(pos, len, bytes);
}

test "cursor arithmetic near SIZE_MAX never wraps, including alignment padding" {
    const max = std.math.maxInt(usize);
    var pos: usize = max - 1;
    try std.testing.expectError(error.EndOfStream, advance(&pos, max, 2));
    try std.testing.expectEqual(max - 1, pos);
    try std.testing.expectError(error.EndOfStream, alignPosition(&pos, max, 4, 8));
    try std.testing.expectEqual(max, pos);
    pos = 4;
    try std.testing.expectError(error.EndOfStream, skipPrimitives(&pos, max, 4, max, 8, 8));
    try std.testing.expectEqual(@as(usize, 4), pos);
}
