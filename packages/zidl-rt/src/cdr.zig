//! CDR (Common Data Representation) writer and reader for zidl-rt.
//!
//! Implements OMG XCDR1 and XCDR2 encoding, little-endian output, per:
//!   - DDS-XTYPES spec formal-20-02-04 §7.3
//!   - RTPS spec formal-22-04-01 §9.6
//!
//! ## CdrWriter
//!
//! Comptime-parameterised on XCDR version; writes into a caller-owned
//! `std.ArrayListUnmanaged(u8)` buffer.  Using a concrete buffer type (rather
//! than a generic streaming writer) supports DHEADER patching for @appendable
//! and @mutable types — streaming writers cannot seek back to patch previously
//! written bytes.
//!
//!   ```zig
//!   var buf = std.ArrayListUnmanaged(u8).empty;
//!   defer buf.deinit(alloc);
//!   var w = CdrWriter(.xcdr2).init(&buf, alloc);
//!   try w.writeEncapHeader();
//!   try w.writeI32(42);
//!   // buf.items now contains the CDR stream
//!   ```
//!
//! Generated serialize functions use `anytype` duck-typing, so any CdrWriter
//! variant is accepted without code-gen changes:
//!   `pub fn serialize(writer: anytype, value: T) !void { ... }`
//!
//! ## CdrReader
//!
//! Runtime endianness and XCDR version, parsed from the encapsulation header:
//!
//!   ```zig
//!   var r = try CdrReader.init(cdr_bytes);
//!   const x = try r.readI32();
//!   ```
//!
//! Every read validates bounds; returns `error.EndOfStream` on truncation.

const fixed = @import("cdr_fixed.zig");
const std = @import("std");
const primitives = @import("cdr_primitives.zig");
const cursor = @import("cdr_cursor.zig");
const strings = @import("cdr_strings.zig");
const keys = @import("cdr_keys.zig");
const framing = @import("cdr_framing.zig");

// ── Encoding version and byte order ──────────────────────────────────────────

pub const XcdrVersion = framing.Version;

pub const ByteOrder = primitives.ByteOrder;

// ── Encapsulation identifier constants (written as big-endian u16) ────────────

/// XCDR1 little-endian encap ID → header bytes [0x00, 0x01, 0x00, 0x00]
pub const ENCAP_CDR1_LE: u16 = 0x0001;
/// XCDR1 big-endian encap ID → header bytes [0x00, 0x00, 0x00, 0x00]
pub const ENCAP_CDR1_BE: u16 = 0x0000;
/// XCDR2 little-endian encap ID → header bytes [0x00, 0x07, 0x00, 0x00]
pub const ENCAP_CDR2_LE: u16 = 0x0007;
/// XCDR2 big-endian encap ID → header bytes [0x00, 0x06, 0x00, 0x00]
pub const ENCAP_CDR2_BE: u16 = 0x0006;
/// XCDR2 Delimited CDR little-endian → header bytes [0x00, 0x09, 0x00, 0x00]
/// Used by RTI Connext DDS for @appendable types in XCDR2 mode.
/// Wire format is identical to CDR2_LE: DHEADER present, handled by skipDheaderIfXcdr2.
pub const ENCAP_DELIMITED_CDR2_LE: u16 = 0x0009;
/// XCDR2 Delimited CDR big-endian → header bytes [0x00, 0x08, 0x00, 0x00]
pub const ENCAP_DELIMITED_CDR2_BE: u16 = 0x0008;
/// XCDR2 ParameterList CDR little-endian → header bytes [0x00, 0x0b, 0x00, 0x00]
/// The XCDR2 representation of an @mutable top-level type (EMHEADER framing);
/// peers may reject a mutable sample under any other id.
pub const ENCAP_PL_CDR2_LE: u16 = 0x000b;
/// XCDR2 ParameterList CDR big-endian → header bytes [0x00, 0x0a, 0x00, 0x00]
pub const ENCAP_PL_CDR2_BE: u16 = 0x000a;
/// PL_CDR (XCDR1 ParameterList) little-endian → header bytes [0x00, 0x03, 0x00, 0x00]
pub const ENCAP_PL_CDR_LE: u16 = 0x0003;
/// PL_CDR (XCDR1 ParameterList) big-endian → header bytes [0x00, 0x02, 0x00, 0x00]
pub const ENCAP_PL_CDR_BE: u16 = 0x0002;

// ── BoundedArray ─────────────────────────────────────────────────────────────
//
// std.BoundedArray was removed in Zig 0.16.0.  We define a minimal
// compatible replacement here so generated code can use `zidl_rt.BoundedArray`.

/// A fixed-capacity array that tracks its own length.
/// Compatible with the std.BoundedArray API used by zidl-generated code.
pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        /// Initialize from a slice; returns error.Overflow if s.len > capacity.
        pub fn fromSlice(s: []const T) error{Overflow}!Self {
            if (s.len > capacity) return error.Overflow;
            var self = Self{};
            @memcpy(self.buf[0..s.len], s);
            self.len = s.len;
            return self;
        }

        /// Return a slice of the valid elements.
        pub fn slice(self: *const Self) []const T {
            return self.buf[0..self.len];
        }

        /// Return a mutable slice of the valid elements.
        pub fn sliceMut(self: *Self) []T {
            return self.buf[0..self.len];
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, new_capacity: usize) error{Overflow}!void {
            _ = allocator;
            if (new_capacity > capacity) return error.Overflow;
            _ = self;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.buf[self.len] = item;
            self.len += 1;
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.appendAssumeCapacity(item);
        }
    };
}

// ── CdrWriter ─────────────────────────────────────────────────────────────────

/// CDR writer, comptime-parameterised on XCDR version.
///
/// Writes into a caller-owned `std.ArrayListUnmanaged(u8)` buffer.  Always
/// emits little-endian bytes.  Tracks the running byte offset for CDR
/// alignment padding (padding bytes are zeros).
///
/// Alignment caps: XCDR1 → 8 bytes max; XCDR2 → 4 bytes max.
pub fn CdrWriter(comptime xcdr_version: XcdrVersion) type {
    return struct {
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        /// Running byte count; used only for CDR alignment arithmetic.
        pos: usize = 0,

        const Self = @This();

        pub fn init(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) Self {
            return .{ .buf = buf, .alloc = alloc };
        }

        // ── Internal helpers ──────────────────────────────────────────────

        /// Raw storage sink used by the shared primitive encoder.
        pub fn writeBytes(self: *Self, bytes: []const u8) !void {
            try self.buf.appendSlice(self.alloc, bytes);
            self.pos += bytes.len;
        }

        pub fn payloadPosition(self: *const Self) usize {
            return self.pos;
        }
        pub fn byteLen(self: *const Self) usize {
            return self.buf.items.len;
        }
        pub fn resetPayload(self: *Self) void {
            self.pos = 0;
        }

        pub fn beginOptionalMember(self: *Self, member_id: u28, mu: bool, present: bool) !?framing.OptionalWrite {
            if (xcdr_version == .xcdr2) {
                try self.writeBool(present);
                return null;
            }
            return try framing.beginOptional(self, member_id, mu);
        }

        pub fn cancelOptionalMember(self: *Self, token: ?framing.OptionalWrite) void {
            if (token) |t| self.pos = framing.optionalParentPosition(self.buf.items.len, t) catch return;
        }

        pub fn finishOptionalMember(self: *Self, token: ?framing.OptionalWrite) !void {
            defer self.cancelOptionalMember(token);
            if (token) |t| try framing.finishOptional(self.buf.items, self.buf.items.len, t, .little);
        }

        // ── Encapsulation header ──────────────────────────────────────────

        /// Emit the 4-byte CDR encapsulation header for this writer's XCDR
        /// version and little-endian byte order.  Use for @final top-level types
        /// (no DHEADER in XCDR2); use writeEncapHeaderDelimited for @appendable.
        ///
        /// The representation identifier is written big-endian (per RTPS spec),
        /// followed by two zero option bytes.
        pub fn writeEncapHeader(self: *Self) !void {
            try framing.writeEncapsulation(self, framing.encapsulationId(xcdr_version, .little, .final, false));
        }

        /// Like writeEncapHeader but uses ENCAP_PL_CDR2_LE (0x000b) for XCDR2, as
        /// required for @mutable top-level types. XCDR1 is unchanged (a
        /// ParameterList XCDR1 encoding is not generated).
        pub fn writeEncapHeaderMutable(self: *Self) !void {
            try framing.writeEncapsulation(self, framing.encapsulationId(xcdr_version, .little, .mutable, false));
        }

        /// Like writeEncapHeader but uses ENCAP_DELIMITED_CDR2_LE (0x0009) for XCDR2.
        /// Required for @appendable top-level types: signals that a DHEADER is present.
        /// XCDR1 behaviour is identical to writeEncapHeader.
        pub fn writeEncapHeaderDelimited(self: *Self) !void {
            try framing.writeEncapsulation(self, framing.encapsulationId(xcdr_version, .little, .appendable, false));
        }

        // ── Primitive writes ──────────────────────────────────────────────

        pub fn writeU8(self: *Self, v: u8) !void {
            try primitives.writeUnsigned(self, u8, v, self.pos, if (xcdr_version == .xcdr1) 8 else 4, .little);
        }

        pub fn writeI8(self: *Self, v: i8) !void {
            try self.writeU8(@bitCast(v));
        }

        pub fn writeBool(self: *Self, v: bool) !void {
            try self.writeU8(if (v) 1 else 0);
        }

        /// IDL `char` → one byte on the wire.
        pub fn writeChar(self: *Self, v: u8) !void {
            try self.writeU8(v);
        }

        /// IDL `wchar` → two bytes on the wire (same as writeU16).
        pub fn writeWchar(self: *Self, v: u16) !void {
            try self.writeU16(v);
        }

        pub fn writeU16(self: *Self, v: u16) !void {
            try primitives.writeUnsigned(self, u16, v, self.pos, if (xcdr_version == .xcdr1) 8 else 4, .little);
        }

        pub fn writeI16(self: *Self, v: i16) !void {
            try self.writeU16(@bitCast(v));
        }

        pub fn writeU32(self: *Self, v: u32) !void {
            try primitives.writeUnsigned(self, u32, v, self.pos, if (xcdr_version == .xcdr1) 8 else 4, .little);
        }

        pub fn writeI32(self: *Self, v: i32) !void {
            try self.writeU32(@bitCast(v));
        }

        pub fn writeF32(self: *Self, v: f32) !void {
            try self.writeU32(@bitCast(v));
        }

        pub fn writeU64(self: *Self, v: u64) !void {
            try primitives.writeUnsigned(self, u64, v, self.pos, if (xcdr_version == .xcdr1) 8 else 4, .little);
        }

        pub fn writeI64(self: *Self, v: i64) !void {
            try self.writeU64(@bitCast(v));
        }

        pub fn writeF64(self: *Self, v: f64) !void {
            try self.writeU64(@bitCast(v));
        }

        /// Write a `fixed<D,S>` value as packed BCD (alignment 1).
        /// N = (D/2)+1 bytes; sign nibble: 0xC positive/zero, 0xD negative.
        pub fn writeFixed(self: *Self, comptime D: u8, comptime S: u8, value: f64) !void {
            comptime if (D < 1 or D > 31) @compileError("fixed<D,S>: D must be 1..31");
            comptime if (S > D) @compileError("fixed<D,S>: S must be <= D");
            try fixed.write(self, D, S, value);
        }

        // ── String / wstring writes ───────────────────────────────────────

        /// CDR string: u32 length (byte count including NUL), then the chars,
        /// then a NUL byte.
        pub fn writeString(self: *Self, v: []const u8) !void {
            try strings.writeString(self, v);
        }

        /// The same UTF-16 byte representation used by canonical key holders.
        pub fn writeKeyWstring(self: *Self, v: []const u16) !void {
            try keys.writeWstring(self, v);
        }

        /// CDR wstring: u32 byte count, then UTF-16 units; no NUL/BOM.
        pub fn writeWstring(self: *Self, v: []const u16) !void {
            try strings.writeWstring(self, v);
        }

        // ── XCDR2 framing ─────────────────────────────────────────────────

        /// Write a DHEADER (u32 byte count of the payload that follows).
        ///
        /// XCDR2 §7.3.3.2: required before every @appendable or @mutable type.
        /// Caller provides the payload size in advance.  For @final types,
        /// DHEADER is not emitted.
        pub fn writeDheader(self: *Self, payload_size: u32) !void {
            try self.writeU32(payload_size);
        }

        /// Reserve a DHEADER slot (writes placeholder 0) and return the buffer
        /// offset so the caller can patch it after writing the payload.
        ///
        /// Usage:
        ///   ```zig
        ///   const dh = try w.reserveDheader();
        ///   // ... write payload ...
        ///   w.patchDheader(dh);
        ///   ```
        pub fn reserveDheader(self: *Self) !usize {
            var offset: usize = undefined;
            try framing.reserveDheader(self, &offset);
            return offset;
        }

        /// Patch a previously reserved DHEADER with the byte count of everything
        /// written after the 4-byte DHEADER field at `dheader_offset`.
        pub fn patchDheader(self: *Self, dheader_offset: usize) void {
            self.patchDheaderChecked(dheader_offset) catch {};
        }

        pub fn patchDheaderChecked(self: *Self, offset: usize) !void {
            try framing.patchDheader(self.buf.items, self.buf.items.len, offset, .little);
        }

        /// For generated @appendable/@mutable types: reserve a DHEADER on XCDR2,
        /// return null on XCDR1 (no DHEADER in XCDR1).
        pub fn reserveDheaderMaybe(self: *Self) !?usize {
            if (xcdr_version == .xcdr1) return null;
            return try self.reserveDheader();
        }

        /// Patch a DHEADER reserved by reserveDheaderMaybe.  No-op when null.
        pub fn patchDheaderMaybeChecked(self: *Self, offset: ?usize) !void {
            if (offset) |off| try self.patchDheaderChecked(off);
        }

        pub fn patchDheaderMaybe(self: *Self, offset: ?usize) void {
            if (offset) |off| self.patchDheader(off);
        }

        // ── EMHEADER (for @mutable types) ────────────────────────────────────

        /// Returned by reserveEmheader; passed to patchEmheader.
        pub const EmheaderPlaceholder = struct {
            /// Offset in buf of the NEXTINT word (4 bytes reserved for payload size).
            nextint_offset: usize,
            /// buf.items.len right after the NEXTINT was written; first byte of payload.
            payload_start: usize,
        };

        /// Write a fixed-size EMHEADER for a member whose payload is exactly
        /// 1, 2, 4, or 8 bytes (LC 0–3).  No NEXTINT is written.
        ///
        /// LC values: 0 → 1 byte, 1 → 2 bytes, 2 → 4 bytes, 3 → 8 bytes.
        pub fn writeEmheaderFixed(self: *Self, member_id: u28, must_understand: bool, lc: u2) !void {
            try framing.writeEmheader(self, member_id, must_understand, lc);
        }

        /// Reserve an EMHEADER + NEXTINT placeholder for a variable-length member
        /// (LC=4: NEXTINT = byte count).  Call patchEmheader after writing the payload.
        pub fn reserveEmheader(self: *Self, member_id: u28, must_understand: bool) !EmheaderPlaceholder {
            var offset: usize = undefined;
            try framing.reserveEmheader(self, member_id, must_understand, &offset);
            return .{ .nextint_offset = offset, .payload_start = self.byteLen() };
        }

        /// Patch the NEXTINT of a reserved EMHEADER with the actual payload byte count.
        pub fn patchEmheader(self: *Self, ph: EmheaderPlaceholder) void {
            self.patchEmheaderChecked(ph) catch {};
        }

        pub fn patchEmheaderChecked(self: *Self, ph: EmheaderPlaceholder) !void {
            try framing.patchEmheader(self.buf.items, self.buf.items.len, ph.nextint_offset, ph.payload_start, .little);
        }
    };
}

// ── KeyHashWriter ────────────────────────────────────────────────────────────

/// Canonical RTPS key-hash writer.
///
/// RTPS §9.6.4.8 computes PID_KEY_HASH from the key fields serialized as
/// PLAIN_CDR2 big-endian.  This writer implements the same duck-typed write
/// API used by generated `serializeKey` methods, but it does not store the
/// whole stream.  It keeps the first 16 bytes and streams every byte into MD5.
pub const KeyHashWriter = struct {
    first16: [16]u8 = @splat(0),
    len: usize = 0,
    pos: usize = 0,
    md5: std.crypto.hash.Md5 = std.crypto.hash.Md5.init(.{}),

    pub fn init() KeyHashWriter {
        return .{};
    }

    pub fn writeBytes(self: *KeyHashWriter, bytes: []const u8) !void {
        if (bytes.len > std.math.maxInt(usize) - self.len or bytes.len > std.math.maxInt(usize) - self.pos) return error.Overflow;
        const dst_start = @min(self.len, self.first16.len);
        const dst_avail = self.first16.len - dst_start;
        const copy_len = @min(dst_avail, bytes.len);
        if (copy_len > 0) {
            @memcpy(self.first16[dst_start..][0..copy_len], bytes[0..copy_len]);
        }
        self.md5.update(bytes);
        self.len += bytes.len;
        self.pos += bytes.len;
    }

    fn writePad(self: *KeyHashWriter, boundary: usize) !void {
        const rem = self.pos % boundary;
        if (rem == 0) return;
        const pad = boundary - rem;
        const z: [4]u8 = @splat(0);
        try self.writeBytes(z[0..pad]);
    }

    inline fn align_(wire_size: usize) usize {
        return @min(wire_size, 4); // PLAIN_CDR2 caps primitive alignment at 4.
    }

    pub fn writeU8(self: *KeyHashWriter, v: u8) !void {
        try self.writeBytes(&[_]u8{v});
    }

    pub fn writeI8(self: *KeyHashWriter, v: i8) !void {
        try self.writeU8(@bitCast(v));
    }

    pub fn writeBool(self: *KeyHashWriter, v: bool) !void {
        try self.writeU8(if (v) 1 else 0);
    }

    pub fn writeChar(self: *KeyHashWriter, v: u8) !void {
        try self.writeU8(v);
    }

    pub fn writeWchar(self: *KeyHashWriter, v: u16) !void {
        try self.writeU16(v);
    }

    pub fn writeU16(self: *KeyHashWriter, v: u16) !void {
        try self.writePad(align_(2));
        try self.writeBytes(&[_]u8{ @truncate(v >> 8), @truncate(v) });
    }

    pub fn writeI16(self: *KeyHashWriter, v: i16) !void {
        try self.writeU16(@bitCast(v));
    }

    pub fn writeU32(self: *KeyHashWriter, v: u32) !void {
        try self.writePad(align_(4));
        try self.writeBytes(&[_]u8{
            @truncate(v >> 24),
            @truncate(v >> 16),
            @truncate(v >> 8),
            @truncate(v),
        });
    }

    pub fn writeI32(self: *KeyHashWriter, v: i32) !void {
        try self.writeU32(@bitCast(v));
    }

    pub fn writeF32(self: *KeyHashWriter, v: f32) !void {
        try self.writeU32(@bitCast(v));
    }

    pub fn writeU64(self: *KeyHashWriter, v: u64) !void {
        try self.writePad(align_(8));
        try self.writeBytes(&[_]u8{
            @truncate(v >> 56),
            @truncate(v >> 48),
            @truncate(v >> 40),
            @truncate(v >> 32),
            @truncate(v >> 24),
            @truncate(v >> 16),
            @truncate(v >> 8),
            @truncate(v),
        });
    }

    pub fn writeI64(self: *KeyHashWriter, v: i64) !void {
        try self.writeU64(@bitCast(v));
    }

    pub fn writeF64(self: *KeyHashWriter, v: f64) !void {
        try self.writeU64(@bitCast(v));
    }

    pub fn writeFixed(self: *KeyHashWriter, comptime D: u8, comptime S: u8, value: f64) !void {
        comptime if (D < 1 or D > 31) @compileError("fixed<D,S>: D must be 1..31");
        comptime if (S > D) @compileError("fixed<D,S>: S must be <= D");
        try fixed.write(self, D, S, value);
    }

    pub fn writeString(self: *KeyHashWriter, v: []const u8) !void {
        try strings.writeString(self, v);
    }

    pub fn writeWstring(self: *KeyHashWriter, v: []const u16) !void {
        try keys.writeWstring(self, v);
    }

    pub fn writeKeyWstring(self: *KeyHashWriter, v: []const u16) !void {
        try keys.writeWstring(self, v);
    }

    /// No-op: key hash spec (RTPS §9.6.4.8) excludes the DHEADER from the
    /// hash computation even for @appendable types.
    pub fn reserveDheaderMaybe(self: *KeyHashWriter) !?usize {
        _ = self;
        return null;
    }

    /// No-op counterpart to reserveDheaderMaybe.
    pub fn patchDheaderMaybeChecked(self: *KeyHashWriter, offset: ?usize) !void {
        self.patchDheaderMaybe(offset);
    }

    pub fn patchDheaderMaybe(self: *KeyHashWriter, offset: ?usize) void {
        _ = self;
        _ = offset;
    }

    pub fn final(self: *KeyHashWriter) [16]u8 {
        return self.finalForType(false);
    }

    pub fn finalForType(self: *KeyHashWriter, force_md5: bool) [16]u8 {
        if (!keys.useMd5(force_md5, self.len)) return self.first16;
        var digest: [16]u8 = undefined;
        self.md5.final(&digest);
        return digest;
    }
};

// ── PlCdrWriter ───────────────────────────────────────────────────────────────

/// PL_CDR (ParameterList CDR) writer for RTPS discovery types.
///
/// Wraps `CdrWriter(.xcdr1)` but emits a PL_CDR_LE encapsulation header.
/// Each member is framed with a 4-byte `(pid: u16 LE, len: u16 LE)` header
/// followed by the CDR-encoded value padded to a multiple of 4 bytes.
/// The stream ends with a `PID_SENTINEL (0x0001, 0)` word.
///
/// Alignment is XCDR1 (max 8 bytes), continuous across the entire payload.
pub const PlCdrWriter = struct {
    inner: CdrWriter(.xcdr1),

    pub fn init(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) PlCdrWriter {
        return .{ .inner = CdrWriter(.xcdr1).init(buf, alloc) };
    }

    /// Write the 4-byte PL_CDR_LE encapsulation header.
    /// Must be the first call; resets CDR position to 0.
    pub fn writeEncapHeader(self: *PlCdrWriter) !void {
        try framing.writeEncapsulation(&self.inner, ENCAP_PL_CDR_LE);
    }

    /// Handle returned by `reservePlParam`; pass to `patchPlParam` after writing value.
    pub const PlParamHandle = struct {
        /// Offset of the u16 length field in `buf`.
        len_offset: usize,
        /// Offset of the first value byte in `buf`.
        buf_value_start: usize,
    };

    /// Write the `(pid, 0)` header placeholder and return a handle.
    /// Write the member value after this call, then call `patchPlParam`.
    pub fn reservePlParam(self: *PlCdrWriter, pid: u16) !PlParamHandle {
        var handle: PlParamHandle = undefined;
        try framing.reserveParameter(&self.inner, pid, &handle.len_offset, &handle.buf_value_start);
        return handle;
    }

    /// Pad the current value to a 4-byte boundary and patch the length field.
    pub fn patchPlParam(self: *PlCdrWriter, h: PlParamHandle) !void {
        try framing.validateParameter(self.inner.byteLen(), h.len_offset, h.buf_value_start);
        const raw = self.inner.byteLen() - h.buf_value_start;
        const padded = try framing.parameterSize(raw);
        const zeros: [4]u8 = @splat(0);
        if (padded > raw) try self.inner.writeBytes(zeros[0 .. padded - raw]);
        try framing.patchParameter(self.inner.buf.items, self.inner.byteLen(), h.len_offset, h.buf_value_start);
    }

    /// Write the PID_SENTINEL (0x0001, 0) to terminate the parameter list.
    /// PL_CDR is XCDR1-framed: no DHEADERs (for collections or aggregates)
    /// inside parameter values.
    pub fn reserveDheaderMaybe(self: *PlCdrWriter) !?usize {
        _ = self;
        return null;
    }

    /// No-op counterpart to reserveDheaderMaybe.
    pub fn patchDheaderMaybeChecked(self: *PlCdrWriter, offset: ?usize) !void {
        self.patchDheaderMaybe(offset);
    }

    pub fn patchDheaderMaybe(self: *PlCdrWriter, offset: ?usize) void {
        _ = self;
        _ = offset;
    }

    pub fn writePlSentinel(self: *PlCdrWriter) !void {
        try framing.writeSentinel(&self.inner);
    }

    /// Re-emit a parameter retained verbatim (`zidl_rt.RawParam`): the raw `pid`
    /// (flag bits included) and its value bytes, re-padded to a 4-byte boundary.
    /// Used by a `@pl_retain_unknown` type's generated `serializePlCdr` to
    /// replay unknown parameters before the sentinel.
    pub fn writeRawParam(self: *PlCdrWriter, pid: u16, value: []const u8) !void {
        const h = try self.reservePlParam(pid);
        try self.inner.writeBytes(value);
        try self.patchPlParam(h);
    }

    /// Return the raw bytes written so far (including encap header).
    pub fn bytes(self: *const PlCdrWriter) []const u8 {
        return self.inner.buf.items;
    }

    // ── Forwarded primitive writes ─────────────────────────────────────────
    /// Append raw bytes at the current position (no length prefix, no padding).
    pub fn writeBytes(self: *PlCdrWriter, data: []const u8) !void {
        try self.inner.writeBytes(data);
    }
    pub fn writeU8(self: *PlCdrWriter, v: u8) !void {
        try self.inner.writeU8(v);
    }
    pub fn writeI8(self: *PlCdrWriter, v: i8) !void {
        try self.inner.writeI8(v);
    }
    pub fn writeBool(self: *PlCdrWriter, v: bool) !void {
        try self.inner.writeBool(v);
    }
    pub fn writeChar(self: *PlCdrWriter, v: u8) !void {
        try self.inner.writeChar(v);
    }
    pub fn writeWchar(self: *PlCdrWriter, v: u16) !void {
        try self.inner.writeWchar(v);
    }
    pub fn writeU16(self: *PlCdrWriter, v: u16) !void {
        try self.inner.writeU16(v);
    }
    pub fn writeI16(self: *PlCdrWriter, v: i16) !void {
        try self.inner.writeI16(v);
    }
    pub fn writeU32(self: *PlCdrWriter, v: u32) !void {
        try self.inner.writeU32(v);
    }
    pub fn writeI32(self: *PlCdrWriter, v: i32) !void {
        try self.inner.writeI32(v);
    }
    pub fn writeF32(self: *PlCdrWriter, v: f32) !void {
        try self.inner.writeF32(v);
    }
    pub fn writeU64(self: *PlCdrWriter, v: u64) !void {
        try self.inner.writeU64(v);
    }
    pub fn writeI64(self: *PlCdrWriter, v: i64) !void {
        try self.inner.writeI64(v);
    }
    pub fn writeF64(self: *PlCdrWriter, v: f64) !void {
        try self.inner.writeF64(v);
    }
    pub fn writeFixed(self: *PlCdrWriter, comptime D: u8, comptime S: u8, v: f64) !void {
        try self.inner.writeFixed(D, S, v);
    }
    pub fn writeString(self: *PlCdrWriter, v: []const u8) !void {
        try self.inner.writeString(v);
    }
    pub fn writeWstring(self: *PlCdrWriter, v: []const u16) !void {
        try self.inner.writeWstring(v);
    }
};

// ── CdrReader ─────────────────────────────────────────────────────────────────

/// CDR reader with runtime endianness and XCDR version.
///
/// Constructed by parsing the 4-byte encapsulation header.  Subsequent reads
/// apply CDR alignment padding and byte-swap for big-endian streams.
///
/// All reads validate that enough bytes remain; `error.EndOfStream` is returned
/// on any truncation.
pub const CdrReader = struct {
    data: []const u8,
    /// Current read position.  Starts at 4 (after the 4-byte encap header).
    pos: usize,
    byte_order: ByteOrder,
    xcdr_version: XcdrVersion,
    /// True when the stream uses PL_CDR (ParameterList) framing.
    /// xcdr_version is .xcdr1 for PL_CDR; this flag distinguishes PL_CDR from plain XCDR1.
    is_pl_cdr: bool,

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
    pub fn init(data: []const u8) !CdrReader {
        const encap = try framing.parseEncapsulation(data);
        return .{ .data = data, .pos = 4, .byte_order = encap.order, .xcdr_version = encap.version, .is_pl_cdr = encap.is_pl_cdr };
    }

    /// Stack-copy a reader with an explicit absolute end; alignment origin stays 4.
    pub fn limited(self: *const CdrReader, end: usize) !CdrReader {
        try framing.validateLimit(self.pos, self.data.len, end);
        var out = self.*;
        out.data = self.data[0..end];
        return out;
    }

    /// A caller-owned stack window. Close after cancel's errdefer: errors keep
    /// the consumed cursor, while success skips the remainder of this frame.
    pub const Window = struct {
        reader: *CdrReader,
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
    pub fn window(self: *CdrReader, end: usize) !Window {
        const bounded = try self.limited(end);
        const scope = Window{ .reader = self, .saved_data = self.data, .end = end };
        self.* = bounded;
        return scope;
    }

    pub const OptionalScope = struct {
        reader: *CdrReader,
        parent: CdrReader,
        framed: bool,
        present: bool,

        pub fn close(self: *OptionalScope) void {
            const pos = self.reader.pos;
            self.reader.* = self.parent;
            if (!self.framed) self.reader.pos = pos;
        }
    };

    /// Close on success and failure before closing any enclosing frame.
    pub fn beginOptionalMember(self: *CdrReader, member_id: u28) !OptionalScope {
        if (self.xcdr_version == .xcdr2) {
            const present = try self.readBool();
            return .{ .reader = self, .parent = self.*, .framed = false, .present = present };
        }
        const span = try framing.readOptional(self.data, &self.pos, member_id, self.byte_order);
        var parent = self.*;
        parent.pos = span.end;
        self.data = self.data[span.start - 4 .. span.end];
        self.pos = 4;
        return .{ .reader = self, .parent = parent, .framed = true, .present = span.start != span.end };
    }

    // ── Internal helpers ──────────────────────────────────────────────────

    fn readSlice(self: *CdrReader, n: usize) ![]const u8 {
        return cursor.readSlice(self.data, &self.pos, n);
    }

    // ── Status ────────────────────────────────────────────────────────────

    pub fn remaining(self: *const CdrReader) usize {
        return if (self.pos < self.data.len) self.data.len - self.pos else 0;
    }

    pub fn skip(self: *CdrReader, n: usize) !void {
        _ = try cursor.advance(&self.pos, self.data.len, n);
    }

    /// Skip a run of `count` fixed-size primitive elements of `elem_wire_size`
    /// bytes each (a `sequence<primitive>` body or a primitive array) without
    /// touching the bytes -- aligns to the element boundary, then advances the
    /// cursor by `count * elem_wire_size` in one step. `elem_wire_size` must be
    /// 1/2/4/8. The caller has already consumed any length prefix.
    pub fn skipPrimitives(self: *CdrReader, count: usize, elem_wire_size: usize) !void {
        try cursor.skipPrimitives(&self.pos, self.data.len, 4, count, elem_wire_size, if (self.xcdr_version == .xcdr1) 8 else 4);
    }

    // ── Primitive reads ───────────────────────────────────────────────────

    pub fn readU8(self: *CdrReader) !u8 {
        return primitives.readUnsigned(u8, self.data, &self.pos, 4, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
    }

    pub fn readI8(self: *CdrReader) !i8 {
        return @bitCast(try self.readU8());
    }

    pub fn readBool(self: *CdrReader) !bool {
        return primitives.readBool(self.data, &self.pos);
    }

    pub fn readChar(self: *CdrReader) !u8 {
        return self.readU8();
    }

    pub fn readWchar(self: *CdrReader) !u16 {
        return self.readU16();
    }

    pub fn readU16(self: *CdrReader) !u16 {
        return primitives.readUnsigned(u16, self.data, &self.pos, 4, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
    }

    pub fn readI16(self: *CdrReader) !i16 {
        return @bitCast(try self.readU16());
    }

    pub fn readU32(self: *CdrReader) !u32 {
        return primitives.readUnsigned(u32, self.data, &self.pos, 4, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
    }

    pub fn readI32(self: *CdrReader) !i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readF32(self: *CdrReader) !f32 {
        return @bitCast(try self.readU32());
    }

    pub fn readU64(self: *CdrReader) !u64 {
        return primitives.readUnsigned(u64, self.data, &self.pos, 4, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
    }

    pub fn readI64(self: *CdrReader) !i64 {
        return @bitCast(try self.readU64());
    }

    pub fn readF64(self: *CdrReader) !f64 {
        return @bitCast(try self.readU64());
    }

    /// Read a `fixed<D,S>` value from packed BCD (alignment 1).
    pub fn readFixed(self: *CdrReader, comptime D: u8, comptime S: u8) !f64 {
        comptime if (D < 1 or D > 31) @compileError("fixed<D,S>: D must be 1..31");
        comptime if (S > D) @compileError("fixed<D,S>: S must be <= D");
        return fixed.read(self.data, &self.pos, D, S);
    }

    // ── String / wstring reads ────────────────────────────────────────────

    /// Zero-copy string read: returns a slice pointing into the CDR buffer.
    ///
    /// The slice is valid as long as the buffer passed to `init` stays alive.
    /// Suitable for the DataReader loan pattern (no per-message allocation).
    pub fn readStringZeroCopy(self: *CdrReader) ![]const u8 {
        return strings.readString(self.data, &self.pos, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
    }

    pub fn skipString(self: *CdrReader) !void {
        _ = try self.readStringZeroCopy();
    }

    /// Owned content excludes the terminator; free with the supplied allocator.
    pub fn readString(self: *CdrReader, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, try self.readStringZeroCopy());
    }

    /// Validate the entire wire span before allocating owned host-order units.
    /// The returned slice excludes the terminator and can contain embedded NULs.
    pub fn readWstring(self: *CdrReader, allocator: std.mem.Allocator) ![]u16 {
        const view = try strings.readWstring(self.data, &self.pos, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
        const out = try allocator.alloc(u16, view.len());
        for (out, 0..) |*wc, i| wc.* = view.codeUnit(i);
        return out;
    }

    pub fn skipWstring(self: *CdrReader) !void {
        _ = try strings.readWstring(self.data, &self.pos, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
    }

    // ── XCDR2 framing ─────────────────────────────────────────────────────

    /// Read and return a DHEADER value (byte count of the following payload).
    pub fn readDheader(self: *CdrReader) !u32 {
        return self.readU32();
    }

    /// For generated @appendable/@mutable types: skip the DHEADER on XCDR2,
    /// no-op on XCDR1 (no DHEADER in XCDR1).
    pub fn skipDheaderIfXcdr2(self: *CdrReader) !void {
        if (self.xcdr_version == .xcdr2) _ = try self.readMutableDheader();
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
    pub fn readEmheader(self: *CdrReader) !EmHeader {
        return framing.readEmheader(self.data, &self.pos, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
    }

    pub fn readMutableDheader(self: *CdrReader) !usize {
        return framing.readDheaderEnd(self.data, &self.pos, if (self.xcdr_version == .xcdr1) 8 else 4, self.byte_order);
    }

    pub fn mutableHasMore(self: *const CdrReader, end_pos: usize) bool {
        return end_pos <= self.data.len and self.pos < end_pos;
    }

    pub fn emheaderEnd(self: *const CdrReader, emh: EmHeader) !usize {
        return framing.memberEnd(self.pos, self.data.len, if (self.xcdr_version == .xcdr1) 8 else 4, emh.lc, emh.payload_bytes);
    }

    pub fn skipEmheaderPayload(self: *CdrReader, emh: EmHeader) !void {
        try framing.skipMember(&self.pos, self.data.len, if (self.xcdr_version == .xcdr1) 8 else 4, emh.lc, emh.payload_bytes);
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
    pub fn readPlParam(self: *CdrReader, mode: PlMode) !?PlParam {
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
    pub fn seekTo(self: *CdrReader, abs_pos: usize) !void {
        try cursor.seek(&self.pos, self.data.len, abs_pos);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkWriter(comptime xver: XcdrVersion, buf: *std.ArrayListUnmanaged(u8)) CdrWriter(xver) {
    return CdrWriter(xver).init(buf, testing.allocator);
}

test "key hash writer: <=16 bytes are padded canonical CDR2 big-endian" {
    var w = KeyHashWriter.init();
    try w.writeI32(0x01020304);
    const got = w.final();
    try testing.expectEqualSlices(u8, &[_]u8{
        0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    }, &got);
}

test "key hash writer: CDR2 big-endian alignment" {
    var w = KeyHashWriter.init();
    try w.writeU8(0x12);
    try w.writeU32(0x01020304);
    const got = w.final();
    try testing.expectEqualSlices(u8, &[_]u8{
        0x12, 0x00, 0x00, 0x00,
        0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    }, &got);
}

test "key hash writer: >16 bytes returns MD5" {
    const s = "abcdefghijklmnop";
    var w = KeyHashWriter.init();
    try w.writeString(s);

    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x11 });
    try bytes.appendSlice(testing.allocator, s);
    try bytes.append(testing.allocator, 0);

    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(bytes.items);
    var expected: [16]u8 = undefined;
    md5.final(&expected);

    const got = w.final();
    try testing.expectEqualSlices(u8, &expected, &got);
}

// ── Encapsulation header ──────────────────────────────────────────────────────

test "encap header: xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00 }, buf.items);
}

test "encap header: xcdr1 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }, buf.items);
}

test "encap header delimited: xcdr2 le emits 0x0009" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeaderDelimited();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x09, 0x00, 0x00 }, buf.items);
}

test "encap header delimited: xcdr1 le emits same as writeEncapHeader" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeaderDelimited();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }, buf.items);
}

test "reader init: rejects unknown encap id" {
    const bad = [_]u8{ 0xFF, 0xFF, 0x00, 0x00 };
    try testing.expectError(error.InvalidEncapsulation, CdrReader.init(&bad));
}

test "reader init: rejects too-short data" {
    try testing.expectError(error.InvalidEncapsulation, CdrReader.init(&[_]u8{0x00}));
}

// ── Primitive roundtrips (XCDR2 LE) ──────────────────────────────────────────

fn writeAndRead(
    comptime T: type,
    value: T,
    comptime writeFn: fn (*CdrWriter(.xcdr2), T) anyerror!void,
    comptime readFn: fn (*CdrReader) anyerror!T,
) !void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try writeFn(&w, value);
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(value, try readFn(&r));
}

test "roundtrip: u8" {
    try writeAndRead(u8, 0xAB, struct {
        fn f(w: *CdrWriter(.xcdr2), v: u8) !void {
            try w.writeU8(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !u8 {
            return r.readU8();
        }
    }.f);
}
test "roundtrip: i8" {
    try writeAndRead(i8, -42, struct {
        fn f(w: *CdrWriter(.xcdr2), v: i8) !void {
            try w.writeI8(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !i8 {
            return r.readI8();
        }
    }.f);
}
test "roundtrip: bool true" {
    try writeAndRead(bool, true, struct {
        fn f(w: *CdrWriter(.xcdr2), v: bool) !void {
            try w.writeBool(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !bool {
            return r.readBool();
        }
    }.f);
}
test "roundtrip: bool false" {
    try writeAndRead(bool, false, struct {
        fn f(w: *CdrWriter(.xcdr2), v: bool) !void {
            try w.writeBool(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !bool {
            return r.readBool();
        }
    }.f);
}
test "roundtrip: u16" {
    try writeAndRead(u16, 0x1234, struct {
        fn f(w: *CdrWriter(.xcdr2), v: u16) !void {
            try w.writeU16(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !u16 {
            return r.readU16();
        }
    }.f);
}
test "roundtrip: i16" {
    try writeAndRead(i16, -1000, struct {
        fn f(w: *CdrWriter(.xcdr2), v: i16) !void {
            try w.writeI16(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !i16 {
            return r.readI16();
        }
    }.f);
}
test "roundtrip: u32" {
    try writeAndRead(u32, 0xDEAD_BEEF, struct {
        fn f(w: *CdrWriter(.xcdr2), v: u32) !void {
            try w.writeU32(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !u32 {
            return r.readU32();
        }
    }.f);
}
test "roundtrip: i32" {
    try writeAndRead(i32, -2_000_000, struct {
        fn f(w: *CdrWriter(.xcdr2), v: i32) !void {
            try w.writeI32(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !i32 {
            return r.readI32();
        }
    }.f);
}
test "roundtrip: f32" {
    try writeAndRead(f32, 3.14, struct {
        fn f(w: *CdrWriter(.xcdr2), v: f32) !void {
            try w.writeF32(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !f32 {
            return r.readF32();
        }
    }.f);
}
test "roundtrip: u64" {
    try writeAndRead(u64, 0xCAFE_BABE_DEAD_BEEF, struct {
        fn f(w: *CdrWriter(.xcdr2), v: u64) !void {
            try w.writeU64(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !u64 {
            return r.readU64();
        }
    }.f);
}
test "roundtrip: i64" {
    try writeAndRead(i64, -9_000_000_000, struct {
        fn f(w: *CdrWriter(.xcdr2), v: i64) !void {
            try w.writeI64(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !i64 {
            return r.readI64();
        }
    }.f);
}
test "roundtrip: f64" {
    try writeAndRead(f64, 2.718281828, struct {
        fn f(w: *CdrWriter(.xcdr2), v: f64) !void {
            try w.writeF64(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !f64 {
            return r.readF64();
        }
    }.f);
}

test "reader: invalid bool byte" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeU8(2); // invalid — CDR bool must be 0 or 1
    var r = try CdrReader.init(buf.items);
    try testing.expectError(error.InvalidBool, r.readBool());
}

// ── Alignment ─────────────────────────────────────────────────────────────────

test "alignment: xcdr2 u8 then u32 has 3-byte pad" {
    // CDR pos after u8 = 1; xcdr2 u32 needs align-4: pad 3 → CDR pos=4; +4=8.
    // buf.len = 4 (encap) + 1 (u8) + 3 (pad) + 4 (u32) = 12.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU8(0xAA); // CDR pos=1
    try w.writeU32(0x12345678); // xcdr2: align-4, pad 3 → CDR pos=4; +4=8
    try testing.expectEqual(@as(usize, 12), buf.items.len);
    try testing.expectEqual(@as(u8, 0xAA), buf.items[4]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[5]); // pad
    try testing.expectEqual(@as(u8, 0x00), buf.items[6]); // pad
    try testing.expectEqual(@as(u8, 0x00), buf.items[7]); // pad
    try testing.expectEqual(@as(u8, 0x78), buf.items[8]);
    try testing.expectEqual(@as(u8, 0x56), buf.items[9]);
    try testing.expectEqual(@as(u8, 0x34), buf.items[10]);
    try testing.expectEqual(@as(u8, 0x12), buf.items[11]);
}

test "alignment: xcdr2 u64 capped at 4" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader(); // pos=4
    try w.writeU8(0x01); // pos=5
    try w.writeU64(1); // xcdr2: cap=4 → align=min(8,4)=4 → CDR pos=1 mod 4=1, pad 3 → CDR pos=4, +8=12
    try testing.expectEqual(@as(usize, 16), buf.items.len);
}

test "alignment: xcdr1 u64 after u8 uses 8-byte alignment" {
    // CDR pos after u8 = 1; xcdr1 u64 needs align-8: pad 7 → CDR pos=8, +8=16.
    // buf.len = 4 (encap) + 1 (u8) + 7 (pad) + 8 (u64) = 20.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU8(0x01); // CDR pos=1
    try w.writeU64(1); // xcdr1: cap=8 → align to 8 → CDR pos=8, +8→16
    try testing.expectEqual(@as(usize, 20), buf.items.len);
}

test "alignment: xcdr1 u64 after u32 pads to 8" {
    // CDR pos: u32(4) + u8(1) = 5; xcdr1 u64 needs align-8: pad 3 → CDR pos=8, +8=16.
    // buf.len = 4 (encap) + 4 (u32) + 1 (u8) + 3 (pad) + 8 (u64) = 20.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU32(0); // CDR pos=4
    try w.writeU8(0x01); // CDR pos=5
    try w.writeU64(1); // xcdr1: align to 8 → pad 3 → CDR pos=8, +8=16
    try testing.expectEqual(@as(usize, 20), buf.items.len);
}

// ── Known byte sequences ──────────────────────────────────────────────────────

test "known bytes: i32(1) xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeI32(1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }, buf.items);
}

test "known bytes: i32(-1) xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeI32(-1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF }, buf.items);
}

// ── String ────────────────────────────────────────────────────────────────────

test "string: known bytes for 'hi'" {
    // "hi": len=3 (2+NUL), then [h i 0x00]
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeString("hi");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 'h', 'i', 0x00 }, buf.items);
}

test "string: roundtrip zero-copy" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeString("hello");
    var r = try CdrReader.init(buf.items);
    try testing.expectEqualStrings("hello", try r.readStringZeroCopy());
}

test "string: empty roundtrip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeString("");
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(usize, 0), (try r.readStringZeroCopy()).len);
}

test "string: allocating read matches zero-copy" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeString("test");
    var r1 = try CdrReader.init(buf.items);
    const zc = try r1.readStringZeroCopy();
    var r2 = try CdrReader.init(buf.items);
    const owned = try r2.readString(testing.allocator);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings(zc, owned);
}

// ── Wstring ───────────────────────────────────────────────────────────────────

test "wstring: roundtrip" {
    const wstr = [_]u16{ 'h', 'i' };
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeWstring(&wstr);
    var r = try CdrReader.init(buf.items);
    const got = try r.readWstring(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u16, &wstr, got);
}

// ── Big-endian reader ─────────────────────────────────────────────────────────

test "reader: xcdr2 big-endian i32(1)" {
    // XCDR2 BE encap = [00 06 00 00]; big-endian i32(1) = [00 00 00 01]
    const data = [_]u8{ 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    var r = try CdrReader.init(&data);
    try testing.expectEqual(ByteOrder.big, r.byte_order);
    try testing.expectEqual(@as(i32, 1), try r.readI32());
}

test "reader: xcdr1 big-endian u16(0x1234)" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x12, 0x34 };
    var r = try CdrReader.init(&data);
    try testing.expectEqual(@as(u16, 0x1234), try r.readU16());
}

// ── Error cases ───────────────────────────────────────────────────────────────

test "EndOfStream on truncated u32" {
    const data = [_]u8{ 0x00, 0x07, 0x00, 0x00, 0xAA }; // only 1 byte after header
    var r = try CdrReader.init(&data);
    try testing.expectError(error.EndOfStream, r.readU32());
}

// ── DHEADER ───────────────────────────────────────────────────────────────────

test "dheader: writeDheader and readDheader" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeDheader(42);
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(u32, 42), try r.readDheader());
}

test "dheader: reserveDheader and patchDheader" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const dh = try w.reserveDheader();
    try w.writeI32(10); // 4 bytes of payload
    try w.writeI32(20); // 4 bytes
    w.patchDheader(dh);
    // DHEADER should now be 8 (two i32s)
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(u32, 8), try r.readDheader());
    try testing.expectEqual(@as(i32, 10), try r.readI32());
    try testing.expectEqual(@as(i32, 20), try r.readI32());
}

// ── EMHEADER ─────────────────────────────────────────────────────────────────

test "emheader: LC=4 must_understand=true member_id=5" {
    // EMHEADER = 0xC000_0005: MU=1 LC=4 id=5; NEXTINT=10
    // bit 31=MU, bits 30-28=LC, bits 27-0=member_id
    // 0xC000_0005 = 1100_0000...0000_0101 → MU=1 LC=4 id=5
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeU32(0xC000_0005);
    try w.writeU32(10);
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 5), em.member_id);
    try testing.expect(em.must_understand);
    try testing.expectEqual(@as(u3, 4), em.lc);
    try testing.expectEqual(@as(u32, 10), em.payload_bytes);
}

test "emheader: LC=2 no nextint member_id=0" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeU32(0x2000_0000); // MU=0 LC=2 id=0
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 0), em.member_id);
    try testing.expect(!em.must_understand);
    try testing.expectEqual(@as(u3, 2), em.lc);
    try testing.expectEqual(@as(u32, 4), em.payload_bytes); // LC=2 → 4 bytes
}

test "emheader: writeEmheaderFixed + readEmheader round-trip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeEmheaderFixed(7, true, 3); // member_id=7, must_understand, LC=3 (8 bytes)
    try w.writeU64(0xDEAD_BEEF_1234_5678);
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 7), em.member_id);
    try testing.expect(em.must_understand);
    try testing.expectEqual(@as(u3, 3), em.lc);
    try testing.expectEqual(@as(u32, 8), em.payload_bytes);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_1234_5678), try r.readU64());
}

test "emheader: reserveEmheader + patchEmheader + readEmheader round-trip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const ph = try w.reserveEmheader(3, false); // member_id=3, LC=4
    try w.writeString("hello"); // 4 (len) + 5 (bytes) + 1 (NUL) = 10 bytes
    w.patchEmheader(ph);
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 3), em.member_id);
    try testing.expect(!em.must_understand);
    try testing.expectEqual(@as(u3, 4), em.lc);
    try testing.expectEqual(@as(u32, 10), em.payload_bytes);
    const s = try r.readString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
}

test "emheader: skipEmheaderPayload for unknown fixed-size member" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeEmheaderFixed(99, false, 2); // unknown member_id=99, LC=2 (4 bytes)
    try w.writeI32(42);
    try w.writeI32(100); // sentinel after the skipped member
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 99), em.member_id);
    try r.skipEmheaderPayload(em);
    try testing.expectEqual(@as(i32, 100), try r.readI32());
}

test "encap: PL_CDR2 (mutable) is written by writeEncapHeaderMutable and read as XCDR2" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeaderMutable();
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x0b, 0x00, 0x00 }, buf.items);
    const r = try CdrReader.init(buf.items);
    try testing.expectEqual(XcdrVersion.xcdr2, r.xcdr_version);
    const be = try CdrReader.init(&.{ 0x00, 0x0a, 0x00, 0x00 });
    try testing.expectEqual(ByteOrder.big, be.byte_order);
}

test "dheader: reserved after unaligned data, pads first and counts only the payload" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeU8(0xAA); // leaves the stream 1 byte past a 4-byte boundary
    const dh = try w.reserveDheader();
    try w.writeU32(7);
    w.patchDheader(dh);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0, 0, 0, 4, 0, 0, 0, 7, 0, 0, 0 }, buf.items[4..]);

    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(u8, 0xAA), try r.readU8());
    try testing.expectEqual(@as(u32, 4), try r.readDheader());
    try testing.expectEqual(@as(u32, 7), try r.readU32());
}

test "emheader: LC 5-7 peek NEXTINT as the start of the member value" {
    // EMHEADER words and member bytes using length codes 5-7 (XCDR2 LE):
    //   id 1, LC=5: sequence<string> ["m"]; NEXTINT is the collection DHEADER
    //   id 2, LC=6: sequence<long> [1, 2]; NEXTINT is the element count
    //   id 4, LC=7: sequence<long long> [5]; NEXTINT is the element count
    const bytes = [_]u8{ 0x00, 0x07, 0x00, 0x00 } ++
        [_]u8{ 0x01, 0x00, 0x00, 0x50, 0x0a, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x6d, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x02, 0x00, 0x00, 0x60, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 } ++
        [_]u8{ 0x04, 0x00, 0x00, 0x70, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var r = try CdrReader.init(&bytes);

    const s_str = try r.readEmheader();
    try testing.expectEqual(@as(u28, 1), s_str.member_id);
    try testing.expectEqual(@as(u32, 4 + 10), s_str.payload_bytes);
    try testing.expectEqual(@as(u32, 10), try r.readDheader()); // value starts at the NEXTINT
    try testing.expectEqual(@as(u32, 1), try r.readU32());
    try testing.expectEqualStrings("m", try r.readStringZeroCopy());

    const s_long = try r.readEmheader();
    try testing.expectEqual(@as(u32, 4 + 2 * 4), s_long.payload_bytes);
    try r.skipEmheaderPayload(s_long); // unknown-member skip lands on the next EMHEADER

    const s_ll = try r.readEmheader();
    try testing.expectEqual(@as(u28, 4), s_ll.member_id);
    try testing.expectEqual(@as(u32, 4 + 1 * 8), s_ll.payload_bytes);
    try testing.expectEqual(@as(u32, 1), try r.readU32());
    try testing.expectEqual(@as(i64, 5), try r.readI64());
    try testing.expectEqual(bytes.len, r.pos);
}

test "emheader: mutableHasMore + readMutableDheader loop" {
    // Encode a simple mutable struct: DHEADER + EMHEADER(0,LC=2) + i32 + EMHEADER(1,LC=2) + i32
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const dh = try w.reserveDheader();
    try w.writeEmheaderFixed(0, false, 2);
    try w.writeI32(11);
    try w.writeEmheaderFixed(1, false, 2);
    try w.writeI32(22);
    w.patchDheader(dh);

    var r = try CdrReader.init(buf.items);
    const em_end = try r.readMutableDheader();
    var x: i32 = 0;
    var y: i32 = 0;
    while (r.mutableHasMore(em_end)) {
        const emh = try r.readEmheader();
        switch (emh.member_id) {
            0 => x = try r.readI32(),
            1 => y = try r.readI32(),
            else => try r.skipEmheaderPayload(emh),
        }
    }
    try testing.expectEqual(@as(i32, 11), x);
    try testing.expectEqual(@as(i32, 22), y);
}

// ── Multi-field struct simulation ─────────────────────────────────────────────

test "Point { i32 x; i32 y; }" {
    const Point = struct { x: i32, y: i32 };
    const orig = Point{ .x = 10, .y = -20 };

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeI32(orig.x);
    try w.writeI32(orig.y);

    var r = try CdrReader.init(buf.items);
    const got = Point{ .x = try r.readI32(), .y = try r.readI32() };
    try testing.expectEqual(orig, got);
}

test "mixed struct: bool + u32 + f64" {
    const Msg = struct { flag: bool, id: u32, value: f64 };
    const orig = Msg{ .flag = true, .id = 0xDEAD, .value = 1.5 };

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeBool(orig.flag);
    try w.writeU32(orig.id);
    try w.writeF64(orig.value);

    var r = try CdrReader.init(buf.items);
    const got = Msg{
        .flag = try r.readBool(),
        .id = try r.readU32(),
        .value = try r.readF64(),
    };
    try testing.expectEqual(orig, got);
}

test "skipPrimitives: empty sequence leaves the cursor at the next member (xcdr1)" {
    // An empty sequence emits only its length prefix -- no elements, hence no
    // leading element-alignment padding. Aligning during the skip would consume
    // bytes belonging to the following member. Regression for greptile PR #47.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeU32(0); // empty sequence<u64> length
    try w.writeU8(0xCD); // next member

    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(u32, 0), try r.readU32());
    const pos_before = r.pos;
    try r.skipPrimitives(0, 8);
    try testing.expectEqual(pos_before, r.pos);
    try testing.expectEqual(@as(u8, 0xCD), try r.readU8());
}

test "skipPrimitives: non-empty run still aligns then steps the whole body (xcdr1)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeU8(0xAA); // knock the cursor off alignment
    try w.writeU32(2); // sequence<u32> length
    try w.writeU32(111);
    try w.writeU32(222);
    try w.writeU8(0xBB);

    var r = try CdrReader.init(buf.items);
    _ = try r.readU8();
    const n = try r.readU32();
    try testing.expectEqual(@as(u32, 2), n);
    try r.skipPrimitives(n, 4);
    try testing.expectEqual(@as(u8, 0xBB), try r.readU8());
}

test "skipPrimitives: an overflowing count is rejected" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeU32(4);

    var r = try CdrReader.init(buf.items);
    _ = try r.readU32();
    try testing.expectError(error.EndOfStream, r.skipPrimitives(std.math.maxInt(usize), 8));
}

test "reserveDheaderMaybe: xcdr2 reserves and patches a DHEADER" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const off = try w.reserveDheaderMaybe();
    try testing.expect(off != null);
    try w.writeI32(42);
    w.patchDheaderMaybe(off);
    // DHEADER at offset should be 4 (one i32 worth of payload)
    var r = try CdrReader.init(buf.items);
    const dh = try r.readDheader();
    try testing.expectEqual(@as(u32, 4), dh);
    try testing.expectEqual(@as(i32, 42), try r.readI32());
}

test "reserveDheaderMaybe: xcdr1 returns null, patchDheaderMaybe is no-op" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    const off = try w.reserveDheaderMaybe();
    try testing.expect(off == null);
    w.patchDheaderMaybe(off); // must not crash
    try w.writeI32(7);
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(i32, 7), try r.readI32());
}

test "skipDheaderIfXcdr2: xcdr2 skips DHEADER, xcdr1 is no-op" {
    // xcdr2: writer emits DHEADER + payload; reader skips DHEADER
    {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(testing.allocator);
        var w = mkWriter(.xcdr2, &buf);
        try w.writeEncapHeader();
        const off = try w.reserveDheader();
        try w.writeI32(99);
        w.patchDheader(off);
        var r = try CdrReader.init(buf.items);
        try r.skipDheaderIfXcdr2(); // skip the DHEADER
        try testing.expectEqual(@as(i32, 99), try r.readI32());
    }
    // xcdr1: no DHEADER written, skipDheaderIfXcdr2 is a no-op
    {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(testing.allocator);
        var w = mkWriter(.xcdr1, &buf);
        try w.writeEncapHeader();
        try w.writeI32(55);
        var r = try CdrReader.init(buf.items);
        try r.skipDheaderIfXcdr2(); // no-op on xcdr1
        try testing.expectEqual(@as(i32, 55), try r.readI32());
    }
}

// ── PL_CDR ────────────────────────────────────────────────────────────────────

test "pl_cdr: encap header bytes" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x03, 0x00, 0x00 }, buf.items);
}

test "pl_cdr: reader init accepts PL_CDR_LE" {
    const data = [_]u8{ 0x00, 0x03, 0x00, 0x00 }; // just the encap header
    const r = try CdrReader.init(&data);
    try testing.expect(r.is_pl_cdr);
    try testing.expectEqual(ByteOrder.little, r.byte_order);
    try testing.expectEqual(XcdrVersion.xcdr1, r.xcdr_version);
}

test "pl_cdr: single i32 param roundtrip" {
    // Encode: pid=5, value=i32(42); decode
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    const h = try w.reservePlParam(5);
    try w.writeI32(42);
    try w.patchPlParam(h);
    try w.writePlSentinel();

    var r = try CdrReader.init(buf.items);
    try testing.expect(r.is_pl_cdr);
    var found: i32 = 0;
    while (try r.readPlParam(.lenient)) |p| {
        switch (p.pid & 0x3FFF) {
            5 => found = try r.readI32(),
            else => {},
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(i32, 42), found);
}

test "pl_cdr: multiple params with padding" {
    // Encode: pid=0x0010 → u8(0xAB), pid=0x0020 → u32(0xDEADBEEF); verify lengths + padding.
    // Note: pid=0x0001 is PID_SENTINEL, pid=0x0000 is PID_PAD — use safe values.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    // param pid=0x10, value=u8 (1 byte → padded to 4)
    const h1 = try w.reservePlParam(0x0010);
    try w.writeU8(0xAB);
    try w.patchPlParam(h1);
    // param pid=0x20, value=u32 (4 bytes → no extra padding)
    const h2 = try w.reservePlParam(0x0020);
    try w.writeU32(0xDEAD_BEEF);
    try w.patchPlParam(h2);
    try w.writePlSentinel();

    // Layout: [encap:4][pid1:2 len1:2 val:1 pad:3][pid2:2 len2:2 val:4][sentinel:4]
    try testing.expectEqual(@as(usize, 4 + 4 + 1 + 3 + 4 + 4 + 4), buf.items.len);

    var r = try CdrReader.init(buf.items);
    var v1: u8 = 0;
    var v2: u32 = 0;
    while (try r.readPlParam(.lenient)) |p| {
        switch (p.pid & 0x3FFF) {
            0x0010 => v1 = try r.readU8(),
            0x0020 => v2 = try r.readU32(),
            else => {},
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(u8, 0xAB), v1);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), v2);
}

test "pl_cdr: unknown pid is skipped via seekTo" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    const h_unknown = try w.reservePlParam(99);
    try w.writeI32(0);
    try w.writeI32(0); // 8-byte unknown payload
    try w.patchPlParam(h_unknown);
    const h_known = try w.reservePlParam(7);
    try w.writeI32(777);
    try w.patchPlParam(h_known);
    try w.writePlSentinel();

    var r = try CdrReader.init(buf.items);
    var found: i32 = 0;
    while (try r.readPlParam(.lenient)) |p| {
        switch (p.pid & 0x3FFF) {
            7 => found = try r.readI32(),
            else => {}, // unknown: seekTo advances past it
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(i32, 777), found);
}

test "pl_cdr: xcdr1 8-byte alignment within param" {
    // An f64 inside a param uses XCDR1 alignment (up to 8 bytes).
    // Layout: [encap:4][pid:2 len:2 u8:1 pad7:7 f64:8][sentinel:4] = 4+4+1+7+8+4 = 28
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    const h = try w.reservePlParam(10);
    try w.writeU8(0x01); // CDR pos=5 after encap+pid+len+u8
    try w.writeF64(1.5); // xcdr1: aligns to 8; CDR pos=5→align8→pad3? No wait...
    // After encap (pos=0), pid(u16→pos=2), len(u16→pos=4 in buf BUT inner pos tracks CDR)
    // Actually inner pos starts at 0 after encap, then writeU16(pid)→pos=2, writeU16(0)→pos=4
    // So value starts at CDR pos=4. writeU8→pos=5. writeF64 xcdr1 align=8 → CDR pos=5 needs
    // to go to 8, so pad=3. f64 at CDR pos=8, ends at CDR pos=16. Total value=1+3+8=12 bytes.
    // patchPlParam: raw_bytes=12, pad=0 (already multiple of 4). len=12.
    try w.patchPlParam(h);
    try w.writePlSentinel();

    var r = try CdrReader.init(buf.items);
    var val: f64 = 0;
    while (try r.readPlParam(.lenient)) |p| {
        switch (p.pid & 0x3FFF) {
            10 => {
                _ = try r.readU8(); // skip the u8
                val = try r.readF64();
            },
            else => {},
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(f64, 1.5), val);
}

test "pl_cdr: @pl_repeated round-trip: three i32 elements with same PID" {
    // Simulate what the generated @pl_repeated serializer emits: three separate
    // parameters with the same PID (0x0032), each carrying one i32.
    const pid: u16 = 0x0032;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    for ([_]i32{ 10, 20, 30 }) |v| {
        const h = try w.reservePlParam(pid);
        try w.writeI32(v);
        try w.patchPlParam(h);
    }
    try w.writePlSentinel();

    // Deserialize: accumulate all occurrences of PID 0x0032 into a list.
    var items = std.ArrayListUnmanaged(i32).empty;
    defer items.deinit(testing.allocator);
    var r = try CdrReader.init(buf.items);
    try testing.expect(r.is_pl_cdr);
    while (try r.readPlParam(.lenient)) |p| {
        switch (p.pid & 0x3FFF) {
            pid => try items.append(testing.allocator, try r.readI32()),
            else => {},
        }
        try r.seekTo(p.end_pos);
    }

    try testing.expectEqual(@as(usize, 3), items.items.len);
    try testing.expectEqual(@as(i32, 10), items.items[0]);
    try testing.expectEqual(@as(i32, 20), items.items[1]);
    try testing.expectEqual(@as(i32, 30), items.items[2]);
}

// ── PL_CDR: retention + strict mode ──────────────────────────────────────────

test "pl_cdr: value_start points at the value bytes" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    const h = try w.reservePlParam(0x0040);
    try w.writeU32(0xCAFEF00D);
    try w.patchPlParam(h);
    try w.writePlSentinel();

    var r = try CdrReader.init(buf.items);
    const p = (try r.readPlParam(.lenient)).?;
    try testing.expectEqual(@as(usize, 4), p.byte_len);
    try testing.expectEqual(r.pos, p.value_start);
    try testing.expectEqualSlices(u8, buf.items[p.value_start .. p.value_start + p.byte_len], &[_]u8{ 0x0D, 0xF0, 0xFE, 0xCA });
}

test "pl_cdr: writeRawParam replays an unknown parameter byte-for-byte" {
    // Original: [ unknown pid=0x8123 with 6 value bytes (must-understand-free) ][ known pid=7 ]
    var orig = std.ArrayListUnmanaged(u8).empty;
    defer orig.deinit(testing.allocator);
    var w = PlCdrWriter.init(&orig, testing.allocator);
    try w.writeEncapHeader();
    const hu = try w.reservePlParam(0x8123);
    try w.writeBytes(&[_]u8{ 1, 2, 3, 4, 5, 6 });
    try w.patchPlParam(hu);
    const hk = try w.reservePlParam(7);
    try w.writeI32(777);
    try w.patchPlParam(hk);
    try w.writePlSentinel();

    // Decode, retaining the unknown, then re-encode via writeRawParam in the same slot.
    var r = try CdrReader.init(orig.items);
    var retained: ?CdrReader.RawParam = null;
    defer if (retained) |rp| testing.allocator.free(rp.bytes);
    var known: i32 = 0;
    while (try r.readPlParam(.lenient)) |p| {
        switch (p.pid & 0x3FFF) {
            7 => known = try r.readI32(),
            else => retained = .{
                .pid = p.pid,
                .bytes = try testing.allocator.dupe(u8, orig.items[p.value_start .. p.value_start + p.byte_len]),
            },
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(i32, 777), known);
    try testing.expect(retained != null);
    try testing.expectEqual(@as(u16, 0x8123), retained.?.pid);

    var re = std.ArrayListUnmanaged(u8).empty;
    defer re.deinit(testing.allocator);
    var w2 = PlCdrWriter.init(&re, testing.allocator);
    try w2.writeEncapHeader();
    try w2.writeRawParam(retained.?.pid, retained.?.bytes);
    const hk2 = try w2.reservePlParam(7);
    try w2.writeI32(777);
    try w2.patchPlParam(hk2);
    try w2.writePlSentinel();

    try testing.expectEqualSlices(u8, orig.items, re.items);
}

test "pl_cdr: strict rejects a truncated final parameter; lenient stops" {
    // pid=0x0050, declared len=8, but only 4 value bytes present.
    const data = [_]u8{
        0x00, 0x03, 0x00, 0x00, // encap
        0x50, 0x00, 0x08, 0x00, // pid=0x0050 len=8
        0xAA, 0xBB, 0xCC, 0xDD, // only 4 bytes
    };
    var rs = try CdrReader.init(&data);
    try testing.expectError(error.TruncatedParameter, rs.readPlParam(.strict));

    var rl = try CdrReader.init(&data);
    try testing.expectEqual(@as(?CdrReader.PlParam, null), try rl.readPlParam(.lenient));
}

test "pl_cdr: strict rejects a missing sentinel; lenient stops" {
    // One well-formed param, then the buffer ends — no PID_SENTINEL.
    const data = [_]u8{
        0x00, 0x03, 0x00, 0x00, // encap
        0x50, 0x00, 0x04, 0x00, // pid=0x0050 len=4
        0x01, 0x02, 0x03, 0x04,
    };
    var rs = try CdrReader.init(&data);
    const p0 = (try rs.readPlParam(.strict)).?; // first param OK
    try rs.seekTo(p0.end_pos);
    try testing.expectError(error.MissingSentinel, rs.readPlParam(.strict));

    var rl = try CdrReader.init(&data);
    const p1 = (try rl.readPlParam(.lenient)).?;
    try rl.seekTo(p1.end_pos);
    try testing.expectEqual(@as(?CdrReader.PlParam, null), try rl.readPlParam(.lenient));
}

test "pl_cdr: strict rejects a non-multiple-of-4 length; lenient rounds up" {
    const data = [_]u8{
        0x00, 0x03, 0x00, 0x00, // encap
        0x05, 0x00, 0x03, 0x00, // pid=5 len=3 (misaligned)
        0x41, 0x42, 0x43, 0x00, // 3 value bytes + 1 pad
        0x01, 0x00, 0x00, 0x00, // sentinel
    };
    var rs = try CdrReader.init(&data);
    try testing.expectError(error.MisalignedParameter, rs.readPlParam(.strict));

    var rl = try CdrReader.init(&data);
    const p = (try rl.readPlParam(.lenient)).?;
    try testing.expectEqual(@as(u16, 3), p.byte_len);
    try testing.expectEqual(@as(usize, 12), p.end_pos); // 8 (hdr end) + 4 (padded)
}

// ── fixed<D,S> roundtrips ─────────────────────────────────────────────────────

test "fixed<5,2>: positive roundtrip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(5, 2, 123.45);
    // Expected BCD: digits=[1,2,3,4,5], sign=0xC → bytes [0x12,0x34,0x5C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x5C }, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, 123.45), try r.readFixed(5, 2), 0.001);
}

test "fixed<5,2>: negative roundtrip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(5, 2, -123.45);
    // Sign nibble 0xD → bytes [0x12,0x34,0x5D]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x5D }, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, -123.45), try r.readFixed(5, 2), 0.001);
}

test "fixed<4,2>: even-digit padding roundtrip" {
    // D=4 (even) → leading zero nibble; N=3 bytes
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(4, 2, 12.34);
    // Nibbles: [0,1,2,3,4,0xC] → bytes [0x01,0x23,0x4C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x23, 0x4C }, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, 12.34), try r.readFixed(4, 2), 0.001);
}

test "fixed<1,0>: single digit" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(1, 0, 7.0);
    // N=1 byte, nibbles [7,0xC] → 0x7C
    try testing.expectEqualSlices(u8, &[_]u8{0x7C}, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, 7.0), try r.readFixed(1, 0), 0.001);
}

test "fixed<3,1>: zero value" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(3, 1, 0.0);
    // digits=[0,0,0], sign=0xC → N=2 bytes, nibbles [0,0,0,0xC] → [0x00,0x0C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x0C }, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try r.readFixed(3, 1), 0.001);
}

test "pl_cdr: @pl_repeated round-trip: mixed PID types" {
    // Interleaved repeated params (PID_A = 0x0032, PID_B = 0x0033) to verify
    // that deserialization correctly routes each occurrence to the right sequence.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    // Emit: A(1), B(100), A(2), B(200), A(3)
    const ha1 = try w.reservePlParam(0x0032);
    try w.writeI32(1);
    try w.patchPlParam(ha1);
    const hb1 = try w.reservePlParam(0x0033);
    try w.writeI32(100);
    try w.patchPlParam(hb1);
    const ha2 = try w.reservePlParam(0x0032);
    try w.writeI32(2);
    try w.patchPlParam(ha2);
    const hb2 = try w.reservePlParam(0x0033);
    try w.writeI32(200);
    try w.patchPlParam(hb2);
    const ha3 = try w.reservePlParam(0x0032);
    try w.writeI32(3);
    try w.patchPlParam(ha3);
    try w.writePlSentinel();

    var list_a = std.ArrayListUnmanaged(i32).empty;
    defer list_a.deinit(testing.allocator);
    var list_b = std.ArrayListUnmanaged(i32).empty;
    defer list_b.deinit(testing.allocator);

    var r = try CdrReader.init(buf.items);
    while (try r.readPlParam(.lenient)) |p| {
        switch (p.pid & 0x3FFF) {
            0x0032 => try list_a.append(testing.allocator, try r.readI32()),
            0x0033 => try list_b.append(testing.allocator, try r.readI32()),
            else => {},
        }
        try r.seekTo(p.end_pos);
    }

    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, list_a.items);
    try testing.expectEqualSlices(i32, &[_]i32{ 100, 200 }, list_b.items);
}

test "key hash writer counters reject overflow before updating the digest" {
    var writer = KeyHashWriter.init();
    writer.len = std.math.maxInt(usize);
    writer.pos = std.math.maxInt(usize);
    try std.testing.expectError(error.Overflow, writer.writeBytes(&.{1}));
    try std.testing.expectEqual(std.math.maxInt(usize), writer.len);
    try std.testing.expectEqual(std.math.maxInt(usize), writer.pos);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0))), &writer.first16);
}
