const std = @import("std");
const rt = @import("root.zig");
const fixed = @import("cdr_fixed.zig");
const vectors = @import("fixed_test_cases.zig");
const testing = std.testing;

fn bits(value: f64) u64 {
    return @bitCast(value);
}

test "fixed independent bytes cover rounding, saturation and all 31 digits" {
    for (vectors.cases) |v| {
        var expected_buf: [16]u8 = undefined;
        const expected = try std.fmt.hexToBytes(&expected_buf, v.hex);
        for ([_]rt.ByteOrder{ .little, .big }) |order| {
            var dynamic: std.ArrayListUnmanaged(u8) = .empty;
            defer dynamic.deinit(testing.allocator);
            var bytes: [16]u8 = undefined;
            for (0..3) |mode| {
                var w = switch (mode) {
                    0 => rt.PrimitiveWriter.initFixed(&bytes, .eight, order),
                    1 => rt.PrimitiveWriter.initCounting(.four, order),
                    else => rt.PrimitiveWriter.initDynamic(&dynamic, testing.allocator, .four, order),
                };
                try fixed.write(&w, v.digits, v.scale, v.value);
                try testing.expectEqual(expected.len, w.len);
                try testing.expectEqual(expected.len, w.pos);
                if (mode == 0) try testing.expectEqualSlices(u8, expected, bytes[0..w.len]);
                if (mode == 2) try testing.expectEqualSlices(u8, expected, dynamic.items);
            }
        }
        var pos: usize = 0;
        try testing.expectEqual(bits(v.decoded), bits(try fixed.read(expected, &pos, v.digits, v.scale)));
        try testing.expectEqual(expected.len, pos);
        for (0..expected.len) |n| {
            pos = 0;
            try testing.expectError(error.EndOfStream, fixed.read(expected[0..n], &pos, v.digits, v.scale));
            try testing.expectEqual(@as(usize, 0), pos);
            var w = rt.PrimitiveWriter.initFixed(expected_buf[0..n], .four, .little);
            try testing.expectError(error.Overflow, fixed.write(&w, v.digits, v.scale, v.value));
            try testing.expectEqual(@as(usize, 0), w.len);
        }
    }
    for (vectors.read_cases) |v| {
        var bytes: [16]u8 = undefined;
        const input = try std.fmt.hexToBytes(&bytes, v.hex);
        var pos: usize = 0;
        try testing.expectEqual(bits(v.decoded), bits(try fixed.read(input, &pos, v.digits, v.scale)));
    }
}

test "fixed wrappers use the shared codec, including key hashes and unaligned values" {
    var bytes: [32]u8 = undefined;
    var w = rt.PrimitiveWriter.initFixed(&bytes, .eight, .big);
    try w.writeU8(42);
    try w.writeFixed(31, 0, 1e30);
    try testing.expectEqual(@as(usize, 17), w.len);
    var expected: [16]u8 = undefined;
    // 1e30's exact binary64 integer, expressed as decimal BCD.
    _ = try std.fmt.hexToBytes(&expected, "1000000000000000019884624838656c");
    try testing.expectEqualSlices(u8, &expected, bytes[1..17]);
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    var legacy = rt.CdrWriter(.xcdr1).init(&buffer, testing.allocator);
    try legacy.writeEncapHeader();
    try legacy.writeFixed(31, 0, 1e30);
    var reader = try rt.CdrReader.init(buffer.items);
    try testing.expectEqual(bits(1e30), bits(try reader.readFixed(31, 0)));
    try testing.expectEqualSlices(u8, &expected, buffer.items[4..]);
    var key = rt.KeyHashWriter.init();
    try key.writeFixed(31, 0, 1e30);
    try testing.expectEqual(expected, key.finalForType(false));
}

test "fixed rejects invalid parameters, digits, signs, padding and NaN" {
    var bytes: [16]u8 = @splat(0);
    var w = rt.PrimitiveWriter.initFixed(&bytes, .four, .little);
    for ([_][2]u8{ .{ 0, 0 }, .{ 32, 0 }, .{ 255, 255 }, .{ 3, 4 } }) |shape| {
        var pos: usize = 0;
        try testing.expectError(error.InvalidFixedPtParameters, fixed.write(&w, shape[0], shape[1], 1));
        try testing.expectError(error.InvalidFixedPtParameters, fixed.read(&bytes, &pos, shape[0], shape[1]));
        try testing.expectEqual(@as(usize, 0), pos);
    }
    try testing.expectError(error.InvalidFixedPtValue, fixed.write(&w, 1, 0, std.math.nan(f64)));
    try testing.expectEqual(@as(usize, 0), w.len);
    var invalid_pos: usize = std.math.maxInt(usize);
    try testing.expectError(error.EndOfStream, fixed.read(&bytes, &invalid_pos, 31, 0));
    var count = rt.PrimitiveWriter.initCounting(.eight, .little);
    count.len = std.math.maxInt(usize) - 1;
    count.pos = count.len;
    try testing.expectError(error.Overflow, fixed.write(&count, 31, 0, 1));
    try testing.expectEqual(std.math.maxInt(usize) - 1, count.len);
    for (0..16) |sign| {
        if (sign == 0xc or sign == 0xd) continue;
        bytes[0] = @intCast(0x10 | sign);
        var pos: usize = 0;
        try testing.expectError(error.InvalidFixedPtSign, fixed.read(bytes[0..1], &pos, 1, 0));
        try testing.expectEqual(@as(usize, 1), pos);
    }
    bytes[0] = 0xac;
    var pos: usize = 0;
    try testing.expectError(error.InvalidFixedPtDigit, fixed.read(bytes[0..1], &pos, 1, 0));
    bytes[0] = 0x11;
    bytes[1] = 0x2c;
    pos = 0;
    try testing.expectError(error.InvalidFixedPtPadding, fixed.read(bytes[0..2], &pos, 2, 0));
}
