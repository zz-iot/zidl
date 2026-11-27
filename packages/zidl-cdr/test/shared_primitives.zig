const std = @import("std");
const rt = @import("zidl_cdr_native");
const adapter = @import("adapter");
const Writer = adapter.Writer;
const testing = std.testing;

test {
    _ = @import("shared_strings.zig");
    _ = @import("shared_framing.zig");
}

extern fn shared_primitives_layout(*[17]usize) void;
extern fn shared_primitives_sample(*Writer) c_int;
extern fn zidl_cdr_writer_init_fixed(*Writer, [*]u8, usize, c_int) void;
extern fn zidl_cdr_writer_init_counting(*Writer, c_int) void;
extern fn zidl_cdr_writer_set_byte_order(*Writer, c_int) void;
extern fn zidl_cdr_write_u8(*Writer, u8) c_int;
extern fn zidl_cdr_write_u64(*Writer, u64) c_int;
extern fn zidl_cdr_reserve_dheader(*Writer, *usize) c_int;
extern fn zidl_cdr_patch_dheader(*Writer, usize) void;

const Reader = adapter.Reader;

test "C compiler and Zig adapter agree on every state offset" {
    var c: [17]usize = undefined;
    shared_primitives_layout(&c);
    const zig = [_]usize{
        @sizeOf(Writer),                   @alignOf(Writer),
        @offsetOf(Writer, "buf"),          @offsetOf(Writer, "cap"),
        @offsetOf(Writer, "len"),          @offsetOf(Writer, "pos"),
        @offsetOf(Writer, "xcdr_version"), @offsetOf(Writer, "byte_order"),
        @offsetOf(Writer, "hash"),         @sizeOf(Reader),
        @alignOf(Reader),                  @offsetOf(Reader, "data"),
        @offsetOf(Reader, "data_len"),     @offsetOf(Reader, "pos"),
        @offsetOf(Reader, "byte_order"),   @offsetOf(Reader, "xcdr_version"),
        @offsetOf(Reader, "is_pl_cdr"),
    };
    try testing.expectEqualSlices(usize, &zig, &c);
}

fn sample(w: *rt.RuntimeWriter) !void {
    try w.writeU8(0xab);
    try w.writeI8(-2);
    try w.writeBool(true);
    try w.writeChar('Q');
    try w.writeU16(0x1234);
    try w.writeI16(-3);
    try w.writeU32(0x12345678);
    try w.writeI32(-4);
    try w.writeF32(1.5);
    try w.writeU64(0x0102030405060708);
    try w.writeI64(-5);
    try w.writeF64(2.5);
}

// Hand-written payload known answers; neither codec generates these fixtures.
const vectors = [_]struct { version: c_int, order: rt.ByteOrder, hex: []const u8 }{
    .{ .version = 2, .order = .little, .hex = "abfe01513412fdff78563412fcffffff0000c03f0807060504030201fbffffffffffffff0000000000000440" },
    .{ .version = 2, .order = .big, .hex = "abfe01511234fffd12345678fffffffc3fc000000102030405060708fffffffffffffffb4004000000000000" },
    .{ .version = 1, .order = .little, .hex = "abfe01513412fdff78563412fcffffff0000c03f000000000807060504030201fbffffffffffffff0000000000000440" },
    .{ .version = 1, .order = .big, .hex = "abfe01511234fffd12345678fffffffc3fc00000000000000102030405060708fffffffffffffffb4004000000000000" },
};

test "independent primitive vectors through native and C paths in all storage modes" {
    for (vectors) |v| {
        var expected_buf: [48]u8 = undefined;
        const expected = try std.fmt.hexToBytes(&expected_buf, v.hex);
        const cap: rt.XcdrVersion = if (v.version == 2) .xcdr2 else .xcdr1;
        var fixed: [48]u8 = undefined;
        var native_fixed = rt.RuntimeWriter.initFixed(fixed[0..expected.len], cap, v.order);
        try sample(&native_fixed);
        try testing.expectEqualSlices(u8, expected, fixed[0..native_fixed.len]);
        var native_counting = rt.RuntimeWriter.initCounting(cap, v.order);
        try sample(&native_counting);
        try testing.expectEqual(expected.len, native_counting.len);
        try testing.expectEqual(expected.len, native_counting.pos);

        for (1..3) |mode| {
            var w: Writer = undefined;
            if (mode == 1) zidl_cdr_writer_init_fixed(&w, &fixed, expected.len, v.version) else zidl_cdr_writer_init_counting(&w, v.version);
            zidl_cdr_writer_set_byte_order(&w, if (v.order == .big) 1 else 0);
            try testing.expectEqual(@as(c_int, 0), shared_primitives_sample(&w));
            try testing.expectEqual(expected.len, w.len);
            try testing.expectEqual(expected.len, w.pos);
            if (mode != 2) try testing.expectEqualSlices(u8, expected, w.buf.?[0..w.len]);
            if (mode == 2) try testing.expect(w.buf == null);
        }
    }
}

test "fixed overflow preserves consumed alignment padding" {
    var bytes: [8]u8 = @splat(0xcc);
    var w: Writer = undefined;
    zidl_cdr_writer_init_fixed(&w, &bytes, bytes.len, 1);
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_write_u8(&w, 0xab));
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_write_u64(&w, 42));
    try testing.expectEqual(@as(usize, 8), w.len);
    try testing.expectEqualSlices(u8, &.{ 0xab, 0, 0, 0, 0, 0, 0, 0 }, &bytes);
    var n = rt.RuntimeWriter.initFixed(&bytes, .xcdr1, .little);
    try n.writeU8(0xab);
    try testing.expectError(error.Overflow, n.writeU64(42));
    try testing.expectEqual(w.len, n.len);
    try testing.expectEqual(w.pos, n.pos);
}

test "counting overflow is recoverable and does not wrap counters" {
    var w: Writer = undefined;
    zidl_cdr_writer_init_counting(&w, 2);
    w.len = std.math.maxInt(usize);
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_write_u8(&w, 1));
    try testing.expectEqual(std.math.maxInt(usize), w.len);
    try testing.expectEqual(@as(usize, 0), w.pos);
    zidl_cdr_writer_init_counting(&w, 2);
    w.pos = std.math.maxInt(usize);
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_write_u8(&w, 1));
    try testing.expectEqual(@as(usize, 0), w.len);
    var n = rt.RuntimeWriter.initCounting(.xcdr2, .little);
    n.pos = std.math.maxInt(usize);
    try testing.expectError(error.Overflow, n.writeU8(1));
    try testing.expectEqual(@as(usize, 0), n.len);
}

test "remaining C framing uses shared primitives and patches BE or counting storage" {
    for ([_]bool{ false, true }) |counting| {
        var bytes: [16]u8 = undefined;
        var w: Writer = undefined;
        if (counting) zidl_cdr_writer_init_counting(&w, 2) else zidl_cdr_writer_init_fixed(&w, &bytes, bytes.len, 2);
        zidl_cdr_writer_set_byte_order(&w, 1);
        var offset: usize = undefined;
        try testing.expectEqual(@as(c_int, 0), zidl_cdr_reserve_dheader(&w, &offset));
        try testing.expectEqual(@as(c_int, 0), zidl_cdr_write_u8(&w, 0xab));
        zidl_cdr_patch_dheader(&w, offset);
        try testing.expectEqual(@as(usize, 5), w.len);
        if (!counting) try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0xab }, bytes[0..w.len]);
    }
}

extern fn zidl_cdr_set_allocator(?*const @import("c_header").ZidlAllocator) void;

const FailAlloc = struct {
    calls: usize = 0,
    alignment: usize = 0,

    fn alloc(ctx: ?*anyopaque, _: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *FailAlloc = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.alignment = alignment;
        return null;
    }

    fn resize(_: ?*anyopaque, _: ?*anyopaque, _: usize, _: usize, _: usize) callconv(.c) bool {
        return false;
    }

    fn free(_: ?*anyopaque, _: ?*anyopaque, _: usize, _: usize) callconv(.c) void {
        unreachable; // No successful allocation in this test.
    }
};

extern fn zidl_cdr_serialize_alloc(c_int, c_int, *const fn (*Writer, ?*const anyopaque) callconv(.c) c_int, ?*const anyopaque, *?[*]u8, *usize) c_int;
extern fn zidl_cdr_free(?*anyopaque, usize) void;
extern fn zidl_cdr_writer_is_counting(*const Writer) c_int;

/// Writes `ctx.*` bytes after the header, changing the count between passes
/// by `ctx.grow` (a sample changed while it was written).
const Payload = struct {
    len: usize,
    grow: isize = 0,
    passes: usize = 0,

    fn write(w: *Writer, raw: ?*const anyopaque) callconv(.c) c_int {
        const self: *Payload = @ptrCast(@alignCast(@constCast(raw.?)));
        defer self.passes += 1;
        if (zidl_cdr_writer_is_counting(w) != 0) {
            if (w.buf != null) return -9;
        } else if (w.buf == null) return -9;
        const n: usize = if (self.passes == 0) self.len else @intCast(@as(isize, @intCast(self.len)) + self.grow);
        for (0..n) |i| {
            const rc = zidl_cdr_write_u8(w, @truncate(i));
            if (rc != 0) return rc;
        }
        return 0;
    }
};

test "serialize_alloc counts, allocates exactly, writes, and rejects a changed sample" {
    var p = Payload{ .len = 7 };
    var out: ?[*]u8 = null;
    var len: usize = 0;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_serialize_alloc(2, 1, Payload.write, &p, &out, &len));
    try testing.expectEqual(@as(usize, 7), len);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6 }, out.?[0..len]);
    zidl_cdr_free(out, len);
    // Grew: the fixed pass runs out of room. Shrank: a short write.
    for ([_]isize{ 1, -1 }, [_]c_int{ -1, -3 }) |grow, want| {
        p = .{ .len = 7, .grow = grow };
        out = null;
        try testing.expectEqual(want, zidl_cdr_serialize_alloc(2, 0, Payload.write, &p, &out, &len));
        try testing.expect(out == null);
    }
    // Empty: nothing to allocate.
    p = .{ .len = 0 };
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_serialize_alloc(2, 0, Payload.write, &p, &out, &len));
    try testing.expect(out == null);
    try testing.expectEqual(@as(usize, 0), len);
    // A counting-pass failure is returned as is.
    var fail = Payload{ .len = 1 };
    const failing = struct {
        fn write(_: *Writer, _: ?*const anyopaque) callconv(.c) c_int {
            return -3;
        }
    };
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_serialize_alloc(2, 0, failing.write, &fail, &out, &len));
}

test "serialize_alloc OOM keeps the registered allocator and status contract" {
    var tracker = FailAlloc{};
    const allocator = @import("c_header").ZidlAllocator{ .ctx = &tracker, .alloc = FailAlloc.alloc, .resize = FailAlloc.resize, .free = FailAlloc.free };
    zidl_cdr_set_allocator(&allocator);
    defer zidl_cdr_set_allocator(null);
    var p = Payload{ .len = 8 };
    var out: ?[*]u8 = null;
    var len: usize = 0;
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_serialize_alloc(2, 0, Payload.write, &p, &out, &len));
    try testing.expectEqual(@as(usize, 1), tracker.calls);
    try testing.expectEqual(@as(usize, 8), tracker.alignment);
    try testing.expect(out == null);
}

extern fn shared_primitives_read_sample(*Reader) c_int;
extern fn zidl_cdr_reader_init(*Reader, [*]const u8, usize) c_int;
extern fn zidl_cdr_read_u8(*Reader, *u8) c_int;
extern fn zidl_cdr_read_u32(*Reader, *u32) c_int;
extern fn zidl_cdr_read_u64(*Reader, *u64) c_int;
extern fn zidl_cdr_read_bool(*Reader, *bool) c_int;
extern fn zidl_cdr_skip(*Reader, usize) c_int;
extern fn zidl_cdr_skip_primitives(*Reader, u32, usize) c_int;
extern fn zidl_cdr_seek_to(*Reader, usize) c_int;

fn readSample(r: *rt.CdrReader) !void {
    try testing.expectEqual(@as(u8, 0xab), try r.readU8());
    try testing.expectEqual(@as(i8, -2), try r.readI8());
    try testing.expect(try r.readBool());
    try testing.expectEqual(@as(u8, 'Q'), try r.readChar());
    try testing.expectEqual(@as(u16, 0x1234), try r.readU16());
    try testing.expectEqual(@as(i16, -3), try r.readI16());
    try testing.expectEqual(@as(u32, 0x12345678), try r.readU32());
    try testing.expectEqual(@as(i32, -4), try r.readI32());
    try testing.expectEqual(@as(f32, 1.5), try r.readF32());
    try testing.expectEqual(@as(u64, 0x0102030405060708), try r.readU64());
    try testing.expectEqual(@as(i64, -5), try r.readI64());
    try testing.expectEqual(@as(f64, 2.5), try r.readF64());
}

test "native and real C callers decode independent vectors and every truncated prefix" {
    for (vectors) |v| {
        var stream: [52]u8 = undefined;
        stream[0..4].* = .{ 0, if (v.version == 2) (if (v.order == .big) 6 else 7) else (if (v.order == .big) 0 else 1), 0, 0 };
        const payload = try std.fmt.hexToBytes(stream[4..], v.hex);
        const bytes = stream[0 .. 4 + payload.len];
        var native = try rt.CdrReader.init(bytes);
        var foreign: Reader = undefined;
        try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&foreign, bytes.ptr, bytes.len));
        try readSample(&native);
        try testing.expectEqual(@as(c_int, 0), shared_primitives_read_sample(&foreign));
        try testing.expectEqual(bytes.len, native.pos);
        try testing.expectEqual(bytes.len, foreign.pos);
        for (4..bytes.len) |len| {
            native = try rt.CdrReader.init(bytes[0..len]);
            try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&foreign, bytes.ptr, len));
            try testing.expectError(error.EndOfStream, readSample(&native));
            try testing.expectEqual(@as(c_int, -2), shared_primitives_read_sample(&foreign));
            try testing.expect(native.pos <= len);
            try testing.expectEqual(native.pos, foreign.pos);
        }
    }
}

test "reader skip overflow, invalid positions and failed seek preserve the cursor" {
    const bytes = [_]u8{ 0, 1, 0, 0, 0xaa, 0, 0, 0 };
    var native = try rt.CdrReader.init(&bytes);
    var foreign: Reader = undefined;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&foreign, &bytes, bytes.len));
    try testing.expectError(error.EndOfStream, native.skip(std.math.maxInt(usize)));
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_skip(&foreign, std.math.maxInt(usize)));
    try testing.expectEqual(@as(usize, 4), native.pos);
    try testing.expectEqual(@as(usize, 4), foreign.pos);
    try testing.expectError(error.EndOfStream, native.seekTo(std.math.maxInt(usize)));
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_seek_to(&foreign, std.math.maxInt(usize)));
    try testing.expectEqual(@as(usize, 4), foreign.pos);
    native.pos = std.math.maxInt(usize);
    foreign.pos = native.pos;
    try testing.expectError(error.EndOfStream, native.readU32());
    var out: u32 = 42;
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_read_u32(&foreign, &out));
    try testing.expectEqual(@as(u32, 42), out);
    try testing.expectEqual(std.math.maxInt(usize), foreign.pos);
    try native.seekTo(2);
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_seek_to(&foreign, 2));
    try testing.expectError(error.EndOfStream, native.readU32());
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_read_u32(&foreign, &out));
    try testing.expectEqual(@as(usize, 2), native.pos);
    try testing.expectEqual(@as(usize, 2), foreign.pos);
    // Byte reads remain permitted after seeking into the encapsulation.
    try testing.expectEqual(@as(u8, 0), try native.readU8());
    var byte: u8 = 0xff;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_u8(&foreign, &byte));
    try testing.expectEqual(@as(u8, 0), byte);
}

test "truncated alignment clamps, failed values preserve C output, empty runs do not align" {
    const bytes = [_]u8{ 0, 1, 0, 0, 0xaa, 0 };
    var native = try rt.CdrReader.init(&bytes);
    var foreign: Reader = undefined;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&foreign, &bytes, bytes.len));
    _ = try native.readU8();
    var byte: u8 = 0;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_u8(&foreign, &byte));
    try native.skipPrimitives(0, 8);
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_skip_primitives(&foreign, 0, 8));
    try testing.expectEqual(@as(usize, 5), native.pos);
    try testing.expectEqual(@as(usize, 5), foreign.pos);
    try testing.expectError(error.EndOfStream, native.readU64());
    var value: u64 = 42;
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_read_u64(&foreign, &value));
    try testing.expectEqual(@as(u64, 42), value);
    try testing.expectEqual(bytes.len, native.pos);
    try testing.expectEqual(bytes.len, foreign.pos);
    try native.seekTo(4);
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_seek_to(&foreign, 4));
    try testing.expectError(error.EndOfStream, native.skipPrimitives(std.math.maxInt(usize), 8));
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_skip_primitives(&foreign, 0xffffffff, 8));
    try testing.expectError(error.InvalidPrimitiveSize, native.skipPrimitives(1, 0));
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_skip_primitives(&foreign, 1, 0));
}

test "invalid bool consumes its byte and leaves the C output unchanged" {
    const bytes = [_]u8{ 0, 7, 0, 0, 2 };
    var native = try rt.CdrReader.init(&bytes);
    var foreign: Reader = undefined;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&foreign, &bytes, bytes.len));
    var out = true;
    try testing.expectError(error.InvalidBool, native.readBool());
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_read_bool(&foreign, &out));
    try testing.expect(out);
    try testing.expectEqual(bytes.len, native.pos);
    try testing.expectEqual(bytes.len, foreign.pos);
}

extern fn optional_wire_tests() c_int;
test "optional member C ABI independent wire witnesses" {
    try std.testing.expectEqual(@as(c_int, 0), optional_wire_tests());
}

extern fn optional_layout(*[9]usize) void;
test "optional scope C and Zig layouts agree" {
    var actual: [9]usize = undefined;
    optional_layout(&actual);
    const W = adapter.OptionalWrite;
    const R = adapter.OptionalRead;
    const expected = [_]usize{
        @sizeOf(W),                  @alignOf(W),                @offsetOf(W, "length_offset"),
        @offsetOf(W, "value_start"), @offsetOf(W, "parent_pos"), @sizeOf(R),
        @alignOf(R),                 @offsetOf(R, "parent"),     @offsetOf(R, "end"),
    };
    try testing.expectEqualSlices(usize, &expected, &actual);
}

const FixedAPI = struct {
    pub const ZidlCdrWriter = adapter.Writer;
    pub const ZidlCdrReader = adapter.Reader;
    pub extern fn zidl_cdr_writer_init_fixed(*ZidlCdrWriter, [*]u8, usize, c_int) void;
    pub extern fn zidl_cdr_writer_init_counting(*ZidlCdrWriter, c_int) void;
    pub extern fn zidl_cdr_writer_set_byte_order(*ZidlCdrWriter, c_int) void;
    pub extern fn zidl_cdr_write_encap(*ZidlCdrWriter) c_int;
    pub extern fn zidl_cdr_write_u8(*ZidlCdrWriter, u8) c_int;
    pub extern fn zidl_cdr_write_fixed(*ZidlCdrWriter, u8, u8, f64) c_int;
    pub extern fn zidl_cdr_reader_init(*ZidlCdrReader, [*]const u8, usize) c_int;
    pub extern fn zidl_cdr_read_u8(*ZidlCdrReader, *u8) c_int;
    pub extern fn zidl_cdr_read_fixed(*ZidlCdrReader, u8, u8, *f64) c_int;
};
test "shared C ABI fixed decimal contract" {
    try @import("fixed_contract.zig").check(FixedAPI);
}

extern fn bulk_primitive_arrays() c_int;
test "C bulk primitives match scalar CDR across representations and error cases" {
    try testing.expectEqual(@as(c_int, 0), bulk_primitive_arrays());
}

extern fn zidl_cdr_key_hash_init(*adapter.KeyHash) void;
extern fn zidl_cdr_key_hash_finish(*adapter.KeyHash, bool, *[16]u8) void;
extern fn zidl_cdr_compute_key_hash_for_type(?[*]const u8, usize, bool, *[16]u8) void;
extern fn zidl_cdr_write_primitives(*Writer, ?*const anyopaque, usize, usize) c_int;
extern fn zidl_cdr_write_bool_array(*Writer, ?[*]const bool, usize) c_int;
extern fn zidl_cdr_reserve_primitives(*Writer, usize, usize, *adapter.Reservation) c_int;

fn arrays(w: *Writer, wide: []const u64, flags: []const bool) !void {
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_write_u8(w, 1));
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_write_primitives(w, wide.ptr, wide.len, 8));
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_write_bool_array(w, flags.ptr, flags.len));
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_write_primitives(w, wide.ptr, 3, 2));
}

test "key hash streams primitive and bool arrays in chunks" {
    // More than one 256-byte chunk of each.
    var wide: [100]u64 = undefined;
    for (&wide, 0..) |*v, i| v.* = 0x0102030405060708 *% (i + 1);
    var flags: [300]bool = undefined;
    for (&flags, 0..) |*f, i| f.* = i % 3 == 0;
    var storage: [2048]u8 = undefined;
    var fixed: Writer = undefined;
    zidl_cdr_writer_init_fixed(&fixed, &storage, storage.len, 2);
    zidl_cdr_writer_set_byte_order(&fixed, 1);
    try arrays(&fixed, &wide, &flags);
    var want: [16]u8 = undefined;
    zidl_cdr_compute_key_hash_for_type(&storage, fixed.len, true, &want);
    var h: adapter.KeyHash = undefined;
    zidl_cdr_key_hash_init(&h);
    try arrays(&h.writer, &wide, &flags);
    try testing.expectEqual(fixed.len, h.writer.len);
    var got: [16]u8 = undefined;
    zidl_cdr_key_hash_finish(&h, true, &got);
    try testing.expectEqualSlices(u8, &want, &got);
    // Nothing to fill in place, and no values to read.
    var res: adapter.Reservation = undefined;
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_reserve_primitives(&h.writer, 2, 4, &res));
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_write_primitives(&h.writer, null, 2, 4));
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_write_bool_array(&h.writer, null, 2));
    try testing.expectEqual(fixed.len, h.writer.len);
}
