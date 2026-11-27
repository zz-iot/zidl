//! The CDR writer: one generic source, each of its parameters (encoding,
//! byte order, output) fixed at compile time or left to run time
//! (docs/design/cdr-specialized-instances.md).
//!
//! A fast instance fixes all three, so every alignment, byte-order and output
//! branch folds away. The run-time instance (`RuntimeWriter`) leaves all three
//! to run time: one compact copy that writes any of them.
//!
//! Output is counting or a fixed buffer; there is no growable output.
//! Count, allocate exactly, then write: `serializeAlloc` does all three.
//! Every method generated `serialize` code calls (`writer: anytype`) is here.

const std = @import("std");
const primitives = @import("cdr_primitives.zig");
const strings = @import("cdr_strings.zig");
const keys = @import("cdr_keys.zig");
const fixed_mod = @import("cdr_fixed.zig");
const framing = @import("cdr_framing.zig");

pub const XcdrVersion = framing.Version;
pub const ByteOrder = primitives.ByteOrder;

pub const Output = enum {
    /// Only sizes and positions: no bytes are stored, and patches are skipped.
    counting,
    /// Into a caller's buffer; running out of room is `error.Overflow`.
    fixed,
};

/// A writer's parameters: each a compile-time value, or null for a run-time
/// field.
pub const WriterConfig = struct {
    version: ?XcdrVersion = null,
    order: ?ByteOrder = null,
    output: ?Output = null,
};

pub fn Writer(comptime cfg: WriterConfig) type {
    return struct {
        const Self = @This();

        /// The output buffer: empty when counting.
        buf: if (cfg.output == .counting) void else []u8,
        /// Bytes written since the buffer's start.
        len: usize = 0,
        /// The alignment position: bytes since the payload's origin, which
        /// `resetPayload` moves.
        pos: usize = 0,
        version_rt: if (cfg.version == null) XcdrVersion else void,
        order_rt: if (cfg.order == null) ByteOrder else void,
        output_rt: if (cfg.output == null) Output else void,

        pub const config = cfg;

        /// A writer into `buf`. `version` and `order` must match the
        /// instance's compile-time values, where it has them.
        pub fn initFixed(buf: []u8, v: XcdrVersion, o: ByteOrder) Self {
            if (cfg.output == .counting) @compileError("a counting writer has no buffer");
            return init(buf, v, o, .fixed);
        }

        /// A writer that only counts.
        pub fn initCounting(v: XcdrVersion, o: ByteOrder) Self {
            if (cfg.output == .fixed) @compileError("a fixed writer needs a buffer");
            return init(if (cfg.output == .counting) {} else &.{}, v, o, .counting);
        }

        fn init(buf: @FieldType(Self, "buf"), v: XcdrVersion, o: ByteOrder, out: Output) Self {
            if (cfg.version) |want| std.debug.assert(want == v);
            if (cfg.order) |want| std.debug.assert(want == o);
            return .{
                .buf = buf,
                .version_rt = if (cfg.version == null) v else {},
                .order_rt = if (cfg.order == null) o else {},
                .output_rt = if (cfg.output == null) out else {},
            };
        }

        pub inline fn version(self: *const Self) XcdrVersion {
            return cfg.version orelse self.version_rt;
        }
        pub inline fn order(self: *const Self) ByteOrder {
            return cfg.order orelse self.order_rt;
        }
        pub inline fn output(self: *const Self) Output {
            return cfg.output orelse self.output_rt;
        }
        inline fn cap(self: *const Self) usize {
            return if (self.version() == .xcdr1) 8 else 4;
        }
        inline fn counting(self: *const Self) bool {
            return self.output() == .counting;
        }
        /// Whether this writer only counts: generated code that sizes a
        /// nested body itself checks it.
        pub fn isCounting(self: *const Self) bool {
            return self.counting();
        }

        /// What has been written; empty when counting.
        pub fn bytes(self: *const Self) []u8 {
            if (cfg.output == .counting) return &.{};
            if (self.counting()) return &.{};
            return self.buf[0..self.len];
        }

        /// What patches write into: null when counting.
        fn storage(self: *const Self) ?[]u8 {
            if (cfg.output == .counting) return null;
            if (self.counting()) return null;
            return self.buf;
        }

        // ── Raw output ────────────────────────────────────────────────────

        pub fn writeBytes(self: *Self, data: []const u8) error{Overflow}!void {
            const next = std.math.add(usize, self.len, data.len) catch return error.Overflow;
            if (cfg.output != .counting and !self.counting()) {
                if (next > self.buf.len) return error.Overflow;
                @memcpy(self.buf[self.len..next], data);
            }
            self.len = next;
            self.pos += data.len;
        }

        pub fn payloadPosition(self: *const Self) usize {
            return self.pos;
        }
        pub fn byteLen(self: *const Self) usize {
            return self.len;
        }
        pub fn resetPayload(self: *Self) void {
            self.pos = 0;
        }

        // ── Encapsulation ─────────────────────────────────────────────────

        fn writeEncap(self: *Self, kind: framing.Extensibility) !void {
            try framing.writeEncapsulation(self, framing.encapsulationId(self.version(), self.order(), kind, false));
        }

        /// The 4-byte encapsulation header for a @final type; resets the
        /// alignment origin to after it.
        pub fn writeEncapHeader(self: *Self) !void {
            try self.writeEncap(.final);
        }
        /// For an @appendable top-level type (DELIMITED_CDR2 on XCDR2).
        pub fn writeEncapHeaderDelimited(self: *Self) !void {
            try self.writeEncap(.appendable);
        }
        /// For a @mutable top-level type (PL_CDR2 on XCDR2).
        pub fn writeEncapHeaderMutable(self: *Self) !void {
            try self.writeEncap(.mutable);
        }

        // ── Primitives ────────────────────────────────────────────────────

        inline fn put(self: *Self, comptime T: type, v: T) error{Overflow}!void {
            if (cfg.output == .counting or (cfg.output == null and self.counting())) {
                // Only the padding and the size: nothing to encode.
                const size = @sizeOf(T);
                const boundary = @min(size, self.cap());
                const step = (boundary - self.pos % boundary) % boundary + size;
                const len = std.math.add(usize, self.len, step) catch return error.Overflow;
                self.pos = std.math.add(usize, self.pos, step) catch return error.Overflow;
                self.len = len;
                return;
            }
            try primitives.writeUnsigned(self, T, v, self.pos, self.cap(), self.order());
        }

        pub fn writeU8(self: *Self, v: u8) !void {
            try self.put(u8, v);
        }
        pub fn writeI8(self: *Self, v: i8) !void {
            try self.put(u8, @bitCast(v));
        }
        pub fn writeBool(self: *Self, v: bool) !void {
            try self.put(u8, @intFromBool(v));
        }
        /// IDL `char`: one byte.
        pub fn writeChar(self: *Self, v: u8) !void {
            try self.put(u8, v);
        }
        /// IDL `wchar`: two bytes.
        pub fn writeWchar(self: *Self, v: u16) !void {
            try self.put(u16, v);
        }
        pub fn writeU16(self: *Self, v: u16) !void {
            try self.put(u16, v);
        }
        pub fn writeI16(self: *Self, v: i16) !void {
            try self.put(u16, @bitCast(v));
        }
        pub fn writeU32(self: *Self, v: u32) !void {
            try self.put(u32, v);
        }
        pub fn writeI32(self: *Self, v: i32) !void {
            try self.put(u32, @bitCast(v));
        }
        pub fn writeF32(self: *Self, v: f32) !void {
            try self.put(u32, @bitCast(v));
        }
        pub fn writeU64(self: *Self, v: u64) !void {
            try self.put(u64, v);
        }
        pub fn writeI64(self: *Self, v: i64) !void {
            try self.put(u64, @bitCast(v));
        }
        pub fn writeF64(self: *Self, v: f64) !void {
            try self.put(u64, @bitCast(v));
        }

        /// A `fixed<D,S>` value as packed BCD (alignment 1).
        pub fn writeFixed(self: *Self, comptime D: u8, comptime S: u8, value: f64) !void {
            comptime if (D < 1 or D > 31) @compileError("fixed<D,S>: D must be 1..31");
            comptime if (S > D) @compileError("fixed<D,S>: S must be <= D");
            try fixed_mod.write(self, D, S, value);
        }

        /// A contiguous primitive array body, without length or framing.
        pub fn writePrimitiveArray(self: *Self, comptime T: type, values: []const T) !void {
            if (values.len == 0) return;
            const width = primitives.nativeArrayWidth(T);
            const pad = primitives.arrayPadding(width, self.pos, self.cap());
            const size = try std.math.mul(usize, values.len, width);
            const total = try std.math.add(usize, pad, size);
            const end = try std.math.add(usize, self.len, total);
            if (cfg.output != .counting and !self.counting()) {
                if (end > self.buf.len) return error.Overflow;
                const dest = self.buf[self.len..end];
                @memset(dest[0..pad], 0);
                if (T == bool) {
                    primitives.writeBools(dest[pad..], values);
                } else {
                    primitives.copyArray(dest[pad..], std.mem.sliceAsBytes(values), width, self.order());
                }
            }
            self.len = end;
            self.pos += total;
        }

        /// Reserves `count` primitives of `width` bytes (1/2/4/8) as
        /// `writePrimitiveArray` would write them (padding zeroed,
        /// all-or-nothing), leaving the elements to fill in place through
        /// `reservedBytes`, then `commitPrimitives`.
        pub fn reservePrimitives(self: *Self, width: usize, count: usize) !primitives.PrimitivesReservation {
            if (!primitives.isArrayWidth(width)) return error.InvalidPrimitiveSize;
            const swap = primitives.swaps(self.order(), width);
            if (count == 0) return .{ .offset = self.len, .width = width, .swap = swap };
            const pad = primitives.arrayPadding(width, self.pos, self.cap());
            const size = try std.math.mul(usize, count, width);
            const total = try std.math.add(usize, pad, size);
            const end = try std.math.add(usize, self.len, total);
            const start = self.len;
            if (cfg.output != .counting and !self.counting()) {
                if (end > self.buf.len) return error.Overflow;
                @memset(self.buf[start..][0..pad], 0);
            }
            self.len = end;
            self.pos += total;
            return .{ .offset = start + pad, .count = count, .width = width, .swap = swap };
        }

        /// Where to fill `res`; null when counting.
        pub fn reservedBytes(self: *Self, res: primitives.PrimitivesReservation) ?[]u8 {
            const s = self.storage() orelse return null;
            return res.bytes(s[0..self.len]);
        }

        /// Puts `res`'s filled elements in the writer's byte order, once.
        pub fn commitPrimitives(self: *Self, res: *primitives.PrimitivesReservation) void {
            const s = self.storage() orelse return;
            res.commit(s[0..self.len]);
        }

        // ── Strings ───────────────────────────────────────────────────────

        /// u32 length (including the NUL), the bytes, then a NUL.
        pub fn writeString(self: *Self, v: []const u8) !void {
            try strings.writeString(self, v);
        }
        /// The UTF-16 representation canonical key holders use.
        pub fn writeKeyWstring(self: *Self, v: []const u16) !void {
            try keys.writeWstring(self, v);
        }
        /// u32 byte count, then UTF-16 units; no NUL or BOM.
        pub fn writeWstring(self: *Self, v: []const u16) !void {
            try strings.writeWstring(self, v);
        }

        // ── DHEADER (XCDR2 @appendable and @mutable) ──────────────────────

        pub fn writeDheader(self: *Self, payload_size: u32) !void {
            try self.writeU32(payload_size);
        }

        /// A placeholder DHEADER; patch it once the payload is written.
        pub fn reserveDheader(self: *Self) !usize {
            if (self.version() != .xcdr2) return error.UnsupportedEncoding;
            var offset: usize = undefined;
            try framing.reserveDheader(self, &offset);
            return offset;
        }

        pub fn patchDheaderChecked(self: *Self, offset: usize) !void {
            try framing.patchDheader(self.storage(), self.len, offset, self.order());
        }
        pub fn patchDheader(self: *Self, offset: usize) void {
            self.patchDheaderChecked(offset) catch {};
        }

        /// A DHEADER on XCDR2, none (null) on XCDR1.
        pub fn reserveDheaderMaybe(self: *Self) !?usize {
            if (self.version() == .xcdr1) return null;
            return try self.reserveDheader();
        }
        pub fn patchDheaderMaybeChecked(self: *Self, offset: ?usize) !void {
            if (offset) |off| try self.patchDheaderChecked(off);
        }
        pub fn patchDheaderMaybe(self: *Self, offset: ?usize) void {
            if (offset) |off| self.patchDheader(off);
        }

        // ── EMHEADER (@mutable members) ───────────────────────────────────

        pub const EmheaderPlaceholder = struct {
            /// Offset of the NEXTINT word.
            nextint_offset: usize,
            /// The byte length right after the NEXTINT: the payload's start.
            payload_start: usize,
        };

        /// An EMHEADER for a member of exactly 1, 2, 4 or 8 bytes (LC 0–3).
        pub fn writeEmheaderFixed(self: *Self, member_id: u28, must_understand: bool, lc: u2) !void {
            try framing.writeEmheader(self, member_id, must_understand, lc);
        }

        /// An EMHEADER and NEXTINT placeholder (LC 4) for a member of any size.
        pub fn reserveEmheader(self: *Self, member_id: u28, must_understand: bool) !EmheaderPlaceholder {
            var offset: usize = undefined;
            try framing.reserveEmheader(self, member_id, must_understand, &offset);
            return .{ .nextint_offset = offset, .payload_start = self.len };
        }

        pub fn patchEmheaderChecked(self: *Self, ph: EmheaderPlaceholder) !void {
            try framing.patchEmheader(self.storage(), self.len, ph.nextint_offset, ph.payload_start, self.order());
        }
        pub fn patchEmheader(self: *Self, ph: EmheaderPlaceholder) void {
            self.patchEmheaderChecked(ph) catch {};
        }

        // ── Optional members ──────────────────────────────────────────────

        /// XCDR2: a presence byte, and no token. XCDR1: a parameter header,
        /// patched by `finishOptionalMember`.
        pub fn beginOptionalMember(self: *Self, member_id: u28, mu: bool, present: bool) !?framing.OptionalWrite {
            if (self.version() == .xcdr2) {
                try self.writeBool(present);
                return null;
            }
            return try framing.beginOptional(self, member_id, mu);
        }

        pub fn cancelOptionalMember(self: *Self, token: ?framing.OptionalWrite) void {
            if (token) |t| self.pos = framing.optionalParentPosition(self.len, t) catch return;
        }

        pub fn finishOptionalMember(self: *Self, token: ?framing.OptionalWrite) !void {
            defer self.cancelOptionalMember(token);
            if (token) |t| try framing.finishOptional(self.storage(), self.len, t, self.order());
        }

        // ── ParameterList (PL_CDR) ────────────────────────────────────────

        pub const PlParamHandle = struct {
            /// Offset of the u16 length field.
            len_offset: usize,
            /// Offset of the first value byte.
            value_start: usize,
        };

        /// The PL_CDR encapsulation header in this writer's byte order.
        pub fn writePlEncapHeader(self: *Self) !void {
            try framing.writeEncapsulation(self, if (self.order() == .little) 0x0003 else 0x0002);
        }

        /// A `(pid, 0)` parameter header; write the value, then `patchPlParam`.
        pub fn reservePlParam(self: *Self, pid: u16) !PlParamHandle {
            var h: PlParamHandle = undefined;
            try framing.reserveParameter(self, pid, &h.len_offset, &h.value_start);
            return h;
        }

        /// Pads the value to 4 bytes and patches its length.
        pub fn patchPlParam(self: *Self, h: PlParamHandle) !void {
            try framing.validateParameter(self.len, h.len_offset, h.value_start);
            const raw = self.len - h.value_start;
            const padded = try framing.parameterSize(raw);
            const zeros: [4]u8 = @splat(0);
            if (padded > raw) try self.writeBytes(zeros[0 .. padded - raw]);
            try framing.patchParameter(self.storage(), self.len, h.len_offset, h.value_start, self.order());
        }

        pub fn writePlSentinel(self: *Self) !void {
            try framing.writeSentinel(self, self.order());
        }

        /// A parameter retained verbatim, re-padded to 4 bytes.
        pub fn writeRawParam(self: *Self, pid: u16, value: []const u8) !void {
            const h = try self.reservePlParam(pid);
            try self.writeBytes(value);
            try self.patchPlParam(h);
        }
    };
}

/// The run-time instance: encoding, byte order and output chosen when it is
/// made. One copy of each generated `serialize` handles every combination.
pub const RuntimeWriter = Writer(.{});

/// Which instances get a compile-time copy. Each enabled encoding gets
/// counting and fixed writers and a reader; everything else uses the
/// run-time instance. Generated code receives this from zidl's
/// `--cdr-fast` option; an application chooses its own.
pub const FastSet = struct {
    xcdr1_le: bool = true,
    xcdr2_le: bool = true,

    pub const all: FastSet = .{};
    pub const none: FastSet = .{ .xcdr1_le = false, .xcdr2_le = false };

    pub fn has(comptime self: FastSet, comptime version: XcdrVersion, comptime order: ByteOrder) bool {
        if (order != .little) return false;
        return switch (version) {
            .xcdr1 => self.xcdr1_le,
            .xcdr2 => self.xcdr2_le,
        };
    }
};

/// The writer for an exact configuration: its fast instance when `fast`
/// has one, the run-time instance otherwise. Initialize it the same way
/// either way (`initFixed`/`initCounting` with the configuration's values).
pub fn WriterFor(comptime fast: FastSet, comptime version: XcdrVersion, comptime order: ByteOrder, comptime output: Output) type {
    if (fast.has(version, order)) return Writer(.{ .version = version, .order = order, .output = output });
    return RuntimeWriter;
}

pub const SerializeAllocError = error{ OutOfMemory, Overflow, LengthMismatch };

/// Counts `value`, allocates exactly that, and writes it: what a growable
/// writer was for. `write(writer, value)` must write the same bytes both
/// times; a mismatch (the value changed between the passes, for one) is
/// `error.LengthMismatch` or `error.Overflow`, never memory corruption.
/// Caller owns the result.
pub fn serializeAlloc(
    comptime fast: FastSet,
    comptime version: XcdrVersion,
    comptime order: ByteOrder,
    allocator: std.mem.Allocator,
    value: anytype,
    comptime write: anytype,
) ![]u8 {
    var counter = WriterFor(fast, version, order, .counting).initCounting(version, order);
    try write(&counter, value);
    const out = try allocator.alloc(u8, counter.len);
    errdefer allocator.free(out);
    var w = WriterFor(fast, version, order, .fixed).initFixed(out, version, order);
    try write(&w, value);
    if (w.len != counter.len) return error.LengthMismatch;
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A message crossing every alignment, framing kind and the bulk paths.
fn writeMessage(w: anytype) !void {
    try writeScalars(w);
    try w.writePrimitiveArray(u32, &[_]u32{ 1, 2, 3 });
    try w.writePrimitiveArray(bool, &[_]bool{ true, false });
    try writeFraming(w);
}

fn writeScalars(w: anytype) !void {
    try w.writeU8(0x11);
    try w.writeF64(1.5);
    try w.writeU16(0x2233);
    try w.writeI64(-7);
    try w.writeString("hello");
    try w.writeWstring(&[_]u16{ 'h', 'i' });
    try w.writeBool(true);
    try w.writeFixed(5, 2, 123.45);
}

fn writeFraming(w: anytype) !void {
    const dh = try w.reserveDheaderMaybe();
    try w.writeU32(42);
    const em = try w.reserveEmheader(7, true);
    try w.writeString("member");
    try w.patchEmheaderChecked(em);
    try w.writeEmheaderFixed(8, false, 2);
    try w.writeI32(-1);
    try w.patchDheaderMaybeChecked(dh);
    const opt = try w.beginOptionalMember(9, false, true);
    try w.writeU64(0xdead_beef);
    try w.finishOptionalMember(opt);
}

/// The message's bytes, checked equal to the removed `CdrWriter`
/// (little-endian) and `PrimitiveWriter` (big-endian) before they went.
const known = struct {
    const xcdr1_le = "000100001100000000000000000000000000f83f3322000000000000f9ffffffffffffff0600000068656c6c6f00000004000000680069000112345c010000000200000003000000010000002a000000070000c00b000000070000006d656d626572000008000020ffffffff017f08000900000008000000efbeadde00000000";
    const xcdr2_le = "0009000011000000000000000000f83f33220000f9ffffffffffffff0600000068656c6c6f00000004000000680069000112345c01000000020000000300000001000000200000002a000000070000c00b000000070000006d656d626572000008000020ffffffff01000000efbeadde00000000";
    // Without the arrays.
    const xcdr1_be = "0000000011000000000000003ff80000000000002233000000000000fffffffffffffff90000000668656c6c6f00000000000004006800690112345c0000002ac00000070000000b000000076d656d626572000020000008ffffffff7f010008000000090000000800000000deadbeef";
    const xcdr2_be = "00080000110000003ff800000000000022330000fffffffffffffff90000000668656c6c6f00000000000004006800690112345c000000200000002ac00000070000000b000000076d656d626572000020000008ffffffff0100000000000000deadbeef";
};

fn checkInstance(comptime C: type, comptime W: type, version: XcdrVersion, order: ByteOrder, expected: []const u8) !void {
    var counter = C.initCounting(version, order);
    try counter.writeEncapHeaderDelimited();
    try writeMessage(&counter);
    try testing.expectEqual(expected.len, counter.len);
    try testing.expectEqual(@as(usize, 0), counter.bytes().len);

    const out = try testing.allocator.alloc(u8, counter.len);
    defer testing.allocator.free(out);
    var w = W.initFixed(out, version, order);
    try w.writeEncapHeaderDelimited();
    try writeMessage(&w);
    try testing.expectEqualSlices(u8, expected, w.bytes());

    // One byte short: an error, never a write past the end.
    var short = W.initFixed(out[0 .. out.len - 1], version, order);
    try short.writeEncapHeaderDelimited();
    try testing.expectError(error.Overflow, writeMessage(&short));
}

test "every little-endian instance writes the known bytes" {
    inline for (.{ XcdrVersion.xcdr1, XcdrVersion.xcdr2 }) |version| {
        var buf: [512]u8 = undefined;
        const expected = try std.fmt.hexToBytes(&buf, if (version == .xcdr1) known.xcdr1_le else known.xcdr2_le);
        try checkInstance(WriterFor(.all, version, .little, .counting), WriterFor(.all, version, .little, .fixed), version, .little, expected);
        const Mixed = Writer(.{ .version = version, .order = .little });
        try checkInstance(Mixed, Mixed, version, .little, expected);
        try checkInstance(RuntimeWriter, RuntimeWriter, version, .little, expected);
        try checkInstance(WriterFor(.none, version, .little, .counting), WriterFor(.none, version, .little, .fixed), version, .little, expected);
    }
}

test "the run-time instance writes the known big-endian bytes" {
    inline for (.{ XcdrVersion.xcdr1, XcdrVersion.xcdr2 }) |version| {
        var buf: [512]u8 = undefined;
        const expected = try std.fmt.hexToBytes(&buf, if (version == .xcdr1) known.xcdr1_be else known.xcdr2_be);
        var out: [256]u8 = undefined;
        var w = RuntimeWriter.initFixed(&out, version, .big);
        try w.writeEncapHeaderDelimited();
        try writeScalars(&w);
        try writeFraming(&w);
        try testing.expectEqualSlices(u8, expected, w.bytes());
    }
}

test "the run-time instance writes big-endian arrays" {
    var out: [32]u8 = undefined;
    var w = RuntimeWriter.initFixed(&out, .xcdr1, .big);
    try w.writeU8(9);
    try w.writePrimitiveArray(u64, &[_]u64{0x0102030405060708});
    try w.writePrimitiveArray(u16, &[_]u16{ 0x0a0b, 0x0c0d });
    try testing.expectEqualSlices(u8, &[_]u8{ 9, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0x0a, 0x0b, 0x0c, 0x0d }, w.bytes());
}

test "counting and fixed instances pick their fast copies" {
    try testing.expect(WriterFor(.all, .xcdr2, .little, .fixed) == Writer(.{ .version = .xcdr2, .order = .little, .output = .fixed }));
    try testing.expect(WriterFor(.all, .xcdr1, .little, .counting) == Writer(.{ .version = .xcdr1, .order = .little, .output = .counting }));
    try testing.expect(WriterFor(.all, .xcdr2, .big, .fixed) == RuntimeWriter);
    try testing.expect(WriterFor(.{ .xcdr1_le = false }, .xcdr1, .little, .fixed) == RuntimeWriter);
    // A fast counting instance stores nothing at all.
    try testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @sizeOf(Writer(.{ .version = .xcdr2, .order = .little, .output = .counting })));
}

test "serializeAlloc counts, allocates exactly and writes" {
    const S = struct {
        fn write(w: anytype, v: u32) !void {
            try w.writeEncapHeader();
            try w.writeString("abc");
            try w.writeU64(v);
        }
    };
    const out = try serializeAlloc(.all, .xcdr1, .little, testing.allocator, @as(u32, 5), S.write);
    defer testing.allocator.free(out);
    // The header resets the alignment origin, so the u64 needs no padding.
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0, 0, 4, 0, 0, 0, 'a', 'b', 'c', 0, 5, 0, 0, 0, 0, 0, 0, 0 }, out);
}

test "serializeAlloc reports a value that changed between its passes" {
    const S = struct {
        var calls: u32 = 0;
        fn write(w: anytype, _: void) !void {
            calls += 1;
            try w.writeString(if (calls == 1) "ab" else "a");
        }
        fn grow(w: anytype, _: void) !void {
            calls += 1;
            try w.writeString(if (calls == 1) "a" else "ab");
        }
    };
    try testing.expectError(error.LengthMismatch, serializeAlloc(.all, .xcdr2, .little, testing.allocator, {}, S.write));
    S.calls = 0;
    try testing.expectError(error.Overflow, serializeAlloc(.all, .xcdr2, .little, testing.allocator, {}, S.grow));
}

test "reservations fill in place, and counting writers have nothing to fill" {
    var out: [32]u8 = undefined;
    var w = RuntimeWriter.initFixed(&out, .xcdr2, .big);
    try w.writeU8(1);
    var res = try w.reservePrimitives(4, 2);
    const dest = w.reservedBytes(res).?;
    std.mem.writeInt(u32, dest[0..4], 0x01020304, @import("builtin").cpu.arch.endian());
    std.mem.writeInt(u32, dest[4..8], 0x05060708, @import("builtin").cpu.arch.endian());
    w.commitPrimitives(&res);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 }, w.bytes());
    try testing.expectError(error.InvalidPrimitiveSize, w.reservePrimitives(3, 1));

    var c = Writer(.{ .version = .xcdr2, .order = .little, .output = .counting }).initCounting(.xcdr2, .little);
    var cres = try c.reservePrimitives(8, 3);
    try testing.expect(c.reservedBytes(cres) == null);
    c.commitPrimitives(&cres);
    try testing.expectEqual(@as(usize, 24), c.len);
}

test "a reservation bound for a builder fills in place and commits once" {
    var out: [32]u8 = undefined;
    inline for (.{ ByteOrder.little, ByteOrder.big }) |order| {
        var w = RuntimeWriter.initFixed(&out, .xcdr2, order);
        try w.writeU8(1);
        var rp: primitives.ReservedPrimitives = .{ .count = 2 };
        const res = try w.reservePrimitives(2, rp.count);
        rp.bind(w.reservedBytes(res), res);
        try testing.expect(rp.asNative(u32) == null);
        const elems = rp.asNative(u16).?;
        try testing.expectEqual(@as(usize, 2), elems.len);
        elems[0] = 0x0102;
        elems[1] = 0x0304;
        rp.commit();
        rp.commit(); // once: a repeat changes nothing
        const expected: []const u8 = if (order == .little) &.{ 1, 0, 2, 1, 4, 3 } else &.{ 1, 0, 1, 2, 3, 4 };
        try testing.expectEqualSlices(u8, expected, w.bytes());

        var w2 = RuntimeWriter.initFixed(&out, .xcdr2, order);
        var rp2: primitives.ReservedPrimitives = .{ .count = 2 };
        const res2 = try w2.reservePrimitives(4, rp2.count);
        rp2.bind(w2.reservedBytes(res2), res2);
        try testing.expectError(error.LengthMismatch, rp2.copyFrom(u32, &[_]u32{1}));
        try testing.expectError(error.InvalidPrimitiveSize, rp2.copyFrom(u16, &[_]u16{ 1, 2 }));
        try rp2.copyFrom(u32, &[_]u32{ 0x01020304, 0x05060708 });
        rp2.commit();
        const expected2: []const u8 = if (order == .little) &.{ 4, 3, 2, 1, 8, 7, 6, 5 } else &.{ 1, 2, 3, 4, 5, 6, 7, 8 };
        try testing.expectEqualSlices(u8, expected2, w2.bytes());
    }

    // Counting: nothing to fill.
    var c = Writer(.{ .version = .xcdr2, .order = .little, .output = .counting }).initCounting(.xcdr2, .little);
    var rp: primitives.ReservedPrimitives = .{ .count = 3 };
    const res = try c.reservePrimitives(8, rp.count);
    rp.bind(c.reservedBytes(res), res);
    try testing.expectEqual(@as(usize, 0), rp.asNative(u64).?.len);
    try testing.expectEqual(@as(usize, 3), rp.count);
}

test "parameter lists are written with padded lengths and a sentinel" {
    var out: [64]u8 = undefined;
    var w = Writer(.{ .version = .xcdr1, .order = .little, .output = .fixed }).initFixed(&out, .xcdr1, .little);
    try w.writePlEncapHeader();
    const h = try w.reservePlParam(0x0050);
    try w.writeString("abcde");
    try w.patchPlParam(h);
    try w.writeRawParam(0x8001, &[_]u8{ 1, 2, 3 });
    try w.writePlSentinel();
    try testing.expectEqualSlices(u8, &[_]u8{
        0, 3, 0, 0, // PL_CDR_LE
        0x50, 0, 12, 0, 6, 0, 0, 0, 'a', 'b', 'c', 'd', 'e', 0, 0, 0, // padded to 12
        0x01, 0x80, 4, 0, 1, 2, 3, 0, // retained verbatim, padded to 4
        1, 0, 0, 0, // PID_SENTINEL
    }, w.bytes());
}

test "a DHEADER is XCDR2-only, and patches outside what was written are refused" {
    var out: [32]u8 = undefined;
    var x1 = RuntimeWriter.initFixed(&out, .xcdr1, .little);
    try testing.expectError(error.UnsupportedEncoding, x1.reserveDheader());
    try testing.expectEqual(@as(?usize, null), try x1.reserveDheaderMaybe());
    var x2 = RuntimeWriter.initFixed(&out, .xcdr2, .little);
    try testing.expectError(error.InvalidPatch, x2.patchDheaderChecked(8));
    x2.patchDheader(8);
    try x2.writeDheader(3);
    try testing.expectEqualSlices(u8, &[_]u8{ 3, 0, 0, 0 }, x2.bytes());
    try x2.writeChar('c');
    try x2.writeWchar('w');
    try x2.writeI8(-1);
    try x2.writeI16(-2);
    try x2.writeF32(1.0);
    try x2.writeKeyWstring(&[_]u16{'k'});
    x2.resetPayload();
    try testing.expectEqual(@as(usize, 0), x2.payloadPosition());
    try testing.expect(x2.byteLen() > 4);
}

test "the remaining framing calls, and running out of room in bulk writes" {
    var out: [24]u8 = undefined;
    var w = RuntimeWriter.initFixed(&out, .xcdr2, .big);
    try w.writeEncapHeaderMutable();
    const dh = try w.reserveDheaderMaybe();
    const em = try w.reserveEmheader(1, false);
    try w.writeU8(5);
    w.patchEmheader(em);
    w.patchDheaderMaybe(dh);
    w.patchDheaderMaybe(null);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0x0a, 0, 0, 0, 0, 0, 9, 0x40, 0, 0, 1, 0, 0, 0, 1, 5 }, w.bytes());
    var empty = try w.reservePrimitives(4, 0);
    try testing.expectEqual(@as(usize, 0), w.reservedBytes(empty).?.len);
    w.commitPrimitives(&empty);
    try testing.expectError(error.Overflow, w.reservePrimitives(8, 2));
    try testing.expectError(error.Overflow, w.writePrimitiveArray(u64, &[_]u64{ 1, 2 }));
    try w.writePrimitiveArray(u8, &[_]u8{});
}

test "a big-endian parameter list reads back: lengths and sentinel in its byte order" {
    var pl: [32]u8 = undefined;
    var b = RuntimeWriter.initFixed(&pl, .xcdr1, .big);
    try b.writePlEncapHeader();
    const h = try b.reservePlParam(0x0050);
    try b.writeU32(0x01020304);
    try b.patchPlParam(h);
    try b.writePlSentinel();
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 2, 0, 0, 0, 0x50, 0, 4, 1, 2, 3, 4, 0, 1, 0, 0 }, b.bytes());

    var r = try @import("reader.zig").CdrReader.init(b.bytes());
    try testing.expect(r.is_pl_cdr);
    const p = (try r.readPlParam(.strict)).?;
    try testing.expectEqual(@as(u16, 0x0050), p.pid);
    try testing.expectEqual(@as(u16, 4), p.byte_len);
    try testing.expectEqual(@as(u32, 0x01020304), try r.readU32());
    try r.seekTo(p.end_pos);
    try testing.expectEqual(@as(?@import("reader.zig").CdrReader.PlParam, null), try r.readPlParam(.strict));
}
