//! Shared framing mechanics. Reader windows and patch errors are explicit;
//! discovery validation policy remains in the language-facing reader.
const std = @import("std");
const primitives = @import("cdr_primitives.zig");
const cursor = @import("cdr_cursor.zig");

pub const Version = enum { xcdr1, xcdr2 };
pub const Extensibility = enum { final, appendable, mutable };
pub const Encapsulation = struct {
    version: Version,
    order: primitives.ByteOrder,
    is_pl_cdr: bool,
};

pub fn encapsulationId(version: Version, order: primitives.ByteOrder, kind: Extensibility, pl: bool) u16 {
    const base: u16 = if (pl) 2 else if (version == .xcdr1) 0 else switch (kind) {
        .final => 6,
        .appendable => 8,
        .mutable => 10,
    };
    return base + @intFromBool(order == .little);
}

pub fn parseEncapsulation(data: []const u8) error{InvalidEncapsulation}!Encapsulation {
    if (data.len < 4) return error.InvalidEncapsulation;
    const id = (@as(u16, data[0]) << 8) | data[1];
    return switch (id) {
        0, 1, 2, 3, 6, 7, 8, 9, 10, 11 => .{
            .version = if (id < 4) .xcdr1 else .xcdr2,
            .order = if (id % 2 == 0) .big else .little,
            .is_pl_cdr = id == 2 or id == 3,
        },
        else => error.InvalidEncapsulation,
    };
}

pub fn writeEncapsulation(sink: anytype, id: u16) !void {
    try sink.writeBytes(&.{ @truncate(id >> 8), @truncate(id), 0, 0 });
    sink.resetPayload();
}

pub fn reserveDheader(sink: anytype, out_offset: *usize) !void {
    const pad = (4 - sink.payloadPosition() % 4) % 4;
    const zeros: [4]u8 = @splat(0);
    if (pad != 0) try sink.writeBytes(zeros[0..pad]);
    out_offset.* = sink.byteLen();
    try sink.writeU32(0);
}

pub fn writeEmheader(sink: anytype, member_id: u32, mu: bool, lc: u8) !void {
    if (member_id > 0x0fffffff or lc > 3) return error.InvalidEmheader;
    try sink.writeU32((@as(u32, @intFromBool(mu)) << 31) | (@as(u32, lc) << 28) | member_id);
}

pub fn reserveEmheader(sink: anytype, member_id: u32, mu: bool, out_offset: *usize) !void {
    if (member_id > 0x0fffffff) return error.InvalidEmheader;
    try sink.writeU32((@as(u32, @intFromBool(mu)) << 31) | 0x40000000 | member_id);
    out_offset.* = sink.byteLen();
    try sink.writeU32(0);
}

fn wordEnd(len: usize, offset: usize) error{InvalidPatch}!usize {
    if (offset > len or 4 > len - offset) return error.InvalidPatch;
    return offset + 4;
}

fn payloadSize(len: usize, start: usize) error{ InvalidPatch, Overflow }!u32 {
    if (start > len) return error.InvalidPatch;
    const size = len - start;
    if (size > std.math.maxInt(u32)) return error.Overflow;
    return @intCast(size);
}

fn storeWord(storage: ?[]u8, len: usize, offset: usize, value: u32, order: primitives.ByteOrder) error{InvalidPatch}!void {
    _ = try wordEnd(len, offset);
    if (storage) |bytes| {
        if (len > bytes.len) return error.InvalidPatch;
        const encoded = primitives.encodeUnsigned(u32, value, order);
        @memcpy(bytes[offset..][0..4], &encoded);
    }
}

pub fn patchDheader(storage: ?[]u8, len: usize, offset: usize, order: primitives.ByteOrder) error{ InvalidPatch, Overflow }!void {
    const start = try wordEnd(len, offset);
    const size = try payloadSize(len, start);
    try storeWord(storage, len, offset, size, order);
}

pub fn patchEmheader(storage: ?[]u8, len: usize, offset: usize, start: usize, order: primitives.ByteOrder) error{ InvalidPatch, Overflow }!void {
    if (start != try wordEnd(len, offset)) return error.InvalidPatch;
    const size = try payloadSize(len, start);
    try storeWord(storage, len, offset, size, order);
}

/// XCDR1 optional values have exact lengths and their own alignment origin.
/// Always emit the legal extended form, including for small member IDs.
pub const OptionalWrite = extern struct {
    length_offset: usize,
    value_start: usize,
    parent_pos: usize,
};

pub fn beginOptional(sink: anytype, member_id: u32, mu: bool) !OptionalWrite {
    if (member_id > 0x0fffffff) return error.InvalidOptionalHeader;
    const pad = (4 - sink.payloadPosition() % 4) % 4;
    const zeros: [4]u8 = @splat(0);
    if (pad != 0) try sink.writeBytes(zeros[0..pad]);
    try sink.writeU16(0x7f01);
    try sink.writeU16(8);
    try sink.writeU32(member_id | (@as(u32, @intFromBool(mu)) << 30));
    const offset = sink.byteLen();
    try sink.writeU32(0);
    const token = OptionalWrite{ .length_offset = offset, .value_start = sink.byteLen(), .parent_pos = sink.payloadPosition() };
    sink.resetPayload();
    return token;
}

pub fn optionalParentPosition(len: usize, token: OptionalWrite) error{InvalidPatch}!usize {
    if (token.value_start > len or token.parent_pos > token.value_start or
        token.length_offset > token.value_start or token.value_start - token.length_offset != 4)
        return error.InvalidPatch;
    return token.parent_pos + (len - token.value_start);
}

pub fn finishOptional(storage: ?[]u8, len: usize, token: OptionalWrite, order: primitives.ByteOrder) error{ InvalidPatch, Overflow }!void {
    _ = try optionalParentPosition(len, token);
    try storeWord(storage, len, token.length_offset, try payloadSize(len, token.value_start), order);
}

pub const OptionalValue = struct { start: usize, end: usize, must_understand: bool };

pub fn readOptional(data: []const u8, pos: *usize, member_id: u32, order: primitives.ByteOrder) error{ EndOfStream, InvalidOptionalHeader }!OptionalValue {
    if (member_id > 0x0fffffff) return error.InvalidOptionalHeader;
    try cursor.alignPosition(pos, data.len, 4, 4);
    const pid = try primitives.readUnsigned(u16, data, pos, 4, 8, order);
    var size: u32 = try primitives.readUnsigned(u16, data, pos, 4, 8, order);
    if (pid & 0x8000 != 0) return error.InvalidOptionalHeader;
    var id: u32 = pid & 0x3fff;
    var mu = pid & 0x4000 != 0;
    if (id == 0x3f01) {
        if (size != 8) return error.InvalidOptionalHeader;
        const extended = try primitives.readUnsigned(u32, data, pos, 4, 8, order);
        if (extended & 0x80000000 != 0) return error.InvalidOptionalHeader;
        id = extended & 0x0fffffff;
        mu = extended & 0x40000000 != 0;
        size = try primitives.readUnsigned(u32, data, pos, 4, 8, order);
    } else if (id > 0x3f00) return error.InvalidOptionalHeader;
    if (id != member_id) return error.InvalidOptionalHeader;
    return .{ .start = pos.*, .end = try bodyEnd(pos.*, size, data.len), .must_understand = mu };
}

pub fn bodyEnd(pos: usize, size: usize, limit: usize) error{EndOfStream}!usize {
    if (pos > limit or size > limit - pos) return error.EndOfStream;
    return pos + size;
}

pub fn validateLimit(pos: usize, len: usize, end: usize) error{EndOfStream}!void {
    if (end > len or pos > end) return error.EndOfStream;
}

pub fn readDheaderEnd(data: []const u8, pos: *usize, cap: usize, order: primitives.ByteOrder) error{EndOfStream}!usize {
    const size = try primitives.readUnsigned(u32, data, pos, 4, cap, order);
    return bodyEnd(pos.*, size, data.len);
}

pub const EmHeader = struct {
    member_id: u28,
    must_understand: bool,
    lc: u3,
    payload_bytes: u32,
};

/// Header-only decoding retains the legacy API, including LC5–7 NEXTINT peek.
/// Validate the value span with memberEnd before constructing a bounded reader.
pub fn readEmheader(data: []const u8, pos: *usize, cap: usize, order: primitives.ByteOrder) error{ EndOfStream, InvalidEmheader }!EmHeader {
    const word = try primitives.readUnsigned(u32, data, pos, 4, cap, order);
    const lc: u3 = @truncate(word >> 28);
    const bytes: u32 = switch (lc) {
        0 => 1,
        1 => 2,
        2 => 4,
        3 => 8,
        4 => try primitives.readUnsigned(u32, data, pos, 4, cap, order),
        5, 6, 7 => blk: {
            const start = pos.*;
            const n = try primitives.readUnsigned(u32, data, pos, 4, cap, order);
            pos.* = start;
            const shift: u6 = if (lc == 5) 0 else if (lc == 6) 2 else 3;
            const size = (@as(u64, n) << shift) + 4;
            if (size > std.math.maxInt(u32)) return error.InvalidEmheader;
            break :blk @intCast(size);
        },
    };
    return .{ .member_id = @truncate(word), .must_understand = word & 0x80000000 != 0, .lc = lc, .payload_bytes = bytes };
}

pub fn skipMember(pos: *usize, limit: usize, cap: usize, lc: u8, bytes: u32) error{ EndOfStream, InvalidEmheader }!void {
    if (lc > 7) return error.InvalidEmheader;
    if (lc < 4) {
        if (bytes != @as(u32, 1) << @intCast(lc)) return error.InvalidEmheader;
        try cursor.alignPosition(pos, limit, 4, @min(cap, bytes));
    }
    _ = try cursor.advance(pos, limit, bytes);
}

pub fn memberEnd(pos: usize, limit: usize, cap: usize, lc: u8, bytes: u32) error{ EndOfStream, InvalidEmheader }!usize {
    var end = pos;
    try skipMember(&end, limit, cap, lc, bytes);
    return end;
}

pub fn parameterEnd(pos: usize, byte_len: u16, limit: usize) error{EndOfStream}!usize {
    const padded = (@as(usize, byte_len) + 3) & ~@as(usize, 3);
    return bodyEnd(pos, padded, limit);
}

pub fn parameterSize(raw_bytes: usize) error{Overflow}!u16 {
    // The largest representable padded length is 65532, not 65535.
    if (raw_bytes > 65532) return error.Overflow;
    return @intCast((raw_bytes + 3) & ~@as(usize, 3));
}

pub fn validateParameter(len: usize, offset: usize, start: usize) error{InvalidPatch}!void {
    if (offset > len or 2 > len - offset or start != offset + 2) return error.InvalidPatch;
}

pub fn reserveParameter(sink: anytype, pid: u16, offset: *usize, start: *usize) !void {
    try sink.writeU16(pid);
    offset.* = sink.byteLen();
    try sink.writeU16(0);
    start.* = sink.byteLen();
}

/// Call after emitting padding. PL_CDR's dedicated writer remains LE-only.
pub fn patchParameter(storage: ?[]u8, len: usize, offset: usize, start: usize) error{ InvalidPatch, Overflow }!void {
    try validateParameter(len, offset, start);
    const raw = len - start;
    const size = try parameterSize(raw);
    if (size != raw) return error.InvalidPatch;
    if (storage) |bytes| {
        if (len > bytes.len) return error.InvalidPatch;
        const encoded = primitives.encodeUnsigned(u16, size, .little);
        @memcpy(bytes[offset..][0..2], &encoded);
    }
}

pub fn writeSentinel(sink: anytype) !void {
    try sink.writeBytes(&.{ 1, 0, 0, 0 });
}

test "framing sizes and patch offsets cannot wrap" {
    const max = std.math.maxInt(usize);
    try std.testing.expectError(error.EndOfStream, bodyEnd(max - 1, 2, max));
    try std.testing.expectError(error.InvalidPatch, patchDheader(null, max, max, .little));
    if (@bitSizeOf(usize) > 32) {
        try std.testing.expectError(error.Overflow, patchDheader(null, @as(usize, std.math.maxInt(u32)) + 5, 0, .little));
    }
    try std.testing.expectEqual(@as(u16, 65532), try parameterSize(65532));
    try std.testing.expectError(error.Overflow, parameterSize(65533));
}
