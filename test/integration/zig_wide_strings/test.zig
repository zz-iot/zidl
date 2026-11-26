//! Wide strings in generated Zig structs, under `std.testing.allocator`: a
//! decoded wstring member, a sequence of them and an optional one are owned,
//! cloned and freed; a wstring @default is a static UTF-16 literal that a
//! default-constructed struct's deinit leaves alone.
const std = @import("std");
const t = std.testing;
const cdr = @import("zidl_cdr");
const fixture = @import("fixture").wide;
const Wide = fixture.Wide;

fn units(comptime s: []const u8) []const u16 {
    return comptime blk: {
        var out: [s.len]u16 = undefined;
        for (s, 0..) |c, i| out[i] = c;
        const final = out;
        break :blk &final;
    };
}

test "a default-constructed struct frees nothing it does not own" {
    var d: Wide = .{};
    try t.expectEqualSlices(u16, units("dflt"), d.fallback);
    try t.expectEqualSlices(u16, units("bnd"), d.bounded_wide.slice());
    try t.expectEqualStrings("abc", d.bounded_text.slice());
    var copy = try d.clone(t.allocator);
    try t.expectEqualSlices(u16, units("dflt"), copy.fallback);
    copy.deinit(t.allocator);
    d.deinit(t.allocator);
}

test "a view frees a wide string member only once it no longer holds its static default" {
    // Default-constructed: the static default is left alone.
    var empty: Wide.View = .{};
    try t.expectEqualSlices(u16, units("dflt"), empty.fallback);
    empty.deinit(t.allocator);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    var w = cdr.CdrWriter(.xcdr2).init(&buf, t.allocator);
    try w.writeEncapHeaderDelimited();
    try Wide.serialize(&w, .{ .text = units("hi"), .fallback = units("decoded") });

    // Decoded: the view owns it, and deinit frees it.
    var r = try cdr.CdrReader.init(buf.items);
    var view: Wide.View = .{};
    try Wide.deserializeView(&view, &r, t.allocator);
    try t.expectEqualSlices(u16, units("decoded"), view.fallback);
    view.deinit(t.allocator);

    // A decode that fails before reaching it leaves the default alone too.
    r = try cdr.CdrReader.init(buf.items[0..6]);
    var failed: Wide.View = .{};
    if (Wide.deserializeView(&failed, &r, t.allocator)) |_| return error.DecodedTruncatedSample else |_| {}
}

test "a key hash that fails to decode leaves a static default alone" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    var w = cdr.CdrWriter(.xcdr2).init(&buf, t.allocator);
    try w.writeEncapHeader();
    try fixture.Keyed.serialize(&w, .{ .id = units("abc"), .value = 1 });
    var alloc: std.mem.Allocator = t.allocator;
    // Whole, it hashes; cut inside the key, it does not, and frees nothing static.
    _ = fixture.Keyed.computeKeyHashFromCdr(@ptrCast(&alloc), buf.items);
    _ = fixture.Keyed.computeKeyHashFromCdr(@ptrCast(&alloc), buf.items[0..6]);
}

test "a sequence element with a zero unit inside is refused, not truncated" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    var w = cdr.CdrWriter(.xcdr1).init(&buf, t.allocator);
    try w.writeEncapHeader();
    try fixture.OneLine.serialize(&w, .{ .count = 1, .item = &.{ 'a', 0, 'b' } });
    var r = try cdr.CdrReader.init(buf.items);
    var out: fixture.Lines = .{};
    try t.expectError(error.InvalidString, fixture.Lines.deserializeInto(&out, &r, t.allocator));
    out.deinit(t.allocator);
}

test "wide strings round-trip, clone and free, in both XCDR versions" {
    inline for (.{ cdr.XcdrVersion.xcdr1, cdr.XcdrVersion.xcdr2 }) |version| {
        var first = [_:0]u16{ 'a', 'b' };
        // A supplementary character: a surrogate pair.
        var second = [_:0]u16{ 0xD83D, 0xDE00 };
        var lines = [_][*:0]const u16{ &first, &second };
        const value: Wide = .{ .text = units("hello"), .lines = .{ ._length = 2, ._maximum = 2, ._buffer = &lines }, .note = units("note") };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(t.allocator);
        var w = cdr.CdrWriter(version).init(&buf, t.allocator);
        try w.writeEncapHeaderDelimited();
        try Wide.serialize(&w, value);

        var r = try cdr.CdrReader.init(buf.items);
        var out: Wide = .{};
        try Wide.deserializeInto(&out, &r, t.allocator);
        defer out.deinit(t.allocator);
        try t.expectEqualSlices(u16, units("hello"), out.text);
        try t.expectEqual(@as(u32, 2), out.lines._length);
        try t.expectEqualSlices(u16, &first, std.mem.span(out.lines._buffer.?[0]));
        try t.expectEqualSlices(u16, &second, std.mem.span(out.lines._buffer.?[1]));
        try t.expectEqualSlices(u16, units("dflt"), out.fallback);
        try t.expectEqualSlices(u16, units("note"), out.note.?);
        try t.expectEqualSlices(u16, units("bnd"), out.bounded_wide.slice());
        try t.expectEqualStrings("abc", out.bounded_text.slice());

        var copy = try out.clone(t.allocator);
        defer copy.deinit(t.allocator);
        try t.expect(copy.text.ptr != out.text.ptr);
        try t.expectEqualSlices(u16, &second, std.mem.span(copy.lines._buffer.?[1]));

        // A failed decode leaves nothing allocated.
        r = try cdr.CdrReader.init(buf.items[0 .. buf.items.len - 1]);
        var failed: Wide = .{};
        if (Wide.deserializeInto(&failed, &r, t.allocator)) |_| return error.DecodedTruncatedSample else |_| {}
    }
}
