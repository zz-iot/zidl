const std = @import("std");
const zidl_cdr = @import("zidl_cdr");
const P = @import("fixture").OptionalWire;
const testing = std.testing;

fn value(comptime T: type, present: bool) T {
    var v: T = .{ .tail = 0x1122334455667788 };
    if (!present) return v;
    if (T == P.Values) {
        v.number = 0x0102030405060708;
        v.text = "";
        v.numbers = .{ .values = .{ 42, 43 } };
        v.texts = .{};
        v.texts.?.appendAssumeCapacity("blue");
        v.texts.?.appendAssumeCapacity("orange");
    } else {
        v._base.item = .{ .prefix = 0xa5, .value = 0x0102030405060708, .tail = 99 };
        v.extra = "extra";
    }
    return v;
}
fn decode(comptime T: type, bytes: []const u8, allocator: std.mem.Allocator, key: bool, present: bool) !void {
    var r = try zidl_cdr.CdrReader.init(bytes);
    var out: T = .{};
    defer out.deinit(allocator);
    if (key) try T.deserializeKeyValueInto(&out, &r, allocator) else try T.deserializeInto(&out, &r, allocator);
    try testing.expectEqual(@as(u64, 0x1122334455667788), out.tail);
    try testing.expectEqual(bytes.len, r.pos);
    if (T == P.Values) {
        try testing.expectEqual(present, out.number != null);
        try testing.expectEqual(present, out.text != null);
        try testing.expectEqual(present, out.numbers != null);
        try testing.expectEqual(present, out.texts != null);
        if (present) {
            try testing.expectEqual(@as(u64, 0x0102030405060708), out.number.?);
            try testing.expectEqualSlices(u8, "", out.text.?);
            try testing.expectEqualSlices(u64, &.{ 42, 43 }, &out.numbers.?.values);
            try testing.expectEqual(@as(usize, 2), out.texts.?.len);
            try testing.expectEqualSlices(u8, "blue", out.texts.?.slice()[0]);
            try testing.expectEqualSlices(u8, "orange", out.texts.?.slice()[1]);
        }
    } else {
        try testing.expectEqual(present, out._base.item != null);
        try testing.expectEqual(present, out.extra != null);
        if (present) {
            try testing.expectEqual(@as(u8, 0xa5), out._base.item.?.prefix);
            try testing.expectEqual(@as(u64, 0x0102030405060708), out._base.item.?.value.?);
            try testing.expectEqual(@as(u64, 99), out._base.item.?.tail);
            try testing.expectEqualSlices(u8, "extra", out.extra.?);
        }
    }
}
fn check(comptime T: type, present: bool, version: u8, order: u8, full: []const u8, compact: []const u8) !void {
    const v = value(T, present);
    for (0..2) |key| {
        var dynamic: std.ArrayListUnmanaged(u8) = .empty;
        defer dynamic.deinit(testing.allocator);
        var actual: [1024]u8 = undefined;
        for (4..full.len) |cap| {
            var failed = zidl_cdr.PrimitiveWriter.initFixed(actual[0..cap], if (version == 1) .eight else .four, if (order == 0) .little else .big);
            try failed.writeBytes(full[0..4]);
            failed.resetPayload();
            if (key == 1) try testing.expectError(error.Overflow, T.serializeKeyValue(&failed, v)) else try testing.expectError(error.Overflow, T.serialize(&failed, v));
            try testing.expect(failed.len <= cap);
            try testing.expectEqual(failed.len - 4, failed.pos);
        }
        for (0..3) |mode| {
            var w = switch (mode) {
                0 => zidl_cdr.PrimitiveWriter.initFixed(&actual, if (version == 1) .eight else .four, if (order == 0) .little else .big),
                1 => zidl_cdr.PrimitiveWriter.initCounting(if (version == 1) .eight else .four, if (order == 0) .little else .big),
                else => zidl_cdr.PrimitiveWriter.initDynamic(&dynamic, testing.allocator, if (version == 1) .eight else .four, if (order == 0) .little else .big),
            };
            try w.writeBytes(full[0..4]);
            w.resetPayload();
            if (key == 1) try T.serializeKeyValue(&w, v) else try T.serialize(&w, v);
            try testing.expectEqual(full.len, w.len);
            if (mode == 0) try testing.expectEqualSlices(u8, full, actual[0..w.len]);
            if (mode == 2) try testing.expectEqualSlices(u8, full, dynamic.items);
        }
        for ([_][]const u8{ full, compact }) |bytes| {
            try decode(T, bytes, testing.allocator, key == 1, present);
            const Runner = struct {
                fn run(allocator: std.mem.Allocator, input: []const u8, projected: bool, exists: bool) !void {
                    try decode(T, input, allocator, projected, exists);
                    var reader = try zidl_cdr.CdrReader.init(input);
                    var selected: T = .{};
                    defer selected.deinit(allocator);
                    try T.deserializeSelected(&reader, 0xffff, &selected, allocator);
                }
            };
            try testing.checkAllAllocationFailures(testing.allocator, Runner.run, .{ bytes, key == 1, present });
            var r = try zidl_cdr.CdrReader.init(bytes);
            try T.skip(&r);
            try testing.expectEqual(bytes.len, r.pos);
            for ([_]u64{ 0, 0xffff, if (T == P.Values) 16 else 2 }) |mask| {
                r = try zidl_cdr.CdrReader.init(bytes);
                var selected: T = .{};
                defer selected.deinit(testing.allocator);
                try T.deserializeSelected(&r, mask, &selected, testing.allocator);
                try testing.expectEqual(bytes.len, r.pos);
                if (mask != 0 or T == P.Derived) try testing.expectEqual(v.tail, selected.tail);
            }
            if (T == P.Values) {
                var allocator = testing.allocator;
                var scratch: [64]u8 = undefined;
                const tail = T.getFieldFromCdr(@ptrCast(&allocator), bytes, "tail", &scratch);
                try testing.expectEqual(@as(i64, @bitCast(v.tail)), tail.?.int);
                const number = T.getFieldFromCdr(@ptrCast(&allocator), bytes, "number", &scratch);
                if (present) try testing.expectEqual(@as(i64, 0x0102030405060708), number.?.int) else try testing.expect(number == null);
                const text = T.getFieldFromCdr(@ptrCast(&allocator), bytes, "text", &scratch);
                if (present) try testing.expectEqualSlices(u8, "", text.?.string) else try testing.expect(text == null);
            }
            for (4..bytes.len) |n| {
                r = try zidl_cdr.CdrReader.init(bytes[0..n]);
                var partial: T = .{};
                defer partial.deinit(testing.allocator);
                const result = if (key == 1) T.deserializeKeyValueInto(&partial, &r, testing.allocator) else T.deserializeInto(&partial, &r, testing.allocator);
                if (result) |_| return error.AcceptedTruncation else |_| {}
                try testing.expectEqual(n, r.data.len);
                try testing.expectEqual(bytes.ptr, r.data.ptr);
                try testing.expect(r.pos <= n);
            }
        }
    }
}
test "generated optional values match independent long and compact headers" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("vectors.txt"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const name = fields.next().?;
        const present = std.mem.eql(u8, fields.next().?, "1");
        const version = try std.fmt.parseInt(u8, fields.next().?, 10);
        const order = try std.fmt.parseInt(u8, fields.next().?, 10);
        var a: [1024]u8 = undefined;
        var b: [1024]u8 = undefined;
        const full = try std.fmt.hexToBytes(&a, fields.next().?);
        const compact = try std.fmt.hexToBytes(&b, fields.next().?);
        if (std.mem.eql(u8, name, "Values")) try check(P.Values, present, version, order, full, compact) else try check(P.Derived, present, version, order, full, compact);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 16), count);
}

test "optional field getter releases a decoded string when a later member is truncated" {
    const hex = "0001000000000000003f090005000000626c756500000000017f0800013f0000000000001f000000000000008877665544332211";
    var storage: [80]u8 = undefined;
    const bytes = try std.fmt.hexToBytes(&storage, hex);
    var allocator = testing.allocator;
    var scratch: [32]u8 = undefined;
    const field = P.Values.getFieldFromCdr(@ptrCast(&allocator), bytes, "text", &scratch);
    try testing.expectEqualSlices(u8, "blue", field.?.string);
    for (4..bytes.len) |n| try testing.expect(P.Values.getFieldFromCdr(@ptrCast(&allocator), bytes[0..n], "text", &scratch) == null);
}
