const std = @import("std");
const rt = @import("zidl_rt");
const V = @import("fixture").Validation;

// A caller-supplied writer may report a patch failure even after all writes
// succeeded. Exercise the generated error paths without allocating 4 GiB.
const FailingWriter = struct {
    pub fn reserveDheaderMaybe(_: *@This()) !?usize {
        return 0;
    }
    pub fn reserveDheader(_: *@This()) !usize {
        return 0;
    }
    pub fn reserveEmheader(_: *@This(), _: u28, _: bool) !usize {
        return 0;
    }
    pub fn writeI32(_: *@This(), _: i32) !void {}
    pub fn writeU32(_: *@This(), _: u32) !void {}
    pub fn writeString(_: *@This(), _: []const u8) !void {}
    pub fn patchDheaderMaybeChecked(_: *@This(), _: ?usize) !void {
        return error.PatchFailure;
    }
    pub fn patchDheaderChecked(_: *@This(), _: usize) !void {
        return error.PatchFailure;
    }
    pub fn patchEmheaderChecked(_: *@This(), _: usize) !void {
        return error.PatchFailure;
    }
};

test "generated serializers propagate aggregate, member, key and collection patch failures" {
    var writer = FailingWriter{};
    try std.testing.expectError(error.PatchFailure, V.App.serialize(&writer, .{ .value = 42 }));
    try std.testing.expectError(error.PatchFailure, V.App.serializeKey(&writer, .{ .value = 42 }));
    try std.testing.expectError(error.PatchFailure, V.Mut.serialize(&writer, .{ .text = "hello" }));
    try std.testing.expectError(error.PatchFailure, V.Collections.serialize(&writer, .{}));
}

test "checked optional patches retain XCDR1 and key writer no-op behavior" {
    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = rt.CdrWriter(.xcdr1).init(&bytes, std.testing.allocator);
    try V.App.serialize(&writer, .{ .value = 42 });
    try std.testing.expectEqual(@as(usize, 4), bytes.items.len);
    var key = rt.KeyHashWriter.init();
    try V.App.serializeKey(&key, .{ .value = 42 });
    try std.testing.expectEqual(@as(usize, 4), key.len);
}

fn truncated(comptime T: type, bytes: []const u8, limit: usize) !void {
    var reader = try rt.CdrReader.init(bytes);
    var out: T = .{};
    try std.testing.expectError(error.EndOfStream, T.deserializeInto(&out, &reader, std.testing.allocator));
    try std.testing.expect(reader.pos <= limit);
    try std.testing.expectEqual(bytes.len, reader.data.len);
    try reader.seekTo(bytes.len - 4);
    try std.testing.expectEqual(@as(i32, 7), try reader.readI32());
}

test "nested appendable frame skips extensions and cannot borrow the parent's bytes" {
    var bytes = [_]u8{ 0, 7, 0, 0, 8, 0, 0, 0, 42, 0, 0, 0, 99, 0, 0, 0, 7, 0, 0, 0 };
    var reader = try rt.CdrReader.init(&bytes);
    var out: V.AppParent = .{};
    try V.AppParent.deserializeInto(&out, &reader, std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 42), out.inner.value);
    try std.testing.expectEqual(@as(i32, 7), out.tail);
    try std.testing.expectEqual(bytes.len, reader.pos);
    try std.testing.expectEqual(bytes.len, reader.data.len);
    bytes[4] = 2;
    try truncated(V.AppParent, &bytes, 10);
    reader = try rt.CdrReader.init(&bytes);
    var key: V.App = .{};
    try std.testing.expectError(error.EndOfStream, V.App.deserializeKeyInto(&key, &reader, std.testing.allocator));
    try std.testing.expect(reader.pos <= 10);
    try std.testing.expectEqual(bytes.len, reader.data.len);
}

test "mutable member, parent frame and unknown member lengths are independently bounded" {
    var bytes = [_]u8{ 0, 7, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0x40, 8, 0, 0, 0, 2, 0, 0, 0, 'x', 0, 0, 0, 7, 0, 0, 0 };
    var reader = try rt.CdrReader.init(&bytes);
    var out: V.MutParent = .{};
    try V.MutParent.deserializeInto(&out, &reader, std.testing.allocator);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 7), out.tail);
    try std.testing.expectEqual(bytes.len, reader.pos);
    try std.testing.expectEqual(bytes.len, reader.data.len);
    bytes[4] = 4;
    try truncated(V.MutParent, &bytes, 12);
    bytes[4] = 16;
    bytes[12] = 4;
    try truncated(V.MutParent, &bytes, 20);
    bytes[8] = 99;
    bytes[12] = 12;
    try truncated(V.MutParent, &bytes, 24);
}

test "sequence and array windows close before a final parent's next field" {
    var seq = [_]u8{ 0, 7, 0, 0, 10, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 'x', 0, 0, 0, 7, 0, 0, 0 };
    var reader = try rt.CdrReader.init(&seq);
    var out: V.CollParent = .{};
    try V.CollParent.deserializeInto(&out, &reader, std.testing.allocator);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 7), out.tail);
    try std.testing.expectEqual(seq.len, reader.pos);
    seq[4] = 8;
    try truncated(V.CollParent, &seq, 16);
    reader = try rt.CdrReader.init(&seq);
    try std.testing.expectError(error.EndOfStream, V.CollParent.skip(&reader));
    try std.testing.expect(reader.pos <= 16);
    try std.testing.expectEqual(seq.len, reader.data.len);

    var array = [_]u8{ 0, 7, 0, 0, 14, 0, 0, 0, 2, 0, 0, 0, 'a', 0, 0, 0, 2, 0, 0, 0, 'b', 0, 0, 0, 7, 0, 0, 0 };
    reader = try rt.CdrReader.init(&array);
    var arr: V.ArrayFields = .{};
    try V.ArrayFields.deserializeInto(&arr, &reader, std.testing.allocator);
    defer arr.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 7), arr.tail);
    try std.testing.expectEqual(array.len, reader.pos);
    array[4] = 12;
    try truncated(V.ArrayFields, &array, 20);
    reader = try rt.CdrReader.init(&array);
    try std.testing.expectError(error.EndOfStream, V.ArrayFields.skip(&reader));
    try std.testing.expect(reader.pos <= 20);
    try std.testing.expectEqual(array.len, reader.data.len);
}

test "mutable key read failure restores the caller's limit after an owned key" {
    const bytes = [_]u8{ 0, 11, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0x40, 6, 0, 0, 0, 2, 0, 0, 0, 'x', 0, 0, 0, 1, 0, 0, 0x20, 7, 0, 0, 0 };
    var reader = try rt.CdrReader.init(&bytes);
    var out: V.MutKey = .{};
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.EndOfStream, V.MutKey.deserializeKeyInto(&out, &reader, std.testing.allocator));
    try std.testing.expectEqualStrings("x", out.key);
    try std.testing.expect(reader.pos <= 28);
    try std.testing.expectEqual(bytes.len, reader.data.len);
}

test "mutable union windows bound both discriminant and active case" {
    var bytes = [_]u8{ 0, 7, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0x20, 0, 0, 0, 0, 1, 0, 0, 0x40, 4, 0, 0, 0, 42, 0, 0, 0, 7, 0, 0, 0 };
    var reader = try rt.CdrReader.init(&bytes);
    var out: V.UnionParent = .{};
    try V.UnionParent.deserializeInto(&out, &reader, std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 7), out.tail);
    try std.testing.expectEqual(bytes.len, reader.pos);
    bytes[20] = 2;
    try truncated(V.UnionParent, &bytes, 26);
    bytes[20] = 4;
    bytes[11] = 0; // LC0 declares one byte for a 4-byte discriminant.
    try truncated(V.UnionParent, &bytes, 13);
}

test "mutable narrow enum windows match emitted widths in either byte order" {
    for ([_]rt.ByteOrder{ .little, .big }) |order| {
        var bytes = std.ArrayListUnmanaged(u8).empty;
        defer bytes.deinit(std.testing.allocator);
        var writer = rt.PrimitiveWriter.initDynamic(&bytes, std.testing.allocator, .four, order);
        try writer.writeBytes(&.{ 0, if (order == .little) 11 else 10, 0, 0 });
        writer.resetPayload();
        try V.NarrowLast.serialize(&writer, .{ .only = .S1 });
        const expected = if (order == .little)
            &[_]u8{ 0, 11, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1 }
        else
            &[_]u8{ 0, 10, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 1 };
        try std.testing.expectEqualSlices(u8, expected, bytes.items);
        var reader = try rt.CdrReader.init(bytes.items);
        var last: V.NarrowLast = .{};
        try V.NarrowLast.deserializeInto(&last, &reader, std.testing.allocator);
        try std.testing.expectEqual(V.Small.S1, last.only);
        try std.testing.expectEqual(bytes.items.len, reader.pos);
        reader = try rt.CdrReader.init(bytes.items);
        try V.NarrowLast.skip(&reader);
        try std.testing.expectEqual(bytes.items.len, reader.pos);

        bytes.clearRetainingCapacity();
        writer = rt.PrimitiveWriter.initDynamic(&bytes, std.testing.allocator, .four, order);
        try writer.writeBytes(&.{ 0, if (order == .little) 11 else 10, 0, 0 });
        writer.resetPayload();
        try V.Narrow.serialize(&writer, .{ .first = .S1, .second = .M1, .tail = 7 });
        reader = try rt.CdrReader.init(bytes.items);
        var out: V.Narrow = .{};
        try V.Narrow.deserializeInto(&out, &reader, std.testing.allocator);
        try std.testing.expectEqual(V.Small.S1, out.first);
        try std.testing.expectEqual(V.Medium.M1, out.second);
        try std.testing.expectEqual(@as(i32, 7), out.tail);
        try std.testing.expectEqual(bytes.items.len, reader.pos);
        reader = try rt.CdrReader.init(bytes.items);
        try V.Narrow.skip(&reader);
        try std.testing.expectEqual(bytes.items.len, reader.pos);
    }
}
