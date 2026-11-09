const std = @import("std");
const cdr = @import("cdr.zig");
const framing = @import("cdr_framing.zig");
const PrimitiveWriter = @import("primitive_writer.zig").PrimitiveWriter;
const testing = std.testing;

const vectors = [_][2][]const u8{
    .{ "00010000017f0800013f004010000000a5000000000000000807060504030201000000008877665544332211017f08000000000000000000", "000000007f01000840003f0100000010a50000000000000001020304050607080000000011223344556677887f0100080000000000000000" },
    .{ "0007000001a500000807060504030201887766554433221100", "0006000001a500000102030405060708112233445566778800" },
};

fn sample(w: anytype) !void {
    try w.writeEncapHeader();
    const scope = try w.beginOptionalMember(0x3f01, true, true);
    defer w.cancelOptionalMember(scope);
    try w.writeU8(0xa5);
    try w.writeU64(0x0102030405060708);
    try w.finishOptionalMember(scope);
    try w.writeU64(0x1122334455667788);
    const absent = try w.beginOptionalMember(0, false, false);
    try w.finishOptionalMember(absent);
}

fn readSample(r: *cdr.CdrReader) !void {
    {
        var scope = try r.beginOptionalMember(0x3f01);
        defer scope.close();
        try testing.expect(scope.present);
        try testing.expectEqual(@as(u8, 0xa5), try r.readU8());
        try testing.expectEqual(@as(u64, 0x0102030405060708), try r.readU64());
    }
    try testing.expectEqual(@as(u64, 0x1122334455667788), try r.readU64());
    var absent = try r.beginOptionalMember(0);
    defer absent.close();
    try testing.expect(!absent.present);
}

test "optional native writers and readers match independent XCDR1 and XCDR2 bytes" {
    inline for (.{ cdr.XcdrVersion.xcdr1, cdr.XcdrVersion.xcdr2 }, 0..) |version, v| {
        for ([_]cdr.ByteOrder{ .little, .big }, 0..) |order, o| {
            var expected_buf: [80]u8 = undefined;
            const expected = try std.fmt.hexToBytes(&expected_buf, vectors[v][o]);
            var dynamic: std.ArrayListUnmanaged(u8) = .empty;
            defer dynamic.deinit(testing.allocator);
            const cap = if (version == .xcdr1) .eight else .four;
            var w = PrimitiveWriter.initDynamic(&dynamic, testing.allocator, cap, order);
            try sample(&w);
            try testing.expectEqualSlices(u8, expected, dynamic.items);
            var bytes: [80]u8 = undefined;
            w = PrimitiveWriter.initFixed(&bytes, cap, order);
            try sample(&w);
            try testing.expectEqualSlices(u8, expected, bytes[0..w.len]);
            w = PrimitiveWriter.initCounting(cap, order);
            try sample(&w);
            try testing.expectEqual(expected.len, w.len);
            try testing.expectEqual(expected.len - 4, w.pos);
            if (order == .little) {
                dynamic.clearRetainingCapacity();
                var legacy = cdr.CdrWriter(version).init(&dynamic, testing.allocator);
                try sample(&legacy);
                try testing.expectEqualSlices(u8, expected, dynamic.items);
            }
            var r = try cdr.CdrReader.init(expected);
            try readSample(&r);
            try testing.expectEqual(expected.len, r.pos);
            for (4..expected.len) |len| {
                r = try cdr.CdrReader.init(expected[0..len]);
                try testing.expectError(error.EndOfStream, readSample(&r));
                try testing.expectEqual(expected.ptr, r.data.ptr);
                try testing.expectEqual(len, r.data.len);
                try testing.expect(r.pos <= len);
            }
        }
    }
}

test "optional short header resets origin and bounds value reads" {
    var bytes: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, "00010000000008000807060504030201007f0000");
    var r = try cdr.CdrReader.init(&bytes);
    {
        var scope = try r.beginOptionalMember(0);
        defer scope.close();
        try testing.expect(scope.present);
        try testing.expectEqual(@as(u64, 0x0102030405060708), try r.readU64());
        try testing.expectError(error.EndOfStream, r.readU64());
    }
    var scope = try r.beginOptionalMember(0x3f00);
    defer scope.close();
    try testing.expect(!scope.present);
}

test "optional headers reject invalid IDs, flags, lengths and out of bounds values" {
    const invalid = [_][]const u8{
        "0001000001800000", // Implementation-specific short header.
        "00010000023f0000", // List-end is not an optional value.
        "00010000017f04000000000000000000", // Extended header length is eight.
        "00010000017f08000000008000000000", // Implementation-specific extended header.
        "0001000001000000", // Wrong member ID.
    };
    for (invalid) |hex| {
        var bytes: [40]u8 = undefined;
        var r = try cdr.CdrReader.init(try std.fmt.hexToBytes(&bytes, hex));
        try testing.expectError(error.InvalidOptionalHeader, r.beginOptionalMember(0));
    }
    var bytes: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, "00010000017f080000000000ffffffff");
    var r = try cdr.CdrReader.init(&bytes);
    try testing.expectError(error.EndOfStream, r.beginOptionalMember(0));
    // Readers accept PID_EXTENDED with either setting of the outer MU flag.
    bytes[5] = 0x3f;
    @memset(bytes[12..], 0);
    r = try cdr.CdrReader.init(&bytes);
    var scope = try r.beginOptionalMember(0);
    defer scope.close();
    try testing.expect(!scope.present);
}

test "optional exact lengths exceed the short header limit and restore on write errors" {
    var w = PrimitiveWriter.initCounting(.eight, .little);
    try w.writeEncapHeader();
    const scope = try w.beginOptionalMember(0x0fffffff, true, true);
    const bytes: [65537]u8 = @splat(0);
    try w.writeBytes(&bytes);
    try w.finishOptionalMember(scope);
    try testing.expectEqual(@as(usize, 12 + 65537), w.pos);
    try testing.expectEqual(@as(usize, 16 + 65537), w.len);
    var large: [65553]u8 = undefined;
    var large_writer = PrimitiveWriter.initFixed(&large, .eight, .little);
    try large_writer.writeEncapHeader();
    const large_scope = try large_writer.beginOptionalMember(0x0fffffff, false, true);
    try large_writer.writeBytes(&bytes);
    try large_writer.finishOptionalMember(large_scope);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 1, 0 }, large[12..16]);
    var fixed: [17]u8 = undefined;
    w = PrimitiveWriter.initFixed(&fixed, .eight, .little);
    try w.writeEncapHeader();
    const failed = try w.beginOptionalMember(1, false, true);
    try w.writeU8(42);
    try testing.expectError(error.Overflow, w.writeU64(99));
    w.cancelOptionalMember(failed);
    try testing.expectEqual(@as(usize, 13), w.pos);
    try testing.expectEqual(@as(usize, 17), w.len);
    var encoded: [20]u8 = @splat(0);
    try framing.finishOptional(&encoded, 19, .{ .length_offset = 12, .value_start = 16, .parent_pos = 12 }, .little);
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0 }, encoded[12..16]);
    try testing.expectError(error.InvalidPatch, framing.finishOptional(null, 20, .{ .length_offset = 19, .value_start = 16, .parent_pos = 12 }, .little));
    if (@bitSizeOf(usize) > 32) {
        try testing.expectError(error.Overflow, framing.finishOptional(null, @as(usize, std.math.maxInt(u32)) + 17, .{ .length_offset = 12, .value_start = 16, .parent_pos = 12 }, .little));
    }
}

test "nested optional scopes restore enclosing alignment and limits" {
    var bytes: [80]u8 = undefined;
    var w = PrimitiveWriter.initFixed(&bytes, .eight, .little);
    try w.writeEncapHeader();
    const outer = try w.beginOptionalMember(3, false, true);
    try w.writeU8(7);
    const inner = try w.beginOptionalMember(4, false, true);
    try w.writeU64(42);
    try w.finishOptionalMember(inner);
    try w.finishOptionalMember(outer);
    try w.writeU64(99);
    var r = try cdr.CdrReader.init(bytes[0..w.len]);
    {
        var a = try r.beginOptionalMember(3);
        defer a.close();
        try testing.expect(a.present);
        try testing.expectEqual(@as(u8, 7), try r.readU8());
        var b = try r.beginOptionalMember(4);
        defer b.close();
        try testing.expect(b.present);
        try testing.expectEqual(@as(u64, 42), try r.readU64());
        try testing.expectError(error.EndOfStream, r.readU64());
    }
    try testing.expectEqual(@as(u64, 99), try r.readU64());
    try testing.expectEqual(w.len, r.pos);
}
