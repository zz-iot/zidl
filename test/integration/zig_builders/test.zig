//! Generated builder types (--generate-views) write the same bytes as the
//! struct: a builder is counted, then serialized into a fixed buffer, its
//! reservations filled in place in host order and committed, and the result
//! matches `serialize` of the equivalent struct in both byte orders and XCDR
//! versions. Absent optionals reserve nothing, counts and strings are checked
//! against their bounds, a builder's key hash matches the struct's, and the
//! typed writer's `loan_builder` publishes or returns its write loan.
const std = @import("std");
const t = std.testing;
const cdr = @import("zidl_cdr");
const mw = @import("zzdds");
const V = @import("views").views;
const B = @import("builders").builders;

const Order = cdr.ByteOrder;

fn begin(buf: []u8, version: cdr.XcdrVersion, order: Order) cdr.RuntimeWriter {
    var w = cdr.RuntimeWriter.initFixed(buf, version, order);
    w.writeEncapHeader() catch unreachable;
    return w;
}

/// `value` serialized as the struct serializes it. Caller frees.
fn expected(comptime T: type, version: cdr.XcdrVersion, order: Order, value: T) ![]u8 {
    var buf: [4096]u8 = undefined;
    var w = begin(&buf, version, order);
    try T.serialize(&w, value);
    return t.allocator.dupe(u8, w.bytes());
}

/// Counts, then serializes `b` into `buf`: the two passes agree.
fn build(comptime T: type, buf: []u8, version: cdr.XcdrVersion, order: Order, b: *T.Builder) !cdr.RuntimeWriter {
    var c = cdr.RuntimeWriter.initCounting(version, order);
    try c.writeEncapHeader();
    try T.Builder.serialize(&c, b);
    var w = begin(buf, version, order);
    try T.Builder.serialize(&w, b);
    try t.expectEqual(c.len, w.len);
    return w;
}

fn fill(comptime E: type, rp: cdr.cdr_primitives.ReservedPrimitives, values: []const E) !void {
    const elems = rp.asNative(E).?;
    try t.expectEqual(values.len, elems.len);
    for (elems, values) |*e, v| e.* = v;
}

fn finalFrame(version: cdr.XcdrVersion, order: Order) !void {
    var data = [_]u8{ 1, 2, 3, 4, 5 };
    var samples = [_]f64{ 1.5, -2.25, 1e300 };
    var flags = [_]bool{ true, false };
    var labels = [_][*:0]const u8{ "a", "bc" };
    var weights = [_]f32{ 0.5, 4.0 };
    var extra = [_]i32{ 7, -8, 9 };
    var grid: [6]i32 = undefined;
    var v: V.FinalFrame = .{};
    v.first = 9;
    v.name = "frame";
    v.tag = try .fromSlice("tag8");
    v.data = .{ ._length = 5, ._maximum = 5, ._buffer = &data };
    v.samples = .{ ._length = 3, ._maximum = 3, ._buffer = &samples };
    for (0..6) |i| {
        grid[i] = @as(i32, @intCast(i)) * 11 - 20;
        v.grid[i / 3][i % 3] = grid[i];
    }
    v.flags = .{ ._length = 2, ._maximum = 2, ._buffer = &flags };
    v.labels = .{ ._length = 2, ._maximum = 2, ._buffer = &labels };
    v.nested = .{ .id = 42, .label = "inner", .weights = .{ ._length = 2, ._maximum = 2, ._buffer = &weights } };
    v.note = "a note";
    v.extra = .{ ._length = 3, ._maximum = 3, ._buffer = &extra };

    var b: V.FinalFrame.Builder = .{
        .first = 9,
        .name = "frame",
        .tag = "tag8",
        .data = .{ .count = 5 },
        .samples = .{ .count = 3 },
        .flags = .{ ._length = 2, ._maximum = 2, ._buffer = &flags },
        .labels = .{ ._length = 2, ._maximum = 2, ._buffer = &labels },
        .nested = .{ .id = 42, .label = "inner", .weights = .{ .count = 2 } },
        .note = "a note",
        .extra = .{ .count = 3 },
    };

    const want = try expected(V.FinalFrame, version, order, v);
    defer t.allocator.free(want);
    var buf: [4096]u8 = undefined;
    const w = try build(V.FinalFrame, &buf, version, order, &b);
    try t.expectEqual(@as(usize, 6), b.grid.count);
    try fill(u8, b.data, &data);
    try b.samples.copyFrom(f64, &samples);
    try fill(i32, b.grid, &grid);
    try fill(f32, b.nested.weights, &weights);
    try fill(i32, b.extra.?, &extra);
    b.commit();
    b.commit(); // once: a repeat cannot swap the elements back
    try t.expectEqualSlices(u8, want, w.bytes());

    // Absent optionals reserve nothing.
    v.note = null;
    v.extra = null;
    b.note = null;
    b.extra = null;
    const absent = try expected(V.FinalFrame, version, order, v);
    defer t.allocator.free(absent);
    const wa = try build(V.FinalFrame, &buf, version, order, &b);
    try fill(u8, b.data, &data);
    try fill(f64, b.samples, &samples);
    try fill(i32, b.grid, &grid);
    try fill(f32, b.nested.weights, &weights);
    b.commit();
    try t.expectEqualSlices(u8, absent, wa.bytes());

    // A bounded string over its bound fails while counting.
    var c = cdr.RuntimeWriter.initCounting(version, order);
    b.tag = "too long!";
    try t.expectError(error.StringTooLong, V.FinalFrame.Builder.serialize(&c, &b));
}

fn mutableFrame(order: Order) !void {
    var data = [_]u8{ 4, 3, 2, 1 };
    var weights = [_]f32{2.5};
    const v: V.MutableFrame = .{
        .name = "mutable",
        .data = .{ ._length = 4, ._maximum = 4, ._buffer = &data },
        .nested = .{ .id = 7, .label = "deep", .weights = .{ ._length = 1, ._maximum = 1, ._buffer = &weights } },
        .count = 31,
    };
    var b: V.MutableFrame.Builder = .{
        .name = "mutable",
        .data = .{ .count = 4 },
        .nested = .{ .id = 7, .label = "deep", .weights = .{ .count = 1 } },
        .count = 31,
    };
    const want = try expected(V.MutableFrame, .xcdr2, order, v);
    defer t.allocator.free(want);
    var buf: [4096]u8 = undefined;
    const w = try build(V.MutableFrame, &buf, .xcdr2, order, &b);
    try fill(u8, b.data, &data);
    try fill(f32, b.nested.weights, &weights);
    b.commit();
    try t.expectEqualSlices(u8, want, w.bytes());
}

fn derived(version: cdr.XcdrVersion, order: Order) !void {
    var stamps = [_]i64{ 11, -22 };
    var pixels = [_]u16{ 1, 2, 65535 };
    const v: V.Derived = .{ ._base = .{ .id = "base-id", .stamps = .{ ._length = 2, ._maximum = 2, ._buffer = &stamps } }, .pixels = .{ ._length = 3, ._maximum = 3, ._buffer = &pixels } };
    var b: V.Derived.Builder = .{ ._base = .{ .id = "base-id", .stamps = .{ .count = 2 } }, .pixels = .{ .count = 3 } };
    const want = try expected(V.Derived, version, order, v);
    defer t.allocator.free(want);
    var buf: [4096]u8 = undefined;
    const w = try build(V.Derived, &buf, version, order, &b);
    try fill(i64, b._base.stamps, &stamps);
    try fill(u16, b.pixels, &pixels);
    b.commit();
    try t.expectEqualSlices(u8, want, w.bytes());
}

/// Key members are as declared, so a builder's key hash is the struct's.
fn keyed(version: cdr.XcdrVersion, order: Order) !void {
    var ids = [_]i32{ 5, -6 };
    var values = [_]f32{ 1.0, 2.0, 3.0 };
    const v: B.Keyed = .{
        .id = 77,
        .name = "keyed",
        .ids = .{ ._length = 2, ._maximum = 2, ._buffer = &ids },
        .origin = .{ .x = 3, .y = -4 },
        .values = .{ ._length = 3, ._maximum = 3, ._buffer = &values },
        .label = "label",
    };
    var b: B.Keyed.Builder = .{ .id = 77, .name = "keyed", .ids = .{ ._length = 2, ._maximum = 2, ._buffer = &ids }, .origin = v.origin, .values = .{ .count = 3 }, .label = "label" };
    const want = try expected(B.Keyed, version, order, v);
    defer t.allocator.free(want);
    var buf: [4096]u8 = undefined;
    const w = try build(B.Keyed, &buf, version, order, &b);
    try fill(f32, b.values, &values);
    b.commit();
    try t.expectEqualSlices(u8, want, w.bytes());
    try t.expectEqual(B.Keyed.computeKeyHash(&v), try b.computeKeyHash());

    var header = [_]u8{ 0xaa, 0xbb };
    var blob = [_]u8{ 1, 2, 3, 4, 5 };
    const d: B.KeyDerived = .{ ._base = .{ .site = 12, .header = .{ ._length = 2, ._maximum = 2, ._buffer = &header } }, .tag = try .fromSlice("tag"), .blob = .{ ._length = 5, ._maximum = 5, ._buffer = &blob } };
    var db: B.KeyDerived.Builder = .{ ._base = .{ .site = 12, .header = .{ .count = 2 } }, .tag = d.tag, .blob = .{ .count = 5 } };
    const dwant = try expected(B.KeyDerived, version, order, d);
    defer t.allocator.free(dwant);
    const dw = try build(B.KeyDerived, &buf, version, order, &db);
    try fill(u8, db._base.header, &header);
    try fill(u8, db.blob, &blob);
    db.commit();
    try t.expectEqualSlices(u8, dwant, dw.bytes());
    try t.expectEqual(B.KeyDerived.computeKeyHash(&d), try db.computeKeyHash());
}

fn bounded(version: cdr.XcdrVersion) !void {
    var c = cdr.RuntimeWriter.initCounting(version, .little);
    var b: B.Bounded.Builder = .{ .few = .{ .count = 5 } };
    try t.expectError(error.SequenceTooLong, B.Bounded.Builder.serialize(&c, &b));
    b.few.count = 4;
    try B.Bounded.Builder.serialize(&c, &b);
}

test "a builder writes the struct's bytes: final, mutable, derived and keyed, both orders and XCDR versions" {
    inline for (.{ Order.little, Order.big }) |order| {
        inline for (.{ cdr.XcdrVersion.xcdr1, cdr.XcdrVersion.xcdr2 }) |version| {
            try finalFrame(version, order);
            try derived(version, order);
            try keyed(version, order);
            try bounded(version);
        }
        // XCDR1 has no ordinary mutable encoding.
        try mutableFrame(order);
    }
}

test "loan_builder: filled in place and published, or returned" {
    const dw = B.KeyedDataWriter.init(.{}, t.allocator);
    defer mw.published.deinit(t.allocator);
    var ids = [_]i32{ 5, -6 };
    const values = [_]f32{ 0.5, -1.0, 2.25 };
    const builder: B.Keyed.Builder = .{ .id = 7, .name = "k", .ids = .{ ._length = 2, ._maximum = 2, ._buffer = &ids }, .values = .{ .count = 3 }, .label = "frame" };

    var loan = try dw.loan_builder(builder);
    defer loan.deinit();
    try t.expectEqual(@as(usize, 1), mw.outstanding_loans);
    try fill(f32, loan.builder.values, &values);
    try loan.publish();
    try t.expectEqual(@as(usize, 0), mw.outstanding_loans);
    try t.expectEqual(mw.WriteKind.alive, mw.published_kind.?);

    // The struct's bytes and key hash.
    var values_copy = values;
    const v: B.Keyed = .{ .id = 7, .name = "k", .ids = .{ ._length = 2, ._maximum = 2, ._buffer = &ids }, .values = .{ ._length = 3, ._maximum = 3, ._buffer = &values_copy }, .label = "frame" };
    const want = try cdr.serializeAlloc(.all, .xcdr2, .little, t.allocator, v, struct {
        fn write(w: anytype, value: B.Keyed) !void {
            try w.writeEncapHeader();
            try B.Keyed.serialize(w, value);
        }
    }.write);
    defer t.allocator.free(want);
    try t.expectEqualSlices(u8, want, mw.published.items);
    try t.expectEqual(B.Keyed.computeKeyHash(&v), mw.published_hash);
    try t.expectError(error.PreconditionNotMet, loan.publish());

    // Cancelled by deinit: returned, nothing published.
    {
        var cancelled = try dw.loan_builder(builder);
        defer cancelled.deinit();
        try t.expectEqual(@as(usize, 1), mw.outstanding_loans);
    }
    try t.expectEqual(@as(usize, 0), mw.outstanding_loans);
    try t.expectEqual(@as(usize, 1), mw.returned_loans);

    // A failed publish still ends the loan.
    mw.fail_publish = true;
    var failing = try dw.loan_builder(builder);
    defer failing.deinit();
    try t.expectError(error.OutOfResources, failing.publish());
    try t.expectEqual(@as(usize, 0), mw.outstanding_loans);
    try t.expectEqual(@as(usize, 1), mw.returned_loans);
}

test "loan_builder: a count over its bound fails before any loan" {
    const dw = B.BoundedDataWriter.init(.{}, t.allocator);
    try t.expectError(error.SequenceTooLong, dw.loan_builder(.{ .few = .{ .count = 5 } }));
    try t.expectEqual(@as(usize, 0), mw.outstanding_loans);
}
