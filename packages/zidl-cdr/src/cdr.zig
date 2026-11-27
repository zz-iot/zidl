//! CDR (Common Data Representation) writer and reader for zidl-cdr.
//!
//! Implements OMG XCDR1 and XCDR2 encoding, little-endian output, per:
//!   - DDS-XTYPES spec formal-20-02-04 §7.3
//!   - RTPS spec formal-22-04-01 §9.6
//!
//! ## Writers
//!
//! `writer.zig`'s `Writer(config)`, `RuntimeWriter` and `KeyHashWriter` below.
//! Generated serialize functions use `anytype` duck-typing, so every writer is
//! accepted without code-gen changes:
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
// compatible replacement here so generated code can use `zidl_cdr.BoundedArray`.

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

    /// No-op for aggregate framing: canonical key holders use FINAL aggregates.
    /// Collection DHEADERs are separate; enum/bitmask array codegen writes their
    /// known payload size directly, since an MD5 stream cannot be back-patched.
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

// ── CdrReader ─────────────────────────────────────────────────────────────────

/// CDR reader with runtime endianness and XCDR version.
///
/// Constructed by parsing the 4-byte encapsulation header.  Subsequent reads
/// apply CDR alignment padding and byte-swap for big-endian streams.
///
/// All reads validate that enough bytes remain; `error.EndOfStream` is returned
/// on any truncation.
pub const CdrReader = @import("reader.zig").CdrReader;

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const RuntimeWriter = @import("writer.zig").RuntimeWriter;

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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00 }, w.bytes());
}

test "encap header: xcdr1 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }, w.bytes());
}

test "encap header delimited: xcdr2 le emits 0x0009" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeaderDelimited();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x09, 0x00, 0x00 }, w.bytes());
}

test "encap header delimited: xcdr1 le emits same as writeEncapHeader" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeaderDelimited();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }, w.bytes());
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
    comptime writeFn: fn (*RuntimeWriter, T) anyerror!void,
    comptime readFn: fn (*CdrReader) anyerror!T,
) !void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try writeFn(&w, value);
    var r = try CdrReader.init(w.bytes());
    try testing.expectEqual(value, try readFn(&r));
}

test "roundtrip: u8" {
    try writeAndRead(u8, 0xAB, struct {
        fn f(w: *RuntimeWriter, v: u8) !void {
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
        fn f(w: *RuntimeWriter, v: i8) !void {
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
        fn f(w: *RuntimeWriter, v: bool) !void {
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
        fn f(w: *RuntimeWriter, v: bool) !void {
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
        fn f(w: *RuntimeWriter, v: u16) !void {
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
        fn f(w: *RuntimeWriter, v: i16) !void {
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
        fn f(w: *RuntimeWriter, v: u32) !void {
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
        fn f(w: *RuntimeWriter, v: i32) !void {
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
        fn f(w: *RuntimeWriter, v: f32) !void {
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
        fn f(w: *RuntimeWriter, v: u64) !void {
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
        fn f(w: *RuntimeWriter, v: i64) !void {
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
        fn f(w: *RuntimeWriter, v: f64) !void {
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeU8(2); // invalid — CDR bool must be 0 or 1
    var r = try CdrReader.init(w.bytes());
    try testing.expectError(error.InvalidBool, r.readBool());
}

// ── Alignment ─────────────────────────────────────────────────────────────────

test "alignment: xcdr2 u8 then u32 has 3-byte pad" {
    // CDR pos after u8 = 1; xcdr2 u32 needs align-4: pad 3 → CDR pos=4; +4=8.
    // buf.len = 4 (encap) + 1 (u8) + 3 (pad) + 4 (u32) = 12.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU8(0xAA); // CDR pos=1
    try w.writeU32(0x12345678); // xcdr2: align-4, pad 3 → CDR pos=4; +4=8
    try testing.expectEqual(@as(usize, 12), w.bytes().len);
    try testing.expectEqual(@as(u8, 0xAA), w.bytes()[4]);
    try testing.expectEqual(@as(u8, 0x00), w.bytes()[5]); // pad
    try testing.expectEqual(@as(u8, 0x00), w.bytes()[6]); // pad
    try testing.expectEqual(@as(u8, 0x00), w.bytes()[7]); // pad
    try testing.expectEqual(@as(u8, 0x78), w.bytes()[8]);
    try testing.expectEqual(@as(u8, 0x56), w.bytes()[9]);
    try testing.expectEqual(@as(u8, 0x34), w.bytes()[10]);
    try testing.expectEqual(@as(u8, 0x12), w.bytes()[11]);
}

test "alignment: xcdr2 u64 capped at 4" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader(); // pos=4
    try w.writeU8(0x01); // pos=5
    try w.writeU64(1); // xcdr2: cap=4 → align=min(8,4)=4 → CDR pos=1 mod 4=1, pad 3 → CDR pos=4, +8=12
    try testing.expectEqual(@as(usize, 16), w.bytes().len);
}

test "alignment: xcdr1 u64 after u8 uses 8-byte alignment" {
    // CDR pos after u8 = 1; xcdr1 u64 needs align-8: pad 7 → CDR pos=8, +8=16.
    // buf.len = 4 (encap) + 1 (u8) + 7 (pad) + 8 (u64) = 20.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU8(0x01); // CDR pos=1
    try w.writeU64(1); // xcdr1: cap=8 → align to 8 → CDR pos=8, +8→16
    try testing.expectEqual(@as(usize, 20), w.bytes().len);
}

test "alignment: xcdr1 u64 after u32 pads to 8" {
    // CDR pos: u32(4) + u8(1) = 5; xcdr1 u64 needs align-8: pad 3 → CDR pos=8, +8=16.
    // buf.len = 4 (encap) + 4 (u32) + 1 (u8) + 3 (pad) + 8 (u64) = 20.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU32(0); // CDR pos=4
    try w.writeU8(0x01); // CDR pos=5
    try w.writeU64(1); // xcdr1: align to 8 → pad 3 → CDR pos=8, +8=16
    try testing.expectEqual(@as(usize, 20), w.bytes().len);
}

// ── Known byte sequences ──────────────────────────────────────────────────────

test "known bytes: i32(1) xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeI32(1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }, w.bytes());
}

test "known bytes: i32(-1) xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeI32(-1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF }, w.bytes());
}

// ── String ────────────────────────────────────────────────────────────────────

test "string: known bytes for 'hi'" {
    // "hi": len=3 (2+NUL), then [h i 0x00]
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeString("hi");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 'h', 'i', 0x00 }, w.bytes());
}

test "string: roundtrip zero-copy" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeString("hello");
    var r = try CdrReader.init(w.bytes());
    try testing.expectEqualStrings("hello", try r.readStringZeroCopy());
}

test "string: empty roundtrip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeString("");
    var r = try CdrReader.init(w.bytes());
    try testing.expectEqual(@as(usize, 0), (try r.readStringZeroCopy()).len);
}

test "string: allocating read matches zero-copy" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeString("test");
    var r1 = try CdrReader.init(w.bytes());
    const zc = try r1.readStringZeroCopy();
    var r2 = try CdrReader.init(w.bytes());
    const owned = try r2.readString(testing.allocator);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings(zc, owned);
}

// ── Wstring ───────────────────────────────────────────────────────────────────

test "wstring: roundtrip" {
    const wstr = [_]u16{ 'h', 'i' };
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeWstring(&wstr);
    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeDheader(42);
    var r = try CdrReader.init(w.bytes());
    try testing.expectEqual(@as(u32, 42), try r.readDheader());
}

test "dheader: reserveDheader and patchDheader" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    const dh = try w.reserveDheader();
    try w.writeI32(10); // 4 bytes of payload
    try w.writeI32(20); // 4 bytes
    w.patchDheader(dh);
    // DHEADER should now be 8 (two i32s)
    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeU32(0xC000_0005);
    try w.writeU32(10);
    var r = try CdrReader.init(w.bytes());
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 5), em.member_id);
    try testing.expect(em.must_understand);
    try testing.expectEqual(@as(u3, 4), em.lc);
    try testing.expectEqual(@as(u32, 10), em.payload_bytes);
}

test "emheader: LC=2 no nextint member_id=0" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeU32(0x2000_0000); // MU=0 LC=2 id=0
    var r = try CdrReader.init(w.bytes());
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 0), em.member_id);
    try testing.expect(!em.must_understand);
    try testing.expectEqual(@as(u3, 2), em.lc);
    try testing.expectEqual(@as(u32, 4), em.payload_bytes); // LC=2 → 4 bytes
}

test "emheader: writeEmheaderFixed + readEmheader round-trip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeEmheaderFixed(7, true, 3); // member_id=7, must_understand, LC=3 (8 bytes)
    try w.writeU64(0xDEAD_BEEF_1234_5678);
    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    const ph = try w.reserveEmheader(3, false); // member_id=3, LC=4
    try w.writeString("hello"); // 4 (len) + 5 (bytes) + 1 (NUL) = 10 bytes
    w.patchEmheader(ph);
    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeEmheaderFixed(99, false, 2); // unknown member_id=99, LC=2 (4 bytes)
    try w.writeI32(42);
    try w.writeI32(100); // sentinel after the skipped member
    var r = try CdrReader.init(w.bytes());
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 99), em.member_id);
    try r.skipEmheaderPayload(em);
    try testing.expectEqual(@as(i32, 100), try r.readI32());
}

test "encap: PL_CDR2 (mutable) is written by writeEncapHeaderMutable and read as XCDR2" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeaderMutable();
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x0b, 0x00, 0x00 }, w.bytes());
    const r = try CdrReader.init(w.bytes());
    try testing.expectEqual(XcdrVersion.xcdr2, r.xcdr_version);
    const be = try CdrReader.init(&.{ 0x00, 0x0a, 0x00, 0x00 });
    try testing.expectEqual(ByteOrder.big, be.byte_order);
}

test "dheader: reserved after unaligned data, pads first and counts only the payload" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeU8(0xAA); // leaves the stream 1 byte past a 4-byte boundary
    const dh = try w.reserveDheader();
    try w.writeU32(7);
    w.patchDheader(dh);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0, 0, 0, 4, 0, 0, 0, 7, 0, 0, 0 }, w.bytes()[4..]);

    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    const dh = try w.reserveDheader();
    try w.writeEmheaderFixed(0, false, 2);
    try w.writeI32(11);
    try w.writeEmheaderFixed(1, false, 2);
    try w.writeI32(22);
    w.patchDheader(dh);

    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeI32(orig.x);
    try w.writeI32(orig.y);

    var r = try CdrReader.init(w.bytes());
    const got = Point{ .x = try r.readI32(), .y = try r.readI32() };
    try testing.expectEqual(orig, got);
}

test "mixed struct: bool + u32 + f64" {
    const Msg = struct { flag: bool, id: u32, value: f64 };
    const orig = Msg{ .flag = true, .id = 0xDEAD, .value = 1.5 };

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeBool(orig.flag);
    try w.writeU32(orig.id);
    try w.writeF64(orig.value);

    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try w.writeU32(0); // empty sequence<u64> length
    try w.writeU8(0xCD); // next member

    var r = try CdrReader.init(w.bytes());
    try testing.expectEqual(@as(u32, 0), try r.readU32());
    const pos_before = r.pos;
    try r.skipPrimitives(0, 8);
    try testing.expectEqual(pos_before, r.pos);
    try testing.expectEqual(@as(u8, 0xCD), try r.readU8());
}

test "skipPrimitives: non-empty run still aligns then steps the whole body (xcdr1)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try w.writeU8(0xAA); // knock the cursor off alignment
    try w.writeU32(2); // sequence<u32> length
    try w.writeU32(111);
    try w.writeU32(222);
    try w.writeU8(0xBB);

    var r = try CdrReader.init(w.bytes());
    _ = try r.readU8();
    const n = try r.readU32();
    try testing.expectEqual(@as(u32, 2), n);
    try r.skipPrimitives(n, 4);
    try testing.expectEqual(@as(u8, 0xBB), try r.readU8());
}

test "skipPrimitives: an overflowing count is rejected" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    try w.writeU32(4);

    var r = try CdrReader.init(w.bytes());
    _ = try r.readU32();
    try testing.expectError(error.EndOfStream, r.skipPrimitives(std.math.maxInt(usize), 8));
}

test "reserveDheaderMaybe: xcdr2 reserves and patches a DHEADER" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try w.writeEncapHeader();
    const off = try w.reserveDheaderMaybe();
    try testing.expect(off != null);
    try w.writeI32(42);
    w.patchDheaderMaybe(off);
    // DHEADER at offset should be 4 (one i32 worth of payload)
    var r = try CdrReader.init(w.bytes());
    const dh = try r.readDheader();
    try testing.expectEqual(@as(u32, 4), dh);
    try testing.expectEqual(@as(i32, 42), try r.readI32());
}

test "reserveDheaderMaybe: xcdr1 returns null, patchDheaderMaybe is no-op" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    const off = try w.reserveDheaderMaybe();
    try testing.expect(off == null);
    w.patchDheaderMaybe(off); // must not crash
    try w.writeI32(7);
    var r = try CdrReader.init(w.bytes());
    try testing.expectEqual(@as(i32, 7), try r.readI32());
}

test "skipDheaderIfXcdr2: xcdr2 skips DHEADER, xcdr1 is no-op" {
    // xcdr2: writer emits DHEADER + payload; reader skips DHEADER
    {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(testing.allocator);
        var buf_fixed: [1 << 16]u8 = undefined;
        var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
        try w.writeEncapHeader();
        const off = try w.reserveDheader();
        try w.writeI32(99);
        w.patchDheader(off);
        var r = try CdrReader.init(w.bytes());
        try r.skipDheaderIfXcdr2(); // skip the DHEADER
        try testing.expectEqual(@as(i32, 99), try r.readI32());
    }
    // xcdr1: no DHEADER written, skipDheaderIfXcdr2 is a no-op
    {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(testing.allocator);
        var buf_fixed: [1 << 16]u8 = undefined;
        var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
        try w.writeEncapHeader();
        try w.writeI32(55);
        var r = try CdrReader.init(w.bytes());
        try r.skipDheaderIfXcdr2(); // no-op on xcdr1
        try testing.expectEqual(@as(i32, 55), try r.readI32());
    }
}

// ── PL_CDR ────────────────────────────────────────────────────────────────────

test "pl_cdr: encap header bytes" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x03, 0x00, 0x00 }, w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
    const h = try w.reservePlParam(5);
    try w.writeI32(42);
    try w.patchPlParam(h);
    try w.writePlSentinel();

    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
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
    try testing.expectEqual(@as(usize, 4 + 4 + 1 + 3 + 4 + 4 + 4), w.bytes().len);

    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
    const h_unknown = try w.reservePlParam(99);
    try w.writeI32(0);
    try w.writeI32(0); // 8-byte unknown payload
    try w.patchPlParam(h_unknown);
    const h_known = try w.reservePlParam(7);
    try w.writeI32(777);
    try w.patchPlParam(h_known);
    try w.writePlSentinel();

    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
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

    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
    for ([_]i32{ 10, 20, 30 }) |v| {
        const h = try w.reservePlParam(pid);
        try w.writeI32(v);
        try w.patchPlParam(h);
    }
    try w.writePlSentinel();

    // Deserialize: accumulate all occurrences of PID 0x0032 into a list.
    var items = std.ArrayListUnmanaged(i32).empty;
    defer items.deinit(testing.allocator);
    var r = try CdrReader.init(w.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
    const h = try w.reservePlParam(0x0040);
    try w.writeU32(0xCAFEF00D);
    try w.patchPlParam(h);
    try w.writePlSentinel();

    var r = try CdrReader.init(w.bytes());
    const p = (try r.readPlParam(.lenient)).?;
    try testing.expectEqual(@as(usize, 4), p.byte_len);
    try testing.expectEqual(r.pos, p.value_start);
    try testing.expectEqualSlices(u8, w.bytes()[p.value_start .. p.value_start + p.byte_len], &[_]u8{ 0x0D, 0xF0, 0xFE, 0xCA });
}

test "pl_cdr: writeRawParam replays an unknown parameter byte-for-byte" {
    // Original: [ unknown pid=0x8123 with 6 value bytes (must-understand-free) ][ known pid=7 ]
    var orig = std.ArrayListUnmanaged(u8).empty;
    defer orig.deinit(testing.allocator);
    var orig_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&orig_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
    const hu = try w.reservePlParam(0x8123);
    try w.writeBytes(&[_]u8{ 1, 2, 3, 4, 5, 6 });
    try w.patchPlParam(hu);
    const hk = try w.reservePlParam(7);
    try w.writeI32(777);
    try w.patchPlParam(hk);
    try w.writePlSentinel();

    // Decode, retaining the unknown, then re-encode via writeRawParam in the same slot.
    var r = try CdrReader.init(w.bytes());
    var retained: ?CdrReader.RawParam = null;
    defer if (retained) |rp| testing.allocator.free(rp.bytes);
    var known: i32 = 0;
    while (try r.readPlParam(.lenient)) |p| {
        switch (p.pid & 0x3FFF) {
            7 => known = try r.readI32(),
            else => retained = .{
                .pid = p.pid,
                .bytes = try testing.allocator.dupe(u8, w.bytes()[p.value_start .. p.value_start + p.byte_len]),
            },
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(i32, 777), known);
    try testing.expect(retained != null);
    try testing.expectEqual(@as(u16, 0x8123), retained.?.pid);

    var re = std.ArrayListUnmanaged(u8).empty;
    defer re.deinit(testing.allocator);
    var re_fixed: [1 << 16]u8 = undefined;
    var w2 = RuntimeWriter.initFixed(&re_fixed, .xcdr1, .little);
    try w2.writePlEncapHeader();
    try w2.writeRawParam(retained.?.pid, retained.?.bytes);
    const hk2 = try w2.reservePlParam(7);
    try w2.writeI32(777);
    try w2.patchPlParam(hk2);
    try w2.writePlSentinel();

    try testing.expectEqualSlices(u8, w.bytes(), w2.bytes());
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
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try w.writeFixed(5, 2, 123.45);
    // Expected BCD: digits=[1,2,3,4,5], sign=0xC → bytes [0x12,0x34,0x5C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x5C }, w.bytes()[4..]);
    var r = try CdrReader.init(w.bytes());
    try testing.expectApproxEqAbs(@as(f64, 123.45), try r.readFixed(5, 2), 0.001);
}

test "fixed<5,2>: negative roundtrip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try w.writeFixed(5, 2, -123.45);
    // Sign nibble 0xD → bytes [0x12,0x34,0x5D]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x5D }, w.bytes()[4..]);
    var r = try CdrReader.init(w.bytes());
    try testing.expectApproxEqAbs(@as(f64, -123.45), try r.readFixed(5, 2), 0.001);
}

test "fixed<4,2>: even-digit padding roundtrip" {
    // D=4 (even) → leading zero nibble; N=3 bytes
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try w.writeFixed(4, 2, 12.34);
    // Nibbles: [0,1,2,3,4,0xC] → bytes [0x01,0x23,0x4C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x23, 0x4C }, w.bytes()[4..]);
    var r = try CdrReader.init(w.bytes());
    try testing.expectApproxEqAbs(@as(f64, 12.34), try r.readFixed(4, 2), 0.001);
}

test "fixed<1,0>: single digit" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try w.writeFixed(1, 0, 7.0);
    // N=1 byte, nibbles [7,0xC] → 0x7C
    try testing.expectEqualSlices(u8, &[_]u8{0x7C}, w.bytes()[4..]);
    var r = try CdrReader.init(w.bytes());
    try testing.expectApproxEqAbs(@as(f64, 7.0), try r.readFixed(1, 0), 0.001);
}

test "fixed<3,1>: zero value" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try w.writeFixed(3, 1, 0.0);
    // digits=[0,0,0], sign=0xC → N=2 bytes, nibbles [0,0,0,0xC] → [0x00,0x0C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x0C }, w.bytes()[4..]);
    var r = try CdrReader.init(w.bytes());
    try testing.expectApproxEqAbs(@as(f64, 0.0), try r.readFixed(3, 1), 0.001);
}

test "pl_cdr: @pl_repeated round-trip: mixed PID types" {
    // Interleaved repeated params (PID_A = 0x0032, PID_B = 0x0033) to verify
    // that deserialization correctly routes each occurrence to the right sequence.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var buf_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&buf_fixed, .xcdr1, .little);
    try w.writePlEncapHeader();
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

    var r = try CdrReader.init(w.bytes());
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

test "mandatory XCDR2 framing rejects XCDR1 before touching the cursor" {
    var bytes_fixed: [1 << 16]u8 = undefined;
    var writer = RuntimeWriter.initFixed(&bytes_fixed, .xcdr1, .little);
    try writer.writeEncapHeader();
    try std.testing.expectError(error.UnsupportedEncoding, writer.reserveDheader());
    try std.testing.expectEqual(@as(usize, 4), writer.bytes().len);
    var reader = try CdrReader.init(writer.bytes());
    try std.testing.expectError(error.UnsupportedEncoding, reader.readMutableDheader());
    try std.testing.expectEqual(@as(usize, 4), reader.pos);
}

test "primitive array bodies agree with scalar writes and validate bools atomically" {
    var bulk_fixed: [1 << 16]u8 = undefined;
    var scalar_fixed: [1 << 16]u8 = undefined;
    inline for (.{ XcdrVersion.xcdr1, XcdrVersion.xcdr2 }) |version| {
        var w = RuntimeWriter.initFixed(&bulk_fixed, version, .little);
        var expected = RuntimeWriter.initFixed(&scalar_fixed, version, .little);
        const values = [_]u64{ 0x0123456789abcdef, 42 };
        try w.writeEncapHeader();
        try expected.writeEncapHeader();
        try w.writeU8(1);
        try expected.writeU8(1);
        try w.writePrimitiveArray(u64, &values);
        for (values) |v| try expected.writeU64(v);
        try w.writePrimitiveArray(bool, &.{ true, false });
        try expected.writeBool(true);
        try expected.writeBool(false);
        try std.testing.expectEqualSlices(u8, expected.bytes(), w.bytes());
        var r = try CdrReader.init(w.bytes());
        _ = try r.readU8();
        var out: [2]u64 = undefined;
        try r.readPrimitiveArray(u64, &out);
        try std.testing.expectEqualSlices(u64, &values, &out);
        const before = r.pos;
        var bools = [_]bool{ false, true };
        w.bytes()[w.bytes().len - 1] = 2;
        try std.testing.expectError(error.InvalidBool, r.readPrimitiveArray(bool, &bools));
        try std.testing.expectEqual(before, r.pos);
        try std.testing.expectEqualSlices(bool, &.{ false, true }, &bools);
    }
}

test "readSequenceCount checks a sequence's bound and body before reading only its length" {
    var bytes_fixed: [1 << 16]u8 = undefined;
    const values = [_]u64{ 1, 0x0123456789abcdef, 3 };
    inline for (.{ XcdrVersion.xcdr1, XcdrVersion.xcdr2 }) |version| {
        var w = RuntimeWriter.initFixed(&bytes_fixed, version, .little);
        try w.writeEncapHeader();
        try w.writeU8(7); // the length and the elements are padded
        try w.writeU32(values.len);
        try w.writePrimitiveArray(u64, &values);

        // Reads only the length; the elements follow at their alignment.
        var r = try CdrReader.init(w.bytes());
        _ = try r.readU8();
        const at_length = r.pos;
        try std.testing.expectEqual(@as(u32, values.len), try r.readSequenceCount(8, null));
        try std.testing.expectEqual(at_length + 3 + 4, r.pos);
        var out: [values.len]u64 = undefined;
        try r.readPrimitiveArray(u64, &out);
        try std.testing.expectEqualSlices(u64, &values, &out);
        try std.testing.expectEqual(w.bytes().len, r.pos);

        // A bound it is within; one it is over, unchanged.
        r.pos = at_length;
        try std.testing.expectEqual(@as(u32, values.len), try r.readSequenceCount(8, values.len));
        r.pos = at_length;
        try std.testing.expectError(error.SequenceTooLong, r.readSequenceCount(8, values.len - 1));
        try std.testing.expectEqual(at_length, r.pos);

        // Another width is refused before anything is read.
        try std.testing.expectError(error.InvalidPrimitiveSize, r.readSequenceCount(3, null));
        try std.testing.expectEqual(at_length, r.pos);

        // Elements one byte short, or a length cut off: unchanged.
        var short = try CdrReader.init(w.bytes()[0 .. w.bytes().len - 1]);
        _ = try short.readU8();
        try std.testing.expectError(error.EndOfStream, short.readSequenceCount(8, null));
        try std.testing.expectEqual(at_length, short.pos);
        var cut = try CdrReader.init(w.bytes()[0 .. at_length + 5]);
        _ = try cut.readU8();
        try std.testing.expectError(error.EndOfStream, cut.readSequenceCount(8, null));
        try std.testing.expectEqual(at_length, cut.pos);

        // A count whose elements cannot fit is refused, not overflowed.
        w = RuntimeWriter.initFixed(&bytes_fixed, version, .little);
        try w.writeEncapHeader();
        try w.writeU32(0xffff_ffff);
        r = try CdrReader.init(w.bytes());
        try std.testing.expectError(error.EndOfStream, r.readSequenceCount(8, null));
        try std.testing.expectEqual(@as(usize, 4), r.pos);

        // An empty sequence needs no element bytes.
        w = RuntimeWriter.initFixed(&bytes_fixed, version, .little);
        try w.writeEncapHeader();
        try w.writeU32(0);
        r = try CdrReader.init(w.bytes());
        try std.testing.expectEqual(@as(u32, 0), try r.readSequenceCount(8, 4));
        try std.testing.expectEqual(w.bytes().len, r.pos);
    }
}

test "viewPrimitives views elements in place, in the stream's byte order" {
    const host_le = @import("builtin").cpu.arch.endian() == .little;
    const values = [_]u32{ 0x01020304, 0xa0b0c0d0, 7 };
    var as_bytes: [12]u8 = undefined;

    // Little endian, as the native writer writes.
    var le_fixed: [1 << 16]u8 = undefined;
    var w = RuntimeWriter.initFixed(&le_fixed, .xcdr1, .little);
    try w.writeEncapHeader();
    try w.writeU8(7);
    try w.writePrimitiveArray(u32, &values);
    try w.writePrimitiveArray(u8, &.{ 9, 8 });
    var r = try CdrReader.init(w.bytes());
    _ = try r.readU8();
    const at = r.pos;
    // Failures leave the reader unchanged; an empty view consumes nothing.
    try std.testing.expectError(error.EndOfStream, r.viewPrimitives(4, 4));
    try std.testing.expectError(error.InvalidPrimitiveSize, r.viewPrimitives(3, 3));
    try std.testing.expectEqual(@as(usize, 0), (try r.viewPrimitives(4, 0)).count());
    try std.testing.expectEqual(at, r.pos);
    const view = try r.viewPrimitives(4, values.len);
    try std.testing.expectEqual(@as(usize, 3), view.count());
    try std.testing.expectEqual(!host_le, view.swapped());
    // Not aligned to u32 in memory: compared element by element.
    if (view.asNative(u32)) |native| for (values, native) |want, got| try std.testing.expectEqual(want, got);
    try std.testing.expect(view.asNative(u16) == null);
    view.copyTo(&as_bytes);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&values), &as_bytes);
    const octets = try r.viewPrimitives(1, 2);
    try std.testing.expect(!octets.swapped());
    try std.testing.expectEqualSlices(u8, &.{ 9, 8 }, octets.asNative(u8).?);
    try std.testing.expectEqual(w.bytes().len, r.pos);

    // Big endian (CDR_BE): the same values, swapped on a little-endian host.
    const be = [_]u8{ 0x00, 0x00, 0x00, 0x00, 7, 0, 0, 0, 0x01, 0x02, 0x03, 0x04, 0xa0, 0xb0, 0xc0, 0xd0, 0, 0, 0, 7 };
    r = try CdrReader.init(&be);
    _ = try r.readU8();
    const swapped = try r.viewPrimitives(4, values.len);
    try std.testing.expectEqual(host_le, swapped.swapped());
    try std.testing.expectEqual(host_le, swapped.asNative(u32) == null);
    swapped.copyTo(&as_bytes);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&values), &as_bytes);
    try std.testing.expectEqual(be.len, r.pos);
}

test "reservePrimitives leaves elements to fill in place, found by offset after later writes" {
    var bulk_fixed: [1 << 16]u8 = undefined;
    var scalar_fixed: [1 << 16]u8 = undefined;
    const values = [_]u64{ 1, 0x0123456789abcdef, 3 };
    var more: [600]u32 = undefined;
    for (&more, 0..) |*m, i| m.* = @intCast(i * 7);
    inline for (.{ XcdrVersion.xcdr1, XcdrVersion.xcdr2 }) |version| {
        var w = RuntimeWriter.initFixed(&bulk_fixed, version, .little);
        var expected = RuntimeWriter.initFixed(&scalar_fixed, version, .little);
        try w.writeEncapHeader();
        try expected.writeEncapHeader();
        try w.writeU8(7);
        try expected.writeU8(7);

        // Another width is refused; an empty reservation reserves nothing.
        try std.testing.expectError(error.InvalidPrimitiveSize, w.reservePrimitives(3, 1));
        const len = w.bytes().len;
        var empty = try w.reservePrimitives(8, 0);
        try std.testing.expectEqual(@as(usize, 0), w.reservedBytes(empty).?.len);
        w.commitPrimitives(&empty);
        try std.testing.expectEqual(len, w.bytes().len);

        // Reserved, then more written: the reservation is found again by
        // its offset and filled late.
        var res = try w.reservePrimitives(8, values.len);
        try expected.writePrimitiveArray(u64, &values);
        try std.testing.expect(!res.committed);
        try w.writePrimitiveArray(u32, &more);
        try expected.writePrimitiveArray(u32, &more);
        @memcpy(w.reservedBytes(res).?, std.mem.sliceAsBytes(&values));
        w.commitPrimitives(&res);
        try std.testing.expect(res.committed);
        w.commitPrimitives(&res); // once: a repeat changes nothing
        try std.testing.expectEqualSlices(u8, expected.bytes(), w.bytes());
    }
}
