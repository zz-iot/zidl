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

// ── The C path's specialized exports: one fast instance behind a pointer,
// as per-instance C entry points would be.
const FastFixed = cdr.Writer(.{ .version = .xcdr2, .order = .little, .output = .fixed });
export fn bench_x2le_size() usize {
    return @sizeOf(FastFixed);
}
export fn bench_x2le_init(w: *FastFixed, buf: [*]u8, cap: usize) void {
    w.* = FastFixed.initFixed(buf[0..cap], .xcdr2, .little);
}
export fn bench_x2le_len(w: *FastFixed) usize {
    return w.len;
}
export fn bench_x2le_write_u8(w: *FastFixed, v: u8) c_int {
    w.writeU8(v) catch return -1;
    return 0;
}
export fn bench_x2le_write_u16(w: *FastFixed, v: u16) c_int {
    w.writeU16(v) catch return -1;
    return 0;
}
export fn bench_x2le_write_u32(w: *FastFixed, v: u32) c_int {
    w.writeU32(v) catch return -1;
    return 0;
}
export fn bench_x2le_write_u64(w: *FastFixed, v: u64) c_int {
    w.writeU64(v) catch return -1;
    return 0;
}
export fn bench_x2le_write_f64(w: *FastFixed, v: f64) c_int {
    w.writeF64(v) catch return -1;
    return 0;
}
export fn bench_x2le_write_string(w: *FastFixed, s: [*]const u8, len: u32) c_int {
    w.writeString(s[0..len]) catch return -1;
    return 0;
}

extern fn bench_c_runtime(buf: [*]u8, cap: usize, seed: u64) usize;
extern fn bench_c_special(state: *anyopaque, buf: [*]u8, cap: usize, seed: u64) usize;

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
        .{ "C: today's ABI, fixed (no count)", cRuntime },
        .{ "C: specialized exports, fixed (no count)", cSpecial },
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
