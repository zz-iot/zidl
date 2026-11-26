//! The CDR reader: one generic source, encoding and byte order each fixed at
//! compile time or read from the sample's encapsulation header
//! (docs/design/cdr-specialized-instances.md). `CdrReader` is the run-time
//! instance; a fast instance (`Reader(.{ .version = .xcdr2, .order = .little })`)
//! accepts only its own header and folds every alignment and byte-order
//! branch. Every instance checks bounds on every read: input is untrusted.

const std = @import("std");
const fixed = @import("cdr_fixed.zig");
const primitives = @import("cdr_primitives.zig");
const cursor = @import("cdr_cursor.zig");
const strings = @import("cdr_strings.zig");
const framing = @import("cdr_framing.zig");

pub const XcdrVersion = framing.Version;
pub const ByteOrder = primitives.ByteOrder;

/// A reader's parameters: each a compile-time value, or null to take it
/// from the header.
pub const ReaderConfig = struct {
    version: ?XcdrVersion = null,
    order: ?ByteOrder = null,
};

/// CDR reader. Constructed by parsing the 4-byte encapsulation header;
/// subsequent reads apply CDR alignment and the stream's byte order, and
/// return `error.EndOfStream` on any truncation.
pub fn Reader(comptime cfg: ReaderConfig) type {
    return struct {
        const Self = @This();
        pub const config = cfg;

        data: []const u8,
        /// Current read position.  Starts at 4 (after the 4-byte encap header).
        pos: usize,
        byte_order: ByteOrder,
        xcdr_version: XcdrVersion,
        /// True when the stream uses PL_CDR (ParameterList) framing.
        /// xcdr_version is .xcdr1 for PL_CDR; this flag distinguishes PL_CDR from plain XCDR1.
        is_pl_cdr: bool,
        /// Opt-in required-member and exact-known-member admission checks.
        strict_validation: bool = false,

        // ── Construction ─────────────────────────────────────────────────────

        /// Parse the 4-byte CDR encapsulation header and return a ready reader.
        ///
        /// Supported encapsulation IDs (big-endian u16 in bytes [0..1]):
        ///   0x0000 → XCDR1 big-endian
        ///   0x0001 → XCDR1 little-endian
        ///   0x0002 → PL_CDR (ParameterList) big-endian   (is_pl_cdr=true, xcdr1 alignment)
        ///   0x0003 → PL_CDR (ParameterList) little-endian (is_pl_cdr=true, xcdr1 alignment)
        ///   0x0006 → XCDR2 big-endian
        ///   0x0007 → XCDR2 little-endian
        ///   0x0008 → XCDR2 Delimited CDR big-endian  (@appendable, same as 0x0006 here)
        ///   0x0009 → XCDR2 Delimited CDR little-endian (@appendable, same as 0x0007 here)
        ///   0x000a → XCDR2 ParameterList CDR big-endian  (@mutable, same as 0x0006 here)
        ///   0x000b → XCDR2 ParameterList CDR little-endian (@mutable, same as 0x0007 here)
        pub fn init(data: []const u8) !Self {
            const encap = try framing.parseEncapsulation(data);
            if (cfg.version) |v| if (encap.version != v) return error.EncapsulationMismatch;
            if (cfg.order) |o| if (encap.order != o) return error.EncapsulationMismatch;
            return .{ .data = data, .pos = 4, .byte_order = encap.order, .xcdr_version = encap.version, .is_pl_cdr = encap.is_pl_cdr };
        }

        /// The stream's encoding: the instance's own when it has one.
        pub inline fn version(self: *const Self) XcdrVersion {
            return cfg.version orelse self.xcdr_version;
        }
        pub inline fn order(self: *const Self) ByteOrder {
            return cfg.order orelse self.byte_order;
        }
        /// For generated code: a compile-time constant in a fast instance.
        pub inline fn isXcdr2(self: *const Self) bool {
            return self.version() == .xcdr2;
        }
        inline fn cap(self: *const Self) usize {
            return if (self.version() == .xcdr1) 8 else 4;
        }

        /// Stack-copy a reader with an explicit absolute end; alignment origin stays 4.
        pub fn limited(self: *const Self, end: usize) !Self {
            try framing.validateLimit(self.pos, self.data.len, end);
            var out = self.*;
            out.data = self.data[0..end];
            return out;
        }

        /// A caller-owned stack window. Close after cancel's errdefer: errors keep
        /// the consumed cursor, while success skips the remainder of this frame.
        pub const Window = struct {
            reader: *Self,
            saved_data: []const u8,
            end: usize,
            complete: bool = true,

            pub fn cancel(self: *Window) void {
                self.complete = false;
            }

            pub fn close(self: *Window) void {
                self.reader.data = self.saved_data;
                if (self.complete) self.reader.pos = self.end;
            }
        };

        /// Usage: defer window.close(); errdefer window.cancel();
        /// No hidden nesting state is added to the reader itself.
        pub fn window(self: *Self, end: usize) !Window {
            const bounded = try self.limited(end);
            const scope = Window{ .reader = self, .saved_data = self.data, .end = end };
            self.* = bounded;
            return scope;
        }

        pub const OptionalScope = struct {
            reader: *Self,
            parent: Self,
            framed: bool,
            present: bool,

            pub fn close(self: *OptionalScope) void {
                const pos = self.reader.pos;
                self.reader.* = self.parent;
                if (!self.framed) self.reader.pos = pos;
            }
        };

        /// Close on success and failure before closing any enclosing frame.
        pub fn beginOptionalMember(self: *Self, member_id: u28) !OptionalScope {
            if (self.version() == .xcdr2) {
                const present = try self.readBool();
                return .{ .reader = self, .parent = self.*, .framed = false, .present = present };
            }
            const span = try framing.readOptional(self.data, &self.pos, member_id, self.order());
            var parent = self.*;
            parent.pos = span.end;
            self.data = self.data[span.start - 4 .. span.end];
            self.pos = 4;
            return .{ .reader = self, .parent = parent, .framed = true, .present = span.start != span.end };
        }

        // ── Internal helpers ──────────────────────────────────────────────────

        fn readSlice(self: *Self, n: usize) ![]const u8 {
            return cursor.readSlice(self.data, &self.pos, n);
        }

        // ── Status ────────────────────────────────────────────────────────────

        pub fn remaining(self: *const Self) usize {
            return if (self.pos < self.data.len) self.data.len - self.pos else 0;
        }

        pub fn skip(self: *Self, n: usize) !void {
            _ = try cursor.advance(&self.pos, self.data.len, n);
        }

        /// Skip a run of `count` fixed-size primitive elements of `elem_wire_size`
        /// bytes each (a `sequence<primitive>` body or a primitive array) without
        /// touching the bytes -- aligns to the element boundary, then advances the
        /// cursor by `count * elem_wire_size` in one step. `elem_wire_size` must be
        /// 1/2/4/8. The caller has already consumed any length prefix.
        pub fn skipPrimitives(self: *Self, count: usize, elem_wire_size: usize) !void {
            try cursor.skipPrimitives(&self.pos, self.data.len, 4, count, elem_wire_size, self.cap());
        }

        /// Reads a primitive sequence's length, checked before its elements are
        /// allocated: within `bound` (null: unbounded), and with room for its
        /// elements of `elem_wire_size` bytes (1/2/4/8) in the input left. Reads
        /// only the length; on failure the reader is unchanged
        /// (`primitives.readSequenceCount`).
        pub fn readSequenceCount(self: *Self, elem_wire_size: usize, bound: ?u32) !u32 {
            return primitives.readSequenceCount(self.data, &self.pos, 4, self.cap(), self.order(), elem_wire_size, bound);
        }

        /// Read a contiguous primitive array body; failure leaves output unchanged.
        pub fn readPrimitiveArray(self: *Self, comptime T: type, values: []T) !void {
            if (values.len == 0) return;
            if (T == bool) {
                return primitives.readBools(self.data, &self.pos, values);
            }
            try primitives.readArray(self.data, &self.pos, 4, self.cap(), self.order(), primitives.nativeArrayWidth(T), values.len, std.mem.sliceAsBytes(values).ptr);
        }

        /// Consumes `count` primitives of `width` bytes (1/2/4/8) as
        /// `readPrimitiveArray` would, but returns a view of them in the input
        /// rather than copying them; valid while the input is. Failure leaves
        /// the reader unchanged.
        pub fn viewPrimitives(self: *Self, width: usize, count: usize) !primitives.PrimitivesView {
            return primitives.viewArray(self.data, &self.pos, 4, self.cap(), self.order(), width, count);
        }

        // ── Primitive reads ───────────────────────────────────────────────────

        pub fn readU8(self: *Self) !u8 {
            return primitives.readUnsigned(u8, self.data, &self.pos, 4, self.cap(), self.order());
        }

        pub fn readI8(self: *Self) !i8 {
            return @bitCast(try self.readU8());
        }

        pub fn readBool(self: *Self) !bool {
            return primitives.readBool(self.data, &self.pos);
        }

        pub fn readChar(self: *Self) !u8 {
            return self.readU8();
        }

        pub fn readWchar(self: *Self) !u16 {
            return self.readU16();
        }

        pub fn readU16(self: *Self) !u16 {
            return primitives.readUnsigned(u16, self.data, &self.pos, 4, self.cap(), self.order());
        }

        pub fn readI16(self: *Self) !i16 {
            return @bitCast(try self.readU16());
        }

        pub fn readU32(self: *Self) !u32 {
            return primitives.readUnsigned(u32, self.data, &self.pos, 4, self.cap(), self.order());
        }

        pub fn readI32(self: *Self) !i32 {
            return @bitCast(try self.readU32());
        }

        pub fn readF32(self: *Self) !f32 {
            return @bitCast(try self.readU32());
        }

        pub fn readU64(self: *Self) !u64 {
            return primitives.readUnsigned(u64, self.data, &self.pos, 4, self.cap(), self.order());
        }

        pub fn readI64(self: *Self) !i64 {
            return @bitCast(try self.readU64());
        }

        pub fn readF64(self: *Self) !f64 {
            return @bitCast(try self.readU64());
        }

        /// Read a `fixed<D,S>` value from packed BCD (alignment 1).
        pub fn readFixed(self: *Self, comptime D: u8, comptime S: u8) !f64 {
            comptime if (D < 1 or D > 31) @compileError("fixed<D,S>: D must be 1..31");
            comptime if (S > D) @compileError("fixed<D,S>: S must be <= D");
            return fixed.read(self.data, &self.pos, D, S);
        }

        // ── String / wstring reads ────────────────────────────────────────────

        /// Zero-copy string read: returns a slice pointing into the CDR buffer.
        ///
        /// The slice is valid as long as the buffer passed to `init` stays alive.
        /// Suitable for the DataReader loan pattern (no per-message allocation).
        pub fn readStringZeroCopy(self: *Self) ![]const u8 {
            return strings.readString(self.data, &self.pos, self.cap(), self.order());
        }

        pub fn skipString(self: *Self) !void {
            _ = try self.readStringZeroCopy();
        }

        /// Owned content excludes the terminator; free with the supplied allocator.
        pub fn readString(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            return allocator.dupe(u8, try self.readStringZeroCopy());
        }

        /// Validate the entire wire span before allocating owned host-order units.
        /// The returned slice excludes the terminator and can contain embedded NULs.
        pub fn readWstring(self: *Self, allocator: std.mem.Allocator) ![]u16 {
            const view = try strings.readWstring(self.data, &self.pos, self.cap(), self.order());
            const out = try allocator.alloc(u16, view.len());
            for (out, 0..) |*wc, i| wc.* = view.codeUnit(i);
            return out;
        }

        pub fn skipWstring(self: *Self) !void {
            _ = try strings.readWstring(self.data, &self.pos, self.cap(), self.order());
        }

        // ── XCDR2 framing ─────────────────────────────────────────────────────

        /// Read and return a DHEADER value (byte count of the following payload).
        pub fn readDheader(self: *Self) !u32 {
            return self.readU32();
        }

        /// For generated @appendable/@mutable types: skip the DHEADER on XCDR2,
        /// no-op on XCDR1 (no DHEADER in XCDR1).
        pub fn skipDheaderIfXcdr2(self: *Self) !void {
            if (self.version() == .xcdr2) _ = try self.readMutableDheader();
        }

        /// Decoded EMHEADER for a @mutable type member.
        pub const EmHeader = framing.EmHeader;

        /// Read an EMHEADER (+ optional NEXTINT) for a @mutable type member.
        ///
        /// XCDR2 §7.3.3.3 — EMHEADER bit layout:
        ///   bit 31: MUST_UNDERSTAND
        ///   bits 28–30: LC (length code)
        ///   bits 0–27: member-id
        ///
        /// LC < 4: no NEXTINT; inline length (0=1B, 1=2B, 2=4B, 3=8B).
        /// LC = 4: a separate NEXTINT follows holding the member's byte length;
        ///   it is consumed.
        /// LC 5–7: the NEXTINT is the first word of the member value itself (its
        ///   DHEADER, string length or sequence length), so it is only peeked and
        ///   the reader stays at the start of the value. Length = 4 + NEXTINT,
        ///   4 + 4×NEXTINT or 4 + 8×NEXTINT (XTypes 1.3 §7.4.3.4.8). Other
        ///   implementations write these for string and collection members.
        pub fn readEmheader(self: *Self) !EmHeader {
            return framing.readEmheader(self.data, &self.pos, self.cap(), self.order());
        }

        pub fn readMutableDheader(self: *Self) !usize {
            if (self.version() != .xcdr2) return error.UnsupportedEncoding;
            return framing.readDheaderEnd(self.data, &self.pos, self.cap(), self.order());
        }

        pub fn mutableHasMore(self: *const Self, end_pos: usize) bool {
            return end_pos <= self.data.len and self.pos < end_pos;
        }

        pub fn emheaderEnd(self: *const Self, emh: EmHeader) !usize {
            return framing.memberEnd(self.pos, self.data.len, self.cap(), emh.lc, emh.payload_bytes);
        }

        pub fn skipEmheaderPayload(self: *Self, emh: EmHeader) !void {
            try framing.skipMember(&self.pos, self.data.len, self.cap(), emh.lc, emh.payload_bytes);
        }

        // ── PL_CDR (ParameterList) framing ────────────────────────────────────

        /// Structural-validation strictness for `readPlParam`.
        ///
        ///  * `lenient` — end the parameter loop cleanly at a truncated parameter or
        ///    a buffer that ends without `PID_SENTINEL`, and round a length that is
        ///    not a multiple of 4 up to the next boundary. Matches the tolerance of
        ///    hand-rolled RTPS discovery parsers.
        ///  * `strict` — return a typed error for any of those
        ///    (`error.TruncatedParameter` / `error.MissingSentinel` /
        ///    `error.MisalignedParameter`). For decoding data from an untrusted peer.
        pub const PlMode = enum { lenient, strict };

        /// One PL_CDR parameter retained verbatim by a `@pl_retain_unknown` type's
        /// generated deserializer. `bytes` is the value only (no PID/length header,
        /// no trailing pad), owned by the containing struct's allocator; re-emit it
        /// with `PlCdrWriter.writeRawParam(pid, bytes)`.
        pub const RawParam = struct {
            pid: u16,
            bytes: []u8,
        };

        /// Decoded PL_CDR parameter header.
        pub const PlParam = struct {
            /// Parameter ID, flag bits included. Bit 15 (`0x8000`) = vendor-specific,
            /// bit 14 (`0x4000`) = must-understand (RTPS 2.5 §9.6.4, Table 9.6);
            /// mask with `0x3FFF` for the bare id.
            pid: u16,
            /// Raw value byte count from the length field (before padding).
            byte_len: u16,
            /// Absolute reader position of the first value byte (equals `reader.pos`
            /// immediately after `readPlParam` returns). `data[value_start ..
            /// value_start + byte_len]` is the value.
            value_start: usize,
            /// Absolute reader position of the first byte *after* this parameter
            /// (value bytes + padding to next 4-byte boundary).
            /// Always call `seekTo(p.end_pos)` after processing a parameter.
            end_pos: usize,
        };

        /// Read one PL_CDR parameter header.
        ///
        /// Returns `null` on `PID_SENTINEL (0x0001)`, and (in `.lenient` mode) also
        /// when the buffer ends without a sentinel or the parameter value runs past
        /// the buffer — the caller should break its loop.  For all other PIDs the
        /// caller reads the value and then calls `seekTo(p.end_pos)` to advance past
        /// any trailing padding.
        pub fn readPlParam(self: *Self, mode: PlMode) !?PlParam {
            if (self.pos > self.data.len or self.data.len - self.pos < 4) {
                return switch (mode) {
                    .lenient => null,
                    .strict => error.MissingSentinel,
                };
            }
            const pid = try self.readU16();
            const len = try self.readU16();
            if (pid == 0x0001) return null; // PID_SENTINEL
            if (mode == .strict and len % 4 != 0) return error.MisalignedParameter;
            const end_pos = framing.parameterEnd(self.pos, len, self.data.len) catch {
                return switch (mode) {
                    .lenient => null,
                    .strict => error.TruncatedParameter,
                };
            };
            return PlParam{
                .pid = pid,
                .byte_len = len,
                .value_start = self.pos,
                .end_pos = end_pos,
            };
        }

        /// Seek to an absolute position in the data buffer.
        ///
        /// Used by generated deserializers to advance to `p.end_pos` after
        /// processing (or skipping) a PL_CDR parameter value.
        pub fn seekTo(self: *Self, abs_pos: usize) !void {
            try cursor.seek(&self.pos, self.data.len, abs_pos);
        }
    };
}

/// The run-time instance: any encoding and byte order, from the header.
pub const CdrReader = Reader(.{});

const FastSet = @import("writer.zig").FastSet;

/// The reader for samples in an exact encoding: its fast instance when
/// `fast` has one, the run-time instance otherwise.
pub fn ReaderFor(comptime fast: FastSet, comptime version: XcdrVersion, comptime order: ByteOrder) type {
    if (fast.has(version, order)) return Reader(.{ .version = version, .order = order });
    return CdrReader;
}

/// Reads one sample with the instance its encapsulation header selects:
/// one check per sample, then every read in that instance. `read(reader,
/// ctx)` is called once, with a fast reader for a header `fast` covers and
/// the run-time reader otherwise.
pub fn readSample(comptime fast: FastSet, comptime T: type, data: []const u8, ctx: anytype, comptime read: anytype) !T {
    const encap = try framing.parseEncapsulation(data);
    if (!encap.is_pl_cdr and encap.order == .little) {
        switch (encap.version) {
            inline else => |v| if (comptime fast.has(v, .little)) {
                var r = try Reader(.{ .version = v, .order = .little }).init(data);
                return read(&r, ctx);
            },
        }
    }
    var r = try CdrReader.init(data);
    return read(&r, ctx);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Writer = @import("writer.zig").Writer;
const RuntimeWriter = @import("writer.zig").RuntimeWriter;

fn writeSample(w: anytype) !void {
    try w.writeEncapHeaderDelimited();
    const dh = try w.reserveDheaderMaybe();
    try w.writeU8(7);
    try w.writeF64(2.5);
    try w.writeString("sample");
    try w.writePrimitiveArray(u16, &[_]u16{ 1, 2, 3 });
    try w.writeI64(-9);
    try w.patchDheaderMaybeChecked(dh);
}

const Decoded = struct { a: u8, b: f64, s_len: usize, arr: [3]u16, c: i64, fast: bool };

fn readDecoded(r: anytype, _: void) !Decoded {
    if (r.isXcdr2()) _ = try r.readMutableDheader();
    var out: Decoded = undefined;
    out.a = try r.readU8();
    out.b = try r.readF64();
    out.s_len = (try r.readStringZeroCopy()).len;
    try r.readPrimitiveArray(u16, &out.arr);
    out.c = try r.readI64();
    out.fast = @TypeOf(r.*).config.version != null;
    return out;
}

test "each instance reads what each writes, and a fast one only its own header" {
    inline for (.{ XcdrVersion.xcdr1, XcdrVersion.xcdr2 }) |version| {
        inline for (.{ ByteOrder.little, ByteOrder.big }) |order| {
            var buf: [128]u8 = undefined;
            var w = RuntimeWriter.initFixed(&buf, version, order);
            try writeSample(&w);
            const data = w.bytes();

            const viaDispatch = try readSample(.all, Decoded, data, {}, readDecoded);
            try testing.expectEqual(@as(u8, 7), viaDispatch.a);
            try testing.expectEqual(@as(f64, 2.5), viaDispatch.b);
            try testing.expectEqual(@as(usize, 6), viaDispatch.s_len);
            try testing.expectEqual([3]u16{ 1, 2, 3 }, viaDispatch.arr);
            try testing.expectEqual(@as(i64, -9), viaDispatch.c);
            // Fast for the little-endian encodings the set covers.
            try testing.expectEqual(order == .little, viaDispatch.fast);

            const viaRuntime = try readSample(.none, Decoded, data, {}, readDecoded);
            try testing.expect(!viaRuntime.fast);
            try testing.expectEqual(viaDispatch.c, viaRuntime.c);

            // A fast instance refuses a header that is not its own.
            const other: XcdrVersion = if (version == .xcdr1) .xcdr2 else .xcdr1;
            try testing.expectError(error.EncapsulationMismatch, Reader(.{ .version = other, .order = order }).init(data));
            const other_order: ByteOrder = if (order == .little) .big else .little;
            try testing.expectError(error.EncapsulationMismatch, Reader(.{ .version = version, .order = other_order }).init(data));
        }
    }
}

test "a fast reader checks bounds as the run-time one does" {
    var buf: [128]u8 = undefined;
    var w = Writer(.{ .version = .xcdr2, .order = .little, .output = .fixed }).initFixed(&buf, .xcdr2, .little);
    try writeSample(&w);
    const data = w.bytes();
    var n: usize = 4;
    while (n < data.len) : (n += 1) {
        try testing.expectError(error.EndOfStream, readSample(.all, Decoded, data[0..n], {}, readDecoded));
        try testing.expectError(error.EndOfStream, readSample(.none, Decoded, data[0..n], {}, readDecoded));
    }
    // A parameter list goes to the run-time reader, which knows PL_CDR.
    var pl: [16]u8 = undefined;
    var pw = Writer(.{ .version = .xcdr1, .order = .little, .output = .fixed }).initFixed(&pl, .xcdr1, .little);
    try pw.writePlEncapHeader();
    try pw.writePlSentinel();
    const PlRead = struct {
        fn read(r: anytype, _: void) !bool {
            return r.is_pl_cdr and @TypeOf(r.*).config.version == null and (try r.readPlParam(.strict)) == null;
        }
    };
    try testing.expect(try readSample(.all, bool, pw.bytes(), {}, PlRead.read));
    try testing.expectError(error.InvalidEncapsulation, readSample(.all, bool, &[_]u8{ 0xff, 0xff, 0, 0 }, {}, PlRead.read));
    try testing.expect(ReaderFor(.all, .xcdr2, .little) == Reader(.{ .version = .xcdr2, .order = .little }));
    try testing.expect(ReaderFor(.all, .xcdr2, .big) == CdrReader);
}
