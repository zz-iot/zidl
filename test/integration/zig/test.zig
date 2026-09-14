// Integration tests for the generated Zig types + CDR serialization + vtable.
// These run as part of `zig build test`.

const std = @import("std");
const testing = std.testing;
const zidl_rt = @import("zidl_rt");
const types = @import("types");
const stub = @import("stub_impl");

// ── CDR round-trip: Sample (@final, with @key) ────────────────────────────────

test "roundtrip: Sample @final fields" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();

    const src = types.Sample{
        .id = 42,
        .b = true,
        .u8_val = 0xFF,
        .s16_val = -1000,
        .u16_val = 65000,
        .s32_val = -2_000_000,
        .u32_val = 4_000_000,
        .s64_val = -9_000_000_000,
        .u64_val = 18_000_000_000,
        .f32_val = 3.14,
        .f64_val = 2.718281828,
        .str = "hello world",
        .bstr = zidl_rt.BoundedArray(u8, 32).fromSlice("bounded") catch unreachable,
        .nums = .{}, // zero-initialized extern struct sequence
        .arr = .{ 10, 20, 30 },
        .clr = .GREEN,
        .nested = .{ .x = 7, .y = -3 },
    };

    try types.Sample.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var dst: types.Sample = .{};
    try types.Sample.deserializeInto(&dst, &reader, testing.allocator);
    defer testing.allocator.free(dst.str);

    try testing.expectEqual(src.id, dst.id);
    try testing.expectEqual(src.b, dst.b);
    try testing.expectEqual(src.u8_val, dst.u8_val);
    try testing.expectEqual(src.s16_val, dst.s16_val);
    try testing.expectEqual(src.u16_val, dst.u16_val);
    try testing.expectEqual(src.s32_val, dst.s32_val);
    try testing.expectEqual(src.u32_val, dst.u32_val);
    try testing.expectEqual(src.s64_val, dst.s64_val);
    try testing.expectEqual(src.u64_val, dst.u64_val);
    try testing.expectApproxEqRel(src.f32_val, dst.f32_val, 1e-5);
    try testing.expectApproxEqRel(src.f64_val, dst.f64_val, 1e-12);
    try testing.expectEqualStrings(src.str, dst.str);
    try testing.expectEqualSlices(u8, src.bstr.slice(), dst.bstr.slice());
    try testing.expectEqualSlices(i32, src.arr[0..], dst.arr[0..]);
    try testing.expectEqual(src.clr, dst.clr);
    try testing.expectEqual(src.nested.x, dst.nested.x);
    try testing.expectEqual(src.nested.y, dst.nested.y);
}

test "roundtrip: Sample key serialization" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();

    const src = types.Sample{ .id = 99 };
    try types.Sample.serializeKey(&writer, src);

    // 4 encap + 4 bytes for the u32 key field
    try testing.expectEqual(@as(usize, 8), buf.items.len);
    try testing.expect(types.Sample.has_key);
    try testing.expect(!types.Frame.has_key);
}

// deserializeKeyInto is a key-only-payload reader.  Calling it on a full
// sample payload only works when ALL key members precede ALL non-key members
// (so the key bytes appear first in both the full payload and the key-only
// payload) -- Sample.id is declared first, so this test passes. This is
// deliberate misuse for illustration only: a real full-payload caller should
// use computeKeyHashFromCdr (deserializeSelected-based), which skips non-key
// members correctly regardless of where @key sits; deserializeKeyInto's own
// contract is "the wire bytes are a key-only payload", not "the leading
// bytes of a full one".
test "roundtrip: Sample deserializeKeyInto from full sample (key field is leading)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    const nums_items = try testing.allocator.dupe(i32, &.{ 11, 22, 33 });
    defer testing.allocator.free(nums_items);

    const src = types.Sample{
        .id = 0x01020304,
        .b = true,
        .str = "non-key payload",
        .nums = .{ ._length = 3, ._maximum = 3, ._buffer = nums_items.ptr, ._release = false },
        .arr = .{ 1, 2, 3 },
        .nested = .{ .x = 10, .y = 20 },
    };

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Sample.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var key: types.Sample = .{};
    try types.Sample.deserializeKeyInto(&key, &reader, testing.allocator);

    try testing.expectEqual(src.id, key.id);
    try testing.expectEqual(false, key.b);
    try testing.expectEqualStrings("", key.str);
    try testing.expectEqual(@as(u32, 0), key.nums._length);
    try testing.expectEqual(@as(i32, 0), key.nested.x);
    // @final structs have no DHEADER bound; deserializeKeyInto reads only key
    // fields and leaves the non-key tail in the reader.
}

test "roundtrip: Sample deserializeKeyInto from key-only payload" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Sample.serializeKey(&writer, .{ .id = 0xDEADBEEF });

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var key: types.Sample = .{};
    try types.Sample.deserializeKeyInto(&key, &reader, testing.allocator);

    try testing.expectEqual(@as(u32, 0xDEADBEEF), key.id);
    try testing.expectEqual(@as(usize, 0), reader.remaining());
}

test "roundtrip: Sample computeKeyHash pads short PLAIN_CDR2 BE key" {
    const value = types.Sample{ .id = 0x01020304 };
    const hash = types.Sample.computeKeyHash(&value);
    const expected = [_]u8{
        0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    try testing.expectEqualSlices(u8, expected[0..], hash[0..]);
}

test "roundtrip: Sample with sequence" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    const nums_items = try testing.allocator.dupe(i32, &.{ 1, 2, 3, 4, 5 });
    defer testing.allocator.free(nums_items);

    var src = types.Sample{};
    src.nums = .{ ._length = 5, ._maximum = 5, ._buffer = nums_items.ptr, ._release = false };

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Sample.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var dst = types.Sample{};
    try types.Sample.deserializeInto(&dst, &reader, testing.allocator);
    defer {
        testing.allocator.free(dst.str);
        if (dst.nums._release) {
            if (dst.nums._buffer) |b| testing.allocator.free(b[0..dst.nums._maximum]);
        }
    }

    const src_slice = if (src.nums._buffer) |b| b[0..src.nums._length] else &.{};
    const dst_slice = if (dst.nums._buffer) |b| b[0..dst.nums._length] else &.{};
    try testing.expectEqualSlices(i32, src_slice, dst_slice);
}

// ── deinit idempotency / self-cleaning deserializeInto ────────────────────────

test "idempotency: Sample.deinit can be called twice safely" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    const nums_items = try testing.allocator.dupe(i32, &.{ 1, 2, 3 });
    defer testing.allocator.free(nums_items);

    var src = types.Sample{ .str = "hello" };
    src.nums = .{ ._length = 3, ._maximum = 3, ._buffer = nums_items.ptr, ._release = false };

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Sample.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var dst = types.Sample{};
    try types.Sample.deserializeInto(&dst, &reader, testing.allocator);

    // Both the string and sequence fields are heap-owned by the decode.
    // A second `deinit()` call must be a safe no-op, not a double-free --
    // testing.allocator (a checking allocator) fails the test otherwise.
    dst.deinit(testing.allocator);
    dst.deinit(testing.allocator);
}

test "deserializeInto self-cleans on a mid-decode error, no caller cleanup needed" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    const nums_items = try testing.allocator.dupe(i32, &.{ 1, 2, 3 });
    defer testing.allocator.free(nums_items);

    var src = types.Sample{ .str = "hello world" };
    src.nums = .{ ._length = 3, ._maximum = 3, ._buffer = nums_items.ptr, ._release = false };

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Sample.serialize(&writer, src);

    // Truncate the tail (`nested.y`, the last field written) so `str` and
    // `nums` are already heap-allocated by the time the read fails.
    var reader = try zidl_rt.CdrReader.init(buf.items[0 .. buf.items.len - 4]);
    var dst = types.Sample{};
    try testing.expectError(
        error.EndOfStream,
        types.Sample.deserializeInto(&dst, &reader, testing.allocator),
    );

    // No manual cleanup here at all: `deserializeInto`'s own
    // `errdefer out.deinit(allocator)` already freed and reset `str`/`nums`
    // on the way out. testing.allocator would flag a leak at test teardown
    // if it hadn't.
    try testing.expectEqualStrings("", dst.str);
    try testing.expectEqual(@as(u32, 0), dst.nums._length);
}

// ── CDR round-trip: Frame (@appendable, DHEADER) ──────────────────────────────

test "roundtrip: Frame @appendable DHEADER" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();

    const src = types.Frame{ .seq_num = 7, .topic = "/sensors/imu" };
    try types.Frame.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var dst: types.Frame = .{};
    try types.Frame.deserializeInto(&dst, &reader, testing.allocator);
    defer testing.allocator.free(dst.topic);

    try testing.expectEqual(src.seq_num, dst.seq_num);
    try testing.expectEqualStrings(src.topic, dst.topic);
}

// ── Cross-backend wire-byte tests ────────────────────────────────────────────
//
// These tests pin the exact CDR bytes for serialize_key / deserialize_key /
// computeKeyHash.  The expected bytes are identical across C, C++, Java, and
// Zig — any divergence is a bug.
//
// Sample (@final, @key unsigned long id=0x01020304):
//   serializeKey  → encap(00 07 00 00) + id-LE(04 03 02 01)           = 8 bytes
//
// Beacon (@appendable, @key unsigned long id=7):
//   serializeKey  → encap(00 07 00 00) + DHEADER-LE(04 00 00 00)
//                   + id-LE(07 00 00 00)                               = 12 bytes
//   computeKeyHash → id-BE(00 00 00 07) padded to 16

test "wire-bytes: Sample serialize_key / deserialize_key" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Sample.serializeKey(&writer, .{ .id = 0x01020304 });

    const expected = [_]u8{
        0x00, 0x07, 0x00, 0x00, // encap: XCDR2 LE
        0x04, 0x03, 0x02, 0x01, // id = 0x01020304, u32 LE
    };
    try testing.expectEqualSlices(u8, &expected, buf.items);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var key: types.Sample = .{};
    try types.Sample.deserializeKeyInto(&key, &reader, testing.allocator);
    try testing.expectEqual(@as(u32, 0x01020304), key.id);
    try testing.expectEqual(@as(usize, 0), reader.remaining());
}

test "wire-bytes: Beacon serialize_key / deserialize_key / computeKeyHash" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Beacon.serializeKey(&writer, .{ .id = 7 });

    const expected = [_]u8{
        0x00, 0x07, 0x00, 0x00, // encap: XCDR2 LE
        0x04, 0x00, 0x00, 0x00, // DHEADER = 4 (one u32 key field follows)
        0x07, 0x00, 0x00, 0x00, // id = 7, u32 LE
    };
    try testing.expectEqualSlices(u8, &expected, buf.items);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var key: types.Beacon = .{};
    try types.Beacon.deserializeKeyInto(&key, &reader, testing.allocator);
    try testing.expectEqual(@as(u32, 7), key.id);
    try testing.expectEqual(@as(usize, 0), reader.remaining());

    const beacon_value = types.Beacon{ .id = 7 };
    const hash = types.Beacon.computeKeyHash(&beacon_value);
    const expected_hash = [_]u8{
        0x00, 0x00, 0x00, 0x07,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected_hash, &hash);
}

// ── Vtable: Greeter ───────────────────────────────────────────────────────────

test "vtable: Greeter call forwarding" {
    var impl = stub.GreeterStub{};
    const g = impl.asGreeter();

    // Forwarding method accepts []const u8 and returns []const u8 (idiomatic Zig).
    const greeting = g.greet("Alice");
    try testing.expectEqualStrings("hello", greeting);
    try testing.expectEqualStrings("Alice", impl.last_name);
    try testing.expectEqual(@as(i32, 1), g.get_count());

    _ = g.greet("Bob");
    try testing.expectEqual(@as(i32, 2), g.get_count());

    g.reset();
    try testing.expectEqual(@as(i32, 0), g.get_count());
}

test "vtable: Greeter deinit is safe" {
    var impl = stub.GreeterStub{};
    const g = impl.asGreeter();
    g.deinit(); // must not crash
}
