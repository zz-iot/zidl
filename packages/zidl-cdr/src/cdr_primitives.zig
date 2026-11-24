//! Shared wire operations; storage and errors belong to the sink.
//! Keep padding separate so fixed-buffer failures preserve cursor behavior.

const cursor = @import("cdr_cursor.zig");

pub const ByteOrder = enum { little, big };

pub fn writeUnsigned(sink: anytype, comptime T: type, value: T, pos: usize, alignment_cap: usize, order: ByteOrder) !void {
    const size = @sizeOf(T);
    const boundary = @min(size, alignment_cap);
    const pad = (boundary - pos % boundary) % boundary;
    const zeros: [8]u8 = @splat(0);
    if (pad != 0) try sink.writeBytes(zeros[0..pad]);
    const bytes = encodeUnsigned(T, value, order);
    try sink.writeBytes(&bytes);
}

pub fn encodeUnsigned(comptime T: type, value: T, order: ByteOrder) [@sizeOf(T)]u8 {
    const size = @sizeOf(T);
    var bytes: [size]u8 = undefined;
    inline for (0..size) |i| {
        const shift: usize = if (order == .little) i else size - 1 - i;
        bytes[i] = @truncate(value >> @intCast(shift * 8));
    }
    return bytes;
}

pub fn readUnsigned(comptime T: type, data: []const u8, pos: *usize, origin: usize, alignment_cap: usize, order: ByteOrder) error{EndOfStream}!T {
    const size = @sizeOf(T);
    if (size > 1) try cursor.alignPosition(pos, data.len, origin, @min(size, alignment_cap));
    const bytes = try cursor.readSlice(data, pos, size);
    var value: T = 0;
    inline for (0..size) |i| {
        const shift: usize = if (order == .little) i else size - 1 - i;
        value |= @as(T, bytes[i]) << @intCast(shift * 8);
    }
    return value;
}

pub fn readBool(data: []const u8, pos: *usize) error{ EndOfStream, InvalidBool }!bool {
    const value = try readUnsigned(u8, data, pos, 0, 1, .little);
    if (value > 1) return error.InvalidBool;
    return value == 1;
}

pub fn isArrayWidth(width: usize) bool {
    return switch (width) {
        1, 2, 4, 8 => true,
        else => false,
    };
}

pub fn nativeArrayWidth(comptime T: type) usize {
    return switch (T) {
        bool, u8, i8 => 1,
        u16, i16 => 2,
        u32, i32, f32 => 4,
        u64, i64, f64 => 8,
        else => @compileError("primitive CDR arrays require bool, an 8/16/32/64-bit integer, f32, or f64"),
    };
}

pub fn arrayPadding(width: usize, pos: usize, cap: usize) usize {
    const boundary = @min(width, cap);
    return (boundary - pos % boundary) % boundary;
}

fn swapArray(comptime T: type, dest: []u8, source: []const u8) void {
    const src: [*]align(1) const T = @ptrCast(source.ptr);
    const dst: [*]align(1) T = @ptrCast(dest.ptr);
    for (src[0 .. source.len / @sizeOf(T)], dst[0 .. dest.len / @sizeOf(T)]) |value, *out| {
        out.* = @byteSwap(value);
    }
}

pub fn copyArray(dest: []u8, source: []const u8, width: usize, order: ByteOrder) void {
    if (width == 1 or (order == .little) == (@import("builtin").cpu.arch.endian() == .little)) {
        @memcpy(dest, source);
        return;
    }
    switch (width) {
        2 => swapArray(u16, dest, source),
        4 => swapArray(u32, dest, source),
        8 => swapArray(u64, dest, source),
        else => unreachable,
    }
}

pub fn readArray(data: []const u8, pos: *usize, origin: usize, cap: usize, order: ByteOrder, width: usize, count: usize, dest: [*]u8) error{EndOfStream}!void {
    if (count == 0) return;
    const source = try takeArray(data, pos, origin, cap, width, count);
    copyArray(dest[0..source.len], source, width, order);
}

/// Consumes `count` elements of `width` bytes at their alignment and returns
/// their wire bytes; on failure `pos` is unchanged. `count` is not 0.
fn takeArray(data: []const u8, pos: *usize, origin: usize, cap: usize, width: usize, count: usize) error{EndOfStream}![]const u8 {
    const size = @import("std").math.mul(usize, count, width) catch return error.EndOfStream;
    var next = pos.*;
    if (width > 1) try cursor.alignPosition(&next, data.len, origin, @min(width, cap));
    const source = try cursor.readSlice(data, &next, size);
    pos.* = next;
    return source;
}

const host_order: ByteOrder = if (@import("builtin").cpu.arch.endian() == .little) .little else .big;

/// Primitives of one width, in place in the input and in its byte order
/// (docs/design/bulk-cdr-zero-copy.md). Valid while the input is.
pub const PrimitivesView = struct {
    /// The elements' wire bytes: `count * width` of them.
    bytes: []const u8 = &.{},
    /// 1, 2, 4 or 8.
    width: usize,
    /// The input's byte order.
    order: ByteOrder,

    pub fn count(self: PrimitivesView) usize {
        return self.bytes.len / self.width;
    }

    /// Whether the wire byte order differs from the host's. Never for one
    /// byte elements.
    pub fn swapped(self: PrimitivesView) bool {
        return self.width > 1 and self.order != host_order;
    }

    /// The elements as `T` values in place, unless they need swapping or `T`
    /// is not `width` bytes. Their memory alignment is not `T`'s: CDR aligns
    /// them relative to the payload, not to memory.
    pub fn asNative(self: PrimitivesView, comptime T: type) ?[]align(1) const T {
        if (self.swapped() or @sizeOf(T) != self.width) return null;
        const elements: [*]align(1) const T = @ptrCast(self.bytes.ptr);
        return elements[0..self.count()];
    }

    /// Copies the elements into `dest`, `bytes.len` bytes long, as host
    /// values, swapping them if needed.
    pub fn copyTo(self: PrimitivesView, dest: []u8) void {
        copyArray(dest[0..self.bytes.len], self.bytes, self.width, self.order);
    }
};

/// Consumes `count` elements of `width` bytes (1, 2, 4 or 8) as `readArray`
/// does, but returns a view of them in `data` rather than copying them. On
/// failure `pos` is unchanged; an empty view consumes nothing.
pub fn viewArray(data: []const u8, pos: *usize, origin: usize, cap: usize, order: ByteOrder, width: usize, count: usize) error{ EndOfStream, InvalidPrimitiveSize }!PrimitivesView {
    if (!isArrayWidth(width)) return error.InvalidPrimitiveSize;
    if (count == 0) return .{ .width = width, .order = order };
    return .{ .bytes = try takeArray(data, pos, origin, cap, width, count), .width = width, .order = order };
}

pub fn writeBools(dest: []u8, values: []const bool) void {
    for (dest, values) |*out, value| out.* = @intFromBool(value);
}

pub fn readBools(data: []const u8, pos: *usize, values: []bool) error{ EndOfStream, InvalidBool }!void {
    var next = pos.*;
    const source = try cursor.readSlice(data, &next, values.len);
    for (source) |byte| if (byte > 1) return error.InvalidBool;
    for (values, source) |*value, byte| value.* = byte != 0;
    pos.* = next;
}

/// Reads a primitive sequence's length and checks it before its elements are
/// allocated: within `bound` (null: unbounded), and that its elements of
/// `width` bytes (1, 2, 4 or 8), aligned as the cursor aligns them, fit in
/// `data`, so `count * width` fits in `usize` too. On success `pos` is past
/// the length only, before the elements' padding; on failure it is unchanged.
/// An unsupported width fails before anything is read, a count over the
/// bound before its body is checked.
pub fn readSequenceCount(data: []const u8, pos: *usize, origin: usize, alignment_cap: usize, order: ByteOrder, width: usize, bound: ?u32) error{ EndOfStream, InvalidPrimitiveSize, SequenceTooLong }!u32 {
    if (!isArrayWidth(width)) return error.InvalidPrimitiveSize;
    var next = pos.*;
    const count = try readUnsigned(u32, data, &next, origin, alignment_cap, order);
    if (bound) |b| if (count > b) return error.SequenceTooLong;
    var body = next;
    try cursor.skipPrimitives(&body, data.len, origin, count, width, alignment_cap);
    pos.* = next;
    return count;
}
