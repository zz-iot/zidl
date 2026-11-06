//! Native storage policies for the first shared-core migration slice.
//! Primitives, strings and framing; schema traversal remains generated.
const std = @import("std");
const primitives = @import("cdr_primitives.zig");
const strings = @import("cdr_strings.zig");
const keys = @import("cdr_keys.zig");
const framing = @import("cdr_framing.zig");

pub const AlignmentCap = enum { four, eight };

pub const PrimitiveWriter = struct {
    storage: union(enum) {
        dynamic: struct { buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator },
        fixed: []u8,
        counting,
    },
    len: usize = 0,
    pos: usize = 0,
    alignment_cap: AlignmentCap,
    byte_order: primitives.ByteOrder,

    pub fn initDynamic(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cap: AlignmentCap, order: primitives.ByteOrder) PrimitiveWriter {
        return .{ .storage = .{ .dynamic = .{ .buffer = buffer, .allocator = allocator } }, .len = buffer.items.len, .alignment_cap = cap, .byte_order = order };
    }

    pub fn initFixed(buffer: []u8, cap: AlignmentCap, order: primitives.ByteOrder) PrimitiveWriter {
        return .{ .storage = .{ .fixed = buffer }, .alignment_cap = cap, .byte_order = order };
    }

    pub fn initCounting(cap: AlignmentCap, order: primitives.ByteOrder) PrimitiveWriter {
        return .{ .storage = .counting, .alignment_cap = cap, .byte_order = order };
    }

    pub fn writeBytes(self: *PrimitiveWriter, bytes: []const u8) !void {
        const next_len = std.math.add(usize, self.len, bytes.len) catch return error.Overflow;
        const next_pos = std.math.add(usize, self.pos, bytes.len) catch return error.Overflow;
        switch (self.storage) {
            .dynamic => |d| try d.buffer.appendSlice(d.allocator, bytes),
            .fixed => |buffer| {
                if (next_len > buffer.len) return error.Overflow;
                @memcpy(buffer[self.len..next_len], bytes);
            },
            .counting => {},
        }
        self.len = next_len;
        self.pos = next_pos;
    }

    pub fn writeUnsigned(self: *PrimitiveWriter, comptime T: type, value: T) !void {
        try primitives.writeUnsigned(self, T, value, self.pos, if (self.alignment_cap == .four) 4 else 8, self.byte_order);
    }
    pub fn writeU8(self: *PrimitiveWriter, value: u8) !void {
        try self.writeUnsigned(u8, value);
    }

    pub fn writeI8(self: *PrimitiveWriter, value: i8) !void {
        try self.writeUnsigned(u8, @as(u8, @bitCast(value)));
    }

    pub fn writeU16(self: *PrimitiveWriter, value: u16) !void {
        try self.writeUnsigned(u16, value);
    }

    pub fn writeI16(self: *PrimitiveWriter, value: i16) !void {
        try self.writeUnsigned(u16, @as(u16, @bitCast(value)));
    }

    pub fn writeU32(self: *PrimitiveWriter, value: u32) !void {
        try self.writeUnsigned(u32, value);
    }

    pub fn writeI32(self: *PrimitiveWriter, value: i32) !void {
        try self.writeUnsigned(u32, @as(u32, @bitCast(value)));
    }

    pub fn writeU64(self: *PrimitiveWriter, value: u64) !void {
        try self.writeUnsigned(u64, value);
    }

    pub fn writeI64(self: *PrimitiveWriter, value: i64) !void {
        try self.writeUnsigned(u64, @as(u64, @bitCast(value)));
    }

    pub fn writeF32(self: *PrimitiveWriter, value: f32) !void {
        try self.writeUnsigned(u32, @bitCast(value));
    }

    pub fn writeF64(self: *PrimitiveWriter, value: f64) !void {
        try self.writeUnsigned(u64, @bitCast(value));
    }

    pub fn writeBool(self: *PrimitiveWriter, value: bool) !void {
        try self.writeU8(@intFromBool(value));
    }

    pub fn writeChar(self: *PrimitiveWriter, value: u8) !void {
        try self.writeU8(value);
    }

    pub fn writeWchar(self: *PrimitiveWriter, value: u16) !void {
        try self.writeU16(value);
    }
    pub fn writeString(self: *PrimitiveWriter, value: []const u8) !void {
        try strings.writeString(self, value);
    }

    pub fn writeKeyWstring(self: *PrimitiveWriter, value: []const u16) !void {
        try keys.writeWstring(self, value);
    }

    pub fn writeWstring(self: *PrimitiveWriter, value: []const u16) !void {
        try strings.writeWstring(self, value);
    }
    pub fn payloadPosition(self: *const PrimitiveWriter) usize {
        return self.pos;
    }
    pub fn byteLen(self: *const PrimitiveWriter) usize {
        return self.len;
    }
    pub fn resetPayload(self: *PrimitiveWriter) void {
        self.pos = 0;
    }

    fn patchStorage(self: *PrimitiveWriter) ?[]u8 {
        return switch (self.storage) {
            .dynamic => |d| d.buffer.items,
            .fixed => |bytes| bytes,
            .counting => null,
        };
    }

    fn writeEncap(self: *PrimitiveWriter, kind: framing.Extensibility) !void {
        const version: framing.Version = if (self.alignment_cap == .four) .xcdr2 else .xcdr1;
        try framing.writeEncapsulation(self, framing.encapsulationId(version, self.byte_order, kind, false));
    }

    pub fn writeEncapHeader(self: *PrimitiveWriter) !void {
        try self.writeEncap(.final);
    }
    pub fn writeEncapHeaderDelimited(self: *PrimitiveWriter) !void {
        try self.writeEncap(.appendable);
    }
    pub fn writeEncapHeaderMutable(self: *PrimitiveWriter) !void {
        try self.writeEncap(.mutable);
    }
    pub fn writeDheader(self: *PrimitiveWriter, size: u32) !void {
        try self.writeU32(size);
    }

    pub fn reserveDheader(self: *PrimitiveWriter) !usize {
        var offset: usize = undefined;
        try framing.reserveDheader(self, &offset);
        return offset;
    }

    pub fn reserveDheaderMaybe(self: *PrimitiveWriter) !?usize {
        if (self.alignment_cap == .eight) return null;
        return try self.reserveDheader();
    }

    pub fn patchDheaderChecked(self: *PrimitiveWriter, offset: usize) !void {
        try framing.patchDheader(self.patchStorage(), self.len, offset, self.byte_order);
    }

    pub fn patchDheader(self: *PrimitiveWriter, offset: usize) void {
        self.patchDheaderChecked(offset) catch {};
    }
    pub fn patchDheaderMaybeChecked(self: *PrimitiveWriter, offset: ?usize) !void {
        if (offset) |off| try self.patchDheaderChecked(off);
    }

    pub fn patchDheaderMaybe(self: *PrimitiveWriter, offset: ?usize) void {
        if (offset) |off| self.patchDheader(off);
    }

    pub const EmheaderPlaceholder = struct { nextint_offset: usize, payload_start: usize };

    pub fn writeEmheaderFixed(self: *PrimitiveWriter, member_id: u28, mu: bool, lc: u2) !void {
        try framing.writeEmheader(self, member_id, mu, lc);
    }

    pub fn reserveEmheader(self: *PrimitiveWriter, member_id: u28, mu: bool) !EmheaderPlaceholder {
        var offset: usize = undefined;
        try framing.reserveEmheader(self, member_id, mu, &offset);
        return .{ .nextint_offset = offset, .payload_start = self.len };
    }

    pub fn patchEmheaderChecked(self: *PrimitiveWriter, ph: EmheaderPlaceholder) !void {
        try framing.patchEmheader(self.patchStorage(), self.len, ph.nextint_offset, ph.payload_start, self.byte_order);
    }

    pub fn patchEmheader(self: *PrimitiveWriter, ph: EmheaderPlaceholder) void {
        self.patchEmheaderChecked(ph) catch {};
    }
};
