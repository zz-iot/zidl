const std = @import("std");
const zidl_cdr = @import("zidl_cdr");
const P = @import("fixture").Projection;
const testing = std.testing;

fn check(comptime T: type, value: T, name: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("vectors.txt"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.next().?, name)) continue;
        const version = try std.fmt.parseInt(u8, fields.next().?, 10);
        const order = try std.fmt.parseInt(u8, fields.next().?, 10);
        const full_hex = fields.next().?;
        const key_hex = fields.next().?;
        var hash: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash, fields.next().?);
        try testing.expectEqual(hash, try T.computeKeyHashChecked(&value));
        for ([_][]const u8{ full_hex, key_hex }, 0..) |hex, key| {
            var expected_buffer: [1024]u8 = undefined;
            const expected = try std.fmt.hexToBytes(&expected_buffer, hex);
            var fixed: [1024]u8 = undefined;
            var dynamic = std.ArrayListUnmanaged(u8).empty;
            defer dynamic.deinit(testing.allocator);
            for (0..3) |mode| {
                var writer = switch (mode) {
                    0 => zidl_cdr.PrimitiveWriter.initFixed(&fixed, if (version == 1) .eight else .four, if (order == 0) .little else .big),
                    1 => zidl_cdr.PrimitiveWriter.initCounting(if (version == 1) .eight else .four, if (order == 0) .little else .big),
                    else => zidl_cdr.PrimitiveWriter.initDynamic(&dynamic, testing.allocator, if (version == 1) .eight else .four, if (order == 0) .little else .big),
                };
                try writer.writeBytes(expected[0..4]);
                writer.resetPayload();
                if (key == 1) try T.serializeKey(&writer, value) else try T.serialize(&writer, value);
                try testing.expectEqual(expected.len, writer.len);
                if (mode == 0) try testing.expectEqualSlices(u8, expected, fixed[0..writer.len]);
                if (mode == 2) try testing.expectEqualSlices(u8, expected, dynamic.items);
            }
            var reader = try zidl_cdr.CdrReader.init(expected);
            var decoded: T = .{};
            defer if (@hasDecl(T, "deinit")) decoded.deinit(testing.allocator);
            if (key == 1) try T.deserializeKeyInto(&decoded, &reader, testing.allocator) else try T.deserializeInto(&decoded, &reader, testing.allocator);
            try testing.expectEqual(expected.len, reader.pos);
            try testing.expectEqual(expected.len, reader.data.len);
            try testing.expectEqual(hash, try T.computeKeyHashChecked(&decoded));
            for (4..expected.len) |n| {
                reader = try zidl_cdr.CdrReader.init(expected[0..n]);
                var partial: T = .{};
                defer if (@hasDecl(T, "deinit")) partial.deinit(testing.allocator);
                const result = if (key == 1) T.deserializeKeyInto(&partial, &reader, testing.allocator) else T.deserializeInto(&partial, &reader, testing.allocator);
                if (result) |_| return error.AcceptedTruncation else |_| {}
                try testing.expectEqual(n, reader.data.len);
                try testing.expect(reader.pos <= n);
            }
        }
        checked += 1;
    }
    try testing.expectEqual(@as(usize, if (T == P.FDerived or T == P.ADerived or T == P.RootBridge or T == P.RootInherited) 4 else 2), checked);
}

const final: P.FDerived = .{ ._base = .{ ._base = .{ .ignored = 99, .id = 42 }, .middle = 88 }, .tail = 77 };
fn mutable(text: []const u8) P.MDerived {
    return .{ ._base = .{ .ignored = 99, .key = text }, .tail = 77 };
}
fn bridge(before: i32, text: []const u8, after: i32) P.MutBridge {
    return .{ .before = before, .inner = mutable(text), .after = after };
}

test "inherited and recursively projected wire values match independent bytes" {
    try check(P.FDerived, final, "FDerived");
    try check(P.ADerived, .{ ._base = .{ .ignored = 99, .id = 42 }, .tail = 77 }, "ADerived");
    try check(P.MDerived, mutable("blue"), "MDerived");
    try check(P.RootBridge, .{ .item = .{ .before = 11, .inner = final, .after = 22 }, .ignored = 66 }, "RootBridge");
    try check(P.RootInherited, .{ .item = .{ ._base = .{ .before = 11 }, .inner = final, .after = 22 }, .ignored = 66 }, "RootInherited");
    try check(P.RootMut, .{ .item = bridge(11, "blue", 22), .token = 33, .ignored = 66 }, "RootMut");
    try check(P.RootArray, .{ .values = .{ .{ .before = 11, .inner = mutable("blue") }, .{ .before = 33, .inner = mutable("orange") } }, .ignored = 66 }, "RootArray");
    var elements = [_]P.MutBridge{ bridge(11, "blue", 22), bridge(33, "orange", 44) };
    try check(P.RootSeq, .{
        .values = try zidl_cdr.BoundedArray(P.MutBridge, 2).fromSlice(&elements),
        .dynamic_values = .{ ._buffer = &elements, ._length = 2, ._maximum = 2, ._release = false },
        .ignored = 66,
    }, "RootSeq");
}

fn frameBounds(comptime T: type, name: []const u8, offsets: []const usize) !void {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("vectors.txt"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.next().?, name)) continue;
        if (!std.mem.eql(u8, fields.next().?, "2")) continue;
        const order: std.builtin.Endian = if (std.mem.eql(u8, fields.next().?, "0")) .little else .big;
        _ = fields.next();
        const hex = fields.next().?;
        for (offsets) |offset| {
            var buffer: [1024]u8 = undefined;
            const bytes = try std.fmt.hexToBytes(&buffer, hex);
            const word: *[4]u8 = bytes[offset..][0..4];
            const size = std.mem.readInt(u32, word, order);
            std.mem.writeInt(u32, word, size - 4, order);
            var reader = try zidl_cdr.CdrReader.init(bytes);
            var value: T = .{};
            defer if (@hasDecl(T, "deinit")) value.deinit(testing.allocator);
            if (T.deserializeKeyInto(&value, &reader, testing.allocator)) |_| return error.BorrowedFollowingFrame else |_| {}
            try testing.expectEqual(bytes.len, reader.data.len);
            try testing.expect(reader.pos <= bytes.len);
        }
    }
}

test "projected inherited frames cannot borrow following fields" {
    try frameBounds(P.ADerived, "ADerived", &.{4});
    try frameBounds(P.MDerived, "MDerived", &.{4});
    try frameBounds(P.RootMut, "RootMut", &.{ 4, 12, 16, 32, 36 });
    try frameBounds(P.RootArray, "RootArray", &.{ 4, 8, 16 });
    try frameBounds(P.RootSeq, "RootSeq", &.{ 4, 12, 32 });
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("vectors.txt"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.next().?, "RootSeq")) continue;
        _ = fields.next();
        if (!std.mem.eql(u8, fields.next().?, "0")) continue;
        _ = fields.next();
        var buffer: [1024]u8 = undefined;
        const bytes = try std.fmt.hexToBytes(&buffer, fields.next().?);
        var reader = try zidl_cdr.CdrReader.init(bytes);
        var value: P.RootSeq = .{};
        defer value.deinit(allocator);
        try P.RootSeq.deserializeKeyInto(&value, &reader, allocator);
        try testing.expectEqual(bytes.len, reader.pos);
    }
}

test "nested projected allocations can be cleaned at every failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailures, .{});
}
