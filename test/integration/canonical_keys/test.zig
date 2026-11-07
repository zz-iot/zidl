const std = @import("std");
const rt = @import("zidl_rt");
const C = @import("fixture").Canonical;
const testing = std.testing;

const Vector = struct { bytes: []u8, hash: [16]u8, force: bool };
fn vector(name: []const u8) !Vector {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("vectors.txt"), '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, parts.next().?, name)) continue;
        const hex = parts.next().?;
        const bytes = try testing.allocator.alloc(u8, hex.len / 2);
        errdefer testing.allocator.free(bytes);
        _ = try std.fmt.hexToBytes(bytes, hex);
        var hash: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash, parts.next().?);
        return .{ .bytes = bytes, .hash = hash, .force = std.mem.eql(u8, parts.next().?, "1") };
    }
    return error.MissingVector;
}

fn check(comptime T: type, value: T, name: []const u8, comptime ext: rt.cdr_framing.Extensibility, comptime xcdr1_ok: bool) !void {
    const expected = try vector(name);
    defer testing.allocator.free(expected.bytes);
    try testing.expectEqual(expected.force, T.KEY_HASH_FORCE_MD5);
    try testing.expectEqualSlices(u8, &expected.hash, &T.computeKeyHash(&value));
    const checked = try T.computeKeyHashChecked(&value);
    try testing.expectEqualSlices(u8, &expected.hash, &checked);
    var fixed: [512]u8 = undefined;
    var writer = rt.PrimitiveWriter.initFixed(&fixed, .four, .big);
    try T.serializeKeyHolder(&writer, value);
    try testing.expectEqualSlices(u8, expected.bytes, fixed[0..writer.len]);
    writer = rt.PrimitiveWriter.initCounting(.four, .big);
    try T.serializeKeyHolder(&writer, value);
    try testing.expectEqual(expected.bytes.len, writer.len);
    var dynamic = std.ArrayListUnmanaged(u8).empty;
    defer dynamic.deinit(testing.allocator);
    writer = rt.PrimitiveWriter.initDynamic(&dynamic, testing.allocator, .four, .big);
    try T.serializeKeyHolder(&writer, value);
    try testing.expectEqualSlices(u8, expected.bytes, dynamic.items);
    inline for (.{ rt.XcdrVersion.xcdr1, rt.XcdrVersion.xcdr2 }) |version| {
        if (version != .xcdr1 or xcdr1_ok) {
            var bytes = std.ArrayListUnmanaged(u8).empty;
            defer bytes.deinit(testing.allocator);
            var wire = rt.CdrWriter(version).init(&bytes, testing.allocator);
            switch (ext) {
                .final => try wire.writeEncapHeader(),
                .appendable => try wire.writeEncapHeaderDelimited(),
                .mutable => try wire.writeEncapHeaderMutable(),
            }
            try T.serialize(&wire, value);
            var reader = try rt.CdrReader.init(bytes.items);
            var decoded: T = .{};
            try T.deserializeInto(&decoded, &reader, testing.allocator);
            defer if (comptime @hasDecl(T, "deinit")) decoded.deinit(testing.allocator);
            try testing.expectEqualSlices(u8, &expected.hash, &T.computeKeyHash(&decoded));
        }
    }
}

test "independent canonical keys: alignment, ID ordering, recursion, bounds and UTF16" {
    try check(C.Align, .{ .a = 0xaa, .b = 0x0102030405060708 }, "Align", .final, true);
    const example: C.Example = .{
        .label = try rt.BoundedArray(u8, 12).fromSlice("BLUE"),
        .m_nested = .{ .m_long = 0x12345678, .u = 10, .w = 20 },
        .x = 100,
        .y = 200,
    };
    try check(C.Example, example, "Example", .mutable, false);
    try check(C.Bounded16, .{ .text = try rt.BoundedArray(u8, 11).fromSlice("BLUE") }, "Bounded16", .appendable, true);
    try check(C.Bounded17, .{ .text = try rt.BoundedArray(u8, 12).fromSlice("BLUE") }, "Bounded17", .final, true);
    try check(C.Unbounded, .{}, "Unbounded", .final, true);
    try check(C.Unbounded, .{ .text = "abcdefghijklmnopqrstuvwxyz" }, "UnboundedLong", .final, true);
    try check(C.Seq16, .{}, "Seq16", .final, true);
    try check(C.Seq17, .{}, "Seq17", .final, true);
    try check(C.UnkeyedNested, .{ .inner = .{ .hi = 0xaa, .lo = 0x1234 } }, "UnkeyedNested", .final, true);
    const elements = [_]C.Nested{ .{ .m_long = 0x01020304, .u = 1 }, .{ .m_long = 0x05060708, .w = 2 } };
    try check(C.ArrayKey, .{ .values = elements }, "ArrayKey", .final, false);
    try check(C.SeqAgg, .{ .values = try rt.BoundedArray(C.Nested, 2).fromSlice(&elements) }, "SeqAgg", .final, false);
    try check(C.WideSeq, .{ .values = try rt.BoundedArray(rt.BoundedArray(u16, 8), 2).fromSlice(&.{ try rt.BoundedArray(u16, 8).fromSlice(&.{ 'A', 0x1234 }), .{} }) }, "WideSeq", .final, true);
    try check(C.UnionKey, .{ .selection = .{ ._d = 0, ._u = .{ .small = 0xab } } }, "UnionKey", .final, false);
    try check(C.Wide16, .{ .text = try rt.BoundedArray(u16, 6).fromSlice(&.{ 'A', 0x1234 }) }, "Wide16", .final, true);
    try check(C.Wide17, .{}, "Wide17", .final, true);
    try check(C.Derived, .{ ._base = .{ .base_value = 0x01020304 }, .value = 0xaa }, "Derived", .final, true);
}

test "normalized IDs agree across canonical holders, mutable wire headers and inheritance" {
    try check(C.Sequential, .{ .a = 0xaa, .b = 0x05060708, .c = 0xcc, .d = 0x01020304 }, "Sequential", .mutable, false);
    try check(C.Hashed, .{ .color = 0xaa, .size = 0x01020304 }, "Hashed", .mutable, false);
    try check(C.AutoDerived, .{ ._base = .{ .base_value = 0x05060708, .tail = 0xaa }, .value = 0x01020304 }, "AutoDerived", .final, true);
    try check(C.UnionDefault, .{ .selection = .{ ._d = 0, ._u = .{ .other = 0x01020304 } } }, "UnionDefault", .final, false);
    inline for (.{
        .{ C.Sequential, C.Sequential{ .a = 0xaa, .b = 0x05060708, .c = 0xcc, .d = 0x01020304 }, "Sequential", true },
        .{ C.Hashed, C.Hashed{ .color = 0xaa, .size = 0x01020304 }, "Hashed", true },
        .{ C.UnionDefault, C.UnionDefault{ .selection = .{ ._d = 0, ._u = .{ .other = 0x01020304 } } }, "UnionDefault", false },
    }) |entry| {
        var data = std.ArrayListUnmanaged(u8).empty;
        defer data.deinit(testing.allocator);
        var writer = rt.CdrWriter(.xcdr2).init(&data, testing.allocator);
        if (entry[3]) try writer.writeEncapHeaderMutable() else try writer.writeEncapHeader();
        try entry[0].serialize(&writer, entry[1]);
        var lines = std.mem.tokenizeScalar(u8, @embedFile("wire_ids.txt"), '\n');
        var found = false;
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            if (!std.mem.eql(u8, parts.next().?, entry[2])) continue;
            const hex = parts.next().?;
            var expected: [256]u8 = undefined;
            const bytes = try std.fmt.hexToBytes(&expected, hex);
            try testing.expectEqualSlices(u8, bytes, data.items);
            found = true;
        }
        try testing.expect(found);
    }
}

test "OMG example 3 key-only mutable payload produces the canonical digest" {
    var bytes: [45]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, "000b0000250000001e0000400c000000080000000000002078563412280000400900000005000000424c554500");
    var reader = try rt.CdrReader.init(&bytes);
    var value: C.Example = .{};
    try C.Example.deserializeKeyInto(&value, &reader, testing.allocator);
    const expected = try vector("Example");
    defer testing.allocator.free(expected.bytes);
    try testing.expectEqualSlices(u8, &expected.hash, &C.Example.computeKeyHash(&value));
}

test "checked native hash rejects a value exceeding its declared sequence bound" {
    const value: C.Seq16 = .{ .values = .{ .len = 13 } };
    try testing.expectError(error.SequenceTooLong, C.Seq16.computeKeyHashChecked(&value));
}

test "normalized IDs and ID ordering match independent MinimalTypeObject bytes and hashes" {
    inline for (.{ .{ C.Sequential, "Sequential" }, .{ C.Hashed, "Hashed" } }) |entry| {
        var lines = std.mem.tokenizeScalar(u8, @embedFile("typeobjects.txt"), '\n');
        var found = false;
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            if (!std.mem.eql(u8, parts.next().?, entry[1])) continue;
            var expected: [512]u8 = undefined;
            const bytes = try std.fmt.hexToBytes(&expected, parts.next().?);
            try testing.expectEqualSlices(u8, bytes, entry[0].type_object);
            var hash: [14]u8 = undefined;
            _ = try std.fmt.hexToBytes(&hash, parts.next().?);
            try testing.expectEqualSlices(u8, &hash, &entry[0].equivalence_hash);
            found = true;
        }
        try testing.expect(found);
    }
}

test "independent ordinary wide wire vectors: both orders/versions, empty and UTF16 pairs" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("wide_wire.txt"), '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const name = parts.next().?;
        const version = try std.fmt.parseInt(u8, parts.next().?, 10);
        const order = try std.fmt.parseInt(u8, parts.next().?, 10);
        var storage: [512]u8 = undefined;
        const bytes = try std.fmt.hexToBytes(&storage, parts.next().?);
        var reader = try rt.CdrReader.init(bytes);
        try testing.expectEqual(if (version == 1) rt.XcdrVersion.xcdr1 else .xcdr2, reader.xcdr_version);
        try testing.expectEqual(if (order == 0) rt.ByteOrder.little else .big, reader.byte_order);
        if (std.mem.eql(u8, name, "seq")) {
            var value: C.WideSeq = .{};
            try C.WideSeq.deserializeInto(&value, &reader, testing.allocator);
            try testing.expectEqual(@as(usize, 2), value.values.len);
            try testing.expectEqualSlices(u16, &.{ 'A', 0x1234 }, value.values.slice()[0].slice());
            try testing.expectEqual(@as(usize, 0), value.values.slice()[1].len);
            var encoded: [64]u8 = undefined;
            var writer = rt.PrimitiveWriter.initFixed(&encoded, if (version == 1) .eight else .four, if (order == 0) .little else .big);
            try C.WideSeq.serialize(&writer, value);
            try testing.expectEqualSlices(u8, bytes[4..], encoded[0..writer.len]);
        } else if (std.mem.eql(u8, name, "empty")) {
            var value: C.Wide17 = .{};
            try C.Wide17.deserializeInto(&value, &reader, testing.allocator);
            try testing.expectEqual(@as(usize, 0), value.text.len);
        } else {
            var value: C.Wide16 = .{};
            try C.Wide16.deserializeInto(&value, &reader, testing.allocator);
            const units: []const u16 = if (std.mem.eql(u8, name, "pair")) &.{ 0xd83d, 0xde00 } else &.{ 'A', 0x1234 };
            try testing.expectEqualSlices(u16, units, value.text.slice());
            var encoded: [8]u8 = undefined;
            var writer = rt.PrimitiveWriter.initFixed(&encoded, if (version == 1) .eight else .four, if (order == 0) .little else .big);
            try C.Wide16.serialize(&writer, value);
            try testing.expectEqualSlices(u8, bytes[4..], encoded[0..writer.len]);
        }
        try testing.expectEqual(bytes.len, reader.pos);
        for (4..bytes.len) |n| {
            var truncated = try rt.CdrReader.init(bytes[0..n]);
            if (std.mem.eql(u8, name, "seq")) {
                try testing.expectError(error.EndOfStream, C.WideSeq.skip(&truncated));
            } else try testing.expectError(error.EndOfStream, truncated.skipWstring());
        }
    }
}

fn checkKeyWire(comptime T: type, value: T, comptime name: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("key_wire.txt"), '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, parts.next().?, name)) continue;
        const order = try std.fmt.parseInt(u8, parts.next().?, 10);
        var encoded: [512]u8 = undefined;
        const bytes = try std.fmt.hexToBytes(&encoded, parts.next().?);
        var expected: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, parts.next().?);
        var fixed: [512]u8 = undefined;
        var writer = rt.PrimitiveWriter.initFixed(&fixed, .four, if (order == 0) .little else .big);
        try T.serializeKey(&writer, value);
        try testing.expectEqualSlices(u8, bytes[4..], fixed[0..writer.len]);
        writer = rt.PrimitiveWriter.initCounting(.four, if (order == 0) .little else .big);
        try T.serializeKey(&writer, value);
        try testing.expectEqual(bytes.len - 4, writer.len);
        var reader = try rt.CdrReader.init(bytes);
        var decoded: T = .{};
        defer if (comptime @hasDecl(T, "deinit")) decoded.deinit(testing.allocator);
        try T.deserializeKeyInto(&decoded, &reader, testing.allocator);
        try testing.expectEqual(bytes.len, reader.pos);
        try testing.expectEqualSlices(u8, &expected, &T.computeKeyHash(&decoded));
        for (4..bytes.len) |n| {
            var short = try rt.CdrReader.init(bytes[0..n]);
            var partial: T = .{};
            defer if (comptime @hasDecl(T, "deinit")) partial.deinit(testing.allocator);
            try testing.expectError(error.EndOfStream, T.deserializeKeyInto(&partial, &short, testing.allocator));
        }
    }
}
test "independent key-only frames and recursive keyed values" {
    try checkKeyWire(C.Example, .{ .label = try rt.BoundedArray(u8, 12).fromSlice("BLUE"), .m_nested = .{ .m_long = 0x12345678, .u = 10, .w = 20 }, .x = 100, .y = 200 }, "Example");
    try checkKeyWire(C.Nested, .{ .m_long = 0x12345678, .u = 10, .w = 20 }, "Nested");
    try checkKeyWire(C.Sequential, .{ .a = 0xaa, .b = 0x05060708, .c = 0xcc, .d = 0x01020304 }, "Sequential");
    try checkKeyWire(C.Hashed, .{ .color = 0xaa, .size = 0x01020304 }, "Hashed");
    const values = [_]C.Nested{ .{ .m_long = 0x01020304, .u = 1 }, .{ .m_long = 0x05060708, .w = 2 } };
    try checkKeyWire(C.ArrayKey, .{ .values = values }, "ArrayKey");
    try checkKeyWire(C.SeqAgg, .{ .values = try rt.BoundedArray(C.Nested, 2).fromSlice(&values) }, "SeqAgg");
    try checkKeyWire(C.UnkeyedNested, .{ .inner = .{ .hi = 0xaa, .lo = 0x1234 } }, "UnkeyedNested");
    var data = std.ArrayListUnmanaged(u8).empty;
    defer data.deinit(testing.allocator);
    var writer = rt.CdrWriter(.xcdr1).init(&data, testing.allocator);
    try testing.expectError(error.UnsupportedKeyEncoding, C.Nested.serializeKey(&writer, .{}));
    try testing.expectEqual(@as(usize, 0), data.items.len);
}

fn keyOracle(name: []const u8, storage: []u8) ![]u8 {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("key_wire.txt"), '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, parts.next().?, name) or !std.mem.eql(u8, parts.next().?, "0")) continue;
        return try std.fmt.hexToBytes(storage, parts.next().?);
    }
    return error.MissingVector;
}
fn decodeKeyExample(bytes: []const u8) ![16]u8 {
    var reader = try rt.CdrReader.init(bytes);
    var value: C.Example = .{};
    defer if (comptime @hasDecl(C.Example, "deinit")) value.deinit(testing.allocator);
    errdefer testing.expectEqual(bytes.len, reader.data.len) catch unreachable;
    try C.Example.deserializeKeyInto(&value, &reader, testing.allocator);
    return C.Example.computeKeyHash(&value);
}
test "key-only mutable reader windows, future tails, MU and EMHEADER overflow" {
    var storage: [512]u8 = undefined;
    const original = try keyOracle("Example", &storage);
    const expected = try vector("Example");
    defer testing.allocator.free(expected.bytes);
    var data: [512]u8 = undefined;
    for (0..3) |mode| {
        @memcpy(data[0..original.len], original);
        const pos: usize = if (mode == 0) 4 else if (mode == 1) 12 else 36;
        std.mem.writeInt(u32, data[pos..][0..4], if (mode == 0) 12 else 4, .little);
        try testing.expectError(error.EndOfStream, decodeKeyExample(data[0..original.len]));
    }
    @memcpy(data[0..25], original[0..25]);
    @memcpy(data[25..29], "FUTR");
    @memcpy(data[29 .. original.len + 4], original[25..]);
    std.mem.writeInt(u32, data[4..8], 44, .little);
    std.mem.writeInt(u32, data[12..16], 13, .little);
    try testing.expectEqualSlices(u8, &expected.hash, &try decodeKeyExample(data[0 .. original.len + 4]));
    @memcpy(data[0..12], original[0..12]);
    @memcpy(data[12 .. original.len - 4], original[16..]);
    std.mem.writeInt(u32, data[4..8], 36, .little);
    std.mem.writeInt(u32, data[8..12], 0x50000028, .little);
    try testing.expectEqualSlices(u8, &expected.hash, &try decodeKeyExample(data[0 .. original.len - 4]));
    for (0..2) |mu| {
        @memcpy(data[0..original.len], original);
        std.mem.writeInt(u32, data[4..8], 48, .little);
        std.mem.writeInt(u32, data[48..52], 0x20000063 | (if (mu == 1) @as(u32, 0x80000000) else 0), .little);
        std.mem.writeInt(u32, data[52..56], 42, .little);
        if (mu == 1) try testing.expectError(error.UnknownMustUnderstand, decodeKeyExample(data[0..56])) else try testing.expectEqualSlices(u8, &expected.hash, &try decodeKeyExample(data[0..56]));
    }
    for (4..8) |lc| {
        @memcpy(data[0..original.len], original);
        std.mem.writeInt(u32, data[4..8], 48, .little);
        std.mem.writeInt(u32, data[48..52], (@as(u32, @intCast(lc)) << 28) | 99, .little);
        std.mem.writeInt(u32, data[52..56], 0xffffffff, .little);
        if (lc == 4) try testing.expectError(error.EndOfStream, decodeKeyExample(data[0..56])) else try testing.expectError(error.InvalidEmheader, decodeKeyExample(data[0..56]));
    }
}
