//! Canonical-key wire helpers. Schema projection and type-size policy are
//! supplied by generated code; byte-only compatibility APIs retain their policy.
const std = @import("std");
const strings = @import("cdr_strings.zig");

pub fn useMd5(force_md5: bool, encoded_len: usize) bool {
    return force_md5 or encoded_len > 16;
}

pub fn hash(bytes: []const u8, force_md5: bool) [16]u8 {
    var result: [16]u8 = @splat(0);
    if (useMd5(force_md5, bytes.len)) {
        std.crypto.hash.Md5.hash(bytes, &result, .{});
    } else {
        @memcpy(result[0..bytes.len], bytes);
    }
    return result;
}

/// PLAIN_CDR2 String<Char16>: byte count, UTF-16 code units, no NUL/BOM.
pub fn writeWstringLength(sink: anytype, len: usize) !void {
    try strings.writeWstringLength(sink, len);
}

pub fn writeWstring(sink: anytype, value: []const u16) !void {
    try strings.writeWstring(sink, value);
}

test "type policy hashes short values when the key holder can exceed sixteen bytes" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 5, 'B', 'L', 'U', 'E', 0 };
    try std.testing.expectEqualSlices(u8, &.{ 0x37, 0x4b, 0x96, 0xe2, 0xe7, 0x27, 0x23, 0x7f, 0x01, 0x6c, 0xc4, 0xce, 0xbb, 0x6e, 0xb7, 0x1e }, &hash(&bytes, true));
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 5, 'B', 'L', 'U', 'E', 0, 0, 0, 0 }, &hash(&bytes, false));
}
