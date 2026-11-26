//! Generated view types (--generate-views) decode in place: viewed members
//! match what was serialized in both XCDR versions, owned members decode as in
//! the struct, optionals follow presence, a failed decode leaves the view
//! empty, a bounded string's bound is enforced, and the typed reader's
//! `take_view` ends its loan with the view, failed when the view does not
//! decode. `std.testing.allocator` checks every view frees what it owns.
const std = @import("std");
const t = std.testing;
const cdr = @import("zidl_cdr");
const mw = @import("zzdds");
const V = @import("fixture").views;

const Encap = enum { final, appendable, mutable };

/// `value` serialized with `encap`'s header, in `version`. Caller frees.
fn encode(comptime T: type, comptime version: cdr.XcdrVersion, encap: Encap, value: T) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(t.allocator);
    var w = cdr.CdrWriter(version).init(&buf, t.allocator);
    switch (encap) {
        .final => try w.writeEncapHeader(),
        .appendable => try w.writeEncapHeaderDelimited(),
        .mutable => try w.writeEncapHeaderMutable(),
    }
    try T.serialize(&w, value);
    return buf.toOwnedSlice(t.allocator);
}

fn within(bytes: []const u8, s: []const u8) bool {
    const p = @intFromPtr(s.ptr);
    return p >= @intFromPtr(bytes.ptr) and p + s.len <= @intFromPtr(bytes.ptr) + bytes.len;
}

fn copied(comptime T: type, view: cdr.cdr_primitives.PrimitivesView, out: []T) []T {
    view.copyTo(std.mem.sliceAsBytes(out[0..view.count()]));
    return out[0..view.count()];
}

fn finalFrame(comptime version: cdr.XcdrVersion) !void {
    var data = [_]u8{ 1, 2, 3, 4, 5 };
    var samples = [_]f64{ 1.5, -2.25, 1e300 };
    var flags = [_]bool{ true, false };
    var labels = [_][*:0]const u8{ "a", "bc" };
    var weights = [_]f32{ 0.5, 4.0 };
    var extra = [_]i32{ 7, -8, 9 };
    var v: V.FinalFrame = .{};
    v.first = 9;
    v.name = "frame";
    v.tag = try .fromSlice("tag8");
    v.data = .{ ._length = 5, ._maximum = 5, ._buffer = &data };
    v.samples = .{ ._length = 3, ._maximum = 3, ._buffer = &samples };
    for (0..6) |i| v.grid[i / 3][i % 3] = @as(i32, @intCast(i)) * 11 - 20;
    v.flags = .{ ._length = 2, ._maximum = 2, ._buffer = &flags };
    v.labels = .{ ._length = 2, ._maximum = 2, ._buffer = &labels };
    v.nested = .{ .id = 42, .label = "inner", .weights = .{ ._length = 2, ._maximum = 2, ._buffer = &weights } };
    v.note = "a note";
    v.extra = .{ ._length = 3, ._maximum = 3, ._buffer = &extra };

    const bytes = try encode(V.FinalFrame, version, .final, v);
    defer t.allocator.free(bytes);
    var r = try cdr.CdrReader.init(bytes);
    var view: V.FinalFrame.View = .{};
    try V.FinalFrame.deserializeView(&view, &r, t.allocator);
    defer view.deinit(t.allocator);
    try t.expectEqual(bytes.len, r.pos);

    // Zero-copy strings and views of the input.
    try t.expectEqual(@as(u8, 9), view.first);
    try t.expectEqualStrings("frame", view.name);
    try t.expectEqualStrings("tag8", view.tag);
    try t.expect(within(bytes, view.name) and within(bytes, view.data.bytes));
    try t.expectEqualSlices(u8, &data, view.data.asNative(u8).?);
    var f64s: [3]f64 = undefined;
    try t.expectEqualSlices(f64, &samples, copied(f64, view.samples, &f64s));
    var i32s: [6]i32 = undefined;
    for (copied(i32, view.grid, &i32s), 0..) |x, i| try t.expectEqual(@as(i32, @intCast(i)) * 11 - 20, x);
    // Owned members, decoded as in the struct.
    try t.expectEqual(@as(u32, 2), view.flags._length);
    try t.expect(view.flags._buffer.?[0] and !view.flags._buffer.?[1]);
    try t.expectEqualStrings("bc", std.mem.span(view.labels._buffer.?[1]));
    // A nested view.
    try t.expectEqual(@as(i32, 42), view.nested.id);
    try t.expectEqualStrings("inner", view.nested.label);
    var f32s: [2]f32 = undefined;
    try t.expectEqualSlices(f32, &weights, copied(f32, view.nested.weights, &f32s));
    // Present optionals.
    try t.expectEqualStrings("a note", view.note.?);
    try t.expectEqualSlices(i32, &extra, copied(i32, view.extra.?, &i32s));

    // Absent optionals.
    v.note = null;
    v.extra = null;
    const absent = try encode(V.FinalFrame, version, .final, v);
    defer t.allocator.free(absent);
    r = try cdr.CdrReader.init(absent);
    var none: V.FinalFrame.View = .{};
    try V.FinalFrame.deserializeView(&none, &r, t.allocator);
    defer none.deinit(t.allocator);
    try t.expect(none.note == null and none.extra == null);

    // A failed decode leaves the view empty, owning nothing.
    r = try cdr.CdrReader.init(absent[0 .. absent.len - 1]);
    var failed: V.FinalFrame.View = .{};
    try t.expectError(error.EndOfStream, V.FinalFrame.deserializeView(&failed, &r, t.allocator));
    try t.expect(failed.name.len == 0 and failed.data.bytes.len == 0 and failed.labels._buffer == null and failed.flags._buffer == null);
}

fn appendFrame(comptime version: cdr.XcdrVersion) !void {
    var data = [_]u8{ 9, 8, 7 };
    var codes = [_]u16{ 0x1234, 0xabcd };
    var stamps = [_]i64{ -1, 0x0102030405060708 };
    const v: V.AppendFrame = .{
        .name = "appended",
        .data = .{ ._length = 3, ._maximum = 3, ._buffer = &data },
        .nested = .{ .code = -5, .codes = .{ ._length = 2, ._maximum = 2, ._buffer = &codes } },
        .stamps = .{ ._length = 2, ._maximum = 2, ._buffer = &stamps },
    };
    const bytes = try encode(V.AppendFrame, version, .appendable, v);
    defer t.allocator.free(bytes);
    var r = try cdr.CdrReader.init(bytes);
    var view: V.AppendFrame.View = .{};
    try V.AppendFrame.deserializeView(&view, &r, t.allocator);
    defer view.deinit(t.allocator);
    try t.expectEqualStrings("appended", view.name);
    try t.expectEqualSlices(u8, &data, view.data.bytes);
    try t.expectEqual(@as(i16, -5), view.nested.code);
    var u16s: [2]u16 = undefined;
    try t.expectEqualSlices(u16, &codes, copied(u16, view.nested.codes, &u16s));
    var i64s: [2]i64 = undefined;
    try t.expectEqualSlices(i64, &stamps, copied(i64, view.stamps.?, &i64s));
}

test "a view decodes in place: final, appendable and derived, both XCDR versions" {
    inline for (.{ cdr.XcdrVersion.xcdr1, cdr.XcdrVersion.xcdr2 }) |version| {
        try finalFrame(version);
        try appendFrame(version);

        var stamps = [_]i64{ 11, -22 };
        var pixels = [_]u16{ 1, 2, 65535 };
        const d: V.Derived = .{ ._base = .{ .id = "base-id", .stamps = .{ ._length = 2, ._maximum = 2, ._buffer = &stamps } }, .pixels = .{ ._length = 3, ._maximum = 3, ._buffer = &pixels } };
        const bytes = try encode(V.Derived, version, .final, d);
        defer t.allocator.free(bytes);
        var r = try cdr.CdrReader.init(bytes);
        var view: V.Derived.View = .{};
        try V.Derived.deserializeView(&view, &r, t.allocator);
        defer view.deinit(t.allocator);
        try t.expectEqualStrings("base-id", view._base.id);
        var i64s: [2]i64 = undefined;
        try t.expectEqualSlices(i64, &stamps, copied(i64, view._base.stamps, &i64s));
        var u16s: [3]u16 = undefined;
        try t.expectEqualSlices(u16, &pixels, copied(u16, view.pixels, &u16s));
    }
}

test "a mutable view dispatches on member ids" {
    var data = [_]u8{ 4, 3, 2, 1 };
    var weights = [_]f32{2.5};
    const v: V.MutableFrame = .{
        .name = "mutable",
        .data = .{ ._length = 4, ._maximum = 4, ._buffer = &data },
        .nested = .{ .id = 7, .label = "deep", .weights = .{ ._length = 1, ._maximum = 1, ._buffer = &weights } },
        .count = 31,
    };
    const bytes = try encode(V.MutableFrame, .xcdr2, .mutable, v);
    defer t.allocator.free(bytes);
    var r = try cdr.CdrReader.init(bytes);
    var view: V.MutableFrame.View = .{};
    try V.MutableFrame.deserializeView(&view, &r, t.allocator);
    defer view.deinit(t.allocator);
    try t.expectEqualStrings("mutable", view.name);
    try t.expectEqualSlices(u8, &data, view.data.bytes);
    try t.expectEqual(@as(i32, 7), view.nested.id);
    try t.expectEqualStrings("deep", view.nested.label);
    var f32s: [1]f32 = undefined;
    try t.expectEqualSlices(f32, &weights, copied(f32, view.nested.weights, &f32s));
    try t.expectEqual(@as(?i32, 31), view.count);
}

test "a view enforces a bounded string's bound" {
    inline for (.{ cdr.XcdrVersion.xcdr1, cdr.XcdrVersion.xcdr2 }) |version| {
        const long = try encode(V.WideTag, version, .final, .{ .tag = "too long" });
        defer t.allocator.free(long);
        var r = try cdr.CdrReader.init(long);
        var view: V.NarrowTag.View = .{};
        try t.expectError(error.StringTooLong, V.NarrowTag.deserializeView(&view, &r, t.allocator));
        try t.expectEqual(@as(usize, 0), view.tag.len);
        const short = try encode(V.WideTag, version, .final, .{ .tag = "ok" });
        defer t.allocator.free(short);
        r = try cdr.CdrReader.init(short);
        try V.NarrowTag.deserializeView(&view, &r, t.allocator);
        try t.expectEqualStrings("ok", view.tag);
    }
}

test "take_view: a view of a sample on loan, ended with it; failed when it does not decode" {
    const dr = V.FinalFrameDataReader.init(.{}, t.allocator);
    mw.failed_samples = 0;
    mw.ended_samples = 0;

    mw.next_raw = null;
    try t.expect(try dr.take_view() == null);
    try t.expectEqual(@as(usize, 0), mw.ended_samples);

    var labels = [_][*:0]const u8{"owned"};
    const bytes = try encode(V.FinalFrame, .xcdr2, .final, .{ .name = "loaned", .labels = .{ ._length = 1, ._maximum = 1, ._buffer = &labels } });
    defer t.allocator.free(bytes);
    mw.next_raw = .{ .data = bytes, .info = .{ .valid_data = true } };
    var sample = (try dr.take_view()).?;
    try t.expectEqualStrings("loaned", sample.view.name);
    try t.expect(within(bytes, sample.view.name));
    try t.expectEqualStrings("owned", std.mem.span(sample.view.labels._buffer.?[0]));
    try t.expect(sample.info.valid_data);
    // The loan stays open while the view is used, and ends with it, once.
    try t.expectEqual(@as(usize, 0), mw.ended_samples);
    sample.deinit();
    try t.expectEqual(@as(usize, 1), mw.ended_samples);
    try t.expectEqual(@as(usize, 0), mw.failed_samples);

    // Without valid data: an empty view.
    mw.next_raw = .{ .data = &.{}, .info = .{ .valid_data = false } };
    var key_only = (try dr.take_view()).?;
    try t.expect(!key_only.info.valid_data and key_only.view.name.len == 0);
    try t.expectEqual(@as(usize, 1), mw.ended_samples);
    key_only.deinit();
    try t.expectEqual(@as(usize, 2), mw.ended_samples);

    // A view that does not decode: the sample is ended failed.
    mw.next_raw = .{ .data = bytes[0 .. bytes.len - 1], .info = .{ .valid_data = true } };
    try t.expectError(error.EndOfStream, dr.take_view());
    try t.expectEqual(@as(usize, 1), mw.failed_samples);
    try t.expectEqual(@as(usize, 3), mw.ended_samples);
}

test "a view keeps a string's @default when a mutable sample omits it" {
    // An older sample, from before `label` and `maybe`.
    var data = [_]u8{1};
    const bytes = try encode(V.DefaultsOld, .xcdr2, .mutable, .{ .name = "n", .data = .{ ._length = 1, ._maximum = 1, ._buffer = &data } });
    defer t.allocator.free(bytes);
    var r = try cdr.CdrReader.init(bytes);
    var view: V.Defaults.View = .{};
    try V.Defaults.deserializeView(&view, &r, t.allocator);
    defer view.deinit(t.allocator);
    var owned: V.Defaults = .{};
    r = try cdr.CdrReader.init(bytes);
    try V.Defaults.deserializeInto(&owned, &r, t.allocator);
    defer owned.deinit(t.allocator);
    try t.expectEqualStrings("n", view.name);
    try t.expectEqualStrings(owned.label, view.label);
    try t.expectEqualStrings("fallback", view.label);
    // A default naming a constant too.
    try t.expectEqualStrings(owned.named, view.named);
    try t.expectEqualStrings("named fallback", view.named);
    try t.expectEqualStrings(owned.maybe.?, view.maybe.?);
}

test "a final view's absent optional is null even with a @default" {
    const bytes = try encode(V.FinalDefaults, .xcdr2, .final, .{ .maybe = null });
    defer t.allocator.free(bytes);
    var r = try cdr.CdrReader.init(bytes);
    var view: V.FinalDefaults.View = .{};
    try V.FinalDefaults.deserializeView(&view, &r, t.allocator);
    defer view.deinit(t.allocator);
    try t.expect(view.maybe == null);
}
