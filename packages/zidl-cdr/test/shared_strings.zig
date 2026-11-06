const std = @import("std");
const rt = @import("zidl_rt");
const adapter = @import("adapter");
const testing = std.testing;
const Reader = adapter.Reader;
const Writer = adapter.Writer;

extern fn shared_strings_sample(*Writer) c_int;
extern fn shared_strings_read_sample(*Reader) c_int;
extern fn zidl_cdr_writer_init(*Writer, c_int) c_int;
extern fn zidl_cdr_writer_init_fixed(*Writer, [*]u8, usize, c_int) void;
extern fn zidl_cdr_writer_init_counting(*Writer, c_int) void;
extern fn zidl_cdr_writer_deinit(*Writer) void;
extern fn zidl_cdr_writer_set_byte_order(*Writer, c_int) void;
extern fn zidl_cdr_write_string(*Writer, ?[*]const u8, u32) c_int;
extern fn zidl_cdr_write_wstring(*Writer, ?[*]const u16, u32) c_int;
extern fn zidl_cdr_reader_init(*Reader, [*]const u8, usize) c_int;
extern fn zidl_cdr_read_string_zerocopy(*Reader, *?[*]const u8, *u32) c_int;
extern fn zidl_cdr_read_string(*Reader, *?[*]u8) c_int;
extern fn zidl_cdr_read_wstring(*Reader, *?[*]u16, *u32) c_int;
extern fn zidl_cdr_free_str(?[*]u8) void;
extern fn zidl_cdr_free_wstr(?[*]u16) void;
extern fn zidl_cdr_set_allocator(?*const rt.ZidlAllocator) void;

// Hand-written payloads: marker, "hi", [0x1234,'Z'], empty string/wstring.
const little = "a500000003000000686900000400000034125a00010000000000000000000000";
const big = "a50000000000000368690000000000041234005a000000010000000000000000";

fn sample(w: *rt.PrimitiveWriter) !void {
    try w.writeU8(0xa5);
    try w.writeString("hi");
    try w.writeWstring(&.{ 0x1234, 'Z' });
    try w.writeString("");
    try w.writeWstring(&.{});
}

fn readSample(r: *rt.CdrReader) !void {
    try testing.expectEqual(@as(u8, 0xa5), try r.readU8());
    try testing.expectEqualStrings("hi", try r.readStringZeroCopy());
    const wide = try r.readWstring(testing.allocator);
    defer testing.allocator.free(wide);
    try testing.expectEqualSlices(u16, &.{ 0x1234, 'Z' }, wide);
    const empty = try r.readString(testing.allocator);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    const empty_wide = try r.readWstring(testing.allocator);
    defer testing.allocator.free(empty_wide);
    try testing.expectEqual(@as(usize, 0), empty_wide.len);
}

test "independent string/wstring vectors in both orders, versions, and storage modes" {
    for ([_]c_int{ 1, 2 }) |version| for ([_]rt.ByteOrder{ .little, .big }) |order| {
        var bytes: [32]u8 = undefined;
        const expected = try std.fmt.hexToBytes(&bytes, if (order == .little) little else big);
        const cap: @FieldType(rt.PrimitiveWriter, "alignment_cap") = if (version == 1) .eight else .four;
        var dynamic = std.ArrayListUnmanaged(u8).empty;
        defer dynamic.deinit(testing.allocator);
        var native = rt.PrimitiveWriter.initDynamic(&dynamic, testing.allocator, cap, order);
        try sample(&native);
        try testing.expectEqualSlices(u8, expected, dynamic.items);
        var fixed: [32]u8 = undefined;
        native = rt.PrimitiveWriter.initFixed(&fixed, cap, order);
        try sample(&native);
        try testing.expectEqualSlices(u8, expected, &fixed);
        native = rt.PrimitiveWriter.initCounting(cap, order);
        try sample(&native);
        try testing.expectEqual(@as(usize, 32), native.len);
        for (0..3) |mode| {
            var w: Writer = undefined;
            switch (mode) {
                0 => try testing.expectEqual(@as(c_int, 0), zidl_cdr_writer_init(&w, version)),
                1 => zidl_cdr_writer_init_fixed(&w, &fixed, fixed.len, version),
                else => zidl_cdr_writer_init_counting(&w, version),
            }
            defer zidl_cdr_writer_deinit(&w);
            zidl_cdr_writer_set_byte_order(&w, if (order == .big) 1 else 0);
            try testing.expectEqual(@as(c_int, 0), shared_strings_sample(&w));
            try testing.expectEqual(@as(usize, 32), w.len);
            try testing.expectEqual(@as(usize, 32), w.pos);
            if (mode != 2) try testing.expectEqualSlices(u8, expected, w.buf.?[0..w.len]);
        }
        var stream: [36]u8 = undefined;
        stream[0..4].* = .{ 0, if (version == 1) (if (order == .big) 0 else 1) else (if (order == .big) 6 else 7), 0, 0 };
        @memcpy(stream[4..], expected);
        var r = try rt.CdrReader.init(&stream);
        try readSample(&r);
        try testing.expectEqual(stream.len, r.pos);
        var foreign: Reader = undefined;
        try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&foreign, &stream, stream.len));
        try testing.expectEqual(@as(c_int, 0), shared_strings_read_sample(&foreign));
        try testing.expectEqual(stream.len, foreign.pos);
        for (4..stream.len) |end| {
            r = try rt.CdrReader.init(stream[0..end]);
            try testing.expectError(error.EndOfStream, readSample(&r));
            try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&foreign, &stream, end));
            try testing.expectEqual(@as(c_int, -2), shared_strings_read_sample(&foreign));
            try testing.expectEqual(r.pos, foreign.pos);
            try testing.expect(r.pos <= end);
        }
    };
}

const Stats = struct {
    calls: usize = 0,
    frees: usize = 0,
    size: usize = 0,
    alignment: usize = 0,
    fail: bool = false,

    fn alloc(ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?[*]u8 {
        const self: *Stats = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.size = size;
        self.alignment = alignment;
        if (self.fail) return null;
        return @ptrCast(std.c.malloc(size));
    }
    fn resize(_: ?*anyopaque, _: ?[*]u8, _: usize, _: usize, _: usize) callconv(.c) bool {
        return false;
    }
    fn free(ctx: ?*anyopaque, ptr: ?[*]u8, size: usize, alignment: usize) callconv(.c) void {
        const self: *Stats = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(size == self.size and alignment == self.alignment);
        self.frees += 1;
        std.c.free(@ptrCast(ptr));
    }
    fn allocator(self: *Stats) rt.ZidlAllocator {
        return .{ .ctx = self, .alloc = alloc, .resize = resize, .free = free };
    }
};

fn initForeign(bytes: []const u8) !Reader {
    var r: Reader = undefined;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&r, bytes.ptr, bytes.len));
    return r;
}

test "malformed narrow terminators, odd wide counts and oversized bodies reject before owned allocation" {
    var stats = Stats{ .fail = true };
    const allocator = stats.allocator();
    zidl_cdr_set_allocator(&allocator);
    defer zidl_cdr_set_allocator(null);
    const cases = [_]struct { bytes: []const u8, wide: bool, invalid: bool }{
        .{ .bytes = &.{ 0, 7, 0, 0, 0, 0, 0, 0 }, .wide = false, .invalid = true },
        .{ .bytes = &.{ 0, 7, 0, 0, 3, 0, 0, 0 }, .wide = true, .invalid = true },
        .{ .bytes = &.{ 0, 7, 0, 0, 2, 0, 0, 0, 'A', 'X' }, .wide = false, .invalid = true },
        .{ .bytes = &.{ 0, 7, 0, 0, 0xff, 0xff, 0xff, 0xff }, .wide = false, .invalid = false },
        .{ .bytes = &.{ 0, 7, 0, 0, 0xfe, 0xff, 0xff, 0xff }, .wide = true, .invalid = false },
        .{ .bytes = &.{ 0, 7, 0, 0, 2, 0, 0, 0, 0x34 }, .wide = true, .invalid = false },
    };
    for (cases) |case| {
        var r = try rt.CdrReader.init(case.bytes);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        const err = if (case.invalid) error.InvalidString else error.EndOfStream;
        if (case.wide) {
            try testing.expectError(err, r.readWstring(failing.allocator()));
        } else {
            try testing.expectError(err, r.readString(failing.allocator()));
        }
        try testing.expectEqual(if (case.invalid) case.bytes.len else @as(usize, 8), r.pos);
        var skip = try rt.CdrReader.init(case.bytes);
        if (case.wide) try testing.expectError(err, skip.skipWstring()) else try testing.expectError(err, skip.skipString());
        try testing.expectEqual(r.pos, skip.pos);
        var foreign = try initForeign(case.bytes);
        var sentinel = [_]u8{'?'};
        var out: ?[*]u8 = &sentinel;
        var wide_sentinel = [_]u16{0xbeef};
        var wide_out: ?[*]u16 = &wide_sentinel;
        var len: u32 = 123;
        const rc = if (case.wide) zidl_cdr_read_wstring(&foreign, &wide_out, &len) else zidl_cdr_read_string(&foreign, &out);
        try testing.expectEqual(@as(c_int, if (case.invalid) -3 else -2), rc);
        try testing.expect(out.? == &sentinel);
        try testing.expect(wide_out.? == &wide_sentinel);
        try testing.expectEqual(@as(u32, 123), len);
        try testing.expectEqual(r.pos, foreign.pos);
        if (!case.wide) {
            foreign = try initForeign(case.bytes);
            var borrowed: ?[*]const u8 = &sentinel;
            try testing.expectEqual(rc, zidl_cdr_read_string_zerocopy(&foreign, &borrowed, &len));
            try testing.expect(borrowed.? == &sentinel);
            try testing.expectEqual(@as(u32, 123), len);
        }
    }
    try testing.expectEqual(@as(usize, 0), stats.calls);
}

test "borrowed and native owned strings retain embedded NULs, C ownership rejects them" {
    var stats = Stats{ .fail = true };
    const allocator = stats.allocator();
    zidl_cdr_set_allocator(&allocator);
    defer zidl_cdr_set_allocator(null);
    const narrow = [_]u8{ 0, 7, 0, 0, 4, 0, 0, 0, 'a', 0, 'b', 0 };
    var r = try rt.CdrReader.init(&narrow);
    const owned = try r.readString(testing.allocator);
    defer testing.allocator.free(owned);
    try testing.expectEqualSlices(u8, &.{ 'a', 0, 'b' }, owned);
    var foreign = try initForeign(&narrow);
    var borrowed: ?[*]const u8 = null;
    var len: u32 = 0;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_string_zerocopy(&foreign, &borrowed, &len));
    try testing.expect(borrowed.? == narrow[8..].ptr);
    try testing.expectEqual(@as(u32, 3), len);
    foreign = try initForeign(&narrow);
    var out: ?[*]u8 = null;
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_read_string(&foreign, &out));
    try testing.expect(out == null);
    const wide = [_]u8{ 0, 6, 0, 0, 0, 0, 0, 6, 0, 'a', 0, 0, 0, 'b' };
    r = try rt.CdrReader.init(&wide);
    const wide_owned = try r.readWstring(testing.allocator);
    defer testing.allocator.free(wide_owned);
    try testing.expectEqualSlices(u16, &.{ 'a', 0, 'b' }, wide_owned);
    foreign = try initForeign(&wide);
    var wide_out: ?[*]u16 = null;
    len = 123;
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_read_wstring(&foreign, &wide_out, &len));
    try testing.expect(wide_out == null);
    try testing.expectEqual(@as(u32, 123), len);
    try testing.expectEqual(wide.len, foreign.pos);
    try testing.expectEqual(@as(usize, 0), stats.calls);
}

test "C owned allocation/free sizes, alignment and OOM remain explicit" {
    var stats = Stats{};
    const allocator = stats.allocator();
    zidl_cdr_set_allocator(&allocator);
    defer zidl_cdr_set_allocator(null);
    const narrow = [_]u8{ 0, 7, 0, 0, 4, 0, 0, 0, 'a', 'b', 'c', 0 };
    const wide = [_]u8{ 0, 6, 0, 0, 0, 0, 0, 4, 0x12, 0x34, 0, 'Z' };
    var foreign = try initForeign(&narrow);
    var out: ?[*]u8 = null;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_string(&foreign, &out));
    try testing.expectEqual(@as(usize, 4), stats.size);
    try testing.expectEqual(@as(usize, 8), stats.alignment);
    try testing.expectEqualSlices(u8, "abc\x00", out.?[0..4]);
    zidl_cdr_free_str(out);
    foreign = try initForeign(&wide);
    var wide_out: ?[*]u16 = null;
    var len: u32 = 123;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_wstring(&foreign, &wide_out, &len));
    try testing.expectEqual(@as(u32, 2), len);
    try testing.expectEqual(@as(usize, 6), stats.size);
    try testing.expectEqualSlices(u16, &.{ 0x1234, 'Z', 0 }, wide_out.?[0..3]);
    zidl_cdr_free_wstr(wide_out);
    try testing.expectEqual(@as(usize, 2), stats.calls);
    try testing.expectEqual(stats.calls, stats.frees);
    stats.fail = true;
    foreign = try initForeign(&narrow);
    out = null;
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_read_string(&foreign, &out));
    try testing.expect(out == null);
    try testing.expectEqual(narrow.len, foreign.pos);
    foreign = try initForeign(&wide);
    wide_out = null;
    len = 123;
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_read_wstring(&foreign, &wide_out, &len));
    try testing.expect(wide_out == null);
    try testing.expectEqual(@as(u32, 123), len);
    try testing.expectEqual(wide.len, foreign.pos);
    var r = try rt.CdrReader.init(&narrow);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, r.readString(failing.allocator()));
    try testing.expectEqual(narrow.len, r.pos);
    r = try rt.CdrReader.init(&wide);
    failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, r.readWstring(failing.allocator()));
    try testing.expectEqual(wide.len, r.pos);
}

test "string fixed-buffer failure preserves partial writes and counting rejects overflowing lengths" {
    var bytes: [9]u8 = @splat(0xcc);
    var foreign: Writer = undefined;
    zidl_cdr_writer_init_fixed(&foreign, &bytes, 6, 2);
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_write_string(&foreign, "hi", 2));
    try testing.expectEqual(@as(usize, 6), foreign.len);
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 'h', 'i' }, bytes[0..6]);
    var native = rt.PrimitiveWriter.initFixed(bytes[0..6], .four, .little);
    try testing.expectError(error.Overflow, native.writeString("hi"));
    try testing.expectEqual(foreign.len, native.len);
    const words = [_]u16{ 0x1234, 'Z' };
    bytes = @splat(0xcc);
    zidl_cdr_writer_init_fixed(&foreign, &bytes, 6, 2);
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_write_wstring(&foreign, &words, words.len));
    try testing.expectEqual(@as(usize, 6), foreign.len);
    try testing.expectEqual(@as(u8, 0xcc), bytes[6]);
    native = rt.PrimitiveWriter.initFixed(bytes[0..6], .four, .little);
    try testing.expectError(error.Overflow, native.writeWstring(&words));
    try testing.expectEqual(foreign.len, native.len);
    zidl_cdr_writer_init_counting(&foreign, 2);
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_write_string(&foreign, null, 0xffffffff));
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_write_wstring(&foreign, null, 0xffffffff));
    try testing.expectEqual(@as(usize, 0), foreign.len);
    try testing.expectEqual(@as(usize, 0), foreign.pos);
}

test "wide input at an odd physical address decodes without borrowing a u16 pointer" {
    const bytes = [_]u8{ 0, 6, 0, 0, 0, 0, 0, 4, 0x12, 0x34, 0, 'Z' };
    var storage: [13]u8 align(2) = undefined;
    @memcpy(storage[1..], &bytes);
    const stream = storage[1..];
    try testing.expect(@intFromPtr(stream.ptr) % 2 == 1);
    var native = try rt.CdrReader.init(stream);
    const value = try native.readWstring(testing.allocator);
    defer testing.allocator.free(value);
    try testing.expectEqualSlices(u16, &.{ 0x1234, 'Z' }, value);
    var foreign = try initForeign(stream);
    var out: ?[*]u16 = null;
    var len: u32 = 0;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_wstring(&foreign, &out, &len));
    defer zidl_cdr_free_wstr(out);
    try testing.expectEqual(@as(u32, 2), len);
    try testing.expectEqualSlices(u16, &.{ 0x1234, 'Z', 0 }, out.?[0..3]);
}
