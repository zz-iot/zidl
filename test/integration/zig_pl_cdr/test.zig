// Compiles and runs --zig-pl-cdr output for real: retention (@pl_retain_unknown
// → unknown_params + replay), strict-mode must-understand rejection, and the
// generated deinit/clone for the retained slice. The codegen tests in
// src/backend/zig.zig only substring-match; this exercises behaviour.

const std = @import("std");
const testing = std.testing;
const zidl_rt = @import("zidl_rt");
const fixture = @import("fixture");

const RetainRec = fixture.RetainRec;
const PlainRec = fixture.PlainRec;

const UNKNOWN_IGNORABLE: u16 = 0x8055; // vendor bit set, must-understand clear
const UNKNOWN_MUST_UNDERSTAND: u16 = 0x4099; // must-understand bit set

/// encap + a(pid 16)=42 + unknown ignorable(8B) + b(pid 32)=7 + unknown MU(4B) + sentinel
fn buildWire(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
    var w = zidl_rt.PlCdrWriter.init(buf, alloc);
    try w.writeEncapHeader();
    {
        const h = try w.reservePlParam(16);
        try w.writeI32(42);
        try w.patchPlParam(h);
    }
    {
        const h = try w.reservePlParam(UNKNOWN_IGNORABLE);
        try w.writeBytes(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
        try w.patchPlParam(h);
    }
    {
        const h = try w.reservePlParam(32);
        try w.writeI32(7);
        try w.patchPlParam(h);
    }
    {
        const h = try w.reservePlParam(UNKNOWN_MUST_UNDERSTAND);
        try w.writeI32(99);
        try w.patchPlParam(h);
    }
    try w.writePlSentinel();
}

test "pl_cdr fixture: @pl_retain_unknown adds the field; a plain @mutable struct does not" {
    try testing.expect(@hasField(RetainRec, "unknown_params"));
    try testing.expect(!@hasField(PlainRec, "unknown_params"));
}

test "pl_cdr fixture: lenient decode keeps modelled fields and retains unknowns in order" {
    const alloc = testing.allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    try buildWire(alloc, &buf);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var rec: RetainRec = .{};
    try RetainRec.deserializeFromPlCdr(&rec, &reader, alloc, .lenient);
    defer rec.deinit(alloc);

    try testing.expectEqual(@as(i32, 42), rec.a);
    try testing.expectEqual(@as(?i32, 7), rec.b);
    try testing.expectEqual(@as(usize, 2), rec.unknown_params.len);
    try testing.expectEqual(UNKNOWN_IGNORABLE, rec.unknown_params[0].pid);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, rec.unknown_params[0].bytes);
    try testing.expectEqual(UNKNOWN_MUST_UNDERSTAND, rec.unknown_params[1].pid);
}

test "pl_cdr fixture: serializePlCdr replays retained unknowns; second decode matches" {
    const alloc = testing.allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    try buildWire(alloc, &buf);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var rec: RetainRec = .{};
    try RetainRec.deserializeFromPlCdr(&rec, &reader, alloc, .lenient);
    defer rec.deinit(alloc);

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(alloc);
    var w = zidl_rt.PlCdrWriter.init(&out, alloc);
    try w.writeEncapHeader();
    try RetainRec.serializePlCdr(&w, rec);

    var reader2 = try zidl_rt.CdrReader.init(out.items);
    var rec2: RetainRec = .{};
    try RetainRec.deserializeFromPlCdr(&rec2, &reader2, alloc, .lenient);
    defer rec2.deinit(alloc);

    try testing.expectEqual(rec.a, rec2.a);
    try testing.expectEqual(rec.b, rec2.b);
    try testing.expectEqual(@as(usize, 2), rec2.unknown_params.len);
    try testing.expectEqualSlices(u8, rec.unknown_params[0].bytes, rec2.unknown_params[0].bytes);
    try testing.expectEqualSlices(u8, rec.unknown_params[1].bytes, rec2.unknown_params[1].bytes);
}

test "pl_cdr fixture: strict decode rejects an unknown must-understand parameter" {
    const alloc = testing.allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    try buildWire(alloc, &buf);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var rec: RetainRec = .{};
    // The ignorable unknown is retained first, then 0x4099 aborts the decode:
    // the generated errdefer must free that partial retention (testing.allocator
    // fails the test otherwise).
    try testing.expectError(
        error.UnknownMustUnderstand,
        RetainRec.deserializeFromPlCdr(&rec, &reader, alloc, .strict),
    );
}

test "pl_cdr fixture: strict decode rejects a repeated non-@pl_repeated PID" {
    const alloc = testing.allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = zidl_rt.PlCdrWriter.init(&buf, alloc);
    try w.writeEncapHeader();
    inline for (.{ 42, 43 }) |v| {
        const h = try w.reservePlParam(16); // pid 16 == RetainRec.a, twice
        try w.writeI32(v);
        try w.patchPlParam(h);
    }
    try w.writePlSentinel();

    var r_strict = try zidl_rt.CdrReader.init(buf.items);
    var rec: RetainRec = .{};
    try testing.expectError(
        error.DuplicateParameter,
        RetainRec.deserializeFromPlCdr(&rec, &r_strict, alloc, .strict),
    );

    // lenient: last-wins, no error
    var r_lenient = try zidl_rt.CdrReader.init(buf.items);
    var rec2: RetainRec = .{};
    try RetainRec.deserializeFromPlCdr(&rec2, &r_lenient, alloc, .lenient);
    defer rec2.deinit(alloc);
    try testing.expectEqual(@as(i32, 43), rec2.a);
}

test "pl_cdr fixture: clone deep-copies unknown_params" {
    const alloc = testing.allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    try buildWire(alloc, &buf);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var rec: RetainRec = .{};
    try RetainRec.deserializeFromPlCdr(&rec, &reader, alloc, .lenient);
    defer rec.deinit(alloc);

    var cl = try rec.clone(alloc);
    defer cl.deinit(alloc);

    try testing.expectEqual(rec.a, cl.a);
    try testing.expectEqual(rec.unknown_params.len, cl.unknown_params.len);
    try testing.expectEqualSlices(u8, rec.unknown_params[0].bytes, cl.unknown_params[0].bytes);
    // independent allocations: the two deinits (deferred) must not double-free
    try testing.expect(rec.unknown_params[0].bytes.ptr != cl.unknown_params[0].bytes.ptr);
}

test "pl_cdr fixture: plain @mutable struct still honours strict must-understand" {
    const alloc = testing.allocator;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = zidl_rt.PlCdrWriter.init(&buf, alloc);
    try w.writeEncapHeader();
    {
        const h = try w.reservePlParam(16);
        try w.writeI32(5);
        try w.patchPlParam(h);
    }
    {
        const h = try w.reservePlParam(UNKNOWN_MUST_UNDERSTAND);
        try w.writeI32(0);
        try w.patchPlParam(h);
    }
    try w.writePlSentinel();

    var r_lenient = try zidl_rt.CdrReader.init(buf.items);
    var p_lenient: PlainRec = .{};
    try PlainRec.deserializeFromPlCdr(&p_lenient, &r_lenient, alloc, .lenient);
    try testing.expectEqual(@as(i32, 5), p_lenient.a);

    var r_strict = try zidl_rt.CdrReader.init(buf.items);
    var p_strict: PlainRec = .{};
    try testing.expectError(
        error.UnknownMustUnderstand,
        PlainRec.deserializeFromPlCdr(&p_strict, &r_strict, alloc, .strict),
    );
}
