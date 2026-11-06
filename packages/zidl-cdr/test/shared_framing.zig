const std = @import("std");
const rt = @import("zidl_rt");
const adapter = @import("adapter");
const testing = std.testing;
const Reader = adapter.Reader;
const Writer = adapter.Writer;
const EmHeader = adapter.EmHeader;
extern fn shared_framing_layout(*[6]usize) void;
extern fn shared_framing_sample(*Writer) c_int;
extern fn shared_framing_read_sample(*Reader) c_int;
extern fn zidl_cdr_writer_init(*Writer, c_int) c_int;
extern fn zidl_cdr_writer_init_fixed(*Writer, [*]u8, usize, c_int) void;
extern fn zidl_cdr_writer_init_counting(*Writer, c_int) void;
extern fn zidl_cdr_writer_deinit(*Writer) void;
extern fn zidl_cdr_writer_set_byte_order(*Writer, c_int) void;
extern fn zidl_cdr_write_encap_kind(*Writer, c_int) c_int;
extern fn zidl_cdr_write_u8(*Writer, u8) c_int;
extern fn zidl_cdr_read_u32(*Reader, *u32) c_int;
extern fn zidl_cdr_write_emheader(*Writer, u32, bool, u8) c_int;
extern fn zidl_cdr_reserve_dheader(*Writer, *usize) c_int;
extern fn zidl_cdr_reserve_emheader(*Writer, u32, bool, *usize) c_int;
extern fn zidl_cdr_patch_dheader_checked(*Writer, usize) c_int;
extern fn zidl_cdr_patch_emheader_checked(*Writer, usize, usize) c_int;
extern fn zidl_cdr_patch_dheader(*Writer, usize) void;
extern fn zidl_cdr_patch_emheader(*Writer, usize, usize) void;
extern fn zidl_cdr_reader_init(*Reader, [*]const u8, usize) c_int;
extern fn zidl_cdr_reader_limit(*const Reader, usize, *Reader) c_int;
extern fn zidl_cdr_read_mutable_dheader(*Reader, *usize) c_int;
extern fn zidl_cdr_read_emheader(*Reader, *EmHeader) c_int;
extern fn zidl_cdr_emheader_end(*const Reader, *const EmHeader, *usize) c_int;
extern fn zidl_cdr_skip_emheader_payload(*Reader, *const EmHeader) c_int;
extern fn zidl_cdr_skip_dheader_if_xcdr2(*Reader) c_int;

const little = "000b000014000000050000a0785634120900004004000000a5003412";
const big = "000a000000000014a0000005123456784000000900000004a5001234";

fn sample(w: anytype) !void {
    try w.writeEncapHeaderMutable();
    const dh = try w.reserveDheader();
    try w.writeEmheaderFixed(5, true, 2);
    try w.writeU32(0x12345678);
    const em = try w.reserveEmheader(9, false);
    try w.writeU8(0xa5);
    try w.writeU16(0x1234);
    try w.patchEmheaderChecked(em);
    try w.patchDheaderChecked(dh);
}

fn readSample(r: *rt.CdrReader) !void {
    const end = try r.readMutableDheader();
    var parent = try r.limited(end);
    const fixed = try parent.readEmheader();
    try testing.expectEqual(@as(u28, 5), fixed.member_id);
    try testing.expect(fixed.must_understand);
    const fixed_end = try parent.emheaderEnd(fixed);
    var member = try parent.limited(fixed_end);
    try testing.expectEqual(@as(u32, 0x12345678), try member.readU32());
    try parent.seekTo(fixed_end);
    const variable = try parent.readEmheader();
    try testing.expectEqual(@as(u28, 9), variable.member_id);
    try testing.expectEqual(@as(u3, 4), variable.lc);
    member = try parent.limited(try parent.emheaderEnd(variable));
    try testing.expectEqual(@as(u8, 0xa5), try member.readU8());
    try testing.expectEqual(@as(u16, 0x1234), try member.readU16());
    try testing.expectEqual(end, member.pos);
    try r.seekTo(end);
}

fn foreign(bytes: []const u8) !Reader {
    var r: Reader = undefined;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_init(&r, bytes.ptr, bytes.len));
    return r;
}

test "EMHEADER C layout is preserved" {
    var c: [6]usize = undefined;
    shared_framing_layout(&c);
    const zig = [_]usize{ @sizeOf(EmHeader), @alignOf(EmHeader), @offsetOf(EmHeader, "member_id"), @offsetOf(EmHeader, "must_understand"), @offsetOf(EmHeader, "lc"), @offsetOf(EmHeader, "payload_bytes") };
    try testing.expectEqualSlices(usize, &zig, &c);
}

test "framing known answers through native/C, both byte orders and every storage mode" {
    for ([_]rt.ByteOrder{ .little, .big }) |order| {
        var expected: [28]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, if (order == .little) little else big);
        var dynamic = std.ArrayListUnmanaged(u8).empty;
        defer dynamic.deinit(testing.allocator);
        var native = rt.PrimitiveWriter.initDynamic(&dynamic, testing.allocator, .four, order);
        try sample(&native);
        try testing.expectEqualSlices(u8, &expected, dynamic.items);
        var bytes: [28]u8 = undefined;
        native = rt.PrimitiveWriter.initFixed(&bytes, .four, order);
        try sample(&native);
        try testing.expectEqualSlices(u8, &expected, &bytes);
        native = rt.PrimitiveWriter.initCounting(.four, order);
        try sample(&native);
        try testing.expectEqual(@as(usize, 28), native.len);
        try testing.expectEqual(@as(usize, 24), native.pos);
        for (0..3) |mode| {
            var w: Writer = undefined;
            switch (mode) {
                0 => try testing.expectEqual(@as(c_int, 0), zidl_cdr_writer_init(&w, 2)),
                1 => zidl_cdr_writer_init_fixed(&w, &bytes, bytes.len, 2),
                else => zidl_cdr_writer_init_counting(&w, 2),
            }
            defer zidl_cdr_writer_deinit(&w);
            zidl_cdr_writer_set_byte_order(&w, if (order == .little) 0 else 1);
            try testing.expectEqual(@as(c_int, 0), shared_framing_sample(&w));
            try testing.expectEqual(@as(usize, 28), w.len);
            try testing.expectEqual(@as(usize, 24), w.pos);
            if (mode != 2) try testing.expectEqualSlices(u8, &expected, w.buf.?[0..w.len]);
        }
        var reader = try rt.CdrReader.init(&expected);
        try readSample(&reader);
        var c = try foreign(&expected);
        try testing.expectEqual(@as(c_int, 0), shared_framing_read_sample(&c));
        try testing.expectEqual(@as(usize, 28), c.pos);
        for (4..expected.len) |len| {
            reader = try rt.CdrReader.init(expected[0..len]);
            try testing.expectError(error.EndOfStream, readSample(&reader));
            c = try foreign(expected[0..len]);
            try testing.expectEqual(@as(c_int, -2), shared_framing_read_sample(&c));
            try testing.expectEqual(reader.pos, c.pos);
        }
        if (order == .little) {
            var legacy_buffer = std.ArrayListUnmanaged(u8).empty;
            defer legacy_buffer.deinit(testing.allocator);
            var legacy = rt.CdrWriter(.xcdr2).init(&legacy_buffer, testing.allocator);
            try sample(&legacy);
            try testing.expectEqualSlices(u8, &expected, legacy_buffer.items);
        }
    }
}

test "all encapsulation IDs preserve endian, version, PL distinction and unused options" {
    for ([_]u8{ 0, 1, 2, 3, 6, 7, 8, 9, 10, 11 }) |id| {
        const bytes = [_]u8{ 0, id, 0xab, 0xcd };
        const r = try rt.CdrReader.init(&bytes);
        const c = try foreign(&bytes);
        try testing.expectEqual(id < 4, r.xcdr_version == .xcdr1);
        try testing.expectEqual(id % 2 == 0, r.byte_order == .big);
        try testing.expectEqual(id == 2 or id == 3, r.is_pl_cdr);
        try testing.expectEqual(@as(c_int, if (id < 4) 1 else 2), c.xcdr_version);
        try testing.expectEqual(@as(c_int, if (id % 2 == 0) 1 else 0), c.byte_order);
        try testing.expectEqual(@as(c_int, @intFromBool(id == 2 or id == 3)), c.is_pl_cdr);
    }
    for ([_]c_int{ 1, 2, 3 }) |version| for ([_]c_int{ 0, 1 }) |order| for ([_]c_int{ 0, 1, 2 }) |kind| {
        var bytes: [4]u8 = undefined;
        var w: Writer = undefined;
        zidl_cdr_writer_init_fixed(&w, &bytes, bytes.len, version);
        zidl_cdr_writer_set_byte_order(&w, order);
        try testing.expectEqual(@as(c_int, 0), zidl_cdr_write_encap_kind(&w, kind));
        const base: u8 = if (version == 1) 0 else if (version == 3) 2 else if (kind == 0) 6 else if (kind == 1) 8 else 10;
        try testing.expectEqualSlices(u8, &.{ 0, base + @as(u8, if (order == 0) 1 else 0), 0, 0 }, &bytes);
        try testing.expectEqual(@as(usize, 0), w.pos);
    };
}

test "bounded parent/member copies prevent reads through following bytes" {
    var bytes: [28]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, little);
    bytes[4] = 4; // Parent contains only the fixed EMHEADER, not its value.
    var r = try rt.CdrReader.init(&bytes);
    const end = try r.readMutableDheader();
    try testing.expectEqual(@as(usize, 12), end);
    var parent = try r.limited(end);
    const em = try parent.readEmheader();
    try testing.expectError(error.EndOfStream, parent.emheaderEnd(em));
    try testing.expectError(error.EndOfStream, parent.readU32());
    try testing.expectEqual(@as(usize, 8), r.pos);
    var c = try foreign(&bytes);
    var c_end: usize = 0;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_mutable_dheader(&c, &c_end));
    var c_parent: Reader = undefined;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_reader_limit(&c, c_end, &c_parent));
    var c_em: EmHeader = undefined;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_emheader(&c_parent, &c_em));
    var member_end: usize = 123;
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_emheader_end(&c_parent, &c_em, &member_end));
    try testing.expectEqual(@as(usize, 123), member_end);
    var value: u32 = 42;
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_read_u32(&c_parent, &value));
    try testing.expectEqual(@as(u32, 42), value);
    const before = c_parent;
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_reader_limit(&c, bytes.len + 1, &c_parent));
    try testing.expectEqual(before.data_len, c_parent.data_len);
    try testing.expectEqual(before.pos, c_parent.pos);
    try testing.expectEqual(@as(usize, 8), c.pos);
}

test "LC5-7 peek NEXTINT and validate the whole member span" {
    const cases = [_]struct { bytes: []const u8, size: u32, lc: u3 }{
        .{ .bytes = &.{ 0, 7, 0, 0, 9, 0, 0, 0x50, 3, 0, 0, 0, 0xaa, 0xbb, 0xcc }, .size = 7, .lc = 5 },
        .{ .bytes = &.{ 0, 7, 0, 0, 9, 0, 0, 0x60, 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0 }, .size = 12, .lc = 6 },
        .{ .bytes = &.{ 0, 7, 0, 0, 9, 0, 0, 0x70, 1, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1 }, .size = 12, .lc = 7 },
    };
    for (cases) |case| {
        var r = try rt.CdrReader.init(case.bytes);
        const em = try r.readEmheader();
        try testing.expectEqual(case.lc, em.lc);
        try testing.expectEqual(case.size, em.payload_bytes);
        try testing.expectEqual(@as(usize, 8), r.pos);
        try testing.expectEqual(case.bytes.len, try r.emheaderEnd(em));
        var c = try foreign(case.bytes);
        var c_em: EmHeader = undefined;
        try testing.expectEqual(@as(c_int, 0), zidl_cdr_read_emheader(&c, &c_em));
        try testing.expectEqual(@as(usize, 8), c.pos);
        var end: usize = 0;
        try testing.expectEqual(@as(c_int, 0), zidl_cdr_emheader_end(&c, &c_em, &end));
        try testing.expectEqual(case.bytes.len, end);
        try testing.expectEqual(@as(c_int, 0), zidl_cdr_skip_emheader_payload(&c, &c_em));
        try testing.expectEqual(end, c.pos);
        var limited = try r.limited(case.bytes.len - 1);
        try testing.expectError(error.EndOfStream, limited.emheaderEnd(em));
    }
}

test "malformed framing and invalid EMHEADER fields return recoverable errors" {
    for ([_][]const u8{ &.{ 0, 7, 0, 0, 0xff, 0xff, 0xff, 0xff }, &.{ 0, 7, 0, 0, 1, 0, 0, 0 } }) |bytes| {
        var r = try rt.CdrReader.init(bytes);
        try testing.expectError(error.EndOfStream, r.readMutableDheader());
        var c = try foreign(bytes);
        var end: usize = 123;
        try testing.expectEqual(@as(c_int, -2), zidl_cdr_read_mutable_dheader(&c, &end));
        try testing.expectEqual(@as(usize, 123), end);
        try testing.expectEqual(@as(usize, 8), c.pos);
        c = try foreign(bytes);
        try testing.expectEqual(@as(c_int, -2), zidl_cdr_skip_dheader_if_xcdr2(&c));
    }
    for ([_]u8{ 0x50, 0x60, 0x70 }) |lc| {
        const bytes = [_]u8{ 0, 7, 0, 0, 9, 0, 0, lc, 0xff, 0xff, 0xff, 0xff };
        var r = try rt.CdrReader.init(&bytes);
        try testing.expectError(error.InvalidEmheader, r.readEmheader());
        try testing.expectEqual(@as(usize, 8), r.pos);
        var c = try foreign(&bytes);
        var em = EmHeader{ .member_id = 42, .must_understand = true, .lc = 1, .payload_bytes = 2 };
        try testing.expectEqual(@as(c_int, -3), zidl_cdr_read_emheader(&c, &em));
        try testing.expectEqual(@as(u32, 42), em.member_id);
        try testing.expectEqual(@as(usize, 8), c.pos);
    }
    var w: Writer = undefined;
    zidl_cdr_writer_init_counting(&w, 2);
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_write_emheader(&w, 0x10000000, false, 2));
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_write_emheader(&w, 1, false, 4));
    try testing.expectEqual(@as(usize, 0), w.len);
}

test "checked patch failures leave storage untouched; legacy void calls are safe no-ops" {
    var bytes: [8]u8 = .{ 0, 0, 0, 0, 0x78, 0x56, 0x34, 0x12 };
    const snapshot = bytes;
    var w: Writer = undefined;
    zidl_cdr_writer_init_fixed(&w, &bytes, bytes.len, 2);
    w.len = bytes.len;
    w.pos = bytes.len;
    const max = std.math.maxInt(usize);
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_patch_dheader_checked(&w, max));
    try testing.expectEqual(@as(c_int, -3), zidl_cdr_patch_emheader_checked(&w, 0, 7));
    zidl_cdr_patch_dheader(&w, max);
    zidl_cdr_patch_emheader(&w, max, max);
    try testing.expectEqualSlices(u8, &snapshot, &bytes);
    try testing.expectEqual(@as(usize, 8), w.len);
    var n = rt.PrimitiveWriter.initFixed(&bytes, .four, .little);
    n.len = bytes.len;
    try testing.expectError(error.InvalidPatch, n.patchDheaderChecked(max));
    n.patchDheader(max);
    try testing.expectEqualSlices(u8, &snapshot, &bytes);
    if (@bitSizeOf(usize) > 32) {
        zidl_cdr_writer_init_counting(&w, 2);
        w.len = @as(usize, std.math.maxInt(u32)) + 5;
        try testing.expectEqual(@as(c_int, -1), zidl_cdr_patch_dheader_checked(&w, 0));
        try testing.expectEqual(@as(c_int, -1), zidl_cdr_patch_emheader_checked(&w, 0, 4));
        n = rt.PrimitiveWriter.initCounting(.four, .little);
        n.len = w.len;
        try testing.expectError(error.Overflow, n.patchDheaderChecked(0));
    }
}

test "reservation failures retain padding and C offset-output progress" {
    var bytes: [4]u8 = undefined;
    var w: Writer = undefined;
    zidl_cdr_writer_init_fixed(&w, &bytes, bytes.len, 2);
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_write_u8(&w, 0xaa));
    var offset: usize = 123;
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_reserve_dheader(&w, &offset));
    try testing.expectEqual(@as(usize, 4), offset);
    try testing.expectEqual(@as(usize, 4), w.len);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0, 0, 0 }, &bytes);
    zidl_cdr_writer_init_fixed(&w, &bytes, bytes.len, 2);
    offset = 123;
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_reserve_emheader(&w, 9, false, &offset));
    try testing.expectEqual(@as(usize, 4), offset);
    try testing.expectEqual(@as(usize, 4), w.len);
}

extern fn shared_pl_layout(*[9]usize) void;
extern fn shared_pl_sample(*Writer) c_int;
extern fn zidl_cdr_pl_write_encap(*Writer) c_int;
extern fn zidl_cdr_pl_reserve_param(*Writer, u16, *adapter.PlHandle) c_int;
extern fn zidl_cdr_pl_patch_param(*Writer, adapter.PlHandle) c_int;
extern fn zidl_cdr_pl_read_param(*Reader, *adapter.PlParam) c_int;

test "PL handle/value layout and independently known padded bytes are preserved" {
    var layout: [9]usize = undefined;
    shared_pl_layout(&layout);
    const H = adapter.PlHandle;
    const P = adapter.PlParam;
    const expected_layout = [_]usize{ @sizeOf(H), @alignOf(H), @offsetOf(H, "len_offset"), @offsetOf(H, "buf_value_start"), @sizeOf(P), @alignOf(P), @offsetOf(P, "pid"), @offsetOf(P, "byte_len"), @offsetOf(P, "end_pos") };
    try testing.expectEqualSlices(usize, &expected_layout, &layout);
    const expected = [_]u8{ 0, 3, 0, 0, 0x10, 0, 4, 0, 0xa5, 0, 0, 0, 1, 0, 0, 0 };
    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(testing.allocator);
    var native = rt.PlCdrWriter.init(&buffer, testing.allocator);
    try native.writeEncapHeader();
    const h = try native.reservePlParam(0x10);
    try native.writeU8(0xa5);
    try native.patchPlParam(h);
    try native.writePlSentinel();
    try testing.expectEqualSlices(u8, &expected, buffer.items);
    for (0..3) |mode| {
        var bytes: [16]u8 = undefined;
        var w: Writer = undefined;
        switch (mode) {
            0 => try testing.expectEqual(@as(c_int, 0), zidl_cdr_writer_init(&w, 3)),
            1 => zidl_cdr_writer_init_fixed(&w, &bytes, bytes.len, 3),
            else => zidl_cdr_writer_init_counting(&w, 3),
        }
        defer zidl_cdr_writer_deinit(&w);
        try testing.expectEqual(@as(c_int, 0), shared_pl_sample(&w));
        try testing.expectEqual(@as(usize, 16), w.len);
        try testing.expectEqual(@as(usize, 12), w.pos);
        if (mode != 2) try testing.expectEqualSlices(u8, &expected, w.buf.?[0..w.len]);
    }
}

test "PL bounds share arithmetic while native strict/lenient policy stays explicit" {
    const truncated = [_]u8{ 0, 3, 0, 0, 0x10, 0, 4, 0, 0xa5 };
    var native = try rt.CdrReader.init(&truncated);
    try testing.expectError(error.TruncatedParameter, native.readPlParam(.strict));
    native = try rt.CdrReader.init(&truncated);
    try testing.expect((try native.readPlParam(.lenient)) == null);
    try testing.expectEqual(@as(usize, 8), native.pos);
    var c = try foreign(&truncated);
    var parameter = adapter.PlParam{ .pid = 42, .byte_len = 123, .end_pos = 321 };
    try testing.expectEqual(@as(c_int, -2), zidl_cdr_pl_read_param(&c, &parameter));
    try testing.expectEqual(@as(u16, 42), parameter.pid);
    try testing.expectEqual(@as(usize, 8), c.pos);
    const unaligned_length = [_]u8{ 0, 3, 0, 0, 0x10, 0, 3, 0, 0xa5, 0, 0, 0 };
    native = try rt.CdrReader.init(&unaligned_length);
    try testing.expectError(error.MisalignedParameter, native.readPlParam(.strict));
    native = try rt.CdrReader.init(&unaligned_length);
    try testing.expectEqual(@as(usize, 12), (try native.readPlParam(.lenient)).?.end_pos);
    c = try foreign(&unaligned_length);
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_pl_read_param(&c, &parameter));
    try testing.expectEqual(@as(u16, 3), parameter.byte_len);
    try testing.expectEqual(@as(usize, 12), parameter.end_pos);
    native.pos = std.math.maxInt(usize);
    try testing.expectError(error.MissingSentinel, native.readPlParam(.strict));
    try testing.expect((try native.readPlParam(.lenient)) == null);
}

test "PL oversized lengths fail before padding or narrowing" {
    var w: Writer = undefined;
    zidl_cdr_writer_init_counting(&w, 3);
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_pl_write_encap(&w));
    var handle: adapter.PlHandle = undefined;
    try testing.expectEqual(@as(c_int, 0), zidl_cdr_pl_reserve_param(&w, 0x10, &handle));
    w.len = handle.buf_value_start + 65533;
    w.pos = w.len - 4;
    const before = w.len;
    try testing.expectEqual(@as(c_int, -1), zidl_cdr_pl_patch_param(&w, handle));
    try testing.expectEqual(before, w.len);
    const payload = try testing.allocator.alloc(u8, 65533);
    defer testing.allocator.free(payload);
    @memset(payload, 0);
    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(testing.allocator);
    var native = rt.PlCdrWriter.init(&buffer, testing.allocator);
    try native.writeEncapHeader();
    try testing.expectError(error.Overflow, native.writeRawParam(0x10, payload));
    try testing.expectEqual(before, buffer.items.len);
}
