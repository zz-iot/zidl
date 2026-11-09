const std = @import("std");
const vectors = @import("fixed_cases");
const testing = std.testing;
fn bits(v: f64) u64 {
    return @bitCast(v);
}

pub fn check(comptime C: type) !void {
    for (vectors.cases) |v| {
        var payload: [16]u8 = undefined;
        const expected = try std.fmt.hexToBytes(&payload, v.hex);
        for ([_]c_int{ 1, 2 }) |version| for ([_]c_int{ 0, 1 }) |order| {
            var input: [32]u8 = @splat(0);
            input[1] = if (version == 1) @intCast(1 - order) else @intCast(7 - order);
            input[4] = 0xa5;
            @memcpy(input[5..][0..expected.len], expected);
            const len = expected.len + 5;
            for (0..3) |mode| {
                var w: C.ZidlCdrWriter = undefined;
                var storage: [32]u8 = undefined;
                if (mode == 0) try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_writer_init(&w, version)) else if (mode == 1) C.zidl_cdr_writer_init_fixed(&w, &storage, storage.len, version) else C.zidl_cdr_writer_init_counting(&w, version);
                defer C.zidl_cdr_writer_deinit(&w);
                C.zidl_cdr_writer_set_byte_order(&w, order);
                try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_write_encap(&w));
                try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_write_u8(&w, 0xa5));
                try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_write_fixed(&w, v.digits, v.scale, v.value));
                try testing.expectEqual(len, w.len);
                try testing.expectEqual(len - 4, w.pos);
                if (mode != 2) {
                    const bytes = if (comptime @typeInfo(@TypeOf(w.buf)) == .optional) w.buf.?[0..w.len] else w.buf[0..w.len];
                    try testing.expectEqualSlices(u8, input[0..len], bytes);
                }
            }
            var r: C.ZidlCdrReader = undefined;
            try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_reader_init(&r, &input, len));
            var marker: u8 = 0;
            var out: f64 = 42;
            try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_read_u8(&r, &marker));
            try testing.expectEqual(@as(u8, 0xa5), marker);
            try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_read_fixed(&r, v.digits, v.scale, &out));
            try testing.expectEqual(bits(v.decoded), bits(out));
            try testing.expectEqual(len, r.pos);
            for (5..len) |n| {
                try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_reader_init(&r, &input, n));
                r.pos = 5;
                out = 42;
                try testing.expectEqual(@as(c_int, -2), C.zidl_cdr_read_fixed(&r, v.digits, v.scale, &out));
                try testing.expectEqual(@as(usize, 5), r.pos);
                try testing.expectEqual(@as(f64, 42), out);
                var w: C.ZidlCdrWriter = undefined;
                C.zidl_cdr_writer_init_fixed(&w, &input, n, version);
                w.len = 5;
                w.pos = 1;
                try testing.expectEqual(@as(c_int, -1), C.zidl_cdr_write_fixed(&w, v.digits, v.scale, v.value));
                try testing.expectEqual(@as(usize, 5), w.len);
            }
        };
    }
    for (vectors.read_cases) |v| {
        var input: [20]u8 = @splat(0);
        input[1] = 1;
        const bytes = try std.fmt.hexToBytes(input[4..], v.hex);
        var r: C.ZidlCdrReader = undefined;
        var out: f64 = 0;
        try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_reader_init(&r, &input, bytes.len + 4));
        try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_read_fixed(&r, v.digits, v.scale, &out));
        try testing.expectEqual(bits(v.decoded), bits(out));
    }
    var input: [20]u8 = @splat(0);
    input[1] = 1;
    var r: C.ZidlCdrReader = undefined;
    var w: C.ZidlCdrWriter = undefined;
    C.zidl_cdr_writer_init_fixed(&w, &input, input.len, 1);
    for ([_][2]u8{ .{ 0, 0 }, .{ 32, 0 }, .{ 255, 255 }, .{ 3, 4 } }) |shape| {
        try testing.expectEqual(@as(c_int, -3), C.zidl_cdr_write_fixed(&w, shape[0], shape[1], 1));
        try testing.expectEqual(@as(usize, 0), w.len);
        try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_reader_init(&r, &input, input.len));
        var out: f64 = 42;
        try testing.expectEqual(@as(c_int, -3), C.zidl_cdr_read_fixed(&r, shape[0], shape[1], &out));
        try testing.expectEqual(@as(usize, 4), r.pos);
        try testing.expectEqual(@as(f64, 42), out);
    }
    try testing.expectEqual(@as(c_int, -3), C.zidl_cdr_write_fixed(&w, 1, 0, std.math.nan(f64)));
    try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_reader_init(&r, &input, input.len));
    r.pos = std.math.maxInt(usize);
    var sentinel: f64 = 42;
    try testing.expectEqual(@as(c_int, -2), C.zidl_cdr_read_fixed(&r, 31, 0, &sentinel));
    try testing.expectEqual(@as(f64, 42), sentinel);
    C.zidl_cdr_writer_init_counting(&w, 1);
    w.len = std.math.maxInt(usize) - 1;
    w.pos = w.len;
    try testing.expectEqual(@as(c_int, -1), C.zidl_cdr_write_fixed(&w, 31, 0, 1));
    try testing.expectEqual(std.math.maxInt(usize) - 1, w.len);
    for (0..16) |sign| {
        if (sign == 0xc or sign == 0xd) continue;
        input[4] = @intCast(0x10 | sign);
        try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_reader_init(&r, &input, 5));
        var out: f64 = 42;
        try testing.expectEqual(@as(c_int, -3), C.zidl_cdr_read_fixed(&r, 1, 0, &out));
        try testing.expectEqual(@as(usize, 5), r.pos);
        try testing.expectEqual(@as(f64, 42), out);
    }
    for ([_][2]u8{ .{ 0xac, 0 }, .{ 0x11, 0x2c } }, 0..) |bad, i| {
        input[4] = bad[0];
        input[5] = bad[1];
        try testing.expectEqual(@as(c_int, 0), C.zidl_cdr_reader_init(&r, &input, 6));
        var out: f64 = 42;
        try testing.expectEqual(@as(c_int, -3), C.zidl_cdr_read_fixed(&r, if (i == 0) 1 else 2, 0, &out));
        try testing.expectEqual(@as(f64, 42), out);
    }
}
