const std = @import("std");
const t = std.testing;
const cdr = @import("zidl_cdr");
const M = @import("fixture").Traversal;
const missing_disc = [_]u8{ 0, 7, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0 };
const unknown_mu = [_]u8{ 0, 7, 0, 0, 7, 0, 0, 0, 8, 0, 0, 0, 50, 0, 0, 0xa0, 42, 0, 0, 0 };
const valid = [_]u8{ 0, 7, 0, 0, 7, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0x20, 42, 0, 0, 0 };
fn boundary(comptime T: type, bytes: []const u8) !void {
    var alloc = t.failing_allocator;
    var r = try cdr.CdrReader.init(bytes);
    try T.skip(&r);
    try t.expectEqual(bytes.len, r.pos);
    r = try cdr.CdrReader.init(bytes);
    var selected: T = .{};
    try T.deserializeSelected(&r, T.KEY_FIELD_MASK, &selected, alloc);
    try t.expectEqual(@as(i32, 7), selected.id);
    const expected = [_]u8{ 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try t.expectEqualSlices(u8, &expected, &T.computeKeyHashFromCdr(@ptrCast(&alloc), bytes));
    var scratch: [8]u8 = undefined;
    try t.expectEqual(@as(i64, 7), T.getFieldFromCdr(@ptrCast(&alloc), bytes, "id", &scratch).?.int);
    r = try cdr.CdrReader.init(bytes);
    var out: T = .{};
    if (T.deserializeInto(&out, &r, alloc)) |_| return error.AdmittedMalformedSample else |_| {}
    r = try cdr.CdrReader.init(bytes);
    const before = r.pos;
    if (T.deserializeValidated(&out, &r, alloc)) |_| return error.ValidatedMalformedSample else |_| {}
    try t.expectEqual(before, r.pos);
    for (4..bytes.len) |cut| {
        r = try cdr.CdrReader.init(bytes[0..cut]);
        if (T.skip(&r)) |_| return error.SkippedTruncatedExtent else |_| {}
        try t.expect(r.pos <= cut);
    }
}
test "structural and projection success cannot authorize admission" {
    try boundary(M.UnionTopic, &missing_disc);
    try boundary(M.StructTopic, &unknown_mu);
}
test "validated decode checks full extent; skip consumes one value" {
    var r = try cdr.CdrReader.init(&valid);
    var out: M.StructTopic = .{};
    try M.StructTopic.deserializeValidated(&out, &r, t.failing_allocator);
    try t.expectEqual(@as(i32, 42), out.payload.number);
    var trailing: [valid.len + 1]u8 = undefined;
    @memcpy(trailing[0..valid.len], &valid);
    trailing[valid.len] = 0xff;
    r = try cdr.CdrReader.init(&trailing);
    try M.StructTopic.skip(&r);
    try t.expectEqual(valid.len, r.pos);
    r = try cdr.CdrReader.init(&trailing);
    try t.expectError(error.TrailingBytes, M.StructTopic.deserializeValidated(&out, &r, t.failing_allocator));
    var oversized = unknown_mu;
    oversized[8] = 64;
    r = try cdr.CdrReader.init(&oversized);
    try t.expectError(error.EndOfStream, M.StructTopic.skip(&r));
}

const bad_map = [_]u8{ 0, 7, 0, 0, 12, 0, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0 };
fn rejectMap(alloc: std.mem.Allocator) !void {
    var r = try cdr.CdrReader.init(&bad_map);
    var out: M.MapTopic = .{};
    M.MapTopic.deserializeInto(&out, &r, alloc) catch |err| {
        if (err == error.OutOfMemory) return err;
        try t.expectEqual(error.MissingDiscriminator, err);
        out.deinit(alloc);
        return;
    };
    out.deinit(alloc);
    return error.PreflightBecameAdmission;
}
test "allocation probes never replace actual entry decoding" {
    var r = try cdr.CdrReader.init(&bad_map);
    try M.MapTopic.skip(&r);
    try t.expectEqual(bad_map.len, r.pos);
    try rejectMap(t.allocator);
    try t.checkAllAllocationFailures(t.allocator, rejectMap, .{});
}
test "a zero key hash cannot distinguish parse failure" {
    var alloc = t.failing_allocator;
    var zero_key = valid;
    @memset(zero_key[4..8], 0);
    const hash = M.StructTopic.computeKeyHashFromCdr(@ptrCast(&alloc), &zero_key);
    const zero: [16]u8 = @splat(0);
    try t.expectEqualSlices(u8, &zero, &hash);
    var oversized = unknown_mu;
    oversized[8] = 64;
    const failed = M.StructTopic.computeKeyHashFromCdr(@ptrCast(&alloc), &oversized);
    try t.expectEqualSlices(u8, &hash, &failed);
}
