//! Known-answer checks for the Zig backend against reference encodings of
//! ka.idl from an independent XTypes implementation (vectors.txt).
//!
//! For each top-level type: the sample encodes to the reference XCDR1 and
//! XCDR2 bytes, including the representation id the type's extensibility
//! selects; the reference bytes decode back to the sample; decoded values
//! clone and release without leaks; every truncated input and every
//! allocation failure is handled cleanly; and the generated minimal
//! TypeObject hash equals the reference hash.
//!
//! `Mut` is XCDR2 only (XCDR1 mutable is PL_CDR). Its bytes are compared by
//! decoding: the reference uses EMHEADER length codes 5–7 where zidl writes 4,
//! which XTypes allows either way.

const std = @import("std");
const testing = std.testing;
const zidl_rt = @import("zidl_rt");
const KA = @import("fixture").KA;

const vectors_txt = @embedFile("vectors.txt");

fn vector(kind: []const u8, name: []const u8, enc: []const u8) ![]u8 {
    var lines = std.mem.tokenizeScalar(u8, vectors_txt, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, f.next() orelse continue, kind)) continue;
        if (!std.mem.eql(u8, f.next() orelse continue, name)) continue;
        if (enc.len != 0 and !std.mem.eql(u8, f.next() orelse continue, enc)) continue;
        const hex = f.next() orelse return error.BadVector;
        const out = try testing.allocator.alloc(u8, hex.len / 2);
        _ = try std.fmt.hexToBytes(out, hex);
        return out;
    }
    return error.MissingVector;
}

// ── Borrowed sample construction ─────────────────────────────────────────────
//
// Samples borrow their storage from `&.{ ... }` literals, so the tests build
// them at comptime (`comptime nested()`): that makes every literal static.

fn borrow(comptime S: type, items: []const zidl_rt.SeqElem(S)) S {
    return .{ ._maximum = @intCast(items.len), ._length = @intCast(items.len), ._buffer = @constCast(items.ptr), ._release = false };
}

fn bounded(comptime S: type, items: []const zidl_rt.SeqElem(S)) S {
    var b: S = .{};
    for (items) |e| b.appendAssumeCapacity(e);
    return b;
}

fn bstr(comptime N: usize, s: []const u8) zidl_rt.BoundedArray(u8, N) {
    return zidl_rt.BoundedArray(u8, N).fromSlice(s) catch unreachable;
}

fn F(comptime T: type, comptime field: []const u8) type {
    return @FieldType(T, field);
}

fn prims() KA.Prims {
    return .{
        .s_long = borrow(F(KA.Prims, "s_long"), &.{ 1, -2, 3 }),
        .s_octet = borrow(F(KA.Prims, "s_octet"), &.{ 1, 2, 3 }),
        .s_bool = borrow(F(KA.Prims, "s_bool"), &.{ true, false }),
        .s_ll = borrow(F(KA.Prims, "s_ll"), &.{ 1, -1 }),
        .s_dbl = borrow(F(KA.Prims, "s_dbl"), &.{1.5}),
        .s_short = borrow(F(KA.Prims, "s_short"), &.{ 7, -8, 9 }),
        .a_long = .{ .{ 1, 2 }, .{ 3, 4 } },
    };
}

fn nonPrims() KA.NonPrims {
    return .{
        .s_str = borrow(F(KA.NonPrims, "s_str"), &.{ "a", "bc" }),
        .s_bstr = bounded(F(KA.NonPrims, "s_bstr"), &.{ bstr(5, "xy"), bstr(5, "z") }),
        .s_ubstr = borrow(F(KA.NonPrims, "s_ubstr"), &.{ bstr(5, "uv"), bstr(5, ""), bstr(5, "w") }),
        .s_enum = borrow(F(KA.NonPrims, "s_enum"), &.{ .GREEN, .BLUE }),
        .s_bm = borrow(F(KA.NonPrims, "s_bm"), &.{ KA.Flags_F0 | KA.Flags_F2, KA.Flags_F1 }),
        .s_struct = borrow(F(KA.NonPrims, "s_struct"), &.{ .{ .label = "n1", .id = 1 }, .{ .label = "n2", .id = 2 } }),
        .s_astruct = borrow(F(KA.NonPrims, "s_astruct"), &.{.{ .label = "x" }}),
        .s_union = borrow(F(KA.NonPrims, "s_union"), &.{ .{ ._d = 1, ._u = .{ .i = 7 } }, .{ ._d = 2, ._u = .{ .s = "u" } } }),
        .t_seq = borrow(KA.StrSeq, &.{"t"}),
    };
}

const SSeq = F(KA.Nested, "s_seq");
const SSeqStr = F(KA.Nested, "s_seq_str");
const SSeqStruct = F(KA.Nested, "s_seq_struct");

fn nested() KA.Nested {
    return .{
        .s_seq = borrow(SSeq, &.{ borrow(zidl_rt.SeqElem(SSeq), &.{ 1, 2 }), borrow(zidl_rt.SeqElem(SSeq), &.{3}) }),
        .s_tseq = bounded(F(KA.Nested, "s_tseq"), &.{ borrow(KA.LongSeq, &.{4}), .{} }),
        .s_seq_str = borrow(SSeqStr, &.{ borrow(zidl_rt.SeqElem(SSeqStr), &.{"a"}), borrow(zidl_rt.SeqElem(SSeqStr), &.{ "b", "c" }) }),
        .s_seq_struct = borrow(SSeqStruct, &.{borrow(zidl_rt.SeqElem(SSeqStruct), &.{.{ .label = "q", .id = 1 }})}),
        .s_arr = borrow(F(KA.Nested, "s_arr"), &.{ .{ 1, 2, 3 }, .{ 4, 5, 6 } }),
        .s_barr = bounded(F(KA.Nested, "s_barr"), &.{.{ 7, 8, 9 }}),
    };
}

fn arrays() KA.Arrays {
    return .{
        .a_str = .{ "p", "q" },
        .a_enum = .{ .BLUE, .RED },
        .a_struct = .{ .{ .label = "s1", .id = 1 }, .{ .label = "s2", .id = 2 } },
        .a_str2 = .{ .{ "w", "x" }, .{ "y", "z" } },
        .a_tarr = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 } },
        .a_seq = .{ borrow(KA.LongSeq, &.{1}), borrow(KA.LongSeq, &.{ 2, 3 }) },
    };
}

fn app() KA.App {
    return .{ .np = nonPrims(), .extra = borrow(F(KA.App, "extra"), &.{.{ .label = "e", .id = 5 }}) };
}

fn mut() KA.Mut {
    return .{
        .s_str = borrow(F(KA.Mut, "s_str"), &.{"m"}),
        .s_long = borrow(F(KA.Mut, "s_long"), &.{ 1, 2 }),
        .s_octet = borrow(F(KA.Mut, "s_octet"), &.{9}),
        .s_ll = borrow(F(KA.Mut, "s_ll"), &.{5}),
        .s_short = borrow(F(KA.Mut, "s_short"), &.{3}),
        .s_struct = borrow(F(KA.Mut, "s_struct"), &.{.{ .label = "k", .id = 4 }}),
        .name = "nm",
        .a_long = .{ 6, 7 },
        .a_struct = .{ .{ .label = "a", .id = 1 }, .{ .label = "b", .id = 2 } },
        .nest = nested(),
    };
}

// ── Structural equality over zidl's representations ──────────────────────────

fn eql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (T == KA.U) {
        if (a._d != b._d) return false;
        return switch (a._d) {
            1 => a._u.i == b._u.i,
            2 => std.mem.eql(u8, a._u.s, b._u.s),
            else => true,
        };
    }
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            if (@hasField(T, "_buffer")) {
                if (a._length != b._length) return false;
                for (0..a._length) |i| if (!eql(a._buffer.?[i], b._buffer.?[i])) return false;
                return true;
            }
            if (@hasField(T, "buf") and @hasDecl(T, "slice")) {
                if (a.len != b.len) return false;
                for (a.slice(), b.slice()) |x, y| if (!eql(x, y)) return false;
                return true;
            }
            inline for (st.fields) |fld| if (!eql(@field(a, fld.name), @field(b, fld.name))) return false;
            return true;
        },
        .pointer => |p| switch (p.size) {
            .slice => return std.mem.eql(p.child, a, b),
            .many => return std.mem.eql(p.child, std.mem.span(a), std.mem.span(b)),
            else => return a == b,
        },
        .array => {
            for (a, b) |x, y| if (!eql(x, y)) return false;
            return true;
        },
        .float => return a == b,
        else => return std.meta.eql(a, b),
    }
}

// ── Checks ────────────────────────────────────────────────────────────────────

/// Top-level extensibility, as annotated in ka.idl: it selects the XCDR2
/// representation id (CDR2 / D_CDR2 / PL_CDR2).
const Ext = enum { final, appendable, mutable };

fn encode(comptime T: type, comptime v: zidl_rt.XcdrVersion, comptime ext: Ext, value: T) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var w = zidl_rt.CdrWriter(v).init(&buf, testing.allocator);
    switch (ext) {
        .final => try w.writeEncapHeader(),
        .appendable => try w.writeEncapHeaderDelimited(),
        .mutable => try w.writeEncapHeaderMutable(),
    }
    try T.serialize(&w, value);
    return buf.toOwnedSlice(testing.allocator);
}

/// The reference sample: the representation id the reference writes for
/// this type and encoding, then the payload.
fn referenceSample(name: []const u8, tag: []const u8) ![]u8 {
    const id = try vector("encap", name, tag);
    defer testing.allocator.free(id);
    const payload = try vector("data", name, tag);
    defer testing.allocator.free(payload);
    const out = try testing.allocator.alloc(u8, payload.len + 4);
    out[0..4].* = .{ id[0], id[1], 0x00, 0x00 };
    @memcpy(out[4..], payload);
    return out;
}

fn decodeWith(comptime T: type, bytes: []const u8, alloc: std.mem.Allocator) !T {
    var r = try zidl_rt.CdrReader.init(bytes);
    var out: T = .{};
    try T.deserializeInto(&out, &r, alloc);
    if (r.pos != bytes.len) {
        out.deinit(alloc);
        return error.TrailingBytes;
    }
    return out;
}

fn decodeAndRelease(alloc: std.mem.Allocator, comptime T: type, bytes: []const u8) !void {
    var v = try decodeWith(T, bytes, alloc);
    defer v.deinit(alloc);
    var c = try v.clone(alloc);
    c.deinit(alloc);
}

fn check(comptime T: type, comptime name: []const u8, comptime ext: Ext, sample: T, comptime compare_bytes: bool, comptime encodings: []const zidl_rt.XcdrVersion) !void {
    inline for (encodings) |v| {
        const tag = if (v == .xcdr1) "xcdr1" else "xcdr2";
        const reference = try referenceSample(name, tag);
        defer testing.allocator.free(reference);

        // zidl encodes the sample to the reference bytes, representation id
        // included (for Mut only the id: its payload legitimately differs).
        const ours = try encode(T, v, ext, sample);
        defer testing.allocator.free(ours);
        if (compare_bytes) {
            try testing.expectEqualSlices(u8, reference, ours);
        } else {
            try testing.expectEqualSlices(u8, reference[0..4], ours[0..4]);
        }

        // The reference bytes (and zidl's own) decode back to the sample.
        inline for (.{ reference, ours }) |bytes| {
            var got = try decodeWith(T, bytes, testing.allocator);
            defer got.deinit(testing.allocator);
            try testing.expect(eql(sample, got));
            var copy = try got.clone(testing.allocator);
            defer copy.deinit(testing.allocator);
            try testing.expect(eql(sample, copy));
        }

        // Every strict prefix fails without leaking or crashing.
        for (4..reference.len) |cut| {
            try testing.expect(std.meta.isError(decodeWith(T, reference[0..cut], testing.allocator)));
        }

        // Every allocation failure during decode + clone rolls back cleanly.
        const Run = struct {
            fn run(alloc: std.mem.Allocator, bytes: []const u8) !void {
                return decodeAndRelease(alloc, T, bytes);
            }
        };
        try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{reference});
    }

    const hash = try vector("hash", name, "");
    defer testing.allocator.free(hash);
    try testing.expectEqualSlices(u8, hash, &T.equivalence_hash);
}

const both = &[_]zidl_rt.XcdrVersion{ .xcdr1, .xcdr2 };

test "Prims (primitive elements: no collection DHEADER)" {
    try check(KA.Prims, "Prims", .final, comptime prims(), true, both);
}

test "NonPrims (string/enum/bitmask/struct/union elements: DHEADER in XCDR2)" {
    try check(KA.NonPrims, "NonPrims", .final, comptime nonPrims(), true, both);
}

test "Nested (sequences of sequences and of array typedefs)" {
    try check(KA.Nested, "Nested", .final, comptime nested(), true, both);
}

test "Arrays (multi-dimensional, flattened array typedefs, arrays of sequences)" {
    try check(KA.Arrays, "Arrays", .final, comptime arrays(), true, both);
}

test "App (appendable holder)" {
    try check(KA.App, "App", .appendable, comptime app(), true, both);
}

test "Mut (mutable members: EMHEADER length codes 5-7 in the reference)" {
    try check(KA.Mut, "Mut", .mutable, comptime mut(), false, &.{.xcdr2});
}

test "minimal TypeObject hashes of element structs" {
    // Unions get no TypeObject constants; `U`'s hash is covered through
    // NonPrims, whose TypeObject embeds it.
    inline for (.{ .{ KA.Named, "Named" }, .{ KA.NamedA, "NamedA" } }) |e| {
        const hash = try vector("hash", e[1], "");
        defer testing.allocator.free(hash);
        try testing.expectEqualSlices(u8, hash, &e[0].equivalence_hash);
    }
}
