// Compile-and-run regression tests for sequences of struct/union elements.
//
// 1. Allocator forwarding. `typeRefNeedsAllocator` treated every bounded
//    sequence as allocation-free because its storage is inline, but
//    struct/union/bitset element decoders still receive the allocator. A holder
//    whose only such member was a bounded sequence emitted `_ = allocator;` and
//    then forwarded `allocator`: "pointless discard of function parameter".
//    Compiling fixture.zig at all is the primary check for that.
// 2. Element ownership. Holders of bounded sequences with heap-owning elements
//    got no deinit/clone, and unbounded sequence deinit/clone released or
//    memcpy'd only the element buffer, leaking (or aliasing) element contents.
//    Every test here runs under testing.allocator, which reports leaks and
//    double frees.

const std = @import("std");
const testing = std.testing;
const zidl_rt = @import("zidl_rt");
const fixture = @import("fixture");

fn encode(comptime T: type, value: T) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try T.serialize(&writer, value);
    return buf.toOwnedSlice(testing.allocator);
}

fn decodeWith(comptime T: type, bytes: []const u8, allocator: std.mem.Allocator) !T {
    var reader = try zidl_rt.CdrReader.init(bytes);
    var out: T = .{};
    try T.deserializeInto(&out, &reader, allocator);
    return out;
}

fn decode(comptime T: type, bytes: []const u8) !T {
    return decodeWith(T, bytes, testing.allocator);
}

fn expectPoints(expected: []const fixture.Point, actual: []const fixture.Point) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.x, a.x);
        try testing.expectEqual(e.y, a.y);
    }
}

fn expectNames(expected: []const fixture.Named, actual: []const fixture.Named) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqualStrings(e.label, a.label);
        try testing.expectEqual(e.id, a.id);
    }
}

const points = [_]fixture.Point{ .{ .x = 1, .y = 2 }, .{ .x = -3, .y = 4 }, .{ .x = 5, .y = -6 } };
const names = [_]fixture.Named{ .{ .label = "alpha", .id = 1 }, .{ .label = "beta", .id = 2 } };

/// Borrowed (non-owning) unbounded sequence view of `names`, for serializing.
fn namesView(comptime Seq: type) Seq {
    return .{ ._buffer = @constCast(&names), ._length = names.len, ._maximum = names.len, ._release = false };
}

// ── Allocator forwarding ────────────────────────────────────────────────────

test "typedef'd struct elements round-trip through a bounded sequence" {
    const value = fixture.AliasHolder{ .rows = try fixture.AliasedPoints.fromSlice(&points) };
    const bytes = try encode(fixture.AliasHolder, value);
    defer testing.allocator.free(bytes);

    const out = try decode(fixture.AliasHolder, bytes);
    try expectPoints(&points, out.rows.slice());
}

test "enum elements still compile and round-trip without allocator use" {
    const colors = [_]fixture.Color{ .BLUE, .RED, .GREEN };
    const value = fixture.ColorHolder{ .colors = try zidl_rt.BoundedArray(fixture.Color, 4).fromSlice(&colors) };
    const bytes = try encode(fixture.ColorHolder, value);
    defer testing.allocator.free(bytes);

    const out = try decode(fixture.ColorHolder, bytes);
    try testing.expectEqualSlices(fixture.Color, &colors, out.colors.slice());
}

test "appendable and mutable holders forward the allocator" {
    const two = points[0..2];
    {
        const value = fixture.AppendableHolder{ .points = try zidl_rt.BoundedArray(fixture.Point, 2).fromSlice(two) };
        const bytes = try encode(fixture.AppendableHolder, value);
        defer testing.allocator.free(bytes);
        const out = try decode(fixture.AppendableHolder, bytes);
        try expectPoints(two, out.points.slice());
    }
    {
        const value = fixture.MutableHolder{
            .points = try zidl_rt.BoundedArray(fixture.Point, 2).fromSlice(two),
            .tail = -9,
        };
        const bytes = try encode(fixture.MutableHolder, value);
        defer testing.allocator.free(bytes);
        const out = try decode(fixture.MutableHolder, bytes);
        try expectPoints(two, out.points.slice());
        try testing.expectEqual(@as(i32, -9), out.tail);
    }
}

test "union case holding a bounded struct sequence round-trips" {
    const two = points[0..2];
    const value = fixture.SeqCase{ ._d = 1, ._u = .{ .points = try zidl_rt.BoundedArray(fixture.Point, 2).fromSlice(two) } };
    const bytes = try encode(fixture.SeqCase, value);
    defer testing.allocator.free(bytes);

    const out = try decode(fixture.SeqCase, bytes);
    try testing.expectEqual(@as(i32, 1), out._d);
    try expectPoints(two, out._u.points.slice());
}

test "an element count above the bound is rejected" {
    const value = fixture.AliasHolder{ .rows = try fixture.AliasedPoints.fromSlice(&points) };
    const bytes = try encode(fixture.AliasHolder, value);
    defer testing.allocator.free(bytes);

    // XCDR2: after the 4-byte encapsulation header comes the collection's
    // DHEADER (its elements are structs), then the element count.
    std.mem.writeInt(u32, bytes[8..12], 5, .little);
    var reader = try zidl_rt.CdrReader.init(bytes);
    var out: fixture.AliasHolder = .{};
    try testing.expectError(error.SequenceTooLong, fixture.AliasHolder.deserializeInto(&out, &reader, testing.allocator));
}

// ── Element ownership: deinit ───────────────────────────────────────────────

test "bounded holder deinit releases decoded element strings" {
    const value = fixture.NamedHolder{ .items = try zidl_rt.BoundedArray(fixture.Named, 3).fromSlice(&names), .tail = 42 };
    const bytes = try encode(fixture.NamedHolder, value);
    defer testing.allocator.free(bytes);

    var out = try decode(fixture.NamedHolder, bytes);
    defer out.deinit(testing.allocator);
    try expectNames(&names, out.items.slice());
    try testing.expectEqual(@as(i32, 42), out.tail);
}

test "bounded union elements are released by the holder" {
    const choices = [_]fixture.Choice{ .{ ._d = 0, ._u = .{ .i = 7 } }, .{ ._d = 1, ._u = .{ .s = "text" } } };
    const value = fixture.ChoiceHolder{ .choices = try zidl_rt.BoundedArray(fixture.Choice, 3).fromSlice(&choices) };
    const bytes = try encode(fixture.ChoiceHolder, value);
    defer testing.allocator.free(bytes);

    var out = try decode(fixture.ChoiceHolder, bytes);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 7), out.choices.slice()[0]._u.i);
    try testing.expectEqualStrings("text", out.choices.slice()[1]._u.s);
}

test "unbounded and typedef'd holders release element strings" {
    {
        const bytes = try encode(fixture.UnboundedHolder, .{ .items = namesView(@FieldType(fixture.UnboundedHolder, "items")) });
        defer testing.allocator.free(bytes);
        var out = try decode(fixture.UnboundedHolder, bytes);
        defer out.deinit(testing.allocator);
        try expectNames(&names, out.items._buffer.?[0..out.items._length]);
    }
    {
        const bytes = try encode(fixture.TypedefUnboundedHolder, .{ .items = namesView(fixture.NamedSeq) });
        defer testing.allocator.free(bytes);
        var out = try decode(fixture.TypedefUnboundedHolder, bytes);
        defer out.deinit(testing.allocator);
        try expectNames(&names, out.items._buffer.?[0..out.items._length]);
    }
    {
        const value = fixture.TypedefBoundedHolder{ .items = try fixture.NamedBoundedSeq.fromSlice(&names) };
        const bytes = try encode(fixture.TypedefBoundedHolder, value);
        defer testing.allocator.free(bytes);
        var out = try decode(fixture.TypedefBoundedHolder, bytes);
        defer out.deinit(testing.allocator);
        try expectNames(&names, out.items.slice());
    }
}

test "nested, optional and union-case bounded members are released" {
    {
        const value = fixture.Outer{
            .inner = .{ .items = try zidl_rt.BoundedArray(fixture.Named, 3).fromSlice(&names), .tail = 1 },
            .x = 3,
        };
        const bytes = try encode(fixture.Outer, value);
        defer testing.allocator.free(bytes);
        var out = try decode(fixture.Outer, bytes);
        defer out.deinit(testing.allocator);
        try expectNames(&names, out.inner.items.slice());
    }
    {
        const value = fixture.OptionalHolder{ .maybe = try zidl_rt.BoundedArray(fixture.Named, 2).fromSlice(&names) };
        const bytes = try encode(fixture.OptionalHolder, value);
        defer testing.allocator.free(bytes);
        var out = try decode(fixture.OptionalHolder, bytes);
        defer out.deinit(testing.allocator);
        try expectNames(&names, out.maybe.?.slice());
    }
    {
        const bytes = try encode(fixture.OptionalHolder, .{});
        defer testing.allocator.free(bytes);
        var out = try decode(fixture.OptionalHolder, bytes);
        defer out.deinit(testing.allocator);
        try testing.expect(out.maybe == null);
    }
    {
        const value = fixture.PeopleCase{ ._d = 1, ._u = .{ .people = try zidl_rt.BoundedArray(fixture.Named, 2).fromSlice(&names) } };
        const bytes = try encode(fixture.PeopleCase, value);
        defer testing.allocator.free(bytes);
        var out = try decode(fixture.PeopleCase, bytes);
        defer out.deinit(testing.allocator);
        try expectNames(&names, out._u.people.slice());
    }
}

// ── Element ownership: clone ────────────────────────────────────────────────

test "clones own independent element storage" {
    {
        const value = fixture.NamedHolder{ .items = try zidl_rt.BoundedArray(fixture.Named, 3).fromSlice(&names), .tail = 0 };
        const bytes = try encode(fixture.NamedHolder, value);
        defer testing.allocator.free(bytes);
        var original = try decode(fixture.NamedHolder, bytes);
        var copy = try original.clone(testing.allocator);
        defer copy.deinit(testing.allocator);
        original.deinit(testing.allocator);
        try expectNames(&names, copy.items.slice());
    }
    {
        const bytes = try encode(fixture.UnboundedHolder, .{ .items = namesView(@FieldType(fixture.UnboundedHolder, "items")) });
        defer testing.allocator.free(bytes);
        var original = try decode(fixture.UnboundedHolder, bytes);
        var copy = try original.clone(testing.allocator);
        defer copy.deinit(testing.allocator);
        original.deinit(testing.allocator);
        try expectNames(&names, copy.items._buffer.?[0..copy.items._length]);
    }
    {
        const bytes = try encode(fixture.TypedefUnboundedHolder, .{ .items = namesView(fixture.NamedSeq) });
        defer testing.allocator.free(bytes);
        var original = try decode(fixture.TypedefUnboundedHolder, bytes);
        var copy = try original.clone(testing.allocator);
        defer copy.deinit(testing.allocator);
        original.deinit(testing.allocator);
        try expectNames(&names, copy.items._buffer.?[0..copy.items._length]);
    }
}

fn cloneUnderFailure(allocator: std.mem.Allocator, source: *const fixture.UnboundedHolder, bounded: *const fixture.NamedHolder) !void {
    var a = try source.clone(allocator);
    defer a.deinit(allocator);
    var b = try bounded.clone(allocator);
    defer b.deinit(allocator);
}

test "clone releases partial copies on every allocation failure" {
    const u_bytes = try encode(fixture.UnboundedHolder, .{ .items = namesView(@FieldType(fixture.UnboundedHolder, "items")) });
    defer testing.allocator.free(u_bytes);
    var source = try decode(fixture.UnboundedHolder, u_bytes);
    defer source.deinit(testing.allocator);

    const b_value = fixture.NamedHolder{ .items = try zidl_rt.BoundedArray(fixture.Named, 3).fromSlice(&names), .tail = 0 };
    const b_bytes = try encode(fixture.NamedHolder, b_value);
    defer testing.allocator.free(b_bytes);
    var bounded = try decode(fixture.NamedHolder, b_bytes);
    defer bounded.deinit(testing.allocator);

    try testing.checkAllAllocationFailures(testing.allocator, cloneUnderFailure, .{ &source, &bounded });
}

// ── Element ownership: failed decode ────────────────────────────────────────

fn decodeUnderFailure(allocator: std.mem.Allocator, u_bytes: []const u8, b_bytes: []const u8) !void {
    var u = try decodeWith(fixture.UnboundedHolder, u_bytes, allocator);
    defer u.deinit(allocator);
    var b = try decodeWith(fixture.NamedHolder, b_bytes, allocator);
    defer b.deinit(allocator);
}

test "decode releases partially decoded elements on every allocation failure" {
    const u_bytes = try encode(fixture.UnboundedHolder, .{ .items = namesView(@FieldType(fixture.UnboundedHolder, "items")) });
    defer testing.allocator.free(u_bytes);
    const b_value = fixture.NamedHolder{ .items = try zidl_rt.BoundedArray(fixture.Named, 3).fromSlice(&names), .tail = 0 };
    const b_bytes = try encode(fixture.NamedHolder, b_value);
    defer testing.allocator.free(b_bytes);

    try testing.checkAllAllocationFailures(testing.allocator, decodeUnderFailure, .{ u_bytes, b_bytes });
}

test "truncated input part-way through an element leaks nothing" {
    {
        const bytes = try encode(fixture.UnboundedHolder, .{ .items = namesView(@FieldType(fixture.UnboundedHolder, "items")) });
        defer testing.allocator.free(bytes);
        // Cut inside the second element's label.
        try testing.expectError(error.EndOfStream, decode(fixture.UnboundedHolder, bytes[0 .. bytes.len - 6]));
    }
    {
        const value = fixture.NamedHolder{ .items = try zidl_rt.BoundedArray(fixture.Named, 3).fromSlice(&names), .tail = 5 };
        const bytes = try encode(fixture.NamedHolder, value);
        defer testing.allocator.free(bytes);
        // Cut inside the second element's label (the trailing long is 4 bytes).
        try testing.expectError(error.EndOfStream, decode(fixture.NamedHolder, bytes[0 .. bytes.len - 10]));
    }
}
