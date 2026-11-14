const std = @import("std");
const t = std.testing;
const cdr = @import("zidl_cdr");
const M = @import("fixture").MapAudit;
// Independent XCDR2 bytes: DHEADER 18, count 1, strings "k"/"v", tail 7.
const owned = [_]u8{ 0, 7, 0, 0, 18, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 'k', 0, 0, 0, 2, 0, 0, 0, 'v', 0, 0, 0, 7, 0, 0, 0 };
fn decode(alloc: std.mem.Allocator, bytes: []const u8) !void {
    var r = try cdr.CdrReader.init(bytes);
    var out: M.Owned = .{};
    try M.Owned.deserializeInto(&out, &r, alloc);
    defer out.deinit(alloc);
    try t.expectEqualStrings("v", out.values.get("k").?);
    try t.expectEqual(@as(i32, 7), out.tail);
}
test "map bytes, truncations, duplicates and allocation cleanup" {
    try decode(t.allocator, &owned);
    try t.checkAllAllocationFailures(t.allocator, decode, .{&owned});
    var r = try cdr.CdrReader.init(&owned);
    var out: M.Owned = .{};
    try M.Owned.deserializeInto(&out, &r, t.allocator);
    defer out.deinit(t.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    var w = cdr.CdrWriter(.xcdr2).init(&buf, t.allocator);
    try w.writeEncapHeader();
    try M.Owned.serialize(&w, out);
    try t.expectEqualSlices(u8, &owned, buf.items);
    for (4..owned.len) |cut| {
        var rr = try cdr.CdrReader.init(owned[0..cut]);
        var value: M.Owned = .{};
        if (M.Owned.deserializeInto(&value, &rr, t.allocator)) |_| {
            value.deinit(t.allocator);
            return error.AcceptedTruncation;
        } else |_| {}
    }
    var dup: [48]u8 = undefined;
    @memcpy(dup[0..12], owned[0..12]);
    std.mem.writeInt(u32, dup[4..8], 34, .little);
    std.mem.writeInt(u32, dup[8..12], 2, .little);
    @memcpy(dup[12..28], owned[12..28]);
    @memcpy(dup[28..44], owned[12..28]);
    @memcpy(dup[44..48], owned[28..32]);
    var dr = try cdr.CdrReader.init(&dup);
    var dv: M.Owned = .{};
    try t.expectError(error.DuplicateMapKey, M.Owned.deserializeInto(&dv, &dr, t.allocator));
    var huge = owned;
    std.mem.writeInt(u32, huge[8..12], 0xffffffff, .little);
    var hr = try cdr.CdrReader.init(&huge);
    var hv: M.Owned = .{};
    try t.expectError(error.MapTooLong, M.Owned.deserializeInto(&hv, &hr, std.testing.failing_allocator));
}
const nested = [_]u8{ 0, 7, 0, 0, 30, 0, 0, 0, 1, 0, 0, 0, 9, 0, 0, 0, 18, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 'k', 0, 0, 0, 2, 0, 0, 0, 'v', 0 };
fn decodeNested(alloc: std.mem.Allocator, bytes: []const u8) !void {
    var r = try cdr.CdrReader.init(bytes);
    var out: M.Nested = .{};
    try M.Nested.deserializeInto(&out, &r, alloc);
    defer out.deinit(alloc);
    try t.expectEqualStrings("v", out.values.get(9).?.get("k").?);
    var copy = try out.clone(alloc);
    defer copy.deinit(alloc);
    try t.expect(out.values.getPtr(9).?.keys()[0].ptr != copy.values.getPtr(9).?.keys()[0].ptr);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var w = cdr.CdrWriter(.xcdr2).init(&buf, alloc);
    try w.writeEncapHeader();
    try M.Nested.serialize(&w, out);
    try t.expectEqualSlices(u8, bytes, buf.items);
}
test "nested map ownership and cloning" {
    try decodeNested(t.allocator, &nested);
    try t.checkAllAllocationFailures(t.allocator, decodeNested, .{&nested});
    for (4..nested.len) |cut| {
        var r = try cdr.CdrReader.init(nested[0..cut]);
        var out: M.Nested = .{};
        if (M.Nested.deserializeInto(&out, &r, t.allocator)) |_| {
            out.deinit(t.allocator);
            return error.AcceptedTruncation;
        } else |_| {}
    }
}
test "primitive map no delimiter and big endian owning map" {
    const numeric = [_]u8{ 0, 7, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 42, 0, 0, 0, 7, 0, 0, 0 };
    var r = try cdr.CdrReader.init(&numeric);
    var out: M.Numeric = .{};
    try M.Numeric.deserializeInto(&out, &r, t.allocator);
    defer out.deinit(t.allocator);
    try t.expectEqual(@as(i32, 42), out.values.get(1).?);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    var w = cdr.CdrWriter(.xcdr2).init(&buf, t.allocator);
    try w.writeEncapHeader();
    try M.Numeric.serialize(&w, out);
    try t.expectEqualSlices(u8, &numeric, buf.items);
    var be = owned;
    be[1] = 6;
    for ([_]usize{ 4, 8, 12, 20, 28 }) |offset| {
        std.mem.reverse(u8, be[offset..][0..4]);
    }
    try decode(t.allocator, &be);
}

fn decodeHolders(alloc: std.mem.Allocator, bytes: []const u8) !void {
    var reader = try cdr.CdrReader.init(bytes);
    var out: M.Holders = .{};
    try M.Holders.deserializeInto(&out, &reader, alloc);
    defer out.deinit(alloc);
    try t.expectEqualStrings("a", out.values.get(7).?.a.get(1).?);
    try t.expectEqualStrings("b", out.values.get(7).?.b.get(2).?);
}

test "aggregate map values initialize untouched owning fields before failure" {
    var value: M.Holders = .{};
    defer value.deinit(t.allocator);
    var holder: M.Holder = .{};
    try holder.a.put(t.allocator, 1, try t.allocator.dupe(u8, "a"));
    try holder.b.put(t.allocator, 2, try t.allocator.dupe(u8, "b"));
    try value.values.put(t.allocator, 7, holder);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    var writer = cdr.CdrWriter(.xcdr2).init(&bytes, t.allocator);
    try writer.writeEncapHeader();
    try M.Holders.serialize(&writer, value);
    try decodeHolders(t.allocator, bytes.items);
    try t.checkAllAllocationFailures(t.allocator, decodeHolders, .{bytes.items});
}
