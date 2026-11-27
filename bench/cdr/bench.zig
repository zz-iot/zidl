//! `zig build bench-cdr`: the tables in docs/design/cdr-specialized-instances.md.
//! One mixed message (every alignment, a string, 64 longs and 32 octet/double
//! pairs, written one at a time), best of several runs, ReleaseFast.
//! Numbers vary by machine; compare rows within one run.
const std = @import("std");
const cdr = @import("zidl_cdr");

fn nowNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

fn message(w: anytype, seed: u64) !void {
    try w.writeU8(@truncate(seed));
    try w.writeF64(@floatFromInt(seed));
    try w.writeU16(@truncate(seed >> 3));
    try w.writeU64(seed *% 31);
    try w.writeI32(@truncate(@as(i64, @bitCast(seed))));
    try w.writeU8(7);
    try w.writeI64(-@as(i64, @intCast(seed & 0xffff)));
    try w.writeString("sensor-frame-0042");
    try w.writeBool(seed & 1 == 0);
    var i: u32 = 0;
    while (i < 64) : (i += 1) try w.writeU32(i ^ @as(u32, @truncate(seed)));
    i = 0;
    while (i < 32) : (i += 1) {
        try w.writeU8(@truncate(i));
        try w.writeF64(@as(f64, @floatFromInt(i)) * 0.5);
    }
}

fn readMessage(r: anytype, _: void) !u64 {
    var sum: u64 = 0;
    sum +%= try r.readU8();
    sum +%= @bitCast(try r.readF64());
    sum +%= try r.readU16();
    sum +%= try r.readU64();
    sum +%= @as(u32, @bitCast(try r.readI32()));
    sum +%= try r.readU8();
    sum +%= @bitCast(try r.readI64());
    sum +%= (try r.readStringZeroCopy()).len;
    sum +%= @intFromBool(try r.readBool());
    for (0..64) |_| sum +%= try r.readU32();
    for (0..32) |_| {
        sum +%= try r.readU8();
        sum +%= @bitCast(try r.readF64());
    }
    return sum;
}

// ── Per-instance C entry points, measured here only (the library does not
// export them; see the design note): `bench_x2le_<op>` for the fixed
// instance and `bench_x2lec_<op>` for the counting one.
const FastFixed = cdr.Writer(.{ .version = .xcdr2, .order = .little, .output = .fixed });
const FastCounting = cdr.Writer(.{ .version = .xcdr2, .order = .little, .output = .counting });

fn Exports(comptime W: type) type {
    return struct {
        fn len(w: *W) callconv(.c) usize {
            return w.len;
        }
        fn writeU8(w: *W, v: u8) callconv(.c) c_int {
            w.writeU8(v) catch return -1;
            return 0;
        }
        fn writeU16(w: *W, v: u16) callconv(.c) c_int {
            w.writeU16(v) catch return -1;
            return 0;
        }
        fn writeU32(w: *W, v: u32) callconv(.c) c_int {
            w.writeU32(v) catch return -1;
            return 0;
        }
        fn writeU64(w: *W, v: u64) callconv(.c) c_int {
            w.writeU64(v) catch return -1;
            return 0;
        }
        fn writeF64(w: *W, v: f64) callconv(.c) c_int {
            w.writeF64(v) catch return -1;
            return 0;
        }
        fn writeString(w: *W, str: [*]const u8, n: u32) callconv(.c) c_int {
            w.writeString(str[0..n]) catch return -1;
            return 0;
        }
        fn exportAll(comptime prefix: []const u8) void {
            @export(&len, .{ .name = prefix ++ "_len" });
            @export(&writeU8, .{ .name = prefix ++ "_write_u8" });
            @export(&writeU16, .{ .name = prefix ++ "_write_u16" });
            @export(&writeU32, .{ .name = prefix ++ "_write_u32" });
            @export(&writeU64, .{ .name = prefix ++ "_write_u64" });
            @export(&writeF64, .{ .name = prefix ++ "_write_f64" });
            @export(&writeString, .{ .name = prefix ++ "_write_string" });
        }
    };
}

comptime {
    Exports(FastFixed).exportAll("bench_x2le");
    Exports(FastCounting).exportAll("bench_x2lec");
}

export fn bench_x2le_size() usize {
    return @max(@sizeOf(FastFixed), @sizeOf(FastCounting));
}
export fn bench_x2le_init(w: *FastFixed, buf: [*]u8, cap: usize) void {
    w.* = FastFixed.initFixed(buf[0..cap], .xcdr2, .little);
}
export fn bench_x2lec_init(w: *FastCounting) void {
    w.* = FastCounting.initCounting(.xcdr2, .little);
}

extern fn bench_c_runtime(buf: [*]u8, cap: usize, seed: u64) usize;
extern fn bench_c_special(state: *anyopaque, buf: [*]u8, cap: usize, seed: u64) usize;
extern fn bench_c_runtime_count_fixed(buf: [*]u8, cap: usize, seed: u64) usize;
extern fn bench_c_special_count_fixed(state: *anyopaque, buf: [*]u8, cap: usize, seed: u64) usize;
extern fn bench_c_mixed_count_fixed(state: *anyopaque, buf: [*]u8, cap: usize, seed: u64) usize;

const iters: u64 = 400_000;
const rounds = 7;

fn best(comptime run: fn (*Ctx) u64, ctx: *Ctx) f64 {
    var b: i64 = std.math.maxInt(i64);
    _ = run(ctx);
    for (0..rounds) |_| {
        const start = nowNs();
        ctx.check +%= run(ctx);
        b = @min(b, nowNs() - start);
    }
    return @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(iters));
}

const Ctx = struct {
    alloc: std.mem.Allocator,
    buf: []u8,
    sample: []const u8 = &.{},
    state: []align(16) u8,
    check: u64 = 0,
};

fn seedOf(n: u64) u64 {
    return @as(*const volatile u64, &n).*;
}

fn countFixed(comptime fast: cdr.FastSet, comptime order: cdr.ByteOrder) fn (*Ctx) u64 {
    return struct {
        fn run(ctx: *Ctx) u64 {
            var sum: u64 = 0;
            for (0..iters) |n| {
                var c = cdr.WriterFor(fast, .xcdr2, order, .counting).initCounting(.xcdr2, order);
                message(&c, seedOf(n)) catch unreachable;
                var w = cdr.WriterFor(fast, .xcdr2, order, .fixed).initFixed(ctx.buf[0..c.len], .xcdr2, order);
                message(&w, seedOf(n)) catch unreachable;
                sum +%= w.len;
            }
            return sum;
        }
    }.run;
}

fn readWith(comptime fast: cdr.FastSet) fn (*Ctx) u64 {
    return struct {
        fn run(ctx: *Ctx) u64 {
            var sum: u64 = 0;
            for (0..iters) |_| {
                const input: []const u8 = @as(*const volatile []const u8, &ctx.sample).*;
                sum +%= cdr.readSample(fast, u64, input, {}, readMessage) catch unreachable;
            }
            return sum;
        }
    }.run;
}

fn readDirect(ctx: *Ctx) u64 {
    var sum: u64 = 0;
    for (0..iters) |_| {
        const input: []const u8 = @as(*const volatile []const u8, &ctx.sample).*;
        var r = cdr.CdrReader.init(input) catch unreachable;
        sum +%= readMessage(&r, {}) catch unreachable;
    }
    return sum;
}

fn cRuntime(ctx: *Ctx) u64 {
    var sum: u64 = 0;
    for (0..iters) |n| sum +%= bench_c_runtime(ctx.buf.ptr, ctx.buf.len, seedOf(n));
    return sum;
}

fn cSpecial(ctx: *Ctx) u64 {
    var sum: u64 = 0;
    for (0..iters) |n| sum +%= bench_c_special(ctx.state.ptr, ctx.buf.ptr, ctx.buf.len, seedOf(n));
    return sum;
}

fn cWith(comptime f: fn (*anyopaque, [*]u8, usize, u64) callconv(.c) usize) fn (*Ctx) u64 {
    return struct {
        fn run(ctx: *Ctx) u64 {
            var sum: u64 = 0;
            for (0..iters) |n| sum +%= f(ctx.state.ptr, ctx.buf.ptr, ctx.buf.len, seedOf(n));
            return sum;
        }
    }.run;
}

fn cRuntimeCountFixed(ctx: *Ctx) u64 {
    var sum: u64 = 0;
    for (0..iters) |n| sum +%= bench_c_runtime_count_fixed(ctx.buf.ptr, ctx.buf.len, seedOf(n));
    return sum;
}

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var ctx: Ctx = .{ .alloc = alloc, .buf = try alloc.alloc(u8, 4096), .state = try alloc.alignedAlloc(u8, .@"16", 256) };
    std.debug.assert(bench_x2le_size() <= ctx.state.len);
    var sample_w = cdr.RuntimeWriter.initFixed(ctx.buf, .xcdr2, .little);
    try sample_w.writeEncapHeader();
    try message(&sample_w, 12345);
    const sample = try alloc.dupe(u8, sample_w.bytes());
    ctx.sample = sample;

    const rows = .{
        .{ "Fast: count, then fixed", countFixed(.all, .little) },
        .{ "Run-time: count, then fixed (LE)", countFixed(.none, .little) },
        .{ "Run-time: count, then fixed (BE)", countFixed(.none, .big) },
        .{ "C: run-time ABI, fixed (no count)", cRuntime },
        .{ "C: per-instance exports, fixed (no count)", cSpecial },
        .{ "C: run-time ABI, count, then fixed", cRuntimeCountFixed },
        .{ "C: run-time count, per-instance fixed", cWith(bench_c_mixed_count_fixed) },
        .{ "C: per-instance count, then fixed", cWith(bench_c_special_count_fixed) },
        .{ "Reader: CdrReader (run-time)", readWith(.none) },
        .{ "Reader: CdrReader, direct", readDirect },
        .{ "Reader: fast, dispatched per sample", readWith(.all) },
    };
    std.debug.print("XCDR2, {d}-byte message, {d} per run, best of {d}\n", .{ sample.len, iters, rounds });
    inline for (rows) |row| {
        std.debug.print("  {s:<44} {d:>8.1} ns/message\n", .{ row[0], best(row[1], &ctx) });
    }
    std.debug.print("(checksum {d})\n", .{ctx.check});
}
